/// 相册页数据层纯函数（条目 5 · 段 A，可单测）。
/// 契约（app/main.py:1689-1721 实读 / static/app.js:947-965 对照）：
/// · GET `/api/photos?album=<id>` → 只从 kind='post' 的 body.media 收集、
///   只 image/%、按记录 created 倒序、同一 mid 只留首次出现；
///   返回 {id,name,mime,owner,status,preview,record_id,date,caption}。
/// · 相册分类 = GET /api/records?kind=album 的记录（body.title 必填）。
/// · 两种视图：按相册分类（chips 筛选）/ 按时间（date 的 yyyy-MM 分组，
///   key 倒序、组内 date 倒序；无 date 归「还没有填日期」）。
library;

/// 一张照片（/api/photos 返回项）。
/// D 段起本模型也承载视频条目（mime=video/*，网格同一瓦片槽位渲染）：
/// · [album] 仅视频条目有值（来自记录 body.album，客户端按它筛相册）；
///   照片由服务端 /api/photos?album= 筛好，恒为空串；
/// · [preview] 视频条目无意义（瓦片走 /media/{mid}?poster=true 首帧）。
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
    this.album = '',
  });

  final String id;
  final String name;
  final String mime;
  final String status;
  final String preview;
  final String recordId;
  final String date; // post 的 body.date（发生日 yyyy-MM-dd）
  final String caption; // post 的 body.content
  final String album; // 视频条目的归属相册（body.album）；照片恒为 ''

  bool get isVideo => mime.startsWith('video/');

  factory PhotoItem.fromJson(Map<String, dynamic> j) => PhotoItem(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        mime: (j['mime'] ?? '').toString(),
        status: (j['status'] ?? '').toString(),
        preview: (j['preview'] ?? '').toString(),
        recordId: (j['record_id'] ?? '').toString(),
        date: (j['date'] ?? '').toString(),
        caption: (j['caption'] ?? '').toString(),
        album: (j['album'] ?? '').toString(),
      );
}

/// 相册分类（kind='album' 记录）
/// · [title] 来自 body.title（必填）；
/// · [cover] 来自 body.media[0]（封面照片 mid，方案③：mid 存于 body.media[0]）；
///   空串表示尚未设置封面（UI 走占位回退）。
class AlbumInfo {
  const AlbumInfo({required this.id, this.title = '', this.cover = ''});
  final String id;
  final String title;
  final String cover;

  factory AlbumInfo.fromRecord(Map<String, dynamic> j) {
    final body = (j['body'] ?? {}) as Map;
    final media = (body['media'] ?? []) as List?;
    final cover = media != null && media.isNotEmpty
        ? media.first.toString()
        : '';
    return AlbumInfo(
      id: (j['id'] ?? '').toString(),
      title: (body['title'] ?? '').toString(),
      cover: cover,
    );
  }
}

/// 相册编辑回填铁律（与时光段二 C buildEditBody 同语义）：
/// 编辑/设封面提交的 body **必须以服务器拉到的原始 body 为底**逐键复制
/// （含客户端不建模的字段、permitted 集内的未知字段），只覆盖实际改动的字段。
/// 服务端 clean_body 只留 permitted 字段且不合并旧 body，故客户端必须自行合并——
/// 绝不按字段表拼装新 body（那会丢掉未知字段）。
Map<String, dynamic> mergeAlbumBody(
    Map<String, dynamic> original, Map<String, dynamic> changes) {
  final body = <String, dynamic>{...original}; // 深拷贝顶层：未知字段全部存活
  body.addAll(changes); // 只覆盖实际改动的字段
  return body;
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

// ── D 段 · 视频专项（B-① 口径）────────────────────────────────────
// 数据源 = GET /api/records?kind=post&media_type=video（服务端遍历序列化
// media 筛 video/*，main.py:1205-1206 实读，与口径同语义；不用 /api/media/videos）。

/// 视频条目提取：序列化 post 记录列表 → video/* 媒体的 PhotoItem。
/// · mime 判定用记录级序列化 media 字段（{id,name,mime,size,status,preview}，
///   serializers.py:75 实读，无 duration 字段 → 时长本期无来源，瓦片只显示 ▶）；
/// · 记录序 = 服务端 created 倒序；同一 mid 只留首次出现（**最新记录优先**，
///   其 date/album/caption 生效——与 /api/photos 照片「同 mid 只留首次」口径一致）；
/// · date=body.date（发生日）、caption=body.content、album=body.album（归属）。
List<PhotoItem> parseVideos(Object? data) {
  if (data is! List) return const [];
  final out = <PhotoItem>[];
  final seen = <String>{};
  for (final e in data) {
    if (e is! Map) continue;
    final body = (e['body'] ?? {}) as Map;
    final media = (e['media'] ?? []) as List?;
    if (media == null) continue;
    final date = (body['date'] ?? '').toString();
    final caption = (body['content'] ?? '').toString();
    final album = (body['album'] ?? '').toString();
    for (final m in media) {
      if (m is! Map) continue;
      final mid = (m['id'] ?? '').toString();
      final mime = (m['mime'] ?? '').toString();
      if (mid.isEmpty || !mime.startsWith('video/')) continue;
      if (!seen.add(mid)) continue; // 同一 mid 只出现一次（最新记录优先）
      out.add(PhotoItem(
        id: mid,
        name: (m['name'] ?? '').toString(),
        mime: mime,
        status: (m['status'] ?? '').toString(),
        preview: (m['preview'] ?? '').toString(),
        recordId: (e['id'] ?? '').toString(),
        date: date,
        caption: caption,
        album: album,
      ));
    }
  }
  return out;
}

/// 按当前相册筛视频（照片由服务端 /api/photos?album= 筛，视频客户端按
/// body.album 筛——/api/records 无 album 参数）。空 albumId=全部照片视图。
List<PhotoItem> videosForAlbum(List<PhotoItem> videos, String albumId) =>
    albumId.isEmpty
        ? videos
        : videos.where((v) => v.album == albumId).toList();

/// 合并照片与视频为统一网格列表（与照片在同一网格按日期统一排序）：
/// · date 倒序；date 相同保持原相对序（照片先于视频，稳定）；
/// · 空 date 排最后（对齐时间视图「还没有填日期」组）；
/// · 跨类 mid 去重兜底（正常 image/video 不相交，纯保险）。
List<PhotoItem> mergePhotoVideo(List<PhotoItem> photos, List<PhotoItem> videos) {
  final merged = <PhotoItem>[...photos, ...videos];
  final seen = <String>{};
  final deduped = <PhotoItem>[
    for (final p in merged)
      if (p.id.isNotEmpty && seen.add(p.id)) p,
  ];
  final indexed = <int, PhotoItem>{
    for (var i = 0; i < deduped.length; i++) i: deduped[i],
  };
  final order = indexed.keys.toList()
    ..sort((a, b) {
      final da = indexed[a]!.date;
      final db = indexed[b]!.date;
      if (da.isEmpty != db.isEmpty) return da.isEmpty ? 1 : -1; // 空 date 最后
      final c = db.compareTo(da); // date 倒序（新在前）
      return c != 0 ? c : a.compareTo(b); // 稳定：原序（照片在前）
    });
  return [for (final i in order) indexed[i]!];
}
