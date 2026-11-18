/// /yearbook 二级页（2.4.3 第 2 项）：今年的我们。
/// 首页年报卡 context.push 进入；内容逐块对齐 Web 年报（app.js:1064-1083
/// yearbookBody），口径全部来自 /api/yearbook 服务端聚合（App 不自算）：
/// ①四格统计（yang 改判：条记录/张照片/天心情 mood_days 去重天数/
///   个心愿 wishes_done；与首页卡两处同数同名，页内标签写全「已完成」）
/// ②facts 花名册（记录天数/最长连续/最勤快月份/最活跃星期/记得最多的
///   类型/收到的回应，逐项>0 才显示——Web 同条件）
/// ③年度关键词 Top8（服务端 2-gram+停用表，字号按出现次数比例）
/// ④心情 Top3  ⑤亮点统计（post/照片/心情条数/完成心愿/纪念日，>0 才显示）
/// total==0 时只显示四格+一句话（Web 同口径）。
/// 年份=服务端按空间时区算的当前年（响应 year 字段，无写死常量），跨年
/// 后自动滚动到新一年（每次进页重拉）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/ui/empty_view.dart';
import '../../core/ui/progress.dart';
import '../../core/together/together_data.dart' show kindLabel;
import 'home_cards.dart';

/// Web WEEKDAY_LABEL（app.js 顶部）：0=周一 … 6=周日。
const _weekdayLabel = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

class YearbookPage extends ConsumerWidget {
  const YearbookPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final yb = ref.watch(yearbookProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('今年的我们')),
      body: yb.when(
        loading: () => const AppProgress(),
        error: (_, _) => const AppEmptyView(
          icon: Icons.auto_stories_rounded,
          title: '年报暂时打不开',
          hint: '回首页再试试。',
        ),
        data: (data) {
          if (data == null) {
            return const AppEmptyView(
              icon: Icons.auto_stories_rounded,
              title: '年报暂时打不开',
              hint: '回首页再试试。',
            );
          }
          final k = data.byKind;
          // ⑤亮点统计（Web highlights：>0 才显示）
          final highlights = <List>[
            ['📝', '时光动态', k['post'] ?? 0],
            ['📷', '收藏照片', data.photos],
            ['☀️', '心情记录', data.moods], // Web 口径：mood 记录条数
            ['✨', '完成心愿', data.wishesDone],
            ['📅', '纪念日', data.anniversaries],
          ].where((x) => (x[2] as num) > 0).toList();
          // ②facts 花名册（Web facts：逐项>0 / streak>1 才显示）
          final facts = <List<String>>[
            if (data.activeDays > 0)
              ['🗓️', '记录下来的日子', '${data.activeDays} 天'],
            if (data.streak > 1) ['🔥', '最长连续记录', '${data.streak} 天'],
            if (data.bestMonth != null)
              [
                '📅',
                '最勤快的一个月',
                '${data.bestMonth!['month']} 月 · ${data.bestMonth!['count']} 条',
              ],
            if (data.bestWeekday != null)
              [
                '📆',
                '最活跃的一天',
                '${_weekdayLabel[(data.bestWeekday!['weekday'] as num).toInt() % 7]} · ${data.bestWeekday!['count']} 条',
              ],
            if (data.topKind != null &&
                kindLabel[data.topKind!['kind']] != null)
              [
                '📌',
                '记得最多',
                '${kindLabel[data.topKind!['kind']]} ${data.topKind!['count']} 条',
              ],
            if (data.interactions > 0)
              ['💬', '收到的回应', '${data.interactions} 次赞与评论'],
          ];
          final words = data.words.take(8).toList();
          final maxWord = words
              .map((w) => (w['n'] as num?)?.toInt() ?? 0)
              .fold(1, (a, b) => a > b ? a : b);
          final moods = data.moodTop.where((m) => ((m['n'] as num?)?.toInt() ?? 0) > 0);

          return ListView(
            padding: const EdgeInsets.fromLTRB(
                16, 12, 16, Spacing.pageBottom),
            children: [
              // ① 四格统计（与首页卡同数同名；页内标签写全「已完成」）
              Container(
                padding: const EdgeInsets.all(Spacing.cardPad),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(17),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Row(children: [
                  _stat(theme, '${data.total}', '条记录'),
                  _stat(theme, '${data.photos}', '张照片'),
                  _stat(theme, '${data.moodDays}', '天心情'),
                  _stat(theme, '${data.wishesDone}', '个心愿（已完成）'),
                ]),
              ),
              if (data.total == 0)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Center(child: Text('这一年，还在慢慢写下我们的故事…')),
                )
              else ...[
                if (facts.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final f in facts)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(children: [
                                Text(f[0]),
                                const SizedBox(width: 8),
                                Text(f[1],
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(color: theme.colorScheme.outline)),
                                const Spacer(),
                                Text(f[2],
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(fontWeight: FontWeight.w600)),
                              ]),
                            ),
                        ]),
                  ),
                if (words.isNotEmpty)
                  _section(context, '这一年常写的字',
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final w in words)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text.rich(TextSpan(children: [
                              TextSpan(
                                  text: '${w['w']}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontSize: 12 +
                                        (((w['n'] as num?)?.toInt() ?? 0) /
                                                maxWord *
                                                8)
                                            .round()
                                            .toDouble(),
                                    fontWeight: FontWeight.w600,
                                  )),
                              TextSpan(
                                  text: ' ${(w['n'] as num?)?.toInt() ?? 0}',
                                  style: theme.textTheme.labelSmall
                                      ?.copyWith(color: theme.colorScheme.outline)),
                            ])),
                          ),
                      ])),
                if (moods.isNotEmpty)
                  _section(context, '最常出现的心情',
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final m in moods)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text.rich(TextSpan(children: [
                              TextSpan(text: '${m['emoji']}'),
                              TextSpan(
                                  text: ' ${(m['n'] as num?)?.toInt() ?? 0}',
                                  style: theme.textTheme.labelSmall
                                      ?.copyWith(color: theme.colorScheme.outline)),
                            ])),
                          ),
                      ])),
                if (highlights.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final h in highlights)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(children: [
                                Text('${h[0]}'),
                                const SizedBox(width: 8),
                                Text('${h[1]}',
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(color: theme.colorScheme.outline)),
                                const Spacer(),
                                Text('${h[2]}',
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(fontWeight: FontWeight.w600)),
                              ]),
                            ),
                        ]),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _section(BuildContext context, String title, Widget child) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            )),
        const SizedBox(height: 8),
        child,
      ]),
    );
  }

  Widget _stat(ThemeData theme, String num, String label) => Expanded(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(num,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: -0.3,
              )),
          const SizedBox(height: 2),
          Text(label,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline)),
        ]),
      );
}
