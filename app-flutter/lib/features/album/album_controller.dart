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
}

final albumControllerProvider =
    NotifierProvider<AlbumController, AlbumState>(AlbumController.new);

/// 查看器当前页索引（条目 5 · 段 B）：查看器翻页时写入，网格页监听后
/// **在查看器仍打开时预滚动**到该照片位置——保证 pop 时 Hero 飞回的
/// 目标缩略图已在视口内（否则 Hero 找不到目标会退化淡出、闪黑/跳图）。
/// 索引按「当前筛选下的 photos 列表」计，与网格数据源一致。
final albumViewerIndexProvider = StateProvider<int>((ref) => 0);
