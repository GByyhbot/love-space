/// 相册全屏查看器（条目 5 · 段 B · 甲档，第二轮返修）。
/// · Hero 共享元素转场：网格缩略图 ↔ 查看器双向，Hero tag 跟随当前页
///   （翻页后返回落点 = 当前查看那张，不是最初点开那张）；
/// · 跨整个相册翻页：PageView 数据集 = 当前筛选下全部照片，首/末页不越界；
/// · 缩放/平移手势仲裁（返修核心，见下方说明）：
///   - 1× 直接双指外拉即可连续放大（不需双击前置）；双指内缩回 1×；
///   - 放大态（scale>1）单指拖动 = 平移局部，跟手；
///   - 1× 单指横滑翻页、单指竖滑下拉关闭、双击缩放，全部照旧；
/// · 下拉跟手关闭：位移跟手、背景渐暗；过阈值关闭且 **HeroMode 禁用**
///   （下拉关闭不触发返回转场，避免打架）；未过阈值弹回；
/// · 计数 n/N、caption/date、相邻图预加载；
/// · 下载走顶部通知（chatToastProvider / ChatToastHost），无底部 SnackBar。
///
/// ── 手势仲裁口径（第二轮返修定版，根因）──
/// 上一轮把 panEnabled 写死 false + _zoomed 不响应 controller 变化 → 放大后不能平移
/// （已修）；但复验发现「1× 捏合完全无反应、须先双击」：根因是查看器外层叠了两个
/// 单指拖拽识别器与 InteractiveViewer 的多指 Scale 抢竞技场——外层下拉关闭的
/// VerticalDragGestureRecognizer + PageView 的 HorizontalDragGestureRecognizer 会在
/// 第二根手指落下前认领第一指的初始位移而抢先胜出，scale 无法组形。放大后这两个识别器
/// 被卸载/禁用，捏合才生效，故「必须先双击」。
/// 本轮修法：**PageView 改为永远 NeverScrollable（彻底移除翻页拖拽这个竞争者），翻页与
/// 下拉关闭都改为非竞技场的 Listener 手动跟踪**（单指横滑→animateToPage；单指竖滑→
/// 下拉关闭）。这样 1× 时竞技场只剩 InteractiveViewer 的 scale（pan 在 1× 关闭），捏合
/// 无竞争者必然生效。双击缩放、放大态单指平移、缩回 1× 后翻页/下拉恢复均不变。
library;

import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart' show Options, ResponseType;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/album/album_data.dart';
import '../../core/api/api_client.dart';
import '../../core/chat/chat_media.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../timeline/image_viewer.dart' show mediaFileExtension;
import 'album_controller.dart';

class AlbumViewerPage extends ConsumerStatefulWidget {
  const AlbumViewerPage({
    super.key,
    required this.photos,
    this.initialIndex = 0,
  });
  final List<PhotoItem> photos;
  final int initialIndex;

  @override
  ConsumerState<AlbumViewerPage> createState() => _AlbumViewerPageState();
}

class _AlbumViewerPageState extends ConsumerState<AlbumViewerPage> {
  late int _index = widget.initialIndex.clamp(0, widget.photos.length - 1);
  late final PageController _page = PageController(initialPage: _index);
  final TransformationController _zoom = TransformationController();
  double _dragDy = 0;
  bool _dragging = false;
  bool _dragDismiss = false; // 下拉关闭中：禁用 Hero，避免与返回转场打架
  bool _saving = false;

  /// 当前缩放倍率（真实状态）：onInteractionEnd 结算 / 双击 / 翻页 同步。
  double _scale = 1.0;

  /// 落在查看器上的活动指针数（Listener 跟踪）。>=2 表示多指（捏合中）→
  /// 关闭单指横滑翻页 / 竖滑下拉，避免与缩放抢手势。
  int _pointers = 0;
  int? _primaryId;          // 首根指针 id（用于计算横滑/下拉位移）
  Offset _primaryStart = Offset.zero;

  static const double _dismissThreshold = 110.0;
  static const double _swipeThreshold = 80.0;
  static const double _maxScale = 5.0;

