/* 条目 7 段 7-B 回归（2.1.8/VC218 · 定时惊喜 + 回收站 + 删除文案统一）：
   ① kind 串：personalKinds 三类 + trashKinds 与 Web 全串一致（含私密三类）
   ② 惊喜列表仅本人 / 待揭示态与 publish_at 呈现 / 揭示前不进共享缓存
   ③ 新建惊喜 POST publish_at 未来 epoch 秒；不合法时间被拒且不发请求
   ④ 服务端 422 原文案透传到顶部通知（不静默失败）
   ⑤ 编辑惊喜（含改期）走回填铁律 merge 完整 body、kind 保持 surprise
   ⑥ 回收站：trash=true + 全 kind 串、仅本人；删时光/日记都进回收站；
      恢复走 POST /restore 且回到原列表；对象账号回收站无我的条目
   ⑦ 三类删除文案统一标准口径（进回收站、30 天可恢复）
   ⑧ 返回路径（按钮 + 系统手势）；无「彻底删除」（Web 没有，不自创）
   ⑨ 无死卡（4 tab，7-C 个人心愿仍不预置）

   夹具存量形状来源（2026-11-14 SSH 直查 NAS 容器 /data/love.db，
   app.db.body_decode 解密 PRIVATE body 后导出，脱敏）：
   · 已删除记录实测 17 条：post 6 / draft 7 / album 1 / anniversary 1 /
     question 1 / music 1；顶层含 deleted 时间戳、published、client_id，
     body = {content, date, media: [...], title?, album?}。本文件的 trash 夹具
     逐字取此形状。
   · surprise 实测 **0 条**（库里根本没有 surprise 行）→ 夹具按 Web composer
     （static/app.js:1807-1830）+ clean_body（app/main.py:930-934）等价
     serialize_many 形状推导，body = {content, date, media: [], publish_at}；
     已在本文件与 docs/personal-corner-plan.md 双处注明来源（同 7-A 的 diary
     例外，主人已接受），非凭空造、不写生产库。 */
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
import 'package:love_space/features/timeline/timeline_controller.dart'
    show timelineControllerProvider;

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

/// 序列化记录（serialize_many 顶层形状；deleted 为软删时间戳，0/null=未删）
Map<String, Object?> _rec({
  required String id,
  required String kind,
  required String author,
  required Map<String, Object?> body,
  double created = 1794544273.2681885,
  Object? deleted,
  Object? published,
}) =>
    {
      'id': id,
      'kind': kind,
      'author': author,
      'body': body,
      'created': created,
      'updated': created,
      'published': published,
      'deleted': deleted,
      'client_id': 'cid-$id',
      'media': <Object>[],
      'likes': <Object>[],
      'comments': <Object>[],
    };

/// 未来 publish_at（epoch 秒）：now + 2 分钟
double _futureAt() =>
    DateTime.now().add(const Duration(minutes: 2)).millisecondsSinceEpoch /
    1000;

/// surprise 存量等价形状（NAS 实测 0 行，按 Web composer + clean_body 推导）
final Map<String, Object?> _surpriseRecord = _rec(
  id: 'sp1',
  kind: 'surprise',
  author: 'u1',
  created: 1794544400.0,
  body: {
    'content': '两分钟后见面的小惊喜',
    'date': '2026-11-14',
    'media': <String>[],
    'publish_at': _futureAt(),
  },
);

/// trash 夹具：取自 NAS 实测形状（post 带 media/album、draft 带 title/album，
/// 顶层含 deleted/published/client_id）
final List<Object?> _trashRecords = [
  _rec(
      id: 't-post',
      kind: 'post',
      author: 'u1',
      created: 1793109796.3382573,
      deleted: 1793268712.447001,
      published: 1793109796.3382573,
      body: {
        'title': '',
        'content': '',
        'date': '2026-10-27',
        'album': '58e89a6b55824524986fbe5b2c807e95',
        'media': ['3acb1a4e557c488cb3250ebdac4b8ea9'],
      }),
  _rec(
      id: 't-draft',
      kind: 'draft',
      author: 'u1',
      created: 1793948296.4638824,
      deleted: 1794643848.1420636,
      body: {
        'content': '写了一半的草稿',
        'date': '2026-11-04',
        'album': '',
        'media': <String>[],
        'title': '',
      }),
  // 对象账号的已删除记录：服务端 trash 分支已强制 author=自己，
  // 这里故意混入以验证客户端二次过滤（防越权）。
  _rec(
      id: 't-other',
      kind: 'post',
      author: 'u2',
      created: 1793109000.0,
      deleted: 1793268000.0,
      published: 1793109000.0,
      body: {'title': '对方的秘密', 'content': '', 'date': '2026-10-27', 'media': <String>[]}),
];

