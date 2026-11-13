/// 相册全屏查看器（条目 5 · 段 B · 甲档，返修版）。
/// · Hero 共享元素转场：网格缩略图 ↔ 查看器双向，Hero tag 跟随当前页
///   （翻页后返回落点 = 当前查看那张，不是最初点开那张）；
/// · 跨整个相册翻页：PageView 数据集 = 当前筛选下全部照片，首/末页不越界；
/// · 缩放/平移手势仲裁（本文件核心，见下方说明）：
///   - 双指捏合缩放 1~5×，连续可调；双击缩放（1×↔2.5×）保留；
///   - 缩放态（scale>1）单指拖动 = 平移局部，跟手，不被翻页/下拉抢走；
///   - 回到 1× 后横滑翻页与下拉关闭自动恢复；
/// · 下拉跟手关闭：位移跟手、背景渐暗；过阈值关闭且 **HeroMode 禁用**
///   （下拉关闭不触发返回转场，避免打架）；未过阈值弹回；
/// · 计数 n/N、caption/date、相邻图预加载；
/// · 下载走顶部通知（chatToastProvider / ChatToastHost），无底部 SnackBar。
///
/// ── 手势仲裁口径（最终版，返修定版）──
/// 冲突双方：外层下拉关闭（竖向拖拽 GestureDetector）、PageView（横滑翻页）、
/// 内层 InteractiveViewer（捏合缩放 + 单指平移）。
/// 关键：**_scale 是真实状态**，由 onInteractionEnd 在手势结束时结算
/// （读 TransformationController 最终值，不中途频繁 setState，避免重建抖动/
/// 丢手势），双击与翻页也同步结算。据此驱动三处：
///   1) InteractiveViewer.panEnabled = 缩放态(active&&_zoomed)——只有放大后才允许
///      单指平移，1× 时关掉，横滑交给 PageView；
///   2) PageView.physics = 缩放态或手势进行中 → NeverScrollable，否则 PageScroll；
///   3) 外层下拉拖拽识别器 = 缩放态或手势进行中 → 不挂载(null)，让 InteractiveViewer
///      完整接管手势（否则竖向拖拽会与平移打架）。
/// 这样：1× 时横滑翻页、竖滑下拉、双击放大都正常；放大后单指平移跟手、双指继续
/// 调倍、横滑/下拉被锁；捏合回 1× 后翻页/下拉恢复。
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

  /// 缩放手势进行中（onInteractionStart→true，onInteractionEnd→false）。
  /// 用于手势期间锁住 PageView 横滑与下拉关闭，避免翻页/下拉抢手势。
  bool _interacting = false;

  /// 当前缩放倍率（真实状态）：onInteractionEnd 结算 / 双击 / 翻页 同步。
  /// 驱动 panEnabled、PageView 物理、下拉识别器三处仲裁。
  double _scale = 1.0;

  static const double _dismissThreshold = 110.0;
  static const double _maxScale = 5.0;

  String get _base => ref.watch(chatBaseProvider).valueOrNull ?? '';
  Map<String, String>? get _headers =>
      ref.watch(mediaCookieHeadersProvider).valueOrNull;

  /// 缩放态：放大超过 1× 即视为「已放大」，解锁单指平移、锁住翻页与下拉。
  bool get _zoomed => _scale > 1.01;

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
      _interacting = false;
    });
    // 翻页即通知网格预滚动：pop 时 Hero 落回「当前查看那张」而非最初点开那张
    ref.read(albumViewerIndexProvider.notifier).state = i;
    _preloadNeighbors();
  }

  /// 缩放/平移手势开始：锁住翻页与下拉（期间 PageView 不可翻、下拉不可触发）。
  void _onScaleStart() => setState(() => _interacting = true);

  /// 缩放/平移手势结束：结算最终倍率（读 controller 值），据此切换 panEnabled
  /// 与翻页/下拉仲裁。**只在手势结束时 setState 一次**，避免手势进行中频繁重建
  /// 导致 InteractiveViewer 丢手势/抖动。
  void _onScaleEnd() => setState(() {
        _scale = _zoom.value.getMaxScaleOnAxis();
        _interacting = false;
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
      _interacting = false;
    });
  }

  /// 下拉跟手：仅未缩放且非手势进行中时启用；位移跟手 + 背景渐暗
  void _onDragUpdate(DragUpdateDetails d) {
    if (_zoomed || _interacting) return;
    setState(() {
      _dragging = true;
      _dragDy = (_dragDy + d.delta.dy).clamp(0.0, double.infinity);
    });
  }

  void _onDragEnd(DragEndDetails d) {
    if (!_dragging) return;
    if (shouldDismissOnDrag(_dragDy, _dismissThreshold) ||
        (d.velocity.pixelsPerSecond.dy > 700 && _dragDy > 40)) {
      // 下拉关闭：先禁用 Hero 再 pop，避免下拉动画与 Hero 返回转场互相打架
      setState(() => _dragDismiss = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop(_index);
      });
      return;
    }
    // 未过阈值：回弹
    setState(() {
      _dragging = false;
      _dragDy = 0;
    });
  }

  void _onDragCancel() {
    setState(() {
      _dragging = false;
      _dragDy = 0;
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
    // 缩放态或手势进行中：PageView 锁翻页、下拉拖拽识别器不挂载（让 InteractiveViewer 接管）
    final gestureLocked = _zoomed || _interacting;
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 1 - dragProgress),
      body: Stack(children: [
        // 全屏图片区（下拉位移跟手）
        Positioned.fill(
          child: Transform.translate(
            offset: Offset(0, _dragDy),
            child: GestureDetector(
              // 缩放/手势进行中：不挂载下拉识别器，避免与 InteractiveViewer 平移打架
              onVerticalDragUpdate: gestureLocked ? null : _onDragUpdate,
              onVerticalDragEnd: gestureLocked ? null : _onDragEnd,
              onVerticalDragCancel: gestureLocked ? null : _onDragCancel,
              onDoubleTap: _onDoubleTap,
              behavior: HitTestBehavior.opaque,
              child: HeroMode(
                enabled: heroEnabled,
                child: PageView.builder(
                  controller: _page,
                  itemCount: widget.photos.length,
                  // 缩放/手势进行中锁翻页；否则正常横滑翻页
                  physics: gestureLocked
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
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
/// 缩放/平移手势仲裁：panEnabled 仅在「当前页且缩放态」开启（1× 关闭，横滑交
/// 给 PageView）；onInteractionStart/End 在手势边界结算 _scale（见上层说明）。
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
      // 仅当前页 + 缩放态允许单指平移；1× 时关闭，横滑翻页交给 PageView
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