  String get _base => ref.watch(chatBaseProvider).valueOrNull ?? '';
  Map<String, String>? get _headers =>
      ref.watch(mediaCookieHeadersProvider).valueOrNull;

  /// 缩放态：放大超过 1× 即视为「已放大」，解锁单指平移、锁翻页/下拉。
  bool get _zoomed => _scale > 1.01;

  /// 单指 + 未缩放：才允许 Listener 横滑翻页 / 竖滑下拉（多指捏合或已缩放时关闭，
  /// 让 InteractiveViewer 完整接管手势）。
  bool get _allowSingleDrag => _pointers == 1 && !_zoomed;

  PhotoItem get _current => widget.photos[_index];

  @override
  void initState() {
    super.initState();
    // 初始索引写入：网格页据此预滚动（首帧前先对齐）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(albumViewerIndexProvider.notifier).state = _index;
      _preloadNeighbors();
    });
  }

  @override
  void dispose() {
    _page.dispose();
    _zoom.dispose();
    super.dispose();
  }

  /// 相邻预加载：用同一个 CachedNetworkImageProvider（URL + Cookie 头），
  /// 让快速翻页时前后两张已在缓存中，不长时间白屏。
  void _preloadNeighbors() {
    if (!mounted || _base.isEmpty) return;
    for (final i in [_index - 1, _index + 1]) {
      if (i < 0 || i >= widget.photos.length) continue;
      final p = widget.photos[i];
      precacheImage(
        CachedNetworkImageProvider(mediaUrl(_base, p.id), headers: _headers),
        context,
      ).catchError((_) {});
    }
  }

  void _onPageChanged(int i) {
    setState(() {
      _index = i;
      _zoom.value = Matrix4.identity(); // 翻页复位缩放
      _scale = 1.0;
    });
    // 翻页即通知网格预滚动：pop 时 Hero 落回「当前查看那张」而非最初点开那张
    ref.read(albumViewerIndexProvider.notifier).state = i;
    _preloadNeighbors();
  }

  /// 缩放/平移手势开始：占位回调。翻页/下拉的锁已由 _allowSingleDrag
  /// （_pointers==1 && !_zoomed）在 Listener 层统一处理，无需在此额外状态。
  void _onScaleStart() {}

  /// 缩放/平移手势结束：结算最终倍率（读 controller 值），据此切换 panEnabled
  /// 与翻页/下拉仲裁。**只在手势结束时 setState 一次**，避免手势进行中频繁重建
  /// 导致 InteractiveViewer 丢手势/抖动。
  void _onScaleEnd() => setState(() {
        _scale = _zoom.value.getMaxScaleOnAxis();
      });

  /// 双击：未缩放 → 2.5×（围绕视口中心）；已缩放 → 复位 1×。同步 _scale 仲裁。
  void _onDoubleTap() {
    final size = MediaQuery.sizeOf(context);
    setState(() {
      if (_zoomed) {
        _zoom.value = Matrix4.identity();
        _scale = 1.0;
      } else {
        _zoom.value = Matrix4.fromList(
            zoomMatrixAroundCenter(2.5, size.width, size.height));
        _scale = 2.5;
      }
    });
  }

  // ── 非竞技场 Listener：跟踪指针，实现 1× 横滑翻页 / 竖滑下拉关闭 ──
  // Listener 不参与手势竞技场，因此不会抢走 InteractiveViewer 的 scale/pan，
  // 也不与（已设为 NeverScrollable 的）PageView 抢翻页。
  void _onPointerDown(PointerDownEvent e) {
    _pointers++;
    if (_pointers == 1) {
      _primaryId = e.pointer;
      _primaryStart = e.position;
      _dragging = false;
      _dragDy = 0;
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_allowSingleDrag) return; // 多指捏合或已缩放：交给 InteractiveViewer
    if (e.pointer != _primaryId) return;
    final dx = e.position.dx - _primaryStart.dx;
    final dy = e.position.dy - _primaryStart.dy;
    if (dy.abs() > dx.abs()) {
      // 以竖向为主 → 下拉关闭位移（仅向下跟手）
      setState(() {
        _dragging = true;
        _dragDy = dy.clamp(0.0, double.infinity);
      });
    } else if (_dragging) {
      // 横滑为主 → 取消下拉位移（翻页交给 onPointerUp）
      setState(() {
        _dragDy = 0;
        _dragging = false;
      });
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    final wasPrimary = e.pointer == _primaryId;
    _pointers = _pointers > 0 ? _pointers - 1 : 0;
    if (!wasPrimary) return;
    if (_pointers == 0) _primaryId = null;
    if (!_allowSingleDrag && _pointers != 0) return;
    final dx = e.position.dx - _primaryStart.dx;
    final dy = e.position.dy - _primaryStart.dy;
    if (_pointers == 0 && !_zoomed) {
      // 单指手势结束：判定横滑翻页 or 下拉关闭
      if (dx.abs() > dy.abs() && dx.abs() > _swipeThreshold) {
        final target = (_index + (dx < 0 ? 1 : -1))
            .clamp(0, widget.photos.length - 1);
        if (target != _index) {
          _page.animateToPage(target,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut);
        }
      } else if (dy > _dismissThreshold) {
        _triggerDismiss();
      }
    }
    setState(() {
      _dragging = false;
      _dragDy = 0;
    });
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _pointers = _pointers > 0 ? _pointers - 1 : 0;
    if (e.pointer == _primaryId) _primaryId = null;
    setState(() {
      _dragging = false;
      _dragDy = 0;
    });
  }

  /// 下拉关闭：先禁用 Hero 再 pop，避免下拉动画与 Hero 返回转场互相打架
  void _triggerDismiss() {
    setState(() => _dragDismiss = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(_index);
    });
  }

  /// 下载原文件 → downloads/，结果走顶部通知
  Future<void> _download() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final dio = await ref.read(dioProvider.future);
      final mid = _current.id;
      final rsp = await dio.get<List<int>>('/media/$mid',
          queryParameters: {'download': 'true'},
          options: Options(responseType: ResponseType.bytes));
      final dir = await getApplicationDocumentsDirectory();
      final downloads = Directory('${dir.path}${Platform.pathSeparator}downloads');
      if (!await downloads.exists()) await downloads.create(recursive: true);
      final ext = mediaFileExtension(_current.mime);
      final path =
          '${downloads.path}${Platform.pathSeparator}$mid$ext';
      await File(path).writeAsBytes(rsp.data ?? const []);
      if (mounted) {
        ref.read(chatToastProvider.notifier).show(
            '已保存到本地：downloads/$mid$ext',
            tone: ChatToastTone.success);
      }
    } catch (e) {
      if (mounted) {
        ref.read(chatToastProvider.notifier).show(
            '下载失败：${errorDetail(e)}', tone: ChatToastTone.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dragProgress = (_dragDy / (size.height * 0.5)).clamp(0.0, 0.6);
    // 下拉过程中禁用 Hero 参与：返回时由 HeroMode 统一控制，
    // 下拉关闭走禁用态（不飞回），按钮/手势返回走启用态（飞回当前缩略图）
    final heroEnabled = !_dragDismiss;
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 1 - dragProgress),
      body: Stack(children: [
        // 全屏图片区（下拉位移跟手）。Listener 非竞技场：跟踪指针实现
        // 1× 横滑翻页 / 竖滑下拉；不参与竞技场，不抢 InteractiveViewer 的缩放。
        Positioned.fill(
          child: Transform.translate(
            offset: Offset(0, _dragDy),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerCancel,
              child: GestureDetector(
                // 仅双击缩放；不与 pinch/pan/翻页抢手势（双击=两次 1 指轻点，
                // 与 scale/横滑竖滑互不冲突）
                onDoubleTap: _onDoubleTap,
                behavior: HitTestBehavior.opaque,
                child: HeroMode(
                  enabled: heroEnabled,
                  // PageView 永远不可拖拽翻页（移除翻页拖拽这个竞技场竞争者），
                  // 翻页改由 Listener 单指横滑 animateToPage 实现
                  child: PageView.builder(
                    controller: _page,
                    itemCount: widget.photos.length,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: _onPageChanged,
                    itemBuilder: (_, i) => _PhotoPage(
                      key: ValueKey(widget.photos[i].id),
                      photo: widget.photos[i],
                      base: _base,
                      headers: _headers,
                      zoom: _zoom,
                      active: i == _index,
                      heroEnabled: heroEnabled,
                      maxScale: _maxScale,
                      zoomed: i == _index && _zoomed,
                      onScaleStart: _onScaleStart,
                      onScaleEnd: _onScaleEnd,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // 顶部计数条
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            child: Opacity(
              opacity: _dragging ? 1 - dragProgress : 1,
              child: Row(children: [
                IconButton(
                  tooltip: '返回',
                  icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(_index),
                ),
                Text('${_index + 1} / ${widget.photos.length}',
                    style: const TextStyle(color: Colors.white, fontSize: 15)),
                const Spacer(),
                IconButton(
                  tooltip: '下载原文件',
                  onPressed: _saving ? null : _download,
                  icon: _saving
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.download_rounded, color: Colors.white),
                ),
              ]),
            ),
          ),
        ),
        // 底部 caption / date
        if (!_dragging)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                color: Colors.black.withValues(alpha: 0.45),
                child: Text(
                  _current.caption.isNotEmpty
                      ? _current.caption
                      : (_current.date.isNotEmpty
                          ? _current.date
                          : '属于我们的瞬间'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
          ),
        // 顶部通知：App 根部全局 ChatToastHost 承载（builder 在 Navigator
        // 之上，覆盖全屏查看器），本页不再单独挂宿主，避免一条通知渲染两遍。
      ]),
    );
  }
}

/// 单页大图：仅当前页挂 Hero（tag 跟随当前照片 → 翻页后返回落点正确），
/// 相邻页只做预渲染不带 Hero，避免重复 tag 导致转场 abort。
/// 缩放/平移手势仲裁：panEnabled 仅在「当前页且缩放态」开启（1× 关闭，横滑翻页
/// 交给 Listener）；onInteractionStart/End 在手势边界结算 _scale（见上层说明）。
class _PhotoPage extends StatelessWidget {
  const _PhotoPage({
    super.key,
    required this.photo,
    required this.base,
    required this.headers,
    required this.zoom,
    required this.active,
    required this.heroEnabled,
    required this.maxScale,
    required this.zoomed,
    required this.onScaleStart,
    required this.onScaleEnd,
  });
  final PhotoItem photo;
  final String base;
  final Map<String, String>? headers;
  final TransformationController zoom;
  final bool active;
  final bool heroEnabled;
  final double maxScale;
  final bool zoomed;
  final VoidCallback onScaleStart;
  final VoidCallback onScaleEnd;

  @override
  Widget build(BuildContext context) {
    final image = CachedNetworkImage(
      imageUrl: mediaUrl(base, photo.id),
      httpHeaders: headers,
      fit: BoxFit.contain,
      width: double.infinity,
      height: double.infinity,
      fadeInDuration: const Duration(milliseconds: 180),
      placeholder: (_, _) => const Center(
          child: CircularProgressIndicator(color: Colors.white54)),
      errorWidget: (_, _, _) => const Center(
          child: Icon(Icons.broken_image_outlined,
              color: Colors.white54, size: 44)),
    );
    return InteractiveViewer(
      transformationController: active ? zoom : null,
      minScale: 1,
      maxScale: maxScale,
      scaleEnabled: true,
      // 仅当前页 + 缩放态允许单指平移；1× 时关闭，横滑翻页交给 Listener
      panEnabled: active && zoomed,
      onInteractionStart: active ? (_) => onScaleStart() : null,
      onInteractionEnd: active ? (_) => onScaleEnd() : null,
      child: Center(
        child: active
            ? HeroMode(
                enabled: heroEnabled,
                child: Hero(
                    tag: albumHeroTag(photo.id),
                    child: image))
            : image,
      ),
    );
  }
}
