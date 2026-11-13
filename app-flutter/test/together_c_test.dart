/* 「我们」页段 C 单测（条目 6 · 情侣问答 + 共同打卡）：
   ① 数据层：answers/checks/answer_count 解析（内容过滤口径依赖服务端，
      客户端只透传）
   ② 控制器：answer → POST /records/{rid}/answer {content}；checkHabit →
      POST /records/{rid}/check 无 body；写后重拉
   ③ 问答页：揭晓态（双方答案都显示）/ 未齐态（只显示自己的 + 揭示提示）/
      回答表单预填可改（ON CONFLICT UPDATE 口径）/ 提问表单题库回填 / 取消不误写
   ④ 打卡页：打卡 POST 无 body、重拉后按钮翻转、同日重复点不产生脏数据
     （reload 后状态以服务端为准）、对方今天状态可见
   ⑤ hub 两张新卡就位（无死卡纪律） */
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import 'package:love_space/core/together/together_data.dart';
import 'package:love_space/features/chat/chat_toast.dart' show ChatToastHost;
import 'package:love_space/features/together/question_habit_pages.dart';
import 'package:love_space/features/together/together_controller.dart';
import 'package:love_space/features/together/together_page.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions options, int callIndex) handler;
  final List<RequestOptions> requests = [];
  int calls = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return handler(options, calls++);
  }
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
    jsonEncode(data), status,
    headers: {Headers.contentTypeHeader: const ['application/json']});

Map<String, Object> _toolRecord(String id, String kind,
        {Map<String, Object> body = const {}, String author = 'u1',
        List<Object> answers = const [], int answerCount = 0,
        List<Object> checks = const []}) =>
    {
      'id': id, 'kind': kind, 'author': author,
      'body': body,
      'created': 1000.0, 'updated': 1000.0, 'client_id': '',
      'media': const <Object>[],
      'answers': answers,
      'answer_count': answerCount,
      'checks': checks,
      'likes': const <Object>[], 'comments': const <Object>[],
    };

