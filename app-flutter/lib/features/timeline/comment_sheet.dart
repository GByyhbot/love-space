/// 时光卡片评论 BottomSheet + 删评论确认弹层（条目 4 · 段二 B2）。
/// · 原生 showModalBottomSheet（按钮关闭 + 下滑手势关闭，isDismissible 默认 true）；
/// · 输入框 ≤5000，发表成功后本卡即时插入、Sheet 收起；
/// · 仅本人评论显示删除入口；删前 AlertDialog 确认弹层可取消。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart';
import '../../core/ui/submit_morph.dart' show SubmitMorphButton;
import 'timeline_controller.dart';
import '../../core/theme/tokens.dart';
import '../../core/ui/apple_ui.dart';
import '../../core/ui/hold_to_confirm.dart' show HoldToConfirmButton;

/// 打开评论 Sheet（footer 评论数点击 / 「回复」入口）
Future<void> showCommentSheet(BuildContext context,
    {required String rid, required MeData me}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true, // 键盘避让
    isDismissible: true, // 允许下滑手势 / 点遮罩关闭
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    builder: (_) => CommentSheet(rid: rid, me: me),
  );
}

class CommentSheet extends ConsumerStatefulWidget {
  const CommentSheet({super.key, required this.rid, required this.me});
  final String rid;
  final MeData me;

  @override
  ConsumerState<CommentSheet> createState() => _CommentSheetState();
}

class _CommentSheetState extends ConsumerState<CommentSheet> {
  final _input = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// 删评论确认弹层（可取消 → 返回路径验收点）
  Future<void> _confirmDelete(String cid) async {
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
    await ref.read(timelineControllerProvider.notifier).deleteComment(
        widget.rid, cid, widget.me.user.id);
  }

  // 2.4.10：改返 Future<bool> 供三连变驱动（成功后 morph 对勾驻留再 pop）。
  Future<bool> _send() async {
    if (_sending) return false;
    setState(() => _sending = true);
    final ok = await ref.read(timelineControllerProvider.notifier).addComment(
        widget.rid, _input.text, widget.me.user.id);
    if (!mounted) return false;
    setState(() => _sending = false);
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final posts = ref.watch(timelineControllerProvider).posts;
    final idx = posts.indexWhere((r) => r.id == widget.rid);
    final comments = idx < 0
        ? const <Map<String, dynamic>>[]
        : posts[idx].comments;
    return AppleSheetContainer(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      title: '评论',
      onClose: () => Navigator.of(context).pop(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
        ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.45),
          child: comments.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Center(child: Text('还没有评论，来说点什么吧')))
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: comments.length,
                  itemBuilder: (_, i) {
                    final c = comments[i];
                    final mine = c['author']?.toString() == widget.me.user.id;
                    final who = widget.me
                            .byId(c['author']?.toString() ?? '')
                            ?.name ??
                        '?';
                    return Row(children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Text.rich(TextSpan(children: [
                            TextSpan(
                                text: '$who：',
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w600)),
                            TextSpan(
                                text: c['content']?.toString() ?? '',
                                style: theme.textTheme.bodySmall),
                          ])),
                        ),
                      ),
                      // 仅本人评论显示删除入口（B2）
                      if (mine)
                        IconButton(
                          tooltip: '删除评论',
                          visualDensity: VisualDensity.compact,
                          onPressed: () =>
                              _confirmDelete(c['id']?.toString() ?? ''),
                          icon: Icon(Icons.delete_outline_rounded,
                              size: 18, color: theme.colorScheme.error),
                        ),
                    ]);
                  }),
        ),
        const SizedBox(height: Spacing.gap),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: TextField(
              controller: _input,
              maxLength: 5000,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                  hintText: '写一句评论…', counterText: '', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          // 2.4.10：发送走三连变（成功对勾驻留后关弹层，内联列表已即时上屏）。
          SubmitMorphButton(
            label: '发送',
            onSubmit: _send,
            onSuccess: () => Navigator.of(context).pop(),
          ),
        ]),
      ]),
    );
  }
}
