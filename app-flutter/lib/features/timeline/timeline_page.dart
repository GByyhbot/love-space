/// 时光页（条目 4 · 段一）：heading 双行文案 + 「记录此刻」入口 + 筛选区
/// （q 防抖搜索/作者/日期/类型 + 激活 chips + 清除筛选）+ post 卡片无限滚动
/// （61/60 游标分页、只追加按 id 去重）+ 首屏骨架错开浮现 + 空态两套 +
/// SSE other 激活时 reset 重拉（chat 事件不搅动本页）。
/// 文案与交互对照 Web timelinePage:860 / recordCard:851 / loadTimeline:282。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/timeline/timeline_data.dart';
import '../../core/sse/sse_client.dart';
import '../../core/ui/error_view.dart';
import '../auth/auth_state.dart';
import 'composer_sheet.dart';
import 'post_card.dart';
import 'timeline_controller.dart';
import '../../core/theme/tokens.dart';

class TimelinePage extends ConsumerStatefulWidget {
  const TimelinePage({super.key, required this.active});
  final bool active; // 当前 tab 是否为时光（SSE other 只在激活时 reset 重拉）

  @override
  ConsumerState<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends ConsumerState<TimelinePage> {
  final _scroll = ScrollController();
  final _qController = TextEditingController();
  Timer? _qDebounce;
  bool _firstRevealDone = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    Future.microtask(() async {
      final me = ref.read(authProvider.notifier).me;
      await ref.read(timelineControllerProvider.notifier).bootstrap(me?.user.id ?? '');
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _qDebounce?.cancel();
    _qController.dispose();
    super.dispose();
  }

  /// 近底部（约一屏）预取下一页（对齐 Web rootMargin 100%）
  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < _scroll.position.viewportDimension) {
      ref.read(timelineControllerProvider.notifier).load(reset: false);
    }
  }

