/// 设置主页（2.4.0 设置搬家 + 入口拆分段）：整体接替退役的全量
/// /settings 长页。本页**只做分组索引，不放任何设置内容本体**——
/// 九行落点 + 页脚「关于」（版本号 + 检查更新，原全量页「关于」节搬入）。
///
/// 路由沿用 `/settings`（旧长页退役，路径语义无缝接管）：
/// · 外观组：空间信息（弹窗，沿 spaceEditRequestedProvider 机制）/
///   主题与外观 / 主页背景 / 聊天背景 / 聊天气泡（后四张独立页）；
/// · 连接与提醒组：提醒设置（→ /channels）/ 线路与连接 / 消息通知；
/// · 数据与账号组：数据导出（独立页）/ 备份与存储（→ /backups，admin
///   门控沿用 main.dart redirect）/ 邀请另一半入住（→ /settings/invite）。
/// 页头文案「设置 / 管理空间、账号和数据。」（沿用原页副题逐字）。
library;

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import '../../core/peer/peer_locator.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:love_space/core/audio/audio_init_status.dart' show audioInitStatusProvider;
import 'package:love_space/core/notify/notify_status.dart' show NotifyDiag, notifyStatusProvider;
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/config.dart';
import '../../core/theme/tokens.dart';
import '../../core/ui/apple_ui.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../shell/web_chrome.dart' show WebSemanticColors;
import '../update/update_service.dart' show manualCheck;
import 'settings_state.dart';

class SettingsHomePage extends ConsumerStatefulWidget {
  const SettingsHomePage({super.key});

  @override
  ConsumerState<SettingsHomePage> createState() => _SettingsHomePageState();
}

