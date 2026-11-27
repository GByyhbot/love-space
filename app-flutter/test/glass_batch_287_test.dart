import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart' show EagerGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import 'package:love_space/core/peer/peer_expected_state.dart';
import 'package:love_space/core/peer/peer_permissions.dart';
import 'package:love_space/core/peer/peer_report_api.dart';
import 'package:love_space/core/peer/peer_track_data.dart';
import 'package:love_space/core/peer/timeline_folding.dart';
import 'package:love_space/core/sse/sse_client.dart'
    show SseClient, SseEvent, SsePhase, SseState, sseEventsProvider, sseProvider;
import 'package:love_space/core/ui/liquid_glass.dart' show LiquidGlassCard;
import 'package:love_space/features/auth/auth_state.dart'
    show AuthNotifier, AuthPhase, MeData, SpaceUser, authProvider;
import 'package:love_space/features/chat/chat_toast.dart'
    show ChatToastController, ChatToastMessage, ChatToastTone, chatToastProvider;
import 'package:love_space/features/settings/peer_share_settings_page.dart';
import 'package:love_space/features/settings/settings_widgets.dart'
    show showFormSheet;
import 'package:love_space/features/together/amap_track_map.dart';
import 'package:love_space/features/together/calendar_page.dart';
import 'package:love_space/features/together/peer_report_page.dart';
import 'package:love_space/features/together/peer_track_page.dart';

class _FakeAuth extends AuthNotifier {
  @override
  AuthPhase build() {
    me = MeData(
      user: const SpaceUser(id: 'u1', name: '我', username: 'u1'),
      users: const [
        SpaceUser(id: 'u1', name: '我', username: 'u1'),
        SpaceUser(id: 'u2', name: 'TA', username: 'u2'),
      ],
      spaceName: '小空间',
      spaceRaw: const <String, dynamic>{},
      spaceSince: '2024-01-01',
    );
    return AuthPhase.authed;
  }
}

class _FakeSse extends SseClient {
  @override
  SseState build() => const SseState(phase: SsePhase.idle);
  @override
  void start() {}
}

class _NoTimerToast extends ChatToastController {
  @override
  void show(String text, {ChatToastTone tone = ChatToastTone.info}) {
    state = ChatToastMessage(id: 1, text: text, tone: tone);
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final Object Function(RequestOptions o) handler;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode(handler(options)),
      200,
      headers: {Headers.contentTypeHeader: const ['application/json']},
    );
  }
}

ProviderContainer _makeContainer(Object Function(RequestOptions o) handler) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://test.local',
      validateStatus: api.validateAppStatus,
    ),
  )..httpClientAdapter = _Adapter(handler);
  return ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      api.dioProvider.overrideWith((ref) async => dio),
      chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
      mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
      api.cookieJarProvider.overrideWith((ref) async {
        throw StateError('test: no cookie jar');
      }),
      authProvider.overrideWith(_FakeAuth.new),
      sseProvider.overrideWith(_FakeSse.new),
      sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
      chatToastProvider.overrideWith(_NoTimerToast.new),
    ],
  );
}

