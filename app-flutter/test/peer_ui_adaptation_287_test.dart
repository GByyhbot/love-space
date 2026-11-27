/// 2.8.7 界面适配优化令 · 呈现层全维度适配测试。
///
/// 覆盖：
/// · 小屏（360×740）× 大屏（430×932）× 浅色/深色双主题零溢出；
/// · 长文案/极值（长 SSID、长应用名、长地点名、100% 电量、四位数分钟数、>6h 警示）；
/// · 轨迹画布投影（2 点共线 / 300 点 / street 仅停留点）+ 气泡防重叠降级为时长；
/// · 手机页 24h 柱条点击交互 + 三子标签切换 + 空态/未授权态；
/// · 生理期页 360dp 下四态图例一行不换行不溢出。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/peer/peer_expected_state.dart';
import 'package:love_space/core/peer/peer_track_data.dart';
import 'package:love_space/core/sse/sse_client.dart';
import 'package:love_space/core/theme/tokens.dart';
import 'package:love_space/features/chat/chat_toast.dart'
    show ChatToastController, ChatToastMessage, ChatToastTone, chatToastProvider;
import 'package:love_space/features/period/period_engine.dart'
    show dayNum, dayStr, spaceTodayIso;
import 'package:love_space/features/period/period_page.dart';
import 'package:love_space/features/personal/personal_controller.dart'
    show personalCurrentUserProvider;
import 'package:love_space/features/settings/peer_share_settings_page.dart';
import 'package:love_space/features/together/peer_phone_page.dart';
import 'package:love_space/features/together/peer_report_page.dart';
import 'package:love_space/features/together/peer_track_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final FutureOr<ResponseBody> Function(RequestOptions options) handler;

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

const _native = MethodChannel('peer_loc/native');

final double _now = DateTime.now().millisecondsSinceEpoch / 1000;

const _longSsid = 'MixC_Guest_Super_Long_WiFi_Network_Name_5G_2026_Test';
const _longApp = '一个名字非常非常长以至于必须单行省略号截断的应用名称测试';
const _longPlace = '深圳市南山区粤海街道高新科技园南区某超长地点名称大厦B座';