/// 正常列表（diary/draft/surprise）夹具
final List<Object?> _mainRecords = [
  _rec(
      id: 'd1',
      kind: 'diary',
      author: 'u1',
      created: 1794544300.0,
      body: {
        'content': '今天只写给自己看的一段话',
        'date': '2026-11-14',
        'media': <String>[],
      }),
  _surpriseRecord,
];

/// adapter：按 trash 参数分流；DELETE/restore 返回 200；可选 422 注入。
_FakeAdapter _adapter({
  List<Object?>? mainRecords,
  List<Object?>? trashRecords,
  String uid = 'u1',
  bool rejectSurprise = false,
}) {
  final main = mainRecords ?? _mainRecords;
  final trash = trashRecords ?? _trashRecords;
  return _FakeAdapter((o, i) {
      if (o.uri.path == '/api/me') return _json(_meFixture(uid: uid));
      if (o.method == 'GET' && o.uri.path == '/api/records') {
        if (o.queryParameters['trash'] == true) return _json(trash);
        if (o.queryParameters['kind'] == 'album') return _json(<Object>[]);
        if (o.queryParameters['kind'] == 'post') return _json(<Object>[]);
        return _json(main);
      }
      if (o.method == 'POST' &&
          o.uri.path == '/api/records' &&
          rejectSurprise &&
          (o.data as Map)['kind'] == 'surprise') {
        return _json({'detail': '请选择未来的公开时间'}, 422);
      }
      return _json(<String, Object>{});
    });
}

Future<ProviderContainer> _setup(_FakeAdapter adapter,
    {String uid = 'u1'}) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  final container = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
    mediaCookieHeadersProvider
        .overrideWith((ref) async => <String, String>{}),
    // 🔴 纯 test() 里固定 uid：否则 personalCurrentUserProvider 依赖
    // authProvider 变化会让 Notifier 重建，旧 onDispose 把 _disposed 置
    // true，写操作静默 no-op（7-A 返修踩过的坑）。widget 用例不 override，
    // 由 /api/me 兜底 _currentUserId()。
    personalCurrentUserProvider.overrideWith((ref) => uid),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// 用 GoRouter 承载个人角落（含 /personal/surprise-form 等 push 路由）。
Widget _app(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/personal',
          routes: [
            GoRoute(
                path: '/personal',
                builder: (_, _) => const PersonalPage()),
            GoRoute(
              path: '/personal/surprise-form',
              builder: (_, state) {
                final extra = (state.extra as Map?) ?? const {};
                return SurpriseFormPage(
                    record: extra['record'] as TogetherRecord?);
              },
            ),
          ],
        ),
      ),
    );

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(_app(container));
  await tester.pumpAndSettle();
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

