/// 2.8.7 全量施工令 · 对方视角预览裁剪（施工令 §六·12：与服务端同夹具同结果）。
///
/// 这里用**同一份夹具**断言客户端裁剪的每一格，与 `tests/test_peer_policy_288.py`
/// 的裁剪矩阵逐条对应；两边任何一侧改了规则，另一侧必须同步（否则预览说谎）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/peer/peer_policy.dart';
import 'package:love_space/core/peer/peer_track_data.dart';
import 'package:love_space/core/peer/peer_usage_data.dart';
import 'package:love_space/features/together/peer_preview.dart';

PeerUsageSide _usage() => const PeerUsageSide(
      screenSec: 3900,
      unlocks: 12,
      longestSessionSec: 1800,
      yesterdayScreenSec: 3000,
      hourly: [0, 0, 0, 0, 0, 0, 0, 0, 100, 200, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0],
      topApps: [PeerTopApp(app: '微信', sec: 600)],
      sessions: [PeerUsageSession(app: '微信', sec: 600, masked: false)],
      foldedCount: 2,
      networkEvents: [PeerNetEvent(ts: 1, net: 'wifi', ssid: 'home')],
      currentApp: PeerCurrentApp(app: '微信'),
    );

PeerTrackSide _track() => const PeerTrackSide(
      level: 'exact',
      points: [
        PeerTrackPoint(ts: 1, lat: 39.9, lng: 116.4),
        PeerTrackPoint(ts: 2, lat: 39.91, lng: 116.41),
      ],
      stays: [
        PeerTrackStay(
            lat: 39.9001,
            lng: 116.4001,
            arrivedAt: 1,
            durationSec: 600,
            placeName: '家'),
      ],
      distanceM: 1500,
      latestLat: 39.9001,
      latestLng: 116.4001,
    );

void main() {
  group('使用数据裁剪', () {
    test('全最高档：原样给', () {
      final p = previewUsage(_usage(), PeerPolicy.defaults);
      expect(p.hidden, isFalse);
      expect(p.hourly, isNotNull);
      expect(p.sessions, isNotNull);
      expect(p.topApps, isNotNull);
      expect(p.currentApp, isNotNull);
      expect(p.networkEvents!.single.ssid, 'home');
    });

    test('usage off：closed_off 且不给任何数（不冒充 0）', () {
      final p = previewUsage(
          _usage(), PeerPolicy.defaults.copyWith(usageLevel: UsageLevel.off));
      expect(p.hidden, isTrue);
      expect(p.screenSec, isNull);
      expect(p.hourly, isNull);
    });

    test('screen_only：只留两数，分布/排行/会话全裁', () {
      final p = previewUsage(_usage(),
          PeerPolicy.defaults.copyWith(usageLevel: UsageLevel.screenOnly));
      expect(p.screenSec, 3900);
      expect(p.unlocks, 12);
      expect(p.hourly, isNull);
      expect(p.topApps, isNull);
      expect(p.sessions, isNull);
      expect(p.currentApp, isNull);
    });

    test('app top5：给排行不给时间流与「正在使用」', () {
      final p = previewUsage(
          _usage(), PeerPolicy.defaults.copyWith(appLevel: AppLevel.top5));
      expect(p.topApps, isNotNull);
      expect(p.sessions, isNull);
      expect(p.currentApp, isNull);
    });

    test('app off：应用两节全无，统计与分布照常', () {
      final p = previewUsage(
          _usage(), PeerPolicy.defaults.copyWith(appLevel: AppLevel.off));
      expect(p.topApps, isNull);
      expect(p.sessions, isNull);
      expect(p.hourly, isNotNull);
      expect(p.screenSec, 3900);
    });

    test('network type_only：SSID 清空但类型保留', () {
      final p = previewUsage(
          _usage(), PeerPolicy.defaults.copyWith(netLevel: NetLevel.typeOnly));
      expect(p.networkEvents!.single.net, 'wifi');
      expect(p.networkEvents!.single.ssid, '');
    });

    test('network off：网络记录整块不返回', () {
      final p = previewUsage(
          _usage(), PeerPolicy.defaults.copyWith(netLevel: NetLevel.off));
      expect(p.networkEvents, isNull);
    });
  });

  group('轨迹裁剪', () {
    test('exact：原样给（点列/距离/停留）', () {
      final p = previewTrack(_track(), PeerPolicy.defaults);
      expect(p.points.length, 2);
      expect(p.distanceM, 1500);
      expect(p.stays.single.placeName, '家');
    });

    test('street：无点列、无距离、停留点网格化', () {
      final p = previewTrack(
          _track(), PeerPolicy.defaults.copyWith(locLevel: LocLevel.street));
      expect(p.isStreet, isTrue);
      expect(p.points, isEmpty);
      expect(p.distanceM, isNull);
      expect(p.stays.length, 1);
      // 0.005° 网格：39.9001 → 39.900
      expect(p.stays.single.lat, closeTo(39.900, 1e-9));
      expect(p.stays.single.lng, closeTo(116.400, 1e-9));
    });

    test('off：closed_off 空壳', () {
      final p = previewTrack(
          _track(), PeerPolicy.defaults.copyWith(locLevel: LocLevel.off));
      expect(p.hidden, isTrue);
      expect(p.points, isEmpty);
    });
  });

  group('实时状态行', () {
    test('stream 档才显示「正在使用」', () {
      expect(previewLiveLine(const PeerCurrentApp(app: '微信'),
              PeerPolicy.defaults),
          '正在使用 微信');
      expect(
          previewLiveLine(const PeerCurrentApp(app: '微信'),
              PeerPolicy.defaults.copyWith(appLevel: AppLevel.top5)),
          '');
    });
  });
}
