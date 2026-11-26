/// 2.8.7 全量施工令 · 手机页数据（`GET /api/peer/usage-daily`）与停用态模型。
///
/// 🔴 解析容缺：所有字段都可能因**属主分档**而缺失（screen_only 无分布、
/// top5 无会话、off 无整块）——缺就是 `null`，**绝不用 0 冒充**。
/// 这与「取不到就整项不显示」的呈现铁律一一对应。
library;

import 'package:dio/dio.dart';

import '../api/api_client.dart';

/// 停用态（完全关闭 / 暂停中）——各读接口同构返回这一段。
class PeerHalt {
  const PeerHalt({this.halted = false, this.reason = '', this.until});

  final bool halted;

  /// `off` = 完全关闭；`paused` = 暂停中；空串 = 未停用。
  final String reason;
  final double? until;

  bool get isOff => halted && reason == 'off';
  bool get isPaused => halted && reason == 'paused';

  static PeerHalt fromJson(Object? raw) {
    if (raw is! Map) return const PeerHalt();
    final j = raw.cast<String, dynamic>();
    return PeerHalt(
      halted: j['halted'] == true,
      reason: (j['reason'] ?? '').toString(),
      until: (j['until'] as num?)?.toDouble(),
    );
  }
}

/// 正在使用的应用（`usage.now`，仅精确时间流档给）。
class PeerCurrentApp {
  const PeerCurrentApp({
    required this.app,
    this.masked = false,
    this.since,
    this.ts,
  });

  final String app;
  final bool masked;
  final double? since;
  final double? ts;

  static PeerCurrentApp? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    final app = (j['app'] ?? '').toString().trim();
    if (app.isEmpty) return null;
    return PeerCurrentApp(
      app: app,
      masked: j['masked'] == true,
      since: (j['since'] as num?)?.toDouble(),
      ts: (j['ts'] as num?)?.toDouble(),
    );
  }
}

/// Top 应用一条。
class PeerTopApp {
  const PeerTopApp({required this.app, required this.sec});
  final String app;
  final int sec;

  static PeerTopApp? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final app = (raw['app'] ?? '').toString().trim();
    if (app.isEmpty) return null;
    return PeerTopApp(app: app, sec: (raw['sec'] as num?)?.toInt() ?? 0);
  }
}

/// 一条应用会话。
class PeerUsageSession {
  const PeerUsageSession({
    required this.app,
    required this.sec,
    this.start,
    this.end,
    this.ts,
    this.masked = false,
    this.folded = false,
  });

  final String app;
  final int sec;
  final double? start;
  final double? end;
  final double? ts;
  final bool masked;
  final bool folded;

  static PeerUsageSession? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    final app = (j['app'] ?? '').toString().trim();
    if (app.isEmpty) return null;
    return PeerUsageSession(
      app: app,
      sec: (j['sec'] as num?)?.toInt() ?? 0,
      start: (j['start'] as num?)?.toDouble(),
      end: (j['end'] as num?)?.toDouble(),
      ts: (j['ts'] as num?)?.toDouble(),
      masked: j['masked'] == true,
      folded: j['folded'] == true,
    );
  }
}

/// 网络切换记录一条。
class PeerNetEvent {
  const PeerNetEvent({required this.ts, required this.net, this.ssid = ''});
  final double ts;
  final String net;
  final String ssid;

  static PeerNetEvent? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return PeerNetEvent(
      ts: (raw['ts'] as num?)?.toDouble() ?? 0,
      net: (raw['net'] ?? '').toString(),
      ssid: (raw['ssid'] ?? '').toString(),
    );
  }
}

/// 一侧的使用汇总（字段缺失 = 被分档裁掉）。
class PeerUsageSide {
  const PeerUsageSide({
    this.closedOff = false,
    this.halted = const PeerHalt(),
    this.screenSec,
    this.unlocks,
    this.longestSessionSec,
    this.yesterdayScreenSec,
    this.hourly,
    this.topApps,
    this.sessions,
    this.foldedCount,
    this.networkEvents,
    this.currentApp,
  });

  final bool closedOff;
  final PeerHalt halted;

  /// 被 usage off / halted 遮挡时全为 null（不是 0）。
  final int? screenSec;
  final int? unlocks;
  final int? longestSessionSec;
  final int? yesterdayScreenSec;

  /// 24 元分布（screen_only 档没有）。
  final List<int>? hourly;
  final List<PeerTopApp>? topApps;
  final List<PeerUsageSession>? sessions;
  final int? foldedCount;
  final List<PeerNetEvent>? networkEvents;
  final PeerCurrentApp? currentApp;

  bool get hidden => closedOff || halted.halted;

  static PeerUsageSide fromJson(Object? raw) {
    final j = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
    List<T>? list<T>(Object? v, T? Function(Object?) parse) {
      if (v is! List) return null;
      return v.map(parse).whereType<T>().toList(growable: false);
    }

    final hourlyRaw = j['hourly'];
    return PeerUsageSide(
      closedOff: j['closed_off'] == true,
      halted: PeerHalt.fromJson(j['halted']),
      screenSec: (j['screen_sec'] as num?)?.toInt(),
      unlocks: (j['unlocks'] as num?)?.toInt(),
      longestSessionSec: (j['longest_session_sec'] as num?)?.toInt(),
      yesterdayScreenSec: (j['yesterday_screen_sec'] as num?)?.toInt(),
      hourly: hourlyRaw is List
          ? hourlyRaw
              .map((e) => e is num ? e.toInt() : 0)
              .toList(growable: false)
          : null,
      topApps: list(j['top_apps'], PeerTopApp.fromJson),
      sessions: list(j['sessions'], PeerUsageSession.fromJson),
      foldedCount: (j['folded_count'] as num?)?.toInt(),
      networkEvents: list(j['network_events'], PeerNetEvent.fromJson),
      currentApp: PeerCurrentApp.fromJson(j['current_app']),
    );
  }
}

/// 一日双方使用汇总。
class PeerUsageDay {
  const PeerUsageDay({required this.date, required this.mine, required this.peer});
  final String date;
  final PeerUsageSide mine;
  final PeerUsageSide peer;

  static PeerUsageDay fromJson(Map<String, dynamic> j) => PeerUsageDay(
        date: (j['date'] ?? '').toString(),
        mine: PeerUsageSide.fromJson(j['mine']),
        peer: PeerUsageSide.fromJson(j['peer']),
      );
}

/// 拉当日使用汇总（对方侧已按对方 policy 裁剪，停用给 halted）。
Future<PeerUsageDay> fetchPeerUsageDaily(Dio dio, {String date = ''}) async {
  final r = await dio.get('/api/peer/usage-daily', queryParameters: {
    if (date.isNotEmpty) 'date': date,
  });
  final err = writeResponseError(r);
  if (err != null) throw PeerUsageException(err);
  final raw = r.data;
  if (raw is! Map) throw const PeerUsageException(genericErrorText);
  return PeerUsageDay.fromJson(raw.cast<String, dynamic>());
}

class PeerUsageException implements Exception {
  const PeerUsageException(this.detail);
  final String detail;

  @override
  String toString() => detail;
}
