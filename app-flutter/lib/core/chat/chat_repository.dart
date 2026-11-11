/// 聊天仓库：records 拉取（游标分页）/ 纯文本发送（client_id 幂等）/ 对账合并。
/// 契约依据 api-samples/03-records.md + app/main.py 实读：
/// · 首屏 GET /api/records?kind=chat&limit=200（服务端 created DESC 返回）；
/// · 上翻 `before`/`before_id` 游标；
/// · POST /api/records {kind:'chat', body, client_id}，服务端
///   UNIQUE(author, client_id) → 同 id 重发幂等返回既有记录（重试依据）。
/// 合并是纯函数（可单测）：按 id 对账、原地更新语义（未变化的行保持同一对象实例）。
library;

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import 'chat_models.dart';

const _uuid = Uuid();

/// 单页条数（与 Web 口径一致：最近 200 条）
const int chatPageSize = 200;

/// client_id 生成（uuid v4，与 Web uuid() 同口径）：发送时生成、重试复用同一 id
String newChatClientId() => _uuid.v4();

/// 首屏拉取：GET /api/records?kind=chat&limit=200
Future<List<ChatRecord>> fetchLatestChats(Dio dio, {int limit = chatPageSize}) async {
  final r = await dio
      .get('/api/records', queryParameters: {'kind': 'chat', 'limit': limit});
  return parseChatRecords(r.data);
}

/// 上翻历史：`before`（最旧 created）+ `before_id`（最旧 id）游标分页
Future<List<ChatRecord>> fetchOlderChats(Dio dio, ChatRecord oldest,
    {int limit = chatPageSize}) async {
  final r = await dio.get('/api/records', queryParameters: {
    'kind': 'chat',
    'limit': limit,
    'before': oldest.created,
    'before_id': oldest.id,
  });
  return parseChatRecords(r.data);
}

/// 解析服务端 records 列表（缺失/畸形条目容错跳过，绝不抛异常中断列表）
List<ChatRecord> parseChatRecords(Object? data) {
  if (data is! List) return const [];
  final result = <ChatRecord>[];
  for (final e in data) {
    if (e is Map) result.add(ChatRecord.fromJson(e.cast<String, dynamic>()));
  }
  return result;
}

/// 发送纯文本消息。服务端幂等：同 (author, client_id) 重发返回既有记录。
Future<ChatRecord> sendChatText(Dio dio, String content, String clientId) async =>
    sendChatBody(dio, {'content': content, 'media': []}, clientId);

/// 发送任意聊天 body（段二扩展：媒体 {content, media:[mid...]}、贴纸
/// {content:'', sticker:path}；服务端 clean_body 白名单过滤未知字段）。
/// 幂等：同 (author, client_id) 重发返回既有记录。
Future<ChatRecord> sendChatBody(
    Dio dio, Map<String, dynamic> body, String clientId) async {
  final r = await dio.post('/api/records', data: {
    'kind': 'chat',
    'body': body,
    'client_id': clientId,
  });
  return ChatRecord.fromJson((r.data as Map).cast<String, dynamic>());
}

/// 对账合并结果：merged 为 created 升序、按 id 去重的完整列表；
/// confirmedClientIds 为出现在服务端记录里的 client_id（pending 幂等收尾依据）；
/// changedCount 为发生内容更新/新增的行数（0 = 服务端无变化，UI 可跳过刷新）。
class ChatMergeResult {
  const ChatMergeResult({
    required this.merged,
    required this.confirmedClientIds,
    required this.changedCount,
  });
  final List<ChatRecord> merged;
  final Set<String> confirmedClientIds;
  final int changedCount;
}

/// 按 id 对账合并（对齐 Web paintChat 语义：不整列表重建，已有 id 原地更新）。
/// 未变化的行保持原对象实例（identical），UI 据此跳过无谓重绘；新记录插入后
/// 整体按 (created, id) 升序排定。incoming 单条（发送返回）与整页（SSE 对账）通用。
ChatMergeResult mergeChats(List<ChatRecord> current, List<ChatRecord> incoming) {
  int asc(ChatRecord a, ChatRecord b) {
    final c = a.created.compareTo(b.created);
    return c != 0 ? c : a.id.compareTo(b.id);
  }

  final byId = <String, ChatRecord>{for (final r in current) r.id: r};
  final confirmed = <String>{};
  var changed = 0;
  for (final r in [...incoming]..sort(asc)) {
    final old = byId[r.id];
    if (old == null) {
      byId[r.id] = r;
      changed++;
    } else if (!old.rendersSameAs(r)) {
      byId[r.id] = r;
      changed++;
    }
    if (r.clientId.isNotEmpty) confirmed.add(r.clientId);
  }
  final merged = byId.values.toList()..sort(asc);
  return ChatMergeResult(
    merged: merged,
    confirmedClientIds: confirmed,
    changedCount: changed,
  );
}
