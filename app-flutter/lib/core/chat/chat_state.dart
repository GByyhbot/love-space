/// 聊天状态层：未读角标 / 页面在栈标志 / 消息列表控制器（发送状态机 + 对账）。
///
/// · chatUnreadProvider：GET /api/me 的 chat_unread（字段名已在 app/main.py 实读
///   确认），auth bootstrap 播种、进聊天页清零、聊天页外 SSE chat 事件经 me 重拉更新。
///   挂独立 Notifier 而不是塞进认证状态：角标变化不必打断 authed 态、不必整页刷新。
/// · chatControllerProvider：列表行（已确认记录 + 本地待发），实现 chat-plan Step 3
///   发送状态机与 Step 4 SSE 对账。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import 'chat_db.dart';
import 'chat_models.dart';
import 'chat_repository.dart';

// ── 未读角标与页面在栈标志 ────────────────────────────────────────────

class ChatUnreadNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void set(int value) {
    if (state != value) state = value;
  }

  void clear() {
    if (state != 0) state = 0;
  }
}

final chatUnreadProvider =
    NotifierProvider<ChatUnreadNotifier, int>(ChatUnreadNotifier.new);

/// 聊天页是否在路由栈上（messages_page initState/dispose 维护）：
/// SSE chat 事件只在页面未打开时才触发 me 重拉刷新角标。
final chatPageActiveProvider = StateProvider<bool>((_) => false);

// ── 持久化抽象（默认 drift 实现；单测换内存实现模拟杀进程）──────────

abstract class ChatPersistence {
  /// 覆盖写入记录（最近窗口缓存，自动裁剪）
  Future<void> saveRecords(List<ChatRecord> records);

  /// 读缓存（created 降序返回）
  Future<List<ChatRecord>> loadRecords();

  Future<void> upsertPending(ChatPending p);
  Future<void> deletePending(String clientId);
  Future<List<ChatPending>> loadPending();
}

/// 默认实现：drift（chat_messages + chat_pending 两张表）
class DriftChatPersistence implements ChatPersistence {
  DriftChatPersistence(this._db);
  final ChatDatabase _db;

  @override
  Future<void> saveRecords(List<ChatRecord> records) =>
      _db.saveRecords(records);

  @override
  Future<List<ChatRecord>> loadRecords() => _db.loadRecords();

  @override
  Future<void> upsertPending(ChatPending p) => _db.savePending(p);

  @override
  Future<void> deletePending(String clientId) => _db.deletePending(clientId);

  @override
  Future<List<ChatPending>> loadPending() => _db.loadPending();
}

final chatPersistenceProvider = FutureProvider<ChatPersistence>((ref) async {
  final db = await ref.watch(chatDbProvider.future);
  return DriftChatPersistence(db);
});

// ── 列表行模型 ──────────────────────────────────────────────────────

/// 列表行：已确认的服务端记录，或本地待发（发送中/未发出）
sealed class ChatRow {
  const ChatRow();
}

class ChatRecordRow extends ChatRow {
  const ChatRecordRow(this.record);
  final ChatRecord record;
}

class ChatPendingRow extends ChatRow {
  const ChatPendingRow({
    required this.clientId,
    required this.content,
    this.failed = false,
  });
  final String clientId;

  /// false=发送中（三点跳动动效）；true=未发出（标红 + 点击重试）
  final bool failed;
  final String content;

  ChatPendingRow withFailed(bool failed) => ChatPendingRow(
        clientId: clientId,
        content: content,
        failed: failed,
      );
}

/// 列表整体状态（行按 created 升序；pending 恒在末尾=最新）
class ChatState {
  const ChatState({
    this.rows = const [],
    this.loadingOlder = false,
    this.hasMoreHistory = true,
    this.cacheLoaded = false,
  });
  final List<ChatRow> rows;
  final bool loadingOlder;
  final bool hasMoreHistory;
  final bool cacheLoaded;

  ChatState copyWith({
    List<ChatRow>? rows,
    bool? loadingOlder,
    bool? hasMoreHistory,
    bool? cacheLoaded,
  }) =>
      ChatState(
        rows: rows ?? this.rows,
        loadingOlder: loadingOlder ?? this.loadingOlder,
        hasMoreHistory: hasMoreHistory ?? this.hasMoreHistory,
        cacheLoaded: cacheLoaded ?? this.cacheLoaded,
      );
}

