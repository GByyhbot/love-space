/* QA3 独立边界用例（全新视角，不复用实现者断言口径）：
   A. 撤回矩阵全组合（本人/对方 × 窗口内/外/边界/已撤回/时钟漂移=服务端略超前）
   B. 背景 payload 不动 name/since：全字段 spaceRaw → apply → 除 chat_bg* 四键外逐键不变
   C. 引用 60 字截断边界：59/60/61 字 + emoji（UTF-16 码元口径与 JS slice 对齐）
   D. 置顶栏「N 条置顶」：数据（latest=created 最大者 + total）与跳转目标 id 一致
   E. drift v2→v3 升版：v2 形态建库（无 media_ids 列）→ v3 打开不抛、旧数据在、列已补
   F. 补充：ChatPendingRow.withFailed 不丢 mediaIds（E1 专项回归）；
      amapWebUrl 的 position=lng,lat 顺序（高德网页地图契约） */
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart'
    show GeneratedDatabase, MigrationStrategy, TableInfo;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/chat/chat_db.dart';
import 'package:love_space/core/chat/chat_models.dart';
import 'package:love_space/core/chat/chat_state.dart';
import 'package:love_space/core/chat/chat_wallpaper.dart';
import 'package:love_space/core/chat/map_launcher.dart';

ChatRecord rec(Map<String, dynamic> body,
        {String id = 'r1', String author = 'u1', double created = 1000.0}) =>
    ChatRecord.fromJson({
      'id': id,
      'kind': 'chat',
      'author': author,
      'body': body,
      'created': created,
      'updated': created,
      'client_id': '',
      'media': [],
    });

