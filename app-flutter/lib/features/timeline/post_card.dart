/// 时光页 post 卡片（条目 4 · 段一投影 + 段二 B 互动）：
/// 头像（LowFreqCacheManager）+昵称+日期（b.date||dateLabel 双时间口径）+可选
/// 标题+正文+媒体网格（图 preview 可点查看器/视频 poster+播放/语音 chip）+
/// footer（时间戳+点赞/评论按钮：本地翻转与评论 Sheet）+内联评论列表
/// （本人评论带删除入口）。段二 B 本卡原地更新：只替换列表里这一条 Record。
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
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../chat/media_bubble_widgets.dart' show MediaImageView, VideoCardView, VoiceChipView;
import '../shell/web_chrome.dart' show WebSemanticColors;
import 'comment_sheet.dart';
import 'composer_sheet.dart';
import 'image_viewer.dart';
import 'timeline_controller.dart';
import '../../core/theme/motion.dart';
import '../../core/theme/tokens.dart';

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

    // 2.3.4（推广段一重做）Web 卡片语言（数值出处 web-visual-plan.md 8.1）：
    // 手机档 .card radius 17（style.css:1421）；kind-* 低饱和 tint 165° 渐变
    // （tint→surface 72%，:1944-1956）；顶部 1px 内高光 hairline（浅 .72 /
    // 夜 .05，:1937/:2017）。深浅双档由 WebSemanticColors/_kindTintAlpha 处理。
    const cardRadius = 17.0;
    final brightness = theme.brightness;
    final tint = _postKindTint(record.kind, theme.colorScheme, brightness);

    Widget card = Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(cardRadius),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: <BoxShadow>[
          // Web --shadow：0 2px 10px .06 + 0 1px 2px .04（style.css:137）
          BoxShadow(
            color: theme.colorScheme.shadow.withValues(alpha: 0.06),
            offset: const Offset(0, 2),
            blurRadius: 10,
          ),
          BoxShadow(
            color: theme.colorScheme.shadow.withValues(alpha: 0.04),
            offset: const Offset(0, 1),
            blurRadius: 2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(cardRadius),
        child: Stack(
          children: [
            // kind tint 165° 渐变：tint 首色 → surface 72%（165°≈垂直略偏，
            // 以 topCenter→bottomCenter 近似；stops 0/0.72 对齐 Web）
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[tint, theme.colorScheme.surface],
                    stops: const [0, 0.72],
                  ),
                ),
              ),
            ),
            // 顶部 1px 内高光（--hairline，浅 .72 / 夜 .05）
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 1,
              child: ColoredBox(
                color: WebSemanticColors.cardHairline(brightness),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(Spacing.cardPad),
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
          // C1 本人卡片「⋯」菜单：编辑 / 删除（非本人不出现）
          if (isOwnPost(record.author, me.user.id))
            _OwnMenu(record: record, me: me),
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
                      height: timelineSingleMediaHeight(w),
                      // 媒体格圆角 12（style.css:602-604/:1434）
                      borderRadius: BorderRadius.circular(12)),
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
                      child: MediaImageView(
                          mid: images[i].id,
                          size: cell,
                          borderRadius: BorderRadius.circular(12)),
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
        // footer：时间戳 + 点赞/评论按钮（段二 B：本地翻转 + 评论 Sheet）
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [
            Icon(Icons.access_time_rounded, size: 13,
                color: theme.colorScheme.outline),
            const SizedBox(width: 4),
            Text(timelineDateLabel(record.created),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const Spacer(),
            // 点赞 toggle：状态与计数同一处，点击走控制器乐观翻转 + 失败回滚
            InkWell(
              borderRadius: BorderRadius.circular(AppRadius.card),
              onTap: () => ref
                  .read(timelineControllerProvider.notifier)
                  .toggleLike(record.id, me.user.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.favorite_rounded, size: 15,
                      color: liked
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline),
                  const SizedBox(width: 3),
                  Text(record.likes.isEmpty ? '喜欢' : '${record.likes.length}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
                ]),
              ),
            ),
            const SizedBox(width: 6),
            // 评论入口：原生 BottomSheet（按钮 + 下滑手势都能关）
            InkWell(
              borderRadius: BorderRadius.circular(AppRadius.card),
              onTap: () => showCommentSheet(context, rid: record.id, me: me),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.mode_comment_rounded, size: 15,
                      color: theme.colorScheme.outline),
                  const SizedBox(width: 3),
                  Text(record.comments.isEmpty
                      ? '评论'
                      : '${record.comments.length}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
                ]),
              ),
            ),
          ]),
        ),
        // 内联评论列表（本人评论带删除入口，段二 B）
        if (record.comments.isNotEmpty) ...[
          const SizedBox(height: Spacing.gap),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final c in record.comments)
                    _CommentRow(
                      comment: c,
                      me: me,
                      rid: record.id,
                    ),
                ]),
          ),
        ],
          ]),
        ),
          ],
        ),
      ),
    );

    // 骨架换内容：错开浮现（对齐 Web revealTimeline 40ms 错开、封顶 600ms）
    if (revealDelayMs > 0) {
      card = _RevealCard(delayMs: revealDelayMs, child: card);
    }
    return card;
  }
}

