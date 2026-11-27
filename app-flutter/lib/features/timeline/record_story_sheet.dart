/// 记录故事弹层（2.4.3 第 1 题 yang 改判「好看优先版」）：/on-this-day
/// 条目点击的底部弹层，内容按 App 设计语言重排——媒体优先（有图整宽大图/
/// 多图时光卡同款网格、视频 poster、语音 chip），作者行带「N 年前的今天」
/// 标签，正文全文，互动行（点赞/评论）与评论区复用既有逻辑层：
/// 点赞=POST /records/{id}/like + toggleLocalLikes 乐观翻转 + 失败回滚
/// （语义等价 timeline_controller.toggleLike:215，但弹层记录来自
/// /on-this-day 而非时光分页列表，无法走其 indexWhere patch 入口）；
/// 评论=POST /records/{id}/comments + 本地插入（语义等价 addComment:239）；
/// 删评论=DELETE /comments/{cid}（语义等价 deleteComment:276）。
/// 外壳：既有 sheet 家族（AppRadius.lg 顶圆角 + 抓手 + 遮罩压暗），
/// 高度自适应上限 86% 屏高、内容超长弹层内滚动；下滑/点遮罩/系统返回
/// 都可关，弹层是 modal 不动下层列表滚动位置。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../../core/chat/chat_models.dart' show ChatSong;
import '../chat/media_bubble_widgets.dart' show SongCardView;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/chat/chat_models.dart' show ChatMedia;
import '../../core/theme/app_icons.dart';
import '../../core/theme/tokens.dart';
import '../../core/timeline/timeline_data.dart';
import '../../core/ui/avatar_media.dart';
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../../core/ui/like_burst.dart' show LikeBurstIcon, LikeCountLabel;
import '../../core/ui/submit_morph.dart' show SubmitMorphButton;
import '../../core/ui/hold_to_confirm.dart' show HoldToConfirmButton;
import '../chat/media_bubble_widgets.dart'
    show MediaImageView, VideoCardView, VoiceChipView;
import 'image_viewer.dart';

Future<void> showRecordStorySheet(
  BuildContext context, {
  required Record record,
  required MeData me,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    useSafeArea: true,
    barrierColor: Colors.black54, // 遮罩压暗
    backgroundColor: Colors.transparent,
    shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.xl))),
    builder: (_) => _RecordStorySheet(record: record, me: me),
  );
}

class _RecordStorySheet extends ConsumerStatefulWidget {
  const _RecordStorySheet({required this.record, required this.me});

  final Record record;
  final MeData me;

  @override
  ConsumerState<_RecordStorySheet> createState() => _RecordStorySheetState();
}

class _RecordStorySheetState extends ConsumerState<_RecordStorySheet> {
  late Record cur = widget.record;
  bool _liking = false;
  bool _sending = false;
  final _commentKey = GlobalKey();
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _toast(String text, ChatToastTone tone) =>
      ref.read(chatToastProvider.notifier).show(text, tone: tone);

  ChatMedia _media(Map<String, dynamic> m) =>
      ChatMedia.fromJson(m);

  /// 点赞：乐观翻转 + 失败回滚（与 toggleLike 同端点同交互语义）。
  Future<void> _toggleLike() async {
    if (_liking) return;
    setState(() => _liking = true);
    final before = List<String>.of(cur.likes);
    final optimistic = toggleLocalLikes(before, widget.me.user.id);
    setState(() => cur = _patch(likes: optimistic));
    try {
      final dio = await ref.read(dioProvider.future);
      final r = await dio.post('/api/records/${cur.id}/like');
      if ((r.statusCode ?? 500) >= 400) throw DioException(requestOptions: r.requestOptions);
      setState(() => _liking = false);
    } catch (_) {
      setState(() {
        cur = _patch(likes: before); // 回滚到点前状态
        _liking = false;
      });
      _toast('点赞失败，已恢复', ChatToastTone.error);
    }
  }

