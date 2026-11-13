/// 共同年历（条目 6 · 段 B，/api/calendar，main.py:2341 契约实读）：
/// 月视图（上月/今天/下月切换）+ 四色点（纪念日/动态/心情/打卡，图例与
/// Web DOT_KINDS 同色系语义）+ 点某天看当天条目（只读行：纪念/心情/动态/
/// 打卡 N 人完成，文案逐字对齐 Web calDetailHTML app.js:1179）。
/// 🔴 年历整体只读浏览，不在年历里做编辑（编辑回各记录自己的页面）；
/// 纪念日的农历换算由服务端 lunardate 完成，客户端只渲染返回结果。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/together/together_data.dart';
import '../auth/auth_state.dart';

class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});
  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  late String _month = _currentMonth();
  CalendarMonth _data = const CalendarMonth(month: '', days: {});
  String? _selected; // 选中日期（'dd' 两位）
  bool _loading = false;
  String? _error;
  int _reqSeq = 0;

  static String _currentMonth() {
    final d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    final seq = ++_reqSeq;
    setState(() => _loading = true);
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio
          .get('/api/calendar', queryParameters: {'month': _month});
      if (!mounted || seq != _reqSeq) return;
      setState(() {
        _data = parseCalendarMonth(r.data);
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _reqSeq) return;
      setState(() {
        _error = api.errorDetail(e);
        _loading = false;
      });
    }
  }

  void _shiftMonth(int delta) {
    final y = int.parse(_month.substring(0, 4));
    final m = int.parse(_month.substring(5, 7));
    final d = DateTime(y, m + delta, 1); // DateTime 月份本身 1-based，勿再 -1
    setState(() {
      _month =
          '${d.year}-${d.month.toString().padLeft(2, '0')}';
      _selected = null;
    });
    _load();
  }

  void _backToToday() {
    setState(() {
      _month = _currentMonth();
      _selected = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final me = ref.watch(authProvider.notifier).me;
    final y = int.parse(_month.substring(0, 4));
    final m = int.parse(_month.substring(5, 7));
    final firstWeekday = DateTime(y, m, 1).weekday % 7; // 周日=0
    final daysInMonth = DateTime(y, m + 1, 0).day;
    final todayFull = todayDateStr();
    final todayDay = todayFull.startsWith(_month)
        ? int.parse(todayFull.substring(8))
        : -1;
    const dotKinds = [
      ('anniversaries', '纪念日'),
      ('posts', '动态'),
      ('moods', '心情'),
      ('checks', '打卡'),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('共同年历')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            // 月份导航
            Row(children: [
              Expanded(
                child: Text(
                  '$m 月 · $y 年'
                  '${_activeDayCount > 0 ? ' · 记了 $_activeDayCount 天' : ' · 还空着'}',
                  style: theme.textTheme.titleMedium),
              ),
              IconButton(
                  tooltip: '上个月',
                  onPressed: () => _shiftMonth(-1),
                  icon: const Icon(Icons.chevron_left_rounded)),
              TextButton(onPressed: _backToToday, child: const Text('今天')),
              IconButton(
                  tooltip: '下个月',
                  onPressed: () => _shiftMonth(1),
                  icon: const Icon(Icons.chevron_right_rounded)),
            ]),
            if (_loading && _data.month.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator())),
            if (!_loading || _data.month.isNotEmpty) ...[
              const SizedBox(height: 4),
              // 星期行
              Row(children: [
                for (final w in const ['日', '一', '二', '三', '四', '五', '六'])
                  Expanded(
                    child: Center(
                        child: Text(w,
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: cs.outline))),
                  ),
              ]),
              const SizedBox(height: 4),
              // 日格（每行 7 格）
              for (var row = 0;
                  row < (firstWeekday + daysInMonth + 6) ~/ 7;
                  row++)
                Row(children: [
                  for (var col = 0; col < 7; col++)
                    _buildCell(theme, cs, row, col, firstWeekday, daysInMonth,
                        todayDay, dotKinds, me),
                ]),
              const SizedBox(height: 8),
              // 图例
              Wrap(spacing: 12, children: [
                for (final (k, label) in dotKinds)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                        width: 8,
                        height: 8,
                        decoration:
                            BoxDecoration(color: _dotColor(k, cs),
                                shape: BoxShape.circle)),
                    const SizedBox(width: 4),
                    Text(label,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: cs.outline)),
                  ]),
              ]),
              const SizedBox(height: 12),
              _buildDetail(theme, cs, me),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }

  int get _activeDayCount =>
      _data.days.values.where((d) => d.hasEvents).length;

  Color _dotColor(String kind, ColorScheme cs) {
    switch (kind) {
      case 'anniversaries':
        return cs.primary;
      case 'posts':
        return cs.primary.withValues(alpha: 0.6);
      case 'moods':
        return const Color(0xFF43A047); // 绿（Web --green 语义）
      case 'checks':
        return const Color(0xFFFFB300); // 琥珀（Web --amber 语义）
    }
    return cs.outline;
  }

  Widget _buildCell(
      ThemeData theme,
      ColorScheme cs,
      int row,
      int col,
      int firstWeekday,
      int daysInMonth,
      int todayDay,
      List<(String, String)> dotKinds,
      MeData? me) {
    final index = row * 7 + col;
    final day = index - firstWeekday + 1;
    if (day < 1 || day > daysInMonth) {
      return const Expanded(child: SizedBox(height: 46));
    }
    final key = day.toString().padLeft(2, '0');
    final info = _data.days[key];
    final selected = _selected == key;
    final isToday = day == todayDay;
    final isWeekend = col == 0 || col == 6;
    final dots = <String>[];
    if (info != null) {
      for (final (k, _) in dotKinds) {
        final list = switch (k) {
          'anniversaries' => info.anniversaries,
          'posts' => info.posts,
          'moods' => info.moods,
          'checks' => info.checks,
          _ => <Map<String, String>>[],
        };
        if (list.isNotEmpty) dots.add(k);
      }
    }
    return Expanded(
      child: SizedBox(
        height: 46,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _selected = key),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? cs.primaryContainer
                    : isToday
                        ? cs.surfaceContainerHighest
                        : Colors.transparent,
              ),
              child: Text(
                '$day',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: selected
                      ? cs.onPrimaryContainer
                      : isWeekend
                          ? cs.error.withValues(alpha: 0.7)
                          : cs.onSurface,
                  fontWeight: isToday ? FontWeight.bold : null,
                ),
              ),
            ),
            const SizedBox(height: 2),
            SizedBox(
              height: 6,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (final k in dots.take(4))
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    decoration: BoxDecoration(
                        color: _dotColor(k, cs), shape: BoxShape.circle),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  /// 当天条目详情（只读；文案逐字对齐 Web calDetailHTML）
  Widget _buildDetail(ThemeData theme, ColorScheme cs, MeData? me) {
    final selected = _selected;
    if (selected == null) {
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Icon(Icons.calendar_month_rounded, color: cs.outline),
            const SizedBox(width: 10),
            Expanded(
                child: Text('点日历上的某一天，看看那天我们一起记下了什么。',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.outline))),
          ]),
        ),
      );
    }
    final sel = _data.days[selected];
    final y = int.parse(_month.substring(0, 4));
    final m = int.parse(_month.substring(5, 7));
    final wd = '日一二三四五六'[DateTime(y, m, int.parse(selected)).weekday % 7];
    final rows = <Widget>[
      for (final a in sel?.anniversaries ?? [])
        _detailRow(theme, '纪念', (a['title'] ?? '').toString()),
      for (final md in sel?.moods ?? [])
        _detailRow(theme, '心情',
            '${me?.byId(md['author'] ?? '')?.name ?? '?'}: ${md['emoji'] ?? '☀️'}'),
      for (final p in sel?.posts ?? [])
        _detailRow(
            theme, '动态', (p['title'] ?? '').toString().isEmpty
                ? '一份回忆'
                : (p['title'] ?? '').toString()),
      if ((sel?.checks.length ?? 0) > 0)
        _detailRow(theme, '打卡', '${sel!.checks.length} 人完成'),
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('$m 月 ${int.parse(selected)} 日',
                style: theme.textTheme.titleMedium),
            const SizedBox(width: 10),
            Text('$y 年 · 周$wd',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: cs.outline)),
          ]),
          const SizedBox(height: 8),
          if (rows.isEmpty)
            Text('这一天还空着，留一段空白也挺好。',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline))
          else ...rows,
        ]),
      ),
    );
  }

  Widget _detailRow(ThemeData theme, String tag, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6)),
          child: Text(tag, style: theme.textTheme.labelSmall),
        ),
        const SizedBox(width: 8),
        Expanded(
            child: Text(text, style: theme.textTheme.bodyMedium)),
      ]),
    );
  }
}
