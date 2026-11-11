/// 聊天本地缓存（drift · 手写 SQL 模式）。
///
/// 为什么不用 drift 代码生成：本条目红线「新依赖只加 uuid」，不能引入
/// build_runner / drift_dev。这里把 drift 当薄 SQLite 封装用（drift 2.35）：
/// · GeneratedDatabase.allTables 覆写为空 → 走默认迁移不生成任何表；
/// · 表结构在 beforeOpen 用原生 CREATE TABLE IF NOT EXISTS 创建（幂等）；
/// · 列演进也在 beforeOpen 做（PRAGMA table_info 检查后 ALTER TABLE），
///   schemaVersion 只作版本标记，不依赖 Migrator；
/// · 读写走 customSelect / customInsert / customStatement，行映射手写。
/// 查询面很窄（按 created 时间窗 + 主键 UPSERT），用不到生成器的类型安全
/// 查询与 watch 流；真机上的 sqlite3 native assets 预编译库照常生效。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'chat_models.dart';

/// 缓存窗口：只留最近 500 条，超出自动裁剪（冷启动先显缓存再同步）
const int chatCacheWindow = 500;

/// 「我的表情包」上限（对齐 Web setStickers slice(0,100)）
const int myStickerLimit = 100;

class ChatDatabase extends GeneratedDatabase {
  ChatDatabase(super.executor);

  /// 正常打开：应用文档目录下的独立缓存库
  ChatDatabase.open() : this(_openExecutor());

  static QueryExecutor _openExecutor() {
    return LazyDatabase(() async {
      final dir = await getApplicationDocumentsDirectory();
      final file =
          File('${dir.path}${Platform.pathSeparator}chat_cache.sqlite');
      return NativeDatabase.createInBackground(file);
    });
  }

  @override
  int get schemaVersion => 2;

