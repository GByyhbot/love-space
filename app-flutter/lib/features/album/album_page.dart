/// 相册页（条目 5 · 段 A）：heading + 两视图（按相册分类 / 按时间月份分组）
/// + 分类 chips（全部照片/各相册）+ 3 列照片网格（CachedNetworkImage 占位色
/// 渐显 + preview=true + Cookie 头）+ 空态两套 + 首屏骨架 + SSE other 重拉。
/// 缩略图带 Hero tag 并 context.push 到查看器（段 A 复用段一基础查看器，
/// 段 B 替换为 Hero 共享转场 + 跨相册翻页的进阶查看器）。
/// 顶部通知宿主（ChatToastHost）按通则挂 body 顶部，供 B/C/D 段结果类提示复用。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/album/album_data.dart';
import '../../core/chat/chat_media.dart';
import '../../core/chat/chat_models.dart';
import '../../core/sse/sse_client.dart';
import '../chat/chat_toast.dart' show ChatToastHost;
import 'album_controller.dart';

class AlbumPage extends ConsumerStatefulWidget {
  const AlbumPage({super.key, required this.active});
  final bool active; // 当前 tab 是否为相册（SSE other 只在激活时重拉）

  @override
  ConsumerState<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends ConsumerState<AlbumPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() =>
        ref.read(albumControllerProvider.notifier).bootstrap());
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

    return SafeArea(
      child: Stack(fit: StackFit.expand, children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _heading(context),
          _viewTabs(context, st),
          if (st.view == AlbumView.byAlbum) _albumChips(context, st),
          Expanded(child: _body(context, st)),
        ]),
        // 顶部通知宿主（结果类提示统一走顶部，宿主不占布局空间）
        const Positioned(top: 0, left: 0, right: 0, child: ChatToastHost()),
      ]),
    );
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

  Widget _albumChips(BuildContext context, AlbumState st) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Wrap(spacing: 6, runSpacing: 6, children: [
        _chip(theme, '全部照片', st.selectedAlbum.isEmpty,
            () => ref.read(albumControllerProvider.notifier).selectAlbum('')),
        for (final a in st.albums)
          _chip(theme, a.title, st.selectedAlbum == a.id,
              () => ref.read(albumControllerProvider.notifier).selectAlbum(a.id)),
      ]),
    );
  }

  Widget _chip(ThemeData theme, String label, bool selected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant),
        ),
        child: Text(label,
            style: theme.textTheme.labelSmall?.copyWith(
                color: selected
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.outline)),
      ),
    );
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
/// Hero tag（段 B 共享元素转场用）+ context.push 打开查看器。
class _Thumb extends ConsumerWidget {
  const _Thumb({required this.photo, required this.all, required this.index});
  final PhotoItem photo;
  final List<PhotoItem> all;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final base = ref.watch(chatBaseProvider).valueOrNull ?? '';
    final headers = ref.watch(mediaCookieHeadersProvider).valueOrNull;
    final images = [
      for (final p in all)
        ChatMedia(id: p.id, name: p.name, mime: p.mime,
            status: p.status, preview: p.preview),
    ];
    return Hero(
      tag: 'album-photo-${photo.id}',
      child: GestureDetector(
        onTap: () => context.push('/album/viewer',
            extra: {'images': images, 'index': index.clamp(0, images.length - 1)}),
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