  // 2.4.10：改返 Future<bool> 供三连变驱动（成功 morph 驻留后 pop）。
  Future<bool> _sendComment() async {
    if (_sending) return false;
    final text = _input.text.trim();
    if (text.isEmpty || text.length > 5000) {
      _toast('评论内容需在 1–5000 字之间', ChatToastTone.warning);
      return false;
    }
    setState(() => _sending = true);
    try {
      final dio = await ref.read(dioProvider.future);
      final r = await dio.post('/api/records/${cur.id}/comments',
          data: {'content': text});
      if ((r.statusCode ?? 500) >= 400) throw DioException(requestOptions: r.requestOptions);
      final cid = ((r.data as Map?) ?? const {})['id']?.toString() ?? '';
      if (cid.isEmpty) throw DioException(requestOptions: r.requestOptions);
      final comments = List<Map<String, dynamic>>.of(cur.comments)
        ..add({
          'id': cid,
          'author': widget.me.user.id,
          'content': text,
          'created': DateTime.now().millisecondsSinceEpoch / 1000,
        });
      setState(() {
        cur = _patch(comments: comments);
        _sending = false;
      });
      _input.clear();
      return true;
    } catch (_) {
      setState(() => _sending = false);
      _toast('评论发送失败，稍后再试', ChatToastTone.error);
      return false;
    }
  }

