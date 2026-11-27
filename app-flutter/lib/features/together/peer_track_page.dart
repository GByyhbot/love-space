/// 2.8.7 全量施工令 · 轨迹页（照原型：示意画布 + 悬浮液态玻璃回放条 + 停留点列表）。
///
/// 三条红线：
/// · **不接商业地图 SDK**：点列按余弦修正等比例投影自绘到画布（无底图、无瓦片）；
/// · street 档不画折线、不显示精确距离，只摆网格化停留点并明示「仅街区」；
/// · off / 停用 → 整页关闭态（原型「定位报备已关闭」形态），不画假线。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/peer/peer_permissions.dart' show networkIconFor;
import '../../core/peer/peer_report_api.dart' show PeerEventItem, fetchPeerEvents;
import '../../core/peer/peer_track_data.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/tokens.dart';
import '../../core/theme/typography.dart';
import '../../core/ui/apple_ui.dart';
import '../../core/ui/empty_view.dart';
import '../../core/ui/error_view.dart';
import '../../core/ui/liquid_glass.dart';
import '../../core/ui/progress.dart';
import 'amap_track_map.dart';
import 'track_replay.dart';

/// 等比例余弦修正画布投影（支持 2~3 点、共线点、全天数百点与 street 仅停留点模式）。
class TrackCanvasMapper {
  TrackCanvasMapper({
    required List<PeerTrackPoint> points,
    required List<PeerTrackStay> stays,
    required Size size,
    EdgeInsets padding = const EdgeInsets.fromLTRB(20, 46, 20, 36),
  }) : _size = size {
    final coords = <(double, double)>[
      for (final p in points) (p.lat, p.lng),
      if (points.isEmpty)
        for (final s in stays) (s.lat, s.lng),
    ];
    if (coords.isEmpty || size.width <= 0 || size.height <= 0) return;

    var minLat = coords.first.$1, maxLat = coords.first.$1;
    var minLng = coords.first.$2, maxLng = coords.first.$2;
    for (var i = 1; i < coords.length; i++) {
      minLat = math.min(minLat, coords[i].$1);
      maxLat = math.max(maxLat, coords[i].$1);
      minLng = math.min(minLng, coords[i].$2);
      maxLng = math.max(maxLng, coords[i].$2);
    }

    final centerLat = (minLat + maxLat) / 2;
    _cosLat = math.cos(centerLat * math.pi / 180.0).clamp(0.2, 1.0);

    // 最小跨度兜底（≈11m），避免共线或紧邻 2~3 点拉满边界变形
    const minSpan = 1e-4;
    final rawSpanLat = maxLat - minLat;
    final rawSpanLng = (maxLng - minLng) * _cosLat;
    final spanLat = math.max(rawSpanLat, minSpan);
    final spanLng = math.max(rawSpanLng, minSpan);

    _minLat = centerLat - spanLat / 2;
    _minLng = ((minLng + maxLng) / 2) - (spanLng / _cosLat) / 2;

    final safeW = math.max(1.0, size.width - padding.horizontal);
    final safeH = math.max(1.0, size.height - padding.vertical);
    _scale = math.min(safeW / spanLng, safeH / spanLat);
    _dx = padding.left + (safeW - spanLng * _scale) / 2;
    _dy = padding.top + (safeH - spanLat * _scale) / 2;
    _maxLat = _minLat + spanLat;
    _valid = true;
  }

  final Size _size;
  bool _valid = false;
  double _cosLat = 1.0;
  double _minLat = 0;
  double _maxLat = 0;
  double _minLng = 0;
  double _scale = 1.0;
  double _dx = 0;
  double _dy = 0;

  bool get valid => _valid;

  Offset toOffset(double lat, double lng) {
    if (!_valid) return Offset(_size.width / 2, _size.height / 2);
    final x = _dx + (lng - _minLng) * _cosLat * _scale;
    final y = _dy + (_maxLat - lat) * _scale;
    return Offset(
      x.clamp(8.0, math.max(8.0, _size.width - 8.0)),
      y.clamp(8.0, math.max(8.0, _size.height - 8.0)),
    );
  }
}

/// 停留点气泡排版结果（供自绘与单测断言）。
class StayLabelPlacement {
  const StayLabelPlacement({
    required this.stay,
    required this.text,
    required this.rect,
    required this.anchor,
    required this.degradedToDuration,
  });

  final PeerTrackStay stay;
  final String text;
  final Rect rect;
  final Offset anchor;
  final bool degradedToDuration;
}

