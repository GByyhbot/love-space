/// 2.8.7 傍晚批 1-1：今日页双人混杂修复的专项护栏。
///
/// 断言：默认只渲染 TA；两人电量绝不混排；切「我」后状态卡/时间线整页随视角切换。
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
import 'package:love_space/core/sse/sse_client.dart';
import 'package:love_space/features/together/peer_report_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
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
    jsonEncode(data), status,
    headers: {Headers.contentTypeHeader: const ['application/json']});

const _native = MethodChannel('peer_loc/native');

final double _t = DateTime(2026, 11, 28, 15, 30).millisecondsSinceEpoch / 1000;

Map<String, Object?> _loc({
  required int battery,
  required bool charging,
  String wifi = 'CMCC-p3j5',
}) =>
    {
      'user': 'u',
      'lat': 36.66,
      'lng': 101.52,
      'acc': 12.0,
      'speed': 0.0,
      'battery': battery,
      'charging': charging,
      'net': 'wifi',
      'wifi': wifi,
      'updated': _t,
    };

Map<String, Object?> _event(String id, {required bool mine, required String summary}) => {
      'id': id,
      'user': mine ? 'me' : 'ta',
      'type': 'manual_report',
      'ts': _t,
      'summary': summary,
      'pushed': 1,
      'source': 'manual',
      'scene': 'arrive_home',
      'note': '',
      'place_name': '',
      'client_id': 'c-$id',
      'ack': null,
      'mine': mine,
      'payload': const {'text': ''},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, null);
  });

  testWidgets('默认只看 TA：两台手机的电量事件绝不混排；切「我」整页换人', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{kPeerExpectedKey: true});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, (call) async {
      switch (call.method) {
        case 'status':
          return {'running': true, 'received': 3, 'queue': 0, 'reported': 3};
        case 'batteryIgnored':
          return true;
        case 'permissions':
          return {'fine': true, 'background': true, 'usage': true,
                  'batteryOk': true, 'notify': true};
      }
      return null;
    });

    final adapter = _FakeAdapter((o) {
      if (o.path.contains('/api/peer/status')) {
        return _json({
          'revision': 9,
          // 她的手机：50% 未充电
          'mine': {'settings': {}, 'location': _loc(battery: 50, charging: false)},
          // TA 的手机：90% 充电中
          'peer': {
            'settings': {},
            'location': _loc(battery: 90, charging: true),
            'enabled': true,
            'closed_off': false,
          },
        });
      }
      if (o.path.contains('/api/peer/events')) {
        return _json({
          'date': '2026-11-28',
          'mine': [_event('m1', mine: true, summary: '我去加班了')],
          'peer': {
            'closed_off': false,
            'events': [_event('p1', mine: false, summary: 'TA 到公司了')],
          },
        });
      }
      if (o.path.contains('/api/peer/state-daily')) {
        return _json({
          'date': '2026-11-28',
          'mine': {'screen_sec': 300, 'unlocks': 2},
          'peer': {'closed_off': false, 'screen_sec': 600, 'unlocks': 5},
        });
      }
      if (o.path.contains('/api/peer/usage-daily')) {
        return _json({
          'date': '2026-11-28',
          'mine': {'closed_off': false, 'screen_sec': 300, 'unlocks': 2},
          'peer': {'closed_off': false, 'screen_sec': 600, 'unlocks': 5},
        });
      }
      return _json({
        'date': '2026-11-28',
        'mine': {'closed_off': false, 'level': 'exact', 'points': [], 'stays': []},
        'peer': {'closed_off': false, 'level': 'exact', 'points': [], 'stays': [],
                 'distance_m': 0.0},
      });
    });

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(393, 2400);
    addTearDown(tester.view.reset);
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final sse = StreamController<SseEvent>.broadcast();
    addTearDown(sse.close);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        sseEventsProvider.overrideWith((ref) => sse.stream),
      ],
      child: const MaterialApp(home: PeerReportPage()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    // 默认看 TA：标题与 TA 的事件在，我方事件不在
    expect(find.byKey(const Key('report-side-toggle')), findsOneWidget);
    expect(find.text('TA 的状态'), findsOneWidget);
    expect(find.byKey(const Key('report-event-p1')), findsOneWidget);
    expect(find.byKey(const Key('report-event-m1')), findsNothing,
        reason: '默认视角不得混入我的事件');
    expect(find.text('90%'), findsWidgets, reason: 'TA 的 90% 应展示');

    // 切到「我」：整页换人
    await tester.tap(find.text('我').last);
    await tester.pumpAndSettle();
    expect(find.text('我的状态'), findsOneWidget);
    expect(find.byKey(const Key('report-event-m1')), findsOneWidget);
    expect(find.byKey(const Key('report-event-p1')), findsNothing,
        reason: '「我」视角不得混入 TA 的事件');
    expect(find.text('50%'), findsWidgets, reason: '我的 50% 应展示');
    expect(find.text('90%'), findsNothing, reason: '切到「我」后不得残留 TA 的电量');

    // 事件接口本身仍按人分桶（不合并）
    expect(find.text('我去加班了'), findsOneWidget);
  });
}
