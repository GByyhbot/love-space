import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/sse/sse_client.dart';
import 'package:love_space/features/together/amap_track_map.dart';
import 'package:love_space/features/together/peer_track_page.dart';
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

const _track = {
  'date': '2026-11-28',
  'mine': {'closed_off': false, 'level': 'exact', 'points': [], 'stays': []},
  'peer': {
    'closed_off': false,
    'level': 'exact',
    'distance_m': 820.0,
    'points': [
      {'ts': 1000, 'lat': 36.6600, 'lng': 101.5200, 'speed': 1.2, 'acc': 8.0},
      {'ts': 1600, 'lat': 36.6650, 'lng': 101.5250, 'speed': 1.6, 'acc': 9.0},
      {'ts': 2200, 'lat': 36.6690, 'lng': 101.5290, 'speed': 1.1, 'acc': 7.0},
    ],
    'stays': [
      {
        'lat': 36.6600,
        'lng': 101.5200,
        'arrived_at': 1000,
        'left_at': 1200,
        'duration_sec': 200,
        'place_name': '矿区宿舍',
      },
    ],
  },
};

Widget _page(ProviderContainer c, {bool embedded = true}) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: embedded
            ? const Scaffold(body: PeerTrackPage())
            : PeerTrackPage(embedded: false),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('cn.iepose.lovespace/amap_config'), null);
  });

  Future<ProviderContainer> pumpPage(WidgetTester tester,
      {bool embedded = true}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('cn.iepose.lovespace/amap_config'),
            (call) async => call.method == 'hasApiKey' ? false : null);
    final adapter = _Adapter((o) {
      if (o.path.contains('/api/peer/track')) return _json(_track);
      if (o.path.contains('/api/peer/events')) {
        return _json({'date': '2026-11-28', 'mine': [], 'peer': []});
      }
      return _json({
        'revision': 1,
        'mine': {'settings': {}, 'location': null, 'enabled': true},
        'peer': {'settings': {}, 'location': null, 'enabled': true},
      });
    });
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = adapter;
    final c = ProviderContainer(overrides: [
      api.dioProvider.overrideWith((ref) async => dio),
      sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(_page(c, embedded: embedded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    return c;
  }

  group('1-3 轨迹地图全屏', () {
    testWidgets('入口进全屏：地图铺满、停留列表隐藏、回放条与切换仍可达', (tester) async {
      await pumpPage(tester);
      expect(find.byKey(const Key('track-fullscreen-enter')), findsOneWidget);
      expect(find.textContaining('矿区宿舍'), findsWidgets);

      await tester.tap(find.byKey(const Key('track-fullscreen-enter')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('track-fullscreen-exit')), findsOneWidget);
      expect(find.textContaining('矿区宿舍'), findsNothing,
          reason: '全屏态停留列表必须隐藏');
      expect(find.byKey(const Key('track-side-toggle')), findsOneWidget,
          reason: 'TA/我 切换在全屏仍可达');
      expect(find.byKey(const Key('track-replay')), findsWidgets,
          reason: '回放条在全屏仍可用');
    });

    testWidgets('收起按钮退全屏；地图 State 不重建（相机不被重置）', (tester) async {
      await pumpPage(tester);
      final before = tester.state(find.byType(AmapTrackMapWidget));

      await tester.tap(find.byKey(const Key('track-fullscreen-enter')));
      await tester.pumpAndSettle();
      final during = tester.state(find.byType(AmapTrackMapWidget));
      expect(identical(before, during), isTrue,
          reason: '进出全屏必须是同一棵树上的同一个 State');

      await tester.tap(find.byKey(const Key('track-fullscreen-exit')));
      await tester.pumpAndSettle();
      final after = tester.state(find.byType(AmapTrackMapWidget));
      expect(identical(before, after), isTrue);
      expect(find.textContaining('矿区宿舍'), findsWidgets);
    });

    testWidgets('系统返回两段式：先退全屏、再退页面', (tester) async {
      // 真路由栈：首页 → push 轨迹页（root 路由无法 pop，必须走 push）
      await pumpPage(tester, embedded: false);
      final navState = tester.state<NavigatorState>(find.byType(Navigator));
      navState.push(MaterialPageRoute<void>(
          builder: (_) => const PeerTrackPage(embedded: false)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('track-fullscreen-enter')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('track-fullscreen-exit')), findsOneWidget);

      final ctx = tester.element(find.byType(PeerTrackPage));
      await Navigator.of(ctx).maybePop();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('track-fullscreen-exit')), findsNothing,
          reason: '第一次返回只退全屏');
      expect(find.byType(PeerTrackPage), findsOneWidget,
          reason: '第一次返回不得离开页面');

      expect(navState.canPop(), isTrue, reason: '第二次返回前路由仍可 pop');
      await navState.maybePop();
      await tester.pumpAndSettle();
      expect(navState.canPop(), isFalse,
          reason: '第二次返回才真正离开轨迹页');
    });

    testWidgets('全屏子树零背景模糊滤镜（零新增硬件成本）', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('track-fullscreen-enter')));
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
    });
  });
}
