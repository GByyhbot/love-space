/// 2.8.7 全量施工令 · 报备设置页（由 2.8.0 的四开关页演进）。
///
/// 照原型自上而下：完全关闭（危险区）→ 暂停 → 分档颗粒度 → 敏感软件过滤 →
/// 对方视角预览 → 双向审计。原四开关里 **events 保留为独立开关**（它管的是
/// 「能不能发报备」，不属于任何档位），其余三项并入档位，避免双入口双口径。
///
/// 🔴 提交纪律：policy 是事实源、四键是投影，每次改动都 `copyWith` 后**整对象
/// 提交**（后端 PUT 覆盖全部键）；失败立即回滚并 toast，不做本地假成功。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/peer/peer_locator.dart';
import '../../core/peer/peer_permissions.dart';
import '../../core/peer/peer_policy.dart';
import '../../core/peer/peer_report_api.dart';
import '../../core/peer/peer_report_queue.dart';
import '../../core/peer/peer_state_collector.dart';
import '../../core/theme/tokens.dart';
import '../../core/ui/error_view.dart';
import '../../core/ui/liquid_glass.dart';
import '../../core/ui/progress.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;

class PeerShareSettingsPage extends ConsumerStatefulWidget {
  const PeerShareSettingsPage({super.key});

  @override
  ConsumerState<PeerShareSettingsPage> createState() =>
      _PeerShareSettingsPageState();
}

