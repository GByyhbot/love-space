/* QA 独立边界用例（不沿用工程师用例，单独补测三条链路）：
   ① 重试成功后再次 retry（同 client_id）：pending 行已不存在 → no-op，
      不再发 POST、不产生重复气泡（防双击/防重复入列）；
   ② 控制器级幂等收尾：发送失败后 SSE 对账拉回「同 client_id」的服务端记录 →
      内存 pending 行删除 + 落盘 pending 删除 + 记录并入列表且无重复；
   ③ 时间条跨年边界：今天是 1 月 1 日，消息在去年 12 月 31 日 →
      应显示「昨天 HH:mm」（Web 先判昨天再判年份），不得出现「2025年12月31日」。 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart';
import 'package:love_space/core/chat/chat_models.dart';
import 'package:love_space/core/chat/chat_state.dart';
import 'package:love_space/core/chat/chat_time.dart';

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
    if (options.method == 'POST') posts.add(options);
    return options.method == 'GET' ? handler(options, gets++) : handler(options, 0);
  }
}

ResponseBody jsonOk(Object data) => ResponseBody.fromString(
    jsonEncode(data), 200,
    headers: {Headers.contentTypeHeader: const ['application/json']});

ResponseBody _post422() => ResponseBody.fromString(
    jsonEncode({'detail': '网络开小差了'}), 422,
    headers: {Headers.contentTypeHeader: const ['application/json']});

/// 内存持久层（模拟落盘）
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
}

ProviderContainer _container(_MemStore store, _FakeAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  return ProviderContainer(overrides: [
    dioProvider.overrideWith((ref) async => dio),
    chatPersistenceProvider.overrideWith((ref) async => store),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('QA① 重试成功后二次重试：no-op，不重复 POST、不产生重复行', () async {
    final store = _MemStore();
    var postFailed = false;
    final adapter = _FakeAdapter((options, _) {
      if (options.method == 'POST') {
        if (!postFailed) {
          postFailed = true;
          return _post422();
        }
        final body = options.data as Map;
        return jsonOk({
          'id': 'srv-1', 'kind': 'chat', 'author': 'u1',
          'body': body['body'], 'created': 1000.0, 'updated': 1000.0,
          'client_id': body['client_id'], 'media': [],
        });
      }
      return jsonOk(const []);
    });
    final c = _container(store, adapter);
    addTearDown(c.dispose);
    final controller = c.read(chatControllerProvider.notifier);
    await controller.bootstrap('u1');

    await expectLater(controller.send('你好'), throwsA(anything));
    final clientId =
        c.read(chatControllerProvider).rows.whereType<ChatPendingRow>().single.clientId;

    await controller.retry(clientId); // 成功
    await controller.retry(clientId); // 行已不存在 → 应 no-op
    await controller.retry(clientId); // 再来一次（连点三下）

    final state = c.read(chatControllerProvider);
    expect(state.rows.whereType<ChatPendingRow>(), isEmpty);
    expect(state.rows.whereType<ChatRecordRow>(), hasLength(1)); // 无重复气泡
    // POST 恰好 2 次：失败那次 + 成功重试一次；后两次 retry 不应再发
    expect(adapter.posts, hasLength(2));
    expect(store.pendings, isEmpty);
  });

  test('QA② 对账幂等收尾：服务端记录与本地 pending 同 client_id → 内存+落盘 pending 双清', () async {
    final store = _MemStore();
    String? sentClientId;
    final adapter = _FakeAdapter((options, callIndex) {
      if (options.method == 'POST') {
        sentClientId = (options.data as Map)['client_id'] as String;
        return _post422();
      }
      // GET：首次（bootstrap）无历史；对账这一次返回「同 client_id」的服务端记录
      // （模拟发送成功但响应丢失，SSE 通知后重拉拿回记录）
      if (callIndex == 0) return jsonOk(const []);
      return jsonOk([
        {
          'id': 'srv-9', 'kind': 'chat', 'author': 'u1',
          'body': {'content': '超时但其实已发出', 'media': []},
          'created': 1000.0, 'updated': 1000.0,
          'client_id': sentClientId, 'media': [],
        }
      ]);
    });
    final c = _container(store, adapter);
    addTearDown(c.dispose);
    final controller = c.read(chatControllerProvider.notifier);
    await controller.bootstrap('u1');

    await expectLater(controller.send('超时但其实已发出'), throwsA(anything));
    expect(c.read(chatControllerProvider).rows.whereType<ChatPendingRow>(),
        hasLength(1));
    expect(store.pendings, hasLength(1));

    await controller.reconcile(); // SSE 触发对账

    final state = c.read(chatControllerProvider);
    expect(state.rows.whereType<ChatPendingRow>(), isEmpty); // 内存 pending 删除
    final recordRows = state.rows.whereType<ChatRecordRow>().toList();
    expect(recordRows, hasLength(1)); // 记录并入且无重复
    expect(recordRows.single.record.id, 'srv-9');
    expect(recordRows.single.record.clientId, sentClientId);
    expect(store.pendings, isEmpty); // 落盘 pending 同步删除
  });

  test('QA③ 跨年边界：1 月 1 日看去年 12 月 31 日的消息 → 「昨天」而非年份前缀', () {
    DateTime now() => DateTime(2026, 1, 1, 10, 0);
    double at(int y, int m, int d, int hh, int mm) =>
        DateTime(y, m, d, hh, mm).millisecondsSinceEpoch / 1000;
    // 2025-12-31 23:30 → 对 2026-01-01 而言是昨天
    final label = chatTimeLabel(at(2025, 12, 31, 23, 30), null, now: now);
    expect(label, '昨天 23:30');
    // 对照：再往前一天（12 月 30 日）才落到跨年年份前缀
    final older = chatTimeLabel(at(2025, 12, 30, 8, 0), null, now: now);
    expect(older, '2025年12月30日 08:00');
  });
}
