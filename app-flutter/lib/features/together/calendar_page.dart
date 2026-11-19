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
import '../../core/theme/tokens.dart';

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
          padding: const EdgeInsets.fromLTRB(16, 8, 16, Spacing.pageBottom),
          children: [
            if (_loading && _data.month.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator())),
            if (!_loading || _data.month.isNotEmpty) ...[
              // 2.4.7 甲组：整月视图收进一张卡（标题行→星期行→日期网格→
              // 发丝线→图例行）；点选/翻月交互语义零变化。
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(Spacing.cardPad),
                  child: Column(children: [
                    _buildHeader(theme, cs),
                    const SizedBox(height: 10),
                    // 星期行
                    Row(children: [
                      for (final w in const [
                        '日', '一', '二', '三', '四', '五', '六'
                      ])
                        Expanded(
                          child: Center(
                              child: Text(w,
                                  style: theme.textTheme.labelSmall
                                      ?.copyWith(color: cs.outline))),
                        ),
                    ]),
                    const SizedBox(height: 2),
                    // 日格（每行 7 格）
                    for (var row = 0;
                        row < (firstWeekday + daysInMonth + 6) ~/ 7;
                        row++)
                      Row(children: [
                        for (var col = 0; col < 7; col++)
                          _buildCell(theme, cs, row, col, firstWeekday,
                              daysInMonth, todayDay, dotKinds, me),
                      ]),
                    const SizedBox(height: 12),
                    // 发丝线 + 图例行（置卡内底部）
                    Divider(height: 1, thickness: 1, color: cs.outlineVariant),
                    const SizedBox(height: 12),
                    Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 14,
                        runSpacing: 6,
                        children: [
                          for (final (k, label) in dotKinds)
                            Row(mainAxisSize: MainAxisSize.min, children: [
                              Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                      color: _dotColor(k, cs),
                                      shape: BoxShape.circle)),
                              const SizedBox(width: 4),
                              Text(label,
                                  style: theme.textTheme.labelSmall
                                      ?.copyWith(color: cs.outline)),
                            ]),
                        ]),
                  ]),
                ),
              ),
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

  /// 标题行：「2026 年 11 月」单行不折行 + 「记了 N 天」主题色浅底胶囊
  /// + 右侧 ‹（浅底圆钮）/ 今天（主题色文字钮）/ ›（2.4.7 甲组）；
  /// 393 宽单行由标题 Flexible+ellipsis 保证。
  Widget _buildHeader(ThemeData theme, ColorScheme cs) {
    final y = int.parse(_month.substring(0, 4));
    final m = int.parse(_month.substring(5, 7));
    final countLabel =
        _activeDayCount > 0 ? '记了 $_activeDayCount 天' : '还空着';
    return Row(children: [
      Expanded(
        child: Row(children: [
          Flexible(
            child: Text('$y 年 $m 月',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999)),
            child: Text(countLabel,
                maxLines: 1,
                style:
                    theme.textTheme.labelSmall?.copyWith(color: cs.primary)),
          ),
        ]),
      ),
      const SizedBox(width: 4),
      _roundNavBtn(
          theme, cs, Icons.chevron_left_rounded, '上个月', () => _shiftMonth(-1)),
      TextButton(
          onPressed: _backToToday,
          child: Text('今天',
              style: TextStyle(
                  color: cs.primary, fontWeight: FontWeight.w600))),
      _roundNavBtn(theme, cs, Icons.chevron_right_rounded, '下个月',
          () => _shiftMonth(1)),
    ]);
  }

  /// 浅底圆形导航小钮（约 28）。
  Widget _roundNavBtn(ThemeData theme, ColorScheme cs, IconData icon,
      String tooltip, VoidCallback onTap) {
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        padding: EdgeInsets.zero,
        iconSize: 20,
        style: IconButton.styleFrom(
          backgroundColor: cs.surfaceContainerHighest.withValues(alpha: 0.6),
          shape: const CircleBorder(),
        ),
        icon: Icon(icon, color: cs.onSurface),
      ),
    );
  }

  int get _activeDayCount =>
      _data.days.values.where((d) => d.hasEvents).length;

  /// 四色点（2.4.7 甲组 token 化）：原 moods/checks 两处写死
  /// 0xFF43A047/0xFFFFB300 退役，改取 colorScheme 令牌——纪念日=primary、
  /// 动态=primary 60%、心情=tertiary、打卡=secondary；图例与格内圆点
  /// 同源，深浅两色自动成立。
  Color _dotColor(String kind, ColorScheme cs) {
    switch (kind) {
      case 'anniversaries':
        return cs.primary;
      case 'posts':
        return cs.primary.withValues(alpha: 0.6);
      case 'moods':
        return cs.tertiary;
      case 'checks':
        return cs.secondary;
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
            // 今天=主题色实心圆白字加粗；选中日=主题色描边圆（2.4.7 甲组）。
            Container(
              key: selected
                  ? const Key('calendar-selected-ring')
                  : isToday
                      ? const Key('calendar-today-circle')
                      : null,
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isToday ? cs.primary : Colors.transparent,
                border: selected
                    ? Border.all(color: cs.primary, width: 1.5)
                    : null,
              ),
              alignment: Alignment.center,
              child: Text(
                '$day',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isToday
                      ? cs.onPrimary
                      : isWeekend
                          ? cs.error.withValues(alpha: 0.7)
                          : cs.onSurface,
                  fontWeight: isToday || selected ? FontWeight.bold : null,
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
      // 提示卡：主题色浅底圆角卡 + 白底圆角方形图标底座（2.4.7 甲组）。
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Spacing.cardPad),
        decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppRadius.card)),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(AppRadius.sm)),
            alignment: Alignment.center,
            child: Icon(Icons.calendar_month_rounded,
                size: 22, color: cs.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
              child: Text('点日历上的某一天，看看那天我们一起记下了什么。',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.onSurface.withValues(alpha: 0.8)))),
        ]),
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
        padding: const EdgeInsets.all(Spacing.cardPad),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('$m 月 ${int.parse(selected)} 日',
                style: theme.textTheme.titleMedium),
            const SizedBox(width: 10),
            Text('$y 年 · 周$wd',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: cs.outline)),
          ]),
          const SizedBox(height: Spacing.gap),
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
