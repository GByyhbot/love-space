/// 时光页数据层纯函数（条目 4 · 段一，可单测）。
/// 契约（app.js loadTimeline:282 / timelinePage:860 实读）：
/// · `GET /api/records?kind=post&limit=61`，取前 60 条，hasMore = length > 60；
/// · 上翻 `before=<created>&before_id=<id>`（列表最后一条）；
/// · 筛选参数 q / author（用户 id）/ date（yyyy-MM-dd）/ media_type（image/video/audio）；
/// · 卡片头部日期 = body.date || dateLabel(created)（发生日 ≠ 发布时间戳）；
/// · dateLabel：zh-CN toLocaleString(month long/day/hour2-digit/minute2-digit)
///   ≈ 「M月d日 HH:mm」。
library;

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
