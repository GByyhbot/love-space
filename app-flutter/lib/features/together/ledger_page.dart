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
import '../../core/ui/empty_view.dart';
import '../../core/ui/error_view.dart';
import '../../core/ui/progress.dart';
import '../../core/ui/selection_sheet.dart';
import '../../core/theme/tokens.dart';
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../settings/settings_widgets.dart'
    show GlassActionBar, filledFieldDecoration;
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
          padding: const EdgeInsets.fromLTRB(16, 8, 16, Spacing.pageBottom),
          children: [
            Text('一起花的钱，也是共同生活的一部分。',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
            const SizedBox(height: Spacing.gap),
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
                padding: const EdgeInsets.all(Spacing.cardPad),
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
                      const SizedBox(height: Spacing.gap),
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
                      const SizedBox(height: Spacing.gap),
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
            // 三态优先级（段 C）：首拉 loading 防闪空态 → 空态且加载失败 →
            // 可重试错误态 → 空态 → 列表。
            if (st.loading && items.isEmpty)
              const AppProgress()
            else if (items.isEmpty && st.error != null)
              Center(
                child: AppErrorView(
                  detail: st.error!,
                  onRetry: () =>
                      ref.read(togetherControllerProvider.notifier).load(),
                ),
              )
            else if (items.isEmpty)
              AppEmptyView(
                icon: Icons.savings_rounded,
                title: '账本还是空的',
                hint: '一起吃的那顿饭、一起买的那张票，都值得记下来。',
              )
            else
              // 列表按 body.date 倒序（对齐 Web ledgerPage）
              for (final r in _sortByDateDesc(items)) _buildTile(context, ref, r, me),
            if (st.error != null && items.isNotEmpty) ...[
              const SizedBox(height: 10),
              // 已出列表后的局部刷新失败维持行内错误文本
              AppErrorText(st.error!),
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

  /// 分类彩色字徽（第 15 项：首字 + 淡彩底圆角块，选择框与选择单行共用；
  /// 分类集合/顺序以 ledgerCategories 为准，一增不减）。
  static const _categoryTints = <String, Color>{
    '餐饮': Color(0xFFFFF3E0),
    '交通': Color(0xFFE3F2FD),
    '旅行': Color(0xFFE0F7FA),
    '礼物': Color(0xFFFCE4EC),
    '生活': Color(0xFFE8F5E9),
    '娱乐': Color(0xFFEDE7F6),
    '其他': Color(0xFFF5F5F5),
  };

  Widget _categoryBadge(String c) {
    final tint = _categoryTints[c] ?? const Color(0xFFF5F5F5);
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(c.isEmpty ? '?' : c.substring(0, 1),
          style: Theme.of(context).textTheme.labelSmall),
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
  /// 2.4.1 第 15 项：居中弹窗改底部 sheet（外壳同 composer：抓手 +
  /// 标题 + 关闭圆钮）；金额大输入（¥ 前缀 + 数字字号 1.4×）；分类原生
  /// 下拉改 showSelectionSheet 底部选择单（行 = 彩色字徽「分类首字 +
  /// 淡彩底」+ 名称，选中淡紫底 + 勾、点选即关，分类集合/顺序以
  /// ledgerCategories 现有列表为准一增不减）；花在哪天改整行日期选择框；
  /// 备注圆角填充；取消/记下来移入 GlassActionBar。提交数据口径零变化。
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
    String? dateError;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(AppRadius.lg))),
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDialogState) => Padding(
          padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: MediaQuery.of(dctx).viewInsets.bottom + 12),
          child: Form(
            key: formKey,
            child: Column(mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // 外壳（同 composer sheet）：抓手 + 标题 + 关闭圆钮。
              Column(children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4.5,
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: Theme.of(dctx)
                          .colorScheme
                          .outlineVariant
                          .withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
                Row(children: [
                  Expanded(
                      child: Text(editing ? '编辑这笔' : '记一笔',
                          style: Theme.of(dctx).textTheme.titleMedium)),
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(dctx)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.6),
                    ),
                    child: IconButton(
                        tooltip: '关闭',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => Navigator.of(dctx).pop(false),
                        icon: const Icon(Icons.close_rounded, size: 18)),
                  ),
                ]),
              ]),
              const SizedBox(height: 10),
              // 金额大输入：¥ 前缀 + 数字字号 1.4×（keyboardType 不变）。
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('金额（元）', style: Theme.of(dctx).textTheme.labelSmall),
                const SizedBox(height: 6),
                TextFormField(
                  controller: amountCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: TextStyle(
                      fontSize:
                          (Theme.of(dctx).textTheme.bodyLarge?.fontSize ?? 16) *
                              1.4),
                  decoration: filledFieldDecoration(
                    prefixText: '¥',
                    prefixStyle: TextStyle(
                        fontSize:
                            (Theme.of(dctx).textTheme.bodyLarge?.fontSize ??
                                    16) *
                                1.4,
                        color: Theme.of(dctx).colorScheme.onSurface),
                  ),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return '请填写金额';
                    final n = double.tryParse(t);
                    if (n == null) return '金额格式不正确';
                    if (n < 0 || n > 100000000) return '金额需在 0–1 亿之间';
                    return null;
                  },
                ),
              ]),
              const SizedBox(height: 10),
              // 分类：整行选择框 + 底部选择单（行 = 彩色字徽 + 名称，
              // 选中淡紫底 + 右勾、点选即关）。
              InkWell(
                key: const Key('ledger-category-field'),
                borderRadius: BorderRadius.circular(12),
                onTap: () async {
                  final picked = await showSelectionSheet<String>(
                    context: dctx,
                    title: '分类',
                    selected: category,
                    options: [
                      for (final c in ledgerCategories)
                        SelectionOption(
                            value: c,
                            label: c,
                            leading: _categoryBadge(c)),
                    ],
                  );
                  if (picked != null) {
                    setDialogState(() => category = picked);
                  }
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Theme.of(dctx)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(children: [
                    Text('分类', style: Theme.of(dctx).textTheme.labelSmall),
                    const Spacer(),
                    _categoryBadge(category),
                    const SizedBox(width: 6),
                    Text(category, style: Theme.of(dctx).textTheme.bodyMedium),
                    const SizedBox(width: 6),
                    Icon(Icons.chevron_right_rounded,
                        size: 18, color: Theme.of(dctx).colorScheme.outline),
                  ]),
                ),
              ),
              const SizedBox(height: 10),
              // 花在哪天：整行日期选择框（样式同第 12 项③）。
              InkWell(
                key: const Key('ledger-date-field'),
                borderRadius: BorderRadius.circular(12),
                onTap: () async {
                  final picked = await showDatePicker(
                      context: dctx,
                      initialDate:
                          DateTime.tryParse(dateCtrl.text) ?? DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100));
                  if (picked != null) {
                    setDialogState(() {
                      dateCtrl.text =
                          '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                      dateError = null;
                    });
                  }
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Theme.of(dctx)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(children: [
                    Text('花在哪天',
                        style: Theme.of(dctx).textTheme.labelSmall),
                    const Spacer(),
                    Text(dateCtrl.text.isEmpty ? '请选择' : dateCtrl.text,
                        style: Theme.of(dctx).textTheme.bodyMedium),
                    const SizedBox(width: 6),
                    Icon(Icons.chevron_right_rounded,
                        size: 18, color: Theme.of(dctx).colorScheme.outline),
                  ]),
                ),
              ),
              const SizedBox(height: 10),
              // 备注圆角填充「备注（可选）」。
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('备注（可选）', style: Theme.of(dctx).textTheme.labelSmall),
                const SizedBox(height: 6),
                TextFormField(
                  controller: contentCtrl,
                  maxLines: 2,
                  maxLength: 20000,
                  decoration: filledFieldDecoration(counterText: ''),
                ),
              ]),
              const SizedBox(height: 10),
              if (dateError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(dateError!,
                        style: Theme.of(dctx).textTheme.bodySmall?.copyWith(
                            color: Theme.of(dctx).colorScheme.error)),
                  ),
                ),
              // 取消/记下来（保存）移入玻璃操作栏（sheet 用
              // safeAreaBottom:false，同 composer 口径）。
              GlassActionBar(
                safeAreaBottom: false,
                cancelLabel: '取消',
                onCancel: () => Navigator.of(dctx).pop(false),
                saveLabel: editing ? '保存' : '记下来',
                onSave: () {
                  // 日期必填（dateCtrl 由整行选择框维护，不走 Form 校验）
                  if (dateCtrl.text.trim().length != 10) {
                    setDialogState(() => dateError = '请选择日期');
                    return;
                  }
                  if (formKey.currentState?.validate() ?? false) {
                    Navigator.of(dctx).pop(true);
                  }
                },
              ),
            ]),
          ),
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
