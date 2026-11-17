/// 经期区间编辑表单（条目 8 · 段 8-B）：逐字移植 `period.js:809-833` periodForm。
///
/// 字段 `start / length(1–15) / cycle(15–60) / flow / symptoms(多选 chips) / content`；
/// 提交 body 恰为 `{start,length,cycle,flow?,symptoms,content}`（`:824-826`），
/// **无 end、无 date、client_id 在记录顶层**。有记录 PUT `/records/{id}`（不带
/// client_id `:827`）/ 无记录 POST `/records` + client_id（`:828`）。
/// `presetDay` 从日历点进来的那天预填 start（`:811`）—— App 把日历选中日
/// 作为 presetDay 传入（Web periodForm 具备该形参但 recordForm 未传，App 接活）。
///
/// 纪律：`client_id` 由表单 State 的 initState 生成一次、失败重试复用（7-C）；
/// 失败经 `api.writeResponseError` 判 4xx + 服务端 detail 原文，
/// 顶部通知 + 表单内联**双呈现**、不 pop、输入保留、不发成功通知、不自动重试。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/together/together_data.dart';
import '../../core/ui/selection_sheet.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../settings/settings_widgets.dart' show GlassActionBar;
import 'period_actions.dart';
import 'period_controller.dart';
import 'period_meta.dart';
import '../../core/theme/tokens.dart';

/// 经期区间表单（新建 / 编辑）。
class PeriodFormDialog extends ConsumerStatefulWidget {
  const PeriodFormDialog({
    super.key,
    this.record,
    required this.presetDay,
    required this.defaultLength,
    required this.defaultCycle,
    required this.today,
  });

  /// null = 新建；非 null = 编辑（`PUT /records/{record.id}`）。
  final TogetherRecord? record;

  /// 从日历选中日预填「这次经期开始于」（`period.js:811`）。
  final String presetDay;

  /// `period.js:816` `b.length ?? d.length` / `b.cycle ?? d.cycle`（引擎值）。
  final int defaultLength;
  final int defaultCycle;

  /// 空间时区日历日（表单日期默认值来源，不用本机时区）。
  final String today;

  @override
  ConsumerState<PeriodFormDialog> createState() => _PeriodFormDialogState();
}

class _PeriodFormDialogState extends ConsumerState<PeriodFormDialog> {
  /// 🔴 7-C：只在 initState 生成一次，失败重试带同一个值。
  late final String _clientId;
  late final TextEditingController _startCtrl;
  late final TextEditingController _lengthCtrl;
  late final TextEditingController _cycleCtrl;
  late final TextEditingController _contentCtrl;
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  /// 0 = 不记；1–5 = 档位。
  int _flow = 0;
  late final Set<String> _symptoms;
  String? _inlineError;
  bool _submitting = false;

  bool get _editing => widget.record != null;

  @override
  void initState() {
    super.initState();
    _clientId = api.newClientId();
    final b = widget.record?.body ?? const <String, dynamic>{};
    final rawStart = (b['start'] ?? '').toString();
    _startCtrl = TextEditingController(
        text: rawStart.isNotEmpty
            ? rawStart
            : (widget.presetDay.isNotEmpty ? widget.presetDay : widget.today));
    _lengthCtrl = TextEditingController(
        text: (b['length'] ?? widget.defaultLength).toString());
    _cycleCtrl = TextEditingController(
        text: (b['cycle'] ?? widget.defaultCycle).toString());
    _contentCtrl =
        TextEditingController(text: (b['content'] ?? '').toString());

    // `:815` 老数据 flow 是「少/中/多」→ 2/3/4；数字档位原样。
    final rawFlow = b['flow'];
    if (rawFlow is num) {
      _flow = rawFlow.toInt();
    } else if (rawFlow != null) {
      _flow = const <String, int>{'少': 2, '中': 3, '多': 4}[rawFlow.toString()] ??
          0;
    } else {
      _flow = 0;
    }

    _symptoms = <String>{
      if (b['symptoms'] is List)
        for (final s in (b['symptoms'] as List)) s.toString(),
    };
  }

  @override
  void dispose() {
    _startCtrl.dispose();
    _lengthCtrl.dispose();
    _cycleCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  /// `yyyy-MM-dd` → UTC 绝对日期（showDatePicker 用，不读本机时区日历日）。
  DateTime _isoToUtc(String iso) {
    final p = iso.split('-');
    if (p.length == 3) {
      final y = int.tryParse(p[0]);
      final m = int.tryParse(p[1]);
      final d = int.tryParse(p[2].substring(0, p[2].length.clamp(0, 2)));
      if (y != null && m != null && d != null) return DateTime.utc(y, m, d);
    }
    return DateTime.utc(2026, 1, 1);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _isoToUtc(_startCtrl.text),
      firstDate: DateTime.utc(2000),
      lastDate: DateTime.utc(2100),
    );
    if (picked != null) {
      _startCtrl.text = '${picked.year.toString().padLeft(4, '0')}-'
          '${picked.month.toString().padLeft(2, '0')}-'
          '${picked.day.toString().padLeft(2, '0')}';
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _submitting = true;
      _inlineError = null;
    });