class _PeerShareSettingsPageState extends ConsumerState<PeerShareSettingsPage>
    with WidgetsBindingObserver {
  PeerShareSettings? _settings;
  List<PeerPolicyAuditItem> _audit = const [];
  String? _error;
  bool _saving = false;
  bool _running = false;
  PeerPermissionSnapshot _perms = PeerPermissionSnapshot.unavailable;
  PeerDiagnosticsSnapshot _diag = PeerDiagnosticsSnapshot.unavailable;
  int _outboxTelemetry = 0;
  bool _showAutoStartGuide = false;
  bool _diagRefreshing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(_load);
    Future.microtask(() => _refreshNativeAndDiag());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshNativeAndDiag(pullUsage: true));
    }
  }

  Future<void> _refreshNativeAndDiag({bool pullUsage = false}) async {
    if (pullUsage) {
      await pullUsageSamples();
    }
    final results = await Future.wait<Object?>([
      peerVerifyStatus(),
      peerPermissionStatus(),
      peerDiagnosticsStatus(),
    ]);
    if (!mounted) return;
    final status = (results[0] as Map?) ?? const {};
    setState(() {
      _running = status['running'] == true;
      _perms = results[1] as PeerPermissionSnapshot;
      _diag = results[2] as PeerDiagnosticsSnapshot;
    });
    unawaited(
      reportOutbox.telemetryCount().then((n) {
        if (mounted) setState(() => _outboxTelemetry = n);
      }).catchError((_) {}),
    );
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final dio = await ref.read(api.dioProvider.future);
      final s = await fetchPeerSettings(dio);
      List<PeerPolicyAuditItem> audit = const [];
      try {
        audit = await fetchPolicyAudit(dio);
      } catch (_) {
        // 审计拉不到只影响那一节，不让整页失败
      }
      final status = await peerVerifyStatus();
      if (!mounted) return;
      setState(() {
        _settings = s;
        _audit = audit;
        // 通道没注册/旧包时 status 可能为空表——按「未运行」展示，不让整页失败
        _running = status['running'] == true;
      });
      unawaited(syncStateCollection(eventsOn: s.events));
      unawaited(applyPeerPolicy(s.policy, force: true));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _settings = null;
        _error = api.errorDetail(e);
      });
    }
  }

  /// 统一提交出口：整对象提交 + 原生即时生效 + 失败回滚。
  Future<void> _save(PeerShareSettings next, {String? toast}) async {
    final current = _settings;
    if (current == null || _saving) return;
    setState(() {
      _saving = true;
      _settings = next;
    });
    try {
      final dio = await ref.read(api.dioProvider.future);
      final saved = await updatePeerSettings(dio, next);
      if (!mounted) return;
      setState(() => _settings = saved);
      unawaited(syncStateCollection(eventsOn: saved.events));
      unawaited(applyPeerPolicy(saved.policy, force: true));
      ref
          .read(chatToastProvider.notifier)
          .show(toast ?? '已生效（对方立刻看到）', tone: ChatToastTone.success);
      unawaited(_refreshNativeAndDiag());
      // 审计流水刷新（本次变更已落服务端）
      try {
        final audit = await fetchPolicyAudit(dio);
        if (mounted) setState(() => _audit = audit);
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      setState(() => _settings = current);
      ref
          .read(chatToastProvider.notifier)
          .show('未保存：${api.errorDetail(e)}', tone: ChatToastTone.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _applyPolicy(PeerPolicy next, {String? toast}) async {
    final s = _settings;
    if (s == null) return;
    await _save(s.copyWith(policy: next), toast: toast);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final s = _settings;
    return Scaffold(
      appBar: AppBar(title: const Text('报备设置')),
      body: SafeArea(
        child: s == null
            ? (_error != null
                ? AppErrorView(detail: _error!, onRetry: _load)
                : const AppProgress())
            : ListView(
                key: const Key('peer-share-scroll'),
                padding:
                    const EdgeInsets.fromLTRB(16, 12, 16, Spacing.pageBottom),
                children: [
                  _statusStrip(theme, cs, s),
                  const SizedBox(height: Spacing.gap),
                  _permissionCenter(theme, cs),
                  const SizedBox(height: Spacing.gap),
                  _dangerZone(theme, cs, s),
                  const SizedBox(height: Spacing.gap),
                  _pauseZone(theme, cs, s),
                  const SizedBox(height: Spacing.gap),
                  _levels(theme, cs, s),
                  const SizedBox(height: Spacing.gap),
                  _extras(theme, cs, s),
                  const SizedBox(height: Spacing.gap),
                  _entries(theme, cs),
                  const SizedBox(height: Spacing.gap),
                  _auditSection(theme, cs),
                  const SizedBox(height: Spacing.gap),
                  _diagnosticsSection(theme, cs),
                  if (_saving)
                    Padding(
                      padding: const EdgeInsets.only(top: Spacing.gap),
                      child: Text('保存中…',
                          key: const Key('peer-share-saving'),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: cs.outline)),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _statusStrip(ThemeData theme, ColorScheme cs, PeerShareSettings s) {
    final p = s.policy;
    final String line;
    if (p.globalOff) {
      line = '已完全关闭报备 · 对方看不到任何数据';
    } else if (p.isPaused) {
      line = '已暂停至 ${_fmt(p.pausedUntil)}';
    } else if (!_running) {
      line = '采集未运行 · 重新打开 App 或检查定位权限';
    } else {
      line = '采集中 · 对方能看到你共享的内容';
    }
    return Container(
      key: const Key('peer-share-status'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: (p.isHalted ? cs.errorContainer : cs.primaryContainer)
            .withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(kGlassInnerRadius),
        border: Border.all(
          color: (p.isHalted ? cs.error : cs.primary).withValues(alpha: 0.35),
        ),
      ),
      child: Row(children: [
        Icon(
          p.isHalted
              ? Icons.pause_circle_outline
              : (_running ? Icons.check_circle_outline : Icons.info_outline),
          size: 16,
          color: p.isHalted ? cs.error : cs.primary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            line,
            style: tabularStyle(
              theme.textTheme.bodySmall?.copyWith(
                color: p.isHalted ? cs.error : cs.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _dangerZone(ThemeData theme, ColorScheme cs, PeerShareSettings s) {
    final off = s.policy.globalOff;
    return LiquidGlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      tint: cs.errorContainer.withValues(alpha: 0.24),
      borderColor: cs.error.withValues(alpha: 0.30),
      child: ListTile(
        key: const Key('peer-share-off'),
        leading: Icon(off ? Icons.lock : Icons.lock_open, color: cs.error),
        title: Text(
          off ? '完全关闭报备（已开启）' : '完全关闭报备',
          style: theme.textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        subtitle: Text('一停全停：定位、状态、使用、网络、电量都不再上报；对方立刻看到关闭态',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
        trailing: Switch(
          value: off,
          onChanged: _saving ? null : (v) => _confirmOff(v),
        ),
      ),
    );
  }

  Future<void> _confirmOff(bool next) async {
    if (!next) {
      await _applyPolicy(_settings!.policy.copyWith(globalOff: false),
          toast: '已恢复报备');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('完全关闭报备？'),
        content: const Text('关闭后对方立刻看不到你的任何数据（包括位置、电量、使用）。'
            '随时可以在这里恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            key: const Key('peer-share-off-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认关闭'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _applyPolicy(
      _settings!.policy.copyWith(globalOff: true, pausedUntil: null),
      toast: '已完全关闭报备',
    );
  }

  Widget _pauseZone(ThemeData theme, ColorScheme cs, PeerShareSettings s) {
    final p = s.policy;
    final now = DateTime.now();
    return LiquidGlassCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('暂停报备',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(
          p.isPaused
              ? '当前暂停至 ${_fmt(p.pausedUntil)}，恢复后中间这段不补报'
              : '暂停期间不采集、不上报；恢复后不补报这段',
          style: tabularStyle(
            theme.textTheme.bodySmall?.copyWith(color: cs.outline),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.tonal(
            key: const Key('peer-share-pause-2h'),
            onPressed: p.globalOff || _saving
                ? null
                : () => _applyPolicy(
                      p.copyWith(pausedUntil: pauseUntilHours(now, 2)),
                      toast: '已暂停 2 小时',
                    ),
            child: const Text('暂停 2 小时'),
          ),
          FilledButton.tonal(
            key: const Key('peer-share-pause-morning'),
            onPressed: p.globalOff || _saving
                ? null
                : () => _applyPolicy(
                      p.copyWith(pausedUntil: pauseUntilNextMorning(now)),
                      toast: '已暂停到明早 8 点',
                    ),
            child: const Text('暂停到明早 8 点'),
          ),
          if (p.isPaused)
            OutlinedButton(
              key: const Key('peer-share-resume'),
              onPressed: _saving
                  ? null
                  : () => _applyPolicy(p.copyWith(pausedUntil: null),
                      toast: '已恢复报备'),
              child: const Text('恢复'),
            ),
        ]),
      ]),
    );
  }

  Future<bool> _maybePromptMissingPerm({
    required String title,
    required String reason,
    required Future<void> Function() onAuthorize,
  }) async {
    final goSave = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final cs = theme.colorScheme;
        return SafeArea(
          child: Padding(
            key: const Key('peer-jit-perm-sheet'),
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(reason,
                    style:
                        theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('peer-jit-save-anyway'),
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('仍先保存'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const Key('peer-jit-authorize'),
                      onPressed: () async {
                        Navigator.of(ctx).pop(false);
                        await onAuthorize();
                        await _refreshNativeAndDiag();
                      },
                      child: const Text('去授权'),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        );
      },
    );
    return goSave == true;
  }

  Future<void> _onPickLocLevel(PeerPolicy p, LocLevel v) async {
    if (v == p.locLevel) return;
    final raising = v.index < p.locLevel.index; // exact(0) < street(1) < off(2)
    if (raising && _perms.channelAvailable && (!_perms.fine || !_perms.background)) {
      final missingBg = _perms.fine && !_perms.background;
      final proceed = await _maybePromptMissingPerm(
        title: missingBg ? '缺少后台定位权限' : '缺少精确定位权限',
        reason: missingBg
            ? '仅授予「使用期间」定位时，息屏或切后台后无法持续上报位置。'
            : '开启位置共享需要系统授予精确定位权限，否则对方看不到实时位置。',
        onAuthorize: () async {
          final ok = await peerRequestLocationPermission(
            background: missingBg,
          );
          if (!ok) await peerOpenAppSettings();
        },
      );
      if (!proceed || !mounted) return;
    }
    await _applyPolicy(p.copyWith(locLevel: v),
        toast: '位置与轨迹已调为${v.label}');
  }

  Future<void> _onPickUsageLevel(PeerPolicy p, UsageLevel v) async {
    if (v == p.usageLevel) return;
    final raising = v.index < p.usageLevel.index; // full(0) < screenOnly(1) < off(2)
    if (raising && _perms.channelAvailable && !_perms.usage) {
      final proceed = await _maybePromptMissingPerm(
        title: '缺少「使用情况访问权限」',
        reason: '统计每日亮屏时长与解锁记录需要在系统设置允许本应用访问使用情况。',
        onAuthorize: openUsageAccessSettings,
      );
      if (!proceed || !mounted) return;
    }
    await _applyPolicy(p.copyWith(usageLevel: v),
        toast: '手机使用已调为${v.label}');
  }

  Future<void> _onPickAppLevel(PeerPolicy p, AppLevel v) async {
    if (v == p.appLevel) return;
    final raising = v.index < p.appLevel.index; // stream(0) < top5(1) < off(2)
    if (raising && _perms.channelAvailable && !_perms.usage) {
      final proceed = await _maybePromptMissingPerm(
        title: '缺少「使用情况访问权限」',
        reason: '查看正在使用的应用或 Top5 排行需要先授予系统使用情况访问权限。',
        onAuthorize: openUsageAccessSettings,
      );
      if (!proceed || !mounted) return;
    }
    await _applyPolicy(p.copyWith(appLevel: v),
        toast: '软件记录已调为${v.label}');
  }

  Widget _levels(ThemeData theme, ColorScheme cs, PeerShareSettings s) {
    final p = s.policy;
    return LiquidGlassCard(
      padding: EdgeInsets.zero,
      child: Column(children: [
        _levelGroup<LocLevel>(
          theme,
          cs,
          key: 'location',
          title: '位置与轨迹',
          desc: '精确轨迹 / 仅街区（≈500m 网格）/ 关闭',
          value: p.locLevel,
          values: LocLevel.values,
          label: (v) => v.label,
          onPick: (v) => _onPickLocLevel(p, v),
        ),
        Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.45)),
        _levelGroup<UsageLevel>(
          theme,
          cs,
          key: 'usage',
          title: '手机使用情况',
          desc: '时长+分布 / 仅亮灭屏 / 关闭',
          value: p.usageLevel,
          values: UsageLevel.values,
          label: (v) => v.label,
          onPick: (v) => _onPickUsageLevel(p, v),
        ),
        Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.45)),
        _levelGroup<AppLevel>(
          theme,
          cs,
          key: 'app',
          title: '软件打开记录',
          desc: '精确时间流 / 仅 Top5 / 关闭',
          value: p.appLevel,
          values: AppLevel.values,
          label: (v) => v.label,
          onPick: (v) => _onPickAppLevel(p, v),
        ),
        Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.45)),
        _levelGroup<NetLevel>(
          theme,
          cs,
          key: 'net',
          title: '网络与 Wi-Fi',
          desc: '显示 SSID / 仅网络类型 / 关闭',
          value: p.netLevel,
          values: NetLevel.values,
          label: (v) => v.label,
          onPick: (v) => _applyPolicy(p.copyWith(netLevel: v),
              toast: '网络共享已调为${v.label}'),
        ),
      ]),
    );
  }

  Widget _levelGroup<T>(
    ThemeData theme,
    ColorScheme cs, {
    required String key,
    required String title,
    required String desc,
    required T value,
    required List<T> values,
    required String Function(T) label,
    required void Function(T) onPick,
  }) {
    final dark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(desc,
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: dark ? 0.5 : 0.7),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: dark ? 0.45 : 0.6),
            ),
          ),
          child: Row(
            children: [
              for (final v in values)
                Expanded(
                  child: ChoiceChip(
                    key: Key('peer-level-$key-${_wire(v)}'),
                    showCheckmark: false,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    side: BorderSide.none,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(11),
                    ),
                    backgroundColor: Colors.transparent,
                    selectedColor: _wire(v) == 'off'
                        ? cs.errorContainer.withValues(alpha: 0.72)
                        : (dark ? cs.primaryContainer : cs.surface),
                    label: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          label(v),
                          maxLines: 1,
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight:
                                v == value ? FontWeight.w700 : FontWeight.w500,
                            color: v == value
                                ? (_wire(v) == 'off'
                                    ? cs.error
                                    : (dark
                                        ? cs.onPrimaryContainer
                                        : cs.onSurface))
                                : cs.outline,
                          ),
                        ),
                      ),
                    ),
                    selected: v == value,
                    onSelected: _saving ? null : (_) => onPick(v),
                  ),
                ),
            ],
          ),
        ),
      ]),
    );
  }

  String _wire<T>(T v) {
    if (v is LocLevel) return v.wire;
    if (v is UsageLevel) return v.wire;
    if (v is AppLevel) return v.wire;
    if (v is NetLevel) return v.wire;
    return v.toString();
  }

  Widget _extras(ThemeData theme, ColorScheme cs, PeerShareSettings s) {
    final p = s.policy;
    return LiquidGlassCard(
      padding: EdgeInsets.zero,
      child: Column(children: [
        SwitchListTile(
          key: const Key('peer-share-events'),
          title: const Text('报备与事件共享'),
          subtitle: const Text('关闭后无法发报备（对方会明确看到已关闭）'),
          value: s.events,
          onChanged: _saving
              ? null
              : (v) => _save(s.copyWith(events: v),
                  toast: v ? '已开启报备共享' : '已关闭报备共享'),
        ),
        Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.45)),
        SwitchListTile(
          key: const Key('peer-share-battery'),
          title: const Text('电量与充电'),
          subtitle: const Text('关闭后对方看不到电量，低电提醒也一起停'),
          value: p.battery,
          onChanged: _saving
              ? null
              : (v) => _applyPolicy(p.copyWith(battery: v),
                  toast: v ? '已开启电量共享' : '已关闭电量共享'),
        ),
        Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.45)),
        SwitchListTile(
          key: const Key('peer-share-battery-alert'),
          title: const Text('低电量提醒'),
          subtitle: const Text('跌破 20% 时提醒对方一次（充电中不算）'),
          value: p.batteryAlert,
          onChanged: (!p.battery || _saving)
              ? null
              : (v) => _applyPolicy(p.copyWith(batteryAlert: v),
                  toast: v ? '已开启低电量提醒' : '已关闭低电量提醒'),
        ),
        Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.45)),
        SwitchListTile(
          key: const Key('peer-share-fold'),
          title: const Text('折叠短暂切换'),
          subtitle: const Text('不足 10 秒的应用切换不记录'),
          value: p.foldShort,
          onChanged: _saving
              ? null
              : (v) => _applyPolicy(p.copyWith(foldShort: v)),
        ),
      ]),
    );
  }

  Widget _entries(ThemeData theme, ColorScheme cs) => LiquidGlassCard(
        padding: EdgeInsets.zero,
        child: Column(children: [
          ListTile(
            key: const Key('peer-share-sensitive'),
            leading: const Icon(Icons.visibility_off_outlined),
            title: const Text('敏感软件过滤'),
            subtitle: Text(
              '已勾选 ${_settings?.policy.sensitivePkgs.length ?? 0} 个 · '
              '在对方那边只显示「其他应用」',
              style: tabularStyle(
                theme.textTheme.bodySmall?.copyWith(color: cs.outline),
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/peer-share/sensitive'),
          ),
          Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.45)),
          ListTile(
            key: const Key('peer-share-preview'),
            leading: const Icon(Icons.remove_red_eye_outlined),
            title: const Text('对方视角预览'),
            subtitle: const Text('看看对方现在看到的你的样子'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/peer-share/preview'),
          ),
        ]),
      );

  Widget _auditSection(ThemeData theme, ColorScheme cs) => LiquidGlassCard(
        key: const Key('peer-share-audit'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('变更记录（双方可见，不可删除）',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (_audit.isEmpty)
            Text('还没有调整记录',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline))
          else
            for (final a in _audit.take(20))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 90,
                      child: Text(
                        _fmt(a.ts),
                        style: tabularStyle(
                          theme.textTheme.bodySmall
                              ?.copyWith(color: cs.outline),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text('${a.mine ? '我' : 'TA'} ${a.detail}',
                          style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
        ]),
      );

  String _fmt(double? ts) {
    if (ts == null || ts <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  String _fmtMs(int? ms) {
    if (ms == null || ms <= 0) return '无';
    return _fmtDateTime(DateTime.fromMillisecondsSinceEpoch(ms));
  }

  String _fmtDateTime(DateTime? d) {
    if (d == null) return '无';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  Widget _permissionCenter(ThemeData theme, ColorScheme cs) {
    final readyCount = [
      _perms.usage,
      _perms.fine,
      _perms.background,
      _perms.notification,
      _perms.batteryIgnored,
    ].where((e) => e).length;
    final summaryText =
        _perms.channelAvailable ? '$readyCount/5 已就绪' : '原生通道未连接';
    return LiquidGlassCard(
      key: const Key('peer-perm-center'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(
            '权限与采集状态',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          Text(
            summaryText,
            style: tabularStyle(
              theme.textTheme.labelMedium?.copyWith(
                color: !_perms.channelAvailable
                    ? cs.outline
                    : (_perms.allGranted ? cs.primary : cs.error),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ]),
        if (_perms.channelAvailable) ...[
          const SizedBox(height: 6),
          _permRow(
            theme,
            cs,
            rowKey: const Key('peer-perm-usage'),
            btnKey: const Key('peer-perm-usage-btn'),
            title: '应用使用情况访问',
            desc: '统计亮屏时长与正在使用的应用',
            granted: _perms.usage,
            onGrant: () async {
              await openUsageAccessSettings();
              await _refreshNativeAndDiag(pullUsage: true);
            },
          ),
          _permDivider(cs),
          _permRow(
            theme,
            cs,
            rowKey: const Key('peer-perm-fine'),
            btnKey: const Key('peer-perm-fine-btn'),
            title: '精确定位',
            desc: '采集最新位置与 Wi-Fi SSID',
            granted: _perms.fine,
            onGrant: () async {
              final ok = await peerRequestLocationPermission(background: false);
              if (!ok) await peerOpenAppSettings();
              await _refreshNativeAndDiag();
            },
          ),
          _permDivider(cs),
          _permRow(
            theme,
            cs,
            rowKey: const Key('peer-perm-bg'),
            btnKey: const Key('peer-perm-bg-btn'),
            title: '后台始终定位',
            desc: '息屏或切后台后持续更新足迹',
            granted: _perms.background,
            grantedLabel:
                _perms.background ? '已开启' : (_perms.fine ? '仅前台' : '未开启'),
            onGrant: () async {
              final ok = await peerRequestLocationPermission(
                background: _perms.fine,
              );
              if (!ok) await peerOpenAppSettings();
              await _refreshNativeAndDiag();
            },
          ),
          _permDivider(cs),
          _permRow(
            theme,
            cs,
            rowKey: const Key('peer-perm-notify'),
            btnKey: const Key('peer-perm-notify-btn'),
            title: '系统通知',
            desc: '保证前台保活常驻通知与重要提醒送达',
            granted: _perms.notification,
            onGrant: () async {
              await peerRequestNotificationPermission();
              await _refreshNativeAndDiag();
            },
          ),
          _permDivider(cs),
          _permRow(
            theme,
            cs,
            rowKey: const Key('peer-perm-battery'),
            btnKey: const Key('peer-perm-battery-btn'),
            title: '忽略电池优化',
            desc: '避免系统 Doze 限制定时心跳与使用采样',
            granted: _perms.batteryIgnored,
            grantedLabel: _perms.batteryIgnored ? '已豁免' : '未豁免',
            onGrant: () async {
              await peerRequestIgnoreBatterySetting();
              await _refreshNativeAndDiag();
            },
          ),
          _permDivider(cs),
          Padding(
            key: const Key('peer-perm-autostart'),
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('厂商自启动 / 后台保护',
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text('系统后台查杀白名单（部分机型需手动开启）',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: cs.outline)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    key: const Key('peer-perm-autostart-btn'),
                    onPressed: () async {
                      final opened = await peerOpenAutoStartSettings();
                      if (!opened && mounted) {
                        setState(() => _showAutoStartGuide = true);
                      }
                    },
                    child: Text(_perms.autoStartIntentSupported ? '去开启' : '查看指引'),
                  ),
                ]),
                if (_showAutoStartGuide ||
                    (_perms.channelAvailable &&
                        !_perms.autoStartIntentSupported))
                  Padding(
                    key: const Key('peer-perm-autostart-guide'),
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      autoStartGuideForManufacturer(_perms.manufacturer),
                      style:
                          theme.textTheme.bodySmall?.copyWith(color: cs.outline),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ]),
    );
  }

  Widget _permDivider(ColorScheme cs) => Divider(
        height: 1,
        color: cs.outlineVariant.withValues(alpha: 0.4),
      );

  Widget _permRow(
    ThemeData theme,
    ColorScheme cs, {
    required Key rowKey,
    required Key btnKey,
    required String title,
    required String desc,
    required bool granted,
    String? grantedLabel,
    required VoidCallback onGrant,
  }) {
    final badgeText = grantedLabel ?? (granted ? '已开启' : '未开启');
    return Padding(
      key: rowKey,
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(
                    title,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: (granted
                            ? cs.primaryContainer
                            : cs.errorContainer)
                        .withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    badgeText,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: granted ? cs.onPrimaryContainer : cs.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ]),
              if (!granted) ...[
                const SizedBox(height: 2),
                Text(desc,
                    style:
                        theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
              ],
            ],
          ),
        ),
        if (!granted) ...[
          const SizedBox(width: 8),
          FilledButton.tonal(
            key: btnKey,
            onPressed: onGrant,
            child: const Text('去授权'),
          ),
        ],
      ]),
    );
  }

  Future<void> _runDiagnosticPull() async {
    if (_diagRefreshing) return;
    setState(() => _diagRefreshing = true);
    try {
      final n = await pullUsageSamples();
      final dio = await ref.read(api.dioProvider.future);
      final flushRes = await reportOutbox.flush(dio);
      await _refreshNativeAndDiag(pullUsage: false);
      if (!mounted) return;
      ref.read(chatToastProvider.notifier).show(
            '自检完成 · 拉取 $n 条，补传 ${flushRes.sent} 条',
            tone: ChatToastTone.success,
          );
    } catch (e) {
      if (!mounted) return;
      ref.read(chatToastProvider.notifier).show(
            '自检拉取失败：${api.errorDetail(e)}',
            tone: ChatToastTone.error,
          );
    } finally {
      if (mounted) setState(() => _diagRefreshing = false);
    }
  }

  Widget _diagnosticsSection(ThemeData theme, ColorScheme cs) => LiquidGlassCard(
        key: const Key('peer-diagnostics-card'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('采集自检',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            FilledButton.tonal(
              key: const Key('peer-diag-refresh'),
              onPressed: _diagRefreshing ? null : _runDiagnosticPull,
              child: Text(_diagRefreshing ? '拉取中…' : '立即自检拉取'),
            ),
          ]),
          const SizedBox(height: 8),
          _diagRow(
            theme,
            cs,
            '定位采集',
            _diag.channelAvailable
                ? '${_diag.locRunning ? '运行中' : '未运行'} · 收点 ${_diag.locReceived} · 已报 ${_diag.locReported} · 队列 ${_diag.locQueue}'
                : '原生通道未连接',
          ),
          _diagRow(
            theme,
            cs,
            '最近定位/冲刷',
            '${_fmtMs(_diag.lastReceivedAtMs)} / ${_fmtMs(_diag.lastFlushAtMs)}',
          ),
          _diagRow(
            theme,
            cs,
            '设备状态采集',
            '${_diag.stateEnabled ? '运行中' : '已停'} · 已投递 ${_diag.stateEmitted} 条 · 最近 ${_fmtMs(_diag.lastStateEmitAtMs)}',
          ),
          _diagRow(
            theme,
            cs,
            '使用统计采集',
            '${_diag.usageEnabled ? '运行中' : '已停'}（权限${_diag.usageGranted ? '已授' : '未授'}）· 已投递 ${_diag.usageEmitted} 条 · 游标 ${_fmtMs(_diag.usageCursorMs)}',
          ),
          _diagRow(
            theme,
            cs,
            '最近拉取/投递',
            '拉 ${_fmtMs(_diag.lastUsagePullAtMs)}（原始 ${_diag.lastUsageRawCount} 条）· 投 ${_fmtMs(_diag.lastUsageEmitAtMs)}',
          ),
          _diagRow(
            theme,
            cs,
            '端侧遥测队列',
            '待发 $_outboxTelemetry 条 · 最近冲刷 ${_fmtDateTime(reportOutbox.lastFlushedAt)}',
          ),
          _diagRow(
            theme,
            cs,
            '当前策略摘要',
            _diag.policySummary.isEmpty ? '尚未下发' : _diag.policySummary,
          ),
          if (_diag.locError != null)
            _diagRow(theme, cs, '最近错误', _diag.locError!, warn: true),
        ]),
      );

  Widget _diagRow(ThemeData theme, ColorScheme cs, String label, String value,
          {bool warn = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 96,
            child: Text(label,
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
          ),
          Expanded(
            child: Text(
              value,
              style: tabularStyle(
                theme.textTheme.bodySmall?.copyWith(
                  color: warn ? cs.error : cs.onSurface,
                ),
              ),
            ),
          ),
        ]),
      );
}
