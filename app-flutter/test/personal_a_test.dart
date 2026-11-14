/* 条目 7 段 7-A 回归（2.1.7/VC217 · 个人角落骨架 + 私密日记 + 草稿箱）：
   ① kind 串显式拉三类（7-B 起 personalKinds 扩为 diary,draft,surprise，
      防「漏扩 kinds」事故）
   ② 跨账号隐私（B 账号 me fixture：列表只含 B 的记录，不含 A 的日记/草稿）
   ③ 编辑 PUT body 含原字段（回填铁律 mergeRecordBody）
   ④ 发布三选一：post→时光 / diary→日记 / 草稿箱消失；PUT merge 后完整 body；
      选 surprise 带未来 publish_at
   ⑤ 删除弹层文案：7-B 起统一标准口径「删除后会进入回收站，30 天内可以恢复。」
      （与共享类一致；7-A 的「不进回收站、不可恢复」临时口径已作废）
   ⑥ tab 切换不丢状态（滚动位置 + 选中态）
   ⑦ 无预置死卡（7-A 2 tab → 7-B 4 tab；7-C 个人心愿仍不预置）

   夹具存量形状来源（2026-11-14 SSH 直查 NAS 容器 /data/love.db，app.db.body_decode
   解密 PRIVATE body 后导出，脱敏）：
   · draft 实测 8 条：body = {content, date, media: []}，部分含 {title, album}；
     序列化顶层字段见 app/serializers.py serialize_many（likes/comments/media 等）。
   · diary 实测 **0 条**（库里根本没有 diary 行）→ 夹具 diary 用等价
     serialize_many 形状，body 按 Web composer（static/app.js:1807-1830）+
     clean_body（app/main.py:1107）同构推导：{content, date, media: []}；
     已在本文件与 docs/personal-corner-plan.md 明确注明来源，非凭空造。 */
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
import 'package:love_space/core/together/together_data.dart';
import 'package:love_space/features/personal/personal_controller.dart';
import 'package:love_space/features/personal/personal_page.dart';

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

Map<String, Object> _meFixture({String uid = 'u1'}) => {
      'user': {'id': uid, 'name': uid == 'u1' ? '我' : 'TA', 'username': uid},
      'users': [
        {'id': 'u1', 'name': '我', 'username': 'u1'},
        {'id': 'u2', 'name': 'TA', 'username': 'u2'},
      ],
      'space': {}, 'unread': 0, 'chat_unread': 0,
    };

/// 序列化记录（serialize_many 顶层形状：id/kind/author/body/created/.../
/// client_id/media/likes/comments）
Map<String, Object?> _rec({
  required String id,
  required String kind,
  required String author,
  required Map<String, Object?> body,
  double created = 1794544273.2681885,
}) =>
    {
      'id': id,
      'kind': kind,
      'author': author,
      'body': body,
      'created': created,
      'updated': created,
      'published': null,
      'client_id': 'cid-$id',
      'media': <Object>[],
      'likes': <Object>[],
      'comments': <Object>[],
    };

/// 存量形状：draft 两条取自 NAS DB 实测（「（草稿）」空草稿 + 带 title/album 草稿）；
/// diary 一条为上述等价形状（DB diary COUNT=0），extra_key 用于验证回填铁律
/// 「未知字段原样带回」（mergeRecordBody 语义）。
final List<Object?> _baseRecords = [
  _rec(
      id: 'd1',
      kind: 'diary',
      author: 'u1',
      created: 1794544300.0,
      body: {
        'content': '今天只写给自己看的一段话',
        'date': '2026-11-14',
        'media': <String>[],
        'extra_key': '原样带回',
      }),
  _rec(
      id: 'dr1',
      kind: 'draft',
      author: 'u1',
      created: 1794544273.2681885,
      body: {'content': '（草稿）', 'date': '2026-11-13', 'media': <String>[]}),
  _rec(
      id: 'dr2',
      kind: 'draft',
      author: 'u1',
      created: 1794534575.5933993,
      body: {
        'content': '测试',
        'date': '2026-11-13',
        'media': <String>[],
        'title': '测试',
        'album': '58e89a6b55824524986fbe5b2c807e95',
      }),
];

