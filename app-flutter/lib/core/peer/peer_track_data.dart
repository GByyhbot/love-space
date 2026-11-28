/// 2.8.7 全量施工令 · 轨迹页数据（`GET /api/peer/track` v2）。
///
/// 服务端已完成滤波、距离、停留聚类、`peer_places` 命名与速度分段；
/// 客户端**只做投影与回放**，不重算聚合（避免双口径）。
///
/// 三档形态：
/// · exact  → `level=exact`，有 points / distance_m / segments；
/// · street → `level=street`，**points 恒空**、distance_m 为 null（精度不足
///   500m 不提供数字）、stays 坐标为 0.005° 网格；
/// · off    → `level=off`，`closed_off=true`（既有明示口径）。
library;

import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../api/api_client.dart';
import 'peer_report_api.dart' show PeerEventItem;
import 'peer_usage_data.dart' show PeerHalt;

/// 一个轨迹点（已滤波，GCJ-02）。
class PeerTrackPoint {
  const PeerTrackPoint({
    required this.ts,
    required this.lat,
    required this.lng,
    this.acc,
    this.speed,
    this.placeName = '',
  });

  final double ts;
  final double lat;
  final double lng;
  final double? acc;
  final double? speed;
  final String placeName;

  static PeerTrackPoint? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final lat = (raw['lat'] as num?)?.toDouble();
    final lng = (raw['lng'] as num?)?.toDouble();
    final ts = (raw['ts'] as num?)?.toDouble();
    if (lat == null || lng == null || ts == null) return null;
    return PeerTrackPoint(
      ts: ts,
      lat: lat,
      lng: lng,
      acc: (raw['acc'] as num?)?.toDouble(),
      speed: (raw['speed'] as num?)?.toDouble(),
      placeName: (raw['place_name'] ?? '').toString().trim(),
    );
  }
}

/// 一个停留点（服务端聚类 + 命名）。
class PeerTrackStay {
  const PeerTrackStay({
    required this.lat,
    required this.lng,
    required this.arrivedAt,
    this.leftAt,
    this.durationSec = 0,
    this.placeName = '',
  });

  final double lat;
  final double lng;
  final double arrivedAt;

  /// null = 仍在此处（当天最后一个停留点）。
  final double? leftAt;
  final int durationSec;

  /// 空串 = 尚未命中地名 → 端上写「停留点」，**不许编地名**。
  final String placeName;

  bool get ongoing => leftAt == null;
  String get displayName => placeName.isEmpty ? '停留点' : placeName;

  PeerTrackStay withPlaceName(String name) => PeerTrackStay(
        lat: lat,
        lng: lng,
        arrivedAt: arrivedAt,
        leftAt: leftAt,
        durationSec: durationSec,
        placeName: name.trim(),
      );

  static PeerTrackStay? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final lat = (raw['lat'] as num?)?.toDouble();
    final lng = (raw['lng'] as num?)?.toDouble();
    final arrived = (raw['arrived_at'] as num?)?.toDouble();
    if (lat == null || lng == null || arrived == null) return null;
    return PeerTrackStay(
      lat: lat,
      lng: lng,
      arrivedAt: arrived,
      leftAt: (raw['left_at'] as num?)?.toDouble(),
      durationSec: (raw['duration_sec'] as num?)?.toInt() ?? 0,
      placeName: (raw['place_name'] ?? '').toString().trim(),
    );
  }
}

/// 速度分段（服务端给区间，端上按 ts 决定实线/虚线）。
class PeerTrackSegment {
  const PeerTrackSegment({
    required this.type,
    required this.startTs,
    required this.endTs,
    this.distanceM = 0,
  });

  /// `still` / `walk` / `drive`。
  final String type;
  final double startTs;
  final double endTs;
  final double distanceM;

  bool get isDrive => type == 'drive';
  bool get isWalk => type == 'walk';