_Adapter _extremeAdapter({bool halted = false}) => _Adapter((o) {
      final p = o.uri.path;
      if (p == '/api/peer/status') {
        return _json({
          'revision': 10,
          'mine': {
            'settings': {'events': true},
            'location': {
              'user': 'me',
              'lat': 22.5431,
              'lng': 114.0579,
              'battery': 100,
              'charging': true,
              'net': 'wifi',
              'wifi': _longSsid,
              'updated': _now - 30,
            },
            'policy': {'global_off': false, 'paused_until': null},
          },
          'peer': {
            'settings': {'events': true, 'location': true, 'track': true},
            'location': halted
                ? null
                : {
                    'user': 'ta',
                    'lat': 22.5229,
                    'lng': 113.9384,
                    'battery': 100,
                    'charging': false,
                    'net': 'wifi',
                    'wifi': _longSsid,
                    'updated': _now - 7 * 3600,
                  },
            'enabled': !halted,
            'closed_off': false,
            'halted': {'halted': halted, 'reason': halted ? 'off' : ''},
            'current_app': halted
                ? null
                : {'app': _longApp, 'masked': false, 'since': _now - 600},
          },
        });
      }
      if (p == '/api/peer/state-daily') {
        return _json({
          'date': '2026-11-27',
          'mine': {'screen_sec': 86400, 'unlocks': 1234},
          'peer': {
            'closed_off': false,
            'screen_sec': 86400,
            'unlocks': 1234,
          },
        });
      }
      if (p == '/api/peer/usage-daily') {
        final hourly = List<int>.generate(24, (h) => h < 6 ? 1200 : 1800);
        return _json({
          'date': '2026-11-27',
          'mine': {'closed_off': false},
          'peer': {
            'closed_off': halted,
            'halted': {'halted': halted, 'reason': halted ? 'off' : ''},
            'screen_sec': 86400,
            'unlocks': 1234,
            'longest_session_sec': 7200,
            'yesterday_screen_sec': 54000,
            'hourly': hourly,
            'top_apps': [
              {'app': _longApp, 'sec': 42000},
              {'app': '其他应用', 'sec': 12000},
            ],
            'sessions': [
              {
                'app': _longApp,
                'sec': 3600,
                'start': _now - 3600,
                'end': _now,
                'masked': false,
              },
              {
                'app': '其他应用',
                'sec': 600,
                'start': _now - 4500,
                'masked': true,
              },
            ],
            'folded_count': 12,
            'network_events': [
              {'ts': _now - 120, 'net': 'wifi', 'ssid': _longSsid},
              {'ts': _now - 3600, 'net': 'cell', 'ssid': ''},
            ],
            'current_app': {'app': _longApp, 'since': _now - 600},
          },
        });
      }
      if (p == '/api/peer/track') {
        return _json({
          'date': '2026-11-27',
          'mine': {'closed_off': false, 'level': 'street', 'stays': [
            {
              'lat': 22.5431,
              'lng': 114.0579,
              'arrived_at': _now - 3600,
              'left_at': null,
              'duration_sec': 3600,
              'place_name': _longPlace,
            }
          ]},
          'peer': {
            'closed_off': halted,
            'halted': {'halted': halted, 'reason': halted ? 'off' : ''},
            'level': 'exact',
            'points': [
              for (var i = 0; i < 40; i++)
                {
                  'ts': _now - (40 - i) * 120,
                  'lat': 22.5200 + i * 0.0005,
                  'lng': 113.9300 + i * 0.0004,
                  'acc': 10.0,
                  'speed': i > 20 ? 12.0 : 1.0,
                },
            ],
            'stays': [
              {
                'lat': 22.5205,
                'lng': 113.9305,
                'arrived_at': _now - 4800,
                'left_at': _now - 3000,
                'duration_sec': 1800,
                'place_name': _longPlace,
              },
              {
                'lat': 22.5207,
                'lng': 113.9307,
                'arrived_at': _now - 2400,
                'left_at': null,
                'duration_sec': 2400,
                'place_name': '海岸城购物中心东门广场超长站点',
              },
            ],
            'segments': [
              {
                'type': 'walk',
                'start_ts': _now - 4800,
                'end_ts': _now - 2400,
                'distance_m': 500,
              },
              {
                'type': 'drive',
                'start_ts': _now - 2400,
                'end_ts': _now,
                'distance_m': 4200,
              },
            ],
            'distance_m': 4700.0,
          },
        });
      }
      if (p == '/api/peer/events') {
        return _json({
          'date': '2026-11-27',
          'mine': <Object?>[],
          'peer': {
            'closed_off': false,
            'events': [
              {
                'id': 'ev1',
                'user': 'ta',
                'type': 'state.net',
                'ts': _now - 120,
                'summary': '连上 Wi-Fi（$_longSsid）',
                'source': 'auto',
                'mine': false,
                'payload': {'net': 'wifi', 'ssid': _longSsid},
              },
              {
                'id': 'ev2',
                'user': 'ta',
                'type': 'manual_report',
                'ts': _now - 600,
                'summary': '到公司啦',
                'source': 'manual',
                'scene': 'arrive_home',
                'note': '今天路况很好',
                'place_name': _longPlace,
                'mine': false,
              },
            ],
          },
        });
      }
      if (p == '/api/peer/settings') {
        return _json({
          'location': true,
          'track': true,
          'events': true,
          'usage': true,
          'policy': {
            'global_off': false,
            'paused_until': null,
            'location_level': 'exact',
            'usage_level': 'full',
            'app_level': 'stream',
            'network_level': 'ssid',
            'battery': true,
            'battery_alert': true,
            'sensitive_pkgs': <String>[],
            'fold_short': true,
          },
        });
      }
      if (p == '/api/peer/policy-audit') {
        return _json({'items': <Object?>[]});
      }
      if (p == '/api/records') {
        final periodStart = dayStr(dayNum(spaceTodayIso(DateTime.now().toUtc())) - 2);
        return _json([
          {
            'id': 'p1',
            'kind': 'period',
            'author': 'u1',
            'body': {'start': periodStart, 'length': 5, 'cycle': 28},
            'created': _now - 86400,
            'updated': _now - 86400,
          }
        ]);
      }
      return _json(<String, Object?>{});
    });

