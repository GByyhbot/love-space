/// 2.8.7 全量施工令 · 「对方视角预览」的裁剪逻辑（纯函数，与服务端同口径）。
///
/// 🔴 为什么要客户端再实现一遍：服务端裁剪发生在**响应**里，预览要把「我的」
/// 完整数据先拿回来再按**我的 policy** 裁一次，才能提前看到对方会看到什么。
/// 两套实现必须同口径——本文件的每条规则都与 `app/peer.py` / `app/peer_agg.py`
/// 的对应分支一一对照，并用同一份夹具做对拍测试（`peer_preview_285_test`）。
library;

import '../../core/peer/peer_policy.dart';
import '../../core/peer/peer_track_data.dart';
import '../../core/peer/peer_usage_data.dart';

/// 我的使用数据 → 对方能看到的形态（字段缺失即 null，不写 0）。
PeerUsageSide previewUsage(PeerUsageSide mine, PeerPolicy policy) {
  if (policy.usageLevel == UsageLevel.off) {
    return const PeerUsageSide(closedOff: true);
  }
  final screenOnly = policy.usageLevel == UsageLevel.screenOnly;
  final appOff = policy.appLevel == AppLevel.off;
  final stream = policy.appLevel == AppLevel.stream;

  return PeerUsageSide(
    screenSec: mine.screenSec,
    unlocks: mine.unlocks,
    longestSessionSec: mine.longestSessionSec,
    yesterdayScreenSec: mine.yesterdayScreenSec,
    // screen_only：分布整块裁掉（服务端同分支不返回 hourly）
    hourly: screenOnly ? null : mine.hourly,
    topApps: (screenOnly || appOff) ? null : mine.topApps,
    sessions: (screenOnly || !stream) ? null : mine.sessions,
    foldedCount: (screenOnly || !stream) ? null : mine.foldedCount,
    networkEvents: policy.netLevel == NetLevel.off
        ? null
        : (mine.networkEvents ?? const <PeerNetEvent>[])
            .map((e) => PeerNetEvent(
                  ts: e.ts,
                  net: e.net,
                  ssid: policy.netLevel == NetLevel.ssid ? e.ssid : '',
                ))
            .toList(growable: false),
    // 「正在使用」属时间流级细节：只有「完整 + 时间流」两档都满足才给
    currentApp: (stream && !screenOnly) ? mine.currentApp : null,
  );
}

/// 我的轨迹 → 对方能看到的形态。
PeerTrackSide previewTrack(PeerTrackSide mine, PeerPolicy policy) {
  switch (policy.locLevel) {
    case LocLevel.off:
      return const PeerTrackSide(closedOff: true, level: 'off');
    case LocLevel.street:
      // 无点列、无分段、无精确距离；停留点坐标网格化（服务端已网格化，
      // 预览再圆一次保证「同一份数据两条路径同结果」）
      return PeerTrackSide(
        level: 'street',
        points: const <PeerTrackPoint>[],
        segments: const <PeerTrackSegment>[],
        distanceM: null,
        stays: mine.stays
            .map((s) => PeerTrackStay(
                  lat: _grid(s.lat),
                  lng: _grid(s.lng),
                  arrivedAt: s.arrivedAt,
                  leftAt: s.leftAt,
                  durationSec: s.durationSec,
                  placeName: s.placeName,
                ))
            .toList(growable: false),
        latestLat: mine.latestLat == null ? null : _grid(mine.latestLat!),
        latestLng: mine.latestLng == null ? null : _grid(mine.latestLng!),
        latestUpdated: mine.latestUpdated,
      );
    case LocLevel.exact:
      return mine;
  }
}

double _grid(double v) => (v / 0.005).round() * 0.005;

/// 我的状态行 → 对方能看到的一行字（预览页顶部用）。
String previewLiveLine(PeerCurrentApp? app, PeerPolicy policy) {
  if (app == null || policy.appLevel != AppLevel.stream) return '';
  return '正在使用 ${app.app}';
}
