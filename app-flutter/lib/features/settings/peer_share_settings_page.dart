/// 2.8.0 P1 · 伴侣共享与守护（四项共享开关二级页）。
///
/// 落点：`features/settings/`（设置主页「连接与提醒」组入口行的目标页，
/// 与其他设置二级页同目录同 AppBar 范式）；路由 `/settings/peer-share`，
/// 一律 `context.push`（AppBar 自动返回 + 系统手势双路径可回）。
///
/// 契约（`app/main.py:2008/2014` + `app/peer.py:46/54` 实读，后端零改动）：
/// · `GET /api/peer/settings` 顶层四键；`PUT` 同结构。
/// · 🔴 `save_settings` 逐键 `bool(data.get(k, True))` **全覆盖**写，
///   故每次提交都是 [PeerShareSettings.copyWith] 后的**完整四键对象**
///   （漏传键 = 静默重置回 true，把对方刚关掉的共享重新打开）。
///
/// 交互纪律：
/// · 首拉失败走 [AppErrorView] + 重试，**禁止**拿默认全开冒充服务端配置；
/// · 切换为乐观显示 + 整组禁用（`_saving` 期间任何开关不可点，避免连点
///   两个开关用同一份旧快照互相覆盖）；失败**立即回滚**到原值并 toast，
///   不做本地假成功。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/peer/peer_report_api.dart';
import '../../core/theme/tokens.dart';
import '../../core/ui/error_view.dart';
import '../../core/ui/progress.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;

/// 四项开关的静态描述（顺序与后端 `SHARE_KEYS` 一致）。
class _ShareSwitchSpec {
  const _ShareSwitchSpec({
    required this.key,
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.pick,
    required this.apply,
  });

  final String key;
  final String emoji;
  final String title;
  final String subtitle;
  final bool Function(PeerShareSettings s) pick;
  final PeerShareSettings Function(PeerShareSettings s, bool v) apply;
}

final List<_ShareSwitchSpec> _specs = [
  _ShareSwitchSpec(
    key: 'location',
    emoji: '📍',
    title: '实时位置共享',
    subtitle: '关闭后对方状态页将明确显示已关闭',
    pick: (s) => s.location,
    apply: (s, v) => s.copyWith(location: v),
  ),
  _ShareSwitchSpec(
    key: 'track',
    emoji: '🗺️',
    title: '历史轨迹共享',
    subtitle: '轨迹 15 天滚动清理，关闭后对方不可查看',
    pick: (s) => s.track,
    apply: (s, v) => s.copyWith(track: v),
  ),
  _ShareSwitchSpec(
    key: 'events',
    emoji: '💌',
    title: '报备与事件共享',
    subtitle: '控制主动报备与守护事件，关闭后无法发报备',
    pick: (s) => s.events,
    apply: (s, v) => s.copyWith(events: v),
  ),
  _ShareSwitchSpec(
    key: 'usage',
    emoji: '📊',
    title: '设备使用报告共享',
    subtitle: '后续版本接入，可提前预设开关',
    pick: (s) => s.usage,
    apply: (s, v) => s.copyWith(usage: v),
  ),
];

class PeerShareSettingsPage extends ConsumerStatefulWidget {
  const PeerShareSettingsPage({super.key});

  @override
  ConsumerState<PeerShareSettingsPage> createState() =>
      _PeerShareSettingsPageState();
}

class _PeerShareSettingsPageState extends ConsumerState<PeerShareSettingsPage> {
  PeerShareSettings? _settings;

  /// 首拉状态：null 且 [_error] 为空 = 加载中。
  String? _error;

  /// 保存中：整组开关同时禁用（防连点用旧快照互相覆盖）。
  bool _saving = false;

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
      if (!mounted) return;
      setState(() => _settings = s);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _settings = null;
        _error = api.errorDetail(e);
      });
    }
  }

  Future<void> _toggle(_ShareSwitchSpec spec, bool next) async {
    final current = _settings;
    if (current == null || _saving) return;
    if (spec.pick(current) == next) return;
    // 乐观显示新值 + 整组禁用
    setState(() {
      _saving = true;
      _settings = spec.apply(current, next);
    });
    try {
      final dio = await ref.read(api.dioProvider.future);
      final saved = await updatePeerSettings(dio, _settings!);
      if (!mounted) return;
      setState(() => _settings = saved); // 以后端落库结果为准
      ref.read(chatToastProvider.notifier).show('共享设置已更新',
          tone: ChatToastTone.success);
    } catch (e) {
      if (!mounted) return;
      // 失败立即回滚原值（不做本地假成功）
      setState(() => _settings = current);
      ref
          .read(chatToastProvider.notifier)
          .show('共享设置未保存：${api.errorDetail(e)}', tone: ChatToastTone.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final s = _settings;

    return Scaffold(
      appBar: AppBar(title: const Text('伴侣共享与守护')),
      body: SafeArea(
        child: s == null
            ? (_error != null
                ? AppErrorView(detail: _error!, onRetry: _load)
                : const AppProgress())
            : ListView(
                key: const Key('peer-share-scroll'),
                padding: const EdgeInsets.fromLTRB(
                    16, 12, 16, Spacing.pageBottom),
                children: [
                  Text('这四项只影响 TA 能看到的范围，随时可以关。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.outline)),
                  const SizedBox(height: Spacing.gap),
                  Card(
                    child: Column(
                      children: [
                        for (var i = 0; i < _specs.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          _tile(theme, _specs[i], s),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: Spacing.gap),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '关闭任一共享后，对方界面会明确提示已关闭，不会显示空白或假故障',
                      key: const Key('peer-share-note'),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.outline),
                    ),
                  ),
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

  Widget _tile(ThemeData theme, _ShareSwitchSpec spec, PeerShareSettings s) {
    final cs = theme.colorScheme;
    return SwitchListTile(
      key: Key('peer-share-${spec.key}'),
      secondary: Text(spec.emoji, style: const TextStyle(fontSize: 22)),
      title: Text(spec.title),
      subtitle: Text(spec.subtitle,
          style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
      value: spec.pick(s),
      // 保存中整组禁用：连点两个开关会用同一份旧快照互相覆盖
      onChanged: _saving ? null : (v) => _toggle(spec, v),
    );
  }
}
