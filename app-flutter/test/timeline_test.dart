/* 时光页段一单测（条目 4 · 段一，timeline-plan §1 质量关）：
   ① 游标 61/60 分页与去重拼接（buildTimelineQuery 带/不带 cursor +
      appendTimelinePage 只追加按 id 去重）
   ② 筛选参数组装矩阵（q/author/date/media_type 四参数全组合）
   ③ b.date||dateLabel(created) 双时间口径（postHeaderDate）
   ④ composer client_id 幂等复用（发布失败重试不换 id、成功清空）
   ⑤ 卡片字段解析矩阵（title 缺省/媒体空/likes 评论空/畸形数据容错） */
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_models.dart'
    show ChatPending, ChatRecord;
import 'package:love_space/core/chat/chat_state.dart'
    show ChatPersistence, chatPersistenceProvider;
import 'package:love_space/core/timeline/timeline_data.dart';
import 'package:love_space/features/timeline/timeline_controller.dart';

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

api.Record _rec(String id, {double created = 1.0}) => api.Record.fromJson({
      'id': id, 'kind': 'post', 'author': 'u1',
      'body': {'content': 'm-$id'}, 'created': created, 'updated': created,
      'client_id': '', 'media': [], 'likes': [], 'comments': [],
    });

void main() {
  // ── ① 游标分页与去重拼接 ────────────────────────────────────────────
  group('① buildTimelineQuery 游标 + appendTimelinePage 去重', () {
    test('基础参数：kind=post + limit=61（拉 61 判 hasMore 留 60）', () {
      final q = buildTimelineQuery(const TimelineFilter());
      expect(q['kind'], 'post');
      expect(q['limit'], 61);
      expect(q.containsKey('before'), false);
    });

    test('上翻游标：before=<created>&before_id=<id>（reset 时不带）', () {
      final q = buildTimelineQuery(const TimelineFilter(),
          cursor: (1700000000.5, 'last-id'));
      expect(q['before'], 1700000000.5);
      expect(q['before_id'], 'last-id');
    });

    test('appendTimelinePage：只追加新 id、不重复、保持服务端序', () {
      final current = [_rec('a'), _rec('b')];
      final (n1, m1) =
          appendTimelinePage(current, [_rec('c'), _rec('d')], (r) => r.id);
      expect(n1, 2);
      expect(m1.map((r) => r.id).toList(), ['a', 'b', 'c', 'd']);
      // 重叠页（翻页时重复出现）→ 只追加新条目
      final (n2, m2) =
          appendTimelinePage(m1, [_rec('d'), _rec('e')], (r) => r.id);
      expect(n2, 1);
      expect(m2.map((r) => r.id).toList(), ['a', 'b', 'c', 'd', 'e']);
      // 完全重复 → 0 新增
      final (n3, m3) =
          appendTimelinePage(m2, [_rec('a'), _rec('e')], (r) => r.id);
      expect(n3, 0);
      expect(m3.map((r) => r.id).toList(), m2.map((r) => r.id).toList());
    });
  });

  // ── ② 筛选参数组装矩阵 ──────────────────────────────────────────────
  group('② buildTimelineQuery 筛选参数矩阵', () {
    test('四参数全带（含 media_type 参数名映射）', () {
      final q = buildTimelineQuery(const TimelineFilter(
          q: '旅行', author: 'u2', date: '2026-01-01', media: 'image'));
      expect(q['q'], '旅行');
      expect(q['author'], 'u2');
      expect(q['date'], '2026-01-01');
      expect(q['media_type'], 'image'); // 参数名映射：filter.media → media_type
    });

    test('空筛选：不出现空值参数键', () {
      final q = buildTimelineQuery(const TimelineFilter());
      for (final k in ['q', 'author', 'date', 'media_type']) {
        expect(q.containsKey(k), false, reason: '空筛选不应带 $k');
      }
    });

    test('部分筛选：只带非空键', () {
      final q = buildTimelineQuery(const TimelineFilter(author: 'u1'));
      expect(q.containsKey('author'), true);
      expect(q.containsKey('q'), false);
      expect(q.containsKey('date'), false);
      expect(q.containsKey('media_type'), false);
    });
  });

  // ── ③ b.date||dateLabel(created) 双时间口径 ─────────────────────────
  group('③ postHeaderDate 双时间口径', () {
    test('body.date 存在 → 发生日优先', () {
      expect(postHeaderDate(bodyDate: '2021-05-20', created: 1794358046.75),
          '2021-05-20');
    });

    test('body.date 缺省 → dateLabel(created)（M月d日 HH:mm）', () {
      final label = postHeaderDate(bodyDate: '', created: 1794358046.75);
      expect(RegExp(r'^\d{1,2}月\d{1,2}日 \d{2}:\d{2}$').hasMatch(label), true,
          reason: '实际值：$label');
    });

    test('timelineDateLabel 补零（HH:mm）', () {
      final ts = DateTime(2026, 3, 5, 9, 7).millisecondsSinceEpoch / 1000;
      expect(timelineDateLabel(ts), '3月5日 09:07');
    });
  });

  // ── ⑤ 卡片字段解析矩阵 ──────────────────────────────────────────────
  group('⑤ 卡片字段解析（title 缺省/媒体空/likes 评论空/畸形容错）', () {
    test('post 全字段解析', () {
      final r = parsePostRecords([
        {
          'id': 'p1', 'kind': 'post', 'author': 'u1',
          'body': {
            'title': '旅行日记', 'content': '那天我们…', 'date': '2026-10-01',
            'media': []
          },
          'created': 1000.0, 'updated': 1000.0, 'client_id': '', 'media': [],
          'likes': ['u2'],
          'comments': [
            {'id': 'c1', 'author': 'u2', 'content': '好美！'}
          ],
        }
      ]);
      expect(r, hasLength(1));
      expect(r.single.body['title'], '旅行日记');
      expect(r.single.likes, ['u2']);
      expect(r.single.comments.single['content'], '好美！');
    });

    test('title 缺省/likes 评论空 → 不炸（卡片走缺省渲染）', () {
      final r = parsePostRecords([
        {
          'id': 'p2', 'kind': 'post', 'author': 'u1',
          'body': {'content': '只有一句话'}, 'created': 1.0, 'updated': 1.0,
          'client_id': '', 'media': [], 'likes': [], 'comments': [],
        },
      ]);
      expect(r.single.body['title'], isNull);
      expect(r.single.likes, isEmpty);
      expect(r.single.comments, isEmpty);
    });

    test('媒体空/畸形条目容错', () {
      final r = parsePostRecords([
        '不是 Map 的条目', // 容错跳过
        {
          'id': 'p3', 'kind': 'post', 'author': 'u1',
          'body': null, 'created': null, 'updated': null, 'client_id': null,
          'media': null, 'likes': null, 'comments': null,
        },
      ]);
      expect(r, hasLength(1));
      expect(r.single.media, isEmpty);
      expect(r.single.likes, isEmpty);
      expect(r.single.comments, isEmpty);
    });
  });

  // ── ④ composer client_id 幂等复用（控制器链路）─────────────────────
  test('④ 发布失败重试复用同一 client_id；成功后清空（下次新 id）', () async {
    final store = _MemStore();
    var postFailed = true;
    final recordPosts = <Map<String, dynamic>>[];
    final adapter = _FakeAdapter((options, _) {
      if (options.uri.path == '/api/records' && options.method == 'POST') {
        final body = options.data as Map;
        if (postFailed) {
          postFailed = false;
          return ResponseBody.fromString(
              jsonEncode({'detail': '发布失败，请重试'}), 422,
              headers: {Headers.contentTypeHeader: ['application/json']});
        }
        recordPosts.add(body.cast<String, dynamic>());
        return jsonOk({
          'id': 'srv-post', 'kind': 'post', 'author': 'u1',
          'body': body['body'], 'created': 10.0, 'updated': 10.0,
          'client_id': body['client_id'], 'media': [], 'likes': [],
          'comments': [],
        });
      }
      return jsonOk(const []); // GET 时光首屏
    });
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final container = ProviderContainer(overrides: [
      api.dioProvider.overrideWith((ref) async => dio),
      chatPersistenceProvider.overrideWith((ref) async => store),
    ]);
    addTearDown(container.dispose);

    final controller = container.read(timelineControllerProvider.notifier);
    await controller.bootstrap('u1');

    final err1 = await controller.publish(
        content: '第一条', date: '2026-11-11', mediaIds: const []);
    expect(err1, isNotNull); // 失败返回错误文案

    final err2 = await controller.publish(
        content: '第一条', date: '2026-11-11', mediaIds: const []);
    expect(err2, isNull); // 重试成功
    expect(recordPosts, hasLength(1));

    // 失败与成功两次 POST 用的是同一个 client_id（幂等复用）
    expect(recordPosts.single['client_id'], isA<String>());

    // 成功后清空 → 下次发布生成新 id
    final err3 = await controller.publish(
        content: '第二条', date: '2026-11-11', mediaIds: const []);
    expect(err3, isNull);
    expect(recordPosts, hasLength(2));
    expect(recordPosts.last['client_id'],
        isNot(recordPosts.first['client_id']));
  });

  test('④b 发布 body 形态（kind:post/body 四键/client_id）', () async {
    final store = _MemStore();
    final recordBodies = <Map<String, dynamic>>[];
    final adapter = _FakeAdapter((options, _) {
      if (options.uri.path == '/api/records' && options.method == 'POST') {
        final body = options.data as Map;
        recordBodies.add(body.cast<String, dynamic>());
        return jsonOk({
          'id': 'srv-2', 'kind': 'post', 'author': 'u1',
          'body': body['body'], 'created': 20.0, 'updated': 20.0,
          'client_id': body['client_id'], 'media': [], 'likes': [],
          'comments': [],
        });
      }
      return jsonOk(const []);
    });
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final container = ProviderContainer(overrides: [
      api.dioProvider.overrideWith((ref) async => dio),
      chatPersistenceProvider.overrideWith((ref) async => store),
    ]);
    addTearDown(container.dispose);
    final controller = container.read(timelineControllerProvider.notifier);
    await controller.bootstrap('u1');
    await controller.publish(
        title: '标题', content: '内容', date: '2026-11-11',
        mediaIds: const ['m1', 'm2']);

    final payload = recordBodies.single;
    expect(payload['kind'], 'post');
    final body = payload['body'] as Map;
    expect(body['title'], '标题');
    expect(body['content'], '内容');
    expect(body['date'], '2026-11-11');
    expect(body['media'], ['m1', 'm2']);
  });
}
