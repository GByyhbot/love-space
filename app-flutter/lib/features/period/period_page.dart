/// 生理期主页（条目 8 · 段 8-B · 2.2.2/VC222）。
///
/// 主页顺序逐字对齐 `periodPage :518`：
/// `headBar → hero → warnBlock → entry(数据分析入口卡) → top(整月日历) →
///  log(当天记录) → symBlock(症状统计) → hist(历史卡)`。
/// · **🔴 数据分析入口（段 C 已落地，活入口非死卡）**：对齐 Web
///   `period.js:517` 的 `<button class="card analysis-entry" data-action=
///   "period-analysis">数据分析</button>`，文案「数据分析 / 周期、流量、痛经、
///   体温的变化」；点击 `context.push('/period/analysis')` 进独立二级页。
/// · **提醒不做**（D3 定案）：本页不碰通知渠道 / 提醒 UI。
/// · **🔴 所有数字与着色只消费 8-A 引擎 [period_engine.dart] + 纯展示层
///   [period_meta.dart] / [period_grid.dart]**：cycle / length / nextStart /
///   phases / dayIn / inWindow / dayOfPeriod 一律不在此重算；日期只用引擎
///   [dayNum] / [dayStr] / [spaceTodayIso]，不用本机时区 `DateTime.now()`
///   直接取日历日。
/// · 经期四动作全程**不出现 `end` 键**（`period.js` 全文无 end）。
/// · 返回路径：8-A 已有 `/period` 二级页（`context.push`），本页 AppBar
///   `automaticallyImplyLeading` 不关，返回按钮 + 系统手势都能回 hub。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/sse/sse_client.dart';
import '../../core/together/together_data.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../personal/personal_controller.dart';
import 'period_actions.dart';
import 'period_colors.dart';
import 'period_controller.dart';
import 'period_engine.dart';
import 'period_form.dart';
import 'period_grid.dart';
import 'period_meta.dart';
import 'period_sheets.dart';
import '../../core/theme/tokens.dart';

/// 生理期页。
class PeriodPage extends ConsumerStatefulWidget {
  const PeriodPage({super.key});

  @override
  ConsumerState<PeriodPage> createState() => _PeriodPageState();
}