void _mockNative() {
  SharedPreferences.setMockInitialValues(<String, Object>{
    kPeerExpectedKey: true,
    kFirstInstallPermGuideDoneKey: true,
  });
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('peer_loc/native'),
    (call) async {
      switch (call.method) {
        case 'status':
          return <String, Object?>{'running': true, 'receiving': true};
        case 'permissions':
          return <String, Object?>{
            'channelAvailable': true,
            'fine': true,
            'background': true,
            'usage': true,
            'notification': true,
            'batteryIgnored': true,
            'manufacturer': 'Xiaomi',
            'autoStartIntentSupported': true,
          };
        default:
          return true;
      }
    },
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('cn.iepose.lovespace/amap_config'),
    (call) async => call.method == 'hasApiKey' ? false : null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('peer_loc/native'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('cn.iepose.lovespace/amap_config'),
      null,
    );
  });

  group('甲：弹层底部磨砂玻璃条与共同年历玻璃化', () {
    test('GlassActionBar 已去除旧实心暗底 Color(0xCC231B1D)，且 BackdropFilter 白名单未扩容', () {
      final src =
          File('lib/features/settings/settings_widgets.dart').readAsStringSync();
      expect(src.contains('0xCC231B1D'), isFalse);
      expect(src.contains('0xCCFAF8F9'), isFalse);
      expect(src.contains('ClipRRect'), isTrue);
      expect(src.contains('BackdropFilter'), isTrue);

      final calSrc =
          File('lib/features/together/calendar_page.dart').readAsStringSync();
      expect(calSrc.contains('BackdropFilter'), isFalse,
          reason: '共同年历使用预烘焙透明玻璃卡 LiquidGlassCard，滚动面禁止 BackdropFilter');
      expect(calSrc.contains('LiquidGlassCard'), isTrue);
    });

    testWidgets('showFormSheet 深浅模式下底部操作条渲染圆角磨砂 GlassActionBar',
        (tester) async {
      for (final b in [Brightness.light, Brightness.dark]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: b, useMaterial3: true),
            home: Builder(
              builder: (ctx) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showFormSheet(
                      ctx,
                      title: '添加小事',
                      saveLabel: '保存',
                      cancelLabel: '取消',
                      builder: (_) => const TextField(),
                      onSave: (closeOk, _) => closeOk(),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        final barFinder = find.byKey(const Key('glass-action-bar'));
        expect(barFinder, findsOneWidget);
        final clip = tester.widget<ClipRRect>(barFinder);
        expect(clip.borderRadius, BorderRadius.circular(16));
        expect(
          find.descendant(of: barFinder, matching: find.byType(BackdropFilter)),
          findsOneWidget,
        );
        Navigator.of(tester.element(barFinder)).pop();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('CalendarPage 使用单层 LiquidGlassCard（月历卡/提示卡/详情卡）',
        (tester) async {
      final now = DateTime.now();
      final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      final c = _makeContainer((o) {
        if (o.uri.path == '/api/calendar') {
          return {
            'month': month,
            'days': {
              '15': {
                'anniversaries': [
                  {'title': '在一起纪念日'},
                ],
                'moods': const [],
                'posts': const [],
                'checks': const [],
              },
            },
          };
        }
        return const <String, Object?>{};
      });
      addTearDown(c.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: CalendarPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Card), findsNothing);
      expect(find.byKey(const Key('calendar-month-card')), findsOneWidget);
      expect(find.byKey(const Key('calendar-hint-card')), findsOneWidget);
      expect(
        tester.widget(find.byKey(const Key('calendar-month-card'))),
        isA<LiquidGlassCard>(),
      );

      await tester.tap(find.text('15'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendar-detail-card')), findsOneWidget);
      expect(find.text('在一起纪念日'), findsOneWidget);
    });
  });

  group('乙-8 & 10：停留点地名解析链与回放条防压盖', () {
    test('resolveStayPlaceName 按围栏>点地名>latest.place_name>手工报备>兜底顺序取值', () {
      const stayEmpty = PeerTrackStay(
        lat: 22.5236,
        lng: 113.9408,
        arrivedAt: 1000,
        leftAt: 2000,
        durationSec: 1000,
      );
      // 1. stay 自带优先
      expect(
        resolveStayPlaceName(
          stayEmpty.withPlaceName('公司'),
          points: const [
            PeerTrackPoint(ts: 1500, lat: 22.5236, lng: 113.9408, placeName: '园区路'),
          ],
          latestLat: 22.5236,
          latestLng: 113.9408,
          latestPlaceName: '万象城',
        ),
        '公司',
      );
      // 2. 区间内 point.placeName
      expect(
        resolveStayPlaceName(
          stayEmpty,
          points: const [
            PeerTrackPoint(ts: 1500, lat: 22.5236, lng: 113.9408, placeName: '科技园北区'),
          ],
          latestLat: 22.5236,
          latestLng: 113.9408,
          latestPlaceName: '万象城',
        ),
        '科技园北区',
      );
      // 3. 150m 内 latest.placeName（今日卡同源）
      expect(
        resolveStayPlaceName(
          stayEmpty,
          latestLat: 22.5238,
          latestLng: 113.9409,
          latestPlaceName: '海岸城 · 南山区',
        ),
        '海岸城 · 南山区',
      );
      // 4. 超过 150m 且无报备 → 不瞎编，回落「停留点」
      expect(
        resolveStayPlaceName(
          stayEmpty,
          latestLat: 22.5500,
          latestLng: 113.9800,
          latestPlaceName: '很远的地方',
        ),
        '停留点',
      );
    });

    testWidgets('PeerTrackPage 显示真实地名，且回放条位于停留点卡片上方互不压盖',
        (tester) async {
      _mockNative();
      final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
      final c = _makeContainer((o) {
        if (o.uri.path == '/api/peer/track') {
          return {
            'date': '2026-11-28',
            'peer': {
              'level': 'exact',
              'closed_off': false,
              'distance_m': 2400,
              'points': [
                {'lat': 22.5311, 'lng': 113.9522, 'ts': now - 7200},
                {'lat': 22.5236, 'lng': 113.9408, 'ts': now - 3600},
                {'lat': 22.5236, 'lng': 113.9408, 'ts': now - 120},
              ],
              'stays': [
                {
                  'lat': 22.5236,
                  'lng': 113.9408,
                  'arrived_at': now - 3600,
                  'duration_sec': 3480,
                  'place_name': '',
                },
              ],
            },
            'mine': {'level': 'exact', 'closed_off': false, 'points': const []},
          };
        }
        if (o.uri.path == '/api/peer/status') {
          return {
            'revision': 1,
            'peer': {
              'enabled': true,
              'closed_off': false,
              'location': {
                'lat': 22.5236,
                'lng': 113.9408,
                'updated': now - 60,
                'place_name': '万象天地',
              },
            },
            'mine': {'settings': {'events': true}},
          };
        }
        return {'items': const [], 'events': const [], 'mine': const [], 'peer': const {}};
      });
      addTearDown(c.dispose);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(393, 859);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: PeerTrackPage(embedded: true)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.textContaining('万象天地'), findsWidgets);
      final replayBox =
          tester.getRect(find.byKey(const Key('track-replay')));
      final staysBox = tester.getRect(find.byKey(const Key('track-stays')));
      expect(replayBox.bottom, lessThanOrEqualTo(staysBox.top));
    });
  });

  group('丙-9：今日时间线高频状态事件呈现层折叠', () {
    PeerEventItem ev(
      String id,
      String type,
      double ts, {
      bool mine = false,
      String summary = '',
      Map<String, Object?> payload = const {},
    }) =>
        PeerEventItem(
          id: id,
          user: mine ? 'u1' : 'u2',
          type: type,
          ts: ts,
          summary: summary,
          mine: mine,
          payload: payload,
        );

    test('相邻同类电量事件折叠为「起→止 · 状态 · 时长」；夹杂其他事件分段；单条不折叠', () {
      const base = 1795800000.0;
      final list = [
        ev('b3', 'state.battery', base + 1500,
            payload: const {'level': 61, 'charging': true}),
        ev('b2', 'state.battery', base + 900,
            payload: const {'level': 78, 'charging': true}),
        ev('b1', 'state.battery', base,
            payload: const {'level': 92, 'charging': true}),
        ev('m1', 'manual_report', base - 300, summary: '出门啦'),
        ev('u2', 'state.unlock', base - 600,
            payload: const {'count': 3}),
        ev('u1', 'state.unlock', base - 900,
            payload: const {'count': 2}),
        ev('n1', 'state.net', base - 1200,
            payload: const {'net': 'wifi', 'ssid': 'Home'}),
      ];

      final entries = foldTimelineEvents(list);
      expect(entries.length, 4);
      expect(entries[0], isA<TimelineFoldedGroup>());
      final bGroup = entries[0] as TimelineFoldedGroup;
      expect(bGroup.events.length, 3);
      expect(bGroup.summaryText, '电量 92% → 61% · 充电中 · 约 25 分钟');

      expect(entries[1], isA<TimelineSingleEntry>());
      expect(entries[2], isA<TimelineFoldedGroup>());
      expect(
        (entries[2] as TimelineFoldedGroup).summaryText,
        '连续解锁 5 次 · 约 5 分钟',
      );
      expect(entries[3], isA<TimelineSingleEntry>());
    });

    testWidgets('PeerReportPage 点击折叠行展开明细、再点收起', (tester) async {
      _mockNative();
      final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
      final c = _makeContainer((o) {
        if (o.uri.path == '/api/peer/events') {
          return {
            'date': '2026-11-28',
            'mine': const [],
            'peer': {
              'closed_off': false,
              'events': [
                {
                  'id': 'b3',
                  'user': 'u2',
                  'type': 'state.battery',
                  'ts': now - 60,
                  'summary': '',
                  'payload': {'level': 61, 'charging': true},
                },
                {
                  'id': 'b2',
                  'user': 'u2',
                  'type': 'state.battery',
                  'ts': now - 660,
                  'summary': '',
                  'payload': {'level': 78, 'charging': true},
                },
                {
                  'id': 'b1',
                  'user': 'u2',
                  'type': 'state.battery',
                  'ts': now - 1560,
                  'summary': '',
                  'payload': {'level': 92, 'charging': true},
                },
              ],
            },
          };
        }
        if (o.uri.path == '/api/peer/status') {
          return {
            'revision': 1,
            'peer': {'enabled': true, 'closed_off': false},
            'mine': {'settings': {'events': true}},
          };
        }
        return const <String, Object?>{};
      });
      addTearDown(c.dispose);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(393, 859);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: PeerReportPage(embedded: true)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final foldFinder = find.byKey(const Key('report-fold-state.battery_b3_b1'));
      expect(foldFinder, findsOneWidget);
      expect(find.textContaining('电量 92% → 61%'), findsOneWidget);
      expect(find.byKey(const Key('report-event-b1')), findsNothing);

      await tester.ensureVisible(foldFinder);
      await tester.tap(foldFinder);
      await tester.pump();
      expect(find.byKey(const Key('report-event-b1')), findsOneWidget);
      expect(find.byKey(const Key('report-event-b2')), findsOneWidget);
      expect(find.byKey(const Key('report-event-b3')), findsOneWidget);

      await tester.tap(foldFinder);
      await tester.pump();
      expect(find.byKey(const Key('report-event-b1')), findsNothing);
    });
  });

  group('乙-6：高德手势抢占、日图强制可读、错误回调自检与画布降级', () {
    test('AmapTrackPlatformView.kt 源码守卫：MAP_TYPE_NORMAL + 防拦截 + ExceptionLogger + OnMapLoadedListener',
        () {
      final kt = File(
        'android/app/src/main/kotlin/cn/iepose/lovespace/love_space/AmapTrackPlatformView.kt',
      ).readAsStringSync();
      expect(kt.contains('AMap.MAP_TYPE_NORMAL'), isTrue);
      expect(kt.contains('AMap.MAP_TYPE_NIGHT'), isFalse);
      expect(kt.contains('requestDisallowInterceptTouchEvent(true)'), isTrue);
      expect(kt.contains('MapsInitializer.setExceptionLogger'), isTrue);
      expect(kt.contains('onDownloaderException'), isTrue);
      expect(kt.contains('addOnMapLoadedListener'), isTrue);
      expect(kt.contains('onMapError'), isTrue);

      final nativeKt = File(
        'android/app/src/main/kotlin/cn/iepose/lovespace/love_space/PeerLocNative.kt',
      ).readAsStringSync();
      expect(nativeKt.contains('"map" to AmapDiagnostics.snapshot()'), isTrue);
      expect(nativeKt.contains('if (pn.isNotEmpty()) put("place_name", pn)'),
          isTrue);
    });

    testWidgets('AndroidView 注册 EagerGestureRecognizer，收到 onMapError 后立即降级自绘画布',
        (tester) async {
      AmapTrackMapWidget.resetKeyCacheForTest();
      const cfgCh = MethodChannel('cn.iepose.lovespace/amap_config');
      const viewPrefix = 'cn.iepose.lovespace/amap_track_view_';
      final binding = tester.binding.defaultBinaryMessenger;
      binding.setMockMethodCallHandler(cfgCh, (call) async {
        if (call.method == 'hasApiKey') return true;
        return null;
      });
      addTearDown(() {
        binding.setMockMethodCallHandler(cfgCh, null);
        AmapTrackMapWidget.resetKeyCacheForTest();
      });

      const side = PeerTrackSide(
        level: 'exact',
        closedOff: false,
        distanceM: 1200,
        points: [
          PeerTrackPoint(ts: 1000, lat: 22.54, lng: 113.95, speed: 0.2),
          PeerTrackPoint(ts: 1300, lat: 22.541, lng: 113.951, speed: 1.1),
        ],
        stays: [],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 300,
              child: AmapTrackMapWidget(
                side: side,
                pathColor: Colors.pink,
                forceAndroidForTest: true,
                fallbackBuilder: (_) =>
                    const Center(child: Text('AMAP-CANVAS-FALLBACK')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final avFinder = find.byKey(const Key('track-amap-view'));
      expect(avFinder, findsOneWidget);
      final av = tester.widget<AndroidView>(avFinder);
      expect(av.gestureRecognizers, isNotNull);
      expect(
        av.gestureRecognizers!.any((f) {
          final rec = f.constructor();
          try {
            return rec is EagerGestureRecognizer;
          } finally {
            rec.dispose();
          }
        }),
        isTrue,
      );
      expect(find.text('AMAP-CANVAS-FALLBACK'), findsNothing);

      // Attach view channel via onPlatformViewCreated(0) then simulate native onMapError.
      av.onPlatformViewCreated?.call(0);
      await tester.pump();
      final codec = const StandardMethodCodec();
      await binding.handlePlatformMessage(
        '${viewPrefix}0',
        codec.encodeMethodCall(const MethodCall('onMapError', {
          'code': 'downloader:1008/403',
          'callback': 'ExceptionLogger.onDownloaderException',
          'message': 'AMap auth/tile error',
        })),
        (_) {},
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('track-amap-view')), findsNothing);
      expect(find.text('AMAP-CANVAS-FALLBACK'), findsOneWidget);
    });

    testWidgets('采集自检面板解析并高亮展示 map 错误码与触发回调', (tester) async {
      const nativeCh = MethodChannel('peer_loc/native');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        nativeCh,
        (call) async {
          switch (call.method) {
            case 'status':
              return <String, Object?>{'running': true, 'queue': 0};
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
                'location': <String, Object?>{'running': true, 'received': 3},
                'state': <String, Object?>{'enabled': true, 'emitted': 1},
                'usage': <String, Object?>{'granted': true, 'enabled': true},
                'permissions': <String, Object?>{
                  'fine': true,
                  'background': true,
                  'usage': true,
                  'notification': true,
                  'batteryIgnored': true,
                },
                'map': <String, Object?>{
                  'status': 'error',
                  'errorCode': 'downloader:1008/403',
                  'callback': 'ExceptionLogger.onDownloaderException',
                  'errorMessage': 'AMap downloader failed',
                  'errorAt': 1795747933000,
                },
                'policySummary': 'halted=false loc=exact',
                'policyHalted': false,
              };
            default:
              return <String, Object?>{};
          }
        },
      );
      addTearDown(() =>
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              nativeCh, null));

      final snap = await peerDiagnosticsStatus();
      expect(snap.mapStatus, 'error');
      expect(snap.mapErrorCode, 'downloader:1008/403');
      expect(snap.mapErrorCallback, 'ExceptionLogger.onDownloaderException');

      final c = _makeContainer((o) {
        if (o.uri.path == '/api/peer/settings') {
          return {
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
          };
        }
        if (o.uri.path == '/api/peer/policy-audit') {
          return {'items': <Object?>[]};
        }
        return const <String, Object?>{};
      });
      addTearDown(c.dispose);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(393, 859);
      addTearDown(tester.view.reset);

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
      expect(find.text('轨迹底图'), findsOneWidget);
      expect(
        find.textContaining('downloader:1008/403 · ExceptionLogger.onDownloaderException'),
        findsOneWidget,
      );
    });
  });
}