  void _onQueryChanged(String v) {
    _qDebounce?.cancel();
    _qDebounce = Timer(const Duration(milliseconds: 480), () {
      if (!mounted) return;
      ref
          .read(timelineControllerProvider.notifier)
          .setFilter(TimelineFilter(
            q: v.trim(),
            author: ref.read(timelineControllerProvider).filter.author,
            date: ref.read(timelineControllerProvider).filter.date,
            media: ref.read(timelineControllerProvider).filter.media,
          ));
    });
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authProvider.notifier).me;
    // SSE other 且时光 tab 激活 → reset 重拉（chat 事件不搅动本页）
    ref.listen(sseEventsProvider, (prev, next) {
      final ev = next.value;
      if (widget.active && (ev?.other == true || ev?.refresh == true)) {
        ref.read(timelineControllerProvider.notifier).resetOnSseOther();
      }
    });
    if (me == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // 骨架 → 内容的错开浮现只做一次（后续更新不重播）
    final chat = ref.watch(timelineControllerProvider);
    if (chat.skeleton == false && chat.posts.isNotEmpty && !_firstRevealDone) {
      _firstRevealDone = true;
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) setState(() {}); // 浮现完成后清 reveal 延迟
      });
    }

    return SafeArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 页头 heading（对齐 Web heading('时光慢慢，爱意满满', ...) + 「记录此刻」）
        // 2.3.4：页头字阶与试点首页 _PageHeading 同口径——h1 26px/600/ls-0.3
        // （app.js:865 文案逐字 + style.css:342-343/:212；字阶映射 headlineSmall 24）。
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('时光慢慢，爱意满满',
                    // headlineSmall 默认色即 onSurface（不写显式 color：
                    // b_test 431 行「timeline 未误用 onSurface」源码护栏口径）
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.3,
                    )),
                Text('那些一起走过的日子，都在这里。',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: Theme.of(context).colorScheme.outline)),
              ]),
            ),
            FilledButton.tonalIcon(
              onPressed: () => showComposerSheet(context),
              icon: const Icon(Icons.edit_note_rounded, size: 18),
              label: const Text('记录此刻'),
            ),
          ]),
        ),
        _buildFilters(context, me, chat),
        Expanded(child: _buildList(context, me, chat)),
      ]),
    );
  }

  // ── 筛选区（q 防抖 + 筛选盒 + chips + 清除）─────────────────────────

  Widget _buildFilters(BuildContext context, MeData me, TimelineState chat) {
    final theme = Theme.of(context);
    final f = chat.filter;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 2.3.4：筛选控件高 46 档（Web 桌面常开 input+select 高 46，
        // style.css:591-600/:1422）——contentPadding/minimumSize 设自然高，
        // 不用固定高容器（Dropdown 在固定高 Row 内约束冲突）。
        TextField(
          controller: _qController,
          onChanged: _onQueryChanged,
          decoration: const InputDecoration(
            hintText: '搜索我们的故事…',
            prefixIcon: Icon(Icons.search_rounded),
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(AppRadius.card))),
          ),
        ),
        const SizedBox(height: Spacing.gap),
        // 2.3.4（呈现层修复，语义零变化）：原单行三列等分在 393/320 宽放不下
        // 中文长文案（「两个人的时光/所有记录」下拉 + icon + padding ≈120px
        // > 三等分列宽 115px，基线固有溢出，既有测试未覆盖此区域）——改两行
        // 两列：作者/类型一行、日期独占行，控件 46 档保持。
        Row(children: [
          // 作者筛选（两个人的时光 / 各自）
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: f.author.isEmpty ? '' : f.author,
              isDense: true,
              decoration: const InputDecoration(isDense: true,
                  border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6)),
              items: [
                const DropdownMenuItem(value: '', child: Text('两个人的时光', maxLines: 1, overflow: TextOverflow.ellipsis)),
                for (final u in me.users)
                  DropdownMenuItem(value: u.id, child: Text(u.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => ref.read(timelineControllerProvider.notifier).setFilter(
                  f.copyWith(author: v ?? '')),
            ),
          ),
          const SizedBox(width: 8),
          // 类型筛选（image/video/audio）
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: f.media.isEmpty ? '' : f.media,
              isDense: true,
              decoration: const InputDecoration(isDense: true,
                  border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6)),
              items: const [
                DropdownMenuItem(value: '', child: Text('所有记录', maxLines: 1, overflow: TextOverflow.ellipsis)),
                DropdownMenuItem(value: 'image', child: Text('照片', maxLines: 1, overflow: TextOverflow.ellipsis)),
                DropdownMenuItem(value: 'video', child: Text('视频', maxLines: 1, overflow: TextOverflow.ellipsis)),
                DropdownMenuItem(value: 'audio', child: Text('语音', maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => ref.read(timelineControllerProvider.notifier).setFilter(
                  f.copyWith(media: v ?? '')),
            ),
          ),
        ]),
        const SizedBox(height: Spacing.gap),
        Row(children: [
          // 日期筛选（原生 showDatePicker，决策 3）
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                final d = await showDatePicker(
                    context: context,
                    initialDate:
                        DateTime.tryParse(f.date) ?? DateTime.now(),
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now().add(const Duration(days: 365)));
                if (d != null) {
                  ref.read(timelineControllerProvider.notifier).setFilter(
                      f.copyWith(date: _fmt(d)));
                }
              },
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46)),
              icon: const Icon(Icons.event_rounded, size: 16),
              label: Text(f.date.isEmpty ? '日期' : f.date),
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(child: SizedBox()),
        ]),
        if (f.isActive) ...[
          const SizedBox(height: Spacing.gap),
          Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (f.q.isNotEmpty) _chip(theme, '“${f.q}”'),
            if (f.author.isNotEmpty)
              _chip(theme, me.byId(f.author)?.name ?? '作者'),
            if (f.date.isNotEmpty) _chip(theme, f.date),
            if (f.media.isNotEmpty)
              _chip(theme, const {'image': '照片', 'video': '视频', 'audio': '语音'}[f.media] ?? f.media),
            ActionChip(
              label: Text('清除筛选（${f.activeCount}）',
                  style: theme.textTheme.labelSmall),
              onPressed: () {
                _qController.clear();
                ref.read(timelineControllerProvider.notifier).clearFilters();
              },
            ),
          ]),
        ],
      ]),
    );
  }

  // 2.3.4：已激活筛选 chip 对齐 Web `.tabs button.active` 选中态（style.css:337）
  // ——soft 底 + primary 1px 描边 + primary-dark 字 + 600。
  Widget _chip(ThemeData theme, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: theme.colorScheme.primary),
        ),
        child: Text(label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            )),
      );

  // ── 列表（骨架/空态两套/无限滚动/末尾提示）─────────────────────────

  Widget _buildList(BuildContext context, MeData me, TimelineState chat) {
    if (chat.skeleton) return _skeletonList(context);
    if (chat.posts.isEmpty) {
      // 空态两套（文案逐字对齐 Web timelinePage empty(...)）；
      // 首拉失败 → 统一可重试错误态（G14 收编：原页内 Text 散形态）。
      final filtered = chat.filter.isActive;
      final theme = Theme.of(context);
      if (chat.error != null) {
        return Center(
          child: AppErrorView(
            detail: chat.error!,
            onRetry: () => ref
                .read(timelineControllerProvider.notifier)
                .load(reset: true),
          ),
        );
      }
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.auto_stories_rounded, size: 44, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text(filtered ? '没有符合条件的记录' : '这一页，留给新的故事',
              style: theme.textTheme.titleMedium),
          const SizedBox(height: Spacing.gap),
          Text(
              filtered ? '换个条件，或清除筛选再试试。' : '可以发照片、文字、视频，或者留下一段声音。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
        ]),
      );
    }
    return RefreshIndicator(
      onRefresh: () => ref.read(timelineControllerProvider.notifier).load(reset: true),
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        // 🔴 G19 附带修复（原逻辑缺陷）：原 itemCount 只在 hasMore 或
        // loading&&!hasMore 时留尾槽，而「没有更多了」页脚要求
        // !hasMore && posts.isNotEmpty —— 恰好不占任何槽位 → 页脚在
        // 正常到底态永远不可达（真机从不出现）。补齐槽位还原页脚意图：
        // hasMore → 加载更多 spinner；!hasMore 且有内容 → 页脚。
        itemCount: chat.posts.length +
            ((chat.hasMore || chat.posts.isNotEmpty) ? 1 : 0),
        itemBuilder: (context, i) {
          if (i < chat.posts.length) {
            return PostCard(
              // ValueKey 保住 widget 身份：段二 B 本卡原地更新时，
              // 其它卡片不重建、列表不跳位、不闪烁
              key: ValueKey(chat.posts[i].id),
              record: chat.posts[i],
              me: me,
              revealDelayMs: _firstRevealDone ? 0 : (i * 40).clamp(0, 600),
            );
          }
          if (!chat.hasMore && chat.posts.isNotEmpty) {
            // G19（必改）：原 Colors.grey 未走主题、夜间不可控；
            // outline 与 2.1 基线「辅助文字 = outline」同源。
            final cs = Theme.of(context).colorScheme;
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(child: Text('没有更多了',
                  style: TextStyle(color: cs.outline))),
            );
          }
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))),
          );
        },
      ),
    );
  }

  /// 首屏骨架 3 卡（形状对齐 Web timelineSkeletonCards：34px 头像、名字/日期
  /// 两行、标题条 42%、正文条 100%/68%、16:10 媒体块）
  Widget _skeletonList(BuildContext context) {
    final theme = Theme.of(context);
    final lineColor = theme.colorScheme.surfaceContainerHighest;
    Widget line(double w, double h) => Container(
          width: w, height: h,
          decoration: BoxDecoration(color: lineColor, borderRadius: BorderRadius.circular(4)),
        );
    Widget card() => Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          padding: const EdgeInsets.all(Spacing.cardPad),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(width: 34, height: 34,
                  decoration: BoxDecoration(color: lineColor, shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                line(86, 15),
                const SizedBox(height: 4),
                line(112, 11),
              ]),
            ]),
            const SizedBox(height: 12),
            line(120, 15),
            const SizedBox(height: Spacing.gap),
            line(double.infinity, 14),
            const SizedBox(height: Spacing.gap),
            line(double.infinity, 14),
            const SizedBox(height: Spacing.gap),
            line(200, 14),
            const SizedBox(height: 10),
            AspectRatio(aspectRatio: 16 / 10,
                child: Container(
                    decoration: BoxDecoration(
                        color: lineColor, borderRadius: BorderRadius.circular(AppRadius.sm)))),
          ]),
        );
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      children: [card(), card(), card()],
    );
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
