/* 「UI/布局优化」段 A（2.2.8/VC228）· 错误通道欠账清偿 4xx 单测。
   7-C 纪律：validateAppStatus 放行 4xx → 每个写方法显式 writeResponseError。
   本文件逐处断言：① detail 原文直通（非兜底文案、非异常对象 dump）；
   ② 不假成功（本地状态未变 / 不 reload / 不重拉 / 不 pop）。
   覆盖落点：api_client.uploadMedia / together_controller 5 写 /
   home_page mood 2 写 / bubble_skin_sheet PUT /api/space /
   chat_repository.sendChatBody / auth_state.logout /
   music uploadMusicToPlaylist（MediaValidationError 直通呈现）。
   夹具与生产共用 validateAppStatus 形状（api_client.dart:275-278 明令）。
   跑前 unset 八个代理变量（flutter_tester 本地 WebSocket 会被代理劫持）。 */
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart'
    show MediaValidationError;
import 'package:love_space/core/chat/chat_models.dart';
import 'package:love_space/core/chat/chat_repository.dart';
import 'package:love_space/core/chat/chat_state.dart'
    show
        ChatPersistence,
        ChatPendingRow,
        ChatRecordRow,
        chatControllerProvider,
        chatPersistenceProvider;
import 'package:love_space/core/sse/sse_client.dart'
    show SseEvent, sseEventsProvider;
import 'package:love_space/features/auth/auth_state.dart';
import 'package:love_space/features/chat/bubble_skin_sheet.dart';
import 'package:love_space/features/chat/chat_toast.dart'
    show
        ChatToastController,
        ChatToastHost,
        ChatToastMessage,
        ChatToastTone,
        chatToastProvider;
import 'package:love_space/features/home/home_page.dart';
import 'package:love_space/features/personal/personal_controller.dart'
    show personalCurrentUserProvider;
import 'package:love_space/features/together/music_page.dart'
    show uploadMusicToPlaylist;
import 'package:love_space/features/together/together_controller.dart';

// ── 夹具 ─────────────────────────────────────────────────────────────

/// 可编程应答：key = 'METHOD path'（records 子资源按完整路径精确匹配）
class _Reply {
  const _Reply(this.status, this.body);
  final int status;
  final Object body;
}

class _Store {
  final List<RequestOptions> requests = <RequestOptions>[];
  final Map<String, _Reply> replies = <String, _Reply>{};
  /// GET /api/records 返回的 records 列表（首页 mood 行用）
  List<Map<String, dynamic>> recordsJson = <Map<String, dynamic>>[];
  int meGets = 0; // /api/me 计数：auth reload 会 +1（不 reload 断言用）
  int recordGets = 0; // /api/records GET 计数：invalidate 重拉会 +1
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
    jsonEncode(data), status,
    headers: {Headers.contentTypeHeader: const ['application/json']});

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.store);
  final _Store store;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    store.requests.add(options);
    final String path = options.uri.path;
    final String method = options.method;

    if (method == 'GET' && path == '/api/me') {
      store.meGets++;
      return _json(<String, dynamic>{
        // 2.4.6 按人皮肤：user 带三键（sheet 初始 _pick 取 user.bubbleSkin，
        // 空串会让「使用这个」禁用）
        'user': <String, dynamic>{'id': 'u1', 'name': '我', 'username': 'u1',
          'bubble_skin': 'g1/b1.png', 'bubble_fg': 'dark', 'bubble_swap': 1},
        'users': <Object>[
          <String, dynamic>{'id': 'u1', 'name': '我', 'username': 'u1'},
          <String, dynamic>{'id': 'u2', 'name': 'TA', 'username': 'u2'},
        ],
        'space': <String, dynamic>{
          'name': '我们的小世界',
          'since': '2020-05-20',
          'theme': 'rose',
          'custom_color': '',
          'motion': true,
          'timezone': 'Asia/Shanghai',
          'chat_bubble': 'g1/b1.png',
        },
        'unread': 0,
        'chat_unread': 0,
      });
    }
    if (method == 'GET' && path == '/api/records') {
      store.recordGets++;
      return _json(store.recordsJson);
    }
    if (method == 'GET' && path == '/api/dashboard') {
      return _json(<String, dynamic>{
        'total': 0, 'likes': 0, 'comments': 0, 'photos': 0,
      });
    }
    if (method == 'GET' && path == '/api/bubbles') {
      return _json(<String, dynamic>{
        'groups': <Object>[
          <String, dynamic>{'id': 'g1', 'count': 2, 'items': ['b1.png', 'b2.png']},
        ],
      });
    }
    // 显式判通道：测试用 replies 精确匹配 'METHOD path'，未配置则 200 {}
    final _Reply? reply = store.replies['$method $path'];
    if (reply != null) return _json(reply.body, reply.status);
    return _json(const <String, dynamic>{});
  }
}

