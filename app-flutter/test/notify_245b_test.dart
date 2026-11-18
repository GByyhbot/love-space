/// 2.4.5 乙组测试：第 4 项通知中心点击跳转（逐类钉死 + 映射表覆盖护栏）+
/// 第 3 项设置页「消息通知」（权限/服务状态/测试通知/放行引导）。
/// widget 用例沿用 notify_a_test 的夹具基建（fake dio adapter + stub router）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/notify/notify_decision.dart';
import 'package:love_space/features/chat/chat_toast.dart'
    show ChatToastController, ChatToastHost, ChatToastMessage, ChatToastTone,
        chatToastProvider;
import 'package:love_space/features/notify/notices_page.dart';
import 'package:love_space/features/settings/notify_settings_page.dart';
import 'package:love_space/features/settings/settings_home_page.dart';

// ── 第 4 项：noticeTargetOf 逐类映射表（纯函数）──────────────────────────

void main() {
  group('第 4 项 · noticeTargetOf 逐类映射表', () {
    test('记录类带 record_id → recordStory（弹层直显该条）', () {
      for (final event in ['activity', 'comment', 'note', 'surprise']) {
        final t = noticeTargetOf(event, 'rec-1');
        expect(t.kind, NoticeTargetKind.recordStory, reason: event);
      }
      // anniversary 双形态：记录型（worker.py:239 带 rid）→ 弹层
      expect(noticeTargetOf('anniversary', 'rec-9').kind,
          NoticeTargetKind.recordStory);
      // wish 记录型（worker.py:242 带 rid）→ 弹层
      expect(noticeTargetOf('wish', 'rec-w').kind, NoticeTargetKind.recordStory);
    });

    test('提醒类无 rid → 直达功能页（kNoticeRoutes）', () {
      expect(noticeTargetOf('anniversary', '').kind, NoticeTargetKind.route);
      expect(noticeTargetOf('anniversary', '').route, '/together/anniversary');
      expect(noticeTargetOf('period', '').route, '/period');
      expect(noticeTargetOf('wish', '').route, '/together/wish');
      expect(noticeTargetOf('habit', '').route, '/together/habit');
    });

    test('运维类无 rid → 兜底弹层（非死条目：有内容 + 标已读）', () {
      for (final event in ['system', 'storage', 'backup']) {
        final t = noticeTargetOf(event, '');
        expect(t.kind, NoticeTargetKind.fallback, reason: event);
      }
    });

    test('映射表覆盖通知中心现行全部 12 事件类型（护栏：新类型漏配'
        '必有显式落点，不许死条目）', () {
      const allEvents = [
        'chat', 'comment', 'note', 'activity', 'anniversary', 'period',
        'wish', 'surprise', 'habit', 'backup', 'storage', 'system',
      ];
      for (final e in allEvents) {
        // 12 类任一 (event, recordId) 组合都返回合法落点（不许死条目）
        final tEmpty = noticeTargetOf(e, '');
        expect(NoticeTargetKind.values.contains(tEmpty.kind), isTrue,
            reason: '$e 空 recordId 落点合法');
        final tRid = noticeTargetOf(e, 'rid');
        expect(NoticeTargetKind.values.contains(tRid.kind), isTrue,
            reason: '$e 带 recordId 落点合法');
      }
      // chat 在通知中心首行被过滤（notices_page.dart:95-97），防御性断言：
      // 即便漏进来也有兜底落点
      expect(noticeTargetOf('chat', '').kind, NoticeTargetKind.fallback);
    });
  });

  // ── 第 4 项 widget：点击通知 → 跳转 ────────────────────────────────────

  final notices = <Map<String, dynamic>>[
    {
      'id': 'n1', 'event': 'activity', 'title': 'TA 发布了新动态',
      'record_id': 'r1', 'created': 1731667200.0, 'seen': 0,
    },
    {
      'id': 'n2', 'event': 'period', 'title': '生理期快到了',
      'record_id': '', 'created': 1731660000.0, 'seen': 0,
    },
    {
      'id': 'n3', 'event': 'system', 'title': '空间开启',
      'record_id': '', 'created': 1731650000.0, 'seen': 0,
    },
  ];

  final record = <String, dynamic>{
    'id': 'r1', 'kind': 'post', 'author': 'u2',
    'body': {'content': '这是一条新动态的正文', 'media': []},
    'created': 1731660000.0, 'client_id': 'c1',
    'likes': <String>[], 'comments': <Map>[], 'media': <Map>[],
  };

  testWidgets('点击 activity（有 rid）→ 拉单条记录弹层直显内容并标已读',
      (tester) async {
    final env = await _Env.make(notices, record);
    final router = env.router;
    await _pump(tester, env.app('/notices'));
    await tester.tap(find.byKey(const Key('notice-detail-n1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('这是一条新动态的正文'), findsWidgets,
        reason: 'recordStory 弹层直显该条内容（历史上的今天同款弹层）');
    // 弹层是 modal：已读标记在弹层关闭后才发（await 语义）——点遮罩关掉
    await tester.tapAt(const Offset(50, 400));
    await tester.pumpAndSettle();
    expect(env.readCalls, contains('r1'), reason: '查看后按 record_id 单条已读');
    router.dispose();
  });

  testWidgets('点击 period（无 rid）→ 直达 /period 功能页并标已读',
      (tester) async {
    final env = await _Env.make(notices, record);
    final router = env.router;
    await _pump(tester, env.app('/notices'));
    await tester.tap(find.byKey(const Key('notice-card-n2')));
    await tester.pumpAndSettle();
    expect(find.text('STUB-PERIOD'), findsOneWidget);
    expect(env.readCalls, contains(''), reason: '无 rid 时按空 record_id 标已读');
    router.dispose();
  });

  testWidgets('点击 system（兜底）→ 弹层呈现服务端内容 + 已读（非死条目）',
      (tester) async {
    final env = await _Env.make(notices, record);
    final router = env.router;
    await _pump(tester, env.app('/notices'));
    await tester.tap(find.byKey(const Key('notice-card-n3')));
    await tester.pumpAndSettle();
    expect(find.text('这一刻的故事'), findsOneWidget);
    expect(find.text('空间开启'), findsWidgets, reason: '列表行 + 弹层两处');
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(env.readCalls, contains(''), reason: '兜底弹层关闭后标已读');
    router.dispose();
  });

  // ── 第 3 项：设置页「消息通知」──────────────────────────────────────────

  testWidgets('设置主页「连接与提醒」组内有「消息通知」行 → 跳 /settings/notify',
      (tester) async {
    final env = await _Env.make(notices, record, initial: '/settings');
    final router = env.router;
    // 设置主页是长索引页：懒构建 ListView，滚到底部找「消息通知」行
    await _pump(tester, env.app('/settings'));
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-home-notify')),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-home-notify')));
    await tester.pumpAndSettle();
    expect(find.text('发送测试通知'), findsOneWidget);
    router.dispose();
  });

  testWidgets('通知设置页：权限/服务状态渲染 + 测试通知入口 + 放行引导入口',
      (tester) async {
    queryPermissionEnabled = () async => false;
    queryServiceRunning = () async => false;
    addTearDown(() {
      queryPermissionEnabled = null;
      queryServiceRunning = null;
    });
    final env = await _Env.make(notices, record, initial: '/settings/notify');
    final router = env.router;
    await _pump(tester, env.app('/settings/notify'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notify-perm-row')), findsOneWidget);
    expect(find.text('未授权'), findsOneWidget);
    expect(find.byKey(const Key('notify-service-restart')), findsOneWidget,
        reason: '服务未运行时提供「重新开启」动作');
    expect(find.byKey(const Key('notify-test-row')), findsOneWidget);
    // 放行引导 sheet：入口 → 三步框架渲染（菜单名以真机为准的诚实边界注明）
    await tester.tap(find.byKey(const Key('notify-guide-row')));
    await tester.pumpAndSettle();
    expect(find.text('小米手机放行三步'), findsOneWidget);
    expect(find.textContaining('自启动'), findsWidgets);
    expect(find.textContaining('电池策略'), findsWidgets);
    expect(find.textContaining('最近任务'), findsWidgets);
    await tester.tap(find.byKey(const Key('notify-guide-done')));
    await tester.pumpAndSettle();
    expect(find.text('小米手机放行三步'), findsNothing);
    router.dispose();
  });
}

// ── 夹具（精简自 notify_a_test.dart 的 _Store/_FakeAdapter/_Env）────────

class _Env {
  final Dio dio;
  final GoRouter router;
  final List<String> readCalls;
  _Env(this.dio, this.router, this.readCalls);

  static Future<_Env> make(
      List<Map<String, dynamic>> notices,
      Map<String, dynamic> record,
      {String initial = '/notices'}) async {
    final readCalls = <String>[];
    final adapter = _FakeAdapter(notices, record, readCalls);
    final dio = Dio(BaseOptions(
      baseUrl: 'https://test.local',
      validateStatus: api.validateAppStatus,
    ))..httpClientAdapter = adapter;
    final router = GoRouter(
      initialLocation: initial,
      routes: <RouteBase>[
        GoRoute(path: '/notices', builder: (_, _) => const NoticesPage()),
        GoRoute(path: '/settings', builder: (_, _) => const SettingsHomePage()),
        GoRoute(
            path: '/settings/notify',
            builder: (_, _) => const NotifySettingsPage()),
        GoRoute(
          path: '/period',
          builder: (_, _) => const Scaffold(
            key: Key('stub-period'),
            body: Center(child: Text('STUB-PERIOD')),
          ),
        ),
        GoRoute(
          path: '/together/anniversary',
          builder: (_, _) => const Scaffold(body: Center(child: Text('STUB-ANNI'))),
        ),
        GoRoute(
          path: '/together/wish',
          builder: (_, _) => const Scaffold(body: Center(child: Text('STUB-WISH'))),
        ),
        GoRoute(
          path: '/together/habit',
          builder: (_, _) => const Scaffold(body: Center(child: Text('STUB-HABIT'))),
        ),
      ],
    );
    return _Env(dio, router, readCalls);
  }

  Widget app(String initial) {
    return UncontrolledProviderScope(
      container: _container(),
      child: MaterialApp.router(
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => Stack(
          children: <Widget>[
            child ?? const SizedBox.shrink(),
            const Positioned(
              top: 0, left: 0, right: 0,
              child: IgnorePointer(child: SafeArea(child: ChatToastHost())),
            ),
          ],
        ),
      ),
    );
  }

  ProviderContainer _container() {
    final c = ProviderContainer(overrides: <Override>[
      api.dioProvider.overrideWith((ref) async => dio),
      chatToastProvider.overrideWith(_NoTimerToastController.new),
      api.baseProvider.overrideWith((ref) async => 'https://test.local'),
    ]);
    return c;
  }
}

class _FakeAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> notices;
  final Map<String, dynamic> record;
  final List<String> readCalls;
  _FakeAdapter(this.notices, this.record, this.readCalls);

  @override
  void close({bool force = false}) {}

  ResponseBody _json(Object data, [int status = 200]) =>
      ResponseBody.fromString(jsonEncode(data), status,
          headers: {
            Headers.contentTypeHeader: const <String>['application/json'],
          });

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final method = options.method;
    if (method == 'GET' && path == '/api/notices') return _json(notices);
    if (method == 'GET' && path == '/api/me') {
      return _json(<String, dynamic>{
        'user': <String, dynamic>{'id': 'u1', 'name': '我', 'username': 'u1'},
        'users': <Map<String, dynamic>>[
          {'id': 'u1', 'name': '我', 'username': 'u1'},
          {'id': 'u2', 'name': 'TA', 'username': 'u2'},
        ],
        'space': <String, dynamic>{'name': '小家'},
        'unread': notices.where((n) => n['seen'] == 0).length,
        'chat_unread': 0,
      });
    }
    if (method == 'GET' && path.startsWith('/api/records/')) {
      return _json(record);
    }
    if (method == 'POST' && path == '/api/notices/read') {
      // record_id 走 query（notify_api.dart:114-116），非 body
      readCalls.add(options.uri.queryParameters['record_id'] ?? '');
      return _json(<String, dynamic>{'ok': true});
    }
    return _json(<String, dynamic>{});
  }
}

class _NoTimerToastController extends ChatToastController {
  @override
  void show(String text, {ChatToastTone tone = ChatToastTone.info}) {
    state = ChatToastMessage(id: 1, text: text, tone: tone);
  }
}

Future<void> _pump(WidgetTester tester, Widget w) async {
  tester.view.physicalSize = const Size(1080, 3600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(w);
  await tester.pump(const Duration(milliseconds: 10));
  await tester.pumpAndSettle();
}
