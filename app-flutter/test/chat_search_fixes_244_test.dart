/* 2.4.4 提交三（第 3+4 项）断言：
   ① 搜索栏悬浮胶囊化：底板透明、胶囊圆角 26/左右 10 与面板同源、✕ 圆钮
      （直径 34）在胶囊边界内、关闭语义原样；
   ② 假入口修复：数据看板/回忆周报/共同年历/恋爱清单/共同愿望/共同账本
      六入口 push 到 hub 同款真路由（GoRouter stub 断言）；
   ③ 源码护栏：lib/ 内「迁移后开放」字面量清零。 */
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:love_space/core/api/api_client.dart';
import 'package:love_space/core/chat/chat_media.dart';
import 'package:love_space/core/chat/chat_models.dart';
import 'package:love_space/core/chat/chat_state.dart';
import 'package:love_space/features/chat/messages_page.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions options, int callIndex) handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return handler(options, 0);
  }
}

ResponseBody jsonOk(Object data) => ResponseBody.fromString(
    jsonEncode(data), 200,
    headers: {Headers.contentTypeHeader: ['application/json']});

class _MemStore implements ChatPersistence {
  final records = <ChatRecord>[];
  final pendings = <String, ChatPending>{};

  @override
  Future<void> saveRecords(List<ChatRecord> rs) async => records.addAll(rs);

  @override
  Future<List<ChatRecord>> loadRecords() async => records;

  @override
  Future<void> upsertPending(ChatPending p) async => pendings[p.clientId] = p;

  @override
  Future<void> deletePending(String clientId) async => pendings.remove(clientId);

  @override
  Future<List<ChatPending>> loadPending() async => pendings.values.toList();

  @override
  Future<void> saveMySticker(String userId, String mid, String name) async {}

  @override
  Future<void> deleteMySticker(String userId, String mid) async {}

  @override
  Future<List<(String, String)>> loadMyStickers(String userId) async => const [];
}

final _stubRoutes = <String, Widget Function(BuildContext, GoRouterState)>{
  '/together/dashboard': (c, s) => Scaffold(
      appBar: AppBar(), body: const Text('STUB-dashboard')),
  '/together/weekly': (c, s) => Scaffold(
      appBar: AppBar(), body: const Text('STUB-weekly')),
  '/together/calendar': (c, s) => Scaffold(
      appBar: AppBar(), body: const Text('STUB-calendar')),
  '/together/quest': (c, s) => Scaffold(
      appBar: AppBar(), body: const Text('STUB-quest')),
  '/together/wish': (c, s) => Scaffold(
      appBar: AppBar(), body: const Text('STUB-wish')),
  '/together/ledger': (c, s) => Scaffold(
      appBar: AppBar(), body: const Text('STUB-ledger')),
};

