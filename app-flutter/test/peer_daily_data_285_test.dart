/// 2.8.7 全量施工令 · 读接口解析护栏（usage-daily / track v2）。
///
/// 核心口径：**分档裁掉的字段必须是 null，不是 0**——页面据此整项不显示。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/peer/peer_track_data.dart';
import 'package:love_space/core/peer/peer_usage_data.dart';

void main() {
  group('usage-daily 解析', () {
    test('齐全：六类字段都解析出来', () {
      final j = PeerUsageDay.fromJson({
        'date': '2026-11-27',
        'mine': {'closed_off': false, 'screen_sec': 100, 'unlocks': 2},
        'peer': {
          'closed_off': false,
          'halted': {'halted': false, 'reason': '', 'until': null},
          'screen_sec': 3900,
          'unlocks': 12,
          'longest_session_sec': 1800,
          'yesterday_screen_sec': 5000,
          'hourly': List<int>.generate(24, (i) => i),
          'top_apps': [
            {'app': '微信', 'sec': 600},
            {'app': '其他应用', 'sec': 300},
          ],
          'sessions': [
            {'app': '微信', 'sec': 600, 'masked': false, 'folded': false},
          ],
          'folded_count': 3,
          'network_events': [
            {'ts': 1, 'net': 'wifi', 'ssid': 'home'},
          ],
          'current_app': {'app': '微信', 'masked': false, 'since': 100},
        },
      });
      final p = j.peer;
      expect(p.screenSec, 3900);
      expect(p.unlocks, 12);
      expect(p.longestSessionSec, 1800);
      expect(p.yesterdayScreenSec, 5000);
      expect(p.hourly!.length, 24);
      expect(p.topApps!.first.app, '微信');
      expect(p.sessions!.single.sec, 600);
      expect(p.foldedCount, 3);
      expect(p.networkEvents!.single.ssid, 'home');
      expect(p.currentApp!.app, '微信');
      expect(p.hidden, isFalse);
    });

    test('screen_only：hourly/top_apps/sessions 缺失 → null（不是空表）', () {
      final p = PeerUsageSide.fromJson({
        'closed_off': false,
        'screen_sec': 600,
        'unlocks': 3,
      });
      expect(p.screenSec, 600);
      expect(p.hourly, isNull);
      expect(p.topApps, isNull);
      expect(p.sessions, isNull);
      expect(p.networkEvents, isNull);
    });

    test('usage off / halted：closed_off 且数值缺失（不冒充 0）', () {
      final p = PeerUsageSide.fromJson({
        'closed_off': true,
        'halted': {'halted': true, 'reason': 'paused', 'until': 999},
      });
      expect(p.hidden, isTrue);
      expect(p.screenSec, isNull, reason: '关闭态不许给假 0');
      expect(p.halted.isPaused, isTrue);
    });

    test('Top5 里空的 app 名丢掉，不渲染空行', () {
      final p = PeerUsageSide.fromJson({
        'top_apps': [
          {'app': '', 'sec': 1},
          {'app': '微信', 'sec': 2},
        ],
      });
      expect(p.topApps!.length, 1);
      expect(p.topApps!.single.app, '微信');
    });

    test('current_app 空对象 → null（不造「正在使用 」）', () {
      expect(PeerUsageSide.fromJson({'current_app': {}}).currentApp, isNull);
      expect(
          PeerUsageSide.fromJson({
            'current_app': {'app': '  '}
          }).currentApp,
          isNull);
    });
  });

  group('track v2 解析', () {
    test('exact：点列/距离/停留/分段都在', () {
      final side = PeerTrackSide.fromJson({
        'closed_off': false,
        'level': 'exact',
        'points': [
          {'ts': 1, 'lat': 39.9, 'lng': 116.4, 'acc': 5, 'speed': 0},
          {'ts': 2, 'lat': 39.91, 'lng': 116.41},
        ],
        'stays': [
          {
            'lat': 39.9,
            'lng': 116.4,
            'arrived_at': 1,
            'left_at': 300,
            'duration_sec': 299,
            'place_name': '家',
          },
          {
            'lat': 39.95,
            'lng': 116.45,
            'arrived_at': 400,
            'left_at': null,
            'duration_sec': 100,
            'place_name': '',
          },
        ],
        'segments': [
          {'type': 'walk', 'start_ts': 1, 'end_ts': 300, 'distance_m': 120.5},
          {'type': 'drive', 'start_ts': 300, 'end_ts': 900, 'distance_m': 5000},
        ],
        'distance_m': 5120.5,
        'latest': {'lat': 39.95, 'lng': 116.45, 'updated': 900},
      });
      expect(side.level, 'exact');
      expect(side.points.length, 2);
      expect(side.distanceM, 5120.5);
      expect(side.stays.first.displayName, '家');
      expect(side.stays.last.displayName, '停留点',
          reason: '没命名就写「停留点」，不许编地名');
      expect(side.stays.last.ongoing, isTrue);
      expect(side.segments.last.isDrive, isTrue);
      expect(side.latestLat, 39.95);
    });

    test('street：无点列、距离为 null、停留点保留', () {
      final side = PeerTrackSide.fromJson({
        'closed_off': false,
        'level': 'street',
        'points': <Object?>[],
        'stays': [
          {'lat': 39.905, 'lng': 116.4, 'arrived_at': 1, 'duration_sec': 600},
        ],
        'distance_m': null,
        'latest': {'lat': 39.905, 'lng': 116.4},
      });
      expect(side.isStreet, isTrue);
      expect(side.hasTrack, isFalse);
      expect(side.distanceM, isNull);
      expect(side.stays.length, 1);
    });

    test('off / halted：hidden 且字段齐为空壳', () {
      final side = PeerTrackSide.fromJson({
        'closed_off': true,
        'halted': {'halted': true, 'reason': 'off'},
        'level': 'off',
        'points': <Object?>[],
        'stays': <Object?>[],
        'distance_m': 0.0,
      });
      expect(side.hidden, isTrue);
      expect(side.halted.isOff, isTrue);
      expect(side.points, isEmpty);
    });

    test('一天完整响应（双方）', () {
      final day = PeerTrackDay.fromJson({
        'date': '2026-11-27',
        'mine': {'closed_off': false, 'level': 'exact', 'points': []},
        'peer': {'closed_off': true, 'level': 'off', 'points': []},
      });
      expect(day.date, '2026-11-27');
      expect(day.mine.level, 'exact');
      expect(day.peer.hidden, isTrue);
    });
  });
}
