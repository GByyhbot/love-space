/// 2.8.7 全量施工令 · 轨迹页（照原型：示意画布 + 回放 + 停留点列表）。
///
/// 三条红线：
/// · **不接商业地图 SDK**：点列按等距圆柱投影自绘到画布（无底图、无瓦片）；
/// · street 档不画折线、不显示精确距离，只摆网格化停留点并明示「仅街区」；
/// · off / 停用 → 整页关闭态（原型「定位报备已关闭」形态），不画假线。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/peer/peer_report_api.dart' show PeerEventItem, fetchPeerEvents;
import '../../core/peer/peer_track_data.dart';
import '../../core/theme/tokens.dart';
import '../../core/ui/empty_view.dart';
import '../../core/ui/error_view.dart';
import '../../core/ui/progress.dart';
import 'track_replay.dart';

class PeerTrackPage extends ConsumerStatefulWidget {
  const PeerTrackPage({super.key});

  @override
  ConsumerState<PeerTrackPage> createState() => _PeerTrackPageState();
}

class _PeerTrackPageState extends ConsumerState<PeerTrackPage> {
  PeerTrackDay? _data;
  List<PeerEventItem> _events = const [];
  bool _loading = false;
  String? _error;

  /// 视角：true = 看对方，false = 看我。
  bool _peerView = true;

  /// 选中的日期（空 = 今天；只允许 15 天保留期内）。
  String _date = '';

