/// 相册页状态与控制器（条目 5 · 段 A）。
/// · 照片走 GET `/api/photos?album=<id>`（服务端筛选，避免整表 join）；
/// · 分类走 GET /api/records?kind=album&limit=200；
/// · 两视图（按相册分类 / 按时间月份分组）共用同一份 photos，切视图不重拉；
/// · 状态挂 keepAlive Notifier（IndexedStack 常驻，切 tab 不丢筛选）；
/// · SSE other 且相册 tab 激活 → reset 重拉（对齐 Web refresh）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/album/album_data.dart';

enum AlbumView { byAlbum, byTime }

class AlbumState {
  const AlbumState({
    this.photos = const [],
    this.albums = const [],
    this.selectedAlbum = '', // 空=全部照片
    this.view = AlbumView.byAlbum,
    this.loading = false,
    this.skeleton = false,
    this.error,
  });
  final List<PhotoItem> photos;
  final List<AlbumInfo> albums;
  final String selectedAlbum;
  final AlbumView view;
  final bool loading;
  final bool skeleton; // 首屏骨架（仅首次拉取）
  final String? error;

  AlbumState copyWith({
    List<PhotoItem>? photos,
    List<AlbumInfo>? albums,
    String? selectedAlbum,
    AlbumView? view,
    bool? loading,
    bool? skeleton,
    String? error,
  }) =>
      AlbumState(
        photos: photos ?? this.photos,
        albums: albums ?? this.albums,
        selectedAlbum: selectedAlbum ?? this.selectedAlbum,
        view: view ?? this.view,
        loading: loading ?? this.loading,
        skeleton: skeleton ?? this.skeleton,
        error: error,
      );
}

class AlbumController extends Notifier<AlbumState> {
  bool _disposed = false;
  bool _loaded = false;
  bool _skeletonSeen = false;
  /// 请求代次：快速连点分类 chips 时旧响应不得写 state（时光页 QA4 同款坑）
  int _reqSeq = 0;

  @override
  AlbumState build() {
    ref.onDispose(() => _disposed = true);
    return const AlbumState();
  }

  /// 进入页面初始化（换号/首次进页拉首屏）
  Future<void> bootstrap() async {
    if (!_loaded) await load();
  }

  /// 拉取照片 + 分类（reset=true 用于筛选变更/SSE 重拉）
  Future<void> load() async {
    if (_disposed) return;
    final seq = ++_reqSeq;
    final album = state.selectedAlbum; // 捕获本次筛选，防 await 期间被改
    state = state.copyWith(loading: true, error: null,
        skeleton: !_skeletonSeen);
    try {
      final dio = await ref.read(api.dioProvider.future);
      final photosR = await dio.get('/api/photos', queryParameters: {
        if (album.isNotEmpty) 'album': album,
      });
      final albumsR = await dio.get('/api/records',
          queryParameters: {'kind': 'album', 'limit': 200});
      if (_disposed || seq != _reqSeq) return; // 旧响应失效
      state = state.copyWith(
        photos: parsePhotos(photosR.data),
        albums: parseAlbumRecords(albumsR.data),
      );
      _skeletonSeen = true;
      state = state.copyWith(loading: false, skeleton: false);
    } catch (e) {
      _skeletonSeen = true;
      if (!_disposed && seq == _reqSeq) {
        state = state.copyWith(loading: false, skeleton: false,
            error: api.errorDetail(e));
      }
    }
    _loaded = true;
  }

  /// 切换相册筛选（空=全部照片）→ reset 重拉
  Future<void> selectAlbum(String id) async {
    if (state.selectedAlbum == id) return;
    if (!_disposed) state = state.copyWith(selectedAlbum: id);
    await load();
  }

  /// 切换视图（按相册分类 / 按时间）：共用 photos，不重拉、不丢筛选
  void setView(AlbumView view) {
    if (_disposed || state.view == view) return;
    state = state.copyWith(view: view);
  }

  /// SSE other（相册 tab 激活时由页面调用）：reset 重拉
  Future<void> resetOnSseOther() async {
    if (_loaded) await load();
  }

  /// 分类 chip 显示名（空=全部照片）
  String albumTitle(String id) {
    if (id.isEmpty) return '全部照片';
    for (final a in state.albums) {
      if (a.id == id) return a.title;
    }
    return '相册';
  }

  // ── 段 C · 增删改与封面 ──────────────────────────────────────
  // 后端契约（app/main.py）：clean_body 只留 permitted 字段且**不合并**旧 body，
  // 故编辑/设封面必须以服务器原始 body 为底合并后 PUT 全量（回填铁律）；
  // DELETE album 服务端自动清掉引用该相册的记录的 body.album（软删）。
  // 全部方法返回 null=成功，否则为错误文案。

