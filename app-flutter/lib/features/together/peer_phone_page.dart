/// 2.8.7 全量施工令 · 手机页（照原型：四格统计 + 24h 分布 + 软件时间流 +
/// Top5 排行 + 网络切换记录）。
///
/// 分档渲染是这一页的重点（服务端已裁，页面按缺字段降级）：
/// · usage off / 停用 → 整页关闭态 + 去设置；
/// · screen_only → 只留两格与分布图，应用两节换明示行；
/// · app off → 统计与分布照常，时间流与排行换明示行；
/// · 自己侧未授权 → 引导卡（去系统页授权），不催、不弹窗。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/peer/peer_usage_data.dart';
import '../../core/peer/state_event_text.dart' show durationTextZh;
import '../../core/theme/tokens.dart';
import '../../core/ui/error_view.dart';
import '../../core/ui/progress.dart';

class PeerPhonePage extends ConsumerStatefulWidget {
  const PeerPhonePage({super.key});

  @override
  ConsumerState<PeerPhonePage> createState() => _PeerPhonePageState();
}

class _PeerPhonePageState extends ConsumerState<PeerPhonePage> {
  PeerUsageDay? _data;
  bool _loading = false;
  String? _error;
  bool _peerView = true;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final dio = await ref.read(api.dioProvider.future);
      final data = await fetchPeerUsageDaily(dio);
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = api.errorDetail(e);
        _loading = false;
      });
    }
  }

  PeerUsageSide get _side =>
      _peerView ? (_data?.peer ?? const PeerUsageSide()) : (_data?.mine ?? const PeerUsageSide());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final side = _side;
    return Scaffold(
      appBar: AppBar(title: const Text('手机使用')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, Spacing.pageBottom),
          children: [
            Row(children: [
              Expanded(
                child: SegmentedButton<bool>(
                  key: const Key('phone-side-toggle'),
                  segments: const [
                    ButtonSegment(value: true, label: Text('TA')),
                    ButtonSegment(value: false, label: Text('我')),
                  ],
                  selected: {_peerView},
                  onSelectionChanged: (s) => setState(() => _peerView = s.first),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            if (_loading && _data == null)
              const AppProgress()
            else if (_data == null)
              AppErrorView(
                detail: '使用数据拉不到：${_error ?? api.genericErrorText}',
                onRetry: _load,
              )
            else if (side.hidden)
              _closedCard(theme, cs, side)
            else ...[
              _statsGrid(theme, cs, side),
              const SizedBox(height: 12),
              if (side.hourly != null)
                _hourlyCard(theme, cs, side)
              else
                _hintCard(theme, cs, 'TA 只共享亮屏总时长，不共享小时分布'),
              const SizedBox(height: 12),
              ..._appSections(theme, cs, side),
              const SizedBox(height: 12),
              _networkCard(theme, cs, side),
            ],
          ],
        ),
      ),
    );
  }

  Widget _closedCard(ThemeData theme, ColorScheme cs, PeerUsageSide side) => _card(
        cs,
        key: const Key('phone-closed'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            side.halted.isPaused ? '已暂停报备 · 看不到手机使用' : '手机使用报备已关闭',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            side.halted.isPaused
                ? '暂停期间不采集，恢复后也不补报这段。'
                : '对方关闭手机使用共享时不显示任何使用数据。',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            key: const Key('phone-go-settings'),
            onPressed: () => context.push('/settings/peer-share'),
            child: const Text('去设置'),
          ),
        ]),
      );

  Widget _statsGrid(ThemeData theme, ColorScheme cs, PeerUsageSide side) {
    final cells = <Widget>[
      _statCell(theme, cs, '总使用时长',
          side.screenSec == null ? '—' : durationTextZh(side.screenSec!),
          side.screenSec != null && side.yesterdayScreenSec != null
              ? _delta(side.screenSec!, side.yesterdayScreenSec!)
              : null),
      _statCell(theme, cs, '解锁次数',
          side.unlocks == null ? '—' : '${side.unlocks} 次',
          (side.unlocks != null && (side.screenSec ?? 0) > 0)
              ? '平均每次 ${durationTextZh(side.screenSec! ~/ side.unlocks!)}'
              : null),
      _statCell(theme, cs, '最长连续',
          side.longestSessionSec == null
              ? '—'
              : durationTextZh(side.longestSessionSec!),
          null),
      _statCell(theme, cs, '当前网络',
          side.networkEvents?.isNotEmpty == true
              ? _netLabel(side.networkEvents!.first)
              : '—',
          null),
    ];
    return Wrap(
      key: const Key('phone-stats'),
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final c in cells)
          SizedBox(width: (MediaQuery.of(context).size.width - 32 - 10) / 2, child: c),
      ],
    );
  }

  Widget _statCell(ThemeData theme, ColorScheme cs, String label, String value,
          String? sub) =>
      _card(
        cs,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(label,
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
          if (sub != null)
            Text(sub,
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
        ]),
      );

  String _delta(int today, int yesterday) {
    final diff = today - yesterday;
    if (diff == 0) return '与昨日持平';
    return '较昨日 ${diff > 0 ? '+' : '-'}${durationTextZh(diff.abs())}';
  }

  Widget _hourlyCard(ThemeData theme, ColorScheme cs, PeerUsageSide side) {
    final hourly = side.hourly!;
    final maxV = hourly.fold<int>(0, (a, b) => b > a ? b : a);
    return _card(
      cs,
      key: const Key('phone-hourly'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('24 小时亮屏分布',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        SizedBox(
          height: 96,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var h = 0; h < 24; h++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Tooltip(
                      message: '$h 点 · ${hourly[h] ~/ 60} 分钟',
                      child: Container(
                        height: maxV == 0 ? 2 : (4 + 80 * hourly[h] / maxV),
                        decoration: BoxDecoration(
                          color: h < 6 ? cs.error : cs.primary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Row(children: [
          Text('00', style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
          const Spacer(),
          Text('06', style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
          const Spacer(),
          Text('12', style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
          const Spacer(),
          Text('18', style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
          const Spacer(),
          Text('23', style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
        ]),
        const SizedBox(height: 4),
        Text('00:00–05:59 用警示色（作息提醒，不评判）',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
      ]),
    );
  }

  List<Widget> _appSections(ThemeData theme, ColorScheme cs, PeerUsageSide side) {
    // usage_level=screen_only 或 app_level=off：应用两节整体换明示行
    final sessions = side.sessions;
    final top = side.topApps;
    if (sessions == null && top == null) {
      return [_hintCard(theme, cs, '对方仅共享亮屏数据（不含应用明细）')];
    }
    return [
      _card(
        cs,
        key: const Key('phone-sessions'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('软件时间流',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          if (sessions == null || sessions.isEmpty)
            Text('今天还没有应用使用记录',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline))
          else
            for (final s in sessions) _sessionRow(theme, cs, s),
          if ((side.foldedCount ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${side.foldedCount} 次短暂切换已折叠',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      _card(
        cs,
        key: const Key('phone-top'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('使用排行 Top5',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          if (top == null || top.isEmpty)
            Text('暂无排行（对方未共享应用记录）',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline))
          else
            for (final t in top) _topRow(theme, cs, t, top.first.sec),
        ]),
      ),
    ];
  }

  Widget _sessionRow(ThemeData theme, ColorScheme cs, PeerUsageSession s) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(
            width: 44,
            child: Text(_clock(s.start),
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
          ),
          Expanded(
            child: Text(
              s.masked ? '其他应用（已隐藏）' : s.app,
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(durationTextZh(s.sec),
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
        ]),
      );

  Widget _topRow(ThemeData theme, ColorScheme cs, PeerTopApp t, int maxSec) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(t.app,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            Text(durationTextZh(t.sec),
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
          ]),
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: maxSec <= 0 ? 0 : (t.sec / maxSec).clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: cs.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
        ]),
      );

  Widget _networkCard(ThemeData theme, ColorScheme cs, PeerUsageSide side) {
    final list = side.networkEvents ?? const <PeerNetEvent>[];
    if (list.isEmpty) {
      return _hintCard(theme, cs, '今天没有网络切换记录');
    }
    return _card(
      cs,
      key: const Key('phone-network'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('网络切换记录',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        for (final e in list.take(20))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              SizedBox(
                width: 44,
                child: Text(_clock(e.ts),
                    style:
                        theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
              ),
              Expanded(
                child: Text(_netLabel(e), style: theme.textTheme.bodySmall),
              ),
            ]),
          ),
      ]),
    );
  }

  String _netLabel(PeerNetEvent e) {
    switch (e.net) {
      case 'wifi':
        return e.ssid.isEmpty ? 'Wi-Fi' : 'Wi-Fi（${e.ssid}）';
      case 'cell':
        return '移动数据';
      case 'none':
        return '无网络';
    }
    return e.net.isEmpty ? '未知' : e.net;
  }

  Widget _hintCard(ThemeData theme, ColorScheme cs, String text) => _card(
        cs,
        child: Text(text,
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
      );

  Widget _card(ColorScheme cs, {required Widget child, Key? key}) => Container(
        key: key,
        width: double.infinity,
        padding: const EdgeInsets.all(Spacing.cardPad),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: child,
      );

  String _clock(double? ts) {
    if (ts == null || ts <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}';
  }
}
