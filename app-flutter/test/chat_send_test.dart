/* 发送状态机单测（Step 3）：
   ① 发送失败标红「未发出」，pending 落盘；
   ② 重试复用同一 client_id（服务端 UNIQUE(author, client_id) 幂等依据）；
   ③ pending 落盘恢复：模拟杀进程重开（持久层实例保留 + 新容器），可重试；
   ④ 成功后 pending 删除、返回记录并入列表。
   假适配器只对 POST 施加脚本（GET /api/records 恒回空列表），
   避免 bootstrap 对账的 GET 消耗掉「首次失败」脚本。 */
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart';
import 'package:love_space/core/chat/chat_models.dart';
import 'package:love_space/core/chat/chat_state.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions options) handler;
  final List<RequestOptions> posts = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.method == 'POST') posts.add(options);
    return handler(options);
  }
}

ResponseBody jsonOk(Object data) => ResponseBody.fromString(
    jsonEncode(data), 200,
    headers: {Headers.contentTypeHeader: const ['application/json']});

ResponseBody _post422() => ResponseBody.fromString(
    jsonEncode({'detail': '网络开小差了'}), 422,
    headers: {Headers.contentTypeHeader: const ['application/json']});

/// 内存持久层：实例跨容器复用 = 模拟磁盘落盘（杀进程重开数据还在）
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

(ProviderContainer, _FakeAdapter) _makeContainer(_MemStore store,
    {bool failFirstPost = false}) {
  var failed = false;
  final adapter = _FakeAdapter((options) {
    if (options.method == 'POST') {
      if (failFirstPost && !failed) {
        failed = true;
        return _post422();
      }
      final body = options.data as Map;
      return jsonOk({
        'id': 'server-1', 'kind': 'chat', 'author': 'u1',
        'body': body['body'], 'created': 1000.0, 'updated': 1000.0,
        'client_id': body['client_id'], 'media': [],
      });
    }
    return jsonOk(const []); // GET /api/records：无历史
  });
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  final container = ProviderContainer(overrides: [
    dioProvider.overrideWith((ref) async => dio),
    chatPersistenceProvider.overrideWith((ref) async => store),
  ]);
  return (container, adapter);
}

Future<(String, ChatState)> _sendFailing(ProviderContainer container) async {
  final controller = container.read(chatControllerProvider.notifier);
  await controller.bootstrap('u1');
  await expectLater(controller.send('你好呀'), throwsA(anything));
  final state = container.read(chatControllerProvider);
  return (state.rows.whereType<ChatPendingRow>().single.clientId, state);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('发送失败：标红未发出 + pending 落盘', () async {
    final store = _MemStore();
    final (container, _) = _makeContainer(store, failFirstPost: true);
    addTearDown(container.dispose);

    final (_, state) = await _sendFailing(container);
    final row = state.rows.whereType<ChatPendingRow>().single;
    expect(row.failed, true);
    expect(row.content, '你好呀');
    expect(store.pendings.values.single.content, '你好呀');
  });

  test('杀进程重开：pending 恢复为可重试态（failed=true）', () async {
    final store = _MemStore();
    final (c1, _) = _makeContainer(store, failFirstPost: true);
    addTearDown(c1.dispose);
    final (clientId, _) = await _sendFailing(c1);

    // 模拟杀进程：新容器（进程），持久层落盘内容保留
    final (c2, _) = _makeContainer(store);
    addTearDown(c2.dispose);
    await c2.read(chatControllerProvider.notifier).bootstrap('u1');
    final restored = c2.read(chatControllerProvider).rows;
    final row = restored.whereType<ChatPendingRow>().single;
    expect(row.clientId, clientId);
    expect(row.failed, true); // 不自动重发，保留「未发出 · 点击重试」
  });

  test('重试复用同一 client_id；成功后 pending 删除、记录并入列表', () async {
    final store = _MemStore();
    final (c1, a1) = _makeContainer(store, failFirstPost: true);
    addTearDown(c1.dispose);
    final (clientId, _) = await _sendFailing(c1);

    final (c2, a2) = _makeContainer(store); // 本次 POST 成功
    addTearDown(c2.dispose);
    await c2.read(chatControllerProvider.notifier).bootstrap('u1');
    await c2.read(chatControllerProvider.notifier).retry(clientId);

    final state = c2.read(chatControllerProvider);
    expect(state.rows.whereType<ChatPendingRow>(), isEmpty);
    final recordRow = state.rows.whereType<ChatRecordRow>().single;
    expect(recordRow.record.id, 'server-1');
    expect(recordRow.record.clientId, clientId);
    expect(store.pendings, isEmpty);
    // 两次 POST（失败那次 + 重试这次）用的是同一个 client_id
    final postedIds = [...a1.posts, ...a2.posts]
        .map((p) => (p.data as Map)['client_id'])
        .toSet();
    expect(postedIds, {clientId});
  });

  test('连续失败发送：pending 行按发送顺序追加在列表末尾', () async {
    final store = _MemStore();
    final adapter = _FakeAdapter((options) =>
        options.method == 'POST' ? _post422() : jsonOk(const []));
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final container = ProviderContainer(overrides: [
      dioProvider.overrideWith((ref) async => dio),
      chatPersistenceProvider.overrideWith((ref) async => store),
    ]);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.bootstrap('u1');
    await expectLater(controller.send('第一条'), throwsA(anything));
    await expectLater(controller.send('第二条'), throwsA(anything));
    final pendings = container
        .read(chatControllerProvider)
        .rows
        .whereType<ChatPendingRow>()
        .toList();
    expect(pendings.map((p) => p.content).toList(), ['第一条', '第二条']);
    expect(pendings.every((p) => p.failed), true);
  });
}
