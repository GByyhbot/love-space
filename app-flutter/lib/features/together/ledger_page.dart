/// 共同账本（条目 6 · 段 D，kind=ledger）：
/// 汇总卡（月切换，下月封顶）+ 当月总额/累计总额/笔数 + 按人聚合双维度
/// （当月谁付得多 / 累计谁花得多——**付款人=记录作者**）+ 近六个月趋势
/// （空月占位）+ 花在哪（当月按分类）——**算法逐字对齐 Web ledgerPage
/// （app.js:1267-1287，汇总走 together_data.ledgerSummary 唯一实现）**。
/// 表单：金额必填（0–1 亿，支持两位小数）+ 分类七选 + 日期必填 + 备注可选。
/// 金额显示逐字对齐 Web money()：'¥'+toFixed(2)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/together/together_data.dart';
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'together_controller.dart';
import 'tool_pages.dart' show ToolTile;

class LedgerPage extends ConsumerStatefulWidget {
  const LedgerPage({super.key});
  @override
  ConsumerState<LedgerPage> createState() => _LedgerPageState();
}

class _LedgerPageState extends ConsumerState<LedgerPage> {
  late String _month = _currentMonth();

  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(togetherControllerProvider.notifier).bootstrap());
  }

  static String _currentMonth() {
    final d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}';
  }

  void _shiftMonth(int delta) {
    final y = int.parse(_month.substring(0, 4));
    final m = int.parse(_month.substring(5, 7));
    final d = DateTime(y, m + delta, 1);
    final key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
    // 下月封顶（对齐 Web switcher：month>=nowMonth 时禁用下个月）
    if (key.compareTo(_currentMonth()) > 0) return;
    setState(() => _month = key);
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(togetherControllerProvider);
    final me = ref.watch(authProvider.notifier).me;
    final userIds = me?.users.map((u) => u.id).toList() ?? const [];
    final ctrl = ref.read(togetherControllerProvider.notifier);
    final items = ctrl.recordsOf('ledger');
    final sum = ledgerSummary(items, _month, userIds);
    final nowMonth = _currentMonth();
    final isCurrent = _month == nowMonth;
    final yy = int.parse(_month.substring(0, 4));
    final mm = int.parse(_month.substring(5, 7));
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    String nameOf(String id) => me?.byId(id)?.name ?? '?';

    return Scaffold(
      appBar: AppBar(title: const Text('共同账本')),
      floatingActionButton: FloatingActionButton.extended(
        tooltip: '记一笔',
        onPressed: () => _showForm(context, ref, null),
        icon: const Icon(Icons.add_rounded),
        label: const Text('记一笔'),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(togetherControllerProvider.notifier).load(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
          children: [
            Text('一起花的钱，也是共同生活的一部分。',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
            const SizedBox(height: 8),
            // 月份切换（下月封顶）
            Row(children: [
              IconButton(
                  tooltip: '上个月',
                  onPressed: () => _shiftMonth(-1),
                  icon: const Icon(Icons.chevron_left_rounded)),
              Expanded(
                child: Text('$yy 年 $mm 月${isCurrent ? ' · 本月' : ''}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium),
              ),
              IconButton(
                tooltip: '下个月',
                onPressed:
                    _month.compareTo(nowMonth) >= 0 ? null : () => _shiftMonth(1),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ]),
            const SizedBox(height: 4),
            // 汇总卡
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${isCurrent ? '本月' : '$mm 月'}一起花了',
                                    style: theme.textTheme.labelSmall
                                        ?.copyWith(color: cs.outline)),
                                Text(ledgerMoney(sum.monthTotal),
                                    style: theme.textTheme.headlineSmall
                                        ?.copyWith(color: cs.primary)),
                              ]),
                        ),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('累计记录',
                                    style: theme.textTheme.labelSmall
                                        ?.copyWith(color: cs.outline)),
                                Text(ledgerMoney(sum.allTotal),
                                    style: theme.textTheme.headlineSmall),
                              ]),
                        ),
                      ]),
                      const SizedBox(height: 6),
                      Text('这个月 ${sum.monthCount} 笔${sum.monthCount == 0 ? '，还没记过' : ''}',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: cs.outline)),
                      // 当月按人（付款人=作者）
                      for (final (author, v) in sum.byUser)
                        _statRow(theme, nameOf(author),
                            sum.monthTotal > 0 ? v / sum.monthTotal : 0, v),
                      Text('这个月谁付的；合计 ${ledgerMoney(sum.monthTotal)}。',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: cs.outline)),
                      const SizedBox(height: 10),
                      Text('累计谁花得多', style: theme.textTheme.titleSmall),
                      for (final (author, v) in sum.allByUser)
                        _statRow(theme, nameOf(author),
                            sum.allTotal > 0 ? v / sum.allTotal : 0, v),
                      // 近六个月趋势（空月占位）
                      const SizedBox(height: 10),
                      Text('最近六个月', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 6),
                      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        for (final (key, v) in sum.trend)
                          Expanded(
                            child: Column(children: [
                              Text(v > 0 ? '¥${v.round()}' : '',
                                  style: theme.textTheme.labelSmall),
                              const SizedBox(height: 2),
                              Container(
                                height: 44,
                                alignment: Alignment.bottomCenter,
                                child: FractionallySizedBox(
                                  widthFactor: 0.6,
                                  child: Container(
                                    height: _trendHeight(sum.trend, key),
                                    decoration: BoxDecoration(
                                      color: key == _month
                                          ? cs.primary
                                          : cs.primary.withValues(alpha: 0.45),
                                      borderRadius: const BorderRadius.vertical(
                                          top: Radius.circular(4)),
                                    ),
                                  ),
                                ),
                              ),
                              Text('${int.parse(key.substring(5))}月',
                                  style: theme.textTheme.labelSmall
                                      ?.copyWith(color: cs.outline)),
                            ]),
                          ),
                      ]),
                      // 当月花在哪
                      if (sum.byCat.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text('花在哪', style: theme.textTheme.titleSmall),
                        for (final (cat, v) in sum.byCat)
                          _statRow(theme, cat,
                              sum.monthTotal > 0 ? v / sum.monthTotal : 0, v),
                      ],
                    ]),
              ),
            ),
            const SizedBox(height: 10),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(children: [
                  Icon(Icons.savings_rounded, size: 44, color: cs.outline),
                  const SizedBox(height: 12),
                  Text('账本还是空的', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text('一起吃的那顿饭、一起买的那张票，都值得记下来。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.outline)),
                ]),
              )
            else
              // 列表按 body.date 倒序（对齐 Web ledgerPage）
              for (final r in _sortByDateDesc(items)) _buildTile(context, ref, r, me),
            if (st.error != null) ...[
              const SizedBox(height: 10),
              Text(st.error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }

  double _trendHeight(List<(String, double)> trend, String key) {
    final peak = trend.fold<double>(1, (p, t) => t.$2 > p ? t.$2 : p);
    final v = trend.firstWhere((t) => t.$1 == key, orElse: () => (key, 0)).$2;
    if (v <= 0) return 3;
    final pct = v / peak;
    return (6 + pct * 34).clamp(6, 40);
  }

  List<TogetherRecord> _sortByDateDesc(List<TogetherRecord> src) {
    final sorted = [...src];
    sorted.sort((a, b) => (b.body['date'] ?? '')
        .toString()
        .compareTo((a.body['date'] ?? '').toString()));
    return sorted;
  }

  Widget _statRow(ThemeData theme, String label, double ratio, double value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(
            width: 56,
            child: Text(label,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall)),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: ratio.clamp(0, 1), minHeight: 8),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
            width: 76,
            child: Text(ledgerMoney(value),
                textAlign: TextAlign.right,
                style: theme.textTheme.labelSmall)),
      ]),
    );
  }

  Widget _buildTile(BuildContext context, WidgetRef ref, TogetherRecord r,
      MeData? me) {
    final theme = Theme.of(context);
    final amount =
        (num.tryParse('${r.body['amount'] ?? ''}') ?? 0).toDouble();
    return ToolTile(
      record: r,
      onEdit: () => _showForm(context, ref, r),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${ledgerMoney(amount)} · ${(r.body['category'] ?? '其他')}'
            '${(r.body['date'] ?? '').toString().isNotEmpty ? ' · ${(r.body['date'] ?? '')}' : ''}',
            style: theme.textTheme.titleMedium),
        if ((r.body['content'] ?? '').toString().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text((r.body['content'] ?? '').toString(),
                style: theme.textTheme.bodySmall),
          ),
      ]),
    );
  }

  /// 记一笔/编辑表单（对齐 Web recordForm ledger 分支）：amount 必填
  /// （0–1 亿，step 0.01 → 允许两位小数，0 元合法）+ category 七选 +
  /// date 必填（默认今天）+ content 备注可选。编辑回填铁律。
  Future<void> _showForm(
      BuildContext context, WidgetRef ref, TogetherRecord? record) async {
    final editing = record != null;
    final b = record?.body ?? const {};
    final amountCtrl =
        TextEditingController(text: (b['amount'] ?? '').toString());
    var category = ((b['category'] ?? '餐饮') as String);
    if (!ledgerCategories.contains(category)) category = '餐饮';
    final dateCtrl = TextEditingController(
        text: ((b['date'] ?? '') as String).isNotEmpty
            ? (b['date'] as String)
            : todayDateStr());
    final contentCtrl = TextEditingController(text: (b['content'] ?? '').toString());
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDialogState) => AlertDialog(
          title: Text(editing ? '编辑这笔' : '记一笔'),
          content: Form(
            key: formKey,
            child: SizedBox(
              width: 360,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextFormField(
                  controller: amountCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: '金额（元）'),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return '请填写金额';
                    final n = double.tryParse(t);
                    if (n == null) return '金额格式不正确';
                    if (n < 0 || n > 100000000) return '金额需在 0–1 亿之间';
                    return null;
                  },
                ),
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: '分类'),
                  items: [
                    for (final c in ledgerCategories)
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => setDialogState(() => category = v ?? '餐饮'),
                ),
                TextFormField(
                  controller: dateCtrl,
                  readOnly: true,
                  decoration: const InputDecoration(labelText: '花在哪天'),
                  onTap: () async {
                    final picked = await showDatePicker(
                        context: dctx,
                        initialDate:
                            DateTime.tryParse(dateCtrl.text) ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100));
                    if (picked != null) {
                      dateCtrl.text =
                          '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                    }
                  },
                  validator: (v) => (v ?? '').length == 10 ? null : '请选择日期',
                ),
                TextFormField(
                  controller: contentCtrl,
                  maxLines: 2,
                  maxLength: 20000,
                  decoration: const InputDecoration(
                      labelText: '备注（可选）', counterText: ''),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(dctx).pop(false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () {
                  if (formKey.currentState?.validate() ?? false) {
                    Navigator.of(dctx).pop(true);
                  }
                },
                child: Text(editing ? '保存' : '记下来')),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final changes = <String, dynamic>{
      'amount': double.parse(amountCtrl.text.trim()),
      'category': category,
      'date': dateCtrl.text.trim(),
      'content': contentCtrl.text.trim(),
    };
    final err = editing
        ? await ref
            .read(togetherControllerProvider.notifier)
            .edit(record.id, 'ledger', record.body, changes)
        : await ref
            .read(togetherControllerProvider.notifier)
            .add('ledger', changes);
    if (!context.mounted) return;
    ref.read(chatToastProvider.notifier).show(
        err == null ? (editing ? '已保存' : '已记下来') : '保存失败：$err',
        tone: err == null ? ChatToastTone.success : ChatToastTone.error);
  }
}
