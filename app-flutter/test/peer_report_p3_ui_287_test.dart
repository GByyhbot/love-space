/// 2.8.7 第三段 · 报备页呈现层 UI 护栏（状态卡四形态 + 今日时间线）。
///
/// 纯函数口径已由 `peer_status_card_287_test` / `peer_timeline_287_test` 钉住，
/// 本文件只管**页面接线**是否照做：
/// ① 齐全 → 顶部出现「TA 的状态」卡，四行都在（key 定位）；
/// ② 缺项 → 缺的那几行真的不渲染（整行消失，不留「未知」占位）；
/// ③ 全缺 → 整张卡不出现（连标题都不出现），报备块照旧；
/// ④ 超 6 小时 → 「长时间无更新」明写；
/// ⑤ 时间线 → 三行乱序数据按时间倒序排（用 y 坐标比），文案用服务器中文；
/// ⑥ 兜底 → summary/payload 都空的事件也不出空行。
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

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final ResponseBody Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return handler(options);
  }
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {Headers.contentTypeHeader: const ['application/json']},
    );

const _native = MethodChannel('peer_loc/native');

final double _now = DateTime.now().millisecondsSinceEpoch / 1000;

/// 对方快照：**按传入的键集合**构造，便于测「字段缺失就整行不显示」。
Map<String, Object?> _loc(Map<String, Object?> extras) => {
      'user': 'ta',
      'lat': 39.9163,
      'lng': 116.3972,
      'acc': 12.0,
      'speed': 0.0,
      if (extras.isNotEmpty) ...extras,
    };

Map<String, Object?> _status({
  Map<String, Object?>? peerLoc,
  bool closedOff = false,
  Map<String, Object?> mineLoc = const {},
}) =>
    {
      'revision': 9,
      'mine': {
        'settings': {'events': true},
        'location': _loc(mineLoc),
        'enabled': true,
      },
      'peer': {
        'settings': {},
        'location': peerLoc,
        'enabled': !closedOff,
        'closed_off': closedOff,
      },
    };

Map<String, Object?> _daily({
  int screenSec = 3900,
  int unlocks = 12,
  bool closedOff = false,
}) =>
    {
      'date': '2026-11-26',
      'mine': {'screen_sec': 0, 'unlocks': 0},
      'peer': {
        'closed_off': closedOff,
        'screen_sec': screenSec,
        'unlocks': unlocks,
      },
    };

Map<String, Object?> _day({
  List<Object?> peer = const [],
  List<Object?> mine = const [],
}) =>
    {
      'date': '2026-11-26',
      'mine': mine,
      'peer': {'closed_off': false, 'events': peer},
    };