  static PeerTrackSegment? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final s = (raw['start_ts'] as num?)?.toDouble();
    final e = (raw['end_ts'] as num?)?.toDouble();
    if (s == null || e == null) return null;
    return PeerTrackSegment(
      type: (raw['type'] ?? '').toString(),
      startTs: s,
      endTs: e,
      distanceM: (raw['distance_m'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// 一侧的当日轨迹。
class PeerTrackSide {
  const PeerTrackSide({
    this.closedOff = false,
    this.halted = const PeerHalt(),
    this.level = 'off',
    this.points = const <PeerTrackPoint>[],
    this.stays = const <PeerTrackStay>[],
    this.segments = const <PeerTrackSegment>[],
    this.distanceM,
    this.displayPoints,
    this.displaySegments,
    this.displayDistanceM,
    this.latestLat,
    this.latestLng,
    this.latestUpdated,
    this.latestPlaceName = '',
  });

  final bool closedOff;
  final PeerHalt halted;
  final String level;
  final List<PeerTrackPoint> points;
  final List<PeerTrackStay> stays;
  final List<PeerTrackSegment> segments;

  /// street 档为 null（精度不足，不提供数字）。
  final double? distanceM;

  /// 二修甲：展示线（停留窗塌缩为停留锚点，移动段保留原有点列）。
  /// 兼容老版服务端：若缺省则为 null，自动回退 `points` / `segments` / `distanceM`。
  final List<PeerTrackPoint>? displayPoints;
  final List<PeerTrackSegment>? displaySegments;
  final double? displayDistanceM;

  final double? latestLat;
  final double? latestLng;
  final double? latestUpdated;
  final String latestPlaceName;

  List<PeerTrackPoint> get effectivePoints => displayPoints ?? points;
  List<PeerTrackSegment> get effectiveSegments => displaySegments ?? segments;
  double? get effectiveDistanceM {
    if (isStreet) return null;
    if (displayDistanceM != null) return displayDistanceM;
    if (displayPoints != null) return trackDistanceMeters(displayPoints!);
    return distanceM;
  }

  bool get hidden => closedOff || halted.halted;
  bool get isStreet => level == 'street';
  bool get hasTrack => effectivePoints.isNotEmpty;

  PeerTrackSide withStays(List<PeerTrackStay> resolvedStays) => PeerTrackSide(
        closedOff: closedOff,
        halted: halted,
        level: level,
        points: points,
        stays: resolvedStays,
        segments: segments,
        distanceM: distanceM,
        displayPoints: displayPoints,
        displaySegments: displaySegments,
        displayDistanceM: displayDistanceM,
        latestLat: latestLat,
        latestLng: latestLng,
        latestUpdated: latestUpdated,
        latestPlaceName: latestPlaceName,
      );

  static PeerTrackSide fromJson(Object? raw) {
    final j = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
    List<T> list<T>(Object? v, T? Function(Object?) parse) {
      if (v is! List) return const [];
      return v.map(parse).whereType<T>().toList(growable: false);
    }

    final latest = (j['latest'] as Map?)?.cast<String, dynamic>();
    final hasDispPts = j.containsKey('display_points') && j['display_points'] is List;
    final hasDispSegs =
        j.containsKey('display_segments') && j['display_segments'] is List;
    return PeerTrackSide(
      closedOff: j['closed_off'] == true,
      halted: PeerHalt.fromJson(j['halted']),
      level: (j['level'] ?? (j['closed_off'] == true ? 'off' : 'exact')).toString(),
      points: list(j['points'], PeerTrackPoint.fromJson),
      stays: list(j['stays'], PeerTrackStay.fromJson),
      segments: list(j['segments'], PeerTrackSegment.fromJson),
      distanceM: (j['distance_m'] as num?)?.toDouble(),
      displayPoints:
          hasDispPts ? list(j['display_points'], PeerTrackPoint.fromJson) : null,
      displaySegments: hasDispSegs
          ? list(j['display_segments'], PeerTrackSegment.fromJson)
          : null,
      displayDistanceM: (j['display_distance_m'] as num?)?.toDouble(),
      latestLat: (latest?['lat'] as num?)?.toDouble(),
      latestLng: (latest?['lng'] as num?)?.toDouble(),
      latestUpdated: (latest?['updated'] as num?)?.toDouble(),
      latestPlaceName: (latest?['place_name'] ?? '').toString().trim(),
    );
  }
}

/// 按给定点列计算总折线距离（米）。
double trackDistanceMeters(List<PeerTrackPoint> pts) {
  if (pts.length < 2) return 0.0;
  var total = 0.0;
  for (var i = 1; i < pts.length; i++) {
    total += _stayDistMeters(pts[i - 1].lat, pts[i - 1].lng, pts[i].lat, pts[i].lng);
  }
  return total;
}

/// 停留点地名真实来源解析（绝不前端现编）：
/// 1. 空间内已命名的停留点名称（[PeerTrackStay.placeName] / `peer_places`）；
/// 2. 停留时段 `[arrivedAt, leftAt]` 内轨迹点自带的系统地名（`points[].place_name`）；
/// 3. 今日卡同源的 `latest.place_name`（150m 围栏半径内且优先 ongoing/临近停留点）
///    或该停留时段内含地名的主动报备；
/// 4. 均未命中时返回 `'停留点'`。
String resolveStayPlaceName(
  PeerTrackStay stay, {
  List<PeerTrackPoint> points = const <PeerTrackPoint>[],
  double? latestLat,
  double? latestLng,
  String latestPlaceName = '',
  List<PeerEventItem> events = const <PeerEventItem>[],
}) {
  final direct = stay.placeName.trim();
  if (direct.isNotEmpty) return direct;

  final endTs = stay.leftAt ?? double.infinity;
  for (var i = points.length - 1; i >= 0; i--) {
    final pt = points[i];
    if (pt.ts >= stay.arrivedAt && pt.ts <= endTs) {
      final pn = pt.placeName.trim();
      if (pn.isNotEmpty) return pn;
    }
  }

  final latestName = latestPlaceName.trim();
  if (latestName.isNotEmpty &&
      latestLat != null &&
      latestLng != null &&
      _stayDistMeters(stay.lat, stay.lng, latestLat, latestLng) <= 150.0) {
    return latestName;
  }

  for (final e in events) {
    if (!e.isManualReport) continue;
    final pn = e.placeName.trim();
    if (pn.isEmpty) continue;
    if (e.ts >= stay.arrivedAt - 300 && e.ts <= endTs + 300) {
      return pn;
    }
  }

  return '停留点';
}

PeerTrackSide resolveTrackSideStays(
  PeerTrackSide side, {
  double? statusLatestLat,
  double? statusLatestLng,
  String statusLatestPlaceName = '',
  List<PeerEventItem> sideEvents = const <PeerEventItem>[],
}) {
  if (side.stays.isEmpty) return side;
  final lat = side.latestLat ?? statusLatestLat;
  final lng = side.latestLng ?? statusLatestLng;
  final placeName = side.latestPlaceName.isNotEmpty
      ? side.latestPlaceName
      : statusLatestPlaceName;

  var changed = false;
  final next = <PeerTrackStay>[];
  for (final s in side.stays) {
    final resolved = resolveStayPlaceName(
      s,
      points: side.points,
      latestLat: lat,
      latestLng: lng,
      latestPlaceName: placeName,
      events: sideEvents,
    );
    if (resolved != '停留点' && resolved != s.placeName) {
      changed = true;
      next.add(s.withPlaceName(resolved));
    } else {
      next.add(s);
    }
  }
  return changed ? side.withStays(List<PeerTrackStay>.unmodifiable(next)) : side;
}

double _stayDistMeters(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLng = (lng2 - lng1) * math.pi / 180.0;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180.0) *
          math.cos(lat2 * math.pi / 180.0) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

class PeerTrackDay {
  const PeerTrackDay({required this.date, required this.mine, required this.peer});
  final String date;
  final PeerTrackSide mine;
  final PeerTrackSide peer;

  static PeerTrackDay fromJson(Map<String, dynamic> j) => PeerTrackDay(
        date: (j['date'] ?? '').toString(),
        mine: PeerTrackSide.fromJson(j['mine']),
        peer: PeerTrackSide.fromJson(j['peer']),
      );
}

/// 拉某日轨迹（对方侧已按对方 policy 裁剪）。
Future<PeerTrackDay> fetchPeerTrack(Dio dio, {String date = ''}) async {
  final r = await dio.get('/api/peer/track', queryParameters: {
    if (date.isNotEmpty) 'date': date,
  });
  final err = writeResponseError(r);
  if (err != null) throw PeerTrackException(err);
  final raw = r.data;
  if (raw is! Map) throw const PeerTrackException(genericErrorText);
  return PeerTrackDay.fromJson(raw.cast<String, dynamic>());
}

class PeerTrackException implements Exception {
  const PeerTrackException(this.detail);
  final String detail;

  @override
  String toString() => detail;
}
