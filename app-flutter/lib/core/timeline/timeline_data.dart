/// 时光页数据层纯函数（条目 4 · 段一，可单测）。
/// 契约（app.js loadTimeline:282 / timelinePage:860 实读）：
/// · `GET /api/records?kind=post&limit=61`，取前 60 条，hasMore = length > 60；
/// · 上翻 `before=<created>&before_id=<id>`（列表最后一条）；
/// · 筛选参数 q / author（用户 id）/ date（yyyy-MM-dd）/ media_type（image/video/audio）；
/// · 卡片头部日期 = body.date || dateLabel(created)（发生日 ≠ 发布时间戳）；
/// · dateLabel：zh-CN toLocaleString(month long/day/hour2-digit/minute2-digit)
///   ≈ 「M月d日 HH:mm」。
library;

import 'dart:math' as math;

import '../api/api_client.dart' as api;

/// 单页条数（服务端拉 61 判 hasMore，展示 60）
const int timelinePageSize = 60;

/// 时光筛选（q/author/date/media_type 四参数）
class TimelineFilter {
  const TimelineFilter({this.q = '', this.author = '', this.date = '', this.media = ''});
  final String q;
  final String author; // 用户 id；空=两个人的时光
  final String date; // yyyy-MM-dd
  final String media; // image / video / audio；空=所有记录

  bool get isActive => q.isNotEmpty || author.isNotEmpty || date.isNotEmpty || media.isNotEmpty;

  int get activeCount =>
      [q, author, date, media].where((v) => v.isNotEmpty).length;

  TimelineFilter copyWith({String? q, String? author, String? date, String? media}) =>
      TimelineFilter(
        q: q ?? this.q,
        author: author ?? this.author,
        date: date ?? this.date,
        media: media ?? this.media,
      );
}

/// 解析服务端 records 列表为时光页 Record（缺失/畸形条目容错跳过，绝不抛异常）
List<api.Record> parsePostRecords(Object? data) {
  if (data is! List) return const [];
  final result = <api.Record>[];
  for (final e in data) {
    if (e is Map) result.add(api.Record.fromJson(e.cast<String, dynamic>()));
  }
  return result;
}

/// 组装 GET /api/records 查询参数（对齐 Web loadTimeline 逐项）。
/// [cursor] 为列表最后一条的 (created, id)；reset 时不带游标。
Map<String, dynamic> buildTimelineQuery(
  TimelineFilter filter, {
  int limit = timelinePageSize + 1,
  (double, String)? cursor,
}) {
  final params = <String, dynamic>{
    'kind': 'post',
    'limit': limit,
  };
  if (filter.q.isNotEmpty) params['q'] = filter.q;
  if (filter.author.isNotEmpty) params['author'] = filter.author;
  if (filter.date.isNotEmpty) params['date'] = filter.date;
  if (filter.media.isNotEmpty) params['media_type'] = filter.media;
  if (cursor != null) {
    params['before'] = cursor.$1;
    params['before_id'] = cursor.$2;
  }
  return params;
}

/// 追加一页：只追加按 id 去重、不整列表重建（Web loadMoreTimeline 语义）。
/// 返回 (新列表, 新增条数)。服务端返回序即展示序（created 降序）。
(int appended, List<T> merged) appendTimelinePage<T>(
    List<T> current, List<T> page, String Function(T) idOf) {
  final ids = {for (final r in current) idOf(r)};
  final fresh = page.where((r) => !ids.contains(idOf(r))).toList();
  return (fresh.length, [...current, ...fresh]);
}

/// zh-CN dateLabel：M月d日 HH:mm（对齐 Web toLocaleString zh-CN 口径）
String timelineDateLabel(double created) {
  final d = DateTime.fromMillisecondsSinceEpoch((created * 1000).round());
  final mm = d.minute.toString().padLeft(2, '0');
  final hh = d.hour.toString().padLeft(2, '0');
  return '${d.month}月${d.day}日 $hh:$mm';
}

/// 卡片头部日期口径：发生日 body.date 优先，缺省回退发布时间戳
String postHeaderDate({
  required String bodyDate,
  required double created,
}) =>
    bodyDate.isNotEmpty ? bodyDate : timelineDateLabel(created);

// ── 段二 B · 互动纯函数（可单测）─────────────────────────────────

/// 本地翻转向量的 likes（B1）：含本人 id → 移除；否则追加。
/// 服务端 POST /records/{id}/like 只回 {ok:true} 不回新状态，故本地翻转。
List<String> toggleLocalLikes(List<String> likes, String myId) => likes.contains(myId)
    ? likes.where((u) => u != myId).toList()
    : [...likes, myId];

/// 按评论 id 去重合并（B2/B3）：服务端列表为底，本地即时插入的评论
/// 仅在 cid 不存在时追加。SSE other 重拉回来的列表与本端即时插入的
/// 那条（用服务端返回的真实 cid）经此合并后恒为一条，绝不重复。
List<Map<String, dynamic>> mergeCommentsByCid(
    List<Map<String, dynamic>> server, List<Map<String, dynamic>> local) {
  final ids = {for (final c in server) c['id']?.toString()};
  final merged = <Map<String, dynamic>>[...server];
  for (final c in local) {
    final cid = c['id']?.toString();
    if (cid != null && cid.isNotEmpty && !ids.contains(cid)) {
      merged.add(c);
      ids.add(cid);
    }
  }
  // 服务端评论按 created 升序；本地插入的 created 更大，排末尾即合序
  merged.sort((a, b) => ((a['created'] as num?)?.toDouble() ?? 0)
      .compareTo((b['created'] as num?)?.toDouble() ?? 0));
  return merged;
}

/// 删评论入口显隐：仅本人评论（B2，服务端 DELETE 亦按 author 校验）
bool canDeleteComment(Map<String, dynamic> comment, String myId) =>
    comment['author']?.toString() == myId;

// ── 时光卡片媒体网格宽度（Web static/style.css:602-609）────────────────
// `.media-grid{grid-template-columns:repeat(3,1fr);gap:8px}`、
// `.media-grid.single{grid-template-columns:1fr}`、
// `.media-grid.single img{aspect-ratio:16/10;max-height:360px}`。
// 旧实现复用聊天气泡的固定 size（220/110）→ 单图右侧 2/3 空白（真机复验缺陷 3）。
const double timelineMediaGap = 8.0;

/// 多图每格边长：卡片内容宽扣两道 8dp 间隙后三等分
double timelineMediaCell(double cardWidth) =>
    (cardWidth - timelineMediaGap * 2) / 3;

/// 单图高度：16/10 比例，封顶 360dp
double timelineSingleMediaHeight(double cardWidth) =>
    math.min(cardWidth * 10 / 16, 360.0);