class _SettingsHomePageState extends ConsumerState<SettingsHomePage> {
  // ── 页脚「关于」（原全量页「关于」节整节搬入，逻辑零改动） ─────────
  ApkStatus? _status;
  String _pkgVersion = '';
  String _pkgBuild = '';
  String? _updateError;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
    Future.microtask(_checkUpdate);
  }

  Future<void> _loadPackageInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _pkgVersion = info.version;
          _pkgBuild = info.buildNumber;
        });
      }
    } catch (_) {
      // 读不到时保持空值，UI 显示「版本加载中…」
    }
  }

  Future<void> _checkUpdate() async {
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.get('/api/status');
      if (mounted) {
        setState(() {
          _status = ApkStatus.fromJson(r.data);
          _updateError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _updateError = api.errorDetail(e));
    }
  }

  Future<void> _copyLink(String link) async {
    await Clipboard.setData(ClipboardData(text: link));
    ref.read(chatToastProvider.notifier).show('下载链接已复制，可以直接发给对方');
  }

  /// 手动检查更新（2.4.3 提交三）：接 GitHub Releases 新数据源，
  /// 不受节流、有明确反馈——有新版弹更新 sheet；无新版顶部 toast
  /// 「已是最新版本」；失败 toast 原因简述。
  Future<void> _manualUpdateCheck() async {
    if (_checking) return;
    if (Platform.isIOS) return; // iOS 不检查（平台判断收口）
    setState(() => _checking = true);
    String status;
    try {
      status = await manualCheck(ref, context, _pkgVersion);
    } catch (_) {
      status = 'error';
    }
    if (!mounted) return;
    setState(() => _checking = false);
    if (status == 'up-to-date') {
      ref.read(chatToastProvider.notifier).show('已是最新版本');
    } else if (status == 'error') {
      ref
          .read(chatToastProvider.notifier)
          .show('检查更新失败：请稍后再试（网络原因）');
    }
    // has-update 已弹层，无需 toast
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: appleCanvasColor(theme),
      appBar: AppBar(
        title: const Text('设置'),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: ApplePageBackground(
        child: RefreshIndicator(
          onRefresh: _checkUpdate,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, Spacing.pageBottom),
            children: [
              // 页头副题（沿用原全量页逐字；标题在 AppBar）
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 14),
                child: Text(
                  '管理空间、账号和数据。',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
                ),
              ),
              AppleGroupedSection(
                title: '外观',
                children: [
                  AppleGroupedRow(
                    key: const Key('settings-home-space'),
                    icon: Icons.home_rounded,
                    tone: AppleIconTone.coral,
                    title: '空间信息',
                    subtitle: '空间名称与相恋日期',
                    onTap: () => context.push('/settings/space'),
                  ),
                  AppleGroupedRow(
                    key: const Key('settings-home-theme'),
                    icon: Icons.palette_rounded,
                    tone: AppleIconTone.purple,
                    title: '主题与外观',
                    subtitle: '主题色、夜间模式与动效',
                    onTap: () => context.push('/settings/theme'),
                  ),
                  AppleGroupedRow(
                    key: const Key('settings-home-cover'),
                    icon: Icons.photo_rounded,
                    tone: AppleIconTone.sky,
                    title: '主页背景',
                    subtitle: '换一张首页封面照片',
                    onTap: () => context.push('/settings/cover'),
                  ),
                  AppleGroupedRow(
                    key: const Key('settings-home-chat-bg'),
                    icon: Icons.wallpaper_rounded,
                    tone: AppleIconTone.teal,
                    title: '聊天背景',
                    subtitle: '聊天壁纸与文字对比度',
                    onTap: () => context.push('/settings/chat-wallpaper'),
                  ),
                  AppleGroupedRow(
                    key: const Key('settings-home-chat-bubble'),
                    icon: Icons.chat_bubble_rounded,
                    tone: AppleIconTone.pink,
                    title: '聊天气泡',
                    subtitle: '两千多款气泡皮肤随手挑',
                    onTap: () => context.push('/settings/chat-bubble'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              AppleGroupedSection(
                title: '连接与提醒',
                children: [
                  AppleGroupedRow(
                    key: const Key('settings-home-remind'),
                    icon: Icons.notifications_rounded,
                    tone: AppleIconTone.rose,
                    title: '提醒设置',
                    subtitle: '通知渠道与提醒偏好',
                    onTap: () => context.push('/channels'),
                  ),
                  AppleGroupedRow(
                    key: const Key('settings-home-links'),
                    icon: Icons.wifi_tethering_rounded,
                    tone: AppleIconTone.blue,
                    title: '线路与连接',
                    subtitle: '链路检测与手动切线路',
                    onTap: () => context.push('/settings/links'),
                  ),
                  AppleGroupedRow(
                    key: const Key('settings-home-notify'),
                    icon: Icons.mark_chat_unread_rounded,
                    tone: AppleIconTone.indigo,
                    title: '消息通知',
                    subtitle: 'App 后台收 TA 的消息提醒',
                    onTap: () => context.push('/settings/notify'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const PeerVerifyCard(),
              const SizedBox(height: 18),
              AppleGroupedSection(
                title: '数据与账号',
                children: [
                  AppleGroupedRow(
                    key: const Key('settings-home-export'),
                    icon: Icons.inventory_2_rounded,
                    tone: AppleIconTone.amber,
                    title: '数据导出',
                    subtitle: '记录打包、Markdown 与日历订阅',
                    onTap: () => context.push('/settings/export'),
                  ),
                  AppleGroupedRow(
                    key: const Key('settings-home-backups'),
                    icon: Icons.cloud_done_rounded,
                    tone: AppleIconTone.slate,
                    title: '备份与存储',
                    subtitle: '完整备份与存储占用（管理员）',
                    onTap: () => context.push('/backups'),
                  ),
                  AppleGroupedRow(
                    key: const Key('settings-home-invite'),
                    icon: Icons.favorite_rounded,
                    tone: AppleIconTone.rose,
                    title: '邀请另一半入住',
                    subtitle: '生成专属邀请链接发给 TA',
                    onTap: () => context.push('/settings/invite'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _aboutCard(context),
            ],
          ),
        ),
      ),
    );
  }

  /// 2.4.15：init 错误原文压成一行摘要（去换行，截 90 字符）。
  String _shortErr(String raw) {
    final oneLine = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length > 90 ? '${oneLine.substring(0, 90)}…' : oneLine;
  }

  // ── 关于（原全量页 _aboutCard 原样搬入；app.js:2593-2612 / :2569） ──
  Widget _aboutCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = _status;
    // 2.4.3 提交三：版本比对改接 GitHub Releases 新数据源（弹层/toast），
    // /api/status 的 apk_version 不再驱动「可更新到」提示；服务端版本展示
    // 与「复制 App 下载链接」原样保留（B3 口径）。
    final link = s == null ? '' : apkDownloadLink(s, AppConfig.builtinMainRoute);
    return AppleGroupedSection(
      title: '关于',
      children: [
        Padding(
          padding: const EdgeInsets.all(Spacing.cardPad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const AppleIconBadge(
                  icon: Icons.favorite_rounded,
                  tone: AppleIconTone.rose,
                  size: 38,
                ),
                title: const Text('恋爱空间'),
                subtitle: Text(
                  _pkgVersion.isEmpty ? '版本加载中…' : 'APK v$_pkgVersion ($_pkgBuild)',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            // 2.5.9 裁定⑥：通知服务状态行（服务运行/SSE 最近事件/最近判定/错误）
            Builder(builder: (context) {
              final NotifyDiag d = ref.read(notifyStatusProvider);
              final ok = d.running && d.connected;
              final ts = d.lastEventAtMs > 0
                  ? DateTime.fromMillisecondsSinceEpoch(d.lastEventAtMs)
                  : null;
              final tsText = ts == null
                  ? '尚无事件'
                  : '${ts.month}/${ts.day} ${ts.hour}:${ts.minute.toString().padLeft(2, '0')}';
              final lines = <String>[
                ok ? '服务运行中 · SSE 已连接' : '服务未连接（${d.running ? '服务在跑，SSE 未连' : '服务未运行'}）',
                '最近 SSE 事件：$tsText',
                if (d.decision.isNotEmpty) d.decision,
                if (d.error.isNotEmpty) '最近错误：${_shortErr(d.error)}',
              ];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(ok ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                      size: 16, color: ok ? cs.primary : cs.outline),
                  const SizedBox(width: 6),
                  Expanded(child: Text(
                    '通知服务状态：${lines.join('；')}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: ok ? cs.outline : cs.outline),
                  )),
                ]),
              );
            }),
            // 2.4.15：系统媒体播放器（通知栏/锁屏）init 结果可见——
            // 失败时带错误摘要，供真机验收截图与定位。
            Builder(builder: (context) {
              final st = ref.read(audioInitStatusProvider);
              final ok = st.ready;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  Icon(ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                      size: 16,
                      color: ok ? cs.primary : cs.error),
                  const SizedBox(width: 6),
                  Expanded(child: Text(
                    ok
                        ? '系统媒体播放器：已就绪'
                        : '系统媒体播放器：未就绪（${_shortErr(st.error ?? '初始化未完成')}）',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: ok ? cs.outline : cs.error),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                ]),
              );
            }),
            if (s != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '已是最新版本 v$_pkgVersion',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.outline),
                ),
              ),
            if (_updateError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _updateError!,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.error),
                ),
              ),
            Wrap(
              spacing: 10,
              children: [
                // 2.4.3 提交三：检查更新改接 GitHub Releases 新数据源
                // （手动检查不受节流、有明确反馈；iOS 不显示不检查）。
                // /api/status 的服务端版本展示（ initState 的 _checkUpdate）
                // 原样保留不动，仅不再驱动更新提示。
                if (!Platform.isIOS)
                  OutlinedButton(
                    key: const Key('settings-check-update'),
                    onPressed: _checking
                        ? null
                        : () => _manualUpdateCheck(),
                    child: Text(_checking ? '检查中…' : '检查更新'),
                  ),
                OutlinedButton(
                  key: const Key('settings-copy-apk'),
                  onPressed: link.isEmpty ? null : () => _copyLink(link),
                  child: const Text('复制 App 下载链接'),
                ),
              ],
            ),
            const SizedBox(height: Spacing.gap),
            Text(
              '网页功能自动更新；原生功能需下载新版 APK，可在检查更新中获取，'
              '也可复制下载链接发给对方在手机浏览器打开。',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: cs.outline),
            ),
          ],
        ),
      ),
      ],
    );
  }
}

