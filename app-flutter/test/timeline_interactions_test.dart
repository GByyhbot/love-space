/* 时光页段二 B 互动单测（条目 4）：
   ① 纯函数：点赞本地翻转 / 评论按 cid 去重合并 / 仅本人可删
   ② 控制器：点赞乐观翻转+失败回滚（顶部通知）/ 本卡原地更新其它卡引用不变
   ③ 评论 POST 真实 cid 即时插入 + SSE other 重拉（服务端已回显/未回显）不重复
   ④ 删评论成功移除 / 失败回滚 / 非本人无入口 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/timeline/timeline_data.dart';
import 'package:love_space/features/chat/chat_toast.dart' show chatToastProvider;
import 'package:love_space/features/timeline/timeline_controller.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions options, int callIndex) handler;
  int calls = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return handler(options, calls++);
  }
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
    jsonEncode(data), status,
    headers: {Headers.contentTypeHeader: const ['application/json']});

Map<String, Object> _recJson(String id,
    {List<Object> likes = const [],
    List<Object> comments = const [],
    double created = 100.0}) => {
      'id': id, 'kind': 'post', 'author': 'u1',
      'body': {'content': 'm-$id'}, 'created': created, 'updated': created,
      'client_id': '', 'media': <Object>[],
      'likes': likes, 'comments': comments,
    };

Map<String, Object> _comment(String cid, String rid, String author,
        {double created = 200.0}) =>
    {'id': cid, 'record_id': rid, 'author': author,
     'content': 'text-$cid', 'created': created};

/// 建一个已加载首屏的控制器（GET 返回两张卡）
Future<(ProviderContainer, List<ResponseBody> Function())> _setup(
    _FakeAdapter adapter) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  final container = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
  ]);
  addTearDown(container.dispose);
  final controller = container.read(timelineControllerProvider.notifier);
  await controller.load(reset: true);
  return (container, () => const <ResponseBody>[]);
}

void main() {
  // ── ① 纯函数 ────────────────────────────────────────────────
  group('① 互动纯函数', () {
    test('toggleLocalLikes：无我→加我、有我→移除，其余不变', () {
      expect(toggleLocalLikes(const [], 'me'), ['me']);
      expect(toggleLocalLikes(const ['u2', 'me'], 'me'), ['u2']);
      expect(toggleLocalLikes(const ['u2'], 'me'), ['u2', 'me']);
    });

    test('mergeCommentsByCid：同 cid 只保留一条，按 created 升序', () {
      final server = [
        _comment('c1', 'r1', 'u2', created: 200),
        _comment('c2', 'r1', 'u1', created: 300),
      ];
      final local = [
        _comment('c1', 'r1', 'u1', created: 250), // 与服务端重复
        _comment('c3', 'r1', 'u1', created: 100), // 新增，created 更小
      ];
      final merged = mergeCommentsByCid(server, local);
      expect(merged.length, 3);
      expect(merged.map((c) => c['id']).toList(), ['c3', 'c1', 'c2']);
      // 重复的 c1 以服务端为准（author/created 不被本地覆盖）
      expect(merged[1]['author'], 'u2');
    });

    test('canDeleteComment：仅本人', () {
      expect(canDeleteComment(_comment('c', 'r', 'u1'), 'u1'), isTrue);
      expect(canDeleteComment(_comment('c', 'r', 'u2'), 'u1'), isFalse);
    });
  });

  // ── ② 点赞：乐观翻转 / 失败回滚 / 本卡原地更新 ───────────────
  group('② 点赞 toggle', () {
    test('成功：本地翻转 likes，且只替换本卡（其它卡引用不变）', () async {
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'GET') {
          return _json([_recJson('r1'), _recJson('r2')]);
        }
        return _json({'ok': true}); // POST like
      });
      final (container, _) = await _setup(adapter);
      final notifier = container.read(timelineControllerProvider.notifier);
      final before = container.read(timelineControllerProvider).posts;
      final otherBefore = before[1];

      await notifier.toggleLike('r1', 'me');
      final after = container.read(timelineControllerProvider).posts;
      expect(after[0].likes, contains('me'));
      expect(after.length, 2);
      expect(identical(after[1], otherBefore), isTrue,
          reason: '本卡原地更新：其它卡对象引用必须不变');
      expect(after[1].likes, isEmpty);
    });

    test('取消点赞：已有本人 id → 移除', () async {
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'GET') {
          return _json([_recJson('r1', likes: const ['me', 'u2'])]);
        }
        return _json({'ok': true});
      });
      final (container, _) = await _setup(adapter);
      await container
          .read(timelineControllerProvider.notifier)
          .toggleLike('r1', 'me');
      expect(container.read(timelineControllerProvider).posts.single.likes,
          ['u2']);
    });

    test('失败（断网）：回滚到点前状态 + 顶部通知', () async {
      var postFailed = false;
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'GET') {
          return _json([_recJson('r1', likes: const ['u2'])]);
        }
        postFailed = true;
        return _json({'detail': '网络不可用'}, 503);
      });
      final (container, _) = await _setup(adapter);
      final notifier = container.read(timelineControllerProvider.notifier);
      await notifier.toggleLike('r1', 'me');
      expect(postFailed, isTrue);
      final posts = container.read(timelineControllerProvider).posts;
      expect(posts.single.likes, ['u2'], reason: '失败必须回滚到点前状态');
      // 顶部通知（同一 chatToastProvider，验收断言有提示而非静默失败）
      // ignore: invalid_use_of_protected_member
      expect(container.read(chatToastProvider)?.text, isNotNull);
    });
  });

  // ── ③ 评论：即时插入 + SSE 重拉去重 ──────────────────────────
  group('③ 评论与 SSE other 重拉去重', () {
    test('POST 返回真实 cid → 卡片即时插入（1 条）', () async {
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'GET') return _json([_recJson('r1')]);
        return _json({'id': 'cid-new'});
      });
      final (container, _) = await _setup(adapter);
      final ok = await container
          .read(timelineControllerProvider.notifier)
          .addComment('r1', ' 你好 ', 'u1');
      expect(ok, isTrue);
      final comments =
          container.read(timelineControllerProvider).posts.single.comments;
      expect(comments.length, 1);
      expect(comments.single['id'], 'cid-new');
      expect(comments.single['content'], '你好');
    });

    test('SSE other 重拉：服务端已回显本端评论 → 不重复；对方新评论刷出',
        () async {
      var getCount = 0;
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'POST') return _json({'id': 'cid-mine'});
        getCount++;
        if (getCount == 1) return _json([_recJson('r1')]);
        // 重拉：服务端已有本端 cid-mine + 对方在 Web 发的 cid-other
        return _json([
          _recJson('r1', comments: [
            _comment('cid-mine', 'r1', 'u1', created: 200),
            _comment('cid-other', 'r1', 'u2', created: 300),
          ])
        ]);
      });
      final (container, _) = await _setup(adapter);
      final notifier = container.read(timelineControllerProvider.notifier);
      await notifier.addComment('r1', '我的评论', 'u1');
      expect(container
          .read(timelineControllerProvider)
          .posts
          .single
          .comments
          .length, 1);
      await notifier.resetOnSseOther();
      final comments =
          container.read(timelineControllerProvider).posts.single.comments;
      expect(comments.length, 2, reason: '不得出现 3 条（本端那条重复）');
      expect(comments.map((c) => c['id']).toSet(),
          {'cid-mine', 'cid-other'});
    });

    test('SSE 重拉快照早于本端 POST：本地即时插入的评论不被抹掉', () async {
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'POST') return _json({'id': 'cid-mine'});
        // 两次 GET 都不含 cid-mine（模拟服务端快照滞后）
        return _json([_recJson('r1')]);
      });
      final (container, _) = await _setup(adapter);
      final notifier = container.read(timelineControllerProvider.notifier);
      await notifier.addComment('r1', '我的评论', 'u1');
      await notifier.resetOnSseOther();
      final comments =
          container.read(timelineControllerProvider).posts.single.comments;
      expect(comments.length, 1);
      expect(comments.single['id'], 'cid-mine');
    });

    test('内容空 / 超 5000 → 不发请求', () async {
      var posts = 0;
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'GET') return _json([_recJson('r1')]);
        posts++;
        return _json({'id': 'x'});
      });
      final (container, _) = await _setup(adapter);
      final notifier = container.read(timelineControllerProvider.notifier);
      expect(await notifier.addComment('r1', '   ', 'u1'), isFalse);
      expect(await notifier.addComment('r1', 'x' * 5001, 'u1'), isFalse);
      expect(posts, 0);
    });
  });

  // ── ④ 删评论 ────────────────────────────────────────────────
  group('④ 删评论', () {
    test('成功：本卡移除，其它卡引用不变', () async {
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'GET') {
          return _json([
            _recJson('r1', comments: [_comment('c1', 'r1', 'u1')]),
            _recJson('r2'),
          ]);
        }
        return _json({'ok': true});
      });
      final (container, _) = await _setup(adapter);
      final before = container.read(timelineControllerProvider).posts;
      final otherBefore = before[1];
      await container
          .read(timelineControllerProvider.notifier)
          .deleteComment('r1', 'c1', 'u1');
      final after = container.read(timelineControllerProvider).posts;
      expect(after[0].comments, isEmpty);
      expect(identical(after[1], otherBefore), isTrue);
    });

    test('失败：回滚到点前状态', () async {
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'GET') {
          return _json([
            _recJson('r1', comments: [_comment('c1', 'r1', 'u1')])
          ]);
        }
        return _json({'detail': '评论不存在或不是你发布的'}, 404);
      });
      final (container, _) = await _setup(adapter);
      await container
          .read(timelineControllerProvider.notifier)
          .deleteComment('r1', 'c1', 'u1');
      expect(container
          .read(timelineControllerProvider)
          .posts
          .single
          .comments
          .length, 1);
    });

    test('非本人评论：控制器拒绝删除，不发请求', () async {
      var deletes = 0;
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'GET') {
          return _json([
            _recJson('r1', comments: [_comment('c1', 'r1', 'u2')])
          ]);
        }
        deletes++;
        return _json({'ok': true});
      });
      final (container, _) = await _setup(adapter);
      await container
          .read(timelineControllerProvider.notifier)
          .deleteComment('r1', 'c1', 'u1');
      expect(deletes, 0);
      expect(container
          .read(timelineControllerProvider)
          .posts
          .single
          .comments
          .length, 1);
    });
  });
}