Map<String, Object?> _event({
  required String id,
  String type = 'manual_report',
  String summary = '平安到家啦',
  double? ts,
  String note = '',
  bool mine = false,
  Map<String, Object?> payload = const {},
}) =>
    {
      'id': id,
      'user': mine ? 'me' : 'ta',
      'type': type,
      'ts': ts ?? _now,
      'summary': summary,
      'pushed': 1,
      'source': type == 'manual_report' ? 'manual' : 'auto',
      'scene': 'arrive_home',
      'note': note,
      'place_name': '',
      'client_id': 'c-$id',
      'ack': null,
      'mine': mine,
      'payload': payload,
    };

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
          return {'running': true, 'received': 4, 'queue': 0};
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

  _Adapter adapter({
    Map<String, Object?>? peerLoc,
    Object? daily,
    int dailyStatus = 200,
    Object? dayBody,
    bool closedOff = false,
  }) =>
      _Adapter((o) {
        if (o.path == '/api/peer/status') {
          return _json(_status(peerLoc: peerLoc, closedOff: closedOff));
        }
        if (o.path == '/api/peer/track') {
          return _json({
            'date': '2026-11-26',
            'mine': <Object?>[],
            'peer': {'closed_off': true, 'points': <Object?>[]},
          });
        }
        if (o.path == '/api/peer/state-daily') {
          return _json(daily ?? _daily(), dailyStatus);
        }
        return _json(dayBody ?? _day());
      });

  /// 页面泵：视口开高一点，让状态卡 + 时间线一次性都建出来（y 坐标可比较）。
  Future<void> pumpPage(WidgetTester tester, _Adapter a) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(393, 2400);
    addTearDown(tester.view.reset);
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = a;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
      ],
      child: const MaterialApp(home: PeerReportPage()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 60));
  }

  group('状态卡四形态', () {
    testWidgets('齐全：标题 + 四行都在，值按口径', (tester) async {
      await pumpPage(
        tester,
        adapter(
          peerLoc: _loc({
            'battery': 82,
            'charging': false,
            'net': 'wifi',
            'wifi': 'home',
            'updated': _now - 600,
          }),
        ),
      );

      expect(find.text('TA 的状态'), findsOneWidget);
      expect(find.byKey(const Key('peer-card-battery')), findsOneWidget);
      expect(find.byKey(const Key('peer-card-net')), findsOneWidget);
      expect(find.byKey(const Key('peer-card-active')), findsOneWidget);
      expect(find.byKey(const Key('peer-card-usage')), findsNothing);

      expect(find.text('82%'), findsOneWidget);
      expect(find.text('82% · 未充电'), findsNothing);
      expect(find.text('Wi-Fi（home）'), findsOneWidget);
      expect(find.textContaining('长时间无更新'), findsNothing,
          reason: '10 分钟前不算失联');
      // 状态卡在最顶上（在手机使用/足迹/时间线之前）
      expect(
        tester.getTopLeft(find.text('TA 的状态')).dy,
        lessThan(tester.getTopLeft(find.text('手机使用')).dy),
      );
    });

    testWidgets('缺项：取不到的行整行不出现，其余行照常', (tester) async {
      await pumpPage(
        tester,
        adapter(
          // 只有坐标与时间：没电量、没网络
          peerLoc: _loc({'updated': _now - 600}),
        ),
      );

      expect(find.text('TA 的状态'), findsOneWidget);
      expect(find.byKey(const Key('peer-card-battery')), findsNothing,
          reason: '电量取不到就不许出现「未知」占位');
      expect(find.byKey(const Key('peer-card-net')), findsNothing);
      expect(find.byKey(const Key('peer-card-active')), findsOneWidget);
      expect(find.byKey(const Key('peer-card-usage')), findsNothing);
      // 卡内不许出现「未知」这类假占位（报备块的「最近报备 未知」是另一回事，
      // 那是既有口径，不归状态卡管）
      expect(
        find.descendant(
          of: find.byKey(const Key('peer-status-card')),
          matching: find.text('未知'),
        ),
        findsNothing,
      );
    });

    testWidgets('全缺：整卡不出现（标题也不出现），报备块照旧', (tester) async {
      await pumpPage(
        tester,
        adapter(
          peerLoc: null, // 对方从无任何快照（连坐标都没有）
          dailyStatus: 500, // 今日汇总也拿不到
        ),
      );

      expect(find.text('TA 还没有报备数据'), findsOneWidget);
      expect(find.byKey(const Key('peer-status-card')), findsNothing,
          reason: '一行都没有就别摆空壳卡');
      expect(find.byKey(const Key('peer-card-battery')), findsNothing);
      expect(find.byKey(const Key('peer-card-net')), findsNothing);
      expect(find.byKey(const Key('peer-card-active')), findsNothing);
      expect(find.byKey(const Key('peer-card-usage')), findsNothing);
    });

    testWidgets('超 6 小时：明写「长时间无更新」', (tester) async {
      await pumpPage(
        tester,
        adapter(
          peerLoc: _loc({
            'battery': 31,
            'charging': false,
            'updated': _now - 8 * 3600,
          }),
        ),
      );

      expect(find.textContaining('长时间无更新'), findsOneWidget);
      // 带年份的定位串，避免撞上我的报备块里的「最近一次上报」标签
      expect(find.textContaining('最近一次 2026'), findsOneWidget);
      expect(find.byKey(const Key('peer-card-active')), findsOneWidget);
    });
  });

  group('今日时间线', () {
    testWidgets('按时间倒序串成一条线，文案用服务器中文', (tester) async {
      await pumpPage(
        tester,
        adapter(
          peerLoc: _loc({'updated': _now - 60}),
          dayBody: _day(
            mine: [
              _event(id: 'm1', ts: _now - 3 * 3600, summary: '我去加班了'),
            ],
            peer: [
              // 顺序故意打乱：接口给的不是时间序
              _event(
                id: 'p1',
                ts: _now - 3600,
                type: 'state.battery',
                summary: '电量 66%，充电中',
                payload: const {'level': 66, 'charging': true},
              ),
              _event(
                id: 'p2',
                ts: _now - 5 * 3600,
                type: 'state.net',
                summary: '切到移动数据（服务端）',
                payload: const {'net': 'cell'},
              ),
            ],
          ),
        ),
      );

      expect(find.text('今日时间线'), findsOneWidget);
      double y(String id) =>
          tester.getTopLeft(find.byKey(Key('report-event-$id'))).dy;
      expect(y('p1'), lessThan(y('m1')), reason: '1 小时前应排在 3 小时前之上');
      expect(y('m1'), lessThan(y('p2')), reason: '3 小时前应排在 5 小时前之上');
      // 服务器 summary 优先于本地按 payload 拼的文案
      expect(find.text('切到移动数据（服务端）'), findsOneWidget);
      expect(find.text('切到移动数据'), findsNothing);
      expect(find.text('电量 66%，充电中'), findsOneWidget);
      expect(find.text('我去加班了'), findsOneWidget);
      // 手填报备保留回应区形态（没发明新组件）
      expect(find.byKey(const Key('report-ack-buttons-m1')), findsNothing,
          reason: '自己的报备不给回应按钮');
      expect(find.byKey(const Key('report-ack-buttons-p1')), findsNothing,
          reason: '状态事件是简行，无回应按钮');
    });

    testWidgets('summary 与 payload 都空也不出空白行', (tester) async {
      await pumpPage(
        tester,
        adapter(
          peerLoc: _loc({'updated': _now - 60}),
          dayBody: _day(peer: [
            _event(id: 's1', type: 'state.battery', summary: ''),
            _event(id: 's2', type: 'manual_report', summary: ''),
            _event(id: 's3', type: 'mystery_type', summary: ''),
          ]),
        ),
      );

      expect(find.text('电量发生变化'), findsOneWidget);
      expect(find.text('报备'), findsOneWidget);
      expect(find.text('有一条动态'), findsOneWidget);
      // 全页不许有空白 Text（空白行事故回归护栏）
      final texts = tester.widgetList<Text>(find.byType(Text));
      for (final t in texts) {
        expect((t.data ?? 'x').trim(), isNotEmpty,
            reason: '渲染出空白文本行：${t.data}');
      }
    });
  });
}