// ── 控制器（发送状态机 + 分页 + SSE 对账）────────────────────────────

class ChatController extends Notifier<ChatState> {
  bool _disposed = false;
  bool _reconciling = false;
  bool _loadingOlder = false;
  bool _cacheLoaded = false;
  String? _boundUserId; // 绑定当前用户：换账号登录后本地状态全部作废重置
  final _sendingClientIds = <String>{};

  @override
  ChatState build() {
    ref.onDispose(() => _disposed = true);
    return const ChatState();
  }

  /// 进入聊天页初始化：换号重置 → pending 落盘恢复 + 缓存秒出 → 首屏网络对账。
  /// 可重复调用（每次进页都走 reconcile，缓存只在首次加载）。
  Future<void> bootstrap(String myId) async {
    if (_boundUserId != myId) {
      _boundUserId = myId;
      _cacheLoaded = false;
      _sendingClientIds.clear();
      if (!_disposed) state = const ChatState();
    }
    if (!_cacheLoaded) {
      _cacheLoaded = true;
      try {
        final store = await ref.read(chatPersistenceProvider.future);
        final pending = await store.loadPending();
        final cached = (await store.loadRecords()).reversed.toList();
        if (_disposed) return;
        // 恢复的 pending 一律置为 failed=true（可重试态）：Web 的失败标记只在内存，
        // 杀进程重开后不自动重发，保留「未发出 · 点击重试」由用户决定
        final restored = pending
            .map((p) => ChatPendingRow(
                  clientId: p.clientId,
                  content: p.content,
                  failed: true,
                ))
            .toList();
        state = state.copyWith(
          rows: [...cached.map(ChatRecordRow.new), ...restored],
          cacheLoaded: true,
        );
      } catch (_) {
        // 缓存读失败不阻塞聊天页：直接走网络对账
      }
    }
    await reconcile();
  }

  /// 对账重拉（进页 / SSE chat 事件 / 回前台）：GET 首屏 200 与本地按 id 合并。
  /// 合并语义：新消息插入、已有 id 原地更新（recall/pinned/body 变化）、
  /// pending 中 client_id 与服务端记录相同的删 pending（幂等收尾）。
  Future<void> reconcile() async {
    if (_reconciling || _disposed) return;
    _reconciling = true;
    try {
      final dio = await ref.read(dioProvider.future);
      final fresh = await fetchLatestChats(dio);
      if (_disposed) return;
      final pendingBefore = state.rows
          .whereType<ChatPendingRow>()
          .map((p) => p.clientId)
          .toSet();
      _applyMerge(fresh);
      await _persist(fresh, pendingBefore);
    } catch (_) {
      // 网络失败：保留缓存与本地态静默展示，下次事件/进页再对账
    } finally {
      _reconciling = false;
    }
  }

  /// 上翻历史：before/before_id 游标（接近列表顶部时由页面触发预拉）
  Future<void> loadOlder() async {
    if (_loadingOlder || !state.hasMoreHistory || _disposed) return;
    final records =
        state.rows.whereType<ChatRecordRow>().map((r) => r.record).toList();
    if (records.isEmpty) return;
    final oldest = records.first;
    _loadingOlder = true;
    if (!_disposed) state = state.copyWith(loadingOlder: true);
    try {
      final dio = await ref.read(dioProvider.future);
      final older = await fetchOlderChats(dio, oldest);
      if (_disposed) return;
      if (older.length < chatPageSize) {
        state = state.copyWith(hasMoreHistory: false);
      }
      _applyMerge(older);
      await _persist(older, const {});
    } catch (_) {
      // 上翻失败不打断浏览；下次接近顶部会再触发
    } finally {
      _loadingOlder = false;
      if (!_disposed) state = state.copyWith(loadingOlder: false);
    }
  }

  /// 发送纯文本（Step 3 状态机）：
  /// ① 生成 client_id → pending 落盘 → 立即渲染发送中三点动效；
  /// ② POST 成功 → 删 pending（落盘 + 内存）→ 返回记录按 id 并入列表；
  /// ③ 失败 → 标红「未发出 · 点击重试」（rethrow 给页面提示中文 detail）。
  Future<void> send(String content) async {
    final text = content.trim();
    if (text.isEmpty) return;
    final clientId = newChatClientId();
    final pending = ChatPending(
      clientId: clientId,
      content: text,
      createdAt: DateTime.now().millisecondsSinceEpoch / 1000,
    );
    try {
      final store = await ref.read(chatPersistenceProvider.future);
      await store.upsertPending(pending);
    } catch (_) {}
    if (_disposed) return;
    state = state.copyWith(
        rows: [...state.rows, ChatPendingRow(clientId: clientId, content: text)]);
    await _postPending(clientId, text);
  }

