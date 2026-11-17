/// 邀请另一半入住 · 共用卡（2.4.0 设置拆分段）：从 profile_page 的邀请卡
/// 抽出的**单一实现**，账号资料页与设置独立邀请页（invite_page）两处引用
/// 同一组件、同一数据源（authProvider.createInvite → POST /api/invite）。
/// 逻辑与文案逐字沿用原实现：生成（仅一次、24h 有效、重新生成会让旧链接
/// 失效）→ 展示专属链接 → 复制；失败原文行内保留 + 顶部通知。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/theme/tokens.dart';
import '../../core/ui/error_view.dart';
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;

class InviteCard extends ConsumerStatefulWidget {
  const InviteCard({super.key});

  @override
  ConsumerState<InviteCard> createState() => _InviteCardState();
}

class _InviteCardState extends ConsumerState<InviteCard> {
  bool _inviting = false;
  String? _inviteUrl;
  String? _error;

  Future<void> _createInvite() async {
    setState(() {
      _inviting = true;
      _error = null;
    });
    final (token, err) = await ref.read(authProvider.notifier).createInvite();
    if (!mounted) return;
    setState(() => _inviting = false);
    if (err != null) {
      setState(() => _error = err);
      ref.read(chatToastProvider.notifier).show(err, tone: ChatToastTone.error);
      return;
    }
    final base = await ref.read(baseProvider.future);
    setState(() =>
        _inviteUrl = '$base/?invite=${Uri.encodeComponent(token ?? '')}');
  }

  Future<void> _copyInvite() async {
    if (_inviteUrl == null) return;
    await Clipboard.setData(ClipboardData(text: _inviteUrl!));
    if (mounted) {
      ref.read(chatToastProvider.notifier).show('邀请链接已复制，私下发给 TA',
          tone: ChatToastTone.success);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.cardPad),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('邀请你，住进我的小世界', style: theme.textTheme.titleSmall),
          const SizedBox(height: Spacing.gap),
          Text(
              '生成专属邀请链接，私下发给另一半。邀请仅可使用一次，二十四小时内有效；重新生成会让旧链接失效。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _inviting ? null : _createInvite,
            child: _inviting
                ? const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('生成邀请链接'),
          ),
          if (_inviteUrl != null) ...[
            const SizedBox(height: 12),
            TextField(
              readOnly: true,
              controller: TextEditingController(text: _inviteUrl),
              decoration: const InputDecoration(labelText: '专属邀请链接'),
            ),
            const SizedBox(height: 10),
            FilledButton.tonal(
                onPressed: _copyInvite, child: const Text('复制邀请链接')),
          ],
          if (_error != null) ...[
            const SizedBox(height: Spacing.gap),
            AppErrorText(_error!),
          ],
        ]),
      ),
    );
  }
}
