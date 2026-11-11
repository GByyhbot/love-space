/* 长按链路回归测试（复验缺陷 2/3：共同根因=长按回调里的 rowContext 实为
   SliverList 元素，findRenderObject 返回 RenderSliverList，as RenderBox 抛
   TypeError → 菜单不弹/缩放不动/撤回入口全失效。修复后：长按气泡 → 菜单
   就近弹出（含撤回项）→ 撤回确认 → 列表行原地变撤回态，全链路应保持绿。 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart';
import 'package:love_space/core/chat/chat_media.dart';
import 'package:love_space/core/chat/chat_models.dart';
import 'package:love_space/core/chat/chat_state.dart';
import 'package:love_space/features/chat/messages_page.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions options, int callIndex) handler;
  final List<RequestOptions> posts = [];
  int gets = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.method == 'POST') {
      posts.add(options);
      return handler(options, posts.length - 1);
    }
    return handler(options, gets++);
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

List<Override> _overrides(Dio dio, ChatPersistence store) => [
      dioProvider.overrideWith((ref) async => dio),
      chatPersistenceProvider.overrideWith((ref) async => store),
      chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
      mediaCookieHeadersProvider.overrideWith((ref) async => {'Cookie': 'k=v'}),
    ];

void main() {
  testWidgets('长按气泡：菜单弹出（撤回项在列）→ 确认撤回 → 行变撤回态',
      (tester) async {
    await _probe(tester);
  });
}

Future<void> _probe(WidgetTester tester) async {
  var recallPosted = false;
  var recordsServed = false;
  final created = DateTime.now()
          .subtract(const Duration(seconds: 30))
          .millisecondsSinceEpoch /
      1000;
  final adapter = _FakeAdapter((options, callIndex) {
    // 认证 bootstrap：GET /api/me（authProvider 在 ProviderScope 首次 read 时构建）
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
    if (options.uri.path == '/api/records/r1/recall') {
      recallPosted = true;
      return jsonOk({'ok': true});
    }
    if (options.uri.path == '/api/records') {
      if (!recordsServed) {
        recordsServed = true;
        return jsonOk([
          {
            'id': 'r1', 'kind': 'chat', 'author': 'u1',
            'body': {'content': '你好呀'},
            'created': created, 'updated': created,
            'client_id': '', 'media': [],
          }
        ]);
      }
      return jsonOk(const []);
    }
    return jsonOk(const []);
  });
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  final store = _MemStore();

  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(dio, store),
      child: const MaterialApp(home: MessagesPage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle(const Duration(seconds: 1));

  expect(find.text('你好呀'), findsOneWidget,
      reason: '首屏对账后消息气泡应已渲染（若此步失败=进入页面即断，与长按无关）');

  // 长按气泡文本 → 操作菜单就近弹出
  await tester.longPress(find.text('你好呀'));
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.text('复制'), findsOneWidget, reason: '长按后应弹出操作菜单');
  expect(find.text('引用'), findsOneWidget);
  expect(find.text('置顶'), findsOneWidget);
  expect(find.text('记入时光'), findsOneWidget);
  expect(find.text('撤回'), findsOneWidget, reason: '本人 30s 前消息应显示撤回项');

  // 点撤回 → 确认弹层（文案对齐 Web）→ 确认
  await tester.tap(find.text('撤回'));
  await tester.pumpAndSettle();
  expect(find.text('撤回这条悄悄话？'), findsOneWidget);
  await tester.tap(find.text('确认'));
  await tester.pumpAndSettle();

  expect(recallPosted, true, reason: 'POST /api/records/r1/recall 应已发出');
  expect(find.text('你撤回了一条消息'), findsOneWidget,
      reason: '撤回成功后列表行应原地变撤回态');
  expect(find.text('你好呀'), findsNothing);
}