  /// 失败重试：复用同一 client_id（服务端 UNIQUE(author, client_id) 保证不重复）
  Future<void> retry(String clientId) async {
    final row = state.rows
        .whereType<ChatPendingRow>()
        .where((r) => r.clientId == clientId)
        .firstOrNull;
    if (row == null || _sendingClientIds.contains(clientId)) return;
    if (!_disposed) state = state.copyWith(rows: _replaceRow(row, false));
    await _postPending(clientId, row.content);
  }

  Future<void> _postPending(String clientId, String content) async {
    _sendingClientIds.add(clientId);
    try {
      final dio = await ref.read(dioProvider.future);
      final record = await sendChatText(dio, content, clientId);
      // 成功：清 pending（落盘 + 内存）→ 记录并入列表（按 id 去重、升序）
      try {
        final store = await ref.read(chatPersistenceProvider.future);
        await store.deletePending(clientId);
      } catch (_) {}
      if (_disposed) return;
      state = state.copyWith(rows: _removePendingRow(clientId));
      _applyMerge([record]);
      await _persist([record], const {});
    } catch (e) {
      // 失败：标红「未发出 · 点击重试」（断网/超时统一失败态）
      if (!_disposed) {
        state = state.copyWith(rows: _markFailed(clientId));
      }
      rethrow;
    } finally {
      _sendingClientIds.remove(clientId);
    }
  }

  /// 进入聊天页清未读：本地角标清零 + POST /api/notices/read?event=chat
  /// （Web navigate('messages') 的行为；失败静默，下次进页再试）
  Future<void> markRead() async {
    ref.read(chatUnreadProvider.notifier).clear();
    try {
      final dio = await ref.read(dioProvider.future);
      await dio.post('/api/notices/read', queryParameters: {'event': 'chat'});
    } catch (_) {}
  }

  // ── 内部工具 ──────────────────────────────────────────────────────

  /// 按 id 对账合并进当前列表（未变化的行保持原实例；不整列表重建）
  void _applyMerge(List<ChatRecord> incoming) {
    if (incoming.isEmpty || _disposed) return;
    final records =
        state.rows.whereType<ChatRecordRow>().map((r) => r.record).toList();
    final result = mergeChats(records, incoming);
    final pendings = state.rows
        .whereType<ChatPendingRow>()
        .where((p) => !result.confirmedClientIds.contains(p.clientId))
        .toList();
    state = state.copyWith(
      rows: [...result.merged.map(ChatRecordRow.new), ...pendings],
    );
  }

  /// 记录写入缓存 + pending 幂等收尾（client_id 被服务端确认的行落盘删除）
  Future<void> _persist(List<ChatRecord> records, Set<String> pendingBefore) async {
    try {
      final store = await ref.read(chatPersistenceProvider.future);
      final confirmed = records
          .map((r) => r.clientId)
          .where((c) => c.isNotEmpty)
          .toSet()
          .intersection(pendingBefore);
      for (final clientId in confirmed) {
        await store.deletePending(clientId);
      }
      await store.saveRecords(records);
    } catch (_) {}
  }

  List<ChatRow> _replaceRow(ChatPendingRow row, bool failed) {
    final rows = [...state.rows];
    final idx = rows.indexOf(row);
    if (idx >= 0) rows[idx] = row.withFailed(failed);
    return rows;
  }

  List<ChatRow> _markFailed(String clientId) {
    final rows = [...state.rows];
    final idx =
        rows.indexWhere((r) => r is ChatPendingRow && r.clientId == clientId);
    if (idx >= 0) rows[idx] = (rows[idx] as ChatPendingRow).withFailed(true);
    return rows;
  }

  List<ChatRow> _removePendingRow(String clientId) => state.rows
      .where((r) => !(r is ChatPendingRow && r.clientId == clientId))
      .toList();
}

final chatControllerProvider =
    NotifierProvider<ChatController, ChatState>(ChatController.new);
