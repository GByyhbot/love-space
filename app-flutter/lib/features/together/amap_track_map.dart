/// 轨迹页签高德真地图封装（Android 接入高德 3D SDK PlatformView，
/// 缺 Key / 离线 / 加载失败 / 非 Android 自动优雅降级为既有自绘轨迹画布）。
///
/// 交互能力：
/// · 支持双指缩放与拖拽浏览；
/// · 手动拖拽进入自由浏览态，右下角浮出「回到轨迹」一键居中按钮；
/// · 精确模式画当日折线 + 可点停留点气泡（停留时长与到达–离开时间）；
/// · 仅街区模式只画停留点不画折线；
/// · 回放标记随时间轴 [replayPoint] 沿轨迹实时移动。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/peer/peer_track_data.dart';
import '../../core/theme/tokens.dart';

class AmapTrackMapWidget extends StatefulWidget {
  const AmapTrackMapWidget({
    super.key,
    required this.side,
    this.replayLat,
    this.replayLng,
    required this.pathColor,
    required this.fallbackBuilder,
  });

  final PeerTrackSide side;
  final double? replayLat;
  final double? replayLng;
  final Color pathColor;
  final WidgetBuilder fallbackBuilder;

  @override
  State<AmapTrackMapWidget> createState() => _AmapTrackMapWidgetState();
}

class _AmapTrackMapWidgetState extends State<AmapTrackMapWidget> {
  static const MethodChannel _configChannel =
      MethodChannel('cn.iepose.lovespace/amap_config');
  static const String _viewType = 'cn.iepose.lovespace/amap_track_view';
  static Future<bool>? _hasKeyFuture;

  bool _useNativeMap = false;
  bool _mapFailed = false;
  bool _freeBrowse = false;
  MethodChannel? _viewChannel;
  final TransformationController _fallbackTransform =
      TransformationController();

  @override
  void initState() {
    super.initState();
    _checkNativeAvailability();
  }

  @override
  void dispose() {
    _viewChannel?.setMethodCallHandler(null);
    _fallbackTransform.dispose();
    super.dispose();
  }

  Future<void> _checkNativeAvailability() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      _hasKeyFuture ??= _configChannel
          .invokeMethod<bool>('hasApiKey')
          .then((v) => v == true)
          .catchError((_) => false);
      final ok = await _hasKeyFuture!;
      if (!mounted) return;
      if (ok && !_mapFailed) {
        setState(() => _useNativeMap = true);
      }
    } catch (_) {
      // 通道不可用时保持自绘回退
    }
  }

  @override
  void didUpdateWidget(covariant AmapTrackMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_viewChannel != null) {
      if (oldWidget.side != widget.side) {
        _syncTrackData();
      }
      if (oldWidget.replayLat != widget.replayLat ||
          oldWidget.replayLng != widget.replayLng) {
        _syncReplayPosition();
      }
    }
  }

  Map<String, Object?> _buildTrackPayload(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return <String, Object?>{
      'isStreet': widget.side.isStreet,
      'dark': dark,
      'pathColor': widget.pathColor.toARGB32(),
      'points': [
        for (final p in widget.side.points)
          <String, Object?>{
            'lat': p.lat,
            'lng': p.lng,
            'speed': p.speed,
          },
      ],
      'stays': [
        for (final s in widget.side.stays)
          <String, Object?>{
            'lat': s.lat,
            'lng': s.lng,
            'title': s.displayName,
            'snippet': _staySnippet(s),
          },
      ],
    };
  }

  String _staySnippet(PeerTrackStay s) {
    final mins = (s.durationSec / 60).round();
    final dur = mins >= 60
        ? '${mins ~/ 60}小时${mins % 60}分'
        : (mins > 0 ? '$mins分钟' : '短暂经过');
    final start = _hhmm(s.arrivedAt);
    final end = s.leftAt == null ? '至今' : _hhmm(s.leftAt!);
    return '停留 $dur · $start – $end';
  }

  String _hhmm(double ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _syncTrackData() async {
    final ch = _viewChannel;
    if (ch == null || !mounted) return;
    try {
      await ch.invokeMethod('setTrackData', _buildTrackPayload(context));
    } catch (_) {}
  }

  Future<void> _syncReplayPosition() async {
    final ch = _viewChannel;
    if (ch == null) return;
    final lat = widget.replayLat;
    final lng = widget.replayLng;
    try {
      await ch.invokeMethod(
        'setReplayPosition',
        (lat == null || lng == null)
            ? null
            : <String, Object?>{'lat': lat, 'lng': lng},
      );
    } catch (_) {}
  }

  Future<void> _recenter() async {
    setState(() => _freeBrowse = false);
    if (_useNativeMap && !_mapFailed && _viewChannel != null) {
      try {
        await _viewChannel!.invokeMethod('recenter');
      } catch (_) {}
    } else {
      _fallbackTransform.value = Matrix4.identity();
    }
  }

  void _onPlatformViewCreated(int viewId) {
    final ch = MethodChannel('${_viewType}_$viewId');
    _viewChannel = ch;
    ch.setMethodCallHandler((call) async {
      if (!mounted) return;
      switch (call.method) {
        case 'onUserDrag':
          if (!_freeBrowse) setState(() => _freeBrowse = true);
        case 'onMapError':
          setState(() {
            _mapFailed = true;
            _useNativeMap = false;
          });
      }
    });
    _syncTrackData();
    _syncReplayPosition();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final showNative = _useNativeMap && !_mapFailed;

    return Stack(
      children: [
        Positioned.fill(
          child: showNative
              ? AndroidView(
                  key: const Key('track-amap-view'),
                  viewType: _viewType,
                  creationParams: _buildTrackPayload(context),
                  creationParamsCodec: const StandardMessageCodec(),
                  onPlatformViewCreated: _onPlatformViewCreated,
                )
              : InteractiveViewer(
                  transformationController: _fallbackTransform,
                  minScale: 1.0,
                  maxScale: 3.5,
                  onInteractionUpdate: (_) {
                    if (!_freeBrowse) setState(() => _freeBrowse = true);
                  },
                  child: widget.fallbackBuilder(context),
                ),
        ),
        // 自由浏览态：右下角浮出「回到轨迹」一键居中按钮
        if (_freeBrowse)
          Positioned(
            right: 8,
            bottom: 8,
            child: Material(
              color: cs.surface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(AppRadius.pill),
              elevation: 2,
              child: InkWell(
                key: const Key('track-recenter-btn'),
                borderRadius: BorderRadius.circular(AppRadius.pill),
                onTap: _recenter,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.my_location_rounded,
                          size: 14, color: cs.primary),
                      const SizedBox(width: 4),
                      Text(
                        '回到轨迹',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
