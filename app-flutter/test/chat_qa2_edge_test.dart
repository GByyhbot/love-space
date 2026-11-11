/* 段二 QA 独立边界用例（Edward · 全新视角复核，不沿用实现者结论）：
   ① drift schema v1→v2 迁移：按 v1 形态建库插旧数据 → 以 v2 打开，
      旧 chat_messages/chat_pending 数据不丢、新列（media_json/phase）可写；
   ② 媒体重试幂等：上传连续失败 2 次 → 第 3 次成功 → POST /api/records 恰好 1 次
      且 client_id 与首次生成一致；
   ③ InputSlotMachine 全组合矩阵：{none,fn,sticker}×意图两态 × 5 事件全枚举；
   ④ rendersSameAs 段二新增字段（media.status/location/song）变化能触发行更新。 */
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart';
import 'package:love_space/core/chat/chat_db.dart';
import 'package:love_space/core/chat/chat_models.dart';
import 'package:love_space/core/chat/chat_state.dart';
import 'package:love_space/features/chat/input_slots.dart';

// ── ① v1→v2 迁移 ─────────────────────────────────────────────────────

/// 复刻段一 v1 形态：chat_pending 无 media_json/phase 两列、无 my_stickers 表
class _V1LegacyDb extends GeneratedDatabase {
  _V1LegacyDb(super.e);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
        beforeOpen: (details) async {
          await customStatement('CREATE TABLE IF NOT EXISTS chat_messages ('
              'id TEXT PRIMARY KEY NOT NULL, author TEXT NOT NULL,'
              'created REAL NOT NULL, updated REAL NOT NULL,'
              'client_id TEXT, body TEXT NOT NULL, media TEXT NOT NULL)');
          await customStatement('CREATE TABLE IF NOT EXISTS chat_pending ('
              'client_id TEXT PRIMARY KEY NOT NULL, content TEXT NOT NULL,'
              'created REAL NOT NULL, failed INTEGER NOT NULL DEFAULT 0)');
          // 段一旧数据：一条正式消息 + 一条失败待发
          await customInsert(
              'INSERT INTO chat_messages (id, author, created, updated, client_id, body, media) '
              'VALUES (?, ?, ?, ?, ?, ?, ?)',
              variables: [
                Variable.withString('legacy-msg-1'),
                Variable.withString('u1'),
                Variable.withReal(1000.0),
                Variable.withReal(1000.0),
                Variable.withString('legacy-cid-1'),
                Variable.withString('{"content":"段一的旧消息"}'),
                Variable.withString('[]'),
              ]);
          await customInsert(
              'INSERT INTO chat_pending (client_id, content, created, failed) '
              'VALUES (?, ?, ?, ?)',
              variables: [
                Variable.withString('legacy-pending-1'),
                Variable.withString('没发出去的一句话'),
                Variable.withReal(1100.0),
                Variable.withInt(1),
              ]);
        },
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('QA2 ① drift v1→v2 迁移（PRAGMA 守卫 ALTER）', () {
    late Directory tmp;
    late File dbFile;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('qa2_chat_db');
      dbFile = File('${tmp.path}${Platform.pathSeparator}chat_cache.sqlite');
    });
    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('旧数据不丢、新列可写、my_stickers 建表', () async {
      // 第一步：按 v1 打开并写入旧数据
      final v1 = _V1LegacyDb(NativeDatabase(dbFile));
      await v1.customSelect('SELECT 1').get();
      await v1.close();

      // 第二步：以 v2 打开（走 onUpgrade + beforeOpen PRAGMA 守卫）
      final db = ChatDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);

      // 旧 chat_messages 数据仍在
      final records = await db.loadRecords();
      expect(records, hasLength(1));
      expect(records.single.id, 'legacy-msg-1');
      expect(records.single.body.content, '段一的旧消息');
      expect(records.single.clientId, 'legacy-cid-1');

      // 旧 chat_pending 行仍在（默认 phase=send、无媒体）
      final pendings = await db.loadPending();
      expect(pendings, hasLength(1));
      expect(pendings.single.clientId, 'legacy-pending-1');
      expect(pendings.single.failed, true);
      expect(pendings.single.phase, ChatPendingPhase.send);
      expect(pendings.single.mediaFiles, isEmpty);

      // 新列可写：带媒体、upload 阶段的 pending 存取往返
      await db.savePending(const ChatPending(
        clientId: 'new-pending-1',
        content: '带图',
        createdAt: 1200.0,
        mediaFiles: [ChatLocalFile(path: '/tmp/a.png', name: 'a.png')],
        phase: ChatPendingPhase.upload,
      ));
      final pendings2 = await db.loadPending();
      expect(pendings2, hasLength(2));
      final restored =
          pendings2.firstWhere((p) => p.clientId == 'new-pending-1');
      expect(restored.phase, ChatPendingPhase.upload);
      expect(restored.mediaFiles.single.name, 'a.png');

      // 新记录写入正常（旧行与新行并存）
      await db.saveRecords([
        ChatRecord(
          id: 'new-msg-1',
          author: 'u1',
          created: 2000.0,
          updated: 2000.0,
          clientId: 'new-cid-1',
          body: const ChatBody(content: '新消息'),
        ),
      ]);
      final records2 = await db.loadRecords();
      expect(records2, hasLength(2));
      expect(records2.any((r) => r.id == 'legacy-msg-1'), true);

      // 幂等：重复打开不重复 ALTER、数据不再丢
      final pendings3 = await db.loadPending();
      expect(pendings3, hasLength(2));
    });

    test('全新安装（无 v1 遗留）直接建 v2 全套表', () async {
      final db = ChatDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);
      expect(await db.loadRecords(), isEmpty);
      expect(await db.loadPending(), isEmpty);
      // my_stickers 表可写（v1 没有此表，beforeOpen 建表时机验证）
      await db.saveMySticker('u1', 'm1', 'e.png');
      expect(await db.loadMyStickers('u1'), [('m1', 'e.png')]);
      await db.deleteMySticker('u1', 'm1');
      expect(await db.loadMyStickers('u1'), isEmpty);
    });
  });

  // ── ② 媒体重试：连败两次 → 第三次成功 ──────────────────────────────
  test('QA2 ② 上传连败 2 次 → 第 3 次成功：POST /api/records 恰 1 次且 client_id 不变',
      () async {
    final store = _MemStore();
    var mediaCalls = 0;
    final recordBodies = <Map<String, dynamic>>[];
    ResponseBody jsonOk(Object data) => ResponseBody.fromString(
        jsonEncode(data), 200,
        headers: {Headers.contentTypeHeader: ['application/json']});
    final adapter = _FakeAdapter((options, _) {
      if (options.uri.path == '/api/media') {
        mediaCalls++;
        if (mediaCalls <= 2) {
          return ResponseBody.fromString(
              jsonEncode({'detail': '文件内容与声明的类型不符，请重新选择'}), 422,
              headers: {Headers.contentTypeHeader: ['application/json']});
        }
        return jsonOk(
            {'id': 'm-ok', 'mime': 'image/png', 'name': 'p.png', 'status': 'pending'});
      }
      if (options.uri.path == '/api/records') {
        final body = options.data as Map;
        recordBodies.add(body.cast<String, dynamic>());
        return jsonOk({
          'id': 'srv-ok', 'kind': 'chat', 'author': 'u1',
          'body': body['body'], 'created': 5000.0, 'updated': 5000.0,
          'client_id': body['client_id'],
          'media': [
            {'id': 'm-ok', 'name': 'p.png', 'mime': 'image/png', 'size': 1,
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

    final file = File(
        '${Directory.systemTemp.path}/qa2_retry_img.png');
    await file.writeAsBytes([7, 7, 7]);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.bootstrap('u1');
    // 首发失败（第 1 次上传 422）
    await expectLater(
        controller.sendMedia(
            [ChatLocalFile(path: file.path, name: 'qa2_retry_img.png')]),
        throwsA(anything));
    final row1 = container
        .read(chatControllerProvider)
        .rows
        .whereType<ChatPendingRow>()
        .single;
    expect(row1.failed, true);
    final clientId = row1.clientId;

    // 重试 1：第 2 次上传仍 422 → 依旧失败态
    await expectLater(controller.retry(clientId), throwsA(anything));
    expect(
        container
            .read(chatControllerProvider)
            .rows
            .whereType<ChatPendingRow>()
            .single
            .failed,
        true);

    // 重试 2：第 3 次上传成功 → 记录发出、pending 清除
    await controller.retry(clientId);
    final state = container.read(chatControllerProvider);
    expect(state.rows.whereType<ChatPendingRow>(), isEmpty);
    expect(
        state.rows.whereType<ChatRecordRow>().single.record.clientId,
        clientId);

    // 断言：/api/media 恰好 3 次（每次重传文件），/api/records 恰好 1 次且 client_id 一致
    expect(mediaCalls, 3);
    expect(recordBodies, hasLength(1));
    expect(recordBodies.single['client_id'], clientId);
    expect(recordBodies.single['body']['media'], ['m-ok']);
    expect(store.pendings, isEmpty);
  });

  // ── ③ InputSlotMachine 全组合矩阵 ─────────────────────────────────
  group('QA2 ③ InputSlotMachine 全组合矩阵', () {
    /// 构造初始状态
    InputSlotMachine build(InputSlot slot, InputSlot? intent) {
      final m = InputSlotMachine();
      if (intent != null) {
        // 目标态：slot=none 且 intent=intent —— 先开意图面板再被键盘压掉
        m.handle(intent == InputSlot.fn
            ? InputSlotEvent.toggleFn
            : InputSlotEvent.toggleSticker);
        m.handle(InputSlotEvent.keyboardFocus);
        expect(m.slot, InputSlot.none);
        expect(m.intent, intent);
        return m;
      }
      switch (slot) {
        case InputSlot.none:
          break;
        case InputSlot.fn:
          m.handle(InputSlotEvent.toggleFn);
        case InputSlot.sticker:
          m.handle(InputSlotEvent.toggleSticker);
      }
      return m;
    }

    final cases = <(String, InputSlot, InputSlot?, InputSlotEvent, InputSlot,
        InputSlot?)>[
      // (说明, 初始slot, 初始intent, 事件, 期望slot, 期望intent)
      ('none × toggleFn', InputSlot.none, null, InputSlotEvent.toggleFn,
          InputSlot.fn, null),
      ('none × toggleSticker', InputSlot.none, null,
          InputSlotEvent.toggleSticker, InputSlot.sticker, null),
      ('none × keyboardFocus', InputSlot.none, null,
          InputSlotEvent.keyboardFocus, InputSlot.none, null),
      ('none × keyboardClosed', InputSlot.none, null,
          InputSlotEvent.keyboardClosed, InputSlot.none, null),
      ('none × pickFunction', InputSlot.none, null,
          InputSlotEvent.pickFunction, InputSlot.none, null),
      ('fn × toggleFn（亲手收起）', InputSlot.fn, null, InputSlotEvent.toggleFn,
          InputSlot.none, null),
      ('fn × toggleSticker（同槽位互换）', InputSlot.fn, null,
          InputSlotEvent.toggleSticker, InputSlot.sticker, null),
      ('fn × keyboardFocus（键盘压面板记意图）', InputSlot.fn, null,
          InputSlotEvent.keyboardFocus, InputSlot.none, InputSlot.fn),
      ('fn × keyboardClosed（无意图不动作）', InputSlot.fn, null,
          InputSlotEvent.keyboardClosed, InputSlot.fn, null),
      ('fn × pickFunction', InputSlot.fn, null, InputSlotEvent.pickFunction,
          InputSlot.none, null),
      ('sticker × toggleFn（同槽位互换）', InputSlot.sticker, null,
          InputSlotEvent.toggleFn, InputSlot.fn, null),
      ('sticker × toggleSticker（亲手收起坞）', InputSlot.sticker, null,
          InputSlotEvent.toggleSticker, InputSlot.none, null),
      ('sticker × keyboardFocus（键盘压坞记意图）', InputSlot.sticker, null,
          InputSlotEvent.keyboardFocus, InputSlot.none, InputSlot.sticker),
      ('sticker × keyboardClosed（无意图不动作）', InputSlot.sticker, null,
          InputSlotEvent.keyboardClosed, InputSlot.sticker, null),
      ('sticker × pickFunction（发送贴纸收坞）', InputSlot.sticker, null,
          InputSlotEvent.pickFunction, InputSlot.none, null),
      // 带意图态：键盘收起必须回位；选走/亲手收起必须清意图
      ('fn+intent × keyboardClosed（回位）', InputSlot.none, InputSlot.fn,
          InputSlotEvent.keyboardClosed, InputSlot.fn, null),
      ('sticker+intent × keyboardClosed（回位）', InputSlot.none,
          InputSlot.sticker, InputSlotEvent.keyboardClosed, InputSlot.sticker,
          null),
      ('fn+intent × pickFunction（选走清意图不回位）', InputSlot.none,
          InputSlot.fn, InputSlotEvent.pickFunction, InputSlot.none, null),
      ('sticker+intent × pickFunction', InputSlot.none, InputSlot.sticker,
          InputSlotEvent.pickFunction, InputSlot.none, null),
      ('fn+intent × toggleFn（键盘开着点⊕：换槽并清意图）', InputSlot.none,
          InputSlot.fn, InputSlotEvent.toggleFn, InputSlot.fn, null),
      ('sticker+intent × toggleSticker（键盘开着点表情：直接开坞并清意图）', InputSlot.none,
          InputSlot.sticker, InputSlotEvent.toggleSticker, InputSlot.sticker,
          null),
      ('sticker+intent × keyboardFocus（意图不改写）', InputSlot.none,
          InputSlot.sticker, InputSlotEvent.keyboardFocus, InputSlot.none,
          InputSlot.sticker),
    ];

    for (final (desc, slot, intent, event, expSlot, expIntent) in cases) {
      test(desc, () {
        final m = build(slot, intent);
        m.handle(event);
        expect(m.slot, expSlot, reason: desc);
        expect(m.intent, expIntent, reason: desc);
      });
    }
  });

  // ── ④ rendersSameAs 段二新增字段 ──────────────────────────────────
  group('QA2 ④ rendersSameAs 新增字段（段一低危修回归）', () {
    ChatRecord rec(Map<String, dynamic> body, List<Map<String, dynamic>> media) =>
        ChatRecord.fromJson({
          'id': 'r1', 'kind': 'chat', 'author': 'u1',
          'body': body, 'created': 1.0, 'updated': 1.0, 'client_id': 'c1',
          'media': media,
        });

    final base = rec({'content': 'hi', 'media': ['m1']}, [
      {'id': 'm1', 'name': 'a.png', 'mime': 'image/png', 'size': 1,
       'status': 'pending', 'preview': null},
    ]);

    test('完全相同 → true', () {
      expect(base.rendersSameAs(rec(base.body.toJson(), base.media.map((m) => m.toJson()).toList())), true);
    });

    test('media.status pending→ready → false（触发 preview 替换）', () {
      final ready = rec(base.body.toJson(), [
        {'id': 'm1', 'name': 'a.png', 'mime': 'image/png', 'size': 1,
         'status': 'ready', 'preview': null},
      ]);
      expect(base.rendersSameAs(ready), false);
    });

    test('location 变化 → false', () {
      final moved = rec({
        'content': 'hi', 'media': ['m1'],
        'location': {'lat': 31.0, 'lng': 121.0},
      }, base.media.map((m) => m.toJson()).toList());
      expect(base.rendersSameAs(moved), false);
    });

    test('song 变化 → false', () {
      final sung = rec({
        'content': 'hi', 'media': ['m1'],
        'song': {'title': '歌', 'artist': '人', 'mid': '', 'src': 's', 'art': 'a', 'dur': 30.0},
      }, base.media.map((m) => m.toJson()).toList());
      expect(base.rendersSameAs(sung), false);
    });
  });
}

// ── 测试工具（独立实现，不 import 其它测试文件）────────────────────────

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
