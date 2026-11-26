/// 2.8.7 全量施工令 · 轨迹回放（纯函数，可单测）。
///
/// 回放不依赖任何计时器：页面只喂一个「当前时刻 t」，这里算出光点位置、
/// 瞬时速度、该时刻的网络与电量读数。这样滑块拖动与自动播放共用一条路径，
/// 也就能脱离 Widget 做断言。
library;

import 'dart:math' as math;

import '../../core/peer/peer_report_data.dart' show haversineMeters;
import '../../core/peer/peer_track_data.dart';

/// 光点位置（经纬度）。
class ReplayPoint {
  const ReplayPoint(this.lat, this.lng);
  final double lat;
  final double lng;
}

/// 两个相邻点之间按时间线性插值。
///
/// 边界：t 早于首点 → 首点；晚于末点 → 末点；只有 1 个点 → 该点；空 → null。
ReplayPoint? pointAt(List<PeerTrackPoint> points, double t) {
  if (points.isEmpty) return null;
  if (points.length == 1) {
    return ReplayPoint(points.first.lat, points.first.lng);
  }
  if (t <= points.first.ts) {
    return ReplayPoint(points.first.lat, points.first.lng);
  }
  if (t >= points.last.ts) {
    return ReplayPoint(points.last.lat, points.last.lng);
  }
  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i];
    final b = points[i + 1];
    if (t >= a.ts && t <= b.ts) {
      final span = b.ts - a.ts;
      final k = span <= 0 ? 0.0 : (t - a.ts) / span;
      return ReplayPoint(
        a.lat + (b.lat - a.lat) * k,
        a.lng + (b.lng - a.lng) * k,
      );
    }
  }
  return ReplayPoint(points.last.lat, points.last.lng);
}

/// 瞬时速度（km/h）：取 t 所在区间的两点速度；区间时长为 0 → null。
double? speedKmhAt(List<PeerTrackPoint> points, double t) {
  if (points.length < 2) return null;
  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i];
    final b = points[i + 1];
    if (t >= a.ts && t <= b.ts) {
      final dt = b.ts - a.ts;
      if (dt <= 0) return null;
      final m = haversineMeters(a.lat, a.lng, b.lat, b.lng);
      return m / dt * 3.6;
    }
  }
  // t 在首点之前 / 末点之后：用相邻首/末区间，不编造静止
  final a = t <= points.first.ts ? points.first : points[points.length - 2];
  final b = t <= points.first.ts ? points[1] : points.last;
  final dt = b.ts - a.ts;
  if (dt <= 0) return null;
  return haversineMeters(a.lat, a.lng, b.lat, b.lng) / dt * 3.6;
}

/// 该时刻「最近一次已发生」的网络记录（按 ts 升序传入，返回 ts<=t 的最后一条）。
PeerNetRecord? netAt(List<PeerNetRecord> records, double t) {
  PeerNetRecord? hit;
  for (final r in records) {
    if (r.ts <= t) {
      hit = r;
    } else {
      break;
    }
  }
  return hit;
}

/// 该时刻的电量（ts<=t 的最后一条；没有就给 null，不显示假值）。
int? batteryAt(List<BatteryReading> readings, double t) {
  int? hit;
  for (final r in readings) {
    if (r.ts <= t) {
      hit = r.level;
    } else {
      break;
    }
  }
  return hit;
}

/// 网络读数（页面用的轻量结构，与 usage 的 PeerNetEvent 同构但独立，
/// 避免轨迹页为了一个读数去依赖手机页的数据模型）。
class PeerNetRecord {
  const PeerNetRecord({required this.ts, required this.net, this.ssid = ''});
  final double ts;
  final String net;
  final String ssid;

  String get label {
    switch (net) {
      case 'wifi':
        return ssid.isEmpty ? 'Wi-Fi' : 'Wi-Fi（$ssid）';
      case 'cell':
        return '移动数据';
      case 'none':
        return '无网络';
    }
    return net.isEmpty ? '未知' : net;
  }
}

/// 电量读数。
class BatteryReading {
  const BatteryReading({required this.ts, required this.level});
  final double ts;
  final int level;
}

/// 进度（0..1）：用于滑块与光点定位；首末时刻相同 → 0。
double replayProgress(List<PeerTrackPoint> points, double t) {
  if (points.length < 2) return 0;
  final start = points.first.ts;
  final end = points.last.ts;
  if (end <= start) return 0;
  return ((t - start) / (end - start)).clamp(0.0, 1.0);
}

/// 进度 → 时刻（滑块 onChanged 用）。
double timeAtProgress(List<PeerTrackPoint> points, double p) {
  if (points.isEmpty) return 0;
  if (points.length == 1) return points.first.ts;
  final start = points.first.ts;
  final end = points.last.ts;
  return start + (end - start) * p.clamp(0.0, 1.0);
}

/// 画布投影（等距圆柱 + fit bounds）。返回归一化坐标 0..1（y 向下）。
///
/// 空点列返回 null；单点给中心 (0.5,0.5)；跨度为 0 时按 1 处理，防除零。
class TrackProjector {
  TrackProjector(List<PeerTrackPoint> points) {
    if (points.isEmpty) return;
    var minLat = points.first.lat, maxLat = points.first.lat;
    var minLng = points.first.lng, maxLng = points.first.lng;
    for (final p in points) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLng = math.min(minLng, p.lng);
      maxLng = math.max(maxLng, p.lng);
    }
    _minLat = minLat;
    _minLng = minLng;
    _spanLat = math.max(maxLat - minLat, 1e-6);
    _spanLng = math.max(maxLng - minLng, 1e-6);
    _valid = true;
  }

  bool _valid = false;
  double _minLat = 0, _minLng = 0, _spanLat = 1, _spanLng = 1;

  bool get valid => _valid;

  /// 归一化坐标（0..1，y 轴向下：纬度越大越靠上）。
  Offset2 project(double lat, double lng) => Offset2(
        ((lng - _minLng) / _spanLng).clamp(0.0, 1.0),
        (1 - (lat - _minLat) / _spanLat).clamp(0.0, 1.0),
      );
}

/// 轻量二维点（不依赖 Flutter，纯函数测试可用）。
class Offset2 {
  const Offset2(this.x, this.y);
  final double x;
  final double y;

  @override
  String toString() => 'Offset2($x, $y)';

  @override
  bool operator ==(Object other) =>
      other is Offset2 &&
      (other.x - x).abs() < 1e-9 &&
      (other.y - y).abs() < 1e-9;

  @override
  int get hashCode => Object.hash(x, y);
}
