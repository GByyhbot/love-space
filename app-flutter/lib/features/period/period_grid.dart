/// 生理期整月网格数据（条目 8 · 段 8-B · 纯 Dart，可单测）。
///
/// 🔴 硬边界（主人 8-B 第 1 条）：**所有数字与着色只消费 8-A 的
/// [period_engine.dart]，禁止第二套公式**。
/// · 阶段 / 预测 / 排卵日：只调 [cyclePhases]（引擎单一实现）；
/// · 每一天的 ISO 串：只调 [dayNum] / [dayStr]（引擎 :30-31）；
/// · 「今天」由调用方注入 [today]（来自 [spaceTodayIso]，非本机时区）；
/// · `lead` / `days` 是日历结构（周几 / 月天数），用 UTC 天序号推算，
///   **不是** cycle / length / nextStart / phases / dayIn / inWindow /
///   dayOfPeriod 中的任何一项，页面 widget 一律不再自行计算这些量。
///
/// 逐字移植 `period.js:174-193` `periodMonthGrid(y,m,d)` 的 class 集合：
/// `ph-{phase}` / `ph-pred` / `ph-ovu` / `ph-start` / `is-today` /
/// `has-rec` / `has-log` / `picked`，并保留 `:189` 的 tip 逐字文案。
/// `:179` 月初第一格取上月最后一天的 phase 作 `prevPhase`，避免每月 1 号
/// 被误标成阶段第一天（对拍夹具 2026-07 专门覆盖）。
library;

import 'period_engine.dart';

String _pad2(int v) => v.toString().padLeft(2, '0');

/// `String(s).slice(0,10)` 的 Dart 等价（`period.js:35`/`:181`）。
String _iso10(String s) => s.length >= 10 ? s.substring(0, 10) : s;

/// 整月网格里某一天的格子数据（与 Web `<button class="cal-day…">` 一一对应）。
class PeriodDayCell {
  const PeriodDayCell({
    required this.iso,
    required this.day,
    required this.month,
    required this.phase,
    required this.predicted,
    required this.ovu,
    required this.isStart,
    required this.hasRec,
    required this.hasLog,
    required this.isToday,
    required this.picked,
    required this.tip,
  });

  /// `yyyy-MM-dd`（引擎 [dayStr]）。
  final String iso;

  /// 月内第几天（1 起）。
  final int day;

  /// 月份（1–12，`aria-label` 用不带前导零的数字）。
  final int month;

  /// 阶段名（period / follicular / fertile / luteal），null = 无阶段。
  final String? phase;
  final bool predicted;
  final bool ovu;
  final bool isStart;
  final bool hasRec;
  final bool hasLog;
  final bool isToday;
  final bool picked;

  /// `period.js:189` tip 文案（' · ' 连接）。
  final String tip;

  /// Web `:191` class 属性按空格切分后的有序 token（含 `cal-day`）。
  /// 顺序恒为：cal-day → ph-{phase} → ph-pred → ph-ovu → ph-start →
  /// is-today → has-rec → has-log → picked。
  List<String> get classes => <String>[
        'cal-day',
        if (phase != null) 'ph-$phase',
        if (phase != null && predicted) 'ph-pred',
        if (phase != null && ovu) 'ph-ovu',
        if (phase != null && isStart) 'ph-start',
        if (isToday) 'is-today',
        if (hasRec) 'has-rec',
        if (hasLog) 'has-log',
        if (picked) 'picked',
      ];

  /// Web `:191` `aria-label="${m} 月 ${v} 日，${tip}"`。
  String get ariaLabel => '$month 月 $day 日，$tip';

  /// 着色键（页面按此选色；**不**在 widget 里重算 phase）。
  String get colorKey {
    if (phase == null) return 'none';
    if (ovu) return 'ovu';
    if (predicted) return 'pred';
    return phase!;
  }
}

/// 整月网格数据。
class PeriodMonthGridData {
  const PeriodMonthGridData({
    required this.year,
    required this.month,
    required this.lead,
    required this.days,
    required this.cells,
  });

  final int year;
  final int month;

  /// 月初前置空格数（`new Date(Date.UTC(y,m-1,1)).getUTCDay()`，0=周日）。
  final int lead;

  /// 当月天数。
  final int days;

  /// 1..[days] 的格子，按日期升序。
  final List<PeriodDayCell> cells;
}

