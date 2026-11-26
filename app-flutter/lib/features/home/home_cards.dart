/// 首页双卡（2.4.3 第 1、2 项）：历史上的今天 + 今年的我们。
///
/// 位置骨架（主人定案）：每日一句下方依次两卡； ListView 普通子组件，
/// 禁 overlay/毛玻璃 blur/手势层/AbsorbPointer——点击热区就是卡自身。
/// 取数并入首页既有加载流（provider 并行、失败静默→null 当无数据处理，
/// 不弹错不拖垮首页其他区块）；加载未完成先不渲染（无假卡闪烁），
/// 下拉刷新随首页 onRefresh 一并 invalidate。
/// 卡面家族：圆角 17 + outlineVariant 描边 + --shadow 双影（PostCard 同款）。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart' show dioProvider, Record;
import '../../core/chat/chat_models.dart' show ChatMedia;
import '../../core/theme/tokens.dart';
import '../../core/together/together_data.dart' show kindLabel;
import '../chat/media_bubble_widgets.dart' show MediaImageView;

/// ── 数据模型 ─────────────────────────────────────────────────────────

/// GET /api/on-this-day 的年份分组（服务端已按年份倒序）。
class OnThisDayGroup {
  const OnThisDayGroup({
    required this.year,
    required this.isToday,
    required this.items,
  });

  final int year;
  final bool isToday;
  final List<Record> items;

  factory OnThisDayGroup.fromJson(Map<String, dynamic> j) => OnThisDayGroup(
        year: (j['year'] as num?)?.toInt() ?? 0,
        isToday: j['is_today'] == true,
        items: ((j['items'] ?? []) as List)
            .whereType<Map>()
            .map((e) => Record.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );
}

/// GET /api/yearbook 响应（统计全部服务端算好，App 只渲染不自算）。
class Yearbook {
  const Yearbook({
    required this.year,
    required this.isCurrent,
    required this.total,
    required this.photos,
    required this.moodDays,
    required this.wishesDone,
    required this.anniversaries,
    required this.moods,
    required this.activeDays,
    required this.streak,
    required this.interactions,
    required this.byKind,
    required this.bestMonth,
    required this.bestWeekday,
    required this.topKind,
    required this.moodTop,
    required this.words,
  });

  final int year;
  final bool isCurrent;
  final int total;
  final int photos;
  final int moodDays;
  final int wishesDone;
  final int anniversaries;
  final int moods;
  final int activeDays;
  final int streak;
  final int interactions;
  final Map<String, int> byKind;
  final Map<String, dynamic>? bestMonth;
  final Map<String, dynamic>? bestWeekday;
  final Map<String, dynamic>? topKind;
  final List<Map<String, dynamic>> moodTop;
  final List<Map<String, dynamic>> words;

  factory Yearbook.fromJson(Map<String, dynamic> j) => Yearbook(
        year: (j['year'] as num?)?.toInt() ?? 0,
        isCurrent: j['is_current'] == true,
        total: (j['total'] as num?)?.toInt() ?? 0,
        photos: (j['photos'] as num?)?.toInt() ?? 0,
        // 2.4.3 新字段：今年有 mood 记录的去重天数（「天心情」口径单一事实源）
        moodDays: (j['mood_days'] as num?)?.toInt() ?? 0,
        wishesDone: (j['wishes_done'] as num?)?.toInt() ?? 0,
        anniversaries: (j['anniversaries'] as num?)?.toInt() ?? 0,
        moods: (j['moods'] as num?)?.toInt() ?? 0,
        activeDays: (j['active_days'] as num?)?.toInt() ?? 0,
        streak: (j['streak'] as num?)?.toInt() ?? 0,
        interactions: (j['interactions'] as num?)?.toInt() ?? 0,
        byKind: ((j['by_kind'] ?? {}) as Map)
            .cast<String, dynamic>()
            .map((k, v) => MapEntry(k, (v as num?)?.toInt() ?? 0)),
        bestMonth: j['best_month'] is Map
            ? (j['best_month'] as Map).cast<String, dynamic>()
            : null,
        bestWeekday: j['best_weekday'] is Map
            ? (j['best_weekday'] as Map).cast<String, dynamic>()
            : null,
        topKind: j['top_kind'] is Map
            ? (j['top_kind'] as Map).cast<String, dynamic>()
            : null,
        moodTop: ((j['mood_top'] ?? []) as List)
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList(),
        words: ((j['words'] ?? []) as List)
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList(),
      );
}

/// ── providers（失败静默：任何异常 → null，首页当作无数据处理） ────────

final onThisDayProvider = FutureProvider<List<OnThisDayGroup>?>((ref) async {
  try {
    final dio = await ref.watch(dioProvider.future);
    final r = await dio.get('/api/on-this-day');
    return ((r.data ?? []) as List)
        .whereType<Map>()
        .map((e) => OnThisDayGroup.fromJson(e.cast<String, dynamic>()))
        .toList();
  } on DioException {
    return null;
  } catch (_) {
    return null;
  }
});

final yearbookProvider = FutureProvider<Yearbook?>((ref) async {
  try {
    final dio = await ref.watch(dioProvider.future);
    final r = await dio.get('/api/yearbook');
    return Yearbook.fromJson((r.data ?? {}) as Map<String, dynamic>);
  } on DioException {
    return null;
  } catch (_) {
    return null;
  }
});

/// 往年今日（排除 is_today 组）：首页卡的显隐判定与预览行都只用往年数据。
List<(OnThisDayGroup, Record)> pastTodayItems(List<OnThisDayGroup> groups) => [
      for (final g in groups)
        if (!g.isToday) for (final it in g.items) (g, it),
    ];

/// ── 卡面公共件 ───────────────────────────────────────────────────────

/// 卡面家族（PostCard 同款）：radius 17 + outlineVariant 描边 + --shadow 双影。
Widget homeCardShell(BuildContext context, {required Widget child, Key? tapKey,
    VoidCallback? onTap}) {
  final theme = Theme.of(context);
  const cardRadius = 17.0;
  return InkWell(
    key: tapKey,
    borderRadius: BorderRadius.circular(cardRadius),
    onTap: onTap,
    child: Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(cardRadius),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: <BoxShadow>[
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
      child: Padding(
        padding: const EdgeInsets.all(Spacing.cardPad),
        child: child,
      ),
    ),
  );
}

/// 卡头一行：emoji 标题（titleMedium w600，与双格卡标题同级）+ 右 chevron。
Widget cardHeader(BuildContext context, String emoji, String title) {
  final theme = Theme.of(context);
  return Row(children: [
    Expanded(
      child: Text('$emoji $title',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          )),
    ),
    Icon(Icons.chevron_right_rounded,
        size: 20, color: theme.colorScheme.outline),
  ]);
}

