/// 生理数据分析页（条目 8 · 段 C · 独立二级页 `/period/analysis`）。
///
/// 逐字对齐 `period.js:674-807` 「生理数据分析」13 板块与文案；所有数字 /
/// 文案只消费 [period_analysis.dart] 的纯 Dart 统计层 [buildAnalysisView]，
/// 该层与 Web 实跑逐项全等（见 `period_c_portrait_test.dart`），本页不再重算。
///
/// · 返回路径：AppBar `automaticallyImplyLeading` 不关 → 返回按钮 + 系统
///   返回手势都能回生理期主页；空态「回到生理期」按钮走同一个 Navigator.pop。
/// · 图表全部走 `CustomPaint`（[PaChart] / [PaDotMatrix]），不引图表库。
/// · 入口：主页 `period.js:517` 的 `analysis-entry` 卡 `context.push` 进本页。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sse/sse_client.dart';
import 'period_analysis.dart';
import 'period_charts.dart';
import 'period_controller.dart';
import 'period_engine.dart';

/// 生理数据分析二级页。
class PeriodAnalysisPage extends ConsumerStatefulWidget {
  const PeriodAnalysisPage({super.key});

  @override
  ConsumerState<PeriodAnalysisPage> createState() =>
      _PeriodAnalysisPageState();
}