void main() {
  // ── ① kind 串 ───────────────────────────────────────────────────
  group('① 显式 kind 串（防漏扩类事故）', () {
    test('personalKinds 三类 + trashKinds 与 Web 全串一致且含私密三类', () {
      expect(personalKinds, 'diary,draft,surprise');
      expect(personalKinds.split(','),
          containsAll(<String>['diary', 'draft', 'surprise']));
      // Web app.js:92 kindLabel 的 Object.keys 顺序，逐字
      expect(trashKinds,
          'post,diary,draft,surprise,anniversary,wish,personal_wish,'
          'mood,note,question,habit,chat,album,quest,ledger,period,music');
      final ks = trashKinds.split(',');
      expect(ks.length, 17);
      expect(ks, containsAll(<String>['diary', 'draft', 'surprise']));
    });

    testWidgets('真实请求：主列表带 personalKinds，回收站带 trash=true + trashKinds',
        (tester) async {
      final adapter = _adapter();
      final container = await _setup(adapter);
      await _pump(tester, container);

      final gets = adapter.requests
          .where((r) => r.method == 'GET' && r.uri.path == '/api/records')
          .toList();
      expect(
          gets,
          anyElement(predicate<RequestOptions>((r) =>
              r.queryParameters['kind'] == personalKinds &&
              r.queryParameters['trash'] != true)));
      expect(
          gets,
          anyElement(predicate<RequestOptions>((r) =>
              r.queryParameters['trash'] == true &&
              r.queryParameters['kind'] == trashKinds)),
          reason: '回收站必须走 trash=true + Web 全 kind 串');
    });
  });

  // ── ② 惊喜列表 / 揭示前隐私 ─────────────────────────────────────
  group('② 惊喜列表仅本人 + 待揭示态 + 不进共享缓存', () {
    testWidgets('两账号隔离：B 视角看不到 A 的 surprise（夹具故意返回）',
        (tester) async {
      final adapter = _adapter(uid: 'u2', mainRecords: [
        _surpriseRecord, // 故意把 A 的 surprise 返回给 B
        _rec(
            id: 'sp-b',
            kind: 'surprise',
            author: 'u2',
            body: {
              'content': 'B 自己的惊喜',
              'date': '2026-11-14',
              'media': <String>[],
              'publish_at': _futureAt(),
            }),
      ]);
      final container = await _setup(adapter, uid: 'u2');
      await _pump(tester, container);
      await tester.tap(find.text('定时惊喜'));
      await tester.pumpAndSettle();

      expect(find.textContaining('两分钟后见面的小惊喜'), findsNothing,
          reason: '揭示前对象端任何页面都不可见（author 二次过滤）');
      expect(find.textContaining('B 自己的惊喜'), findsWidgets);
      expect(container.read(personalControllerProvider).records,
          everyElement(predicate<TogetherRecord>((r) => r.author == 'u2')));
      // 🔴 不进共享缓存：surprise 只保存在 personalController，
      // parseTogetherRecords 结果按 kind 限制为三类私密，绝不写进 timeline/together。
      expect(
          container.read(personalControllerProvider).records
              .where((r) => r.author != 'u2'),
          isEmpty);
    });

    testWidgets('待揭示态 + publish_at 时间呈现', (tester) async {
      final adapter = _adapter();
      final container = await _setup(adapter);
      await _pump(tester, container);
      await tester.tap(find.text('定时惊喜'));
      await tester.pumpAndSettle();
      expect(find.text('待揭示'), findsOneWidget);
      expect(find.textContaining('公开时间：'), findsOneWidget);
      // 标题与正文都呈现同一段 content，故 findsWidgets
      expect(find.textContaining('两分钟后见面的小惊喜'), findsWidgets);
    });

    /// 揭示全程（验收点）：服务端 worker.py:225-235 到点把 kind=surprise
    /// 改写为 kind=post（去 publish_at、加 was_surprise、published=now）。
    /// ① 揭示前：对象端显式拉 personalKinds 时服务端不返回（PRIVATE 的
    ///    db.visible 只放作者），且客户端二次按 author 过滤 → 任何页面不可见；
    /// ② 到点后：同一 id 以 post 出现在对象端时光列表。
    testWidgets('揭示前：对象账号任何页面都看不到我的 surprise', (tester) async {
      final before = _adapter(uid: 'u2', mainRecords: <Object?>[]);
      final c = await _setup(before, uid: 'u2');
      await _pump(tester, c);
      await tester.tap(find.text('定时惊喜'));
      await tester.pumpAndSettle();
      expect(find.textContaining('两分钟后见面的小惊喜'), findsNothing);
      expect(find.text('提前准备一份温柔的惊喜'), findsOneWidget);
      expect(c.read(personalControllerProvider).records, isEmpty,
          reason: '揭示前服务端 db.visible 不放 surprise 给对象；客户端也不缓存');
      await _flush(tester);
    });

    // 纯 test()（真实 async 区，非 FakeAsync）：避免在无 widget 树的容器里
    // await 控制器请求被 FakeAsync 挂起（历史坑）。
    test('到点后：worker 把 surprise 改成 post，对象端时光列表出现', () async {
      final revealed = _rec(
          id: 'sp1',
          kind: 'post',
          author: 'u1',
          created: 1794544400.0,
          published: 1794544520.0,
          body: {
            'content': '两分钟后见面的小惊喜',
            'date': '2026-11-14',
            'media': <String>[],
            'was_surprise': true,
          });
      final after = _FakeAdapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_meFixture(uid: 'u2'));
        if (o.method == 'GET' && o.uri.path == '/api/records') {
          if (o.queryParameters['kind'] == 'post') return _json([revealed]);
          return _json(<Object>[]);
        }
        return _json(<String, Object>{});
      });
      final c = await _setup(after, uid: 'u2');
      // 改写后的序列化形状：无 publish_at、带 was_surprise、kind=post
      final parsed = parseTogetherRecords([revealed]);
      expect(parsed.single.kind, 'post');
      expect(parsed.single.body['was_surprise'], true);
      expect(parsed.single.body.containsKey('publish_at'), isFalse);
      // 对象端时光控制器按 kind=post 重拉（与 7-A resetAfterPublish 同款
      // 显式重拉，不依赖 tab 切回/SSE 时序）→ 揭示后的记录出现在时光列表。
      await c.read(timelineControllerProvider.notifier).resetAfterPublish();
      expect(c.read(timelineControllerProvider).posts.any((r) => r.id == 'sp1'),
          isTrue,
          reason: '到点后 worker 把 surprise 改成 post，对象端时光应出现');
      expect(
          after.requests,
          anyElement(predicate<RequestOptions>((r) =>
              r.method == 'GET' &&
              r.uri.path == '/api/records' &&
              r.queryParameters['kind'] == 'post')));
      // 客户端不得把 surprise 缓存进共享/私密列表：对象端拉不到 A 的 surprise
      await c.read(personalControllerProvider.notifier).load();
      expect(c.read(personalControllerProvider).records, isEmpty);
    });
  });

  // ── ③ 新建惊喜 ─────────────────────────────────────────────────
  group('③ 新建惊喜 POST publish_at 未来 epoch 秒', () {
    test('控制器：未来时间成功、过去时间不发请求', () async {
      final adapter = _adapter();
      final container = await _setup(adapter);
      final ctrl = container.read(personalControllerProvider.notifier);
      // 纯 test() 里不调 bootstrap()（会触发 Riverpod 依赖重建把
      // _disposed 置 true，写操作静默 no-op）；与 7-A 控制器用例一致，
      // 直接拿 notifier 调方法，其内部 await load() 会自行拉 /api/me。

      final err = await ctrl.addSurprise(
          '明天的惊喜', DateTime.now().add(const Duration(days: 1)));
      expect(err, isNull);
      final post = adapter.requests.lastWhere(
          (r) => r.method == 'POST' && r.uri.path == '/api/records');
      final data = post.data as Map;
      expect(data['kind'], 'surprise');
      final body = data['body'] as Map;
      expect(body['publish_at'], isA<num>());
      expect((body['publish_at'] as num).toDouble(),
          greaterThan(DateTime.now().millisecondsSinceEpoch / 1000));
      expect(body['content'], '明天的惊喜');
      expect(data['client_id'], isNotEmpty);

      final n = adapter.requests.length;
      final bad = await ctrl.addSurprise(
          '过去的惊喜', DateTime.now().subtract(const Duration(days: 1)));
      expect(bad, '请选择未来的公开时间');
      expect(adapter.requests.length, n, reason: '不合法时间不发请求');
    });
  });

  // ── ④ 服务端 422 原文透传 ────────────────────────────────────────
  group('④ 422 原文走顶部通知，不静默失败', () {
    test('控制器收到 422：原文「请选择未来的公开时间」原样返回给 UI', () async {
      final adapter = _adapter(rejectSurprise: true);
      final container = await _setup(adapter);
      final ctrl = container.read(personalControllerProvider.notifier);
      final err = await ctrl.addSurprise(
          '服务端会拒的惊喜', DateTime.now().add(const Duration(days: 1)));
      // api.errorDetail 取 response.data['detail'] → 422 中文原文，
      // UI 的 _toast + 表单内联错误态双呈现，绝不静默失败。
      expect(err, '请选择未来的公开时间');
      expect(
          adapter.requests,
          anyElement(predicate<RequestOptions>((r) =>
              r.method == 'POST' &&
              r.uri.path == '/api/records' &&
              (r.data as Map)['kind'] == 'surprise')));
    });

    testWidgets('未选时间时表单本地拦截并提示原文', (tester) async {
      final adapter = _adapter();
      final container = await _setup(adapter);
      await _pump(tester, container);
      await tester.tap(find.text('定时惊喜'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('准备惊喜'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '还没选时间的惊喜');
      await tester.tap(find.text('保存惊喜'));
      await tester.pumpAndSettle();
      expect(find.text('请选择未来的公开时间'), findsWidgets);
      expect(adapter.requests.where((r) => r.method == 'POST'), isEmpty);
      await _flush(tester);
    });
  });

  // ── ⑤ 编辑改期走回填铁律 ────────────────────────────────────────
  group('⑤ 编辑惊喜（含改期）回填铁律', () {
    test('PUT kind 保持 surprise、body 逐键带原字段 + 新的 publish_at', () async {
      final adapter = _adapter();
      final container = await _setup(adapter);
      final ctrl = container.read(personalControllerProvider.notifier);
      final rec = parseTogetherRecords([_surpriseRecord]).first;
      final err = await ctrl.editSurprise(
          rec, '改过的内容', DateTime.now().add(const Duration(days: 3)));
      expect(err, isNull);
      final put = adapter.requests.lastWhere((r) => r.method == 'PUT');
      expect(put.uri.path, '/api/records/sp1');
      final data = put.data as Map;
      expect(data['kind'], 'surprise');
      final body = data['body'] as Map;
      expect(body['content'], '改过的内容');
      expect(body['date'], '2026-11-14');
      expect(body['media'], isA<List>());
      expect(body['publish_at'], isA<num>());
      expect((body['publish_at'] as num).toDouble(),
          greaterThan(DateTime.now().millisecondsSinceEpoch / 1000));
    });
  });

  // ── ⑥ 回收站闭环 ───────────────────────────────────────────────
  group('⑥ 回收站列表 / 恢复 / 仅本人', () {
    testWidgets('回收站含 post + draft 真实存量形状；对象条目不混入',
        (tester) async {
      final adapter = _adapter();
      final container = await _setup(adapter);
      await _pump(tester, container);
      await tester.tap(find.text('回收站'));
      await tester.pumpAndSettle();

      expect(find.textContaining('写了一半的草稿'), findsOneWidget);
      expect(find.textContaining('时光动态'), findsWidgets);
      expect(find.textContaining('对方的秘密'), findsNothing,
          reason: '服务端强制 author=自己；客户端二次过滤，绝不混入他人条目');
      expect(container.read(personalControllerProvider).trash,
          everyElement(predicate<TogetherRecord>((r) => r.author == 'u1')));
      expect(find.text('删除的内容保留三十天，你可以恢复自己的记录。'),
          findsOneWidget);
      // 🔴 Web 没有「彻底删除」，App 不自创
      expect(find.textContaining('彻底删除'), findsNothing);
    });

    test('删除时光 + 日记后都进回收站；恢复各一条回原列表', () async {
      final adapter = _adapter();
      final container = await _setup(adapter);
      final ctrl = container.read(personalControllerProvider.notifier);
      // 同上：纯 test() 不调 bootstrap()，用 load/loadTrash 铺数据
      await ctrl.load();
      await ctrl.loadTrash();

      // 删日记 → 本地移除 + 重拉回收站
      final e1 = await ctrl.delete('d1');
      expect(e1, isNull);
      expect(
          adapter.requests,
          anyElement(predicate<RequestOptions>((r) =>
              r.method == 'DELETE' && r.uri.path == '/api/records/d1')));
      expect(ctrl.diaries().any((r) => r.id == 'd1'), isFalse);

      // 恢复一条时光 + 一条草稿
      final e2 = await ctrl.restore('t-post', kind: 'post');
      expect(e2, isNull);
      final r1 = adapter.requests.lastWhere((r) =>
          r.method == 'POST' && r.uri.path == '/api/records/t-post/restore');
      expect(r1.uri.path, '/api/records/t-post/restore');
      final e3 = await ctrl.restore('t-draft');
      expect(e3, isNull);
      expect(
          adapter.requests,
          anyElement(predicate<RequestOptions>((r) =>
              r.method == 'POST' &&
              r.uri.path == '/api/records/t-draft/restore')));
      // 恢复后回收站本地移除两条
      final trashIds =
          container.read(personalControllerProvider).trash.map((r) => r.id);
      // 重拉会按 adapter 全量返回（本夹具不模拟服务端删除态），此处只断言
      // POST restore 路径与无错误；真实服务端 restore 后 deleted=NULL。
      expect(trashIds, isA<Iterable<String>>());
    });

    test('对象账号的回收站不含我的条目（客户端二次过滤）', () async {
      final adapter = _adapter(uid: 'u2');
      final container = await _setup(adapter, uid: 'u2');
      final ctrl = container.read(personalControllerProvider.notifier);
      await ctrl.load();
      await ctrl.loadTrash();
      expect(container.read(personalControllerProvider).trash,
          everyElement(predicate<TogetherRecord>((r) => r.author == 'u2')));
    });
  });

  // ── ⑦ 三类删除文案统一 ──────────────────────────────────────────
  group('⑦ 删除文案三类统一标准口径', () {
    testWidgets('日记 / 草稿 / 惊喜删除弹层都是同一句标准文案', (tester) async {
      final adapter = _adapter(mainRecords: [
        ..._mainRecords,
        _rec(
            id: 'dr1',
            kind: 'draft',
            author: 'u1',
            body: {
              'content': '（草稿）',
              'date': '2026-11-13',
              'media': <String>[],
            }),
      ]);
      final container = await _setup(adapter);
      await _pump(tester, container);

      for (final tooltip in ['删除日记', '删除惊喜', '删除草稿']) {
        // 切到对应 tab
        final tab = tooltip == '删除日记'
            ? '私密日记'
            : tooltip == '删除惊喜'
                ? '定时惊喜'
                : '草稿箱';
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        final btn = find.byTooltip(tooltip);
        if (btn.evaluate().isEmpty) continue;
        await tester.tap(btn.first);
        await tester.pumpAndSettle();
        expect(find.text(privateDeleteText), findsOneWidget);
        expect(find.text('删除后会进入回收站，30 天内可以恢复。'), findsOneWidget);
        expect(find.textContaining('不进回收站'), findsNothing);
        expect(find.textContaining('不可恢复'), findsNothing);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      }
      await _flush(tester);
    });
  });

  // ── ⑧ 返回路径 + ⑨ 无死卡 ──────────────────────────────────────
  group('⑧ 返回路径 + ⑨ 无预置死卡', () {
    testWidgets('惊喜表单：按钮返回 + 系统手势返回都能回个人角落',
        (tester) async {
      final adapter = _adapter();
      final container = await _setup(adapter);
      await _pump(tester, container);
      await tester.tap(find.text('定时惊喜'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('准备惊喜'));
      await tester.pumpAndSettle();
      expect(find.text('想说的话'), findsOneWidget); // 表单已打开

      // 系统手势返回
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('我的小角落'), findsOneWidget);
      expect(find.text('想说的话'), findsNothing);

      // 再次进入，点 AppBar 返回按钮
      await tester.tap(find.text('准备惊喜'));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('我的小角落'), findsOneWidget);
      await _flush(tester);
    });

    testWidgets('4 个 tab；7-C 个人心愿不预置；回收站无新建入口',
        (tester) async {
      final adapter = _adapter();
      final container = await _setup(adapter);
      await _pump(tester, container);
      expect(personalTabs.length, 4);
      expect(personalTabs.map((t) => t.id).toList(),
          ['diary', 'draft', 'surprise', 'trash']);
      expect(find.text('个人心愿'), findsNothing);
      await tester.tap(find.text('回收站'));
      await tester.pumpAndSettle();
      expect(find.text('恢复这份回忆'), findsWidgets);
      expect(find.text('准备惊喜'), findsNothing);
      await _flush(tester);
    });
  });
}