class _PeriodPageState extends ConsumerState<PeriodPage> {
  /// Web `state.periodDay`：选中日期。**切月不丢**（翻月用 [shiftMonth]
  /// 把选中日夹到目标月，而不是重置回今天）。null = 今天。
  String? _selectedDay;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(periodControllerProvider.notifier).bootstrap());
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(periodControllerProvider);
    // 对方写记录 → 服务端 bump_shared → SSE other/refresh → 重拉（8-A 验收点②）。
    ref.listen(sseEventsProvider, (prev, next) {
      final ev = next.value;
      if (ev?.other == true || ev?.refresh == true) {
        ref.read(periodControllerProvider.notifier).load();
      }
    });

    // 🔴 空间时区（默认 Asia/Shanghai）日历日，不是设备本机时区。
    final utcNow = DateTime.now().toUtc();
    final today = spaceTodayIso(utcNow);
    final nowTime = nowTimeOf(utcNow);
    final rows = <PeriodRow>[
      for (final r in st.records)
        PeriodRow(id: r.id, author: r.author, body: r.body),
    ];
    final d = periodData(rows, today: today);
    final selected = _selectedDay ?? today;
    final grid = buildPeriodMonthGrid(
      year: int.parse(selected.substring(0, 4)),
      month: int.parse(selected.substring(5, 7)),
      d: d,
      records: rows,
      today: today,
      picked: selected,
    );
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final uid = ref.watch(personalCurrentUserProvider);

    return Scaffold(
      // 🔴 automaticallyImplyLeading 不关：返回按钮 + 系统手势都能回上一页。
      appBar: AppBar(title: const Text('生理期')),
      floatingActionButton: FloatingActionButton.extended(
        tooltip: '记一次经期（详细表单）',
        onPressed: () => _openEpisodeForm(null, selected, d, today),
        icon: const Icon(Icons.edit_note_rounded),
        label: const Text('记一次经期'),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(periodControllerProvider.notifier).load(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, Spacing.pageBottom),
          children: [
            // headBar（heading 的副标题；标题在 AppBar）
            Text(periodHeadingSub,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.outline)),
            const SizedBox(height: 12),
            // hero（空态走 :489）
            _heroCard(context, d, rows, today, utcNow),
            // warnBlock（踩线才提示，正常时整块不存在）
            _warnBlock(context, d),
            // entry：数据分析入口卡（段 C 活入口，非死卡；对齐 period.js:517）
            const SizedBox(height: 12),
            _analysisEntry(context),
            const SizedBox(height: 12),
            // top：整月日历
            _calendarCard(context, grid, today, selected),
            const SizedBox(height: 12),
            // log：当天（选中日）记录卡
            _logCard(context, d, rows, selected, today, nowTime),
            // symBlock：症状统计
            _symptomBlock(context, d, rows),
            // hist：一次月经一张卡
            ..._historyCards(context, d, rows, today, uid),
            if (st.error != null) ...[
              const SizedBox(height: 10),
              Text(st.error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.error)),
            ],
          ],
        ),
      ),
    );
  }

  // ── hero（cycleHero :246-277 + periodPage :487-489） ─────────────────

  Widget _heroCard(BuildContext context, PeriodData d, List<PeriodRow> rows,
      String today, DateTime utcNow) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    if (d.items.isEmpty) {
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.cardPad),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(periodEmptyTitle, style: theme.textTheme.titleMedium),
                const SizedBox(height: Spacing.gap),
                Text(periodEmptyText,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.outline)),
              ]),
        ),
      );
    }

    final dayIn = dayInCycle(d);
    final cyc = d.cycle < 1 ? 1 : d.cycle;
    final ph = todayPhase(d, today: today);
    final fert = fertilityOf(d, today);
    final segs = phaseSegments(d);
    final cursor = phaseCursor(d);
    final dayRows = periodDayRowsOf(rows);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.cardPad),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(greetWord(utcNow),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.outline)),
                    const SizedBox(height: 4),
                    Text(heroTitle(d, today),
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(heroTip(d, today),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.outline)),
                    if (fert != null) ...[
                      const SizedBox(height: Spacing.gap),
                      Wrap(crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text('受孕概率 ',
                                style: theme.textTheme.bodySmall),
                            Text(fert[0],
                                style: theme.textTheme.titleSmall?.copyWith(
                                    color: cs.primary,
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(width: 6),
                            Text(fert[1],
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: cs.outline)),
                          ]),
                      // 🔴 免责原文逐字（`:228`，**带句号**），不给百分比。
                      const SizedBox(height: 2),
                      Text(fertilityNote,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: cs.outline)),
                    ],
                  ]),
            ),
            const SizedBox(width: 12),
            Column(children: [
              Semantics(
                label: '周期第 $dayIn 天，共 $cyc 天',
                child: _CycleRing(dayIn: dayIn, percent: heroPercent(d)),
              ),
              const SizedBox(height: 4),
              Text('周期第 $dayIn 天', style: theme.textTheme.labelSmall),
            ]),
          ]),
          const SizedBox(height: 12),
          // `:488` 下次预计（月/日 + 参考值 + 还有/已推迟）
          Text(heroNextLine(d),
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
          const SizedBox(height: 12),
          // phaseBar `:281-289`：四段相对天数权重 + 今天游标
          _phaseBar(context, segs, cursor, ph?.phase),
          const SizedBox(height: 14),
          // `:488` 三联统计（记录天数 = 日记录行数）
          Row(children: [
            _heroStat(context, '平均周期', '${d.cycle}', '天'),
            _heroStat(context, '平均经期', '${d.length}', '天'),
            _heroStat(context, '记录天数', '${dayRows.length}', '天'),
          ]),
        ]),
      ),
    );
  }

  Widget _heroStat(
          BuildContext context, String label, String value, String unit) =>
      Expanded(
        child: Column(children: [
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline)),
          const SizedBox(height: 2),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(value, style: Theme.of(context).textTheme.titleMedium),
            Text(unit, style: Theme.of(context).textTheme.labelSmall),
          ]),
        ]),
      );

  Widget _phaseBar(BuildContext context, List<PhaseSegment> segs,
      double cursor, String? current) {
    // 2.3.9：阶段色走主题变量语义表（period_colors.dart，明暗两档，
    // style.css :57-60/:61-63/:38/:40 浅 + :1510/:1511/:1506 夜），
    // 删除写死四色（原 0xFFEF3F68/0xFF81C784/0xFF9575CD/0xFFFFB74D）。
    final colors = <String, Color>{
      'period': periodStageColor(context),
      'follicular': follicularStageColor(context),
      'fertile': fertileStageColor(context),
      'luteal': lutealStageColor(context),
    };
    return LayoutBuilder(builder: (ctx, constraints) {
      final width = constraints.maxWidth;
      final left = (cursor / 100 * width).clamp(0.0, width);
      return SizedBox(
        height: 34,
        child: Stack(clipBehavior: Clip.none, children: [
          Row(children: [
            for (final s in segs)
              Expanded(
                flex: s.days,
                child: Container(
                  height: 34,
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  decoration: BoxDecoration(
                    color: (colors[s.phase] ?? Colors.grey)
                        .withValues(alpha: s.phase == current ? 0.95 : 0.45),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  alignment: Alignment.center,
                  child: FittedBox(
                    child: Text('${s.name} ${s.days}天',
                        style: Theme.of(ctx)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: Colors.white)),
                  ),
                ),
              ),
          ]),
          Positioned(
            left: (left - 1).clamp(0.0, width - 2),
            top: -2,
            bottom: -2,
            // G10（必改）：「今天」竖线原来是 Colors.black87，深色 surface 上
            // 不可见；onSurface 随 fromSeed 双亮度自适应（浅=近黑、深=近白）。
            child: Container(
                width: 2,
                color: Theme.of(ctx).colorScheme.onSurface),
          ),
        ]),
      );
    });
  }

  // ── warnBlock（periodWarnings :232-245 + periodPage :515-516） ────────

  Widget _warnBlock(BuildContext context, PeriodData d) {
    final warns = periodWarnings(d);
    if (warns.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        margin: EdgeInsets.zero,
        color: cs.errorContainer.withValues(alpha: 0.35),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.cardPad),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(warnBlockTitle,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(color: cs.error)),
                const SizedBox(height: Spacing.gap),
                for (final w in warns)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // G11（必改）：项目符号原 Colors.black54 深色下
                          // 对比不足；与相邻 bodySmall 同源 onSurface。
                          Text('· ',
                              style: TextStyle(color: cs.onSurface)),
                          Expanded(
                              child: Text(w,
                                  style: theme.textTheme.bodySmall)),
                        ]),
                  ),
                const SizedBox(height: 4),
                Text(warnBlockNote,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: cs.outline)),
              ]),
        ),
      ),
    );
  }

  // ── entry：数据分析入口卡（period.js:517 逐字） ───────────────────
  Widget _analysisEntry(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        key: const Key('period-analysis-entry'),
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: () => context.push('/period/analysis'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(children: [
            const Text('📊', style: TextStyle(fontSize: 24)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('数据分析', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text('周期、流量、痛经、体温的变化',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.outline)),
                  ]),
            ),
            Icon(Icons.chevron_right_rounded, color: cs.outline),
          ]),
        ),
      ),
    );
  }

  // ── top：整月日历（periodMonthGrid :174-193 / periodTopCard :292-295） ──

  Widget _calendarCard(BuildContext context, PeriodMonthGridData grid,
      String today, String selected) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // 月份栏：‹ / 今天 / ›
          Row(children: [
            Text('${grid.month} 月', style: theme.textTheme.titleMedium),
            const SizedBox(width: 6),
            Text('${grid.year} 年',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.outline)),
            const Spacer(),
            IconButton(
              tooltip: '上个月',
              icon: const Text('‹', style: TextStyle(fontSize: 24)),
              onPressed: () => _shiftMonth(-1, selected),
            ),
            TextButton(
              onPressed: () => setState(() => _selectedDay = today),
              child: const Text('今天'),
            ),
            IconButton(
              tooltip: '下个月',
              icon: const Text('›', style: TextStyle(fontSize: 24)),
              onPressed: () => _shiftMonth(1, selected),
            ),
          ]),
          const SizedBox(height: Spacing.gap),
          // 星期行
          Row(children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Center(
                  child: Text(const ['日', '一', '二', '三', '四', '五', '六'][i],
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: (i == 0 || i == 6) ? cs.error : cs.outline)),
                ),
              ),
          ]),
          const SizedBox(height: Spacing.gap),
          // 整月网格（lead 个空格 + 逐日格子）。
          // 🔴 不用嵌套 GridView(shrinkWrap)：外层已是 ListView（viewport），
          // 嵌套 shrinkWrap viewport 会让首帧布局反复震荡；按周切 Row 最稳。
          _calendarRows(context, grid),
          const SizedBox(height: 10),
          // 图例四项（Web period.js:294 lg-pill 四项）：色源全部走
          // 2.3.9 主题变量语义表——预测经期用 period 色 α（方块 α.55，
          // Web「浅粉虚线=推算」同源浅化；p-pred 底 rgba(period,.06) :1655）；
          // 排卵日与排卵期同用 --fertile（style.css:61/:1511），消灭原
          // 0xFF7E57C2/0xFF9575CD 两套紫并存。
          Wrap(spacing: 10, runSpacing: 4, children: [
            _legend(context, cs, periodStageColor(context), '月经期'),
            _legend(context, cs, periodStageColor(context), '预测经期'),
            _legend(context, cs, fertileStageColor(context), '排卵期'),
            _legend(context, cs, fertileStageColor(context), '排卵日',
                dot: true),
          ]),
        ]),
      ),
    );
  }

  /// 把 [PeriodMonthGridData] 铺成 7 列的行（周日起），无嵌套 viewport。
  Widget _calendarRows(BuildContext context, PeriodMonthGridData grid) {
    final cells = <Widget>[
      for (var i = 0; i < grid.lead; i++)
        const Expanded(child: SizedBox(height: 38)),
      for (final cell in grid.cells)
        Expanded(
          child: SizedBox(
            height: 38,
            child: Padding(
              padding: const EdgeInsets.all(1.5),
              child: _dayCell(context, cell),
            ),
          ),
        ),
    ];
    while (cells.length % 7 != 0) {
      cells.add(const Expanded(child: SizedBox(height: 38)));
    }
    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += 7) {
      rows.add(Row(children: cells.sublist(i, i + 7)));
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }

  Widget _legend(BuildContext context, ColorScheme cs, Color color, String label,
      {bool dot = false}) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: dot ? Colors.transparent : color.withValues(alpha: 0.55),
            shape: dot ? BoxShape.circle : BoxShape.rectangle,
            borderRadius: dot ? null : BorderRadius.circular(3),
            border: dot ? Border.all(color: color, width: 2) : null,
          ),
        ),
        const SizedBox(width: 4),
        Text(label,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: cs.outline)),
      ]);

  Widget _dayCell(BuildContext context, PeriodDayCell cell) {
    final cs = Theme.of(context).colorScheme;
    final base = _cellColor(cell, cs);
    return Tooltip(
      message: cell.tip,
      child: Semantics(
        label: cell.ariaLabel,
        button: true,
        child: InkWell(
          key: Key('period-day-${cell.iso}'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _selectedDay = cell.iso),
          child: Container(
            decoration: BoxDecoration(
              color: base,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: cell.picked
                    ? cs.primary
                    : cell.isToday
                        ? cs.onSurface
                        : cell.isStart
                            ? cs.primary.withValues(alpha: 0.55)
                            : Colors.transparent,
                width: cell.picked ? 2.5 : (cell.isToday ? 2 : 1),
              ),
            ),
            child: Stack(alignment: Alignment.center, children: [
              Text('${cell.day}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: cell.isToday || cell.isStart
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: _cellText(cell, cs),
                  )),
              if (cell.ovu)
                Positioned(
                  top: 2,
                  right: 3,
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: const BoxDecoration(
                        color: Colors.white, shape: BoxShape.circle),
                  ),
                ),
              if (cell.hasRec)
                const Positioned(
                  bottom: 2,
                  left: 4,
                  child: Icon(Icons.circle, size: 5, color: Colors.white),
                ),
              if (cell.hasLog)
                Positioned(
                  bottom: 2,
                  right: 4,
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                        color: cs.onSurface.withValues(alpha: 0.65),
                        shape: BoxShape.circle),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  Color _cellColor(PeriodDayCell cell, ColorScheme cs) {
    if (cell.phase == null) return cs.surfaceContainerHighest;
    // 2.3.9：格子色走主题变量语义表（同 _phaseBar/_legend 出处）；
    // 排卵日格原写死 0xFF7E57C2 与排卵期 0xFF9575CD 双紫并存，统一为
    // --fertile 单一变量（Web 排卵日圆点即 var(--fertile)，:1643）。
    if (cell.ovu) return fertileStageColor(context);
    final alpha = cell.predicted ? 0.45 : 0.9;
    switch (cell.phase) {
      case 'period':
        return periodStageColor(context).withValues(alpha: alpha);
      case 'follicular':
        return follicularStageColor(context).withValues(alpha: alpha);
      case 'fertile':
        return fertileStageColor(context).withValues(alpha: alpha);
      case 'luteal':
        return lutealStageColor(context).withValues(alpha: alpha);
      default:
        return cs.surfaceContainerHighest;
    }
  }

  Color _cellText(PeriodDayCell cell, ColorScheme cs) {
    if (cell.ovu) return Colors.white;
    if (cell.phase == 'period' && !cell.predicted) return Colors.white;
    return cs.onSurface;
  }

  /// `:195-201` 翻月夹到目标月最后一天；**选中日期状态保留**（只挪日期）。
  void _shiftMonth(int delta, String selected) {
    setState(() => _selectedDay = shiftMonth(selected, delta));
  }

  // ── log：当天记录卡（periodLogCard :298-315） ─────────────────────────

  Widget _logCard(BuildContext context, PeriodData d, List<PeriodRow> rows,
      String day, String today, String nowTime) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final log = periodDayLogOf(rows, day);
    final n = dayNum(day);
    final hit = periodEpisodeOf(d, n);
    final on = hit != null;
    final head = day == today
        ? '今天'
        : '${int.parse(day.substring(5, 7))} 月 '
            '${int.parse(day.substring(8, 10))} 日';
    final ownerRecord = hit == null ? null : _recordById(hit.owner.id);

    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(head, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(on
                        ? '经期第 ${n - hit.ep.start + 1} 天'
                        : '记下这一天，周期会更准',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.outline)),
                  ]),
            ),
            if (ownerRecord != null)
              TextButton(
                onPressed: () =>
                    _openEpisodeForm(ownerRecord, day, d, today),
                child: const Text('改经期长度'),
              ),
          ]),
          const SizedBox(height: Spacing.gap),
          // 经期四动作（走了 / 又来了 / 来了）—— 全程无 end 键。
          Row(children: [
            const Text('🩸', style: TextStyle(fontSize: 18)),
            const SizedBox(width: 8),
            const SizedBox(width: 44, child: Text('经期')),
            const Spacer(),
            if (on) ...[
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _runAction(
                        () => planEnd(d, day), '月经走了'),
                child: const Text('月经走了'),
              ),
              const SizedBox(width: 6),
              FilledButton.tonal(
                onPressed: _busy
                    ? null
                    : () => _runAction(
                        () => planMore(d, day), '月经又来了'),
                child: const Text('月经又来了'),
              ),
            ] else
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _runAction(
                        () => planStart(d, day,
                            clientId: api.newClientId()),
                        '月经来了'),
                child: const Text('月经来了'),
              ),
          ]),
          const Divider(height: 14),
          // 9 字段行
          for (final f in periodLogFields)
            _logRow(context, f[0], f[1], f[2],
                periodValueText(f[0], log), day, today, nowTime),
          // 日记行（`:313`）
          _logRow(context, periodDiaryKey, periodDiaryName, periodDiaryIcon,
              _contentPreview(log), day, today, nowTime),
        ]),
      ),
    );
  }

  String _contentPreview(Map<String, dynamic> log) {
    final s = (log['content'] ?? '').toString();
    return s.length > 16 ? s.substring(0, 16) : s;
  }

  Widget _logRow(BuildContext context, String key, String name, String icon,
      String value, String day, String today, String nowTime) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return InkWell(
      onTap: () => showPeriodLogSheet(context,
          field: key, day: day, today: today, nowTime: nowTime),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(children: [
          Text(icon, style: const TextStyle(fontSize: 17)),
          const SizedBox(width: 10),
          SizedBox(width: 44, child: Text(name, style: theme.textTheme.bodyMedium)),
          Expanded(
            child: Text(value,
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.outline)),
          ),
          const SizedBox(width: 6),
          value.isEmpty
              ? Icon(Icons.add_circle_outline, size: 16, color: cs.primary)
              : Icon(Icons.chevron_right, size: 16, color: cs.outline),
        ]),
      ),
    );
  }

  TogetherRecord? _recordById(String id) {
    for (final r in ref.read(periodControllerProvider).records) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// 执行四动作计划（7-C 错误通道：失败只发 error tone，不发成功通知）。
  Future<void> _runAction(
      PeriodWritePlan Function() build, String actionName) async {
    if (_busy) return;
    setState(() => _busy = true);
    final plan = build();
    final err = await ref
        .read(periodControllerProvider.notifier)
        .executePlan(plan);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      ref
          .read(chatToastProvider.notifier)
          .show('操作失败：$err', tone: ChatToastTone.error);
    } else {
      // Web `toast(...)` 是普通提示；成功语义也走 info，不冒充成功通知。
      ref.read(chatToastProvider.notifier).show(plan.message);
    }
  }

  Future<void> _openEpisodeForm(TogetherRecord? record, String selected,
      PeriodData d, String today) async {
    await showDialog<bool>(
      context: context,
      builder: (_) => PeriodFormDialog(
        record: record,
        presetDay: selected,
        defaultLength: d.length,
        defaultCycle: d.cycle,
        today: today,
      ),
    );
  }

  // ── symBlock：症状统计（periodPage :493-499） ─────────────────────────

  Widget _symptomBlock(
      BuildContext context, PeriodData d, List<PeriodRow> rows) {
    final summary = symptomSummary(d, rows);
    if (summary.items.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.cardPad),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('常出现的症状', style: theme.textTheme.titleSmall),
          const SizedBox(height: Spacing.gap),
          for (final s in summary.items)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                SizedBox(width: 88, child: Text(s.name, style: theme.textTheme.bodySmall)),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: (s.count / summary.total).clamp(0.0, 1.0),
                      minHeight: 8,
                      backgroundColor: cs.surfaceContainerHighest,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text('${s.count} 次', style: theme.textTheme.labelSmall),
              ]),
            ),
          const SizedBox(height: 4),
          Text(summary.note,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: cs.outline)),
        ]),
      ),
    );
  }

  // ── hist：一次月经一张卡（periodPage :502-510） ───────────────────────

  List<Widget> _historyCards(BuildContext context, PeriodData d,
      List<PeriodRow> rows, String today, String uid) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final out = <Widget>[];
    for (final ep in d.episodes.reversed) {
      final startIso = dayStr(ep.start);
      final endIso = dayStr(ep.end);
      final details = episodeDetailDays(ep, rows);
      final author = ep.frags.first.author;
      final authorLabel = author == uid ? '我' : 'TA';
      final chips = episodeSymptoms(ep);
      final words = episodeWords(ep);
      final firstRecord = _recordById(ep.frags.first.id);
      final subtitle = <String>[
        '共 ${ep.length} 天 · ${endIso.substring(5)} 结束',
        if (details > 0) '记了 $details 天细节',
        if (ep.frags.length > 1) '分 ${ep.frags.length} 段记的',
        '$authorLabel 记录',
      ].join(' · ');

      out.add(Card(
        margin: const EdgeInsets.only(top: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  CircleAvatar(
                      radius: 14,
                      child: Text(authorLabel,
                          style: theme.textTheme.labelSmall)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${int.parse(startIso.substring(5, 7))} 月 '
                              '${int.parse(startIso.substring(8, 10))} 日开始',
                              style: theme.textTheme.titleSmall),
                          const SizedBox(height: 2),
                          Text(subtitle,
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: cs.outline)),
                        ]),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多操作',
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑')),
                      PopupMenuItem(
                          value: 'delete', child: Text('删除这次')),
                    ],
                    onSelected: (v) {
                      if (v == 'edit' && firstRecord != null) {
                        _openEpisodeForm(firstRecord, startIso, d, today);
                      }
                      if (v == 'delete') _confirmDeleteEpisode(ep);
                    },
                  ),
                ]),
                if (chips.isNotEmpty) ...[
                  const SizedBox(height: Spacing.gap),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final s in chips)
                        Chip(
                            label: Text(s,
                                style: theme.textTheme.labelSmall),
                            visualDensity: VisualDensity.compact),
                    ],
                  ),
                ],
                if (words.isNotEmpty) ...[
                  const SizedBox(height: Spacing.gap),
                  Text(words, style: theme.textTheme.bodySmall),
                ],
              ]),
        ),
      ));
    }
    return out;
  }

  Future<void> _confirmDeleteEpisode(PeriodEpisode ep) async {
    final ids = deleteEpisodeIds(ep);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(periodDeleteEpisodeTitle),
        content: Text(periodDeleteEpisodeText(ids.length)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error),
              onPressed: () => Navigator.of(dctx).pop(true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    final err = await ref
        .read(periodControllerProvider.notifier)
        .deleteEpisode(ids);
    if (!mounted) return;
    ref.read(chatToastProvider.notifier).show(
        err == null
            ? '已删除，可在个人角落 · 回收站恢复'
            : '删除失败：$err',
        tone: err == null ? ChatToastTone.info : ChatToastTone.error);
  }
}

