/// 相册页（条目 5 · 段 A 页与网格 + 段 B 查看器联动）：
/// heading + 两视图 + 分类 chips + 3 列网格（preview=true + Cookie 头 +
/// 占位色渐显）+ 空态两套 + 骨架 + SSE other 重拉。
/// 段 B：缩略图 Hero tag ↔ 查看器双向；查看器翻页时通过 albumViewerIndexProvider
/// 通知本页**预滚动**到当前查看那张，保证返回时 Hero 落点正确（不闪黑/不跳图）。
/// 顶部通知由 App 根部全局 ChatToastHost 统一承载（本页不再单独挂宿主）。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/album/album_data.dart';
import '../../core/chat/chat_media.dart';
import '../../core/sse/sse_client.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'album_controller.dart';
import 'album_cover_tile.dart';
import '../timeline/composer_sheet.dart';

/// 网格缩略图尺寸（3 列）：cell = (屏宽 - 左右 32 - 两道 8) / 3
double albumCellSize(double screenWidth) => (screenWidth - 32 - 16) / 3;

class AlbumPage extends ConsumerStatefulWidget {
  const AlbumPage({super.key, required this.active});
  final bool active; // 当前 tab 是否为相册（SSE other 只在激活时重拉）

  @override
  ConsumerState<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends ConsumerState<AlbumPage> {
  final ScrollController _gridScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() =>
        ref.read(albumControllerProvider.notifier).bootstrap());
  }

  @override
  void dispose() {
    _gridScroll.dispose();
    super.dispose();
  }

  /// 段 B：查看器翻页 → 网格在后台预滚动到该照片（无动画，避免与 Hero 打架）。
  /// 只在 3 列网格视图且滚动控制器已挂载时生效；按时间视图用 ensureVisible 的
  /// 等价偏移（列表分组高度不固定，采用行偏移近似，误差 ≤ 一行）。
  void _scrollToViewerIndex(int index) {
    if (!_gridScroll.hasClients) return;
    final st = ref.read(albumControllerProvider);
    if (st.photos.isEmpty) return;
    final cell = albumCellSize(MediaQuery.sizeOf(context).width);
    final offset = albumGridScrollOffset(
      index.clamp(0, st.photos.length - 1),
      cellSize: cell,
      spacing: 8,
      viewportHeight: _gridScroll.position.viewportDimension,
      maxScrollExtent: _gridScroll.position.maxScrollExtent,
    );
    _gridScroll.jumpTo(offset);
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(albumControllerProvider);
    // SSE other 且相册 tab 激活 → reset 重拉（对方上传/删除照片后刷出）
    ref.listen(sseEventsProvider, (prev, next) {
      final ev = next.value;
      if (widget.active && (ev?.other == true || ev?.refresh == true)) {
        ref.read(albumControllerProvider.notifier).resetOnSseOther();
      }
    });
    // 查看器翻页索引 → 预滚动（查看器仍打开时就对齐，pop 时 Hero 目标已在视口）
    ref.listen(albumViewerIndexProvider, (prev, next) {
      if (widget.active && st.view == AlbumView.byAlbum) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scrollToViewerIndex(next);
        });
      }
    });

    return SafeArea(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        floatingActionButton: FloatingActionButton(
          tooltip: '上传照片',
          onPressed: () => _openUpload(context, st.selectedAlbum),
          child: const Icon(Icons.add_a_photo_rounded),
        ),
        body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _heading(context),
          _viewTabs(context, st),
          if (st.view == AlbumView.byAlbum) _albumCoverRow(context, st),
          Expanded(child: _body(context, st)),
        ]),
      ),
    );
  }

  /// 上传照片：FAB 打开官方 composer，预填当前相册（全部照片视图不预填）。
  /// 复用时光段二 composer 全链路：本地暂存 / client_id 幂等 / 顶部通知。
  void _openUpload(BuildContext context, String selectedAlbum) {
    showComposerSheet(context, initialAlbum: selectedAlbum);
  }

  Widget _heading(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('把喜欢的瞬间，装进口袋', style: theme.textTheme.headlineSmall),
        Text('每一张照片，都是我们走过的日子。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline)),
      ]),
    );
  }

  Widget _viewTabs(BuildContext context, AlbumState st) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: SegmentedButton<AlbumView>(
        segments: const [
          ButtonSegment(
              value: AlbumView.byAlbum,
              icon: Icon(Icons.photo_library_outlined, size: 16),
              label: Text('按相册分类')),
          ButtonSegment(
              value: AlbumView.byTime,
              icon: Icon(Icons.calendar_month_outlined, size: 16),
              label: Text('按时间')),
        ],
        selected: {st.view},
        showSelectedIcon: false,
        style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            textStyle: WidgetStateProperty.all(theme.textTheme.labelMedium)),
        onSelectionChanged: (s) => ref
            .read(albumControllerProvider.notifier)
            .setView(s.first),
      ),
    );
  }

  /// 相册入口（段 C）：横向滚动的封面卡网格——「全部照片」卡 + 各相册封面卡
  /// （LowFreqCache 单槽位显示封面，无封面走占位回退）+「+ 新建相册」卡。
  /// 每张相册卡带 ⋯ 菜单（改名/删除）；点卡进入该相册；点「全部照片」回到全部。
  Widget _albumCoverRow(BuildContext context, AlbumState st) {
    final theme = Theme.of(context);
    final base = ref.watch(chatBaseProvider).valueOrNull ?? '';
    final headers = ref.watch(mediaCookieHeadersProvider).valueOrNull;
    final controller = ref.read(albumControllerProvider.notifier);
    final cards = <Widget>[
      _allPhotosCard(theme, st.selectedAlbum.isEmpty, () => controller.selectAlbum('')),
    ];
    for (final a in st.albums) {
      cards.add(_albumCoverCard(
        theme,
        album: a,
        base: base,
        headers: headers,
        selected: st.selectedAlbum == a.id,
        onTap: () => controller.selectAlbum(a.id),
        onRename: () => _showRenameDialog(context, a),
        onDelete: () => _showDeleteConfirm(context, a),
      ));
    }
    cards.add(_createCard(theme, () => _showCreateAlbumDialog(context)));
    return SizedBox(
      height: 132,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        scrollDirection: Axis.horizontal,
        itemCount: cards.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) => cards[i],
      ),
    );
  }

  Widget _allPhotosCard(ThemeData theme, bool selected, VoidCallback onTap) {
    final cs = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 100,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: selected ? cs.primaryContainer : cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected ? cs.primary : cs.outlineVariant),
        ),
        child: Column(children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: selected ? cs.onPrimaryContainer.withValues(alpha: 0.08) : cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Icon(Icons.photo_library_rounded,
                    size: 28, color: selected ? cs.primary : cs.outline),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text('全部照片',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                  color: selected ? cs.onPrimaryContainer : cs.outline)),
        ]),
      ),
    );
  }

  Widget _albumCoverCard(
    ThemeData theme, {
    required AlbumInfo album,
    required String base,
    required Map<String, String>? headers,
    required bool selected,
    required VoidCallback onTap,
    required VoidCallback onRename,
    required VoidCallback onDelete,
  }) {
    final cs = theme.colorScheme;
    final coverPlaceholder = Container(
      color: cs.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(Icons.photo_album_rounded, size: 28, color: cs.outline),
    );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 100,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: selected ? cs.primaryContainer : cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected ? cs.primary : cs.outlineVariant),
        ),
        child: Column(children: [
          Expanded(
            child: Stack(children: [
              AlbumCoverTile(
                base: base,
                headers: headers,
                coverMid: album.cover,
                slot: 'album_cover_${album.id}',
                placeholder: coverPlaceholder,
                borderRadius: 10,
              ),
              Positioned(
                top: -4,
                right: -4,
                child: PopupMenuButton<String>(
                  tooltip: '更多',
                  icon: Icon(Icons.more_horiz_rounded, size: 18,
                      color: cs.onSurface.withValues(alpha: 0.7)),
                  padding: EdgeInsets.zero,
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('改名')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                  onSelected: (v) {
                    if (v == 'rename') {
                      onRename();
                    } else if (v == 'delete') {
                      onDelete();
                    }
                  },
                ),
              ),
            ]),
          ),
          const SizedBox(height: 6),
          Text(album.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                  color: selected ? cs.onPrimaryContainer : cs.outline)),
        ]),
      ),
    );
  }

  Widget _createCard(ThemeData theme, VoidCallback onTap) {
    final cs = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 100,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outlineVariant, style: BorderStyle.solid),
        ),
        child: Column(children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Icon(Icons.add_rounded, size: 28, color: cs.primary),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text('新建相册',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: cs.primary)),
        ]),
      ),
    );
  }

  /// 新建相册弹层（可取消）：标题必填，确认走 createAlbum。
  Future<void> _showCreateAlbumDialog(BuildContext context) async {
    final ctrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('新建相册'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: ctrl,
            autofocus: true,
            maxLength: 100,
            decoration: const InputDecoration(
                labelText: '相册名称', counterText: ''),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? '相册名称不能为空' : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false), // 取消
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.of(dctx).pop(true);
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (submitted != true) return; // 取消/关闭：不动
    final title = ctrl.text.trim();
    if (title.isEmpty) return;
    final err = await ref
        .read(albumControllerProvider.notifier)
        .createAlbum(title);
    if (!mounted) return;
    ref.read(chatToastProvider.notifier).show(
        err == null ? '已新建相册' : '新建失败：$err',
        tone: err == null ? ChatToastTone.success : ChatToastTone.error);
  }

  /// 相册改名弹层（可取消）：预填原标题，确认走 renameAlbum（回填铁律）。
  Future<void> _showRenameDialog(BuildContext context, AlbumInfo album) async {
    final ctrl = TextEditingController(text: album.title);
    final formKey = GlobalKey<FormState>();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('相册改名'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: ctrl,
            autofocus: true,
            maxLength: 100,
            decoration: const InputDecoration(
                labelText: '相册名称', counterText: ''),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? '相册名称不能为空' : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false), // 取消
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.of(dctx).pop(true);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (submitted != true) return;
    final title = ctrl.text.trim();
    if (title.isEmpty) return;
    final err = await ref
        .read(albumControllerProvider.notifier)
        .renameAlbum(album.id, title);
    if (!mounted) return;
    ref.read(chatToastProvider.notifier).show(
        err == null ? '已保存' : '改名失败：$err',
        tone: err == null ? ChatToastTone.success : ChatToastTone.error);
  }

  /// 删除相册确认弹层（可取消，含 G5 口径）：软删，服务端自动清归属。
  Future<void> _showDeleteConfirm(BuildContext context, AlbumInfo album) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('删除相册'),
        content: Text(
            '确定删除「${album.title}」吗？\n\n照片会保留在全部照片里，但恢复相册不会自动还原照片的归类。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false), // 取消
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return; // 取消/关闭：不删
    final err = await ref
        .read(albumControllerProvider.notifier)
        .deleteAlbum(album.id);
    if (!mounted) return;
    ref.read(chatToastProvider.notifier).show(
        err == null ? '已删除相册' : '删除失败：$err',
        tone: err == null ? ChatToastTone.success : ChatToastTone.error);
  }

  Widget _body(BuildContext context, AlbumState st) {
    if (st.skeleton) return _skeleton(context);
    if (st.photos.isEmpty) {
      return _empty(context, filtered: st.selectedAlbum.isNotEmpty, error: st.error);
    }
    if (st.view == AlbumView.byAlbum) return _albumGrid(context, st.photos);
    return _timeList(context, st.photos);
  }

  Widget _albumGrid(BuildContext context, List<PhotoItem> photos) {
    return RefreshIndicator(
      onRefresh: () => ref.read(albumControllerProvider.notifier).load(),
      child: GridView.builder(
        controller: _gridScroll, // 段 B：查看器翻页后预滚动，保证 Hero 落点
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        itemCount: photos.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3, mainAxisSpacing: 8, crossAxisSpacing: 8),
        itemBuilder: (_, i) => _Thumb(photo: photos[i], all: photos, index: i),
      ),
    );
  }

  Widget _timeList(BuildContext context, List<PhotoItem> photos) {
    final groups = groupPhotosByMonth(photos);
    return RefreshIndicator(
      onRefresh: () => ref.read(albumControllerProvider.notifier).load(),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        itemCount: groups.length,
        itemBuilder: (_, gi) {
          final g = groups[gi];
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(g.label,
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final row in chunkPhotosForGrid(g.photos))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  for (final p in row)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: _Thumb(
                              photo: p,
                              all: photos,
                              index: photos.indexOf(p)),
                        ),
                      ),
                    ),
                  // 不足 3 张时补齐占位，保证行内等比
                  for (var k = row.length; k < 3; k++)
                    const Expanded(
                        child: Padding(
                            padding: EdgeInsets.only(right: 8),
                            child: SizedBox())),
                ]),
              ),
          ]);
        },
      ),
    );
  }

  Widget _empty(BuildContext context,
      {required bool filtered, String? error}) {
    final theme = Theme.of(context);
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.photo_library_outlined, size: 44,
            color: theme.colorScheme.outline),
        const SizedBox(height: 12),
        Text(filtered ? '这个相册还没有照片' : '还没有照片，先去记录第一刻吧',
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(filtered ? '换个相册，或看看全部照片。' : '在时光里发一张图，就会收进这里。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline)),
        if (error != null) ...[
          const SizedBox(height: 10),
          Text(error,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error)),
        ],
      ]),
    );
  }

  Widget _skeleton(BuildContext context) {
    final c = Theme.of(context).colorScheme.surfaceContainerHighest;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: 9,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3, mainAxisSpacing: 8, crossAxisSpacing: 8),
      itemBuilder: (_, i) => Container(
        decoration: BoxDecoration(
            color: c, borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}

/// 缩略图：CachedNetworkImage（preview=true + Cookie）+ 占位色渐显 +
/// Hero tag（段 B 共享元素转场双向）+ context.push 打开甲档查看器。
class _Thumb extends ConsumerWidget {
  const _Thumb({required this.photo, required this.all, required this.index});
  final PhotoItem photo;
  final List<PhotoItem> all;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final base = ref.watch(chatBaseProvider).valueOrNull ?? '';
    final headers = ref.watch(mediaCookieHeadersProvider).valueOrNull;
    return Hero(
      tag: albumHeroTag(photo.id),
      child: GestureDetector(
        onTap: () async {
          // 打开前先把索引对齐到点开的这张（查看器 initState 会再写一次）
          ref.read(albumViewerIndexProvider.notifier).state = index;
          // albumId 仅当正处于某个相册内才带上（全部照片视图不预填封面归属）
          final albumId = ref.read(albumControllerProvider).selectedAlbum;
          await context.push('/album/viewer',
              extra: {
                'photos': all,
                'index': index.clamp(0, all.length - 1),
                'albumId': albumId,
              });
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: CachedNetworkImage(
            imageUrl: mediaUrl(base, photo.id),
            httpHeaders: headers,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            fadeInDuration: const Duration(milliseconds: 260),
            placeholder: (_, _) => Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest),
            errorWidget: (_, _, _) => Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              alignment: Alignment.center,
              child: Icon(Icons.broken_image_outlined,
                  size: 22, color: Theme.of(context).colorScheme.outline),
            ),
          ),
        ),
      ),
    );
  }
}