Dio _dio(_Store store) => Dio(BaseOptions(
      baseUrl: 'https://test.local',
      validateStatus: api.validateAppStatus, // 🔴 与生产共用同一形状
    ))..httpClientAdapter = _FakeAdapter(store);

/// 测试替身：保留顶部通知文本（供原文断言），不启动 2.2s Timer，
/// 避免 flutter_test 结束时 `A Timer is still pending` 不变量失败。
class _NoTimerToastController extends ChatToastController {
  @override
  void show(String text, {ChatToastTone tone = ChatToastTone.info}) {
    state = ChatToastMessage(id: 1, text: text, tone: tone);
  }
}

ProviderContainer _container(_Store store) {
  final Dio dio = _dio(store);
  final ProviderContainer c = ProviderContainer(overrides: <Override>[
    api.dioProvider.overrideWith((ref) async => dio),
    chatToastProvider.overrideWith(_NoTimerToastController.new),
    api.baseProvider.overrideWith((ref) async => 'https://test.local'),
    sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    personalCurrentUserProvider.overrideWith((ref) => 'u1'),
  ]);
  addTearDown(c.dispose);
  return c;
}

Widget _app(ProviderContainer c, {required GoRouter router}) =>
    UncontrolledProviderScope(
      container: c,
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

GoRouter _router({
  required Widget Function(BuildContext) home,
  List<GoRoute> extra = const <GoRoute>[],
}) =>
    GoRouter(
      initialLocation: '/',
      routes: <RouteBase>[
        GoRoute(path: '/', builder: (ctx, _) => home(ctx)),
        GoRoute(path: '/profile',
            builder: (ctx, _) => const Scaffold(body: Text('page-profile'))),
        GoRoute(path: '/together/anniversary',
            builder: (ctx, _) =>
                const Scaffold(body: Text('page-anniversary'))),
        ...extra,
      ],
    );

Future<void> _pump(WidgetTester tester, Widget w) async {
  tester.view.physicalSize = const Size(1080, 3600);
  tester.view.devicePixelRatio = 1.0;
  // 2.4.3 双卡落首页后页内有了 InkWell（需 Material 祖先）；裸 pump 页面
  // 统一套一层不占布局的 Material（对齐 settings_242/shell_gesture 先例）。
  await tester.pumpWidget(Material(child: w));
  await tester.pump(const Duration(milliseconds: 10));
  await tester.pumpAndSettle();
}

/// 进入页面后**延迟打开弹层**（FakeAsync 纪律：延迟 400ms 让 bootstrap 的
/// Timer.run 宏任务先经 pump 推进完成，弹层 initState 才能读到 me）
class _OpenOnFrame extends StatefulWidget {
  const _OpenOnFrame(this.open);
  final void Function(BuildContext context) open;

  @override
  State<_OpenOnFrame> createState() => _OpenOnFrameState();
}

class _OpenOnFrameState extends State<_OpenOnFrame> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) widget.open(context);
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.shrink());
}

/// 聊天 pending 落盘内存替身（chat_media_test 同款形状）
class _MemStore implements ChatPersistence {
  @override
  Future<void> saveRecords(List<ChatRecord> rs) async {}

  @override
  Future<List<ChatRecord>> loadRecords() async => const <ChatRecord>[];

  @override
  Future<void> upsertPending(ChatPending p) async {}

  @override
  Future<void> deletePending(String clientId) async {}

  @override
  Future<List<ChatPending>> loadPending() async => const <ChatPending>[];

  @override
  Future<void> saveMySticker(String userId, String mid, String name) async {}

  @override
  Future<void> deleteMySticker(String userId, String mid) async {}

  @override
  Future<List<(String, String)>> loadMyStickers(String userId) async =>
      const <(String, String)>[];
}