  @override
  Iterable<TableInfo> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
        // 列演进全部由 beforeOpen 的 PRAGMA 守卫 ALTER 完成（幂等），这里保持
        // no-op——但必须显式提供：drift 对升版打开若没有 onUpgrade 会直接抛
        // 「didn't provide a migration strategy」，beforeOpen 根本执行不到，
        // v1→v2 升版打开会永久失败（QA2① 回归根因）。
        onUpgrade: (m, from, to) async {},
        beforeOpen: (details) async {
          await customStatement(_createChatMessages);
          await customStatement(_createChatPending);
          await customStatement(_createMyStickers);
          // 段一 v1 → 段二 v2：chat_pending 加媒体两列（幂等检查后 ALTER）
          final cols = await customSelect('PRAGMA table_info(chat_pending)')
              .get();
          final names =
              cols.map((row) => row.data['name']?.toString() ?? '').toSet();
          if (!names.contains('media_json')) {
            await customStatement(
                "ALTER TABLE chat_pending ADD COLUMN media_json TEXT NOT NULL DEFAULT '[]'");
          }
          if (!names.contains('phase')) {
            await customStatement(
                "ALTER TABLE chat_pending ADD COLUMN phase TEXT NOT NULL DEFAULT 'send'");
          }
        },
      );

  static const String _createChatMessages = '''
    CREATE TABLE IF NOT EXISTS chat_messages (
      id TEXT PRIMARY KEY NOT NULL,
      author TEXT NOT NULL,
      created REAL NOT NULL,
      updated REAL NOT NULL,
      client_id TEXT,
      body TEXT NOT NULL,
      media TEXT NOT NULL
    )''';

  static const String _createChatPending = '''
    CREATE TABLE IF NOT EXISTS chat_pending (
      client_id TEXT PRIMARY KEY NOT NULL,
      content TEXT NOT NULL,
      created REAL NOT NULL,
      failed INTEGER NOT NULL DEFAULT 0,
      media_json TEXT NOT NULL DEFAULT '[]',
      phase TEXT NOT NULL DEFAULT 'send'
    )''';

  /// 「我的表情包」（对齐 Web localStorage['stickers:<uid>']：上传即存服务器
  /// 媒体库，本机只存 mid 列表；上限 100 在写入层裁剪）
  static const String _createMyStickers = '''
    CREATE TABLE IF NOT EXISTS my_stickers (
      mid TEXT NOT NULL,
      user_id TEXT NOT NULL,
      name TEXT NOT NULL DEFAULT '',
      created REAL NOT NULL,
      PRIMARY KEY (user_id, mid)
    )''';

  // ── chat_messages（最近窗口缓存）──────────────────────────────────

  /// 按 id UPSERT 一批聊天记录，然后裁剪到最近 [chatCacheWindow] 条
  Future<void> saveRecords(List<ChatRecord> records) async {
    if (records.isEmpty) return;
    await transaction(() async {
      for (final r in records) {
        await customInsert(
          'INSERT INTO chat_messages (id, author, created, updated, client_id, body, media) '
          'VALUES (?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(id) DO UPDATE SET author = excluded.author, created = excluded.created, '
          'updated = excluded.updated, client_id = excluded.client_id, '
          'body = excluded.body, media = excluded.media',
          variables: [
            Variable.withString(r.id),
            Variable.withString(r.author),
            Variable.withReal(r.created),
            Variable.withReal(r.updated),
            Variable.withString(r.clientId),
            Variable.withString(jsonEncode(r.body.toJson())),
            Variable.withString(jsonEncode(r.media.map((m) => m.toJson()).toList())),
          ],
        );
      }
    });
    await _trim();
  }

  /// 只留最近窗口：按 created 降序取前 [chatCacheWindow] 条的 id，其余删除
  Future<void> _trim() async {
    await customStatement(
      'DELETE FROM chat_messages WHERE id NOT IN '
      '(SELECT id FROM chat_messages ORDER BY created DESC, id DESC LIMIT ?)',
      [chatCacheWindow],
    );
  }

  /// 读缓存（created 降序返回；调用方自行反转为升序）
  Future<List<ChatRecord>> loadRecords({int limit = chatCacheWindow}) async {
    final rows = await customSelect(
      'SELECT id, author, created, updated, client_id, body, media '
      'FROM chat_messages ORDER BY created DESC, id DESC LIMIT ?',
      variables: [Variable.withInt(limit)],
    ).get();
    return rows.map(_recordFromRow).toList();
  }

  ChatRecord _recordFromRow(QueryRow row) => ChatRecord(
        id: row.data['id']! as String,
        author: row.data['author']! as String,
        created: (row.data['created']! as num).toDouble(),
        updated: (row.data['updated']! as num).toDouble(),
        clientId: (row.data['client_id'] ?? '') as String,
        body: ChatBody.fromJson(
            (jsonDecode(row.data['body']! as String) as Map).cast<String, dynamic>()),
        media: ((jsonDecode(row.data['media']! as String) as List)
                .whereType<Map>()
                .map((m) => ChatMedia.fromJson(m.cast<String, dynamic>())))
            .toList(),
      );

  // ── chat_pending（待发队列落盘；等价 Web localStorage pending）────

  Future<void> savePending(ChatPending p) async {
    await customInsert(
      'INSERT INTO chat_pending (client_id, content, created, failed, media_json, phase) '
      'VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(client_id) DO UPDATE SET content = excluded.content, '
      'created = excluded.created, failed = excluded.failed, '
      'media_json = excluded.media_json, phase = excluded.phase',
      variables: [
        Variable.withString(p.clientId),
        Variable.withString(p.content),
        Variable.withReal(p.createdAt),
        Variable.withBool(p.failed),
        Variable.withString(jsonEncode(p.mediaFiles.map((f) => f.toJson()).toList())),
        Variable.withString(
            p.phase == ChatPendingPhase.upload ? 'upload' : 'send'),
      ],
    );
  }

  Future<void> deletePending(String clientId) async {
    await customStatement(
      'DELETE FROM chat_pending WHERE client_id = ?',
      [clientId],
    );
  }

  Future<List<ChatPending>> loadPending() async {
    final rows = await customSelect(
      'SELECT client_id, content, created, failed, media_json, phase '
      'FROM chat_pending ORDER BY created ASC',
    ).get();
    return rows.map(_pendingFromRow).toList();
  }

  ChatPending _pendingFromRow(QueryRow row) {
    final phaseRaw = (row.data['phase'] ?? 'send').toString();
    return ChatPending(
      clientId: row.data['client_id']! as String,
      content: row.data['content']! as String,
      createdAt: (row.data['created']! as num).toDouble(),
      failed: (row.data['failed']! as num).toInt() == 1,
      mediaFiles: ((jsonDecode((row.data['media_json'] ?? '[]') as String) as List)
              .whereType<Map>()
              .map((f) => ChatLocalFile.fromJson(f.cast<String, dynamic>())))
          .toList(),
      phase: phaseRaw == 'upload' ? ChatPendingPhase.upload : ChatPendingPhase.send,
    );
  }

  // ── my_stickers（我的表情包）───────────────────────────────────────

  Future<void> saveMySticker(String userId, String mid, String name) async {
    await customInsert(
      'INSERT INTO my_stickers (mid, user_id, name, created) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(user_id, mid) DO UPDATE SET name = excluded.name',
      variables: [
        Variable.withString(mid),
        Variable.withString(userId),
        Variable.withString(name),
        Variable.withReal(DateTime.now().millisecondsSinceEpoch / 1000),
      ],
    );
    // 上限裁剪：保留最近 100 张
    await customStatement(
      'DELETE FROM my_stickers WHERE user_id = ? AND mid NOT IN '
      '(SELECT mid FROM my_stickers WHERE user_id = ? '
      'ORDER BY created DESC, mid DESC LIMIT ?)',
      [userId, userId, myStickerLimit],
    );
  }

  Future<void> deleteMySticker(String userId, String mid) async {
    await customStatement(
      'DELETE FROM my_stickers WHERE user_id = ? AND mid = ?',
      [userId, mid],
    );
  }

  Future<List<(String, String)>> loadMyStickers(String userId) async {
    final rows = await customSelect(
      'SELECT mid, name FROM my_stickers WHERE user_id = ? '
      'ORDER BY created DESC, mid DESC',
      variables: [Variable.withString(userId)],
    ).get();
    return rows
        .map((row) => (
              row.data['mid']! as String,
              (row.data['name'] ?? '') as String
            ))
        .toList();
  }
}

/// drift 数据库（App 全局唯一实例；聊天缓存专用库，不与其它功能共用）
final chatDbProvider = FutureProvider<ChatDatabase>((ref) async {
  final db = ChatDatabase.open();
  ref.onDispose(() => db.close());
  return db;
});
