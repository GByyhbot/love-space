/// /on-this-day 二级页（2.4.3 第 1 项）：历史上的今天。
/// 首页历史卡 context.push 进入；按年份分组倒序全量列出往年今日记录
/// （is_today 组不列——显隐与内容都只认「往年今日」口径）；条目为展示
/// 精简版（作者头像/日期行/正文摘要/首图缩略），点击弹「记录故事」弹层
/// （复用详情呈现与互动逻辑层，不新造详情页）；空态统一空状态组件，
/// 直达路由（卡隐藏后理论不可达）不崩。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' show Record;
import '../../core/chat/chat_models.dart' show ChatMedia;
import '../../core/theme/tokens.dart';
import '../../core/timeline/timeline_data.dart';
import '../../core/ui/avatar_media.dart';
import '../../core/ui/empty_view.dart';
import '../../core/ui/progress.dart';
import '../auth/auth_state.dart';
import '../chat/media_bubble_widgets.dart' show MediaImageView;
import '../timeline/record_story_sheet.dart';
import 'home_cards.dart';

class OnThisDayPage extends ConsumerWidget {
  const OnThisDayPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final me = ref.watch(authProvider.notifier).me;
    final groups = ref.watch(onThisDayProvider);

    return Scaffold(
      // automaticallyImplyLeading 不关：AppBar 返回按钮 + 系统手势双路径。
      appBar: AppBar(title: const Text('历史上的今天')),
      body: groups.when(
        loading: () => const AppProgress(),
        error: (_, _) => const AppEmptyView(
          icon: Icons.history_rounded,
          title: '往年的今天还没有记录',
          hint: '回忆加载失败，回首页再试试。',
        ),
        data: (list) {
          // 空/失败静默（null）与「往年无记录」同形：统一空状态兜底。
          final past = list == null
              ? const <(OnThisDayGroup, Record)>[]
              : pastTodayItems(list);
          if (past.isEmpty) {
            return const AppEmptyView(
              icon: Icons.history_rounded,
              title: '往年的今天还没有记录',
              hint: '这一天的回忆，正在被我们一起写下。',
            );
          }
          // 响应已按年份倒序；同一年内保持服务端顺序（created 升序）。
          final byYear = <int, List<Record>>{};
          for (final (g, r) in past) {
            byYear.putIfAbsent(g.year, () => []).add(r);
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(
                16, 12, 16, Spacing.pageBottom),
            children: [
              for (final year in byYear.keys) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('$year 年的今天',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      )),
                ),
                for (final r in byYear[year]!)
                  _OtdEntry(
                    record: r,
                    me: me,
                    onTap: me == null
                        ? null
                        : () => showRecordStorySheet(context,
                            record: r, me: me),
                  ),
                const SizedBox(height: 14),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// 条目精简卡：作者头像 + 日期行 + 正文摘要（title||content 单行）+ 首图缩略。
class _OtdEntry extends StatelessWidget {
  const _OtdEntry({required this.record, required this.me, this.onTap});

  final Record record;
  final MeData? me;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final author = me?.byId(record.author) ??
        const SpaceUser(id: '', name: '?', username: '');
    final images = record.media
        .whereType<Map>()
        .map((m) => ChatMedia.fromJson(m.cast<String, dynamic>()))
        .where((m) => m.mime.startsWith('image/'))
        .toList();
    final text = ((record.body['title'] ?? record.body['content'] ?? '')
            .toString())
        .replaceAll(RegExp(r'\s+'), ' ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(children: [
            AvatarMedia(
                avatarId: author.avatar, name: author.name, radius: 15),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Flexible(
                    child: Text(author.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge),
                  ),
                  const SizedBox(width: 8),
                  Text(
                      postHeaderDate(
                          bodyDate: record.body['date']?.toString() ?? '',
                          created: record.created),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
                ]),
                const SizedBox(height: 2),
                Text(
                    text.isEmpty ? '一份回忆' : text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall),
              ]),
            ),
            if (images.isNotEmpty) ...[
              const SizedBox(width: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: MediaImageView(mid: images.first.id),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
