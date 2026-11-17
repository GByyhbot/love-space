/// 设置主页（2.4.0 设置搬家 + 入口拆分段）：整体接替退役的全量
/// /settings 长页。本页**只做分组索引，不放任何设置内容本体**——
/// 九行落点 + 页脚「关于」（版本号 + 检查更新，原全量页「关于」节搬入）。
///
/// 路由沿用 `/settings`（旧长页退役，路径语义无缝接管）：
/// · 外观组：空间信息（弹窗，沿 spaceEditRequestedProvider 机制）/
///   主题与外观 / 主页背景 / 聊天背景 / 聊天气泡（后四张独立页）；
/// · 连接与提醒组：提醒设置（→ /channels）/ 线路与连接（独立页）；
/// · 数据与账号组：数据导出（独立页）/ 备份与存储（→ /backups，admin
///   门控沿用 main.dart redirect）/ 邀请另一半入住（→ /settings/invite）。
/// 页头文案「设置 / 管理空间、账号和数据。」（沿用原页副题逐字）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/config.dart';
import '../../core/theme/tokens.dart';
import '../chat/chat_toast.dart' show chatToastProvider;
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
              onTap: () {
                // 沿用原机制：设标志位回首页触发 hero 编辑弹窗（弹窗本体
                // 挂在首页 hero，双端同步写回）。
                ref.read(spaceEditRequestedProvider.notifier).state = true;
                context.go('/home');
              },
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
          title: Text(title),
          subtitle: Text(subtitle,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline)),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      );

  // ── 关于（原全量页 _aboutCard 原样搬入；app.js:2593-2612 / :2569） ──
  Widget _aboutCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = _status;
    final updateTarget = s?.apkVersion ?? '';
    final notes = s?.apkNotes ?? '';
    final hasUpdate = s != null &&
        s.apkVersion.isNotEmpty &&
        _pkgVersion.isNotEmpty &&
        newerVer(s.apkVersion, _pkgVersion);
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
            if (hasUpdate)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '可更新到 v$updateTarget',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.error),
                ),
              ),
            if (notes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '更新说明：$notes',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: cs.outline),
                ),
              ),
            if (!hasUpdate && s != null)
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
                OutlinedButton(
                  key: const Key('settings-check-update'),
                  onPressed: _checkUpdate,
                  child: const Text('检查更新'),
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