/// 2.8.0 第 0 步：定位验证包开关卡（临时；真机 24h 验证数据采集入口）。
/// 开=权限引导 + 原生采集上报（正式 /api/peer/location，数据进 peer 表）；
/// 关=停采停报清队列。不开 overlay、不反复弹窗（红线口径）。
/// 公开化（fix2）：widget 测试直接驱动真组件验证呈现路径（原私有类测试不可达）。
/// 2.8.0 定位守护验证卡（fix4 胶水重做：Dart 只搬运与渲染）。
/// 开关态以原生 status 为单一事实源（页面进入与 toggle 后回填）；
/// 缺前台/缺后台两种 reason 分别引导；fatal 日志提供导出入口
/// （机主能把文件拿出来才算落盘完成）。不开 overlay、不反复弹窗。
class PeerVerifyCard extends ConsumerStatefulWidget {
  const PeerVerifyCard({super.key});

  @override
  ConsumerState<PeerVerifyCard> createState() => PeerVerifyCardState();
}

class PeerVerifyCardState extends ConsumerState<PeerVerifyCard> {
  bool _on = false;
  bool _busy = false;
  String _summary = '';
  String _reason = '';
  /// fix6 A1：期望态（用户意图，落盘）。只用于「已停止→点击恢复」提示，
  /// 永不自动开启采集；实态仍以原生 status 为唯一事实源。
  bool _expectedOn = false;
  /// fix6 B3：电池优化豁免状态（平台 API 读回；null=读不到）。
  bool? _batteryIgnored;

