/* 段三单测（Step 7–9 + 低危备忘 E1/E3）：
   ① 撤回窗口显隐矩阵（本人/对方 × 窗口内/外/已撤回）
   ② phase 分流重试：send 相位零重传（POST 段失败后重试不再打 /api/media）
   ③ mime 大小写矩阵（fromJson 归一小写后判定）
   ④ 置顶 toggle（本地原地更新）+ 置顶栏数据（pinnedBarInfo/pinnedBarText）
   ⑤ 引用 reply_to 截 60 字（quoteSnippet + sendTextReply 请求体）
   ⑥ 背景 chat_bg_users 目标选择 payload（applyChatBgPayload：四键覆盖、其余键原样）
   ⑦ 皮肤分批加载参数（nextBubbleVisible：90/批、封顶、续载） */
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart';
import 'package:love_space/core/chat/chat_bubbles.dart';
import 'package:love_space/core/chat/chat_models.dart';
import 'package:love_space/core/chat/chat_state.dart';
import 'package:love_space/core/chat/chat_wallpaper.dart';

ChatRecord rec(Map<String, dynamic> body,
        {String id = 'r1', String author = 'u1', double created = 1000.0}) =>
    ChatRecord.fromJson({
      'id': id, 'kind': 'chat', 'author': author,
      'body': body, 'created': created, 'updated': created,
      'client_id': '', 'media': [],
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // ── ①③④⑤⑥⑦ 纯函数与链路矩阵 ──
  // ── ① 撤回窗口显隐矩阵 ─────────────────────────────────────────────
  group('① canRecallChat 撤回窗口矩阵', () {
    DateTime now() => DateTime(2026, 11, 11, 12, 0, 0);
    double at(int secondsAgo) =>
        now().subtract(Duration(seconds: secondsAgo)).millisecondsSinceEpoch / 1000;

    test('本人 + 窗口内（≤120s）→ 可撤回', () {
      expect(canRecallChat(rec({'content': 'hi'}, created: at(60)), 'u1', now: now), true);
      expect(canRecallChat(rec({'content': 'hi'}, created: at(120)), 'u1', now: now), true);
    });

    test('本人 + 超窗（>120s）→ 不可撤回', () {
      expect(canRecallChat(rec({'content': 'hi'}, created: at(121)), 'u1', now: now), false);
    });

    test('对方消息 → 不可撤回（窗口内也不行）', () {
      expect(canRecallChat(rec({'content': 'hi'}, author: 'u2', created: at(10)), 'u1', now: now), false);
    });

    test('已撤回 → 不再显示撤回项', () {
      expect(
          canRecallChat(rec({'content': '', 'recalled': true}, created: at(10)), 'u1', now: now),
          false);
    });
  });

  // ── ③ mime 大小写矩阵 ─────────────────────────────────────────────
  group('③ mime 大小写归一（E3）', () {
    ChatRecord withMedia(String mime) => ChatRecord.fromJson({
          'id': 'm1', 'kind': 'chat', 'author': 'u1',
          'body': {'content': '', 'media': ['x']},
          'created': 1.0, 'updated': 1.0, 'client_id': '', 'media': [
            {'id': 'x', 'name': 'f', 'mime': mime, 'size': 1, 'status': 'ready', 'preview': null},
          ],
        });

    test('大写 mime 归一：IMAGE/PNG → 图片占位', () {
      final v = chatVisualOf(withMedia('IMAGE/PNG'));
      expect(v.imageMids, ['x']);
    });

    test('大写 webp 自定义表情仍贴纸化：Image/WEBP', () {
      final v = chatVisualOf(withMedia('Image/WEBP'));
      expect(v.sticker, isNotNull);
      expect(v.sticker!.isVideo, false);
    });

    test('大写 webm 自定义表情 → 贴纸视频：VIDEO/WEBM', () {
      final v = chatVisualOf(withMedia('VIDEO/WEBM'));
      expect(v.sticker!.isVideo, true);
    });

    test('占位标签小写化：Audio/M4A → [语音]', () {
      expect(withMedia('Audio/M4A').media.first.placeholderLabel, '[语音]');
    });
  });

  // ── ④ 置顶栏数据 ─────────────────────────────────────────────────
  group('④ 置顶栏数据（pinnedBarInfo/pinnedBarText）', () {
    test('无置顶 → null', () {
      expect(pinnedBarInfo([rec({'content': 'a'}), rec({'content': 'b'}, id: 'r2')]), isNull);
    });

    test('取最新一条 + 总数；已撤回的不算', () {
      final info = pinnedBarInfo([
        rec({'content': '旧置顶', 'pinned': true}, id: 'old', created: 100),
        rec({'content': '新置顶', 'pinned': true}, id: 'new', created: 200),
        rec({'content': '撤回的置顶', 'pinned': true, 'recalled': true}, id: 'recalled', created: 300),
      ]);
      expect(info!.total, 2);
      expect(info.latest.id, 'new');
    });

    test('摘要 slice 42（码元口径）；空内容显「一条附件」', () {
      expect(pinnedBarText(rec({'content': 'x' * 50})), '${'x' * 42}…');
      expect(pinnedBarText(rec({'content': '短'})), '短');
      expect(pinnedBarText(rec({'content': '', 'media': ['m']})), '一条附件');
    });
  });

  // ── ⑤ 引用截 60 字 ───────────────────────────────────────────────
  group('⑤ quoteSnippet reply_to 截 60 字', () {
    test('≤60 原样；>60 截断加省略号；空文本回退「原消息」', () {
      expect(quoteSnippet('短消息'), '短消息');
      expect(quoteSnippet('x' * 60), 'x' * 60);
      expect(quoteSnippet('y' * 61), '${'y' * 60}…');
      expect(quoteSnippet('   '), '原消息');
    });

    test('sendTextReply：请求体 reply_to.text 已截 60 字', () async {
      final store = _MemStore();
      final recordBodies = <Map<String, dynamic>>[];
      final adapter = _FakeAdapter((options, _) {
        if (options.uri.path == '/api/records') {
          final body = options.data as Map;
          recordBodies.add(body.cast<String, dynamic>());
          return ResponseBody.fromString(
              jsonEncode({
                'id': 'srv-q', 'kind': 'chat', 'author': 'u1',
                'body': body['body'], 'created': 9.0, 'updated': 9.0,
                'client_id': body['client_id'], 'media': [],
              }),
              200,
              headers: {Headers.contentTypeHeader: ['application/json']});
        }
        return ResponseBody.fromString(jsonEncode(const []), 200,
            headers: {Headers.contentTypeHeader: ['application/json']});
      });
      final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
        ..httpClientAdapter = adapter;
      final container = ProviderContainer(overrides: [
        dioProvider.overrideWith((ref) async => dio),
        chatPersistenceProvider.overrideWith((ref) async => store),
      ]);
      addTearDown(container.dispose);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.bootstrap('u1');
      await controller.sendTextReply('收到！', 'target-id', 'z' * 100);

      final body = recordBodies.single['body'] as Map;
      expect(body['reply_to']['id'], 'target-id');
      expect(body['reply_to']['text'], '${'z' * 60}…');
    });
  });

  // ── ⑥ 背景 chat_bg_users 目标选择 payload ─────────────────────────
  group('⑥ applyChatBgPayload（每人一份 + 全量覆盖）', () {
    final spaceRaw = <String, dynamic>{
      'name': '我们的小家',
      'since': '2020-01-01',
      'chat_bg_users': {
        'u1': {'bg': 'sakura', 'media': '', 'dim': 20},
      },
    };

    test('设给自己：覆盖 chat_bg* 四键 + 保留 name/since 与他人的那份', () {
      final (payload, err) = applyChatBgPayload(spaceRaw,
          target: 'u1', bg: 'night', media: '', dim: 60);
      expect(err, isNull);
      expect(payload!['chat_bg_target'], 'u1');
      expect(payload['chat_bg'], 'night');
      expect(payload['chat_bg_media'], '');
      expect(payload['chat_bg_dim'], 60);
      expect(payload['name'], '我们的小家');
      expect(payload['since'], '2020-01-01');
      expect((payload['chat_bg_users'] as Map)['u1']['bg'], 'sakura'); // 原样保留
    });

    test('设给对方：target 指向对方 uid，其余键原样带回（全量覆盖语义）', () {
      final (payload, err) = applyChatBgPayload(spaceRaw,
          target: 'u2', bg: 'photo', media: 'm9', dim: 40);
      expect(err, isNull);
      expect(payload!['chat_bg_target'], 'u2');
      expect(payload['chat_bg_media'], 'm9');
    });

    test('photo 未选图 → 本地拦截（不发请求）', () {
      final (payload, err) = applyChatBgPayload(spaceRaw,
          target: 'u1', bg: 'photo', media: '', dim: 35);
      expect(payload, isNull);
      expect(err, isNotNull);
    });

    test('chatBgOf：本人那份优先，否则退回空间级默认', () {
      final wp = chatBgOf(spaceRaw, 'u1');
      expect(wp.bg, 'sakura');
      final fallback = chatBgOf({
        ...spaceRaw,
        'chat_bg': 'mint',
        'chat_bg_media': '',
        'chat_bg_dim': 50,
      }, 'u2');
      expect(fallback.bg, 'mint');
      expect(fallback.dim, 50);
    });
  });

  // ── ⑦ 皮肤分批加载参数 ───────────────────────────────────────────
  group('⑦ nextBubbleVisible 分批（BP_PAGE=90）', () {
    test('首批 90', () {
      expect(nextBubbleVisible(2000, 0), 90);
      expect(nextBubbleVisible(50, 0), 50); // 不足一批封顶
    });

    test('滚动到底续载 +90，封顶 total', () {
      expect(nextBubbleVisible(2000, 90), 180);
      expect(nextBubbleVisible(2000, 1980), 2000);
      expect(nextBubbleVisible(2000, 2000), 2000); // 已到底不再增长
    });

    test('ChatSkin 左右图与 swap', () {
      const skin = ChatSkin(skin: 'p1/abc.png', fg: 'dark', swap: false);
      expect(skin.leftRightUrls, ('p1/abc.png', 'p1/abc-r.png'));
      const swapped = ChatSkin(skin: 'p1/abc.png', fg: 'light', swap: true);
      expect(swapped.leftRightUrls, ('p1/abc-r.png', 'p1/abc.png'));
      expect(applyChatSkinPayload({'name': 'n'}, skin: '', fg: 'dark', swap: true),
          {'name': 'n', 'chat_bubble': '', 'chat_bubble_fg': 'dark', 'chat_bubble_swap': true});
    });
  });

  // ── ② phase 分流重试（send 相位零重传）+ 置顶 toggle 控制器链路 ────

  test('② phase 分流：POST 段失败落盘 send 相位，重试零重传', () async {
    final store = _MemStore();
    var mediaCalls = 0;
    var postFailed = true;
    final recordPosts = <Map<String, dynamic>>[];
    final adapter = _FakeAdapter((options, callIndex) {
      if (options.uri.path == '/api/media') {
        mediaCalls++;
        return jsonOk({'id': 'm-1', 'mime': 'image/png', 'name': 'p.png', 'status': 'pending'});
      }
      if (options.uri.path == '/api/records') {
        final body = options.data as Map;
        if (postFailed) {
          postFailed = false;
          return ResponseBody.fromString(
              jsonEncode({'detail': '网络开小差了'}), 422,
              headers: {Headers.contentTypeHeader: ['application/json']});
        }
        recordPosts.add(body.cast<String, dynamic>());
        return jsonOk({
          'id': 'srv-p', 'kind': 'chat', 'author': 'u1',
          'body': body['body'], 'created': 10.0, 'updated': 10.0,
          'client_id': body['client_id'],
          'media': [
            {'id': 'm-1', 'name': 'p.png', 'mime': 'image/png', 'size': 1,
             'status': 'ready', 'preview': null},
          ],
        });
      }
      return jsonOk(const []);
    });
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final container = ProviderContainer(overrides: [
      dioProvider.overrideWith((ref) async => dio),
      chatPersistenceProvider.overrideWith((ref) async => store),
    ]);
    addTearDown(container.dispose);
    final file = File('${Directory.systemTemp.path}/seg3_phase.png');
    await file.writeAsBytes([1, 2, 3]);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.bootstrap('u1');
    // 上传成功、POST 失败 → pending 保持 send 相位且已带 media_ids
    await expectLater(
        controller.sendMedia([ChatLocalFile(path: file.path, name: 'seg3_phase.png')]),
        throwsA(anything));
    final row = container
        .read(chatControllerProvider)
        .rows
        .whereType<ChatPendingRow>()
        .single;
    expect(row.phase, ChatPendingPhase.send);
    expect(row.mediaIds, ['m-1']);
    expect(store.pendings.values.single.phase, ChatPendingPhase.send);
    expect(store.pendings.values.single.mediaIds, ['m-1']);
    final mediaCallsBefore = mediaCalls;

    // 重试：直接 POST 记录（零重传）
    await controller.retry(row.clientId);
    expect(mediaCalls, mediaCallsBefore); // E1：send 相位零重传
    expect(recordPosts, hasLength(1));
    expect(recordPosts.single['client_id'], row.clientId);
    expect((recordPosts.single['body'] as Map)['media'], ['m-1']);
    expect(container.read(chatControllerProvider).rows.whereType<ChatPendingRow>(),
        isEmpty);
  });

  test('④b pinMessage：POST pin 后本地原地更新 body.pinned', () async {
    final store = _MemStore();
    var pinned = false;
    final adapter = _FakeAdapter((options, _) {
      if (options.uri.path == '/api/records/r1/pin') {
        pinned = !pinned;
        return jsonOk({'ok': true, 'pinned': pinned});
      }
      return jsonOk([{
        'id': 'r1', 'kind': 'chat', 'author': 'u1',
        'body': {'content': '被置顶的那条'}, 'created': 5.0, 'updated': 5.0,
        'client_id': '', 'media': [],
      }]);
    });
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final container = ProviderContainer(overrides: [
      dioProvider.overrideWith((ref) async => dio),
      chatPersistenceProvider.overrideWith((ref) async => store),
    ]);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.bootstrap('u1'); // 对账拉回 r1

    await controller.pinMessage('r1');
    var row = container
        .read(chatControllerProvider)
        .rows
        .whereType<ChatRecordRow>()
        .single;
    expect(row.record.body.pinned, true);
    expect(pinnedBarInfo([row.record])!.latest.id, 'r1'); // 置顶栏出现

    await controller.pinMessage('r1'); // 取消置顶
    row = container.read(chatControllerProvider).rows.whereType<ChatRecordRow>().single;
    expect(row.record.body.pinned, false);
    expect(pinnedBarInfo([row.record]), isNull);
  });

  test('④c recallMessage：本地行变撤回态（recalled=true 且内容清空）', () async {
    final store = _MemStore();
    final adapter = _FakeAdapter((options, _) {
      if (options.uri.path == '/api/records/r9/recall') {
        return jsonOk({'ok': true});
      }
      return jsonOk([{
        'id': 'r9', 'kind': 'chat', 'author': 'u1',
        'body': {'content': '要撤回的话'}, 'created': 5.0, 'updated': 5.0,
        'client_id': '', 'media': [],
      }]);
    });
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final container = ProviderContainer(overrides: [
      dioProvider.overrideWith((ref) async => dio),
      chatPersistenceProvider.overrideWith((ref) async => store),
    ]);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.bootstrap('u1');
    await controller.recallMessage('r9');
    final row = container
        .read(chatControllerProvider)
        .rows
        .whereType<ChatRecordRow>()
        .single;
    expect(row.record.body.recalled, true);
    expect(row.record.body.content, '');
  });
}

// ── 测试工具（独立实现，不 import 其它测试文件）────────────────────────

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