class _PeriodAnalysisPageState extends ConsumerState<PeriodAnalysisPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(periodControllerProvider.notifier).bootstrap());
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(periodControllerProvider);
    ref.listen(sseEventsProvider, (prev, next) {
      final ev = next.value;
      if (ev?.other == true || ev?.refresh == true) {
        ref.read(periodControllerProvider.notifier).load();
      }
    });

    // 空间时区（默认 Asia/Shanghai）日历日，不是设备本机时区。
    final today = spaceTodayIso(DateTime.now().toUtc());
    final rows = <PeriodRow>[
      for (final r in st.records)
        PeriodRow(id: r.id, author: r.author, body: r.body),
    ];
    final d = periodData(rows, today: today);
    final a = periodAnalysis(d, rows, today: today);
    final view = buildAnalysisView(a, d);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      // 🔴 automaticallyImplyLeading 不关：返回按钮 + 系统手势都能回主页。
      appBar: AppBar(title: const Text(analysisHeadingTitle)),
      body: RefreshIndicator(
        onRefresh: () => ref.read(periodControllerProvider.notifier).load(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            // `:676-677` page-heading
            Text(analysisHeadingDesc,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.outline)),
            const SizedBox(height: 12),
            if (view.isEmpty)
              _emptyCard(context, cs)
            else ...[
              _overview(context, view.overview!),
              for (final s in view.sections) _section(context, s, view),
              const SizedBox(height: 8),
              Text(analysisFoot,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.outline)),
            ],
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

  // ── `:678` 空态 ───────────────────────────────────────────────────
  Widget _emptyCard(BuildContext context, ColorScheme cs) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(analysisEmptyText,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: cs.outline)),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text(analysisBackButton),
                ),
              ]),
        ),
      );

  // ── ① `:688-702` 概览 ────────────────────────────────────────────
  Widget _overview(BuildContext context, AnalysisOverview o) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final deg = double.tryParse(o.ringDeg) ?? 0;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _ScoreRing(degrees: deg, label: o.ringLabel),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(o.grade, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(o.note,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.outline)),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (_num(o.meterWidth) / 100).clamp(0.0, 1.0),
                        minHeight: 7,
                        backgroundColor: cs.surfaceContainerHighest,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(o.completeLine,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: cs.outline)),
                  ]),
            ),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            _stat(context, '平均周期', o.stats[0]),
            _stat(context, '平均经期', o.stats[1]),
            _stat(context, '记录天数', o.stats[2]),
          ]),
          if (o.warns.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: cs.errorContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('需要留意',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(color: cs.error)),
                    const SizedBox(height: 4),
                    for (final w in o.warns)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text('· $w',
                            style: theme.textTheme.bodySmall),
                      ),
                    if (o.warnsNote != null)
                      Text(o.warnsNote!,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: cs.outline)),
                  ]),
            ),
          ],
          const SizedBox(height: 10),
          Text(o.mini,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: cs.outline)),
        ]),
      ),
    );
  }

  Widget _stat(BuildContext context, String label, String value) => Expanded(
        child: Column(children: [
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline)),
          const SizedBox(height: 2),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(value, style: Theme.of(context).textTheme.titleMedium),
            Text('天',
                style: Theme.of(context).textTheme.labelSmall),
          ]),
        ]),
      );

  // ── `sec()` 卡片分发（13 板块） ───────────────────────────────────
  Widget _section(BuildContext context, AnalysisSection s, AnalysisView view) {
    Widget body;
    switch (s.kind) {
      case 'pred':
        body = _prediction(context, view.prediction!);
        break;
      case 'cycle':
        body = _cycle(context, view.cycle!);
        break;
      case 'len':
        body = _length(context, view.length!, view.lengthChart!);
        break;
      case 'flow':
        body = _grouped(context, '本周期流量对比近半年：', view.flowText!,
            view.flowChart!);
        break;
      case 'pain':
        body = _grouped(context, '', view.painText!, view.painChart!);
        break;
      case 'color':
        body = _dots(context, view.colorDots, view.colorLegend);
        break;
      case 'syms':
        body = _symRows(context, view.symRows);
        break;
      case 'mood':
        body = _mood(context, view.moodChips, view.moodTotal);
        break;
      case 'dis':
        body = _dots(context, view.disDots, view.disLegend);
        break;
      case 'sex':
        body = _sex(context, view);
        break;
      case 'temp':
        body = PaChart(svg: view.tempChart!);
        break;
      case 'weight':
        body = PaChart(svg: view.weightChart!);
        break;
      default:
        body = const SizedBox.shrink();
    }
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(s.title,
                    style: Theme.of(context).textTheme.titleSmall)),
            if (s.sub.isNotEmpty)
              Text(s.sub,
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: Theme.of(context).colorScheme.outline)),
          ]),
          const SizedBox(height: 10),
          body,
        ]),
      ),
    );
  }

  // ② `:705-719` 经期预测
  Widget _prediction(BuildContext context, AnalysisPrediction p) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text.rich(TextSpan(
        style: theme.textTheme.bodySmall,
        children: _leadSpans(p.lead, cs),
      )),
      const SizedBox(height: 12),
      Row(children: [
        for (final c in p.cells)
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: c.cls == 'on'
                    ? cs.primary
                    : c.cls == 'soft'
                        ? cs.primaryContainer
                        : cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Column(children: [
                Text('${c.day}',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: c.cls == 'on'
                          ? cs.onPrimary
                          : c.cls == 'soft'
                              ? cs.onPrimaryContainer
                              : cs.onSurface,
                    )),
                const SizedBox(height: 2),
                Text(c.wd,
                    style: TextStyle(
                      fontSize: 10,
                      color: c.cls == 'on'
                          ? cs.onPrimary
                          : c.cls == 'soft'
                              ? cs.onPrimaryContainer
                              : cs.outline,
                    )),
              ]),
            ),
          ),
      ]),
      const SizedBox(height: 8),
      _legendChips(context, const ['预测开始日', '可能的开始日']),
    ]);
  }

  /// 把 Web `lead`（含 `<b>`）转成富文本，文案与 Web 实跑逐字一致。
  List<InlineSpan> _leadSpans(String lead, ColorScheme cs) {
    final out = <InlineSpan>[];
    final re = RegExp(r'<b>(.*?)</b>');
    var pos = 0;
    for (final m in re.allMatches(lead)) {
      if (m.start > pos) out.add(TextSpan(text: lead.substring(pos, m.start)));
      out.add(TextSpan(
        text: m.group(1),
        style: TextStyle(fontWeight: FontWeight.bold, color: cs.primary),
      ));
      pos = m.end;
    }
    if (pos < lead.length) out.add(TextSpan(text: lead.substring(pos)));
    return out;
  }

  // ③ `:722-734` 周期变化
  Widget _cycle(BuildContext context, AnalysisCycle c) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final k = c.kpi;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (k != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            Expanded(
                child: _kpi(context, '最近 1 个周期', '${k.value} 天', k.tag,
                    k.tag == '正常')),
            Expanded(
                child: _kpi(context, '比平均周期', k.diffText, null, true)),
          ]),
        ),
      Text(c.mini,
          style: theme.textTheme.labelSmall?.copyWith(color: cs.outline)),
      const SizedBox(height: 8),
      for (final r in c.rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            SizedBox(
                width: 78,
                child: Text(r.date, style: theme.textTheme.labelSmall)),
            SizedBox(
              width: 74,
              child: Text(r.chip ?? r.diff ?? '',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: r.diffCls == 'early'
                        ? cs.tertiary
                        : r.diffCls == 'late'
                            ? cs.error
                            : cs.outline,
                  )),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (r.width / 100).clamp(0.0, 1.0),
                  minHeight: 7,
                  backgroundColor: cs.surfaceContainerHighest,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text('${r.days}天', style: theme.textTheme.labelSmall),
          ]),
        ),
    ]);
  }

  Widget _kpi(BuildContext context, String label, String value, String? tag,
      bool normal) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: theme.textTheme.labelSmall?.copyWith(color: cs.outline)),
      const SizedBox(height: 2),
      Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(value, style: theme.textTheme.titleSmall),
        if (tag != null) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: normal
                  ? cs.tertiaryContainer
                  : cs.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(tag,
                style: TextStyle(
                    fontSize: 10,
                    color: normal ? cs.onTertiaryContainer : cs.onErrorContainer)),
          ),
        ],
      ]),
    ]);
  }

  // ④ `:737-745` 经期变化
  Widget _length(BuildContext context, AnalysisLength l, PaSvg chart) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
            child: _kpi(context, '本次经期', '${l.kpi.value} 天', l.kpi.tag,
                l.kpi.tag == '正常')),
        Expanded(
            child: _kpi(context, '和上个周期', l.kpi.diffText, null, true)),
      ]),
      const SizedBox(height: 6),
      Text(l.mini,
          style: theme.textTheme.labelSmall?.copyWith(color: cs.outline)),
      const SizedBox(height: 8),
      PaChart(svg: chart),
    ]);
  }

  // ⑤ / ⑥ 分组柱
  Widget _grouped(BuildContext context, String prefix, String text, PaSvg svg) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text.rich(TextSpan(children: [
        if (prefix.isNotEmpty) TextSpan(text: prefix),
        TextSpan(
            text: text, style: const TextStyle(fontWeight: FontWeight.bold)),
      ], style: theme.textTheme.bodySmall)),
      const SizedBox(height: 10),
      PaChart(svg: svg),
      const SizedBox(height: 8),
      _legendChips(context, const ['本周期', '近半年', '未记录']),
    ]);
  }

  // ⑦ / ⑩ 点阵
  Widget _dots(BuildContext context, List<PaDotRow> rows, String? legend) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PaDotMatrix(rows: rows),
        const SizedBox(height: 6),
        _dotLegend(context, rows, legend),
      ]);

  Widget _dotLegend(BuildContext context, List<PaDotRow> rows, String? legend) {
    final cs = Theme.of(context).colorScheme;
    final seen = <String, String>{};
    for (final row in rows) {
      for (final cell in row.cells) {
        if (cell.color != null) {
          // tip 形如「第N天 深红色」→ 取末段作为图例名。
          final parts = cell.tip.split(' ');
          seen[cell.color!] = parts.length > 1 ? parts.last : cell.tip;
        }
      }
    }
    return Wrap(spacing: 10, runSpacing: 4, children: [
      for (final e in seen.entries)
        Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                  color: _dotColor(e.key, cs), shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Text(e.value, style: TextStyle(fontSize: 10, color: cs.outline)),
        ]),
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: cs.outlineVariant)),
        ),
        const SizedBox(width: 4),
        Text('未记录', style: TextStyle(fontSize: 10, color: cs.outline)),
      ]),
    ]);
  }

  Color _dotColor(String hex, ColorScheme cs) {
    if (hex.startsWith('#') && hex.length == 7) {
      final n = int.tryParse(hex.substring(1), radix: 16);
      if (n != null) return Color(0xFF000000 | n);
    }
    return cs.primary;
  }

  // ⑧ 症状排行
  Widget _symRows(BuildContext context, List<PaSymRow> rows) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(children: [
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            SizedBox(
                width: 88, child: Text(r.name, style: theme.textTheme.bodySmall)),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (r.width / 100).clamp(0.0, 1.0),
                  minHeight: 8,
                  backgroundColor: cs.surfaceContainerHighest,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text('${r.n} 次', style: theme.textTheme.labelSmall),
          ]),
        ),
    ]);
  }

  // ⑨ 心情 chips
  Widget _mood(BuildContext context, List<PaMoodChip> chips, String? total) {
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 6, children: [
        for (final c in chips)
          Chip(
            avatar: Text(c.emoji, style: const TextStyle(fontSize: 14)),
            label: Text('${c.name}  ${c.n}',
                style: const TextStyle(fontSize: 11)),
            visualDensity: VisualDensity.compact,
            backgroundColor: cs.surfaceContainerHighest,
          ),
      ]),
      if (total != null) ...[
        const SizedBox(height: 6),
        Text('共 $total 次心情记录',
            style: TextStyle(fontSize: 11, color: cs.outline)),
      ],
    ]);
  }

  // ⑪ 爱爱
  Widget _sex(BuildContext context, AnalysisView view) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(view.sexLine ?? '', style: theme.textTheme.bodySmall),
      const SizedBox(height: 6),
      Text('近 6 个月',
          style: theme.textTheme.labelSmall?.copyWith(color: cs.outline)),
      const SizedBox(height: 8),
      PaChart(svg: view.monthlyChart!),
    ]);
  }

  Widget _legendChips(BuildContext context, List<String> labels) {
    final cs = Theme.of(context).colorScheme;
    final colors = <Color>[cs.primary, const Color(0xFFA98BD8), cs.outlineVariant];
    return Wrap(spacing: 12, children: [
      for (var i = 0; i < labels.length; i++)
        Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: i < colors.length ? colors[i] : Colors.transparent,
              shape: BoxShape.circle,
              border: i == 2 ? Border.all(color: cs.outlineVariant) : null,
            ),
          ),
          const SizedBox(width: 4),
          Text(labels[i], style: TextStyle(fontSize: 10, color: cs.outline)),
        ]),
    ]);
  }

  double _num(String s) => double.tryParse(s) ?? 0;
}

/// `:690` 规律度 conic 环（`(score||0)*3.6` 度，中心写分数或 `--`）。
class _ScoreRing extends StatelessWidget {
  const _ScoreRing({required this.degrees, required this.label});

  final double degrees;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 84,
      height: 84,
      child: CustomPaint(
        painter: _RingPainter(
          track: cs.surfaceContainerHighest,
          fill: cs.primary,
          fraction: (degrees / 360).clamp(0.0, 1.0),
        ),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(label,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            Text('规律度',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: cs.outline)),
          ]),
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
    final center = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) / 2 - 6;
    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
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
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction || old.track != track || old.fill != fill;
}
