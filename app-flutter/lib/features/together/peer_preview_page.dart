/// 2.8.7 全量施工令 · 对方视角预览（「对方看到的你的样子」）。
///
/// 取**我自己**的完整数据，用**我的 policy** 现场裁一遍（`peer_preview.dart`
/// 与服务端同口径），所以这里看到的 = 对方会看到的。裁剪规则不另写一套。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/peer/peer_policy.dart';
import '../../core/peer/peer_report_api.dart';
import '../../core/peer/peer_track_data.dart';
import '../../core/peer/peer_usage_data.dart';
import '../../core/peer/state_event_text.dart' show durationTextZh;
import '../../core/theme/tokens.dart';
import '../../core/ui/error_view.dart';
import '../../core/ui/liquid_glass.dart';
import '../../core/ui/progress.dart';
import 'peer_preview.dart';

class PeerPreviewPage extends ConsumerStatefulWidget {
  const PeerPreviewPage({super.key});

  @override
  ConsumerState<PeerPreviewPage> createState() => _PeerPreviewPageState();
}

class _PeerPreviewPageState extends ConsumerState<PeerPreviewPage> {
  PeerPolicy _policy = PeerPolicy.defaults;
  PeerUsageSide? _usage;
  PeerTrackSide? _track;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final dio = await ref.read(api.dioProvider.future);
      final settings = await fetchPeerSettings(dio);
      PeerUsageSide? usage;
      PeerTrackSide? track;
      try {
        usage = (await fetchPeerUsageDaily(dio)).mine;
      } catch (_) {}
      try {
        track = (await fetchPeerTrack(dio)).mine;
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _policy = settings.policy;
        _usage = usage;
        _track = track;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = api.errorDetail(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('对方视角预览')),
      body: _loading
          ? const AppProgress()
          : _error != null
              ? AppErrorView(detail: _error!, onRetry: _load)
              : ListView(
                  key: const Key('preview-scroll'),
                  padding:
                      const EdgeInsets.fromLTRB(16, 12, 16, Spacing.pageBottom),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.secondaryContainer.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Text(
                        '这就是对方看到的你的样子（按当前分档裁剪后的结果）',
                        key: const Key('preview-banner'),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_policy.isHalted)
                      _card(
                        theme,
                        cs,
                        key: const Key('preview-halted'),
                        child: Text(
                          _policy.haltedReason == 'off'
                              ? '对方看到：你已完全关闭报备'
                              : '对方看到：你已暂停报备',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: cs.error),
                        ),
                      )
                    else ...[
                      _usageCard(theme, cs),
                      const SizedBox(height: 12),
                      _trackCard(theme, cs),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      '分档在「报备设置」里调；预览与对方端读同一套裁剪口径。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.outline),
                    ),
                  ],
                ),
    );
  }

  Widget _usageCard(ThemeData theme, ColorScheme cs) {
    final mine = _usage;
    if (mine == null) {
      return _card(theme, cs, child: const Text('使用数据暂不可用'));
    }
    final p = previewUsage(mine, _policy);
    return _card(
      theme,
      cs,
      key: const Key('preview-usage'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('手机使用',
            style:
                theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        if (p.hidden)
          Text('对方看到：手机使用报备已关闭',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.error))
        else ...[
          Text(
            '亮屏 ${p.screenSec == null ? '—' : durationTextZh(p.screenSec!)}'
            ' · 解锁 ${p.unlocks ?? '—'} 次',
            key: const Key('preview-usage-line'),
            style: theme.textTheme.bodyMedium,
          ),
          if (p.hourly != null) _line(theme, cs, '小时分布：可见'),
          if (p.topApps != null)
            _line(theme, cs, '使用排行：${p.topApps!.take(3).map((e) => e.app).join('、')}'),
          if (p.sessions != null) _line(theme, cs, '软件时间流：可见（${p.sessions!.length} 条）'),
          if (p.currentApp != null) _line(theme, cs, '正在使用：${p.currentApp!.app}'),
          if (p.networkEvents != null)
            _line(theme, cs, '网络记录：${p.networkEvents!.length} 条'),
        ],
      ]),
    );
  }

  Widget _trackCard(ThemeData theme, ColorScheme cs) {
    final mine = _track;
    if (mine == null) {
      return _card(theme, cs, child: const Text('轨迹数据暂不可用'));
    }
    final p = previewTrack(mine, _policy);
    return _card(
      theme,
      cs,
      key: const Key('preview-track'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('今日足迹',
            style:
                theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        if (p.hidden)
          Text('对方看到：定位报备已关闭',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.error))
        else if (p.isStreet)
          Text(
            '对方看到：仅街区 · ${p.stays.length} 个停留点，无精确路线与距离',
            key: const Key('preview-track-line'),
            style: theme.textTheme.bodyMedium,
          )
        else
          Text(
            '对方看到：已移动 ${p.distanceM == null ? '—' : '${(p.distanceM! / 1000).toStringAsFixed(1)} 公里'}'
            ' · ${p.stays.length} 个停留点',
            key: const Key('preview-track-line'),
            style: theme.textTheme.bodyMedium,
          ),
      ]),
    );
  }

  Widget _line(ThemeData theme, ColorScheme cs, String text) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(text,
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
      );

  Widget _card(ThemeData theme, ColorScheme cs,
          {required Widget child, Key? key}) =>
      LiquidGlassCard(key: key, child: child);
}
