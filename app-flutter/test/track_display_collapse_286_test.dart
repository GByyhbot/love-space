import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/peer/peer_permissions.dart';
import 'package:love_space/core/peer/peer_policy.dart';
import 'package:love_space/core/peer/peer_track_data.dart';
import 'package:love_space/core/sse/sse_client.dart';
import 'package:love_space/features/chat/chat_toast.dart'
    show ChatToastController, ChatToastMessage, ChatToastTone, chatToastProvider;
import 'package:love_space/features/personal/personal_controller.dart'
    show personalCurrentUserProvider;
import 'package:love_space/features/settings/peer_share_settings_page.dart';
import 'package:love_space/features/together/peer_preview.dart';
import 'package:love_space/features/together/peer_track_page.dart';
import 'package:love_space/features/together/track_replay.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final ResponseBody Function(RequestOptions options) handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return handler(options);
  }
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {Headers.contentTypeHeader: const ['application/json']},
    );

class _NoTimerToast extends ChatToastController {
  @override
  void show(String text, {ChatToastTone tone = ChatToastTone.info}) {
    state = ChatToastMessage(id: 1, text: text, tone: tone);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('peer_loc/native'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('cn.iepose.lovespace/amap_config'), null);
  });

  group('甲：展示线塌缩数据与预览口径', () {
    test('PeerTrackSide 优先采用 display_points/display_distance_m，缺省时兼容老服务端回退 points',
        () {
      final v2 = PeerTrackSide.fromJson({
        'closed_off': false,
        'level': 'exact',
        'points': [
          {'ts': 100, 'lat': 31.2300, 'lng': 121.4700},
          {'ts': 500, 'lat': 31.2330, 'lng': 121.4730},
          {'ts': 900, 'lat': 31.2300, 'lng': 121.4700},
        ],
        'stays': [
          {
            'lat': 31.2305,
            'lng': 121.4705,
            'arrived_at': 100,
            'left_at': null,
            'duration_sec': 800,
            'place_name': '矿区宿舍',
          },
        ],
        'distance_m': 491.0,
        'display_points': [
          {'ts': 100, 'lat': 31.2305, 'lng': 121.4705, 'speed': 0.0},
          {'ts': 900, 'lat': 31.2305, 'lng': 121.4705, 'speed': 0.0},
        ],
        'display_segments': [
          {'type': 'still', 'start_ts': 100, 'end_ts': 900, 'distance_m': 0.0},
        ],
        'display_distance_m': 0.0,
      });

      expect(v2.points.length, 3);
      expect(v2.effectivePoints.length, 2);
      expect(v2.effectivePoints.first.lat, 31.2305);
      expect(v2.effectiveDistanceM, 0.0);
      expect(v2.effectiveSegments.single.type, 'still');
      expect(v2.stays.single.lat, v2.effectivePoints.first.lat);
      expect(v2.stays.single.lng, v2.effectivePoints.first.lng);

      // Legacy server without display_* keys still works via points/distance_m.
      final legacy = PeerTrackSide.fromJson({
        'closed_off': false,
        'level': 'exact',
        'points': [
          {'ts': 100, 'lat': 31.2300, 'lng': 121.4700},
          {'ts': 200, 'lat': 31.2310, 'lng': 121.4700},
        ],
        'distance_m': 111.0,
      });
      expect(legacy.effectivePoints.length, 2);
      expect(legacy.effectiveDistanceM, 111.0);
    });

    test('previewTrack 在 street 档同时清空 displayPoints 与 displayDistanceM', () {
      const full = PeerTrackSide(
        level: 'exact',
        points: [
          PeerTrackPoint(ts: 1, lat: 31.23, lng: 121.47),
          PeerTrackPoint(ts: 2, lat: 31.24, lng: 121.48),
        ],
        displayPoints: [
          PeerTrackPoint(ts: 1, lat: 31.23, lng: 121.47),
          PeerTrackPoint(ts: 2, lat: 31.24, lng: 121.48),
        ],
        distanceM: 1500,
        displayDistanceM: 1400,
        stays: [
          PeerTrackStay(lat: 31.2301, lng: 121.4701, arrivedAt: 1, durationSec: 600),
        ],
      );
      final street = previewTrack(
        full,
        PeerPolicy.defaults.copyWith(locLevel: LocLevel.street),
      );
      expect(street.effectivePoints, isEmpty);
      expect(street.effectiveDistanceM, isNull);
    });

    test('回放沿展示线在停留段内固定于同一锚点', () {
      const anchorLat = 31.2305;
      const anchorLng = 121.4705;
      const displayPts = [
        PeerTrackPoint(ts: 100, lat: anchorLat, lng: anchorLng, speed: 0),
        PeerTrackPoint(ts: 1000, lat: anchorLat, lng: anchorLng, speed: 0),
        PeerTrackPoint(ts: 1300, lat: 31.2350, lng: 121.4750, speed: 2.0),
      ];
      final midStay = pointAt(displayPts, 550)!;
      expect(midStay.lat, closeTo(anchorLat, 1e-9));
      expect(midStay.lng, closeTo(anchorLng, 1e-9));
      final moving = pointAt(displayPts, 1150)!;
      expect(moving.lat, closeTo((anchorLat + 31.2350) / 2, 1e-9));
    });
  });

  group('甲：轨迹页展示线渲染与影子评估自检展示', () {
    testWidgets('PeerTrackPage 显示展示线里程「已移动 0 米」而非 491 米', (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('cn.iepose.lovespace/amap_config'),
        (call) async => call.method == 'hasApiKey' ? false : null,
      );

      final adapter = _Adapter((o) {
        if (o.uri.path == '/api/peer/track') {
          return _json({
            'date': '2026-11-28',
            'mine': {'closed_off': false, 'level': 'exact', 'points': []},
            'peer': {
              'closed_off': false,
              'level': 'exact',
              'distance_m': 491.0,
              'display_distance_m': 0.0,
              'points': [
                {'ts': 1000, 'lat': 31.2300, 'lng': 121.4700},
                {'ts': 5000, 'lat': 31.2320, 'lng': 121.4720},
                {'ts': 9000, 'lat': 31.2305, 'lng': 121.4705},
              ],
              'display_points': [
                {'ts': 1000, 'lat': 31.2305, 'lng': 121.4705, 'speed': 0.0},
                {'ts': 9000, 'lat': 31.2305, 'lng': 121.4705, 'speed': 0.0},
              ],
              'stays': [
                {
                  'lat': 31.2305,
                  'lng': 121.4705,
                  'arrived_at': 1000,
                  'left_at': null,
                  'duration_sec': 8000,
                  'place_name': '矿区宿舍',
                },
              ],
            },
          });
        }
        return _json({'items': const [], 'events': const [], 'mine': const [], 'peer': const {}});
      });

      final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
        ..httpClientAdapter = adapter;
      final c = ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
        personalCurrentUserProvider.overrideWith((ref) => 'u1'),
        chatToastProvider.overrideWith(_NoTimerToast.new),
      ]);
      addTearDown(c.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: PeerTrackPage(embedded: true)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('已移动 0 米'), findsOneWidget);
      expect(find.textContaining('491'), findsNothing);
      expect(find.textContaining('矿区宿舍'), findsWidgets);
    });

    testWidgets('PeerDiagnosticsSnapshot 与采集自检卡片展示高德影子评估状态', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('peer_loc/native'),
          (call) async {
        switch (call.method) {
          case 'status':
            return <String, Object?>{'running': true, 'received': 10};
          case 'permissions':
            return <String, Object?>{
              'fine': true,
              'background': true,
              'usage': true,
              'notification': true,
              'batteryIgnored': true,
            };
          case 'diagnostics':
            return <String, Object?>{
              'location': <String, Object?>{'running': true, 'received': 10},
              'state': <String, Object?>{'enabled': true, 'emitted': 2},
              'usage': <String, Object?>{'granted': true, 'enabled': true},
              'permissions': <String, Object?>{
                'fine': true,
                'background': true,
                'usage': true,
                'notification': true,
                'batteryIgnored': true,
              },
              'amapShadow': <String, Object?>{
                'enabled': true,
                'sdkVersion': '6.4.1',
                'attempts': 12,
                'succeeded': 11,
                'failed': 1,
                'lastLocType': 'wifi',
                'lastAcc': 15.0,
                'logBytes': 4096,
                'logPath': '/sdcard/peer-loc/amap-shadow-eval.jsonl',
              },
            };
          default:
            return <String, Object?>{};
        }
      });

      final snap = await peerDiagnosticsStatus();
      expect(snap.shadowEnabled, isTrue);
      expect(snap.shadowSdkVersion, '6.4.1');
      expect(snap.shadowSucceeded, 11);

      final adapter = _Adapter((o) {
        if (o.uri.path == '/api/peer/settings') {
          return _json({
            'location': true,
            'track': true,
            'events': true,
            'usage': true,
            'policy': {
              'location_level': 'exact',
              'usage_level': 'full',
              'app_level': 'stream',
              'network_level': 'ssid',
            },
          });
        }
        return _json({'items': const []});
      });
      final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
        ..httpClientAdapter = adapter;
      final c = ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
        personalCurrentUserProvider.overrideWith((ref) => 'u1'),
        chatToastProvider.overrideWith(_NoTimerToast.new),
      ]);
      addTearDown(c.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: PeerShareSettingsPage()),
        ),
      );
      await tester.pumpAndSettle();

      final card = find.byKey(const Key('peer-diagnostics-card'));
      await tester.scrollUntilVisible(card, 300);
      await tester.pumpAndSettle();

      expect(find.text('高德影子评估'), findsOneWidget);
      expect(find.textContaining('采样 11/12 · wifi ±15m'), findsOneWidget);
    });
  });
}
