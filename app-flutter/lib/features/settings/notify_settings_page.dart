/// 2.4.5 乙组第 3 项 · 设置页「消息通知」独立页。
///
/// 落点：设置主页「连接与提醒」组内「消息通知」行 → 本页（独立页与既有
/// 六张二级页同构；未并入 /settings/links 理由：线路页聚焦链路检测/切线，
/// 本页聚焦通知权限/服务/渠道全链路验证，职责不同）。
///
/// 页内（提示词第 3 项 1）：
/// · 通知权限状态：已授权/未授权；未授权一键申请/跳系统设置；
/// · 消息接收服务状态：运行中/未运行；未运行「重新开启」直接拉起；
/// · 「发送测试通知」：立即弹一条本地测试通知（love_messages 渠道，
///   当场验证「权限+渠道+声音」全链路）；
/// · 放行引导入口（小米三步 sheet）。
///
/// 小米放行三步（提示词第 3 项 2）：①自启动 ②电池策略 ③最近任务锁定。
/// 🔴 诚实边界：菜单名与操作路径**未经 HyperOS 真机实地核对**（开发机无
/// 小米设备）——文案按 Android 公共 API 与 HyperOS 公开常识给出占位，每步
/// 可一键跳转的系统页都直跳（电池优化页有公共 API 直达；自启动/最近任务
/// 无公共 API → 跳应用信息页并在图示标出要点项）；**菜单名定稿必须等 yang
/// 真机核对后补独立小提交**，摘要如实注明。触发时机：通知授权成功后弹一次
/// （shared_preferences 已引导标记，不重复弹；页内随时可重看）。
///
/// 与既有外部渠道的关系（提示词第 3 项 3）：Bark/ntfy/企业微信原样不动，
/// 本页文案不引导关掉它们（信息卡明示两条腿并行）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/notify/local_notifications.dart';
import '../../core/notify/notify_decision.dart' show NotifyItem, kChannelMessages;
import '../../core/notify/notify_task.dart' show startNotifyTask;
import '../../core/theme/tokens.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../notify/notify_widgets.dart' show NotifyInfoCard;

const String kPrefNotifyGuideShown = 'notify_guide_shown';

/// 状态查询注入点（测试 stub 用）
Future<bool> Function()? queryPermissionEnabled;
Future<bool> Function()? queryServiceRunning;

Future<bool> _defaultPermission() => areNotificationsEnabled();

Future<bool> _defaultServiceRunning() async {
  try {
    return await FlutterForegroundTask.isRunningService;
  } catch (_) {
    return false;
  }
}

/// 授权成功后弹一次引导（shell/设置页调用；已弹过/跳过不再弹）
Future<void> maybeShowNotifyGuide(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(kPrefNotifyGuideShown) == true) return;
  await prefs.setBool(kPrefNotifyGuideShown, true);
  if (!context.mounted) return;
  await showXiaomiGuideSheet(context);
}

class NotifySettingsPage extends ConsumerStatefulWidget {
  const NotifySettingsPage({super.key});

  @override
  ConsumerState<NotifySettingsPage> createState() => _NotifySettingsPageState();
}

class _NotifySettingsPageState extends ConsumerState<NotifySettingsPage> {
  bool? _permission;
  bool? _serviceRunning;
  bool _busy = false;

  void _toast(String text, {ChatToastTone tone = ChatToastTone.info}) {
    ref.read(chatToastProvider.notifier).show(text, tone: tone);
  }