/// 停留点紧凑时长（降级标签用）。
String formatStayShortDuration(int sec) {
  if (sec < 60) return '<1分钟';
  final m = sec ~/ 60;
  if (m < 60) return '$m分钟';
  final h = m ~/ 60;
  final rest = m % 60;
  return rest == 0 ? '$h小时' : '$h小时$rest分';
}

/// 气泡防重叠排版：依次尝试上/下/右/左槽位；名称重叠时降级为仅时长，仍重叠则跳过。
List<StayLabelPlacement> layoutStayLabels({
  required List<PeerTrackStay> stays,
  required TrackCanvasMapper mapper,
  required Size size,
  TextStyle textStyle = const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
}) {
  if (stays.isEmpty || size.width <= 40 || size.height <= 60) {
    return const <StayLabelPlacement>[];
  }
  const padX = 7.0;
  const padY = 3.0;
  const safeTop = 44.0;
  const safeBottom = 30.0;
  const safeSide = 8.0;
  final maxLabelW = math.max(48.0, size.width * 0.38);

  final placed = <StayLabelPlacement>[];
  final occupied = <Rect>[];

  Rect? tryPlace(Offset anchor, String label) {
    final tp = TextPainter(
      text: TextSpan(text: label, style: textStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxLabelW);

    final w = tp.width + padX * 2;
    final h = tp.height + padY * 2;
    final maxLeft = math.max(safeSide, size.width - safeSide - w);
    final maxTop = math.max(safeTop, size.height - safeBottom - h);

    final candidates = <Offset>[
      Offset(anchor.dx - w / 2, anchor.dy - h - 9), // 上方
      Offset(anchor.dx - w / 2, anchor.dy + 9), // 下方
      Offset(anchor.dx + 9, anchor.dy - h / 2), // 右侧
      Offset(anchor.dx - w - 9, anchor.dy - h / 2), // 左侧
    ];

    for (final c in candidates) {
      final left = c.dx.clamp(safeSide, maxLeft);
      final top = c.dy.clamp(safeTop, maxTop);
      final rect = Rect.fromLTWH(left, top, w, h);
      final inflated = rect.inflate(2.5);
      if (!occupied.any((o) => o.overlaps(inflated))) {
        return rect;
      }
    }
    return null;
  }

  for (final s in stays) {
    final anchor = mapper.toOffset(s.lat, s.lng);
    final full = s.displayName;
    final fullRect = tryPlace(anchor, full);
    if (fullRect != null) {
      occupied.add(fullRect);
      placed.add(StayLabelPlacement(
        stay: s,
        text: full,
        rect: fullRect,
        anchor: anchor,
        degradedToDuration: false,
      ));
      continue;
    }
    final dur = formatStayShortDuration(s.durationSec);
    final durRect = tryPlace(anchor, dur);
    if (durRect != null) {
      occupied.add(durRect);
      placed.add(StayLabelPlacement(
        stay: s,
        text: dur,
        rect: durRect,
        anchor: anchor,
        degradedToDuration: true,
      ));
    }
  }
  return placed;
}

class PeerTrackPage extends ConsumerStatefulWidget {
  const PeerTrackPage({
    super.key,
    this.embedded = false,
    this.onSwitchTab,
  });

  final bool embedded;
  final ValueChanged<int>? onSwitchTab;

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

  /// 回放时刻（unix 秒，ValueNotifier 驱动：拖动/60x 播放只局部重绘画布与浮条）。
  final ValueNotifier<double?> _tNotifier = ValueNotifier<double?>(null);
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
    _tNotifier.dispose();
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
      _timer?.cancel();
      _tNotifier.value = null;
      setState(() {
        _data = data;
        _events = events;
        _error = null;
        _loading = false;
        _playing = false;
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
      final cur = _tNotifier.value;
      if (cur == null || cur >= points.last.ts) {
        _tNotifier.value = points.first.ts;
      }
    });
    // 60x 丝滑推进：33ms 一帧推进 2 秒，肉眼跟手不卡顿
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 33), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final cur = _tNotifier.value ?? points.first.ts;
      final next = cur + 2.0;
      if (next >= points.last.ts) {
        _tNotifier.value = points.last.ts;
        setState(() => _playing = false);
        t.cancel();
      } else {
        _tNotifier.value = next;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final side = _side;
    final hasReplay =
        _data != null && !side.hidden && side.points.length >= 2;
    final topInset = widget.embedded ? ShellChromeScope.topInsetOf(context) : 0.0;
    final body = Stack(
        children: [
          RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                16,
                topInset + 12,
                16,
                hasReplay
                    ? (widget.embedded ? 216 : 156)
                    : (widget.embedded ? Spacing.pageBottom + 64 : Spacing.pageBottom),
              ),
              children: [
                _topBar(theme, cs),
                const SizedBox(height: 12),
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
                      icon: AppIcons.locationOff,
                      title: '这一天没有轨迹记录',
                      hint: '仅街区共享时只显示停留点，不保留精确轨迹',
                      padding: EdgeInsets.symmetric(vertical: 24),
                    ),
                  )
                else if (side.points.isEmpty && side.stays.isEmpty)
                  _card(
                    cs,
                    child: const AppEmptyView(
                      icon: AppIcons.track,
                      title: '这一天没有轨迹记录',
                      hint: '不开定位或当天没走动，都不会画线',
                      padding: EdgeInsets.symmetric(vertical: 24),
                    ),
                  )
                else ...[
                  _canvasCard(theme, cs, side),
                  const SizedBox(height: 12),
                  _staysCard(theme, cs, side),
                ],
              ],
            ),
          ),
          if (hasReplay)
            Positioned(
              left: 16,
              right: widget.embedded ? 78 : 16,
              bottom: widget.embedded ? 82 : 12,
              child: SafeArea(
                top: false,
                child: _replayBar(theme, cs, side),
              ),
            ),
        ],
      );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('今日轨迹')),
      body: body,
    );
  }

  Widget _topBar(ThemeData theme, ColorScheme cs) {
    final y = _yesterday();
    return Row(children: [
      LiquidPillSegmented<bool>(
        key: const Key('track-side-toggle'),
        selected: _peerView,
        segments: const [
          LiquidPillSegment(value: true, label: 'TA'),
          LiquidPillSegment(value: false, label: '我'),
        ],
        onChanged: (v) => setState(() {
          _peerView = v;
          _tNotifier.value = null;
          _timer?.cancel();
          _playing = false;
        }),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Align(
          alignment: Alignment.centerRight,
          child: LiquidPillSegmented<String>(
            selected: _date.isEmpty ? '' : y,
            segments: [
              const LiquidPillSegment(
                key: Key('track-date-today'),
                value: '',
                label: '今天',
              ),
              LiquidPillSegment(
                key: const Key('track-date-yesterday'),
                value: y,
                label: '昨天',
              ),
            ],
            onChanged: (v) {
              if (_date == v) return;
              setState(() => _date = v);
              _load();
            },
          ),
        ),
      ),
    ]);
  }

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
          const SizedBox(height: 12),
          FilledButton.tonal(
            key: const Key('track-go-settings'),
            onPressed: () => context.push('/settings/peer-share'),
            child: const Text('去设置'),
          ),
        ]),
      );

  Widget _canvasCard(ThemeData theme, ColorScheme cs, PeerTrackSide side) {
    return _card(
      cs,
      padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(
          aspectRatio: 1.32,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(kGlassInnerRadius),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Container(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.38),
                    child: ValueListenableBuilder<double?>(
                      valueListenable: _tNotifier,
                      builder: (context, t, _) {
                        final reading =
                            t == null ? null : pointAt(side.points, t);
                        return AmapTrackMapWidget(
                          side: side,
                          replayLat: reading?.lat,
                          replayLng: reading?.lng,
                          pathColor: cs.primary,
                          fallbackBuilder: (_) => CustomPaint(
                            key: const Key('track-canvas'),
                            painter: _TrackPainter(
                              side: side,
                              pathColor: cs.primary,
                              driveColor: cs.tertiary,
                              stayColor: cs.secondary,
                              gridColor: cs.outlineVariant,
                              reading: reading,
                              labelColor: cs.onSurface,
                              bgLabel: cs.surface,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                // 顶部悬浮 HUD 条（原型一致：实时位置状态 + 里程）
                Positioned(
                  top: 8,
                  left: 8,
                  right: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: cs.surface.withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: cs.outlineVariant.withValues(alpha: 0.55),
                      ),
                    ),
                    child: Row(children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: side.isStreet ? cs.secondary : cs.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          side.isStreet
                              ? '仅街区（不画折线）'
                              : (side.stays.isNotEmpty
                                  ? side.stays.last.displayName
                                  : '当日路线'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (side.distanceM != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          '已移动 ${_km(side.distanceM!)}',
                          style: tabularStyle(
                            theme.textTheme.labelSmall
                                ?.copyWith(color: cs.outline),
                          ),
                        ),
                      ],
                    ]),
                  ),
                ),
                // 左下角图例小胶囊
                if (!side.isStreet && side.points.length >= 2)
                  Positioned(
                    bottom: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: cs.surface.withValues(alpha: 0.86),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: cs.outlineVariant.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(width: 12, height: 2.5, color: cs.primary),
                          const SizedBox(width: 4),
                          Text('步行/静止',
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: cs.outline, fontSize: 10)),
                          const SizedBox(width: 8),
                          Container(
                              width: 12, height: 2.5, color: cs.tertiary),
                          const SizedBox(width: 4),
                          Text('驾车/通勤',
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: cs.outline, fontSize: 10)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (side.isStreet)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 2),
            child: Text('仅街区共享：只给停留点，不给精确路线与距离',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
          ),
        if (side.stays.isNotEmpty) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final s in side.stays.take(6))
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    '${s.displayName} · ${_dur(s.durationSec)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tabularStyle(theme.textTheme.labelSmall),
                  ),
                ),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _replayBar(ThemeData theme, ColorScheme cs, PeerTrackSide side) {
    final points = side.points;
    final nets = _netRecords();
    final batteries = _batteryReadings();
    return ValueListenableBuilder<double?>(
      valueListenable: _tNotifier,
      builder: (context, rawT, _) {
        final t = rawT ?? points.first.ts;
        final net = netAt(nets, t);
        final batt = batteryAt(batteries, t);
        final speed = speedKmhAt(points, t);
        return LiquidGlassSurface(
          key: const Key('track-replay'),
          borderRadius: BorderRadius.circular(kGlassSheetRadius),
          padding: const EdgeInsets.fromLTRB(12, 10, 14, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                IconButton.filledTonal(
                  key: const Key('track-play'),
                  onPressed: _togglePlay,
                  icon: Icon(_playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded),
                ),
                const SizedBox(width: Spacing.xs),
                Expanded(
                  child: Slider(
                    key: const Key('track-slider'),
                    value: replayProgress(points, t),
                    onChanged: (v) {
                      _timer?.cancel();
                      if (_playing) setState(() => _playing = false);
                      _tNotifier.value = timeAtProgress(points, v);
                    },
                  ),
                ),
                const SizedBox(width: Spacing.xs),
                Text(
                  _clock(t),
                  style: AppType.numeric(
                    theme,
                    base: theme.textTheme.labelLarge?.copyWith(
                      color: cs.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: Spacing.xs),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _readout(theme, cs, '速度',
                      speed == null ? '—' : '${speed.toStringAsFixed(0)} km/h'),
                  Flexible(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (net != null) ...[
                          Icon(networkIconFor(net.net),
                              size: 13, color: cs.outline),
                          const SizedBox(width: Spacing.xs),
                        ],
                        Flexible(
                          child: _readout(theme, cs, '网络', net?.label ?? '—'),
                        ),
                      ],
                    ),
                  ),
                  _readout(theme, cs, '电量', batt == null ? '—' : '$batt%'),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _readout(ThemeData theme, ColorScheme cs, String label, String value) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$label ',
            style: theme.textTheme.labelSmall?.copyWith(color: cs.outline)),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.numeric(
              theme,
              base: theme.textTheme.labelSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ),
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
        Row(children: [
          Text('停留点与通勤节点', style: AppType.title(theme)),
          const Spacer(),
          Text('点击定位到时间轴', style: AppType.caption(theme)),
        ]),
        const SizedBox(height: Spacing.sm),
        for (var i = 0; i < side.stays.length; i++) ...[
          if (i > 0)
            Divider(
              height: 1,
              color: cs.outlineVariant.withValues(alpha: 0.45),
            ),
          _stayRow(theme, cs, side.stays[i], i + 1),
        ],
      ]),
    );
  }

  Widget _stayRow(
      ThemeData theme, ColorScheme cs, PeerTrackStay s, int index) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.small),
      onTap: () {
        _timer?.cancel();
        if (_playing) setState(() => _playing = false);
        _tNotifier.value = s.arrivedAt;
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppTouch.minTarget),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              vertical: Spacing.sm, horizontal: Spacing.xs),
          child: Row(children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: s.ongoing ? cs.primary : cs.secondaryContainer,
            ),
            alignment: Alignment.center,
            child: Text(
              '$index',
              style: tabularStyle(
                theme.textTheme.labelSmall?.copyWith(
                  color: s.ongoing ? cs.onPrimary : cs.onSecondaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_clock(s.arrivedAt)}'
                  '${s.ongoing ? ' – 至今' : ' – ${_clock(s.leftAt!)}'}',
                  style: tabularStyle(
                    theme.textTheme.labelSmall?.copyWith(color: cs.outline),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _dur(s.durationSec),
            style: tabularStyle(
              theme.textTheme.labelMedium?.copyWith(
                color: s.ongoing ? cs.primary : cs.outline,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ]),
        ),
      ),
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

  Widget _card(
    ColorScheme cs, {
    required Widget child,
    Key? key,
    EdgeInsetsGeometry padding = const EdgeInsets.all(Spacing.cardPad),
  }) =>
      LiquidGlassCard(key: key, padding: padding, child: child);
}

