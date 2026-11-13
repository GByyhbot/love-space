/// 回忆周报（条目 6 · 可选段 E，只读）：
/// 契约 /api/weekly?offset=（app/main.py:2126 实读；offset>0 或 <-52 → 422）；
/// 呈现口径逐字对齐 Web weeklyPage（app.js:1317）：周切换（上一周任意往前、
/// 下一周在 off>=0 禁用）→ week-hero（message + delta 文案 + 最常见心情 +
/// streak 行）→ 四联卡（记录/有记录的天数/照片/互动）→ 这一周写了什么 /
/// 心情分布 → 本周精选（highlights 简卡，serialize_many 形状）→ 复制文字版
/// （4 行格式，Web act('week-copy') app.js:2479 逐字）。
/// 🔴 只读：无任何写路径。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/together/together_data.dart';
import '../chat/chat_toast.dart';

class WeeklyPage extends ConsumerStatefulWidget {
  const WeeklyPage({super.key});
  @override
  ConsumerState<WeeklyPage> createState() => _WeeklyPageState();
}

class _WeeklyPageState extends ConsumerState<WeeklyPage> {
  int _offset = 0;
  WeeklyData? _data;
  bool _loading = false;
  String? _error;
  int _reqSeq = 0;

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
          .get('/api/weekly', queryParameters: {'offset': _offset});
      if (!mounted || seq != _reqSeq) return;
      setState(() {
        _data = parseWeekly(r.data);
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

  void _shift(int delta) {
    final next = _offset + delta;
    if (next > 0 || next < -52) return; // 与服务端 422 同口径
    setState(() => _offset = next);
    _load();
  }

  Future<void> _copy() async {
    final w = _data;
    if (w == null) return;
    await Clipboard.setData(ClipboardData(text: weeklyCopyText(w)));
    if (!mounted) return;
    ref.read(chatToastProvider.notifier).show('周报文字已复制');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final w = _data;

    return Scaffold(
      appBar: AppBar(title: const Text('回忆周报')),
      // 周切换固定头部（不进 ListView——滚走会被懒构建卸载，入口消失）；
      // 列表只承载周报正文
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('把这一周，收进一封小小的信。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.outline)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          // 周切换：← 上一周 / 范围 / 下一周（off>=0 禁用，Web 同口径）
          child: Row(children: [
            IconButton(
                tooltip: '上一周',
                onPressed: _loading ? null : () => _shift(-1),
                icon: const Icon(Icons.chevron_left_rounded)),
            Expanded(
              child: Text(
                w?.rangeLabel ?? '',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelLarge,
              ),
            ),
            IconButton(
              tooltip: '下一周',
              onPressed:
                  (_loading || _offset >= 0) ? null : () => _shift(1),
              icon: Icon(Icons.chevron_right_rounded,
                  color: _offset >= 0
                      ? cs.outline.withValues(alpha: 0.4)
                      : null),
            ),
          ]),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                if (_loading && w == null)
                  const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()))
                else if (w != null) ...[
                  _hero(theme, w),
                  const SizedBox(height: 12),
                  _statGrid(theme, [
                    ('记录', '${w.total}', '条'),
                    ('有记录的天数', '${w.daysActive}', '天'),
                    ('照片', '${w.photos}', '张'),
                    ('互动', '${w.likes + w.comments}', '次'),
                  ]),
                  const SizedBox(height: 12),
                  _card(theme, '这一周写了什么', [
                    if (w.kindRows.isEmpty)
                      _meta(theme, '这一周还没有记录。')
                    else
                      for (final (k, n) in w.kindRows)
                        _statRow(theme, kindLabel[k] ?? k,
                            n / (w.total == 0 ? 1 : w.total), '$n'),
                  ]),
                  const SizedBox(height: 12),
                  _card(theme, '心情分布', [
                    if (w.moodRows.isEmpty)
                      _meta(theme, '这一周还没有心情记录。')
                    else
                      _moodRows(theme, w.moodRows),
                  ]),
                  const SizedBox(height: 12),
                  if (w.highlights.isNotEmpty) ...[
                    Text('💗 本周精选', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final r in w.highlights) _highlightCard(theme, r),
                    const SizedBox(height: 12),
                  ],
                  FilledButton.tonalIcon(
                    onPressed: _copy,
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('复制文字版'),
                  ),
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
        ),
      ]),
    );
  }

  Widget _hero(ThemeData theme, WeeklyData w) {
    final cs = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(w.message, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
              w.deltaText +
                  (w.topMood != null ? ' · 这周最常见的心情是 ${w.topMood}' : ''),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: cs.onPrimaryContainer)),
          const SizedBox(height: 4),
          Text(w.streakLine,
              style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold, color: cs.primary)),
        ]),
      ),
    );
  }

  Widget _highlightCard(ThemeData theme, TogetherRecord r) {
    final cs = theme.colorScheme;
    final title = (r.body['title'] ?? '').toString();
    final content = (r.body['content'] ?? '').toString();
    return Card(
      margin: EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6)),
              child: Text(kindLabel[r.kind] ?? r.kind,
                  style: theme.textTheme.labelSmall),
            ),
            const Spacer(),
            Text('❤️ ${r.likeCount} · 💬 ${r.commentCount}',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: cs.outline)),
          ]),
          if (title.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(title, style: theme.textTheme.titleSmall),
          ],
          if (content.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(content,
                maxLines: 3, overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.outline)),
          ],
        ]),
      ),
    );
  }

  // ── 与 dashboard_page 同款小件（两页只读，不共享私有件，各自持有） ──

  Widget _statGrid(ThemeData theme, List<(String, String, String)> items) {
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
                    textAlign: TextAlign.center,
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

  Widget _bar(ThemeData theme, double ratio) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Stack(children: [
        Container(height: 8, color: theme.colorScheme.surfaceContainerHighest),
        FractionallySizedBox(
          widthFactor: ratio.clamp(0.0, 1.0),
          child:
              Container(height: 8, color: theme.colorScheme.primary),
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
        Text(n,
            style: theme.textTheme.bodySmall
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
            Text('$n',
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ]),
        ),
    ]);
  }
}