  Future<void> _load() async {
    final perm = (queryPermissionEnabled ?? _defaultPermission)();
    final svc = (queryServiceRunning ?? _defaultServiceRunning)();
    final r = await Future.wait<bool>([perm, svc]);
    if (!mounted) return;
    setState(() {
      _permission = r[0];
      _serviceRunning = r[1];
    });
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  /// 权限：未授权 → 一键申请；被系统判永久拒绝（返回仍 false 且再点）→
  /// 跳应用信息页（每步能直达的直达，直达不了的跳应用信息页并标要点）。
  Future<void> _togglePermission() async {
    setState(() => _busy = true);
    try {
      final granted = await requestNotificationPermission();
      if (!mounted) return;
      setState(() => _permission = granted);
      if (granted) {
        _toast('通知权限已开启', tone: ChatToastTone.success);
        // 提示词第 3 项 2：首次开启通知（授权成功）后主动弹一次引导（可跳过）
        await maybeShowNotifyGuide(context);
      } else {
        _toast('未获得授权，可到系统设置里手动开启');
        await _openAppDetails();
      }
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openAppDetails() async {
    try {
      final pkg = const String.fromEnvironment('LOVE_APP_ID',
          defaultValue: 'cn.iepose.lovespace.love_space');
      await launchUrl(Uri.parse('package:$pkg'),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      _toast('请在系统设置中找到「恋爱空间」');
    }
  }

  /// 服务未运行 → 重新开启（拉起服务；配置注入由 shell 的 enterShell 负责，
  /// 这里走 restart 刷新；点了必有明确反馈，不许没反应）
  Future<void> _restartService() async {
    setState(() => _busy = true);
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.restartService();
        if (!mounted) return;
        _toast('消息接收服务已重启', tone: ChatToastTone.success);
      } else {
        await FlutterForegroundTask.startService(
          serviceId: 256,
          notificationTitle: '恋爱空间',
          notificationText: '消息接收中',
          callback: startNotifyTask,
        );
        if (!mounted) return;
        _toast('消息接收服务已开启', tone: ChatToastTone.success);
      }
      await _load();
    } catch (e) {
      if (mounted) _toast('开启失败：${api.errorDetail(e)}', tone: ChatToastTone.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 发送测试通知：立即弹一条本地测试通知（love_messages 渠道，验证
  /// 「权限 + 渠道 + 声音」全链路）
  Future<void> _sendTestNotification() async {
    await showNotifyItem(const NotifyItem(
      key: 'chat:test-notification',
      androidId: 190245001,
      channelId: kChannelMessages,
      title: '恋爱空间 · 测试通知',
      body: '能看到这条，说明通知权限、渠道与声音都通了。',
      route: '',
      clearChatOnTap: false,
    ));
    if (mounted) {
      _toast('测试通知已发出，请查看系统通知栏', tone: ChatToastTone.success);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      // automaticallyImplyLeading 不关：返回按钮 + 系统手势都能回上一页
      appBar: AppBar(title: const Text('消息通知')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, Spacing.pageBottom),
          children: <Widget>[
            const NotifyInfoCard(
              title: 'App 在后台也能第一时间收到 TA 的消息',
              subtitle: '开启通知权限并放行后台运行即可；服务器侧的第三方渠道'
                  '（Bark / 企业微信等）原样可用，两条腿并行，互不影响。',
              lines: <String>[],
            ),
            const SizedBox(height: 12),
            _row(
              key: const Key('notify-perm-row'),
              icon: Icons.notifications_active_rounded,
              title: '通知权限',
              subtitle: _permission == null
                  ? '检测中…'
                  : (_permission! ? '已授权' : '未授权'),
              trailing: (_permission == false)
                  ? TextButton(
                      onPressed: _busy ? null : _togglePermission,
                      child: const Text('去开启'),
                    )
                  : null,
            ),
            _row(
              key: const Key('notify-service-row'),
              icon: Icons.sync_rounded,
              title: '消息接收服务',
              subtitle: _serviceRunning == null
                  ? '检测中…'
                  : (_serviceRunning! ? '运行中' : '未运行'),
              trailing: (_serviceRunning == false)
                  ? TextButton(
                      key: const Key('notify-service-restart'),
                      onPressed: _busy ? null : _restartService,
                      child: const Text('重新开启'),
                    )
                  : null,
            ),
            _row(
              key: const Key('notify-test-row'),
              icon: Icons.notifications_rounded,
              title: '发送测试通知',
              subtitle: '当场验证「权限 + 渠道 + 声音」全链路',
              onTap: _sendTestNotification,
            ),
            _row(
              key: const Key('notify-guide-row'),
              icon: Icons.shield_rounded,
              title: '小米手机放行引导',
              subtitle: '自启动 · 电池策略 · 最近任务上锁',
              onTap: () => showXiaomiGuideSheet(context),
            ),
            const SizedBox(height: 12),
            Text(
              '提示：小米 HyperOS 的省电策略较强，放行三步做完是后台收通知'
              '的前提；若极端省电下仍收不到，属系统限制。',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row({
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        key: key,
        leading: Icon(icon, size: 22),
        title: Text(title),
        subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        trailing: trailing ??
            (onTap != null ? const Icon(Icons.chevron_right, size: 20) : null),
        onTap: onTap,
      ),
    );
  }
}

/// 小米放行三步 sheet（图文分步；每步一键跳转能直达的系统页）。
Future<void> showXiaomiGuideSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: Colors.black54,
    backgroundColor: Colors.transparent,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg))),
    builder: (_) => const _XiaomiGuideSheet(),
  );
}

class _XiaomiGuideSheet extends StatelessWidget {
  const _XiaomiGuideSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 16, 20, 16 + MediaQuery.of(context).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text('小米手机放行三步', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '（菜单名以真机为准，不同 HyperOS 版本措辞或有差异）',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
          ),
          const SizedBox(height: 12),
          _step(
            context,
            '① 自启动',
            '系统设置 → 应用设置 → 应用管理 → 恋爱空间 → '
                '「自启动」开关打开。',
            () => _openAppDetails(context),
            '跳应用信息',
          ),
          _step(
            context,
            '② 电池策略',
            '在电池优化设置里把「恋爱空间」设为不优化'
                '（HyperOS 里对应「省电策略 → 无限制」）。',
            () => _openBattery(context),
            '跳电池设置',
          ),
          _step(
            context,
            '③ 最近任务上锁',
            '打开最近任务（多任务界面），找到恋爱空间卡片，'
                '下拉或长按（以真机为准）选中「锁定」，锁定的卡片不会被清理。',
            null,
            null,
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('notify-guide-done'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('我已完成这三步'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _step(BuildContext context, String title, String detail,
      VoidCallback? onJump, String? jumpLabel) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(detail, style: theme.textTheme.bodySmall),
            if (onJump != null && jumpLabel != null) ...<Widget>[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onJump,
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: Text(jumpLabel),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openAppDetails(BuildContext context) async {
    try {
      final pkg = const String.fromEnvironment('LOVE_APP_ID',
          defaultValue: 'cn.iepose.lovespace.love_space');
      await launchUrl(Uri.parse('package:$pkg'),
          mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _openBattery(BuildContext context) async {
    try {
      // 公共 API 直达电池优化白名单设置页（提示词：能直达的系统页直达）
      await FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
    } catch (_) {}
  }
}