/// v2 形态数据库（段二落库形态：chat_pending 无 media_ids 列，user_version=2）
class _V2Db extends GeneratedDatabase {
  _V2Db(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  Iterable<TableInfo> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(onCreate: (m) async {
        await customStatement('''
          CREATE TABLE chat_messages (
            id TEXT PRIMARY KEY NOT NULL, author TEXT NOT NULL,
            created REAL NOT NULL, updated REAL NOT NULL, client_id TEXT,
            body TEXT NOT NULL, media TEXT NOT NULL)''');
        await customStatement('''
          CREATE TABLE chat_pending (
            client_id TEXT PRIMARY KEY NOT NULL, content TEXT NOT NULL,
            created REAL NOT NULL, failed INTEGER NOT NULL DEFAULT 0,
            media_json TEXT NOT NULL DEFAULT '[]',
            phase TEXT NOT NULL DEFAULT 'send')''');
        await customStatement('''
          CREATE TABLE my_stickers (
            mid TEXT NOT NULL, user_id TEXT NOT NULL,
            name TEXT NOT NULL DEFAULT '', created REAL NOT NULL,
            PRIMARY KEY (user_id, mid))''');
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── A. 撤回矩阵全组合 ────────────────────────────────────────────────
  group('A. canRecallChat 全组合（本人/对方 × 窗口/已撤回/时钟漂移）', () {
    DateTime now() => DateTime(2026, 11, 11, 12, 0, 0);
    double at(int secondsAgo) =>
        now().subtract(Duration(seconds: secondsAgo)).millisecondsSinceEpoch /
        1000;

    test('本人 × 窗口内（0s/119s/120s）→ true（120s 边界与服务端 >120 拒绝对齐）', () {
      for (final s in [0, 119, 120]) {
        expect(
            canRecallChat(
                rec({'content': 'hi'}, created: at(s)), 'u1', now: now),
            true,
            reason: '$s 秒前应可撤回');
      }
    });

    test('本人 × 窗口外（121s/1h）→ false', () {
      expect(
          canRecallChat(rec({'content': 'hi'}, created: at(121)), 'u1',
              now: now),
          false);
      expect(
          canRecallChat(rec({'content': 'hi'}, created: at(3600)), 'u1',
              now: now),
          false);
    });

    test('对方 × 窗口内/外 → false（窗口内外都不出撤回项）', () {
      expect(
          canRecallChat(
              rec({'content': 'hi'}, author: 'u2', created: at(10)), 'u1',
              now: now),
          false);
      expect(
          canRecallChat(
              rec({'content': 'hi'}, author: 'u2', created: at(3600)), 'u1',
              now: now),
          false);
    });

    test('已撤回 × 本人 × 窗口内 → false（不再重复撤回）', () {
      expect(
          canRecallChat(rec({'recalled': true}, created: at(10)), 'u1',
              now: now),
          false);
    });

    test('时钟漂移：服务端略超前（created 在本地未来 30s）→ 仍可撤回（负差值不误判超窗）', () {
      final future = now().add(const Duration(seconds: 30));
      final r =
          rec({'content': 'hi'}, created: future.millisecondsSinceEpoch / 1000);
      expect(canRecallChat(r, 'u1', now: now), true);
    });
  });

  // ── B. 背景 payload 全字段不动 name/since ────────────────────────────
  group('B. applyChatBgPayload：全字段 spaceRaw 只改 chat_bg* 四键', () {
    test('构造 me.space 全字段 → apply → 除四键外逐键深度相等', () {
      final spaceRaw = <String, dynamic>{
        'name': '我们的小家',
        'since': '2020-01-01',
        'mood': {'emoji': '😊', 'content': '今天也要加油', 'date': '2026-11-11'},
        'cover': 'media-cover-id',
        'anniversary': [
          {'title': '领证', 'date': '2021-05-20'}
        ],
        'chat_unread': 3,
        'chat_bubble': 'p1/a.png',
        'chat_bubble_fg': 'light',
        'chat_bubble_swap': false,
        'chat_bg': 'mint',
        'chat_bg_media': '',
        'chat_bg_dim': 20,
        'chat_bg_users': {
          'u1': {'bg': 'sakura', 'media': '', 'dim': 20},
          'u2': {'bg': 'photo', 'media': 'm8', 'dim': 50},
        },
        'daily': {'quote': '早安'},
      };
      final before = jsonEncode(spaceRaw);
      final (payload, err) = applyChatBgPayload(spaceRaw,
          target: 'u2', bg: 'night', media: '', dim: 65);
      expect(err, isNull);
      // 除 chat_bg_target/chat_bg/chat_bg_media/chat_bg_dim 外全部原样
      final expected = jsonDecode(before) as Map<String, dynamic>;
      for (final k in expected.keys) {
        if (k == 'chat_bg' || k == 'chat_bg_media' || k == 'chat_bg_dim') {
          continue;
        }
        expect(jsonEncode(payload![k]), jsonEncode(expected[k]),
            reason: '键 $k 不应被背景保存改动');
      }
      expect(payload!['chat_bg'], 'night');
      expect(payload['chat_bg_media'], '');
      expect(payload['chat_bg_dim'], 65);
      expect(payload['chat_bg_target'], 'u2');
      // 皮肤三键也原样保留（背景保存不得顺手改皮肤）
      expect(payload['chat_bubble'], 'p1/a.png');
      expect(payload['chat_bubble_fg'], 'light');
      expect(payload['chat_bubble_swap'], false);
      // dim 边界 clamp 0–80
      final (p2, _) = applyChatBgPayload(spaceRaw,
          target: 'u1', bg: 'mint', media: '', dim: 95);
      expect(p2!['chat_bg_dim'], 80);
      final (p3, _) = applyChatBgPayload(spaceRaw,
          target: 'u1', bg: 'mint', media: '', dim: -5);
      expect(p3!['chat_bg_dim'], 0);
    });
  });

  // ── C. 引用 60 字截断边界（含 emoji）─────────────────────────────────
  group('C. quoteSnippet 60 字边界（UTF-16 码元口径）', () {
    test('59/60/61 个中文字', () {
      expect(quoteSnippet('中' * 59), '中' * 59);
      expect(quoteSnippet('中' * 60), '中' * 60);
      expect(quoteSnippet('中' * 61), '${'中' * 60}…');
    });

    test('emoji（2 码元）：60 码元整 emoji 不截；62 码元截到码元 60 落在完整字符边界', () {
      final smile = '😊'; // 2 UTF-16 code units
      expect(quoteSnippet(smile * 30), smile * 30); // 60 units 原样
      final cut = quoteSnippet(smile * 31); // 62 units → 60 units + …
      expect(cut.length, 61); // 30 emoji(60) + …
      expect(cut.endsWith('…'), true);
      expect(cut.startsWith(smile * 30), true);
      // 码元 58/59 必须构成合法代理对（高+低），没有孤立代理
      expect(cut.codeUnitAt(58), inInclusiveRange(0xD800, 0xDBFF));
      expect(cut.codeUnitAt(59), inInclusiveRange(0xDC00, 0xDFFF));
    });

    test('emoji 与 JS slice 同口径：截断落在代理对中间时按码元硬切（不抛异常）', () {
      // 59 个 ASCII + 1 个 emoji = 61 units → slice(0,60) 会切进代理对
      final s = '${'x' * 59}😊';
      final cut = quoteSnippet(s);
      expect(cut.length, 61); // 59 x + 孤立高代理位 + …
      expect(cut.startsWith('x' * 59), true);
      expect(cut.endsWith('…'), true);
      expect(cut.codeUnitAt(59), inInclusiveRange(0xD800, 0xDBFF));
    });

    test('首尾空白 trim 后再计数', () {
      expect(quoteSnippet('  ${'中' * 61}  '), '${'中' * 60}…');
    });
  });

  // ── D. 置顶栏「N 条置顶」数据与跳转目标 ──────────────────────────────
  group('D. pinnedBarInfo：N 条置顶 + 跳转目标=created 最大者', () {
    test('3 条置顶：total=3，latest=created 最大那条的 id', () {
      final info = pinnedBarInfo([
        rec({'content': '甲', 'pinned': true}, id: 'a', created: 100),
        rec({'content': '乙', 'pinned': true}, id: 'b', created: 300),
        rec({'content': '丙', 'pinned': true}, id: 'c', created: 200),
        rec({'content': '未置顶'}, id: 'd', created: 999),
      ]);
      expect(info, isNotNull);
      expect(info!.total, 3);
      expect(info.latest.id, 'b'); // 跳转目标必须是最新置顶
      expect(pinnedBarText(info.latest), '乙');
    });

    test('撤回的置顶不占位也不进总数', () {
      final info = pinnedBarInfo([
        rec({'content': '活的', 'pinned': true}, id: 'a', created: 100),
        rec({'content': '没了', 'pinned': true, 'recalled': true},
            id: 'b', created: 300),
      ]);
      expect(info!.total, 1);
      expect(info.latest.id, 'a');
    });
  });

  // ── E. drift v2→v3 升版 ─────────────────────────────────────────────
  group('E. chat_pending v2→v3 幂等迁移', () {
    test('v2 形态建库（无 media_ids）→ v3 打开：不抛、旧数据在、media_ids 列已补', () async {
      final dir = await Directory.systemTemp.createTemp('qa3_drift');
      final f = File('${dir.path}${Platform.pathSeparator}chat_cache.sqlite');
      final v2 = _V2Db(NativeDatabase(f));
      // 建库并落旧数据（触发 onCreate + user_version=2 落盘）
      await v2.customStatement(
          "INSERT INTO chat_messages VALUES ('r1','u1',5.0,5.0,'',"
          "'{\"content\":\"v2的旧消息\",\"media\":[]}', '[]')");
      await v2.customStatement(
          "INSERT INTO chat_pending VALUES ('c1','v2的待发',1.0,1,'[]','send')");
      await v2.close();

      final db = ChatDatabase(NativeDatabase(f));
      // 升版打开：任何抛出都会让用例失败
      final pending = await db.loadPending();
      final records = await db.loadRecords();
      expect(pending, hasLength(1));
      expect(pending.single.clientId, 'c1');
      expect(pending.single.content, 'v2的待发');
      expect(pending.single.phase, ChatPendingPhase.send); // 'send' 原样解析
      expect(pending.single.mediaIds, isEmpty); // 新列默认空
      expect(records, hasLength(1));
      expect(records.single.body.content, 'v2的旧消息');
      // media_ids 列已补上且可写（幂等迁移生效）
      final cols = await db
          .customSelect('PRAGMA table_info(chat_pending)')
          .get()
          .then((rows) => rows.map((r) => r.data['name']).toList());
      expect(cols.contains('media_ids'), true);
      await db.customStatement(
          "UPDATE chat_pending SET media_ids='[\"m1\"]' WHERE client_id='c1'");
      final again = await db.loadPending();
      expect(again.single.mediaIds, ['m1']);
      await db.close();
      await dir.delete(recursive: true);
    });
  });

  // ── F. 补充回归 ─────────────────────────────────────────────────────
  group('F. E1 回归 + 高德 URL 契约', () {
    test('withFailed 不丢 mediaIds（POST 失败标记后重试仍零重传的数据前提）', () {
      const row = ChatPendingRow(
        clientId: 'c1',
        content: 'hi',
        mediaFiles: [ChatLocalFile(path: '/tmp/a.png', name: 'a.png')],
        phase: ChatPendingPhase.send,
        mediaIds: ['m1', 'm2'],
      );
      final failed = row.withFailed(true);
      expect(failed.mediaIds, ['m1', 'm2']);
      expect(failed.phase, ChatPendingPhase.send); // 不重置回 upload
      expect(row.withPhase(ChatPendingPhase.send).mediaIds, ['m1', 'm2']);
      expect(row.withProgress(0.5).mediaIds, ['m1', 'm2']);
    });

    test('amapWebUrl：position=lng,lat（高德网页地图契约经纬顺序）', () {
      final url = amapWebUrl(31.23456, 121.45678, '我们的位置');
      expect(url.scheme, 'https');
      expect(url.host, 'uri.amap.com');
      expect(url.path, '/marker');
      expect(url.queryParameters['position'], '121.45678,31.23456');
      expect(url.queryParameters['callnative'], '1');
      expect(url.queryParameters['coordinate'], 'gaode');
      final app = amapAppUrl(31.23456, 121.45678, '我们的位置');
      expect(app.scheme, 'androidamap');
      expect(app.queryParameters['lat'], '31.23456');
      expect(app.queryParameters['lon'], '121.45678');
    });
  });
}
