/// 数据看板（条目 6 · 可选段 E，只读）：
/// 契约 /api/dashboard（app/main.py:2082 实读）；呈现口径逐字对齐
/// Web dashboardPage（app.js:1303）：四联卡（在一起/共同记录/照片/互动）
/// → 最近一年柱状（12 月旧→新，峰高归一，≥4% 下限）+ 愿望进度
/// → 记录构成 / 心情分布（数量降序，条宽按占比）→ 互动小结。
/// 🔴 只读：数字与 Web 完全同源（服务端已按可见性过滤），无任何写路径。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/together/together_data.dart';

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});
  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  DashboardData? _data;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.get('/api/dashboard');
      if (!mounted) return;
      setState(() {
        _data = parseDashboard(r.data);
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = api.errorDetail(e);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final d = _data;

    return Scaffold(
      appBar: AppBar(title: const Text('数据看板')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text('我们的点点滴滴，都在这里。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.outline)),
            const SizedBox(height: 12),
            if (_loading && d == null)
              const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()))
            else if (d != null) ...[
              _statGrid(theme, [
                ('在一起', d.daysTogether == null ? '—' : '${d.daysTogether}', '天'),
                ('共同记录', '${d.total}', '条'),
                ('照片', '${d.photos}', '张'),
                ('互动', '${(d.likes) + (d.comments)}', '次'),
              ]),
              const SizedBox(height: 12),
              _card(theme, '📖 最近一年', [
                if (d.months.isEmpty)
                  _meta(theme, '还没有记录，写下第一条就会出现在这里。')
                else
                  _monthBars(theme, d.months),
                const SizedBox(height: 6),
                Text('每个月写下的记录条数',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: cs.outline)),
              ]),
              const SizedBox(height: 12),
              _card(theme, '💗 愿望进度', [
                if (d.wishesTotal == 0)
                  _meta(theme, '还没有共同愿望，去许一个吧。')
                else ...[
                  _metaRich(theme, '已实现 ', '${d.wishesDone}',
                      ' / ${d.wishesTotal} 个共同愿望'),
                  const SizedBox(height: 8),
                  _bar(theme, d.wishesDone / d.wishesTotal, tall: true),
                  const SizedBox(height: 6),
                  // Web：wp = wn ? Math.round(wd/wn*100) : 0
                  Text(
                      '完成度 ${(d.wishesDone / d.wishesTotal * 100).round()}%',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: cs.outline)),
                ],
              ]),
              const SizedBox(height: 12),
              _card(theme, '记录构成', [
                if (d.kindRows.isEmpty)
                  _meta(theme, '还没有记录。')
                else
                  for (final (k, n) in d.kindRows)
                    _statRow(theme,
                        kindLabel[k] ?? k, n / (d.total == 0 ? 1 : d.total), '$n'),
              ]),
              const SizedBox(height: 12),
              _card(theme, '心情分布', [
                if (d.moodRows.isEmpty)
                  _meta(theme, '还没有心情记录。')
                else
                  _moodRows(theme, d.moodRows),
              ]),
              const SizedBox(height: 12),
              _card(theme, '💬 互动小结', [
                _statGrid(theme, [
                  ('喜欢', '${d.likes}', '次'),
                  ('留言与评论', '${d.comments}', '条'),
                ], two: true),
                const SizedBox(height: 8),
                Text(
                    '私密日记、草稿与定时惊喜只统计你自己的，另一半看不到；这里的数字只包含你能看到的内容。',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: cs.outline)),
              ]),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.error)),
            ],
          ],
        ),
      ),
    );
  }

  // ── 通用小件 ──────────────────────────────────────────────

  Widget _statGrid(ThemeData theme, List<(String, String, String)> items,
      {bool two = false}) {
    return Row(children: [
      for (final (label, value, unit) in items)
        Expanded(
          child: Card(
            margin: EdgeInsetsDirectional.only(
                end: items.last == (label, value, unit) ? 0 : 8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(children: [
                Text(label,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.outline)),
                const SizedBox(height: 4),
                Row(mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(value,
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(width: 2),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(unit,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.colorScheme.outline)),
                  ),
                ]),
              ]),
            ),
          ),
        ),
    ]);
  }

  Widget _card(ThemeData theme, String title, List<Widget> children) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 10),
          ...children,
        ]),
      ),
    );
  }

  Widget _meta(ThemeData theme, String text) => Text(text,
      style: theme.textTheme.bodySmall
          ?.copyWith(color: theme.colorScheme.outline));

  Widget _metaRich(
      ThemeData theme, String a, String strong, String b) {
    return Text.rich(TextSpan(text: a, style: theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.outline), children: [
      TextSpan(text: strong,
          style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface)),
      TextSpan(text: b,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline)),
    ]));
  }

  /// 最近一年柱状（Web：height=max(4, round(count/peak*100))%）
  Widget _monthBars(ThemeData theme, List<MonthCount> months) {
    final cs = theme.colorScheme;
    final peak = months.fold<int>(1, (s, m) => m.count > s ? m.count : s);
    return SizedBox(
      height: 120,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (final m in months)
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
              Container(
                height: 86.0 *
                    (m.count / peak).clamp(0.04, 1.0),
                width: 14,
                decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(4)),
              ),
              const SizedBox(height: 4),
              Text('${int.tryParse(m.month.substring(5, 7)) ?? ''}月',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: cs.outline, fontSize: 10)),
            ]),
          ),
      ]),
    );
  }

  Widget _bar(ThemeData theme, double ratio, {bool tall = false}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Stack(children: [
        Container(
          height: tall ? 12 : 8,
          color: theme.colorScheme.surfaceContainerHighest,
        ),
        FractionallySizedBox(
          widthFactor: ratio.clamp(0.0, 1.0),
          child: Container(
            height: tall ? 12 : 8,
            color: theme.colorScheme.primary,
          ),
        ),
      ]),
    );
  }

  Widget _statRow(ThemeData theme, String label, double ratio, String n) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        SizedBox(width: 72, child: Text(label, style: theme.textTheme.bodySmall)),
        const SizedBox(width: 8),
        Expanded(child: _bar(theme, ratio)),
        const SizedBox(width: 8),
        Text(n, style: theme.textTheme.bodySmall
            ?.copyWith(fontWeight: FontWeight.bold)),
      ]),
    );
  }

  Widget _moodRows(ThemeData theme, List<(String, int)> rows) {
    final peak = rows.fold<int>(1, (s, r) => r.$2 > s ? r.$2 : s);
    return Column(children: [
      for (final (emoji, n) in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Text(emoji, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 8),
            Expanded(child: _bar(theme, n / peak)),
            const SizedBox(width: 8),
            Text('$n', style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.bold)),
          ]),
        ),
    ]);
  }
}
