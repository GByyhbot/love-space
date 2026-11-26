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

import 'package:dio/dio.dart';

import '../api/api_client.dart';
import 'peer_usage_data.dart' show PeerHalt;

/// 一个轨迹点（已滤波，GCJ-02）。
class PeerTrackPoint {
  const PeerTrackPoint({
    required this.ts,
    required this.lat,
    required this.lng,
    this.acc,
    this.speed,
  });

  final double ts;
  final double lat;
  final double lng;
  final double? acc;
  final double? speed;

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

  /// 空串 = `peer_places` 没命中 → 端上写「停留点」，**不许编地名**。
  final String placeName;

  bool get ongoing => leftAt == null;
  String get displayName => placeName.isEmpty ? '停留点' : placeName;

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
      placeName: (raw['place_name'] ?? '').toString(),
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
    this.latestLat,
    this.latestLng,
    this.latestUpdated,
  });

  final bool closedOff;
  final PeerHalt halted;
  final String level;
  final List<PeerTrackPoint> points;
  final List<PeerTrackStay> stays;
  final List<PeerTrackSegment> segments;

  /// street 档为 null（精度不足，不提供数字）。
  final double? distanceM;
  final double? latestLat;
  final double? latestLng;
  final double? latestUpdated;

  bool get hidden => closedOff || halted.halted;
  bool get isStreet => level == 'street';
  bool get hasTrack => points.isNotEmpty;

  static PeerTrackSide fromJson(Object? raw) {
    final j = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
    List<T> list<T>(Object? v, T? Function(Object?) parse) {
      if (v is! List) return const [];
      return v.map(parse).whereType<T>().toList(growable: false);
    }

    final latest = (j['latest'] as Map?)?.cast<String, dynamic>();
    return PeerTrackSide(
      closedOff: j['closed_off'] == true,
      halted: PeerHalt.fromJson(j['halted']),
      level: (j['level'] ?? (j['closed_off'] == true ? 'off' : 'exact')).toString(),
      points: list(j['points'], PeerTrackPoint.fromJson),
      stays: list(j['stays'], PeerTrackStay.fromJson),
      segments: list(j['segments'], PeerTrackSegment.fromJson),
      distanceM: (j['distance_m'] as num?)?.toDouble(),
      latestLat: (latest?['lat'] as num?)?.toDouble(),
      latestLng: (latest?['lng'] as num?)?.toDouble(),
      latestUpdated: (latest?['updated'] as num?)?.toDouble(),
    );
  }
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