/// 逐字移植 `period.js:174-193` `periodMonthGrid(y,m,d)`。
///
/// [d] 来自 [periodData]（引擎）；[records] 是同一份原始记录，仅用于
/// `has-log`（日记录行）；[today] / [picked] 由页面注入（空间时区日历日）。
/// 绝不读 `DateTime.now()`、绝不读设备本机时区。
PeriodMonthGridData buildPeriodMonthGrid({
  required int year,
  required int month,
  required PeriodData d,
  required List<PeriodRow> records,
  required String today,
  required String picked,
}) {
  final mm = _pad2(month);
  final prefix = '$year-$mm-';
  final firstIso = '${prefix}01';
  final firstN = dayNum(firstIso);

  // `:175` lead = 当月 1 号的星期（JS getUTCDay：0=周日）。
  // 1970-01-01（dayNum 0）是周四，JS getUTCDay 为 4；UTC 天序号 +4 再模 7
  // 即该天星期，与 `Date.UTC(y,m-1,1).getUTCDay()` 逐日一致。
  final lead = (4 + firstN) % 7;

  // `:175` days = `Date.UTC(y,m,0).getUTCDate()`。用引擎 dayStr 逐日推进
  // 到「下个月 1 号」为止，纯 UTC、与任何时区无关。
  var days = 1;
  while (dayStr(firstN + days).startsWith(prefix)) {
    days++;
  }

  // 🔴 阶段着色：只调引擎 cyclePhases，页面不许第二套公式。
  final phases = cyclePhases(d);

  // `:180-181` recs = 参与推算的经期行 start 日（前 10 位）。
  final recs = <String>{for (final r in d.items) _iso10(r.start)};
  // `:36/:176` logs = 日记录行 date（前 10 位）。
  final logs = <String>{
    for (final r in records)
      if (r.isDayRow) _iso10(r.date),
  };

  // `:179` 月初第一格的「上一段」取上月最后一天的 phase。
  var prevPhase = phases[dayStr(firstN - 1)]?.phase ?? '';

  final cells = <PeriodDayCell>[];
  for (var v = 1; v <= days; v++) {
    final iso = dayStr(firstN + v - 1);
    final ph = phases[iso];
    // `:185` isStart = 该日 phase 与前一天 phase 不同。
    final isStart = ph != null && ph.phase != prevPhase;
    prevPhase = ph?.phase ?? '';
    final rec = recs.contains(iso);
    final log = logs.contains(iso);

    // `:189` tip 逐字（顺序：阶段名 / 排卵日 / 记录点 / 记过或点一下）。
    final parts = <String>[
      ph != null
          ? '${phaseNames[ph.phase] ?? ph.phase}${ph.predicted ? '（预测）' : ''}'
          : '还没有记录',
      if (ph != null && ph.ovu) '排卵日',
      if (rec) '这次经期的第一天',
      log ? '这天记过身体情况' : '点一下记这天',
    ];

    cells.add(PeriodDayCell(
      iso: iso,
      day: v,
      month: month,
      phase: ph?.phase,
      predicted: ph?.predicted ?? false,
      ovu: ph?.ovu ?? false,
      isStart: isStart,
      hasRec: rec,
      hasLog: log,
      isToday: iso == today,
      picked: iso == picked,
      tip: parts.join(' · '),
    ));
  }

  return PeriodMonthGridData(
    year: year,
    month: month,
    lead: lead,
    days: days,
    cells: cells,
  );
}

/// 逐字移植 `period.js:195-201` `shiftMonth(day,delta)`：翻月把日期夹到
/// 目标月最后一天（1/31 往前翻不能跳到 3 月）。
///
/// 只用 UTC 绝对日期运算 + 引擎 [dayNum]/[dayStr] 归一化输出，
/// 不读 `DateTime.now()`、不用本机时区。
String shiftMonth(String day, int delta) {
  final y = int.parse(day.substring(0, 4));
  final m0 = int.parse(day.substring(5, 7)) - 1 + delta; // 0-based，可越界
  // JS `new Date(Date.UTC(y,m,1))`：m 越界时自动跨年；Dart DateTime.utc 同款。
  final dt = DateTime.utc(y, m0 + 1, 1);
  final last = DateTime.utc(dt.year, dt.month + 1, 0).day;
  final dayOfMonth = int.parse(day.substring(8));
  final date = dayOfMonth < last ? dayOfMonth : last;
  return dayStr(dayNum(
      '${dt.year.toString().padLeft(4, '0')}-${_pad2(dt.month)}-${_pad2(date)}'));
}