Future<void> _pumpAdapted(
  WidgetTester tester,
  Widget page, {
  required Size size,
  required Brightness brightness,
  _Adapter? adapter,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  final dio = Dio(BaseOptions(
    baseUrl: 'https://test.local',
    validateStatus: api.validateAppStatus,
  ))..httpClientAdapter = adapter ?? _extremeAdapter();

  final c = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    personalCurrentUserProvider.overrideWith((ref) => 'u1'),
    chatToastProvider.overrideWith(_NoTimerToast.new),
  ]);
  addTearDown(c.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFEF3F68),
          brightness: brightness,
        ),
        cardTheme: CardThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
        ),
      ),
      home: page,
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
  await tester.pump(const Duration(milliseconds: 80));
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kPeerExpectedKey: true,
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, (call) async {
      switch (call.method) {
        case 'status':
          return {'running': true, 'received': 10, 'queue': 0};
        case 'batteryIgnored':
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, null);
  });

  group('轨迹画布投影与气泡防重叠', () {
    test('2 点共线、300 点与 street 仅停留点投影均不变形且不出界', () {
      const canvas = Size(320, 240);
      final two = [
        const PeerTrackPoint(ts: 1, lat: 22.5200, lng: 113.9300),
        const PeerTrackPoint(ts: 2, lat: 22.5201, lng: 113.9300),
      ];
      final m2 = TrackCanvasMapper(points: two, stays: const [], size: canvas);
      expect(m2.valid, isTrue);
      final pA = m2.toOffset(two[0].lat, two[0].lng);
      final pB = m2.toOffset(two[1].lat, two[1].lng);
      expect(pA.dx, closeTo(pB.dx, 0.5));
      expect(pA.dy, greaterThan(pB.dy));

      final many = [
        for (var i = 0; i < 300; i++)
          PeerTrackPoint(
            ts: 1000.0 + i * 60,
            lat: 22.50 + i * 0.0002,
            lng: 113.90 + (i % 17) * 0.0003,
          ),
      ];
      final mMany = TrackCanvasMapper(points: many, stays: const [], size: canvas);
      expect(mMany.valid, isTrue);
      for (final pt in many) {
        final o = mMany.toOffset(pt.lat, pt.lng);
        expect(o.dx, inInclusiveRange(8.0, canvas.width - 8.0));
        expect(o.dy, inInclusiveRange(8.0, canvas.height - 8.0));
      }

      final streetStays = [
        const PeerTrackStay(
          lat: 22.52,
          lng: 113.93,
          arrivedAt: 100,
          durationSec: 600,
        ),
        const PeerTrackStay(
          lat: 22.53,
          lng: 113.94,
          arrivedAt: 900,
          durationSec: 1200,
        ),
      ];
      final mStreet =
          TrackCanvasMapper(points: const [], stays: streetStays, size: canvas);
      expect(mStreet.valid, isTrue);
    });

    test('气泡重叠时降级为仅显时长且全画布不重叠', () {
      const canvas = Size(380, 104);
      // 仅容一行的垂直带内，左右两点长地名(≈134px)占满两侧，
      // 中间点(lng=113.9320)长地名四向均碰撞，降级为「15分钟」(≈44px)可嵌入中间空隙。
      final stays = [
        const PeerTrackStay(
          lat: 22.5200,
          lng: 113.9300,
          arrivedAt: 100,
          durationSec: 1800,
          placeName: '高新科技园南区超长地点一',
        ),
        const PeerTrackStay(
          lat: 22.5200,
          lng: 113.9340,
          arrivedAt: 2000,
          durationSec: 1560,
          placeName: '高新科技园南区超长地点二',
        ),
        const PeerTrackStay(
          lat: 22.5200,
          lng: 113.9320,
          arrivedAt: 5000,
          durationSec: 900,
          placeName: '高新科技园南区超长地点三',
        ),
      ];
      final mapper =
          TrackCanvasMapper(points: const [], stays: stays, size: canvas);
      final placed =
          layoutStayLabels(stays: stays, mapper: mapper, size: canvas);
      expect(placed.length, 3);
      expect(placed.any((p) => p.degradedToDuration), isTrue,
          reason: '紧密簇内的长地名必须降级为紧凑时长');
      for (var i = 0; i < placed.length; i++) {
        for (var j = i + 1; j < placed.length; j++) {
          expect(placed[i].rect.overlaps(placed[j].rect), isFalse,
              reason: '已排布气泡矩形绝对不允许互相重叠');
        }
      }
    });
  });

  group('小屏 360dp / 大屏 430dp × 深浅双主题无溢出', () {
    final configs = <(String, Size, Brightness)>[
      ('360-light', const Size(360, 740), Brightness.light),
      ('360-dark', const Size(360, 740), Brightness.dark),
      ('430-light', const Size(430, 932), Brightness.light),
      ('430-dark', const Size(430, 932), Brightness.dark),
    ];

    for (final (tag, size, brightness) in configs) {
      testWidgets('PeerReportPage 极值与长文案 ($tag)', (tester) async {
        await _pumpAdapted(tester, const PeerReportPage(),
            size: size, brightness: brightness);
        expect(find.byKey(const Key('peer-status-card')), findsOneWidget);
        expect(find.byKey(const Key('report-poke-fab')), findsOneWidget);
        expect(find.textContaining('长时间无更新'), findsOneWidget);
      });

      testWidgets('PeerTrackPage 极值与浮条 ($tag)', (tester) async {
        await _pumpAdapted(tester, const PeerTrackPage(),
            size: size, brightness: brightness);
        expect(find.byKey(const Key('track-canvas')), findsOneWidget);
        expect(find.byKey(const Key('track-replay')), findsOneWidget);
      });

      testWidgets('PeerPhonePage 极值与交互 ($tag)', (tester) async {
        await _pumpAdapted(tester, const PeerPhonePage(),
            size: size, brightness: brightness);
        expect(find.byKey(const Key('phone-stats')), findsOneWidget);
        expect(find.byKey(const Key('phone-hourly')), findsOneWidget);
        expect(find.byKey(const Key('phone-sessions')), findsOneWidget);
      });

      testWidgets('PeerShareSettingsPage 分档与胶囊 ($tag)', (tester) async {
        await _pumpAdapted(tester, const PeerShareSettingsPage(),
            size: size, brightness: brightness);
        expect(find.byKey(const Key('peer-share-status')), findsOneWidget);
        expect(find.byKey(const Key('peer-level-location-exact')), findsOneWidget);
      });

      testWidgets('PeriodPage 卡片对齐与图例一行 ($tag)', (tester) async {
        await _pumpAdapted(tester, const PeriodPage(),
            size: size, brightness: brightness);
        expect(find.byKey(const Key('period-legend')), findsOneWidget);
        final y0 = tester.getCenter(find.text('实记')).dy;
        final y1 = tester.getCenter(find.text('排卵易孕')).dy;
        expect((y0 - y1).abs(), lessThan(2.0));
      });
    }
  });

  group('手机页交互与空/停用态', () {
    testWidgets('点击 24h 柱条更新指示胶囊并可切 3 子标签', (tester) async {
      await _pumpAdapted(
        tester,
        const PeerPhonePage(),
        size: const Size(360, 740),
        brightness: Brightness.light,
      );
      await tester.tap(find.byKey(const Key('phone-hour-bar-14')));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const Key('phone-hourly-tip')),
          matching: find.textContaining('14:00'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('phone-tab-top')));
      await tester.pump();
      expect(find.byKey(const Key('phone-top')), findsOneWidget);

      await tester.tap(find.byKey(const Key('phone-tab-net')));
      await tester.pump();
      expect(find.byKey(const Key('phone-network')), findsOneWidget);

      // 切到「我」全空数据 → 展示未授权/空态引导卡
      await tester.tap(find.text('我'));
      await tester.pump();
      expect(find.byKey(const Key('phone-empty')), findsOneWidget);
    });

    testWidgets('报备页停用态明示', (tester) async {
      await _pumpAdapted(
        tester,
        const PeerReportPage(),
        size: const Size(360, 740),
        brightness: Brightness.dark,
        adapter: _extremeAdapter(halted: true),
      );
      expect(find.byKey(const Key('peer-halted-line')), findsOneWidget);
    });
  });
}
