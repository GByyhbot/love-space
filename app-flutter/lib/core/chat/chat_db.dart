/// 聊天本地缓存（drift · 手写 SQL 模式）。
///
/// 为什么不用 drift 代码生成：本条目红线「新依赖只加 uuid」，不能引入
/// build_runner / drift_dev。这里把 drift 当薄 SQLite 封装用（drift 2.35）：
/// · GeneratedDatabase.allTables 覆写为空 → 走默认迁移不生成任何表；
/// · 表结构在 beforeOpen 用原生 CREATE TABLE IF NOT EXISTS 创建；
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
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
        beforeOpen: (details) async {
          await customStatement(_createChatMessages);
          await customStatement(_createChatPending);
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
      failed INTEGER NOT NULL DEFAULT 0
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
      'INSERT INTO chat_pending (client_id, content, created, failed) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(client_id) DO UPDATE SET content = excluded.content, '
      'created = excluded.created, failed = excluded.failed',
      variables: [
        Variable.withString(p.clientId),
        Variable.withString(p.content),
        Variable.withReal(p.createdAt),
        Variable.withBool(p.failed),
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
      'SELECT client_id, content, created, failed FROM chat_pending ORDER BY created ASC',
    ).get();
    return rows
        .map((row) => ChatPending(
              clientId: row.data['client_id']! as String,
              content: row.data['content']! as String,
              createdAt: (row.data['created']! as num).toDouble(),
              failed: (row.data['failed']! as num).toInt() == 1,
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
