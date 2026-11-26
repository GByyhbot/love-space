/// 2.8.0 报备信息展示层（只读）：`/api/peer/status` + `/api/peer/track` 解析、
/// Haversine 距离、相对/绝对时间文案。
///
/// 🔴 边界（三句）：
/// ① **不新增后端接口、不新增轮询**——本模块只读既有 peer 两个 GET，一次拉取；
///    页面打开拉一次，页内 SSE `peer` 段到达时再拉一次（静默）。
/// ② 坐标口径：后端 `peer_location_latest` 入库即 **GCJ-02**（原生端上
///    WGS-84→GCJ-02 转换，见 PeerLocNative.kt:457 注释），本模块不再做任何
///    坐标转换；距离用 Haversine 直接算，仅用于「约」级展示，不做导航精度承诺。
/// ③ 失败语义：任一路拉取失败一律抛 [PeerReportException]，由调用方决定
///    「状态未知」呈现；本模块**不缓存、不回落旧值**（不许拿旧缓存冒充实时）。
library;

import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../api/api_client.dart';
import 'peer_policy.dart';
import 'peer_usage_data.dart' show PeerCurrentApp, PeerHalt;

/// 拉取失败（带服务端 detail 原文；网络层失败由 dio 异常直接透传）。
class PeerReportException implements Exception {
  const PeerReportException(this.detail);
  final String detail;

  @override
  String toString() => detail;
}

/// `peer_location_latest` 单行（双方同构；`user` 字段本层不用）。
class PeerLatest {
  const PeerLatest({
    required this.lat,
    required this.lng,
    required this.updated,
    this.acc,
    this.speed,
    this.battery,
    this.charging,
    this.net,
    this.wifi,
    this.stateUpdated,
  });

  final double? lat;
  final double? lng;

  /// 服务端记录时间（unix 秒，上报落库时刻）——「最近一次报备时间」唯一来源。
  final double? updated;
  final double? acc;
  final double? speed;

  /// 电量百分比原值（原生读不到时为 -1 → 本层归一为 null）。
  final int? battery;

  /// 充电状态原值；缺字段 = 未知（不推断）。
  final bool? charging;

  /// 网络类型原值（wifi / cell / none）。
  final String? net;
  final String? wifi;

  /// 2.8.7：状态事件最后一次刷新快照的时刻（与定位的 `updated` 分开）。
  /// 定位停了但状态还在动时，靠它说明「状态仍然新鲜」。
  final double? stateUpdated;

  static PeerLatest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    final lat = (j['lat'] as num?)?.toDouble();
    final lng = (j['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null; // 无坐标的行不当作「有报备」
    final batteryRaw = (j['battery'] as num?)?.toInt();
    final netRaw = (j['net'] ?? '').toString();
    final wifiRaw = (j['wifi'] ?? '').toString();
    return PeerLatest(
      lat: lat,
      lng: lng,
      updated: (j['updated'] as num?)?.toDouble(),
      acc: (j['acc'] as num?)?.toDouble(),
      speed: (j['speed'] as num?)?.toDouble(),
      // 原生读不到电量给 -1，负值视为未知，不显示「电量 -1%」
      battery: (batteryRaw == null || batteryRaw < 0) ? null : batteryRaw,
      charging: j['charging'] is bool ? j['charging'] as bool : null,
      net: netRaw.isEmpty ? null : netRaw,
      wifi: wifiRaw.isEmpty ? null : wifiRaw,
      stateUpdated: (j['state_updated'] as num?)?.toDouble(),
    );
  }
}

/// `GET /api/peer/status` 归一结果。
class PeerStatusData {
  const PeerStatusData({
    required this.revision,
    required this.mine,
    required this.peer,
    required this.peerEnabled,
    required this.peerClosedOff,
    this.mineEventsOn = true,
    this.peerHalt = const PeerHalt(),
    this.peerCurrentApp,
    this.myPolicy = PeerPolicy.defaults,
    this.peerPolicy = PeerPolicy.defaults,
  });

  final int revision;

  /// 我的最新状态（null = 我方尚无任何上报）。
  final PeerLatest? mine;

  /// 对方最新状态（null = 对方尚无任何上报）。
  final PeerLatest? peer;

  /// 对方定位共享开关是否开（对等口径：关闭态明示，不当作故障）。
  final bool peerEnabled;
  final bool peerClosedOff;

  /// 我方 `events` 共享开关（2.8.7 采集状态三态行用；缺字段按开处理）。
  final bool mineEventsOn;

  /// 对方停用态（完全关闭 / 暂停中）——停用时 location 恒 null。
  final PeerHalt peerHalt;

  /// 对方「正在使用」（仅对方 app_level=stream 时给）。
  final PeerCurrentApp? peerCurrentApp;

  /// 双方分档 policy（我自己那份用于设置页回填与预览）。
  final PeerPolicy myPolicy;
  final PeerPolicy peerPolicy;

  static PeerStatusData fromJson(Map<String, dynamic> j) {
    final mine = (j['mine'] as Map?)?.cast<String, dynamic>() ?? const {};
    final peer = (j['peer'] as Map?)?.cast<String, dynamic>() ?? const {};
    return PeerStatusData(
      revision: (j['revision'] as num?)?.toInt() ?? 0,
      mine: PeerLatest.fromJson(mine['location']),
      peer: PeerLatest.fromJson(peer['location']),
      peerEnabled: peer['enabled'] == true,
      peerClosedOff: peer['closed_off'] == true,
      mineEventsOn:
          (mine['settings'] as Map?)?['events'] is bool
              ? (mine['settings'] as Map)['events'] as bool
              : true,
      peerHalt: PeerHalt.fromJson(peer['halted']),
      peerCurrentApp: PeerCurrentApp.fromJson(peer['current_app']),
      myPolicy: PeerPolicy.fromJson(mine['policy']),
      peerPolicy: PeerPolicy.fromJson(peer['policy']),
    );
  }
}

/// 一屏所需的全部数据：status + （可选）对方今日报备点数。
class PeerReport {
  const PeerReport({required this.status, this.peerTodayPoints});