    final body = periodFormBody(
      start: _startCtrl.text.trim(),
      lengthText: _lengthCtrl.text.trim(),
      cycleText: _cycleCtrl.text.trim(),
      flowText: _flow == 0 ? '' : '$_flow',
      symptoms: periodSymptoms.where(_symptoms.contains).toList(),
      content: _contentCtrl.text,
      defaultCycle: widget.defaultCycle,
    );
    final plan = planSaveEpisodeForm(
      recordId: widget.record?.id,
      body: body,
      clientId: _clientId,
    );
    final err = await ref
        .read(periodControllerProvider.notifier)
        .executePlan(plan);
    if (!mounted) return;

    if (err != null) {
      // 🔴 失败：原文双呈现、不 pop、输入保留、不自动重试、不发成功通知。
      setState(() {
        _submitting = false;
        _inlineError = err;
      });
      ref
          .read(chatToastProvider.notifier)
          .show('保存失败：$err', tone: ChatToastTone.error);
      return;
    }
    ref.read(chatToastProvider.notifier).show(plan.message);
    Navigator.of(context).pop(true);
  }

  /// 经量显示文案（0=不记，其余查 periodFlow）。
  String _flowLabel() => _flow == 0 ? '不记' : (periodFlow[_flow] ?? '不记');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // 2.4.1 通则 A：居中弹窗改底部表单 sheet（抓手 + 标题 + 关闭圆钮 +
    // 玻璃栏）；字段/校验/提交口径（含失败内联双呈现不 pop）零变化。
    return Padding(
      padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4.5,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: cs.outlineVariant.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          Row(children: [
            Expanded(
                child: Text(_editing ? '编辑这次经期' : '记录这次经期',
                    style: theme.textTheme.titleMedium)),
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
              ),
              child: IconButton(
                  tooltip: '关闭',
                  visualDensity: VisualDensity.compact,
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(false),
                  icon: const Icon(Icons.close_rounded, size: 18)),
            ),
          ]),
          const SizedBox(height: 10),
          Flexible(
            child: SingleChildScrollView(
              child: Form(
                key: _formKey,
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  TextFormField(
                    controller: _startCtrl,
                    readOnly: true,
                    decoration: const InputDecoration(
                        labelText: '这次经期开始于'),
                    onTap: _pickDate,
                    validator: (v) =>
                        (v ?? '').length == 10 ? null : '请选择日期',
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: _lengthCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '经期几天'),
                        validator: (v) {
                          final n = int.tryParse((v ?? '').trim());
                          return n != null && n >= 1 && n <= 15
                              ? null
                              : '经期需在 1–15 天之间';
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _cycleCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '周期几天'),
                        validator: (v) {
                          final n = int.tryParse((v ?? '').trim());
                          return n != null && n >= 15 && n <= 60
                              ? null
                              : '周期需在 15–60 天之间';
                        },
                      ),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  // 2.4.1 通则 B：整体经量下拉改整行选择框 + 底部选择单。
                  InkWell(
                    key: const Key('period-flow-field'),
                    borderRadius: BorderRadius.circular(12),
                    onTap: () async {
                      final picked = await showSelectionSheet<int>(
                        context: context,
                        title: '整体经量',
                        selected: _flow,
                        options: <SelectionOption<int>>[
                          const SelectionOption<int>(value: 0, label: '不记'),
                          for (final entry in periodFlow.entries)
                            SelectionOption<int>(
                                value: entry.key, label: entry.value),
                        ],
                      );
                      if (picked != null) setState(() => _flow = picked);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest
                            .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(children: [
                        Text('整体经量',
                            style: theme.textTheme.labelSmall),
                        const Spacer(),
                        Text(_flowLabel(),
                            style: theme.textTheme.bodyMedium),
                        const SizedBox(width: 6),
                        Icon(Icons.chevron_right_rounded,
                            size: 18, color: cs.outline),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('身体的感受（可多选）',
                      style: theme.textTheme.bodySmall),
                  const SizedBox(height: Spacing.gap),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final s in periodSymptoms)
                        FilterChip(
                          label: Text(s, style: theme.textTheme.bodySmall),
                          selected: _symptoms.contains(s),
                          onSelected: (_) => setState(() {
                            if (_symptoms.contains(s)) {
                              _symptoms.remove(s);
                            } else {
                              // periodForm :813 不设互斥（互斥只在日记录症状弹层
                              // periodMultiSheet :419，两个表单口径不同，逐字对齐）。
                              _symptoms.add(s);
                            }
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _contentCtrl,
                    maxLines: 3,
                    maxLength: 20000,
                    decoration: const InputDecoration(
                        labelText: '想说的话（可选）', counterText: ''),
                  ),
                  const SizedBox(height: Spacing.gap),
                  Text(periodFormNote,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.outline)),
                  if (_inlineError != null) ...[
                    const SizedBox(height: Spacing.gap),
                    Text(_inlineError!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.error)),
                  ],
                ]),
              ),
            ),
          ),
          const SizedBox(height: 10),
          GlassActionBar(
            safeAreaBottom: false,
            cancelLabel: '取消',
            onCancel: _submitting
                ? null
                : () => Navigator.of(context).pop(false),
            saveLabel: '保存',
            onSave: _submit,
            busy: _submitting,
          ),
        ],
      ),
    );
  }
}