/// 环形进度（对齐 `cycleHero :269-274` 的 SVG：R=31、C=194.8、
/// `stroke-dashoffset=C*(1-pct/100)`、从 -90° 起画、中心写 dayIn）。
/// [percent] 只取 [heroPercent]（引擎结果换算，Web 实跑对拍过的展示值）。
class _CycleRing extends StatelessWidget {
  const _CycleRing({required this.dayIn, required this.percent});

  final int dayIn;
  final int percent;

  @override
  Widget build(BuildContext context) {
    // 2.3.9：描边走 --period 主题变量纯色（style.css:1699 fill=var(--period)
    // 无渐变；track=rgba(var(--period-rgb),.2) :1698），不再用 cs.primary
    // （fromSeed 派生色，非 Web 周期色）；环内字 period-ink（:1700）。
    return SizedBox(
      width: 72,
      height: 72,
      child: CustomPaint(
        painter: _RingPainter(
          track: periodStageColor(context).withValues(alpha: 0.2),
          fill: periodStageColor(context),
          fraction: (percent / 100).clamp(0.0, 1.0),
        ),
        child: Center(
          child: Text('$dayIn',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: periodInkColor(context),
                  )),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.track,
    required this.fill,
    required this.fraction,
  });

  final Color track;
  final Color fill;
  final double fraction;

  @override
  void paint(Canvas canvas, Size size) {
    const r = 31.0;
    final center = Offset(size.width / 2, size.height / 2);
    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      // 2.3.9：线宽 9（style.css:1698-1699 stroke-width:9，原 6 为旧值）。
      ..strokeWidth = 9;
    final fillPaint = Paint()
      ..color = fill
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, r, trackPaint);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r),
      -math.pi / 2,
      2 * math.pi * fraction,
      false,
      fillPaint,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.fraction != fraction ||
      oldDelegate.track != track ||
      oldDelegate.fill != fill;
}