/// 示意画布：无底图，支持等比例投影、亚像素抽稀与气泡防重叠降级。
class _TrackPainter extends CustomPainter {
  _TrackPainter({
    required this.side,
    required this.pathColor,
    required this.driveColor,
    required this.stayColor,
    required this.gridColor,
    required this.labelColor,
    required this.bgLabel,
    this.reading,
  });

  final PeerTrackSide side;
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
      ..color = gridColor.withValues(alpha: 0.30)
      ..strokeWidth = 0.6;
    for (var i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      final y = size.height * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final mapper = TrackCanvasMapper(
      points: side.points,
      stays: side.stays,
      size: size,
    );
    if (!mapper.valid) return;

    // 折线：步行/静止实线，驾车虚线；数百点按像素步长抽稀，防卡顿
    if (!side.isStreet && side.points.length >= 2) {
      final solidPath = Path();
      final drivePaint = Paint()
        ..color = driveColor
        ..strokeWidth = 2.8
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      var prevPt = side.points.first;
      var prevPx = mapper.toOffset(prevPt.lat, prevPt.lng);
      for (var i = 1; i < side.points.length; i++) {
        final curPt = side.points[i];
        final curPx = mapper.toOffset(curPt.lat, curPt.lng);
        final isLast = i == side.points.length - 1;
        if (!isLast && (curPx - prevPx).distanceSquared < 1.5) {
          continue;
        }
        if (_driveBetween(prevPt.ts, curPt.ts)) {
          _dashLine(canvas, prevPx, curPx, drivePaint);
        } else {
          solidPath.moveTo(prevPx.dx, prevPx.dy);
          solidPath.lineTo(curPx.dx, curPx.dy);
        }
        prevPt = curPt;
        prevPx = curPx;
      }
      canvas.drawPath(
        solidPath,
        Paint()
          ..color = pathColor
          ..strokeWidth = 3.0
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );

      final firstPx = mapper.toOffset(side.points.first.lat, side.points.first.lng);
      final lastPx = mapper.toOffset(side.points.last.lat, side.points.last.lng);
      canvas.drawCircle(firstPx, 6, Paint()..color = bgLabel);
      _dot(canvas, firstPx, pathColor, 4.5);
      canvas.drawCircle(lastPx, 6.5, Paint()..color = bgLabel);
      _dot(canvas, lastPx, pathColor.withValues(alpha: 0.72), 4.5);
    }

    // 停留点圆点 + 防重叠气泡
    for (final s in side.stays) {
      final p = mapper.toOffset(s.lat, s.lng);
      canvas.drawCircle(p, 7.5, Paint()..color = bgLabel);
      _dot(canvas, p, stayColor, 5.5);
    }
    final labelStyle = TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w600,
      color: labelColor,
    );
    final placements = layoutStayLabels(
      stays: side.stays,
      mapper: mapper,
      size: size,
      textStyle: labelStyle,
    );
    final maxLabelW = math.max(48.0, size.width * 0.38);
    for (final item in placements) {
      final rrect = RRect.fromRectAndRadius(item.rect, const Radius.circular(8));
      canvas.drawRRect(
        rrect,
        Paint()..color = bgLabel.withValues(alpha: 0.90),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = stayColor.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
      final tp = TextPainter(
        text: TextSpan(text: item.text, style: labelStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: maxLabelW);
      tp.paint(canvas, Offset(item.rect.left + 7, item.rect.top + 3));
    }

    // 回放光点
    final r = reading;
    if (r != null) {
      final p = mapper.toOffset(r.lat, r.lng);
      canvas.drawCircle(p, 11, Paint()..color = pathColor.withValues(alpha: 0.24));
      canvas.drawCircle(p, 7, Paint()..color = bgLabel);
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
      old.pathColor != pathColor ||
      old.bgLabel != bgLabel;
}