/// 通用 adapter：/api/me 返回 me fixture；/api/records GET 按 kind 分流
/// （album 是 composer 的相册分类请求，返回空）；写方法返回 200 空对象。
_FakeAdapter _adapter({
  required List<Object?> records,
  String uid = 'u1',
}) =>
    _FakeAdapter((options, i) {
      if (options.uri.path == '/api/me') return _json(_meFixture(uid: uid));
      if (options.method == 'GET' && options.uri.path == '/api/records') {
        // 7-B 起个人角落会额外拉一次回收站；7-A 夹具无 deleted 记录，返回空
        if (options.queryParameters['trash'] == true) {
          return _json(<Object>[]);
        }
        if (options.queryParameters['kind'] == 'album') {
          return _json(<Object>[]);
        }
        return _json(records);
      }
      return _json(<String, Object>{});
    });

Future<ProviderContainer> _setup(_FakeAdapter adapter) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  final container = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
    mediaCookieHeadersProvider
        .overrideWith((ref) async => <String, String>{}),
  ]);
  addTearDown(container.dispose);
  return container;
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

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  final router = _router();
  addTearDown(router.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pumpAndSettle();
}

/// 顶部通知 provider 的 2.2s 自毁 Timer 需要冲掉，否则 teardown 报 pending
Future<void> _flushToasts(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

Map<String, dynamic> _putBody(RequestOptions r) =>
    (r.data as Map)['body'] as Map<String, dynamic>;

RequestOptions _lastPut(List<RequestOptions> rs) =>
    rs.lastWhere((r) => r.method == 'PUT' && r.uri.path.startsWith('/api/records/'));

void main() {
  // ── ① kind 串 / 骨架 ────────────────────────────────────────────
  group('① 显式 kind 拉取（防漏扩类事故）', () {
    test('顶层常量 personalKinds = diary,draft,surprise 且三类都覆盖', () {
      expect(personalKinds, 'diary,draft,surprise');
      final kinds = personalKinds.split(',');
      expect(kinds, contains('diary'));
      expect(kinds, contains('draft'));
      expect(kinds, contains('surprise'));
      expect(kinds.length, 3);
    });

    testWidgets('load 请求 queryParameters[kind] == personalKinds + author 加固',
        (tester) async {
      final adapter = _adapter(records: _baseRecords);
      final container = await _setup(adapter);
      await _pump(tester, container);

      final gets = adapter.requests
          .where((r) => r.method == 'GET' && r.uri.path == '/api/records')
          .toList();
      expect(gets, isNotEmpty);
      final personalGet = gets.firstWhere(
          (r) => r.queryParameters['kind'] == personalKinds,
          orElse: () => throw TestFailure('未发出显式 kind 的 /api/records 请求'));
      expect(personalGet.queryParameters['kind'], 'diary,draft,surprise');
      expect(personalGet.queryParameters['kind']!.split(','),
          containsAll(<String>['diary', 'draft', 'surprise']));
      expect(personalGet.queryParameters['author'], 'u1');
      // 两 tab 数据都渲染（客户端按 r.kind 分流）
      expect(find.text('今天只写给自己看的一段话'), findsWidgets);
      await tester.tap(find.text('草稿箱'));
      await tester.pumpAndSettle();
      expect(find.text('（草稿）'), findsWidgets);
    });
  });

  // ── ② 跨账号隐私 ────────────────────────────────────────────────
  group('② 跨账号隐私（B 账号 me fixture）', () {
    testWidgets('列表只含 B 自己的记录，不含 A 的日记/草稿', (tester) async {
      final records = <Object?>[
        _rec(
            id: 'a-diary',
            kind: 'diary',
            author: 'u1',
            body: {
              'content': 'A 的私密日记',
              'date': '2026-11-14',
              'media': <String>[],
            }),
        _rec(
            id: 'a-draft',
            kind: 'draft',
            author: 'u1',
            body: {
              'content': 'A 的草稿内容',
              'date': '2026-11-13',
              'media': <String>[],
            }),
        _rec(
            id: 'b-diary',
            kind: 'diary',
            author: 'u2',
            body: {
              'content': 'B 的私密日记',
              'date': '2026-11-14',
              'media': <String>[],
            }),
        _rec(
            id: 'b-draft',
            kind: 'draft',
            author: 'u2',
            body: {
              'content': 'B 的草稿内容',
              'date': '2026-11-13',
              'media': <String>[],
            }),
      ];
      // 适配器故意把 A 的记录也返回（模拟越权数据），客户端必须不渲染
      final adapter = _adapter(records: records, uid: 'u2');
      final container = await _setup(adapter);
      await _pump(tester, container);

      final personalGet = adapter.requests.firstWhere(
          (r) => r.method == 'GET' &&
              r.uri.path == '/api/records' &&
              r.queryParameters['kind'] == personalKinds);
      expect(personalGet.queryParameters['author'], 'u2');

      // diary tab
      expect(find.textContaining('B 的私密日记'), findsWidgets);
      expect(find.textContaining('A 的私密日记'), findsNothing);
      // draft tab 同样隔离
      await tester.tap(find.text('草稿箱'));
      await tester.pumpAndSettle();
      expect(find.textContaining('B 的草稿内容'), findsWidgets);
      expect(find.textContaining('A 的草稿内容'), findsNothing);
    });
  });

  // ── ③ 编辑 PUT 回填铁律 ─────────────────────────────────────────
  group('③ 编辑 PUT body 含原字段', () {
    testWidgets('日记编辑：只盖 content，date/media/未知键原样带回',
        (tester) async {
      final adapter = _adapter(records: _baseRecords);
      final container = await _setup(adapter);
      await _pump(tester, container);

      await tester.tap(find.byTooltip('编辑日记'));
      await tester.pumpAndSettle();
      expect(find.text('编辑日记'), findsOneWidget); // AppBar 自动返回按钮在
      await tester.enterText(find.byType(TextField), '改过的内容');
      await tester.tap(find.text('保存日记'));
      await tester.pumpAndSettle();

      final put = _lastPut(adapter.requests);
      expect(put.uri.path, '/api/records/d1');
      expect((put.data as Map)['kind'], 'diary');
      final body = _putBody(put);
      expect(body['content'], '改过的内容');
      expect(body['date'], '2026-11-14'); // 原字段
      expect(body['media'], <String>[]); // 原字段
      expect(body['extra_key'], '原样带回'); // 未知字段（回填铁律）
      // 返回路径：push 的二级页 pop 后回到个人角落
      expect(find.text('我的小角落'), findsOneWidget);
      await _flushToasts(tester);
    });
  });

  // ── ④ 发布三选一 ────────────────────────────────────────────────
  group('④ 草稿发布（post / diary / surprise）', () {
    testWidgets('post → PUT kind=post + merge 完整 body + 草稿箱消失',
        (tester) async {
      final adapter = _adapter(records: _baseRecords);
      final container = await _setup(adapter);
      await _pump(tester, container);
      await tester.tap(find.text('草稿箱'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('发布').first); // 第一张草稿卡（dr1 最新）
      await tester.pumpAndSettle();
      expect(find.text('发布这份草稿'), findsOneWidget);
      // 默认 post：直接确认发布
      await tester.tap(find.text('确认发布'));
      await tester.pumpAndSettle();

      final put = _lastPut(adapter.requests);
      expect(put.uri.path, '/api/records/dr1');
      expect((put.data as Map)['kind'], 'post');
      final body = _putBody(put);
      expect(body['content'], '（草稿）');
      expect(body['date'], '2026-11-13');
      expect(body['media'], <String>[]);
      expect(body.containsKey('publish_at'), false);
      // 本地移除：草稿 tab 不再有这条
      expect(find.text('（草稿）'), findsNothing);
      await _flushToasts(tester);
    });

    testWidgets('diary → PUT kind=diary + 移入日记列表、草稿箱消失',
        (tester) async {
      final adapter = _adapter(records: _baseRecords);
      final container = await _setup(adapter);
      await _pump(tester, container);
      await tester.tap(find.text('草稿箱'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('发布').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('存为私密日记'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认发布'));
      await tester.pumpAndSettle();

      final put = _lastPut(adapter.requests);
      expect((put.data as Map)['kind'], 'diary');
      expect(_putBody(put)['content'], '（草稿）');
      expect(_putBody(put).containsKey('publish_at'), false);
      expect(find.text('（草稿）'), findsNothing); // 草稿 tab 已移除
      // 切回日记 tab：同一条记录以 diary 身份出现
      await tester.tap(find.text('私密日记'));
      await tester.pumpAndSettle();
      expect(find.text('（草稿）'), findsWidgets);
      await _flushToasts(tester);
    });

    testWidgets('surprise → 未选未来时间不发 PUT（UI 拦截）', (tester) async {
      final adapter = _adapter(records: _baseRecords);
      final container = await _setup(adapter);
      await _pump(tester, container);
      await tester.tap(find.text('草稿箱'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('发布').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('定时惊喜'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认发布'));
      await tester.pumpAndSettle();
      expect(find.text('请选择未来的公开时间'), findsOneWidget);
      expect(adapter.requests.where((r) => r.method == 'PUT'), isEmpty);
    });

    test('surprise 控制器：未来 publish_at + merge 完整 body；过去时间拒绝',
        () async {
      final adapter = _adapter(records: _baseRecords);
      final container = await _setup(adapter);
      final draft = TogetherRecord.fromJson(
          _rec(
                  id: 'dr1',
                  kind: 'draft',
                  author: 'u1',
                  body: {
                    'content': '（草稿）',
                    'date': '2026-11-13',
                    'media': <String>[],
                  })
              .cast<String, dynamic>());
      final ctrl = container.read(personalControllerProvider.notifier);
      final future = DateTime.now().add(const Duration(days: 2));
      final err = await ctrl.publishDraft(draft, 'surprise', publishAt: future);
      expect(err, isNull);
      final put = _lastPut(adapter.requests);
      expect((put.data as Map)['kind'], 'surprise');
      final body = _putBody(put);
      expect(body['content'], '（草稿）'); // merge 后的完整 body
      expect(body['date'], '2026-11-13');
      expect(body['publish_at'], isA<num>());
      expect((body['publish_at'] as num).toDouble(),
          greaterThan(DateTime.now().millisecondsSinceEpoch / 1000));
      // 过去时间直接拒绝，不发请求
      final before = adapter.requests.length;
      final err2 = await ctrl.publishDraft(draft, 'surprise',
          publishAt: DateTime.now().subtract(const Duration(days: 1)));
      expect(err2, '请选择未来的公开时间');
      expect(adapter.requests.length, before);
    });
  });

  // ── ⑤ 删除弹层文案（7-B 起标准口径） ────────────────────────────
  group('⑤ 三类统一标准删除文案', () {
    testWidgets('弹层写明进回收站 30 天可恢复；取消不删、确认才 DELETE',
        (tester) async {
      final adapter = _adapter(records: _baseRecords);
      final container = await _setup(adapter);
      await _pump(tester, container);

      await tester.tap(find.byTooltip('删除日记'));
      await tester.pumpAndSettle();
      expect(find.text(privateDeleteText), findsOneWidget);
      expect(find.textContaining('30 天'), findsWidgets);
      expect(find.text('删除后会进入回收站，30 天内可以恢复。'), findsOneWidget);
      expect(find.textContaining('不进回收站'), findsNothing);
      expect(find.textContaining('不可恢复'), findsNothing);
      // 可取消
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(adapter.requests.where((r) => r.method == 'DELETE'), isEmpty);

      await tester.tap(find.byTooltip('删除日记'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(
          adapter.requests,
          anyElement(predicate<RequestOptions>((r) =>
              r.method == 'DELETE' && r.uri.path == '/api/records/d1')));
      expect(find.text('今天只写给自己看的一段话'), findsNothing);
      await _flushToasts(tester);
    });
  });

  // ── ⑥ tab 切换不丢状态 ──────────────────────────────────────────
  group('⑥ tab 切换不丢状态 + 无预置死卡', () {
    testWidgets('滚动位置与选中态切换后保持；7-B 起 4 个 tab',
        (tester) async {
      final records = <Object?>[
        ..._baseRecords,
        for (var i = 0; i < 8; i++)
          _rec(
              id: 'more-$i',
              kind: 'diary',
              author: 'u1',
              created: 1794544200.0 + i,
              body: {
                'content': '补充日记 $i',
                'date': '2026-11-14',
                'media': <String>[],
                'title': i == 7 ? '末尾标题' : '补充标题 $i',
              }),
      ];
      final adapter = _adapter(records: records);
      final container = await _setup(adapter);
      await _pump(tester, container);

      // ⑦ 无死卡：7-A 2 tab → 7-B 4 tab（surprise/trash 已落地），
      // 7-C「个人心愿」仍不预置
      expect(personalTabs.length, 4);
      expect(personalTabs.map((t) => t.id).toList(),
          ['diary', 'draft', 'surprise', 'trash']);
      expect(find.text('私密日记'), findsOneWidget);
      expect(find.text('草稿箱'), findsOneWidget);
      expect(find.text('定时惊喜'), findsOneWidget);
      expect(find.text('回收站'), findsOneWidget);
      expect(find.text('个人心愿'), findsNothing);

      // 滚到页尾元素（ListView 懒构建）
      await tester.scrollUntilVisible(find.text('末尾标题'), 250);
      final scroller = find.byType(Scrollable).first;
      final before =
          tester.state<ScrollableState>(scroller).position.pixels;
      expect(before, greaterThan(0));

      await tester.tap(find.text('草稿箱'));
      await tester.pumpAndSettle();
      expect(find.text('（草稿）'), findsWidgets);
      await tester.tap(find.text('私密日记'));
      await tester.pumpAndSettle();
      final after = tester.state<ScrollableState>(scroller).position.pixels;
      expect(after, before, reason: '切走再切回，日记列表滚动位置不丢');
      expect(find.text('末尾标题'), findsOneWidget);
    });
  });

  // ── ⑧ 草稿继续编辑走正式 composer 且保持 kind=draft ─────────────
  group('⑧ 草稿继续编辑（正式 composer）', () {
    testWidgets('showComposerSheet 载入草稿，编辑 PUT kind=draft',
        (tester) async {
      final adapter = _adapter(records: _baseRecords);
      final container = await _setup(adapter);
      await _pump(tester, container);
      await tester.tap(find.text('草稿箱'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('继续编辑').first);
      await tester.pumpAndSettle();
      expect(find.text('编辑这一刻'), findsOneWidget);
      // composer 预填草稿内容（不另造编辑器）
      expect(
          find.byWidgetPredicate((w) =>
              w is TextField &&
              w.controller != null &&
              w.controller!.text == '（草稿）'),
          findsOneWidget);
      await tester.enterText(find.byType(TextField).at(1), '改过的草稿内容');
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();

      final put = _lastPut(adapter.requests);
      expect((put.data as Map)['kind'], 'draft');
      expect(_putBody(put)['content'], isA<String>());
      await _flushToasts(tester);
    });
  });
}
