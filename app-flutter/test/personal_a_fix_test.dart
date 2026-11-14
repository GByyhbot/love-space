/* 段 7-A 第 1 轮 QA 返修回归（4 个真缺陷，独立补测）：
   P0-1 换号隐私串号：真实 authProvider 状态迁移（me=null;state=out → me=B;
        state=authed）后 B 不得看到 A 的私密记录；logout() 作废私密控制器。
   P1-2 底栏 5 tab 窄屏：真实 ShellPage 扫宽 320/360/393/400/411/428 零
        RenderFlex overflow（tester.takeException）。
   P1-3 draft→post：不切 tab 直接读 timelineControllerProvider.state 即含该 id；
        draft→diary 不触发时光重拉。
   P2-4 兜底 uid 为空 fail-closed：diaries()/drafts() 返回空、不放行全量。
   其余原有 personal_a_test 11 例不回退（见该文件）。 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import 'package:love_space/core/sse/sse_client.dart'
    show SseClient, SsePhase, SseState, sseProvider;
import 'package:love_space/core/together/together_data.dart';
import 'package:love_space/features/auth/auth_state.dart';
import 'package:love_space/features/personal/personal_controller.dart';
import 'package:love_space/features/personal/personal_page.dart';
import 'package:love_space/features/shell/shell_page.dart';
import 'package:love_space/features/timeline/timeline_controller.dart'
    show timelineControllerProvider;

class _FixAdapter implements HttpClientAdapter {
  _FixAdapter(this.handler);
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

Map<String, Object> _me(String uid, {bool loggedOut = false}) => loggedOut
    ? <String, Object>{}
    : {
        'user': {'id': uid, 'name': uid == 'u1' ? '我' : 'TA', 'username': uid},
        'users': [
          {'id': 'u1', 'name': '我', 'username': 'u1'},
          {'id': 'u2', 'name': 'TA', 'username': 'u2'},
        ],
        'space': {}, 'unread': 0, 'chat_unread': 0,
      };

MeData _meData(String uid) => MeData(
      user: SpaceUser(id: uid, name: uid == 'u1' ? '我' : 'TA', username: uid),
      users: const [
        SpaceUser(id: 'u1', name: '我', username: 'u1'),
        SpaceUser(id: 'u2', name: 'TA', username: 'u2'),
      ],
      spaceName: '',
      spaceRaw: const {},
      spaceSince: '',
    );

Map<String, Object?> _rec({
  required String id,
  required String kind,
  required String author,
  required String content,
  double created = 1794544273.0,
}) =>
    {
      'id': id,
      'kind': kind,
      'author': author,
      'body': {'content': content, 'date': '2026-11-14', 'media': <String>[]},
      'created': created,
      'updated': created,
      'published': null,
      'client_id': 'cid-$id',
      'media': <Object>[],
      'likes': <Object>[],
      'comments': <Object>[],
    };

/// 越权夹具：A 的 diary/draft + B 的 diary/draft 一并返回（模拟服务端漏过滤）
final List<Object?> _abRecords = [
  _rec(id: 'a-diary', kind: 'diary', author: 'u1', content: 'A 的私密日记'),
  _rec(id: 'a-draft', kind: 'draft', author: 'u1', content: 'A 的草稿内容'),
  _rec(id: 'b-diary', kind: 'diary', author: 'u2', content: 'B 的私密日记'),
  _rec(id: 'b-draft', kind: 'draft', author: 'u2', content: 'B 的草稿内容'),
];

/// 仅一条草稿（发布流程用）
final List<Object?> _oneDraft = [
  _rec(id: 'dr1', kind: 'draft', author: 'u1', content: '（草稿）'),
];

/// 服务端在 draft→post 之后的时光数据：同一 id 以 post 身份出现
final List<Object?> _postAfterPublish = [
  _rec(id: 'dr1', kind: 'post', author: 'u1', content: '（草稿）'),
];

Future<ProviderContainer> _container(_FixAdapter adapter,
    {bool fakeSse = false}) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  final container = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
    mediaCookieHeadersProvider
        .overrideWith((ref) async => <String, String>{}),
    // 测试环境无 path_provider 通道：让 logout() 里的 jar 清理快速抛错
    // （被 logout 的 try/catch 兜住），否则 FakeAsync 区会挂住。
    api.cookieJarProvider.overrideWith((ref) async {
      throw StateError('test: no cookie jar');
    }),
    if (fakeSse) sseProvider.overrideWith(_FakeSse.new),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// 真实 ShellPage 扫宽用：SSE 不连网（只保留事件流与 notifier 接口）
class _FakeSse extends SseClient {
  @override
  SseState build() => const SseState(phase: SsePhase.idle);

  @override
  void start() {}
}

GoRouter _router() => GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
            path: '/home',
            builder: (_, _) => const PersonalPage()),
        GoRoute(
          path: '/personal/diary-form',
          builder: (_, state) {
            final extra = (state.extra as Map?) ?? const {};
            return DiaryFormPage(record: extra['record'] as TogetherRecord?);
          },
        ),
        GoRoute(
          path: '/personal/publish',
          builder: (_, state) {
            final extra = (state.extra as Map?) ?? const {};
            return DraftPublishPage(draft: extra['draft']! as TogetherRecord);
          },
        ),
      ],
    );

Future<void> _pumpPersonal(WidgetTester tester, ProviderContainer container) async {
  final router = _router();
  addTearDown(router.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pumpAndSettle();
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

void main() {
  // ── P0-1 换号隐私串号 ────────────────────────────────────────────
  group('P0-1 换号隐私（真实 authProvider 状态迁移）', () {
    testWidgets('A→B 换号后：A 的 diary/draft 全部消失、控制器只含 u2',
        (tester) async {
      String currentUid = 'u1';
      final adapter = _FixAdapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me(currentUid));
        if (o.method == 'GET' && o.uri.path == '/api/records') {
          return _json(_abRecords); // 故意把 A 的记录也返回
        }
        return _json(<String, Object>{});
      });
      final container = await _container(adapter);
      await _pumpPersonal(tester, container);

      // 换号前：A 视角只看到 A 的
      expect(find.textContaining('A 的私密日记'), findsWidgets);
      expect(find.textContaining('B 的私密日记'), findsNothing);

      final auth = container.read(authProvider.notifier);
      currentUid = 'u2';
      auth.me = null;
      // ignore: invalid_use_of_protected_member
      auth.state = AuthPhase.out;
      await tester.pumpAndSettle();
      auth.me = _meData('u2');
      // ignore: invalid_use_of_protected_member
      auth.state = AuthPhase.authed;
      await tester.pumpAndSettle();

      // diary tab：B 视角不得有 A 的私密日记
      expect(find.textContaining('A 的私密日记'), findsNothing);
      expect(find.textContaining('B 的私密日记'), findsWidgets);
      // draft tab 同样
      await tester.tap(find.text('草稿箱'));
      await tester.pumpAndSettle();
      expect(find.textContaining('A 的草稿内容'), findsNothing);
      expect(find.textContaining('B 的草稿内容'), findsWidgets);
      // 控制器 state 不允许残留任何非 u2 记录
      final recs = container.read(personalControllerProvider).records;
      expect(recs, isNotEmpty);
      expect(recs.every((r) => r.author == 'u2'), isTrue,
          reason: '控制器 state 不得缓存 A 账号的私密记录');
    });

    testWidgets('P0-1 ② logout() 作废 personalControllerProvider',
        (tester) async {
      bool loggedOut = false;
      final adapter = _FixAdapter((o, i) {
        if (o.uri.path == '/api/me') {
          return _json(_me('u1', loggedOut: loggedOut));
        }
        if (o.method == 'GET' && o.uri.path == '/api/records') {
          return _json(_abRecords);
        }
        return _json(<String, Object>{});
      });
      final container = await _container(adapter);
      await _pumpPersonal(tester, container);
      expect(container.read(personalControllerProvider).records, isNotEmpty);

      loggedOut = true;
      // dio POST 在 FakeAsync 区会挂住（Dio 的 requestStream/addProgress），
      // 用 runAsync 切到真实 async 区执行 logout。
      await tester.runAsync(
          () => container.read(authProvider.notifier).logout());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(container.read(personalControllerProvider).records, isEmpty,
          reason: '登出后私密控制器被 invalidate，缓存不带到下一个账号');
    });
  });

  // ── P1-2 底栏窄屏溢出 ───────────────────────────────────────────
  group('P1-2 ShellPage 五 tab 扫宽', () {
    testWidgets('320/360/393/400/411/428 六档零 RenderFlex overflow',
        (tester) async {
      final adapter = _FixAdapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me('u1'));
        return _json(<Object>[]);
      });
      final container = await _container(adapter, fakeSse: true);
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(393, 800);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ShellPage()),
      ));
      // 不用 pumpAndSettle：子页加载态的 CircularProgressIndicator 是无限动画，
      // 会让它超时；按帧 pump 即可拿到布局异常。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      const widths = <double>[320, 360, 393, 400, 411, 428];
      for (final w in widths) {
        tester.view.physicalSize = Size(w, 800);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        final e = tester.takeException();
        expect(e, isNull,
            reason: 'w=$w 时不得有 RenderFlex overflow 或其它异常（实际异常：$e）');
      }

      // 5 个入口文案都在、IndexedStack 可切到 index 4、AppBar 标题数组含个人角落
      for (final label in ['首页', '时光', '相册', '我们', '角落']) {
        expect(find.text(label), findsWidgets, reason: '$label 入口存在');
      }
      await tester.tap(find.text('角落'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('个人角落'), findsOneWidget);
      final stack = tester.widget<IndexedStack>(find.byType(IndexedStack).first);
      expect(stack.index, 4);
      expect(stack.children.length, 5);
      // FAB 缺口居中：M3 BottomAppBar padding 清零 + centerDocked
      final bar = tester.widget<BottomAppBar>(find.byType(BottomAppBar));
      expect(bar.padding, EdgeInsets.zero);
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });
  });

  // ── P1-3 draft→post 时光 tab 重拉 ────────────────────────────────
  group('P1-3 草稿发布后时光 tab 同步', () {
    _FixAdapter publishAdapter() => _FixAdapter((o, i) {
          if (o.uri.path == '/api/me') return _json(_me('u1'));
          if (o.method == 'GET' && o.uri.path == '/api/records') {
            final kind = o.queryParameters['kind'] ?? '';
            if (kind == 'post') return _json(_postAfterPublish);
            if (kind == personalKinds) return _json(_oneDraft);
            return _json(<Object>[]);
          }
          return _json(<String, Object>{});
        });

    testWidgets('draft→post：不切 tab，timelineControllerProvider 即含 dr1',
        (tester) async {
      final adapter = publishAdapter();
      final container = await _container(adapter);
      await _pumpPersonal(tester, container);
      expect(container.read(timelineControllerProvider).posts, isEmpty);

      await tester.tap(find.text('草稿箱'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('发布').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认发布')); // 默认 post
      await tester.pumpAndSettle();

      expect((adapter.requests.lastWhere((r) => r.method == 'PUT').data
          as Map)['kind'], 'post');
      expect(
          container
              .read(timelineControllerProvider)
              .posts
              .any((r) => r.id == 'dr1'),
          isTrue,
          reason: '发布 post 后必须显式触发时光重拉（不依赖 tab 切回）');
      expect(
          adapter.requests,
          anyElement(predicate<RequestOptions>((r) =>
              r.method == 'GET' &&
              r.uri.path == '/api/records' &&
              r.queryParameters['kind'] == 'post')));
      await _flush(tester);
    });

    testWidgets('draft→diary：不触发时光重拉', (tester) async {
      final adapter = publishAdapter();
      final container = await _container(adapter);
      await _pumpPersonal(tester, container);
      await tester.tap(find.text('草稿箱'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('发布').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('存为私密日记'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认发布'));
      await tester.pumpAndSettle();

      final put = adapter.requests.lastWhere((r) => r.method == 'PUT');
      expect((put.data as Map)['kind'], 'diary');
      expect(
          adapter.requests,
          isNot(anyElement(predicate<RequestOptions>((r) =>
              r.method == 'GET' &&
              r.uri.path == '/api/records' &&
              r.queryParameters['kind'] == 'post'))),
          reason: 'diary 目标不应触发时光重拉');
      expect(container.read(timelineControllerProvider).posts, isEmpty);
      await _flush(tester);
    });
  });

  // ── P2-4 兜底 uid 为空 fail-closed ───────────────────────────────
  group('P2-4 fail-closed', () {
    test('uid 兜底取不到时不放行全量记录', () async {
      final adapter = _FixAdapter((o, i) {
        if (o.uri.path == '/api/me') return _json(<String, Object>{});
        if (o.method == 'GET' && o.uri.path == '/api/records') {
          return _json(_abRecords);
        }
        return _json(<String, Object>{});
      });
      final container = await _container(adapter);
      final ctrl = container.read(personalControllerProvider.notifier);
      await ctrl.bootstrap();
      expect(container.read(personalControllerProvider).records, isEmpty);
      expect(ctrl.diaries(), isEmpty);
      expect(ctrl.drafts(), isEmpty);
    });
  });
}
