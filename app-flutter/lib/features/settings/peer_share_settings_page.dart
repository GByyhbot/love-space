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
import '../../core/peer/peer_policy.dart';
import '../../core/peer/peer_report_api.dart';
import '../../core/peer/peer_state_collector.dart';
import '../../core/theme/tokens.dart';
import '../../core/ui/error_view.dart';
import '../../core/ui/progress.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;

class PeerShareSettingsPage extends ConsumerStatefulWidget {
  const PeerShareSettingsPage({super.key});

  @override
  ConsumerState<PeerShareSettingsPage> createState() =>
      _PeerShareSettingsPageState();
}

class _PeerShareSettingsPageState extends ConsumerState<PeerShareSettingsPage> {
  PeerShareSettings? _settings;
  List<PeerPolicyAuditItem> _audit = const [];
  String? _error;
  bool _saving = false;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (p.isHalted ? cs.errorContainer : cs.secondaryContainer)
            .withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(line,
          style: theme.textTheme.bodySmall?.copyWith(
            color: p.isHalted ? cs.error : cs.onSurface,
          )),
    );
  }

  Widget _dangerZone(ThemeData theme, ColorScheme cs, PeerShareSettings s) {
    final off = s.policy.globalOff;
    return Card(
      color: cs.errorContainer.withValues(alpha: 0.25),
      child: ListTile(
        key: const Key('peer-share-off'),
        leading: Icon(off ? Icons.lock : Icons.lock_open, color: cs.error),
        title: Text(off ? '完全关闭报备（已开启）' : '完全关闭报备'),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('暂停报备',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(
            p.isPaused
                ? '当前暂停至 ${_fmt(p.pausedUntil)}，恢复后中间这段不补报'
                : '暂停期间不采集、不上报；恢复后不补报这段',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
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
      ),
    );
  }

  Widget _levels(ThemeData theme, ColorScheme cs, PeerShareSettings s) {
    final p = s.policy;
    return Card(
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
          onPick: (v) => _applyPolicy(p.copyWith(locLevel: v),
              toast: '位置与轨迹已调为${v.label}'),
        ),
        const Divider(height: 1),
        _levelGroup<UsageLevel>(
          theme,
          cs,
          key: 'usage',
          title: '手机使用情况',
          desc: '时长+分布 / 仅亮灭屏 / 关闭',
          value: p.usageLevel,
          values: UsageLevel.values,
          label: (v) => v.label,
          onPick: (v) => _applyPolicy(p.copyWith(usageLevel: v),
              toast: '手机使用已调为${v.label}'),
        ),
        const Divider(height: 1),
        _levelGroup<AppLevel>(
          theme,
          cs,
          key: 'app',
          title: '软件打开记录',
          desc: '精确时间流 / 仅 Top5 / 关闭',
          value: p.appLevel,
          values: AppLevel.values,
          label: (v) => v.label,
          onPick: (v) => _applyPolicy(p.copyWith(appLevel: v),
              toast: '软件记录已调为${v.label}'),
        ),
        const Divider(height: 1),
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
  }) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          Text(desc,
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final v in values)
              ChoiceChip(
                key: Key('peer-level-$key-${_wire(v)}'),
                label: Text(label(v)),
                selected: v == value,
                onSelected: _saving ? null : (_) => onPick(v),
              ),
          ]),
          const SizedBox(height: 4),
        ]),
      );

  String _wire<T>(T v) {
    if (v is LocLevel) return v.wire;
    if (v is UsageLevel) return v.wire;
    if (v is AppLevel) return v.wire;
    if (v is NetLevel) return v.wire;
    return v.toString();
  }

  Widget _extras(ThemeData theme, ColorScheme cs, PeerShareSettings s) {
    final p = s.policy;
    return Card(
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
        const Divider(height: 1),
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

  Widget _entries(ThemeData theme, ColorScheme cs) => Card(
        child: Column(children: [
          ListTile(
            key: const Key('peer-share-sensitive'),
            leading: const Icon(Icons.visibility_off_outlined),
            title: const Text('敏感软件过滤'),
            subtitle: Text(
              '已勾选 ${_settings?.policy.sensitivePkgs.length ?? 0} 个 · '
              '在对方那边只显示「其他应用」',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/peer-share/sensitive'),
          ),
          const Divider(height: 1),
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

  Widget _auditSection(ThemeData theme, ColorScheme cs) => Card(
        key: const Key('peer-share-audit'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('变更记录（双方可见，不可删除）',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            if (_audit.isEmpty)
              Text('还没有调整记录',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.outline))
            else
              for (final a in _audit.take(20))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    SizedBox(
                      width: 88,
                      child: Text(_fmt(a.ts),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: cs.outline)),
                    ),
                    Expanded(
                      child: Text('${a.mine ? '我' : 'TA'} ${a.detail}',
                          style: theme.textTheme.bodySmall),
                    ),
                  ]),
                ),
          ]),
        ),
      );

  String _fmt(double? ts) {
    if (ts == null || ts <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