Future<void> _pumpChat(WidgetTester tester) async {
  final created = DateTime.now().millisecondsSinceEpoch / 1000;
  final adapter = _FakeAdapter((options, callIndex) {
    if (options.uri.path == '/api/me') {
      return jsonOk({
        'user': {'id': 'u1', 'name': '我', 'username': 'u1'},
        'users': [
          {'id': 'u1', 'name': '我', 'username': 'u1'},
          {'id': 'u2', 'name': 'TA', 'username': 'u2'},
        ],
        'space': {},
        'unread': 0,
        'chat_unread': 0,
      });
    }
    return jsonOk([
      {
        'id': 'r1', 'kind': 'chat', 'author': 'u1',
        'body': {'content': '你好呀'},
        'created': created, 'updated': created,
        'client_id': '', 'media': [],
      }
    ]);
  });
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  final router = GoRouter(
    initialLocation: '/messages',
    routes: [
      GoRoute(path: '/messages', builder: (_, _) => const MessagesPage()),
      for (final e in _stubRoutes.entries)
        GoRoute(path: e.key, builder: e.value),
    ],
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [
      dioProvider.overrideWith((ref) async => dio),
      chatPersistenceProvider.overrideWith((ref) async => _MemStore()),
      chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
      mediaCookieHeadersProvider.overrideWith((ref) async => {'Cookie': 'k=v'}),
    ],
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle(const Duration(seconds: 1));
}

void main() {
  test('③ 源码护栏：lib/ 内「迁移后开放」字面量清零', () {
    final lib = Directory('lib');
    final offenders = <String>[];
    for (final f in lib.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      if (f.readAsStringSync().contains('迁移后开放')) offenders.add(f.path);
    }
    expect(offenders, isEmpty,
        reason: '迁移期占位全部摘除（figure 的 Web 专属文案不含该字面量）');
  });

  testWidgets('① 搜索栏悬浮胶囊：边距/圆角同源、✕ 圆钮在胶囊内、关闭原样',
      (tester) async {
    await _pumpChat(tester);

    // 打开搜索：面板「搜消息」→ onOpenSearch 回调（搜索从面板进入）
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.text('搜消息'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final capsule =
        tester.getRect(find.byKey(const Key('search-bar-capsule')));
    expect(capsule.left, 10, reason: '左右边距 10 与面板/输入栏同源');
    expect(capsule.width, tester.view.physicalSize.width /
        tester.view.devicePixelRatio - 20,
        reason: '左右各 10（不目测另写）');

    final capsuleWidget = tester.widget<Container>(
        find.byKey(const Key('search-bar-capsule')));
    final deco = capsuleWidget.decoration! as BoxDecoration;
    expect(deco.borderRadius, BorderRadius.circular(26),
        reason: '全圆角与输入栏胶囊同档');
    // 底板去掉：胶囊底色 = chatChromeColor（外壳契约五处同源），外层透明
    final outer = tester.widget<Container>(find
        .byWidgetPredicate((w) =>
            w is Container &&
            w.child is Container &&
            (w.child! as Container).key ==
                const Key('search-bar-capsule')));
    expect(outer.color, Colors.transparent, reason: '底板去掉透出聊天背景');

    // ✕ 圆钮在胶囊边界内
    final closeDot = tester.getRect(find.byKey(const Key('search-close-dot')));
    expect(closeDot.width, 34);
    expect(closeDot.height, 34);
    expect(closeDot.left, greaterThanOrEqualTo(capsule.left),
        reason: '✕ 圆钮在胶囊边界内');
    expect(closeDot.right, lessThanOrEqualTo(capsule.right));
    expect(closeDot.top, greaterThanOrEqualTo(capsule.top));
    expect(closeDot.bottom, lessThanOrEqualTo(capsule.bottom));

    // 输入处理原样：输入词不崩；关闭 → 栏收起
    await tester.enterText(find.byType(TextField).first, '你好');
    await tester.pump();
    await tester.tap(find.byKey(const Key('search-close-dot')));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byKey(const Key('search-bar-capsule')), findsNothing,
        reason: '关闭语义原样（收栏恢复列表）');
  });

  testWidgets('② 六个假入口 push 到 hub 同款真路由（不再弹占位 toast）',
      (tester) async {
    await _pumpChat(tester);
    final tiles = <String, String>{
      '数据看板': 'STUB-dashboard',
      '回忆周报': 'STUB-weekly',
      '共同年历': 'STUB-calendar',
      '恋爱清单': 'STUB-quest',
      '共同愿望': 'STUB-wish',
      '共同账本': 'STUB-ledger',
    };
    for (final e in tiles.entries) {
      // 每个入口都从聊天页面板打开（stub 页返回后仍在聊天页）
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await tester.tap(find.text(e.key), warnIfMissed: false);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.text(e.value), findsOneWidget,
          reason: '${e.key} → push 真路由（不再弹「迁移后开放」）');
      // 回聊天页再测下一个
      final back = find.byType(BackButtonIcon);
      if (back.evaluate().isNotEmpty) {
        await tester.tap(back.first);
        await tester.pumpAndSettle(const Duration(seconds: 1));
      }
    }
    // 占位 toast 文案不再出现
    expect(find.textContaining('迁移后开放'), findsNothing);
  });
}
