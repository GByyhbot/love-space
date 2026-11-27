/// 设置主页（2.4.0 设置搬家 + 入口拆分段）：整体接替退役的全量
/// /settings 长页。本页**只做分组索引，不放任何设置内容本体**——
/// 九行落点 + 页脚「关于」（版本号 + 检查更新，原全量页「关于」节搬入）。
///
/// 路由沿用 `/settings`（旧长页退役，路径语义无缝接管）：
/// · 外观组：空间信息（弹窗，沿 spaceEditRequestedProvider 机制）/
///   主题与外观 / 主页背景 / 聊天背景 / 聊天气泡（后四张独立页）；
/// · 连接与提醒组：提醒设置（→ /channels）/ 线路与连接 / 消息通知 /
///   伴侣共享与守护（2.8.0 P1，均为独立页）；
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
import '../../core/theme/app_icons.dart';
import '../../core/theme/tokens.dart';
import '../../core/theme/typography.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
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
      appBar: AppBar(title: const Text('设置')),
      body: RefreshIndicator(
        onRefresh: _checkUpdate,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, Spacing.pageBottom),
          children: [
            // 页头副题（沿用原全量页逐字；标题在 AppBar）
            Text('管理空间、账号和数据。',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
            const SizedBox(height: 12),
            _heading(context, '外观'),
            _row(
              context,
              key: const Key('settings-home-space'),
              emoji: '🏡',
              title: '空间信息',
              subtitle: '空间名称与相恋日期',
              // 2.4.1 第 1 项：弹窗机制退役（关闭弹窗会连 /settings 一起
              // 带走掉回原 tab），改独立路由页；二级页一律 push 禁 go。
              onTap: () => context.push('/settings/space'),
            ),
            _row(
              context,
              key: const Key('settings-home-theme'),
              emoji: '🎨',
              title: '主题与外观',
              subtitle: '主题色、夜间模式与动效',
              onTap: () => context.push('/settings/theme'),
            ),
            _row(
              context,
              key: const Key('settings-home-cover'),
              emoji: '🖼️',
              title: '主页背景',
              subtitle: '换一张首页封面照片',
              onTap: () => context.push('/settings/cover'),
            ),
            _row(
              context,
              key: const Key('settings-home-chat-bg'),
              emoji: '🌄',
              title: '聊天背景',
              subtitle: '聊天壁纸与文字对比度',
              onTap: () => context.push('/settings/chat-wallpaper'),
            ),
            _row(
              context,
              key: const Key('settings-home-chat-bubble'),
              emoji: '💬',
              title: '聊天气泡',
              subtitle: '两千多款气泡皮肤随手挑',
              onTap: () => context.push('/settings/chat-bubble'),
            ),
            const SizedBox(height: 16),
            _heading(context, '连接与提醒'),
            _row(
              context,
              key: const Key('settings-home-remind'),
              emoji: '🔔',
              title: '提醒设置',
              subtitle: '通知渠道与提醒偏好',
              onTap: () => context.push('/channels'),
            ),
            _row(
              context,
              key: const Key('settings-home-links'),
              emoji: '📡',
              title: '线路与连接',
              subtitle: '链路检测与手动切线路',
              onTap: () => context.push('/settings/links'),
            ),
            // 2.4.5 乙组第 3 项：消息通知独立页（权限/服务状态/测试通知/
            // 小米放行引导）
            _row(
              context,
              key: const Key('settings-home-notify'),
              emoji: '📬',
              title: '消息通知',
              subtitle: 'App 后台收 TA 的消息提醒',
              onTap: () => context.push('/settings/notify'),
            ),
            // 2.8.0 P1：四项共享开关页（也是报备 422「去开启」的跳转目标）
            _row(
              context,
              key: const Key('settings-home-peer-share'),
              emoji: '🛡️',
              title: '伴侣共享与守护',
              subtitle: '位置、轨迹、报备与使用报告共享开关',
              onTap: () => context.push('/settings/peer-share'),
            ),
            const SizedBox(height: 16),
            // 2.8.0 第 0 步：定位验证包临时开关（分支 experiment/peer-loc-verify，
            // 机主确认后主体接线替换为正式设置页；本卡不进 main）
            const PeerVerifyCard(),
            const SizedBox(height: 16),
            _heading(context, '数据与账号'),
            _row(
              context,
              key: const Key('settings-home-export'),
              emoji: '📦',
              title: '数据导出',
              subtitle: '记录打包、Markdown 与日历订阅',
              onTap: () => context.push('/settings/export'),
            ),
            _row(
              context,
              key: const Key('settings-home-backups'),
              emoji: '🗄️',
              title: '备份与存储',
              subtitle: '完整备份与存储占用（管理员）',
              onTap: () => context.push('/backups'),
            ),
            _row(
              context,
              key: const Key('settings-home-invite'),
              emoji: '💌',
              title: '邀请另一半入住',
              subtitle: '生成专属邀请链接发给 TA',
              onTap: () => context.push('/settings/invite'),
            ),
            const SizedBox(height: 20),
            _heading(context, '关于'),
            _aboutCard(context),
          ],
        ),
      ),
    );
  }

  Widget _heading(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 8),
        child: Text(
          text,
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      );

  /// 分组索引行：标题 + 副题 + 右箭头，只跳转不放内容本体。
  Widget _row(
    BuildContext context, {
    required Key key,
    required String emoji,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: ListTile(
          key: key,
          leading: Text(emoji, style: const TextStyle(fontSize: 22)),
          title: Text(title, style: AppType.body(Theme.of(context))),
          subtitle: Text(subtitle, style: AppType.caption(Theme.of(context))),
          trailing: Icon(AppIcons.chevronRight,
              color: Theme.of(context).colorScheme.outline),
          onTap: onTap,
        ),
      );

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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.cardPad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Text('💕', style: TextStyle(fontSize: 26)),
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
          : '已关闭';
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
      _on = r.ok;
      _reason = r.ok ? '' : r.reason;
      _summary = r.ok ? '采集上报中（探针验证中）' : (v ? '开启失败' : '已关闭');
      // 期望态由 peerVerifyToggle 写盘，这里同步内存值（开关返回即真相）
      if (!v || r.ok) _expectedOn = v;
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
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
        child: Column(children: [
          SwitchListTile(
            secondary: const Text('📍', style: TextStyle(fontSize: 22)),
            title: const Text('位置共享（定位验证包）'),
            subtitle: Text(
                _on
                    ? '开启中 · 数据仅存自家 NAS · 轨迹保留 15 天'
                    : '第 0 步真机验证 · 原生 LocationManager 三 provider · 25m 位移/5min 心跳',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.outline)),
            value: _on,
            onChanged: _busy ? null : _toggle,
          ),
          if (_summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(_summary,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.outline)),
            ),
          // 常驻失败原因行（细分引导：缺前台/缺后台文案由原生区分）
          if (_reason.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('⚠ $_reason',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.error)),
            ),
          // fix6 A1：期望开而实态停（进程被系统结束）→ 黄色提示 + 一键恢复。
          // 只提示、不自动开启：恢复必须由用户点击（采集启动仍是显式动作）。
          if (_expectedOn && !_on)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.amber.withValues(alpha: 0.6)),
              ),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  const Text('⚠ 已停止（进程被系统结束），点击恢复',
                      style: TextStyle(fontSize: 12, color: Colors.amber)),
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
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(
                          color: _batteryIgnored == false
                              ? Colors.amber
                              : cs.outline),
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
            label: const Text('导出 peer-loc-fatal 日志'),
          ),
          const SizedBox(height: 4),
        ]),
      ),
    );
  }
}