/// C1 本人卡片「⋯」菜单：编辑 / 删除。
/// PopupMenuButton 点外部或系统返回键即可关闭（菜单可关验收项）；
/// 删除必须经确认弹层，不许一点即删。
class _OwnMenu extends ConsumerWidget {
  const _OwnMenu({required this.record, required this.me});
  final Record record;
  final MeData me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: '更多',
      icon: const Icon(Icons.more_horiz_rounded, size: 20),
      padding: EdgeInsets.zero,
      onSelected: (v) async {
        if (v == 'edit') {
          await showComposerSheet(context, editRecord: record);
        } else if (v == 'delete') {
          await _confirmDelete(context, ref);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
            value: 'edit',
            child: Row(children: [
              Icon(Icons.edit_rounded, size: 18),
              SizedBox(width: 10),
              Text('编辑'),
            ])),
        PopupMenuItem(
            value: 'delete',
            child: Row(children: [
              Icon(Icons.delete_outline_rounded, size: 18),
              SizedBox(width: 10),
              Text('删除'),
            ])),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这一刻？'),
        content: const Text('删除后会进入回收站，30 天内可以恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return; // 误删防护：确认弹层可取消
    final err = await ref
        .read(timelineControllerProvider.notifier)
        .deleteRecord(record.id);
    ref.read(chatToastProvider.notifier).show(
        err ?? '已删除（30 天内可在回收站恢复）',
        tone: err == null
            ? ChatToastTone.success
            : ChatToastTone.error);
  }
}

/// 内联评论行：仅本人评论显示删除入口；删前弹确认弹层（可取消）。
class _CommentRow extends ConsumerWidget {
  const _CommentRow({required this.comment, required this.me, required this.rid});
  final Map<String, dynamic> comment;
  final MeData me;
  final String rid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mine = canDeleteComment(comment, me.user.id);
    final cid = comment['id']?.toString() ?? '';
    return Row(children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text.rich(TextSpan(children: [
            TextSpan(
                text: '${_name(me, comment['author']?.toString() ?? '')}：',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600)),
            TextSpan(
                text: comment['content']?.toString() ?? '',
                style: theme.textTheme.bodySmall),
          ])),
        ),
      ),
      if (mine)
        InkWell(
          borderRadius: BorderRadius.circular(AppRadius.card),
          onTap: () => _confirmDelete(context, ref, cid),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(Icons.close_rounded, size: 14,
                color: theme.colorScheme.error),
          ),
        ),
    ]);
  }

  String _name(MeData me, String id) => me.byId(id)?.name ?? '?';

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, String cid) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条评论？'),
        content: const Text('删除后无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(timelineControllerProvider.notifier).deleteComment(
        rid, cid, me.user.id);
  }
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
      duration: Motion.base,
      child: AnimatedSlide(
        offset: _shown ? Offset.zero : const Offset(0, 0.02),
        duration: Motion.base,
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
      // 2.4.1 第 7 项④：头像加约 1.5px 白色低透明细描边。
      return Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.55),
            width: 1.5,
          ),
        ),
        child: ClipOval(
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

/// 2.3.4（推广段一重做）kind-* 低饱和 tint 映射（Web style.css:1930-1956，
/// rgb 通道随主题/明暗——App 端等价映射为 colorScheme/语义色 withValues α）：
/// mood=tint-rose(primary .055)；post/diary/draft/surprise/question/note/period
/// 等默认 primary .04；anniversary=amber .06；wish/personal_wish/music=fertile
/// .06；quest/habit=amber .055；ledger=green .06；album=info .05。
Color _postKindTint(String kind, ColorScheme cs, Brightness brightness) {
  switch (kind) {
    case 'mood':
      return cs.primary.withValues(alpha: 0.038); // tint-rose（:1930，2.4.1 降一档）
    case 'anniversary':
      return WebSemanticColors.amber(brightness).withValues(alpha: 0.042);
    case 'wish':
    case 'personal_wish':
    case 'music':
      return WebSemanticColors.fertile(brightness).withValues(alpha: 0.042);
    case 'quest':
    case 'habit':
      return WebSemanticColors.amber(brightness).withValues(alpha: 0.038);
    case 'ledger':
      return WebSemanticColors.green(brightness).withValues(alpha: 0.042);
    case 'album':
      return WebSemanticColors.info(brightness).withValues(alpha: 0.035);
    default: // post/diary/draft/surprise/question/note/period（:1955-1956）
      return cs.primary.withValues(alpha: 0.04);
  }
}
