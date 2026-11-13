/// 相册页数据层纯函数（条目 5 · 段 A，可单测）。
/// 契约（app/main.py:1689-1721 实读 / static/app.js:947-965 对照）：
/// · GET `/api/photos?album=<id>` → 只从 kind='post' 的 body.media 收集、
///   只 image/%、按记录 created 倒序、同一 mid 只留首次出现；
///   返回 {id,name,mime,owner,status,preview,record_id,date,caption}。
/// · 相册分类 = GET /api/records?kind=album 的记录（body.title 必填）。
/// · 两种视图：按相册分类（chips 筛选）/ 按时间（date 的 yyyy-MM 分组，
///   key 倒序、组内 date 倒序；无 date 归「还没有填日期」）。
library;

/// 一张照片（/api/photos 返回项）
class PhotoItem {
  const PhotoItem({
    required this.id,
    this.name = '',
    this.mime = '',
    this.status = '',
    this.preview = '',
    this.recordId = '',
    this.date = '',
    this.caption = '',
  });

  final String id;
  final String name;
  final String mime;
  final String status;
  final String preview;
  final String recordId;
  final String date; // post 的 body.date（发生日 yyyy-MM-dd）
  final String caption; // post 的 body.content

  factory PhotoItem.fromJson(Map<String, dynamic> j) => PhotoItem(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        mime: (j['mime'] ?? '').toString(),
        status: (j['status'] ?? '').toString(),
        preview: (j['preview'] ?? '').toString(),
        recordId: (j['record_id'] ?? '').toString(),
        date: (j['date'] ?? '').toString(),
        caption: (j['caption'] ?? '').toString(),
      );
}

/// 相册分类（kind='album' 记录）
class AlbumInfo {
  const AlbumInfo({required this.id, this.title = ''});
  final String id;
  final String title;

  factory AlbumInfo.fromRecord(Map<String, dynamic> j) => AlbumInfo(
        id: (j['id'] ?? '').toString(),
        title: (((j['body'] ?? {}) as Map)['title'] ?? '').toString(),
      );
}

/// 解析照片列表（畸形条目容错跳过，绝不抛异常）
List<PhotoItem> parsePhotos(Object? data) {
  if (data is! List) return const [];
  final out = <PhotoItem>[];
  for (final e in data) {
    if (e is Map) {
      final p = PhotoItem.fromJson(e.cast<String, dynamic>());
      if (p.id.isNotEmpty) out.add(p);
    }
  }
  return out;
}

/// 解析相册分类（kind=album 记录；丢弃 id/标题为空的条目）
List<AlbumInfo> parseAlbumRecords(Object? data) {
  if (data is! List) return const [];
  final out = <AlbumInfo>[];
  for (final e in data) {
    if (e is Map) {
      final a = AlbumInfo.fromRecord(e.cast<String, dynamic>());
      if (a.id.isNotEmpty && a.title.isNotEmpty) out.add(a);
    }
  }
  return out;
}

/// 月份分组单元
class PhotoMonthGroup {
  const PhotoMonthGroup({required this.key, required this.label, required this.photos});
  final String key; // yyyy-MM 或 ''（无日期）
  final String label;
  final List<PhotoItem> photos;
}

/// 按 date 的 yyyy-MM 分组（对齐 Web albumsPage 的「按时间」视图）：
/// key 倒序（空 key 排最后），组内 date 倒序，date 相同保序（服务端序）。
List<PhotoMonthGroup> groupPhotosByMonth(List<PhotoItem> photos) {
  final buckets = <String, List<PhotoItem>>{};
  for (final p in photos) {
    final key = p.date.length >= 7 ? p.date.substring(0, 7) : '';
    buckets.putIfAbsent(key, () => <PhotoItem>[]).add(p);
  }
  final keys = buckets.keys.toList()
    ..sort((a, b) {
      if (a.isEmpty) return 1;
      if (b.isEmpty) return -1;
      return b.compareTo(a); // 新月份在前
    });
  return [
    for (final k in keys)
      PhotoMonthGroup(
        key: k,
        label: monthGroupLabel(k),
        photos: _sortByDateDesc(buckets[k]!),
      ),
  ];
}

/// 组内 date 倒序（稳定：相同 date 用插入序号保序）
List<PhotoItem> _sortByDateDesc(List<PhotoItem> src) {
  final indexed = <int, PhotoItem>{
    for (var i = 0; i < src.length; i++) i: src[i],
  };
  final order = indexed.keys.toList()
    ..sort((a, b) {
      final c = indexed[b]!.date.compareTo(indexed[a]!.date);
      return c != 0 ? c : a.compareTo(b);
    });
  return [for (final i in order) indexed[i]!];
}

/// 月份标题：yyyy-MM → 「YYYY 年 M 月」；空 → 「还没有填日期」
String monthGroupLabel(String key) {
  if (key.isEmpty) return '还没有填日期';
  final parts = key.split('-');
  if (parts.length < 2) return key;
  final m = int.tryParse(parts[1]);
  return '${parts[0]} 年 ${m ?? parts[1]} 月';
}

/// 网格 3 列切行（按相册分类视图用；每行的最后一行允许不足 3 张）
List<List<PhotoItem>> chunkPhotosForGrid(List<PhotoItem> photos,
    {int columns = 3}) {
  final rows = <List<PhotoItem>>[];
  for (var i = 0; i < photos.length; i += columns) {
    rows.add(photos.sublist(i, (i + columns).clamp(0, photos.length)));
  }
  return rows;
}

/// 相册缩略图 ↔ 查看器的 Hero tag（网格与查看器共用，保证双向转场）
String albumHeroTag(String mid) => 'album-photo-$mid';

/// 3 列网格：给定 index 的滚动目标偏移（用于翻页后返回网格时把落点
/// 滚到「当前查看的那张」而不是最初点开的）。行高 = cell + 行间距。
double albumGridScrollOffset(
  int index, {
  required double cellSize,
  required double spacing,
  required double viewportHeight,
  required double maxScrollExtent,
}) {
  final row = index ~/ 3;
  final rowStride = cellSize + spacing;
  // 目标：让该行居中（不足一屏时归零），并夹在可滚动范围内
  final raw = row * rowStride - (viewportHeight - cellSize) / 2;
  return raw.clamp(0.0, maxScrollExtent < 0 ? 0.0 : maxScrollExtent);
}

/// 双击缩放围绕视口中心的变换矩阵（供 InteractiveViewer 用，纯函数可单测）：
/// T(中心) · S(s) · T(-中心)，使中心点在缩放前后不动。
List<double> zoomMatrixAroundCenter(double scale, double width, double height) {
  final cx = width / 2, cy = height / 2;
  return <double>[
    scale, 0, 0, 0,
    0, scale, 0, 0,
    0, 0, 1, 0,
    cx * (1 - scale), cy * (1 - scale), 0, 1,
  ];
}

/// 下拉关闭阈值判定（位移过阈值 → 关闭；否则回弹）
bool shouldDismissOnDrag(double dy, double threshold) => dy > threshold;