// ── ① api_client.uploadMedia（头像/封面上传，4xx 显式判）─────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('api_client.uploadMedia 4xx 显式判', () {
    test('422：detail 原文经 errorDetail 直通（不假成功返回 id）', () async {
      final _Store store = _Store();
      store.replies['POST /api/media'] =
          const _Reply(422, <String, dynamic>{'detail': '头像文件超过大小上限'});
      final ProviderContainer c = _container(store);
      final Dio dio = await c.read(api.dioProvider.future);
      Object? caught;
      try {
        await api.uploadMedia(dio, 'avatar.png', <int>[1, 2, 3]);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<DioException>(),
          reason: '失败必须抛（与 5xx 同通道），绝不能返回 "null" mid');
      expect(api.errorDetail(caught), '头像文件超过大小上限',
          reason: '调用方既有 catch + errorDetail 即取到原文，非兜底文案');
      expect(store.requests, hasLength(1));
    });

    test('200：返回 id（形状不变，成功路径不受影响）', () async {
      final _Store store = _Store();
      store.replies['POST /api/media'] = const _Reply(200, <String, dynamic>{
        'id': 'm1', 'mime': 'image/png', 'name': 'a.png', 'status': 'pending',
      });
      final ProviderContainer c = _container(store);
      final Dio dio = await c.read(api.dioProvider.future);
      final String mid = await api.uploadMedia(dio, 'a.png', <int>[1]);
      expect(mid, 'm1');
    });
  });

  // ── ② together_controller 5 写（清单/愿望/问答/打卡页面共用）────────
  group('together_controller 5 写 4xx 显式判', () {
    test('add/edit/delete/answer/checkHabit：返回 detail 原文且不 reload（不假成功）',
        () async {
      final _Store store = _Store();
      store.replies['POST /api/records'] =
          const _Reply(422, <String, dynamic>{'detail': '许愿内容不合规'});
      store.replies['PUT /api/records/r1'] =
          const _Reply(403, <String, dynamic>{'detail': '只能修改自己写的内容'});
      store.replies['DELETE /api/records/r1'] =
          const _Reply(403, <String, dynamic>{'detail': '只有本人能删除这条记录'});
      store.replies['POST /api/records/r1/answer'] =
          const _Reply(422, <String, dynamic>{'detail': '答案要在 1..5000 字之间'});
      store.replies['POST /api/records/r1/check'] =
          const _Reply(409, <String, dynamic>{'detail': '今天已经打过卡了'});
      final ProviderContainer c = _container(store);
      final TogetherController ctrl = c.read(togetherControllerProvider.notifier);
      await ctrl.bootstrap(); // 首次 load：1 次 GET /api/records
      final int getsAfterLoad = store.recordGets;

      expect(await ctrl.add('wish', <String, dynamic>{'title': 'x'}),
          '许愿内容不合规');
      expect(await ctrl.edit('r1', 'wish', const <String, dynamic>{},
          <String, dynamic>{'done': true}), '只能修改自己写的内容');
      expect(await ctrl.delete('r1'), '只有本人能删除这条记录');
      expect(await ctrl.answer('r1', '答案'), '答案要在 1..5000 字之间');
      expect(await ctrl.checkHabit('r1'), '今天已经打过卡了');

      // 不假成功：失败路径不触发 reload（无第二次 GET /api/records），
      // 列表状态保持原样（不刷新假数据）
      expect(store.recordGets, getsAfterLoad);
      expect(c.read(togetherControllerProvider).records, isEmpty);
      expect(c.read(togetherControllerProvider).loading, isFalse);
      // 5 个写请求确实发出（显式判拦下，不是没发）
      expect(store.requests.where((RequestOptions r) => r.method != 'GET'),
          hasLength(5));
    });

    test('成功路径：返回 null 且 reload（显式判不破坏正常流）', () async {
      final _Store store = _Store();
      final ProviderContainer c = _container(store);
      final TogetherController ctrl = c.read(togetherControllerProvider.notifier);
      await ctrl.bootstrap();
      final int getsAfterLoad = store.recordGets;
      expect(await ctrl.add('wish', <String, dynamic>{'title': 'x'}), isNull);
      expect(store.recordGets, getsAfterLoad + 1, reason: '成功后整列表 reload');
    });
  });

  // ── ③ home_page mood 2 写 ──────────────────────────────────────────
  group('home_page mood 写 4xx 显式判', () {
    final String today = todayStr();

    testWidgets('记一笔 POST 422：detail 原文 toast、不 invalidate（不假成功）',
        (WidgetTester tester) async {
      final _Store store = _Store();
      store.replies['POST /api/records'] =
          const _Reply(422, <String, dynamic>{'detail': '心情内容太长了'});
      final ProviderContainer c = _container(store);
      await _pump(tester,
          _app(c, router: _router(home: (_) => const HomePage())));

      await tester.tap(find.text('＋ 记一笔'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('记一笔'));
      await tester.pumpAndSettle();

      expect(c.read(chatToastProvider)?.text, '心情内容太长了',
          reason: 'detail 原文直通，非「保存失败：\$e」拼异常对象');
      expect(c.read(chatToastProvider)?.tone, ChatToastTone.error);
      // 不假成功：无成功语义 toast、无 invalidate 触发的二次重拉
      expect(store.recordGets, 1);
    });

    testWidgets('更新 PUT 403：detail 原文 toast、本地不重拉（不假成功）',
        (WidgetTester tester) async {
      final _Store store = _Store();
      store.recordsJson = <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'm1',
          'kind': 'mood',
          'author': 'u1',
          'body': <String, dynamic>{
            'date': today, 'emoji': '☀️', 'content': '心情不错', 'media': <Object>[],
          },
          'created': 1731600000.0,
        },
      ];
      store.replies['PUT /api/records/m1'] =
          const _Reply(403, <String, dynamic>{'detail': '只能修改自己写的心情'});
      final ProviderContainer c = _container(store);
      await _pump(tester,
          _app(c, router: _router(home: (_) => const HomePage())));

      await tester.tap(find.text('☀️ 心情不错'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更新'));
      await tester.pumpAndSettle();

      expect(c.read(chatToastProvider)?.text, '只能修改自己写的心情');
      expect(c.read(chatToastProvider)?.tone, ChatToastTone.error);
      expect(store.recordGets, 1);
    });
  });

  // ── ④ bubble_skin_sheet PUT /api/profile（2.4.6 改按人端点）──────────────
  group('bubble_skin_sheet 保存 4xx 显式判', () {
    /// 弹层内 CachedNetworkImage/SkinBubble 的图片链路在测试环境无真网可达，
    /// pumpAndSettle 永不静置 —— 改用**定量 pump**（不弱化断言，只换推进方式）。
    /// 序列：300ms（bootstrap 宏任务完成，me 就位）→ 400ms（延迟定时器开弹层）
    /// → 300ms（弹层 initState 读 me + /api/bubbles setState）。
    Future<void> pumpSheet(WidgetTester tester, Widget w) async {
      tester.view.physicalSize = const Size(1080, 3600);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(w);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('422：原文 toast、不 reload、不 pop（弹层留在原地）',
        (WidgetTester tester) async {
      final _Store store = _Store();
      store.replies['PUT /api/profile'] =
          const _Reply(422, <String, dynamic>{'detail': '皮肤字段不合法'});
      final ProviderContainer c = _container(store);
      // 🔴 FakeAsync 纪律：bootstrap 内层是 Timer.run 宏任务，不能在 pump 前
      // await reload()（永挂）；read 触发后靠 pumpSheet 的 pump 推进完成。
      c.read(authProvider);
      await pumpSheet(
          tester,
          _app(
            c,
            router: _router(
              home: (_) =>
                  _OpenOnFrame((BuildContext ctx) => showBubbleSkinSheet(ctx)),
            ),
          ));
      expect(store.meGets, 1, reason: 'bootstrap 完成（me 就位，含 chat_bubble）');

      await tester.tap(find.text('使用这个'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500)); // PUT + toast + setState

      expect(c.read(chatToastProvider)?.text, '皮肤字段不合法',
          reason: 'detail 原文直通');
      expect(c.read(chatToastProvider)?.tone, ChatToastTone.error);
      // 不 pop：弹层仍在
      expect(find.text('使用这个'), findsOneWidget);
      // 不 reload：/api/me 计数不变（reload 会再拉一次）
      expect(store.meGets, 1);
      // 硬性护栏：气泡保存不发空间 PUT（mock 计数=0）
      expect(
          store.requests.where((r) => '${r.method} ${r.uri.path}' == 'PUT /api/space'),
          isEmpty);
    });

    testWidgets('成功路径：reload + pop（显式判不破坏正常流）',
        (WidgetTester tester) async {
      final _Store store = _Store();
      final ProviderContainer c = _container(store);
      c.read(authProvider); // bootstrap 靠 pump 推进（同上）
      await pumpSheet(
          tester,
          _app(
            c,
            router: _router(
              home: (_) =>
                  _OpenOnFrame((BuildContext ctx) => showBubbleSkinSheet(ctx)),
            ),
          ));
      expect(store.meGets, 1);

      await tester.tap(find.text('使用这个'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500)); // PUT + reload（宏任务）
      // 2.4.10：三连变对勾驻留 1s 后 pop——补足驻留 + pop 退场动画，
      // 驻留 Timer 不留到树销毁（否则 !timersPending 断言炸）。
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('使用这个'), findsNothing, reason: '成功后 pop');
      expect(store.meGets, 2, reason: '成功后 reload（/api/me 再拉一次）');
    });
  });

  // ── ⑤ chat_repository.sendChatBody（4xx detail 进 pending 失败态）──
  group('sendChatBody 4xx detail 透传', () {
    test('403：detail 原文随异常上抛，pending 落失败态保留可重试', () async {
      final _Store store = _Store();
      store.replies['POST /api/records'] =
          const _Reply(403, <String, dynamic>{'detail': '写请求缺少空间头'});
      final ProviderContainer c = ProviderContainer(overrides: <Override>[
        api.dioProvider.overrideWith((ref) async => _dio(store)),
        chatPersistenceProvider.overrideWith((ref) async => _MemStore()),
      ]);
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await ctrl.bootstrap('u1');

      Object? caught;
      try {
        await ctrl.send(' hello ');
      } catch (e) {
        caught = e;
      }
      // messages_page._retry 的呈现通道是 catch + errorDetail：必须拿到原文
      expect(api.errorDetail(caught), '写请求缺少空间头');
      // 不假成功：pending 落失败态（保留可重试），没有假记录混入列表
      final row = c
          .read(chatControllerProvider)
          .rows
          .whereType<ChatPendingRow>()
          .single;
      expect(row.failed, isTrue);
      expect(c.read(chatControllerProvider).rows.whereType<ChatRecordRow>(),
          isEmpty);
    });

    test('成功路径：返回记录（显式判不破坏正常流）', () async {
      final _Store store = _Store();
      // 最小合法记录应答（200 分支走 fromJson 正常解析）
      store.replies['POST /api/records'] = const _Reply(200, <String, dynamic>{
        'id': 'srv-1', 'kind': 'chat', 'author': 'u1',
        'body': <String, dynamic>{'content': 'hi', 'media': <Object>[]},
        'created': 1000.0, 'updated': 1000.0, 'client_id': 'cid',
      });
      final ProviderContainer c = ProviderContainer(overrides: <Override>[
        api.dioProvider.overrideWith((ref) async => _dio(store)),
        chatPersistenceProvider.overrideWith((ref) async => _MemStore()),
      ]);
      addTearDown(c.dispose);
      final rec = await sendChatBody(
          await c.read(api.dioProvider.future),
          <String, dynamic>{'content': 'hi', 'media': <String>[]},
          'cid');
      expect(rec.id, 'srv-1');
    });
  });

  // ── ⑥ auth_state.logout（4xx 不阻断登出，注释留痕口径验证）────────
  group('auth logout 4xx', () {
    test('POST /api/logout 403：本地清态为准（me 清空、状态回未登录）', () async {
      final _Store store = _Store();
      store.replies['POST /api/logout'] =
          const _Reply(403, <String, dynamic>{'detail': '会话已失效'});
      final ProviderContainer c = _container(store);
      await c.read(authProvider.notifier).reload();
      expect(c.read(authProvider), AuthPhase.authed);

      await c.read(authProvider.notifier).logout();

      expect(c.read(authProvider), AuthPhase.out, reason: '4xx 不阻断登出');
      expect(c.read(authProvider.notifier).me, isNull);
      expect(store.requests.any((RequestOptions r) =>
          r.method == 'POST' && r.uri.path == '/api/logout'), isTrue);
    });
  });

  // ── ⑦ music uploadMusicToPlaylist（uploadChatMedia 调用方直通核查）──
  group('music 上传错误直通', () {
    test('MediaValidationError：message 原文直通 toast（不裸打印异常对象）', () async {
      final _Store store = _Store();
      final ProviderContainer c = _container(store);
      await uploadMusicToPlaylist(
        c,
        filename: 'song.mp3',
        bytes: <int>[1, 2, 3],
        title: '歌',
        content: '歌手',
        upload: (Dio dio, String f, List<int> b) async =>
            throw const MediaValidationError('音频文件损坏，请重新选择'),
      );
      expect(c.read(chatToastProvider)?.text, '上传失败：音频文件损坏，请重新选择',
          reason: 'MediaValidationError.message 直通，非 DioException dump');
      expect(c.read(chatToastProvider)?.tone, ChatToastTone.error);
    });
  });
}