  @override
  void initState() {
    super.initState();
    // 页面进入：以原生 status 回填（单一事实源）+ 读期望态/电池豁免
    peerLocatorAutoStart().then((_) => _loadExtras());
  }

  /// 期望态与电池豁免状态（旁路信息，读失败不影响开关链）。
  Future<void> _loadExtras() async {
    final expected = await peerExpectedOn();
    final battery = await peerBatteryIgnored();
    if (!mounted) return;
    setState(() {
      _expectedOn = expected;
      _batteryIgnored = battery;
    });
    await _refresh();
  }

  Future<void> _refresh() async {
    final st = await peerVerifyStatus();
    if (!mounted) return;
    setState(() {
      _on = st['running'] == true;
      final received = (st['received'] as num?)?.toInt() ?? 0;
      final queue = (st['queue'] as num?)?.toInt() ?? 0;
      final reported = (st['reported'] as num?)?.toInt() ?? 0;
      _summary = _on
          ? '采集上报中 · 回调 $received · 已报 $reported · 队列 $queue'
          : (_expectedOn ? '采集待恢复' : '已关闭');
    });
  }

  Future<void> _toggle(bool v) async {
    setState(() => _busy = true);
    // 🔴 Dart 只搬运与渲染：结果由原生一口价返回，任何异常也产出可见原因
    PeerVerifyResult r;
    try {
      r = await peerVerifyToggle(v);
    } catch (e) {
      r = PeerVerifyResult(
          false,
          '开关处理异常：${e.toString().substring(0, e.toString().length.clamp(0, 120))}',
          const {});
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _on = v ? r.ok : false;
      _expectedOn = v ? (r.ok ? true : _expectedOn) : false;
      _reason = r.ok ? '' : r.reason;
      _summary = r.ok
          ? (v ? '采集上报中（探针验证中）' : '已关闭')
          : (v ? '开启失败' : '已关闭');
    });
    if (v && !r.ok && r.reason.isNotEmpty) {
      // 顶部弹窗（既有统一机制）+ 下方常驻原因行（失败态不许不可见）
      ref.read(chatToastProvider.notifier)
          .show(r.reason, tone: ChatToastTone.warning);
    }
    if (r.ok) await _refresh();
  }

  /// fix6 B3：拉起系统「忽略电池优化」对话框，回来后复读平台 API。
  Future<void> _requestBatteryExemption() async {
    final sent = await requestPeerBatteryExemption();
    if (!mounted) return;
    if (!sent) {
      ref.read(chatToastProvider.notifier).show(
          '无法拉起系统对话框，请在系统设置中手动将本应用设为「不限制」',
          tone: ChatToastTone.warning);
    }
    final now = await peerBatteryIgnored();
    if (!mounted) return;
    setState(() => _batteryIgnored = now);
  }

  Future<void> _exportFatal() async {
    try {
      final log = await exportPeerFatalLog();
      if (!mounted) return;
      if (log.content.isEmpty) {
        ref.read(chatToastProvider.notifier).show(
            '暂无 fatal 记录（${log.path.isEmpty ? "文件不存在" : log.path}）',
            tone: ChatToastTone.info);
        return;
      }
      await Clipboard.setData(ClipboardData(text: log.content));
      ref.read(chatToastProvider.notifier).show(
          'fatal 日志已复制到剪贴板（${log.content.length} 字符，源文件：${log.path}）',
          tone: ChatToastTone.success);
    } catch (e) {
      ref.read(chatToastProvider.notifier)
          .show('导出失败：$e', tone: ChatToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final amberFg = WebSemanticColors.amber(theme.brightness);
    final amberBg = WebSemanticColors.amberSoft(theme.brightness);
    return AppleGroupedSection(
      title: '位置共享',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
          child: Column(children: [
            SwitchListTile(
              secondary: const AppleIconBadge(
                icon: Icons.my_location_rounded,
                tone: AppleIconTone.emerald,
              ),
              title: const Text('位置共享'),
              subtitle: Text(
                  _expectedOn
                      ? (_on
                          ? '开启中 · 数据仅存自家空间 · 轨迹保留 15 天'
                          : '已开启 · 等待恢复后台采集 · 轨迹保留 15 天')
                      : '后台定位上报 · 数据仅存自家空间 · 轨迹保留 15 天',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  )),
              value: _expectedOn,
              onChanged: _busy ? null : _toggle,
            ),
          if (_summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(_summary,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  )),
            ),
          // 常驻失败原因行（细分引导：缺前台/缺后台文案由原生区分）
          if (_reason.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('⚠ $_reason',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.error)),
            ),
          // fix6 A1：期望开而实态停（进程被系统结束）→ 琥珀提示 + 一键恢复。
          if (_expectedOn && !_on)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              decoration: BoxDecoration(
                color: amberBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: amberFg.withValues(alpha: 0.45)),
              ),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Text('⚠ 已停止（进程被系统结束），点击恢复',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: amberFg,
                      )),
                  TextButton(
                    onPressed: _busy ? null : () => _toggle(true),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('恢复', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          // fix6 B3：电池优化豁免（平台 API 读回，不做推断）+ 小米两项引导
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
            child: Row(children: [
              Expanded(
                child: Text(
                  _batteryIgnored == null
                      ? '电池优化：状态未知（通道未注册）'
                      : (_batteryIgnored!
                          ? '电池优化：已豁免'
                          : '电池优化：未豁免（后台可能被系统限制）'),
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: _batteryIgnored == false
                          ? amberFg
                          : cs.onSurfaceVariant),
                ),
              ),
              if (_batteryIgnored != true)
                TextButton(
                  onPressed: _busy ? null : _requestBatteryExemption,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('去豁免', style: TextStyle(fontSize: 12)),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
            child: Text(
              '小米机型还需在「设置 → 应用 → 本应用」里单独开启「自启动」与'
              '「后台高耗电时不限制」——这两项系统开关无法由 App 代开。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.outline),
            ),
          ),
          TextButton.icon(
            onPressed: _exportFatal,
            icon: const Icon(Icons.bug_report, size: 16),
            label: const Text('导出定位诊断日志'),
          ),
          const SizedBox(height: 4),
        ]),
      ),
      ],
    );
  }
}
