/// 2.8.0 报备入口 P0 · UI 护栏（施工令四·4/5/6）。
///
/// 覆盖：
/// ④ 胶囊条：单击按预设参数发送 / 长按 sheet 沿用预设 summary+push /
///    首页手势护栏（布局流内，可滚动 + 其它卡片可达）/ presets 失败回落默认 6 条；
/// ⑤ 事件流卡片状态机：对方未 ack 有按钮 / 点击后整区禁用防连点 /
///    成功变「已回应」/ 我方两态文案 / closed_off 明示行；
/// ⑥ 发送失败入队、422 关闭文案 + 「去开启」动作（2.8.0 P1：点击跳
///    PeerShareSettingsPage，闭环接管 P0 遗留缺口）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/peer/peer_report_queue.dart';
import 'package:love_space/core/sse/sse_client.dart'
    show SseClient, SseEvent, SsePhase, SseState, sseEventsProvider, sseProvider;
import 'package:go_router/go_router.dart';
import 'package:love_space/features/chat/chat_toast.dart'
    show
        ChatToastController,
        ChatToastHost,
        ChatToastMessage,
        ChatToastTone,
        chatToastProvider;
import 'package:love_space/features/home/report_capsule_bar.dart'
    show ReportCapsuleBar, reportPresetsProvider;
import 'package:love_space/features/settings/peer_share_settings_page.dart';
import 'package:love_space/features/together/peer_report_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return handler(options);
  }

  /// 精确路径匹配（`contains` 会把 `/api/peer/report-presets` 也算进
  /// `/api/peer/report`，断言会假阳性）。
  Iterable<RequestOptions> byPath(String path) =>
      requests.where((r) => r.path == path);
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: const ['application/json'],
      },
    );

class _FakeSse extends SseClient {
  @override
  SseState build() => const SseState(phase: SsePhase.idle);
  @override
  void start() {}
}

class _NoTimerToastController extends ChatToastController {
  @override
  void show(String text, {ChatToastTone tone = ChatToastTone.info}) {
    state = ChatToastMessage(id: 1, text: text, tone: tone);
  }

