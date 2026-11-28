/// 1-3 全屏态浅/深两色截图（`flutter test --update-goldens` 落盘到 output/精修截图/）。
library;

import 'dart:convert';
import 'dart:io' show Platform;


import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/sse/sse_client.dart';
import 'package:love_space/features/together/peer_track_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

const bool _doCapture =
    bool.fromEnvironment('CAPTURE_FULLSCREEN', defaultValue: false);

class _A implements HttpClientAdapter {
  _A(this.h);
  final ResponseBody Function(RequestOptions) h;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s,
          Future<void>? f) async =>
      h(o);
}

ResponseBody _j(Object d) => ResponseBody.fromString(jsonEncode(d), 200,
    headers: {Headers.contentTypeHeader: const ['application/json']});

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
      {'lat': 36.6600, 'lng': 101.5200, 'arrived_at': 1000, 'left_at': 1200,
       'duration_sec': 200, 'place_name': '矿区宿舍'},
    ],
  },
};

Future<void> _capture(WidgetTester tester, Brightness brightness, String name) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('cn.iepose.lovespace/amap_config'),
          (c) async => c.method == 'hasApiKey' ? false : null);
  final dio = Dio(BaseOptions(baseUrl: 'https://t.local'))
    ..httpClientAdapter = _A((o) {
      if (o.path.contains('/api/peer/track')) return _j(_track);
      if (o.path.contains('/api/peer/events')) {
        return _j({'date': '2026-11-28', 'mine': [], 'peer': {'closed_off': false, 'events': []}});
      }
      return _j({
        'revision': 1,
        'mine': {'settings': {}, 'location': null, 'enabled': true},
        'peer': {'settings': {}, 'location': null, 'enabled': true},
      });
    });
  final c = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
  ]);
  addTearDown(c.dispose);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(393, 852);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: MaterialApp(
      theme: ThemeData(brightness: brightness, useMaterial3: true),
      home: const Scaffold(body: PeerTrackPage()),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(find.byKey(const Key('track-fullscreen-enter')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 180));
  await tester.pump(const Duration(milliseconds: 220));
  await expectLater(find.byType(MaterialApp),
      matchesGoldenFile('../../output/精修截图/track_fullscreen_$name.png'));
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  // 与 polish_visual_capture_test 同一约定：截图测试只在 Windows 上、
  // 且显式 --dart-define=CAPTURE_FULLSCREEN=true 时跑（golden 是本地字体渲染，
  // Linux CI 逐像素必不同；CI 跳过，出图只在本机做）。
  if (!_doCapture || !Platform.isWindows) {
    test('fullscreen capture skipped (needs CAPTURE_FULLSCREEN=true on Windows)', () {});
    return;
  }
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('全屏浅色', (t) => _capture(t, Brightness.light, 'light'));
  testWidgets('全屏深色', (t) => _capture(t, Brightness.dark, 'dark'));
}
