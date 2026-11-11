/* 游标分页单测：before/before_id 参数构造 + 两页拼接（created 升序、无重复无丢失）。
   用假 HttpClientAdapter 拦截请求，不触网。 */
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/chat/chat_models.dart';
import 'package:love_space/core/chat/chat_repository.dart';

ChatRecord rec(String id, double created, {String clientId = ''}) =>
    ChatRecord(
      id: id, author: 'a1', created: created, updated: created,
      body: ChatBody(content: 'm-$id'), clientId: clientId,
    );

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions options) handler;
  final List<RequestOptions> seen = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    seen.add(options);
    return handler(options);
  }
}

ResponseBody jsonOk(Object data) => ResponseBody.fromString(
    jsonEncode(data), 200,
    headers: {Headers.contentTypeHeader: const ['application/json']});

void main() {
  test('上翻游标：before=<oldest created>&before_id=<oldest id> 传参正确', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'));
    final adapter = _FakeAdapter((options) => jsonOk([]));
    dio.httpClientAdapter = adapter;

    final oldest = rec('oldest', 1000.5);
    await fetchOlderChats(dio, oldest, limit: 200);

    expect(adapter.seen, hasLength(1));
    final q = adapter.seen.first.uri.queryParameters;
    expect(q['kind'], 'chat');
    expect(q['limit'], '200');
    expect(double.parse(q['before']!), 1000.5);
    expect(q['before_id'], 'oldest');
  });

  test('两页拼接：升序、无重复、无丢失（服务端 DESC 返回，客户端反转归一）', () async {
    // 第一页：created 300..1499（服务端 created DESC 返回）
    final page1 = [for (var i = 1499; i >= 300; i--) rec('r$i', i.toDouble())];
    // 第二页（游标之前）：created 0..299，同样 DESC
    final page2 = [for (var i = 299; i >= 0; i--) rec('r$i', i.toDouble())];

    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'));
    dio.httpClientAdapter = _FakeAdapter((options) {
      final before = options.uri.queryParameters['before'];
      // 无 before=首屏；带 before=游标之前的更早一页（created < before）
      return jsonOk(before == null
          ? page1.map((r) => r.toJson()).toList()
          : page2.map((r) => r.toJson()).toList());
    });

    final first = await fetchLatestChats(dio);
    final oldest = first.reduce((a, b) => a.created < b.created ? a : b);
    final older = await fetchOlderChats(dio, oldest);

    final result = mergeChats(mergeChats(const [], first).merged, older).merged;

    expect(result, hasLength(1500));
    expect(result.first.id, 'r0');
    expect(result.last.id, 'r1499');
    // 升序且无重复
    for (var i = 1; i < result.length; i++) {
      expect(result[i].created, greaterThan(result[i - 1].created));
    }
    expect(result.map((r) => r.id).toSet(), hasLength(1500));
  });

  test('发送返回单条并入：按 id 去重（重试幂等返回同一条不重复）', () {
    final base = mergeChats(const [], [rec('a', 1), rec('b', 2)]).merged;
    final again = mergeChats(base, [rec('a', 1)]).merged;
    expect(again, hasLength(2));
    expect(again.where((r) => r.id == 'a'), hasLength(1));
  });
}