  /// 2.8.0 P1：带动作的提示也要渲染出来（同样不挂定时器）。
  @override
  void showAction(
    String text, {
    required String actionLabel,
    required VoidCallback onAction,
    ChatToastTone tone = ChatToastTone.error,
  }) {
    state = ChatToastMessage(
      id: 1,
      text: text,
      tone: tone,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }
}

const _native = MethodChannel('peer_loc/native');

List<Map<String, Object?>> _presets() => [
      {
        'scene': 'arrive_home',
        'label': '到家了',
        'emoji': '🏠',
        'summary': '平安到家啦',
        'push': true,
      },
      {
        // 静默预设：补备注时 push 必须保持 false（不许被升级成强推送）
        'scene': 'meal',
        'label': '吃饭中',
        'emoji': '🍚',
        'summary': '正在干饭',
        'push': false,
      },
    ];

Map<String, Object?> _day({List<Object?> peer = const [], List<Object?> mine = const [], bool closedOff = false}) => {
      'date': '2026-11-24',
      'mine': mine,
      'peer': {'closed_off': closedOff, 'events': peer},
    };

Map<String, Object?> _event({
  required String id,
  String type = 'manual_report',
  String summary = '平安到家啦',
  double? ts,
  String scene = 'arrive_home',
  Object? ack,
  bool mine = false,
}) =>
    {
      'id': id,
      'user': mine ? 'me' : 'ta',
      'type': type,
      'ts': ts ?? DateTime.now().millisecondsSinceEpoch / 1000,
      'summary': summary,
      'pushed': 1,
      'source': type == 'manual_report' ? 'manual' : 'auto',
      'scene': scene,
      'note': '',
      'place_name': '',
      'client_id': 'c-$id',
      'ack': ack,
      'mine': mine,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late ReportOutbox outbox;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, (call) async {
      switch (call.method) {
        case 'status':
          return {'running': true, 'received': 3, 'queue': 0};
        case 'batteryIgnored':
          return true;
      }
      return null;
    });
    tmp = Directory.systemTemp.createTempSync('report-ui-');
    outbox = ReportOutbox(dirProvider: () async => tmp);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ProviderContainer makeContainer(_Adapter adapter) {
    final dio = Dio(BaseOptions(
      baseUrl: 'https://test.local',
      validateStatus: api.validateAppStatus,
    ))..httpClientAdapter = adapter;
    final c = ProviderContainer(overrides: [
      api.dioProvider.overrideWith((ref) async => dio),
      sseProvider.overrideWith(_FakeSse.new),
      sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
      chatToastProvider.overrideWith(_NoTimerToastController.new),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  /// 胶囊条单测泵：默认给全量路由（presets/events/POST）。
  Future<void> pumpBar(
    WidgetTester tester,
    ProviderContainer c, {
    Size size = const Size(393, 800),
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Scaffold(
          body: ListView(key: const Key('page-scroll'), children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: ReportCapsuleBar(outbox: outbox),
            ),
            // 手势护栏用：同页其它卡片（可点）+ 足量滚动内容
            SizedBox(
              height: 900,
              child: Center(
                child: Builder(
                  builder: (_) => const Text('其它卡片占位'),
                ),
              ),
            ),
          ]),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
  }

  /// 带路由 + 顶部提示层的泵页：断言 422「去开启」跳到共享开关页
  /// 必须是真实 GoRouter（`context.push` 依赖 GoRouter.of）。
  Future<void> pumpBarWithRouter(WidgetTester tester, ProviderContainer c) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(393, 800);
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/t',
      routes: [
        GoRoute(
          path: '/t',
          builder: (_, _) => Scaffold(
            body: Column(children: [
              const ChatToastHost(),
              Expanded(
                child: ListView(children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: ReportCapsuleBar(outbox: outbox),
                  ),
                ]),
              ),
            ]),
          ),
        ),
        GoRoute(
          path: '/settings/peer-share',
          builder: (_, _) => const PeerShareSettingsPage(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
  }

  _Adapter fullAdapter({
    Future<ResponseBody> Function(RequestOptions)? onPost,
    Object? presetBody,
    Object? dayBody,
  }) {
    return _Adapter((o) async {
      if (o.path.contains('/api/peer/report-presets')) {
        return _json(presetBody ?? {'presets': _presets()});
      }
      if (o.path.contains('/api/peer/events/') && o.path.endsWith('/ack')) {
        return onPost?.call(o) ??
            Future.value(_json({'ok': true, 'event': _event(id: 'p1')}));
      }
      if (o.path.contains('/api/peer/events')) {
        return _json(dayBody ?? _day());
      }
      if (o.path.contains('/api/peer/settings')) {
        return _json({
          'location': true,
          'track': true,
          'events': true,
          'usage': true,
        });
      }
      if (o.path.contains('/api/peer/report')) {
        return onPost?.call(o) ??
            Future.value(_json({
              'ok': true,
              'created': true,
              'event': _event(id: 'new'),
            }));
      }
      return _json({});
    });
  }

  group('④ 胶囊条', () {
    testWidgets('单击：按预设参数发送（scene/summary/push + client_id 非空）', (tester) async {
      final adapter = fullAdapter();
      final c = makeContainer(adapter);
      await pumpBar(tester, c);

      await tester.tap(find.byKey(const Key('report-capsule-arrive_home')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      final post = adapter.byPath('/api/peer/report').toList();
      expect(post.length, 1, reason: '单击即发一次，不多发');
      final body = post.single.data as Map;
      expect(body['scene'], 'arrive_home');
      expect(body['summary'], '平安到家啦');
      expect(body['push'], true);
      expect((body['client_id'] as String).isNotEmpty, isTrue);
      expect(c.read(chatToastProvider)?.text, '已报备给 TA');
      await tester.pumpAndSettle(); // 排空墨水扩散等动画，避免残留 Timer
    });

    testWidgets('长按：sheet 补备注/地点，scene/summary/push 仍沿静默预设', (tester) async {
      final adapter = fullAdapter();
      final c = makeContainer(adapter);
      await pumpBar(tester, c);

      await tester.longPress(find.byKey(const Key('report-capsule-meal')));
      await tester.pumpAndSettle();
      expect(find.text('备注（可选）'), findsOneWidget);

      await tester.enterText(find.byType(TextField).at(0), '加班半小时');
      await tester.enterText(find.byType(TextField).at(1), '公司 12 楼');
      await tester.tap(find.byKey(const Key('report-compose-send')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 60));

      final body = adapter.byPath('/api/peer/report').single.data as Map;
      expect(body['note'], '加班半小时');
      expect(body['place_name'], '公司 12 楼');
      expect(body['scene'], 'meal');
      expect(body['summary'], '正在干饭', reason: '补备注不改预设 summary');
      expect(body['push'], false, reason: '静默预设补备注也不许升级强推送');
    });

    testWidgets('presets 失败回落：仍渲染默认 6 条，不空白', (tester) async {
      final failing = _Adapter((o) async {
        if (o.path.contains('/api/peer/report-presets')) {
          return _json({'detail': 'boom'}, 500);
        }
        if (o.path.contains('/api/peer/events')) return _json(_day());
        return _json({});
      });
      final c = makeContainer(failing);
      await pumpBar(tester, c);

      // 横向 ListView 惰性构建，只断言可见的前几条 + 数据源本身是 6 条
      expect(find.byKey(const Key('report-capsule-depart')), findsOneWidget);
      expect(find.byKey(const Key('report-capsule-arrive_home')),
          findsOneWidget);
      final presets = await c.read(reportPresetsProvider.future);
      expect(presets.length, 6, reason: '接口失败回落默认 6 条');
      expect(presets.map((e) => e.scene).toList(), [
        'depart',
        'arrive_home',
        'meal',
        'busy',
        'sleep',
        'miss',
      ]);
    });

    testWidgets('网络失败：入队待发 + 提示，client_id 与请求一致', (tester) async {
      final adapter = fullAdapter(
        onPost: (o) async => throw DioException.connectionError(
          requestOptions: o,
          reason: 'offline',
        ),
      );
      final c = makeContainer(adapter);
      await pumpBar(tester, c);

      await tester.tap(find.byKey(const Key('report-capsule-arrive_home')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      expect(c.read(chatToastProvider)?.text, '网络不畅，已存待发');
      final queued = await outbox.load();
      expect(queued.length, 1);
      final sentId =
          (adapter.byPath('/api/peer/report').single.data as Map)['client_id'];
      expect(queued.single.clientId, sentId,
          reason: '同一次发送的重试必须复用同一 client_id');
    });

    testWidgets('422 关闭：固定文案 + 「去开启」→ 跳共享开关页 + 不入队', (tester) async {
      final adapter = fullAdapter(
        onPost: (o) async => _json({'detail': '报备事件共享已关闭'}, 422),
      );
      final c = makeContainer(adapter);
      await pumpBarWithRouter(tester, c);

      await tester.tap(find.byKey(const Key('report-capsule-arrive_home')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pumpAndSettle();

      expect(c.read(chatToastProvider)?.text, '已关闭报备事件共享，开启后才能发报备');
      expect(await outbox.load(), isEmpty, reason: '422 不入队，重试无意义');

      // 2.8.0 P1：P0 遗留的「去开启」缺口闭环——动作存在且能导航
      final action = find.byKey(const Key('toast-action'));
      expect(action, findsOneWidget, reason: '422 提示必须带「去开启」动作');
      expect(find.text('去开启'), findsOneWidget);

      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.byType(PeerShareSettingsPage), findsOneWidget,
          reason: '「去开启」应 push 到 /settings/peer-share');
      // 开关页按服务端真实值渲染（夹具全开）。
      // 2.8.7 全量重构后该开关在分档区之后，需滚动到可见（断言口径不变）
      await tester.scrollUntilVisible(
        find.byKey(const Key('peer-share-events')), 200,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('peer-share-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.byKey(const Key('peer-share-events')), findsOneWidget);
    });

    testWidgets('最近一条小字：有对方 manual 报备才渲染，无则整行不渲染', (tester) async {
      final adapter = fullAdapter(
        dayBody: _day(peer: [
          _event(
            id: 'p1',
            ts: DateTime.now()
                    .subtract(const Duration(minutes: 12))
                    .millisecondsSinceEpoch /
                1000,
          )
        ]),
      );
      final c = makeContainer(adapter);
      await pumpBar(tester, c);
      expect(find.byKey(const Key('report-capsule-recent')), findsOneWidget);
      expect(find.textContaining('TA · 到家了 ·'), findsOneWidget);

      // 空数据 → 整行不渲染（不占位造假）
      final emptyAdapter = fullAdapter(dayBody: _day());
      final c2 = makeContainer(emptyAdapter);
      await pumpBar(tester, c2);
      expect(find.byKey(const Key('report-capsule-recent')), findsNothing);
    });

    testWidgets('首页手势护栏：胶囊条在布局流内，页面可滚动、其它区域可达', (tester) async {
      final adapter = fullAdapter();
      final c = makeContainer(adapter);
      await pumpBar(tester, c);

      // ① 胶囊点击可用（命中自身而不是某层透明拦截）
      await tester.tap(find.byKey(const Key('report-capsule-arrive_home')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(adapter.byPath('/api/peer/report').length, 1);
      await tester.pumpAndSettle();

      // ② 可滚动：拖动后占位文本上移（有覆盖层时滚动根本不会生效）
      final before = tester.getTopLeft(find.text('其它卡片占位')).dy;
      await tester.drag(
          find.byKey(const Key('page-scroll')), const Offset(0, -260));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final after = tester.getTopLeft(find.text('其它卡片占位')).dy;
      expect(after, lessThan(before), reason: '覆盖层存在时滚动不会生效');
    });
  });

  group('⑤ 事件流卡片状态机', () {
    Future<void> pumpPage(WidgetTester tester, ProviderContainer c) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(393, 1400);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: PeerReportPage()),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 60));
    }

    _Adapter pageAdapter({
      required Object dayBody,
      Future<ResponseBody> Function(RequestOptions)? onAck,
    }) =>
        _Adapter((o) async {
          if (o.path.contains('/api/peer/status')) {
            return _json({
              'revision': 3,
              'mine': {'settings': {}, 'location': null, 'enabled': true},
              'peer': {'settings': {}, 'location': null, 'enabled': true},
            });
          }
          if (o.path.contains('/api/peer/track')) {
            return _json({'date': '2026-11-24', 'peer': {'closed_off': true, 'points': []}});
          }
          if (o.path.endsWith('/ack')) {
            return onAck?.call(o) ?? Future.value(_json({'ok': true, 'event': {}}));
          }
          return _json(dayBody);
        });

    testWidgets('对方未 ack → 三个回应按钮；我方两态文案；自动事件简行', (tester) async {
      final adapter = pageAdapter(
        dayBody: _day(
          peer: [_event(id: 'p1')],
          mine: [
            _event(id: 'm1', mine: true),
            _event(id: 'm2', mine: true, ack: {'by': 'ta', 'emoji': '🫂'}),
          ],
        ),
      );
      final c = makeContainer(adapter);
      await pumpPage(tester, c);

      expect(find.byKey(const Key('report-ack-buttons-p1')), findsOneWidget);
      expect(find.text('等待对方回应'), findsOneWidget);
      expect(find.text('对方已收到 🫂'), findsOneWidget);
      expect(find.byKey(const Key('report-ack-buttons-m1')), findsNothing,
          reason: '自己的报备不给回应按钮');
    });

    testWidgets('点击 ack：请求期间整区禁用（防连点），成功后就地变已回应', (tester) async {
      final gate = Completer<void>();
      final adapter = pageAdapter(
        dayBody: _day(peer: [_event(id: 'p1')]),
        onAck: (o) async {
          await gate.future;
          return _json({
            'ok': true,
            'event': _event(
              id: 'p1',
              ack: {'by': 'me', 'emoji': '❤️'},
            ),
          });
        },
      );
      final c = makeContainer(adapter);
      await pumpPage(tester, c);

      await tester.tap(find.byKey(const Key('report-ack-p1-❤️')));
      await tester.pump(); // 请求挂起

      // 期间三个按钮全部禁用
      for (final emoji in ['❤️', '🫂', '👍']) {
        final btn = tester.widget<OutlinedButton>(
            find.byKey(Key('report-ack-p1-$emoji')));
        expect(btn.onPressed, isNull, reason: '请求未返回前必须禁用，防重复推送');
      }

      gate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('已回应 ❤️'), findsOneWidget);
      expect(find.byKey(const Key('report-ack-buttons-p1')), findsNothing,
          reason: '已回应不再给按钮');
    });

    testWidgets('ack 失败：按钮恢复可用 + 顶部通知，不做本地假成功', (tester) async {
      final adapter = pageAdapter(
        dayBody: _day(peer: [_event(id: 'p1')]),
        onAck: (o) async => _json({'detail': '网络异常'}, 500),
      );
      final c = makeContainer(adapter);
      await pumpPage(tester, c);

      await tester.tap(find.byKey(const Key('report-ack-p1-👍')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      final btn =
          tester.widget<OutlinedButton>(find.byKey(const Key('report-ack-p1-👍')));
      expect(btn.onPressed, isNotNull, reason: '失败要恢复可用，让用户重试');
      expect(find.text('已回应 👍'), findsNothing, reason: '不许本地假成功');
      expect(c.read(chatToastProvider)?.text, isNotNull);
    });

    testWidgets('closed_off：整节明示「TA 已关闭报备共享」', (tester) async {
      final adapter = pageAdapter(dayBody: _day(closedOff: true));
      final c = makeContainer(adapter);
      await pumpPage(tester, c);
      expect(find.byKey(const Key('report-events-closed')), findsOneWidget);
      expect(find.text('今天还没有报备'), findsOneWidget);
    });

    testWidgets('自动事件维持简行：不渲染回应按钮', (tester) async {
      final adapter = pageAdapter(
        dayBody: _day(peer: [
          _event(id: 'a1', type: 'arrive_place', summary: '到了公司'),
        ]),
      );
      final c = makeContainer(adapter);
      await pumpPage(tester, c);
      expect(find.text('到了公司'), findsOneWidget);
      expect(find.byKey(const Key('report-ack-buttons-a1')), findsNothing);
    });
  });
}