String _today() {
  final d = DateTime.now();
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

Map<String, Object> _meFixture = {
  'user': {'id': 'u1', 'name': '我', 'username': 'u1'},
  'users': [
    {'id': 'u1', 'name': '我', 'username': 'u1'},
    {'id': 'u2', 'name': 'TA', 'username': 'u2'},
  ],
  'space': {}, 'unread': 0, 'chat_unread': 0,
};

_FakeAdapter _withMe(ResponseBody Function(RequestOptions, int) inner) =>
    _FakeAdapter((options, i) {
      if (options.uri.path == '/api/me') return _json(_meFixture);
      return inner(options, i);
    });

void main() {
  group('① 数据层解析', () {
    test('answers/answerCount/checks 解析 + 畸形容错', () {
      final r = TogetherRecord.fromJson(_toolRecord('q1', 'question',
          body: {'title': '第一次见面'},
          answers: [
            {'record_id': 'q1', 'author': 'u1', 'content': '在图书馆'},
          ],
          answerCount: 1,
          checks: [
            {'record_id': 'q1', 'author': 'u1', 'day': _today()},
            'junk',
          ]).cast<String, dynamic>());
      expect(r.answers.single['content'], '在图书馆');
      expect(r.answerCount, 1);
      expect(r.checks.single['day'], _today());
      final empty = TogetherRecord.fromJson(
          _toolRecord('q2', 'question', body: {'title': 'x'})
              .cast<String, dynamic>());
      expect(empty.answers, isEmpty);
      expect(empty.answerCount, 0);
    });
  });

  group('② 控制器子资源', () {
    test('answer：POST /records/{rid}/answer {content}，写后重拉', () async {
      var posted = false;
      final adapter = _withMe((options, i) {
        if (options.method == 'POST' && options.uri.path == '/api/records/q1/answer') {
          posted = true;
          return _json({'ok': true});
        }
        return _json([
          _toolRecord('q1', 'question',
              body: {'title': '第一次见面'},
              answers: posted
                  ? [
                      {'record_id': 'q1', 'author': 'u1', 'content': '在图书馆'},
                    ]
                  : [],
              answerCount: posted ? 1 : 0),
        ]);
      });
      final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
        ..httpClientAdapter = adapter;
      final container = ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
      ]);
      addTearDown(container.dispose);
      await container.read(togetherControllerProvider.notifier).bootstrap();
      final err = await container
          .read(togetherControllerProvider.notifier)
          .answer('q1', '在图书馆');
      expect(err, isNull);
      final post = adapter.requests.firstWhere((r) => r.method == 'POST');
      expect(post.uri.path, '/api/records/q1/answer');
      expect((post.data as Map)['content'], '在图书馆');
      expect(container
          .read(togetherControllerProvider)
          .records
          .single
          .answers
          .single['content'], '在图书馆', reason: '重拉后答案入 state');
    });

    test('checkHabit：POST /records/{rid}/check 无 body，重拉状态以后端为准', () async {
      var checked = false;
      final adapter = _withMe((options, i) {
        if (options.method == 'POST' && options.uri.path == '/api/records/h1/check') {
          checked = true;
          return _json({'ok': true});
        }
        return _json([
          _toolRecord('h1', 'habit',
              body: {'title': '早睡'},
              checks: checked
                  ? [
                      {'record_id': 'h1', 'author': 'u1', 'day': _today()},
                    ]
                  : []),
        ]);
      });
      final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
        ..httpClientAdapter = adapter;
      final container = ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
      ]);
      addTearDown(container.dispose);
      await container.read(togetherControllerProvider.notifier).bootstrap();
      final rec = container.read(togetherControllerProvider).records.single;
      expect(rec.checks, isEmpty, reason: '打卡前无记录');
      final err = await container
          .read(togetherControllerProvider.notifier)
          .checkHabit('h1');
      expect(err, isNull);
      final post = adapter.requests.firstWhere((r) => r.method == 'POST');
      expect(post.uri.path, '/api/records/h1/check');
      expect(post.data, isNull, reason: 'check 无 body');
      expect(container
          .read(togetherControllerProvider)
          .records
          .single
          .checks
          .single['author'], 'u1', reason: '重拉后打卡状态以后端为准');
    });
  });

  group('③ 情侣问答页', () {
    ProviderContainer widgetSetup(_FakeAdapter adapter) {
      final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
        ..httpClientAdapter = adapter;
      return ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
        mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
      ]);
    }

    Future<void> pumpPage(WidgetTester tester, ProviderContainer container,
        {Widget page = const QuestionPage()}) async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => Stack(children: [
            child ?? const SizedBox.shrink(),
            const Positioned(
                top: 0, left: 0, right: 0,
                child: IgnorePointer(child: SafeArea(child: ChatToastHost()))),
          ]),
          home: page,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('揭晓态：双方答案都显示；未齐态：只有自己的 + 提示', (tester) async {
      final adapter = _withMe((options, i) {
        return _json([
          _toolRecord('q1', 'question',
              body: {'title': '已到齐的问题'},
              answers: [
                {'record_id': 'q1', 'author': 'u1', 'content': '我的答案A'},
                {'record_id': 'q1', 'author': 'u2', 'content': 'TA的答案B'},
              ],
              answerCount: 2),
          _toolRecord('q2', 'question',
              body: {'title': '还没答齐的问题'},
              answers: [
                {'record_id': 'q2', 'author': 'u1', 'content': '我的答案C'},
              ],
              answerCount: 1),
        ]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      expect(find.text('我的答案A'), findsOneWidget);
      expect(find.text('TA 的答案'), findsOneWidget, reason: '双方都答 → 对方答案可见');
      expect(find.text('TA的答案B'), findsOneWidget);
      expect(find.text('我的答案C'), findsOneWidget);
      expect(find.text('TA的答案C'), findsNothing, reason: '未齐态对方答案不下发');
      expect(find.text('对方的答案要等 TA 也回答后才会揭晓。'), findsOneWidget);
      expect(find.textContaining('两个人的答案都到齐啦'), findsOneWidget);
    });

    testWidgets('回答表单：预填自己已存答案 → 更新答案 POST（可改口径）', (tester) async {
      var answerPosts = 0;
      final adapter = _withMe((options, i) {
        if (options.method == 'POST' && options.uri.path == '/api/records/q1/answer') {
          answerPosts++;
          return _json({'ok': true});
        }
        return _json([
          _toolRecord('q1', 'question',
              body: {'title': '第一次见面'},
              answers: [
                {'record_id': 'q1', 'author': 'u1', 'content': '在图书馆'},
              ],
              answerCount: 1),
        ]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      await tester.tap(find.text('修改我的答案'));
      await tester.pumpAndSettle();
      expect(find.text('在图书馆'), findsWidgets, reason: '预填自己已存答案（可改）');
      await tester.enterText(find.byType(TextFormField).first, '在图书馆门口');
      await tester.tap(find.text('更新答案'));
      await tester.pumpAndSettle();
      expect(answerPosts, 1);
      final post = adapter.requests.firstWhere(
          (r) => r.method == 'POST' && r.uri.path.endsWith('/answer'));
      expect((post.data as Map)['content'], '在图书馆门口');
      expect(find.text('答案已更新'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('提问表单：题库挑选回填标题；取消不误写', (tester) async {
      var postCount = 0;
      final adapter = _withMe((options, i) {
        if (options.method == 'POST' && options.uri.path == '/api/records') {
          postCount++;
          return _json(_toolRecord('qNew', 'question',
              body: (options.data['body'] as Map).cast<String, Object>()));
        }
        return _json([]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      await tester.tap(find.byTooltip('提个问题'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(postCount, 0, reason: '取消不误写');

      await tester.tap(find.byTooltip('提个问题'));
      await tester.pumpAndSettle();
      // 题库挑选：下拉选一条 → 回填标题
      await tester.tap(find.text('或从题库挑一个'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('回忆 · 第一次心动').last);
      await tester.pumpAndSettle();
      expect(
          (find.byType(TextFormField).evaluate().first.widget as TextFormField)
              .controller!
              .text,
          '第一次心动，是哪个瞬间？',
          reason: '题库挑选回填标题');
      await tester.tap(find.text('提问'));
      await tester.pumpAndSettle();
      expect(postCount, 1);
      final post = adapter.requests.firstWhere((r) => r.method == 'POST');
      expect(post.data['kind'], 'question');
      expect(((post.data['body'] as Map)['title'] as String)
          .startsWith('第一次心动'), isTrue);
      expect(find.text('问题已提出，等 TA 一起回答'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('④ 共同打卡页', () {
    ProviderContainer widgetSetup(_FakeAdapter adapter) {
      final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
        ..httpClientAdapter = adapter;
      return ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
        mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
      ]);
    }

    Future<void> pumpPage(WidgetTester tester, ProviderContainer container) async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => Stack(children: [
            child ?? const SizedBox.shrink(),
            const Positioned(
                top: 0, left: 0, right: 0,
                child: IgnorePointer(child: SafeArea(child: ChatToastHost()))),
          ]),
          home: const HabitPage(),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('打卡：POST 无 body → 重拉按钮翻转；对方今天状态可见；重复点不脏',
        (tester) async {
      var checkPosts = 0;
      final adapter = _withMe((options, i) {
        if (options.method == 'POST' && options.uri.path == '/api/records/h1/check') {
          checkPosts++;
          return _json({'ok': true});
        }
        return _json([
          _toolRecord('h1', 'habit',
              body: {'title': '一起早睡'},
              checks: [
                // 对方今天已打卡；我方打卡状态由 checkPosts 模拟服务端
                {'record_id': 'h1', 'author': 'u2', 'day': _today()},
                if (checkPosts > 0)
                  {'record_id': 'h1', 'author': 'u1', 'day': _today()},
              ]),
        ]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      expect(find.text('TA今天已打卡 ✓'), findsOneWidget, reason: '对方状态可见（跨账号互看）');
      expect(find.text('今天也一起坚持'), findsOneWidget);

      await tester.tap(find.text('今天也一起坚持'));
      await tester.pumpAndSettle();
      expect(checkPosts, 1);
      final post = adapter.requests
          .firstWhere((r) => r.method == 'POST' && r.uri.path.endsWith('/check'));
      expect(post.data, isNull, reason: 'check 无 body');
      expect(find.text('今天已打卡'), findsOneWidget, reason: '重拉后状态以后端为准不回弹');
      expect(find.text('今天也一起向前了一小步'), findsOneWidget);

      // 同一天重复点：仍 POST（服务端 OR IGNORE 幂等），reload 后状态不变
      await tester.tap(find.text('今天已打卡'));
      await tester.pumpAndSettle();
      expect(checkPosts, 2);
      expect(find.text('今天已打卡'), findsOneWidget, reason: '重复点不产生脏数据');
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('⑤ hub 新卡', () {
    testWidgets('问答/打卡两卡就位', (tester) async {
      final adapter = _withMe((options, i) => _json([]));
      final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
        ..httpClientAdapter = adapter;
      final container = ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
        mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: TogetherPage(active: true)),
      ));
      await tester.pumpAndSettle();
      expect(find.text('情侣问答'), findsOneWidget);
      expect(find.text('共同打卡'), findsOneWidget);
    });
  });
}