  /// 新建相册：POST kind='album'，title 必填（服务端亦校验）。
  /// 成功后重拉分类列表（新 chip 出现）。返回 null=成功。
  Future<String?> createAlbum(String title) async {
    final t = title.trim();
    if (t.isEmpty) return '相册名称不能为空';
    if (_disposed) return null;
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.post('/api/records', data: {
        'kind': 'album',
        'body': {'title': t},
      });
      if ((r.statusCode ?? 500) >= 400) {
        final d = r.data;
        if (d is Map && d['detail'] != null) return d['detail'].toString();
        return '创建失败，请重试';
      }
      await _reloadAlbums(); // 新相册入列表，chip 立即出现
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// 拉取单条记录原始 body（回填铁律的底）。失败/不存在返回 null。
  Future<Map<String, dynamic>?> _fetchAlbumBody(String id) async {
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.get('/api/records/$id');
      if (r.data is Map) {
        final body = (r.data as Map)['body'];
        if (body is Map) {
          return Map<String, dynamic>.from(body.cast<String, dynamic>());
        }
      }
    } catch (_) {
      // 404 / 网络异常：交由调用方判空
    }
    return null;
  }

  /// 相册改名：GET 原始 body → 以底合并 {title} → PUT 全量。
  /// 回填铁律：未知字段与封面（body.media）一律原样带回。
  Future<String?> renameAlbum(String id, String title) async {
    final t = title.trim();
    if (t.isEmpty) return '相册名称不能为空';
    if (_disposed) return null;
    final original = await _fetchAlbumBody(id);
    if (original == null) return '相册不存在或已删除';
    final body = mergeAlbumBody(original, {'title': t});
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.put('/api/records/$id', data: {
        'kind': 'album',
        'body': body,
      });
      if ((r.statusCode ?? 500) >= 400) {
        final d = r.data;
        if (d is Map && d['detail'] != null) return d['detail'].toString();
        return '保存失败，请重试';
      }
      await _reloadAlbums();
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// 设封面：把 [mid] 置到 body.media[0]（方案③）。
  /// 回填铁律：保留 media 中其余元素（若有）与全部未知字段；[mid] 为空则清空封面。
  Future<String?> setCover(String id, String mid) async {
    if (_disposed) return null;
    final original = await _fetchAlbumBody(id);
    if (original == null) return '相册不存在或已删除';
    final oldMedia = List<String>.from(
        ((original['media'] as List?) ?? [])
            .whereType<dynamic>()
            .map((e) => e.toString()));
    final m = mid.trim();
    if (m.isEmpty) {
      oldMedia.clear(); // 清空封面（无封面回退）
    } else {
      oldMedia.removeWhere((x) => x == m); // 若已在尾部则先移除，避免重复
      oldMedia.insert(0, m); // 置顶为封面
    }
    final body = mergeAlbumBody(original, {'media': oldMedia});
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.put('/api/records/$id', data: {
        'kind': 'album',
        'body': body,
      });
      if ((r.statusCode ?? 500) >= 400) {
        final d = r.data;
        if (d is Map && d['detail'] != null) return d['detail'].toString();
        return '设置封面失败，请重试';
      }
      await _reloadAlbums();
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// 删除相册：DELETE（软删，服务端自动清掉引用该相册的记录的归属）。
  /// 客户端删后切回「全部照片」视图并重拉（照片仍在，归属已清）。
  Future<String?> deleteAlbum(String id) async {
    if (_disposed) return null;
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.delete('/api/records/$id');
      if ((r.statusCode ?? 500) >= 400) {
        final d = r.data;
        if (d is Map && d['detail'] != null) return d['detail'].toString();
        return '删除失败，请重试';
      }
      // 切回全部照片（selectedAlbum=''）后整页重拉：photos 全量回显、
      // albums 自动剔除已删相册（load 同时拉分类）。
      if (!_disposed) state = state.copyWith(selectedAlbum: '');
      await load();
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// 仅重拉分类列表（新建/改名/设封面后刷新 chip 与封面，不重拉照片）。
  Future<void> _reloadAlbums() async {
    if (_disposed) return;
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.get('/api/records',
          queryParameters: {'kind': 'album', 'limit': 200});
      if (!_disposed) {
        state = state.copyWith(albums: parseAlbumRecords(r.data));
      }
    } catch (_) {
      // 分类刷新失败不阻断主流程：下次 load 自然会重拉
    }
  }
}

final albumControllerProvider =
    NotifierProvider<AlbumController, AlbumState>(AlbumController.new);

/// 查看器当前页索引（条目 5 · 段 B）：查看器翻页时写入，网格页监听后
/// **在查看器仍打开时预滚动**到该照片位置——保证 pop 时 Hero 飞回的
/// 目标缩略图已在视口内（否则 Hero 找不到目标会退化淡出、闪黑/跳图）。
/// 索引按「当前筛选下的 photos 列表」计，与网格数据源一致。
final albumViewerIndexProvider = StateProvider<int>((ref) => 0);
