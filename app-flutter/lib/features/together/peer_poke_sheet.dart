/// 2.8.7 全量施工令 · 互动抽屉（想 TA 一下）。
///
/// 落点：既有报备通道三类 scene（poke / hug / care），不新建通道、不做语音贴。
/// 频控在服务端（每类每小时 ≤6，超限 422）；端上把 422 原文直接 toast 出来，
/// 不自己算次数（两套计数必然漂移）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/peer/peer_report_api.dart';
import '../../core/peer/peer_report_queue.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;

/// 四条快捷提醒（原型文案）。
const List<String> kCareQuickTexts = [
  '早点睡呀',
  '记得充电',
  '逛完早点回家',
  '别熬夜啦',
];

Future<void> showPeerPokeSheet(
  BuildContext context,
  WidgetRef ref, {
  ReportOutbox? outbox,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PokeSheet(outbox: outbox ?? reportOutbox, ref: ref),
    );

class _PokeSheet extends StatefulWidget {
  const _PokeSheet({required this.outbox, required this.ref});
  final ReportOutbox outbox;
  final WidgetRef ref;

  @override
  State<_PokeSheet> createState() => _PokeSheetState();
}

class _PokeSheetState extends State<_PokeSheet> {
  final _textCtrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _send(String scene, String summary) async {
    if (_sending) return;
    setState(() => _sending = true);
    final cid = newReportClientId();
    try {
      final dio = await widget.ref.read(api.dioProvider.future);
      await widget.outbox.enqueue(PendingReport(
        scene: scene,
        clientId: cid,
        createdAt: DateTime.now().millisecondsSinceEpoch / 1000,
        summary: summary,
        push: true,
      ));
      final r = await widget.outbox.flush(dio);
      if (!mounted) return;
      if (r.sent > 0) {
        Navigator.of(context).pop();
        widget.ref.read(chatToastProvider.notifier).show('已经送到 TA 那边了',
            tone: ChatToastTone.success);
      } else if (r.closedOff) {
        widget.ref.read(chatToastProvider.notifier).show('已关闭报备事件共享，开启后才能发',
            tone: ChatToastTone.error);
      } else if (r.kept > 0) {
        Navigator.of(context).pop();
        widget.ref.read(chatToastProvider.notifier).show('网络不畅，已存待发',
            tone: ChatToastTone.info);
      }
    } catch (e) {
      if (!mounted) return;
      widget.ref
          .read(chatToastProvider.notifier)
          .show(api.errorDetail(e), tone: ChatToastTone.error);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 4,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('想 TA 一下',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: FilledButton.tonal(
                key: const Key('poke-send-poke'),
                onPressed: _sending ? null : () => _send('poke', '戳了你一下'),
                child: const Text('👉 戳一下'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.tonal(
                key: const Key('poke-send-hug'),
                onPressed: _sending ? null : () => _send('hug', '抱了抱你'),
                child: const Text('🫂 抱抱'),
              ),
            ),
          ]),
          const SizedBox(height: 14),
          Text('提醒 TA',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final t in kCareQuickTexts)
              ActionChip(
                key: Key('poke-care-$t'),
                label: Text(t),
                onPressed: _sending ? null : () => _send('care', t),
              ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                key: const Key('poke-custom-input'),
                controller: _textCtrl,
                maxLength: 40,
                decoration: const InputDecoration(
                  hintText: '自己说一句…',
                  counterText: '',
                  isDense: true,
                ),
                onSubmitted: (v) {
                  final t = v.trim();
                  if (t.isNotEmpty) _send('care', t);
                },
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const Key('poke-custom-send'),
              onPressed: _sending
                  ? null
                  : () {
                      final t = _textCtrl.text.trim();
                      if (t.isEmpty) return;
                      _send('care', t);
                    },
              child: const Text('发送'),
            ),
          ]),
          const SizedBox(height: 6),
          Text('每类每小时最多 6 次',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
        ],
      ),
    );
  }
}