  final PeerStatusData status;

  /// 对方今日报备点数（`/api/peer/track` 当日 points 计数）。
  /// null = 该接口未给出（对方 track 共享关闭 / 该次请求失败）→ 该行整行不显示，
  /// 不显示 0、不显示估算值。
  final int? peerTodayPoints;
}

/// 一次完整拉取：status 必成功；track 尽力而为（失败只丢「今日点数」一行）。
Future<PeerReport> fetchPeerReport(Dio dio, {String date = ''}) async {
  final r = await dio.get('/api/peer/status');
  final err = writeResponseError(r);
  if (err != null) throw PeerReportException(err);
  final raw = r.data;
  if (raw is! Map) throw const PeerReportException(genericErrorText);
  final status = PeerStatusData.fromJson(raw.cast<String, dynamic>());

  int? todayPoints;
  try {
    final t = await dio.get('/api/peer/track', queryParameters: {
      if (date.isNotEmpty) 'date': date,
    });
    // 4xx 由 validateAppStatus 放行 → 必须显式判定（7-C 错误通道口径）
    if (writeResponseError(t) == null && t.data is Map) {
      final peer = ((t.data as Map)['peer'] as Map?)?.cast<String, dynamic>();
      if (peer != null && peer['closed_off'] != true) {
        final pts = peer['points'];
        if (pts is List) todayPoints = pts.length;
      }
    }
  } catch (_) {
    // 轨迹接口失败不影响主块：该行不显示（不冒充 0）
  }

  return PeerReport(status: status, peerTodayPoints: todayPoints);
}

/// 球面距离（米，Haversine）。两点均按 GCJ-02 直接代入——
/// GCJ-02 是全境平滑偏移，同城两点距离误差在「约」级展示范围内可忽略；
/// 本函数只服务「距我约 X」，不用于导航。
double haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  const earthRadius = 6371000.0;
  double rad(double d) => d * math.pi / 180.0;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) *
          math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * earthRadius * math.asin(math.min(1.0, math.sqrt(a)));
}

/// 距离展示：<1km 用米（取整），≥1km 用公里（保留一位小数）。
String formatDistance(double meters) {
  if (meters < 1000) return '${meters.round()} 米';
  return '${(meters / 1000).toStringAsFixed(1)} 公里';
}

/// 「距我约 X」整行文案；任一方无坐标时返回 null（调用方整行不渲染）。
String? distanceLine(PeerLatest? mine, PeerLatest? peer) {
  if (mine?.lat == null || mine?.lng == null) return null;
  if (peer?.lat == null || peer?.lng == null) return null;
  final m = haversineMeters(mine!.lat!, mine.lng!, peer!.lat!, peer.lng!);
  return '距我约 ${formatDistance(m)}';
}

/// 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前 / 更早给日期。
String relativeTimeZh(double? unixSeconds, {DateTime? now}) {
  if (unixSeconds == null || unixSeconds <= 0) return '未知';
  final t = DateTime.fromMillisecondsSinceEpoch((unixSeconds * 1000).round());
  final diff = (now ?? DateTime.now()).difference(t);
  final sec = diff.inSeconds;
  if (sec < 0) return '刚刚'; // 时钟漂移不显示「-3 分钟前」
  if (sec < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 8) return '${diff.inDays} 天前';
  return absoluteTimeZh(unixSeconds);
}

/// 绝对时间（本地时区）：yyyy-MM-dd HH:mm。
String absoluteTimeZh(double? unixSeconds) {
  if (unixSeconds == null || unixSeconds <= 0) return '未知';
  final t = DateTime.fromMillisecondsSinceEpoch((unixSeconds * 1000).round());
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// 卡面摘要一行（施工令一·入口卡）：
/// 有数据 → 「TA · 12 分钟前报备 · 电量 82%」；对方无数据 → 「TA 还没有
/// 报备数据」；拉取失败 → 「状态未知」（**不许拿旧缓存冒充实时**）。
/// 对方关闭共享 → 「TA 已关闭位置共享」（对等口径：明示，不显示假故障）。
String peerSummaryLine(PeerStatusData? status,
    {DateTime? now, bool failed = false}) {
  if (failed || status == null) return '状态未知';
  if (status.peerClosedOff) return 'TA 已关闭位置共享';
  final p = status.peer;
  if (p == null) return 'TA 还没有报备数据';
  final rel = '${relativeTimeZh(p.updated, now: now)}报备';
  final b = p.battery;
  return b == null ? 'TA · $rel' : 'TA · $rel · 电量 $b%';
}

/// 电量展示：null → 未知（不显示 0%）。
String batteryText(int? battery) => battery == null ? '未知' : '$battery%';

/// 充电状态展示：原值直译（true/false/未知），不做推断。
String chargingText(bool? charging) =>
    charging == null ? '未知' : (charging ? '充电中' : '未充电');

/// 经纬度展示（GCJ-02，6 位小数 ≈ 0.1m 级，够「最近一点」用）。
String coordText(PeerLatest? l) {
  if (l?.lat == null || l?.lng == null) return '未知';
  return '${l!.lat!.toStringAsFixed(6)}, ${l.lng!.toStringAsFixed(6)}';
}
