/// 时光页 post 卡片（条目 4 · 段一，对齐 Web recordCard 的 post 投影）：
/// 头像（LowFreqCacheManager）+昵称+日期（b.date||dateLabel 双时间口径）+可选
/// 标题+正文+媒体网格（图 preview 可点查看器/视频 poster+播放/语音 chip）+
/// footer（时间戳+点赞数/评论数展示，互动行为段二接）+内联评论列表。
/// kind 扩展位：post 之外字段照常渲染（列本页仅 post）。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/cache/low_freq_cache.dart';
import '../../core/chat/chat_media.dart';
import '../auth/auth_state.dart';
import '../../core/chat/chat_models.dart';
import '../../core/timeline/timeline_data.dart';
import '../chat/media_bubble_widgets.dart' show MediaImageView, VideoCardView, VoiceChipView;
import 'image_viewer.dart';

/// post 卡片
class PostCard extends ConsumerWidget {
  const PostCard({super.key, required this.record, required this.me, this.revealDelayMs = 0});
  final Record record;
  final MeData me;
  final int revealDelayMs; // 骨架换内容时的错开浮现（0=不动画）

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final b = record.body;
    final author = me.byId(record.author) ??
        SpaceUser(id: record.author, name: '?', username: '');
    final title = b['title']?.toString() ?? '';
    final content = b['content']?.toString() ?? '';
    final media = record.media
        .whereType<Map>()
        .map((m) => ChatMedia.fromJson(m.cast<String, dynamic>()))
        .toList();
    final images = media.where((m) => m.mime.startsWith('image/')).toList();
    final videos = media.where((m) => m.mime.startsWith('video/')).toList();
    final voices = media.where((m) => m.mime.startsWith('audio/')).toList();
    final liked = record.likes.contains(me.user.id);

    Widget card = Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min, children: [
        // 头部：头像（低频缓存）+昵称+日期（b.date||created 双时间口径）
        Row(children: [
          _CardAvatar(user: author, me: me),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min, children: [
              Text(author.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall),
              Text(postHeaderDate(
                  bodyDate: b['date']?.toString() ?? '',
                  created: record.created),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ]),
          ),
        ]),
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(title, style: theme.textTheme.titleMedium),
          ),
        if (content.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(content, style: theme.textTheme.bodyMedium),
          ),
        // 媒体网格：铺满卡片内容宽（Web static/style.css:602-609
        // `.media-grid{grid-template-columns:repeat(3,1fr);gap:8px}`、
        // `.single{grid-template-columns:1fr}` + `aspect-ratio:16/10;max-height:360`）。
        // 旧实现直接复用聊天气泡的 MediaImageView(size:220/110) 固定正方形，
        // 单图右边空一大块、多图也铺不满（用户复验「右侧 2/3 空白」根因）。
        // 聊天侧所有调用点不传 width/height，行为不变。
        if (images.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth;
              if (images.length == 1) {
                return GestureDetector(
                  onTap: () => openImageViewer(context, images),
                  child: MediaImageView(
                      mid: images.first.id,
                      width: w,
                      height: timelineSingleMediaHeight(w)),
                );
              }
              const gap = timelineMediaGap;
              final cell = timelineMediaCell(w);
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (var i = 0; i < images.length; i++)
                    GestureDetector(
                      onTap: () =>
                          openImageViewer(context, images, initialIndex: i),
                      child: MediaImageView(mid: images[i].id, size: cell),
                    ),
                ],
              );
            }),
          ),
        if (videos.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(spacing: 4, children: [
              for (final v in videos) VideoCardView(mid: v.id, size: 200)
            ]),
          ),
        if (voices.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(spacing: 4, children: [
              for (final v in voices) VoiceChipView(mid: v.id)
            ]),
          ),
        // footer：时间戳 + 点赞/评论数展示（行为段二接）
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(children: [
            Icon(Icons.schedule_rounded, size: 14,
                color: theme.colorScheme.outline),
            const SizedBox(width: 4),
            Text(timelineDateLabel(record.created),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const Spacer(),
            Icon(Icons.favorite_rounded, size: 14,
                color: liked ? theme.colorScheme.primary : theme.colorScheme.outline),
            const SizedBox(width: 3),
            Text(record.likes.isEmpty ? '喜欢' : '${record.likes.length}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const SizedBox(width: 12),
            Icon(Icons.mode_comment_rounded, size: 14,
                color: theme.colorScheme.outline),
            const SizedBox(width: 3),
            Text(record.comments.isEmpty ? '回复' : '${record.comments.length}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ]),
        ),
        // 内联评论列表
        if (record.comments.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final c in record.comments)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text.rich(TextSpan(children: [
                        TextSpan(
                            text: '${_personName(me, c['author']?.toString() ?? '')}：',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w600)),
                        TextSpan(
                            text: c['content']?.toString() ?? '',
                            style: theme.textTheme.bodySmall),
                      ])),
                    ),
                ]),
          ),
        ],
      ]),
    );

    // 骨架换内容：错开浮现（对齐 Web revealTimeline 40ms 错开、封顶 600ms）
    if (revealDelayMs > 0) {
      card = _RevealCard(delayMs: revealDelayMs, child: card);
    }
    return card;
  }

  String _personName(MeData me, String id) =>
      me.byId(id)?.name ?? '?';
}

/// 错开浮现（透明度+轻微上移，40ms 错开封顶 600ms）
class _RevealCard extends StatefulWidget {
  const _RevealCard({required this.delayMs, required this.child});
  final int delayMs;
  final Widget child;

  @override
  State<_RevealCard> createState() => _RevealCardState();
}

class _RevealCardState extends State<_RevealCard> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(
        Duration(milliseconds: widget.delayMs.clamp(0, 600)),
        () => mounted ? setState(() => _shown = true) : null);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _shown ? 1 : 0,
      duration: const Duration(milliseconds: 240),
      child: AnimatedSlide(
        offset: _shown ? Offset.zero : const Offset(0, 0.02),
        duration: const Duration(milliseconds: 240),
        child: widget.child,
      ),
    );
  }
}

/// 卡片头像（低频缓存，对齐聊天 _ChatAvatar 的 LowFreqCache 策略）
class _CardAvatar extends ConsumerWidget {
  const _CardAvatar({required this.user, required this.me});
  final SpaceUser user;
  final MeData me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    const size = 34.0;
    final id = user.avatar;
    if (id.isNotEmpty && ref.watch(chatBaseProvider).valueOrNull != null) {
      final base = ref.watch(chatBaseProvider).valueOrNull!;
      return ClipOval(
        child: CachedNetworkImage(
          imageUrl: mediaUrl(base, id),
          httpHeaders: ref.watch(mediaCookieHeadersProvider).valueOrNull,
          cacheManager: ref.watch(lowFreqCacheManagerProvider),
          width: size,
          height: size,
          fit: BoxFit.cover,
          placeholder: (_, _) => _fallback(theme, size),
          errorWidget: (_, _, _) => _fallback(theme, size),
        ),
      );
    }
    return _fallback(theme, size);
  }

  Widget _fallback(ThemeData theme, double size) => CircleAvatar(
        radius: size / 2,
        backgroundColor: theme.colorScheme.primaryContainer,
        child: Text(
          user.name.isEmpty ? '?' : user.name.characters.first,
          style: TextStyle(
              fontSize: size * 0.38,
              color: theme.colorScheme.onPrimaryContainer),
        ),
      );
}