/// ── 第 1 项：历史上的今天卡 ──────────────────────────────────────────

class OnThisDayCard extends ConsumerWidget {
  const OnThisDayCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(onThisDayProvider).value;
    // 显隐规则（硬性）：当前日期在往年没有任何符合口径的记录 → 整卡不渲染
    // （不占位不留空卡）。判定用「往年今日」数据，不是「今天有没有记录」。
    final previews = groups == null ? const <(OnThisDayGroup, Record)>[] : pastTodayItems(groups);
    if (previews.isEmpty) return const SizedBox.shrink();
    final top = previews.take(2).toList(); // 年份近的在上（响应已倒序）
    return homeCardShell(
      context,
      tapKey: const Key('home-card-otd'),
      onTap: () => context.push('/on-this-day'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min, children: [
        cardHeader(context, '🕰', '历史上的今天'),
        const SizedBox(height: 10),
        for (var i = 0; i < top.length; i++) ...[
          _OtdPreviewRow(year: top[i].$1.year, record: top[i].$2),
          if (i < top.length - 1) const SizedBox(height: 8),
        ],
      ]),
    );
  }
}

class _OtdPreviewRow extends StatelessWidget {
  const _OtdPreviewRow({required this.year, required this.record});

  final int year;
  final Record record;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final images = record.media
        .whereType<Map>()
        .map((m) => ChatMedia.fromJson(m.cast<String, dynamic>()))
        .where((m) => m.mime.startsWith('image/'))
        .toList();
    // 摘要口径（A1 Web 呈现）：文字类取正文第一行（title||content）单行截断；
    // 纯图记录 40×40 缩略图 +「📷 照片」（主人卡面定案）。
    final text = (record.body['title'] ?? record.body['content'] ?? '')
        .toString();
    return Row(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text('$year 年的今天', style: theme.textTheme.labelSmall),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: images.isNotEmpty
            ? Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: MediaImageView(mid: images.first.id),
                  ),
                ),
                const SizedBox(width: 6),
                Text('📷 照片', style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline)),
              ])
            : Text(
                text.isEmpty ? (kindLabel[record.kind] ?? '一份回忆') : text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall),
      ),
    ]);
  }
}

/// ── 第 2 项：今年的我们卡 ────────────────────────────────────────────

class YearbookCard extends ConsumerWidget {
  const YearbookCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final yb = ref.watch(yearbookProvider).value;
    // 加载未完成先不渲染（无假卡闪烁）；数据到位后恒渲染（全零也显示）。
    if (yb == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return homeCardShell(
      context,
      tapKey: const Key('home-card-yearbook'),
      onTap: () => context.push('/yearbook'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min, children: [
        cardHeader(context, '📖', '今年的我们'),
        const SizedBox(height: 12),
        Row(children: [
          // 四格等宽均分（yang 改判口径）：条记录/张照片/天心情/个心愿。
          _stat(theme, '${yb.total}', '条记录'),
          _stat(theme, '${yb.photos}', '张照片'),
          _stat(theme, '${yb.moodDays}', '天心情'),
          _stat(theme, '${yb.wishesDone}', '个心愿'),
        ]),
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
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline)),
        ]),
      );
}