  /// 回放时刻（unix 秒）；null = 未回放（显示全天概要）。
  double? _t;
  Timer? _timer;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final dio = await ref.read(api.dioProvider.future);
      final data = await fetchPeerTrack(dio, date: _date);
      List<PeerEventItem> events = const [];
      try {
        final day = await fetchPeerEvents(dio, date: _date);
        events = day.events;
      } catch (_) {
        // 事件流拿不到只影响回放读数，不影响轨迹本身
      }
      if (!mounted) return;
      setState(() {
        _data = data;
        _events = events;
        _error = null;
        _loading = false;
        _t = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = api.errorDetail(e);
        _loading = false;
      });
    }
  }

  PeerTrackSide get _side =>
      _peerView
          ? (_data?.peer ?? const PeerTrackSide())
          : (_data?.mine ?? const PeerTrackSide());

  void _togglePlay() {
    final points = _side.points;
    if (points.length < 2) return;
    if (_playing) {
      _timer?.cancel();
      setState(() => _playing = false);
      return;
    }
    setState(() {
      _playing = true;
      _t ??= points.first.ts;
    });
    // 60x：每 100ms 推进 6 秒
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final cur = _t ?? points.first.ts;
      final next = cur + 6;
      if (next >= points.last.ts) {
        setState(() {
          _t = points.last.ts;
          _playing = false;
        });
        t.cancel();
      } else {
        setState(() => _t = next);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final side = _side;
    return Scaffold(
      appBar: AppBar(title: const Text('今日轨迹')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, Spacing.pageBottom),
          children: [
            _topBar(theme, cs),
            const SizedBox(height: 10),
            if (_loading && _data == null)
              const AppProgress()
            else if (_data == null)
              AppErrorView(
                detail: '轨迹拉不到：${_error ?? api.genericErrorText}',
                onRetry: _load,
              )
            else if (side.hidden)
              _closedCard(theme, cs, side)
            else if (side.isStreet && side.stays.isEmpty)
              _card(
                cs,
                child: const AppEmptyView(
                  icon: Icons.location_off_outlined,
                  title: '这一天没有轨迹记录',
                  hint: '仅街区共享时只显示停留点，不保留精确轨迹',
                  padding: EdgeInsets.symmetric(vertical: 24),
                ),
              )
            else if (side.points.isEmpty && side.stays.isEmpty)
              _card(
                cs,
                child: const AppEmptyView(
                  icon: Icons.route_outlined,
                  title: '这一天没有轨迹记录',
                  hint: '不开定位或当天没走动，都不会画线',
                  padding: EdgeInsets.symmetric(vertical: 24),
                ),
              )
            else ...[
              _canvasCard(theme, cs, side),
              const SizedBox(height: 12),
              if (side.points.length >= 2) _replayBar(theme, cs, side),
              if (side.points.length >= 2) const SizedBox(height: 12),
              _staysCard(theme, cs, side),
            ],
          ],
        ),
      ),
    );
  }

  Widget _topBar(ThemeData theme, ColorScheme cs) => Row(children: [
        Expanded(
          child: Wrap(spacing: 8, children: [
            ChoiceChip(
              key: const Key('track-date-today'),
              label: const Text('今天'),
              selected: _date.isEmpty,
              onSelected: (_) {
                if (_date.isEmpty) return;
                setState(() => _date = '');
                _load();
              },
            ),
            ChoiceChip(
              key: const Key('track-date-yesterday'),
              label: const Text('昨天'),
              selected: _date == _yesterday(),
              onSelected: (_) {
                final y = _yesterday();
                if (_date == y) return;
                setState(() => _date = y);
                _load();
              },
            ),
          ]),
        ),
        // 视角切换（对方 / 我）
        SegmentedButton<bool>(
          key: const Key('track-side-toggle'),
          segments: const [
            ButtonSegment(value: true, label: Text('TA')),
            ButtonSegment(value: false, label: Text('我')),
          ],
          selected: {_peerView},
          onSelectionChanged: (s) => setState(() {
            _peerView = s.first;
            _t = null;
            _timer?.cancel();
            _playing = false;
          }),
        ),
      ]);

  String _yesterday() {
    final d = DateTime.now().subtract(const Duration(days: 1));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Widget _closedCard(ThemeData theme, ColorScheme cs, PeerTrackSide side) => _card(
        cs,
        key: const Key('track-closed'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            side.halted.isPaused
                ? '已暂停报备 · 看不到这一天的轨迹'
                : '定位报备已关闭',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            side.halted.isPaused
                ? '对方暂停期间不采集，恢复后也不补报这段。'
                : '位置与轨迹共享关闭时不显示任何轨迹，也不保留历史。',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            key: const Key('track-go-settings'),
            onPressed: () => context.push('/settings/peer-share'),
            child: const Text('去设置'),
          ),
        ]),
      );

  Widget _canvasCard(ThemeData theme, ColorScheme cs, PeerTrackSide side) {
    final proj = TrackProjector(side.points);
    final t = _t;
    final reading = t == null ? null : pointAt(side.points, t);
    return _card(
      cs,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(side.isStreet ? '仅街区（不画折线）' : '当日路线',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
          const Spacer(),
          if (side.distanceM != null)
            Text('已移动 ${_km(side.distanceM!)}',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
        ]),
        const SizedBox(height: 8),
        AspectRatio(
          aspectRatio: 1.35,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: Container(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
              child: CustomPaint(
                key: const Key('track-canvas'),
                painter: _TrackPainter(
                  side: side,
                  proj: proj,
                  pathColor: cs.primary,
                  driveColor: cs.tertiary,
                  stayColor: cs.secondary,
                  gridColor: cs.outlineVariant,
                  reading: reading,
                  labelColor: cs.onSurface,
                  bgLabel: cs.surface,
                ),
              ),
            ),
          ),
        ),
        if (side.isStreet)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('仅街区共享：只给停留点，不给精确路线与距离',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
          ),
        if (side.stays.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final s in side.stays.take(6))
              Chip(
                visualDensity: VisualDensity.compact,
                label: Text('${s.displayName} · ${_dur(s.durationSec)}'),
              ),
          ]),
        ],
      ]),
    );
  }

  Widget _replayBar(ThemeData theme, ColorScheme cs, PeerTrackSide side) {
    final points = side.points;
    final t = _t ?? points.first.ts;
    final nets = _netRecords();
    final batteries = _batteryReadings();
    final net = netAt(nets, t);
    final batt = batteryAt(batteries, t);
    final speed = speedKmhAt(points, t);
    return _card(
      cs,
      key: const Key('track-replay'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconButton.filledTonal(
            key: const Key('track-play'),
            onPressed: _togglePlay,
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Slider(
              key: const Key('track-slider'),
              value: replayProgress(points, t),
              onChanged: (v) => setState(() {
                _t = timeAtProgress(points, v);
                _timer?.cancel();
                _playing = false;
              }),
            ),
          ),
        ]),
        Wrap(spacing: 14, runSpacing: 4, children: [
          _readout(theme, cs, '时间', _clock(t)),
          _readout(theme, cs, '速度',
              speed == null ? '—' : '${speed.toStringAsFixed(0)} km/h'),
          _readout(theme, cs, '网络', net?.label ?? '—'),
          _readout(theme, cs, '电量', batt == null ? '—' : '$batt%'),
        ]),
        const SizedBox(height: 4),
        Text('60 倍速回放 · 拖动滑块即定位',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
      ]),
    );
  }

  Widget _readout(ThemeData theme, ColorScheme cs, String label, String value) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$label ', style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
        Text(value, style: theme.textTheme.bodySmall),
      ]);

  Widget _staysCard(ThemeData theme, ColorScheme cs, PeerTrackSide side) {
    if (side.stays.isEmpty) {
      return _card(
        cs,
        child: Text('这一天没有停留点（停留不足 5 分钟不单独记）',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
      );
    }
    return _card(
      cs,
      key: const Key('track-stays'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('停留点与通勤节点',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        for (final s in side.stays)
          InkWell(
            onTap: () => setState(() {
              _t = s.arrivedAt;
              _timer?.cancel();
              _playing = false;
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Icon(Icons.place_outlined, size: 15, color: cs.secondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${s.displayName} · ${_clock(s.arrivedAt)}'
                    '${s.ongoing ? ' 起' : ' – ${_clock(s.leftAt!)}'}',
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(_dur(s.durationSec),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.outline)),
              ]),
            ),
          ),
      ]),
    );
  }

  List<PeerNetRecord> _netRecords() {
    final out = <PeerNetRecord>[];
    for (final e in _events) {
      if (e.type != 'state.net') continue;
      final p = e.payload;
      out.add(PeerNetRecord(
        ts: e.ts,
        net: (p['net'] ?? '').toString(),
        ssid: (p['ssid'] ?? '').toString(),
      ));
    }
    out.sort((a, b) => a.ts.compareTo(b.ts));
    return out;
  }

  List<BatteryReading> _batteryReadings() {
    final out = <BatteryReading>[];
    for (final e in _events) {
      if (e.type != 'state.battery') continue;
      final level = (e.payload['level'] as num?)?.toInt();
      if (level == null) continue;
      out.add(BatteryReading(ts: e.ts, level: level));
    }
    out.sort((a, b) => a.ts.compareTo(b.ts));
    return out;
  }

  String _km(double m) =>
      m < 1000 ? '${m.round()} 米' : '${(m / 1000).toStringAsFixed(1)} 公里';

  String _dur(int sec) {
    if (sec < 60) return '不足 1 分钟';
    final m = sec ~/ 60;
    if (m < 60) return '$m 分钟';
    final h = m ~/ 60;
    final rest = m % 60;
    return rest == 0 ? '$h 小时' : '$h 小时 $rest 分钟';
  }

  String _clock(double? ts) {
    if (ts == null || ts <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}';
  }

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
}