  /// 删本人评论：确认弹层 → DELETE /comments/{cid} → 本地移除（失败回滚）。
  Future<void> _deleteComment(String cid) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条评论？'),
        content: const Text('删除后无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          // 2.4.10 第 04 项：删除确认改长按确认。
          HoldToConfirmButton(onConfirm: () => Navigator.of(ctx).pop(true)),
        ],
      ),
    );
    if (ok != true) return;
    final before = List<Map<String, dynamic>>.of(cur.comments);
    setState(() => cur = _patch(
        comments: before.where((c) => c['id']?.toString() != cid).toList()));
    try {
      final dio = await ref.read(dioProvider.future);
      final r = await dio.delete('/api/comments/$cid');
      if ((r.statusCode ?? 500) >= 400) throw DioException(requestOptions: r.requestOptions);
    } catch (_) {
      setState(() => cur = _patch(comments: before)); // 回滚
      _toast('删除失败，已恢复', ChatToastTone.error);
    }
  }

  Record _patch({List<String>? likes, List<Map<String, dynamic>>? comments}) =>
      Record(
        id: cur.id,
        kind: cur.kind,
        author: cur.author,
        body: cur.body,
        created: cur.created,
        clientId: cur.clientId,
        likes: likes ?? cur.likes,
        comments: comments ?? cur.comments,
        media: cur.media,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media =
        cur.media.whereType<Map>().map((m) => _media(m.cast<String, dynamic>())).toList();
    final images = media.where((m) => m.mime.startsWith('image/')).toList();
    final videos = media.where((m) => m.mime.startsWith('video/')).toList();
    final voices = media.where((m) => m.mime.startsWith('audio/')).toList();
    final author = widget.me.byId(cur.author) ??
        SpaceUser(id: cur.author, name: '?', username: '');
    final title = cur.body['title']?.toString() ?? '';
    final content = cur.body['content']?.toString() ?? '';
    // 「N 年前的今天」：发生年 body.date[:4] 优先，缺省回退创建年
    final dateStr = cur.body['date']?.toString() ?? '';
    final recYear = int.tryParse(
            dateStr.length >= 4 ? dateStr.substring(0, 4) : '') ??
        DateTime.fromMillisecondsSinceEpoch((cur.created * 1000).round()).year;
    final yearsAgo = DateTime.now().year - recYear;
    final liked = cur.likes.contains(widget.me.user.id);

    return Container(
      margin: const EdgeInsets.only(top: 60),
      decoration: const BoxDecoration(
        color: Colors.transparent,
      ),
      child: Container(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.86),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadius.xl)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min, children: [
            // 抓手（既有 sheet 家族同款 38×4.5）
            Center(
              child: Container(
                width: 38,
                height: 4.5,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant
                      .withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            // ① 媒体区（媒体优先；无媒体整段跳过不留白）
            if (images.isNotEmpty)
              _imagesGrid(context, images)
            else if (videos.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: VideoCardView(mid: videos.first.id, size: 200),
              )
            else if (voices.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: VoiceChipView(mid: voices.first.id),
              )
            else if (cur.body['song'] is Map)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: LayoutBuilder(builder: (context, c) {
                  final song = ChatSong.fromJson(
                      (cur.body['song'] as Map).cast<String, dynamic>());
                  return SongCardView(
                    song: song,
                    width: c.maxWidth,
                    unavailable: song.mid.isEmpty && song.src.isEmpty,
                  );
                }),
              ),
            // ② 作者行：头像 + 昵称 + 完整日期 +「N 年前的今天」标签
            Row(children: [
              AvatarMedia(
                  avatarId: author.avatar, name: author.name, radius: 17),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min, children: [
                  Text(author.name, style: theme.textTheme.titleSmall),
                  Text(
                      postHeaderDate(
                          bodyDate: dateStr, created: cur.created),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
                ]),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: Spacing.xs),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(
                  yearsAgo <= 0 ? '今年的今天' : '$yearsAgo 年前的今天',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ]),
            // ③ 正文全文（不截断）
            if (title.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(title, style: theme.textTheme.titleMedium),
              ),
            if (content.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(content, style: theme.textTheme.bodyMedium),
              ),
            // ④ 互动行（与时光卡同款图标与计数语义；2.4.10 接入爆粒子）
            Row(children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                LikeBurstIcon(
                  key: const Key('story-like'),
                  liked: liked,
                  onTap: _toggleLike,
                  size: 16,
                ),
                const SizedBox(width: 2),
                LikeCountLabel(
                  liked: liked,
                  count: cur.likes.length,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ]),
              const SizedBox(width: 6),
              InkWell(
                borderRadius: BorderRadius.circular(AppRadius.card),
                onTap: () => Scrollable.ensureVisible(
                    _commentKey.currentContext ?? context),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.mode_comment_rounded,
                        size: 16, color: theme.colorScheme.outline),
                    const SizedBox(width: 3),
                    Text(cur.comments.isEmpty
                        ? '评论'
                        : '${cur.comments.length}',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline)),
                  ]),
                ),
              ),
            ]),
            // ⑤ 评论区：已有评论（本人可删）+ 底部写评论入口
            Container(
              key: _commentKey,
              margin: const EdgeInsets.only(top: 10),
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min, children: [
                if (cur.comments.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('还没有评论，来说点什么吧',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline)),
                  ),
                for (final c in cur.comments)
                  Row(children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text.rich(TextSpan(children: [
                          TextSpan(
                              text:
                                  '${widget.me.byId(c['author']?.toString() ?? '')?.name ?? '?'}：',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w600)),
                          TextSpan(
                              text: c['content']?.toString() ?? '',
                              style: theme.textTheme.bodySmall),
                        ])),
                      ),
                    ),
                    if (c['author']?.toString() == widget.me.user.id)
                      IconButton(
                        tooltip: '删除评论',
                        visualDensity: VisualDensity.compact,
                        onPressed: () =>
                            _deleteComment(c['id']?.toString() ?? ''),
                        icon: Icon(AppIcons.trash,
                            size: 18, color: theme.colorScheme.error),
                      ),
                  ]),
                const SizedBox(height: Spacing.gap),
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(
                    child: TextField(
                      key: const Key('story-comment-input'),
                      controller: _input,
                      maxLength: 5000,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                          hintText: '写一句评论…',
                          counterText: '',
                          isDense: true),
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  // 2.4.10：发送走三连变。
                  SubmitMorphButton(
                    key: const Key('story-comment-send'),
                    label: '发送',
                    onSubmit: _sendComment,
                  ),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  /// 多图：时光卡同款网格口径（单图整宽 16/10、多图三等分 Wrap），
  /// 点击进既有图片查看器。
  Widget _imagesGrid(BuildContext context, List<ChatMedia> images) {
    if (images.length == 1) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: GestureDetector(
          onTap: () => openImageViewer(context, images),
          child: LayoutBuilder(builder: (context, c) => MediaImageView(
              mid: images.first.id,
              width: c.maxWidth,
              height: timelineSingleMediaHeight(c.maxWidth),
              // 圆角 14（主人弹层定案：整宽大图圆角 14）
              borderRadius: BorderRadius.circular(14))),
        ),
      );
    }
    const gap = timelineMediaGap;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: LayoutBuilder(builder: (context, c) {
        final cell = (c.maxWidth - gap) / 2; // 弹层多图两列（大图优先观感）
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
                    width: cell,
                    height: cell,
                    borderRadius: BorderRadius.circular(14)),
              ),
          ],
        );
      }),
    );
  }
}