/// 示意画布：无底图，只有路线、起终点与停留点气泡。
class _TrackPainter extends CustomPainter {
  _TrackPainter({
    required this.side,
    required this.proj,
    required this.pathColor,
    required this.driveColor,
    required this.stayColor,
    required this.gridColor,
    required this.labelColor,
    required this.bgLabel,
    this.reading,
  });

  final PeerTrackSide side;
  final TrackProjector proj;
  final Color pathColor;
  final Color driveColor;
  final Color stayColor;
  final Color gridColor;
  final Color labelColor;
  final Color bgLabel;
  final ReplayPoint? reading;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor.withValues(alpha: 0.35)
      ..strokeWidth = 0.5;
    for (var i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      final y = size.height * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    Offset toPx(double lat, double lng) {
      final n = proj.project(lat, lng);
      return Offset(n.x * size.width, n.y * size.height);
    }

    // 折线：步行/静止实线，驾车虚线（按服务端分段着色）
    if (!side.isStreet && side.points.length >= 2) {
      final solid = Paint()
        ..color = pathColor
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      final dashed = Paint()
        ..color = driveColor
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < side.points.length - 1; i++) {
        final a = side.points[i];
        final b = side.points[i + 1];
        final isDrive = _driveBetween(a.ts, b.ts);
        final p1 = toPx(a.lat, a.lng);
        final p2 = toPx(b.lat, b.lng);
        if (isDrive) {
          _dashLine(canvas, p1, p2, dashed);
        } else {
          canvas.drawLine(p1, p2, solid);
        }
      }
      // 起终点
      _dot(canvas, toPx(side.points.first.lat, side.points.first.lng),
          pathColor, 5);
      _dot(canvas, toPx(side.points.last.lat, side.points.last.lng),
          pathColor.withValues(alpha: 0.55), 5);
    }

    // 停留点气泡
    for (final s in side.stays) {
      final p = toPx(s.lat, s.lng);
      _dot(canvas, p, stayColor, 6);
      if (s.placeName.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
            text: s.placeName,
            style: TextStyle(fontSize: 10, color: labelColor),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: size.width * 0.4);
        final rect = Rect.fromLTWH(
            p.dx + 6, p.dy - 7, tp.width + 6, tp.height + 2);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(3)),
          Paint()..color = bgLabel.withValues(alpha: 0.85),
        );
        tp.paint(canvas, Offset(rect.left + 3, rect.top + 1));
      }
    }

    // 回放光点
    final r = reading;
    if (r != null) {
      final p = toPx(r.lat, r.lng);
      canvas.drawCircle(p, 9, Paint()..color = pathColor.withValues(alpha: 0.22));
      _dot(canvas, p, pathColor, 5);
    }
  }

  bool _driveBetween(double aTs, double bTs) {
    for (final s in side.segments) {
      if (s.type == 'drive' && aTs >= s.startTs && bTs <= s.endTs) return true;
    }
    return false;
  }

  void _dot(Canvas canvas, Offset p, Color c, double r) =>
      canvas.drawCircle(p, r, Paint()..color = c);

  void _dashLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 6.0, gap = 4.0;
    final total = (b - a).distance;
    if (total <= 0) return;
    final dir = (b - a) / total;
    var d = 0.0;
    while (d < total) {
      final end = math.min(d + dash, total);
      canvas.drawLine(a + dir * d, a + dir * end, paint);
      d = end + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _TrackPainter old) =>
      old.reading != reading ||
      old.side != side ||
      old.pathColor != pathColor;
}
