/// 生理期独立二级页（条目 8 · 段 8-A · D1 / D2 / D6）。
///
/// 边界（🔴 本段不越界、不留半成品入口）：
/// · **状态摘要**：当前阶段 / 周期第几天 / 下次预测，**全部来自第 1 步移植的
///   [periodData] / [todayPhase] / [dayInCycle] 引擎**，页面不另写一套推算；
/// · **记录列表 + 两种形状的基本新建/编辑/删除**（经期区间 start/length/cycle/
///   content；日记录 date/content），编辑走回填铁律，删除为软删；
/// · 恢复**不新做入口**，接已有通用 restore（个人角落 · 回收站），
///   见 `period_controller.dart` 文件头；
/// · **B 段内容一律不做**：整月日历网格、9 字段弹层、经期四动作
///   （来了/走了/又来了）、预警、数据分析页、滚轮/多选/数字键盘/受孕概率卡。
///
/// 入口与返回（D1）：hub 🌸 宽卡与聊天 ⊕ 面板都 `context.push('/period')`；
/// 本页 `AppBar` 的 `automaticallyImplyLeading` 保持默认（不关），
/// 返回按钮 + 系统返回手势都能回上一页（阶段 2 通则）。
///
/// 权限（D6）：双方可看可记可改可删，**不加 `author == uid` 门槛**——
/// 每条记录的编辑/删除菜单对所有人开放；恢复限本人由服务端兜
/// （`restore_period_record :1271-1272` 404「记录不存在」，经 7-C 返修后的
/// 错误通道原文呈现，不静默、不发成功通知）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/sse/sse_client.dart';
import '../../core/together/together_data.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'period_controller.dart';
import 'period_engine.dart';

/// 生理期页。
class PeriodPage extends ConsumerStatefulWidget {
  const PeriodPage({super.key});

  @override
  ConsumerState<PeriodPage> createState() => _PeriodPageState();
}

class _PeriodPageState extends ConsumerState<PeriodPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(periodControllerProvider.notifier).bootstrap());
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(periodControllerProvider);
    // 对方写记录 → 服务端 bump_shared → SSE other/refresh → 重拉（验收点②）。
    ref.listen(sseEventsProvider, (prev, next) {
      final ev = next.value;
      if (ev?.other == true || ev?.refresh == true) {
        ref.read(periodControllerProvider.notifier).load();
      }
    });

    // 🔴 注入的是「空间时区（默认 Asia/Shanghai）日历日」，不是设备本机时区：
    // 与 Web app.js:90 today() 1:1；引擎再把该字符串按 UTC 午夜解析（dayNum）。
    final today = spaceTodayIso(DateTime.now().toUtc());
    final d = periodData(_rowsOf(st.records), today: today);
    final sorted = sortPeriodRecords(st.records);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      // 🔴 automaticallyImplyLeading 不关：返回按钮 + 系统手势都能回上一页。
      appBar: AppBar(title: const Text('生理期')),
      floatingActionButton: FloatingActionButton.extended(
        tooltip: '记一笔',
        onPressed: () => _pickNewShape(context, d),
        icon: const Icon(Icons.add_rounded),
        label: const Text('记一笔'),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(periodControllerProvider.notifier).load(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
          children: [
            Text('记下周期，把照顾提前一点。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.outline)),
            const SizedBox(height: 12),
            _summaryCard(context, d, today),
            const SizedBox(height: 10),
            Text(
              '两个人共同维护同一条周期，谁都能记、能改、能删；删除的记录进「个人角落 · 回收站」，30 天内可恢复（仅本人）。',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
            ),
            const SizedBox(height: 12),
            if (sorted.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Column(children: [
                  Icon(Icons.favorite_border_rounded,
                      size: 44, color: cs.outline),
                  const SizedBox(height: 12),
                  Text('还没有记录', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text('点右下角「记一笔」，把这次的第一天记下来。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.outline)),
                ]),
              )
            else
              for (final r in sorted) _recordTile(context, r, d),
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

  /// 把通用记录形状转成引擎入参（引擎只吃 `{id, author, body}`）。
  List<PeriodRow> _rowsOf(List<TogetherRecord> src) => [
        for (final r in src)
          PeriodRow(id: r.id, author: r.author, body: r.body),
      ];

  /// 状态摘要卡：当前阶段 / 周期第几天 / 下次预测，全部来自引擎。
  Widget _summaryCard(BuildContext context, PeriodData d, String today) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final ph = todayPhase(d, today: today);
    final stage = ph == null
        ? (d.items.isEmpty ? '还没有记录' : '周期还在推算')
        : '${phaseNames[ph.phase] ?? ph.phase}${ph.predicted ? '（预测）' : ''}';
    final next = d.nextStartStr == null
        ? '记一次就能推算'
        : '${d.nextStartStr}${d.estimated ? '（参考值）' : ''}';
    final window =
        d.inWindow ? '经期第 ${d.dayOfPeriod} 天' : '今天不在经期里';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('🌸 周期概览', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _stat(theme, cs, '当前阶段', stage)),
            Expanded(
                child: _stat(
                    theme, cs, '周期第', '${dayInCycle(d)} 天')),
            Expanded(child: _stat(theme, cs, '下次预测', next)),
          ]),
          const SizedBox(height: 10),
          Text('平均周期 ${d.cycle} 天 · 平均经期 ${d.length} 天 · $window',
              style:
                  theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
        ]),
      ),
    );
  }

  Widget _stat(ThemeData theme, ColorScheme cs, String label, String value) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: theme.textTheme.labelSmall?.copyWith(color: cs.outline)),
        const SizedBox(height: 2),
        Text(value, style: theme.textTheme.bodyMedium),
      ]);

  /// 记录行：两种形状分别渲染；编辑/删除菜单**不加作者门槛**（D6）。
  Widget _recordTile(
      BuildContext context, TogetherRecord r, PeriodData d) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final shape = periodShapeOf(r.body);
    final b = r.body;
    final isEpisode = shape == PeriodShape.episode;
    final dateLabel = isEpisode
        ? (b['start'] ?? '').toString()
        : (b['date'] ?? '').toString();
    final title = isEpisode ? '经期 · $dateLabel 开始' : '这一天 · $dateLabel';
    final details = isEpisode
        ? '共 ${b['length'] ?? 1} 天 · 周期 ${b['cycle'] ?? '—'} 天'
        : '';
    final content = (b['content'] ?? '').toString();
    final sub = <String>[
      if (details.isNotEmpty) details,
      if (content.isNotEmpty) content,
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(children: [
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  if (sub.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(sub,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.outline)),
                  ],
                ]),
          ),
          // 🔴 D6：不加 `author == uid` 判断，双方都能编辑/删除任意一条。
          PopupMenuButton<String>(
            tooltip: '更多操作',
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('编辑')),
              PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
            onSelected: (v) {
              if (v == 'edit' && shape != PeriodShape.unknown) {
                _openForm(context, shape, r, d);
              }
              if (v == 'delete') _confirmDelete(context, r);
            },
          ),
        ]),
      ),
    );
  }

  /// 新建：先选两种形状之一，再打开对应基础表单。
  Future<void> _pickNewShape(BuildContext context, PeriodData d) async {
    final shape = await showDialog<PeriodShape>(
      context: context,
      builder: (dctx) => SimpleDialog(
        title: const Text('记一笔'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dctx).pop(PeriodShape.episode),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Icon(Icons.bloodtype_outlined),
                SizedBox(width: 12),
                Expanded(
                    child: Text('记一次经期　开始日 / 天数 / 周期')),
              ]),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dctx).pop(PeriodShape.day),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Icon(Icons.event_note_outlined),
                SizedBox(width: 12),
                Expanded(child: Text('记这一天　日期 / 想说的话')),
              ]),
            ),
          ),
        ],
      ),
    );
    if (shape == null || !context.mounted) return;
    await _openForm(context, shape, null, d);
  }

  Future<void> _openForm(BuildContext context, PeriodShape shape,
      TogetherRecord? record, PeriodData d) async {
    await showDialog<bool>(
      context: context,
      builder: (_) => PeriodFormDialog(
        shape: shape,
        record: record,
        // 默认天数也来自引擎（不另写推算）。
        defaultLength: d.length,
        defaultCycle: d.cycle,
      ),
    );
  }

  /// 删除确认（服务端软删 → 个人角落 · 回收站）。
  Future<void> _confirmDelete(BuildContext context, TogetherRecord r) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('删除这条记录'),
        content: const Text('删除后会进入「个人角落 · 回收站」，30 天内可以恢复。'),
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
    final err = await ref.read(periodControllerProvider.notifier).delete(r.id);
    if (!context.mounted) return;
    ref.read(chatToastProvider.notifier).show(
        err == null ? '已删除，可在个人角落 · 回收站恢复' : '删除失败：$err',
        tone:
            err == null ? ChatToastTone.success : ChatToastTone.error);
  }
}

/// 新建/编辑基础表单（**表单 State 的 initState 生成一次 clientId 复用**）。
///
/// 字段按形状：经期 `start/length/cycle/content`；日记录 `date/content`。
/// 失败时：顶部通知（原文）+ 表单内联（原文）**双呈现**，不 pop、输入保留、
/// 不发成功通知、不自动重试（7-C 返修后的错误通道）；请求中按钮禁用防连点。
class PeriodFormDialog extends ConsumerStatefulWidget {
  const PeriodFormDialog({
    super.key,
    required this.shape,
    this.record,
    required this.defaultLength,
    required this.defaultCycle,
  });

  final PeriodShape shape;
  final TogetherRecord? record;
  final int defaultLength;
  final int defaultCycle;

  @override
  ConsumerState<PeriodFormDialog> createState() => _PeriodFormDialogState();
}

class _PeriodFormDialogState extends ConsumerState<PeriodFormDialog> {
  /// 🔴 7-C 教训前置执行：只在 initState 生成一次，失败重试带同一个值
  /// （`api_client.dart:158` `newClientId()`；服务端 `find_by_client` 幂等）。
  late final String _clientId;
  late final TextEditingController _dateCtrl;
  late final TextEditingController _lengthCtrl;
  late final TextEditingController _cycleCtrl;
  late final TextEditingController _contentCtrl;
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  String? _inlineError;
  bool _submitting = false;

  bool get _editing => widget.record != null;
  bool get _isEpisode => widget.shape == PeriodShape.episode;

  @override
  void initState() {
    super.initState();
    _clientId = api.newClientId();
    final b = widget.record?.body ?? const <String, dynamic>{};
    final dayKey = _isEpisode ? 'start' : 'date';
    final rawDate = (b[dayKey] ?? '').toString();
    _dateCtrl = TextEditingController(
        text: rawDate.isNotEmpty
            ? rawDate
            : spaceTodayIso(DateTime.now().toUtc()));
    _lengthCtrl = TextEditingController(
        text: (b['length'] ?? widget.defaultLength).toString());
    _cycleCtrl = TextEditingController(
        text: (b['cycle'] ?? widget.defaultCycle).toString());
    _contentCtrl =
        TextEditingController(text: (b['content'] ?? '').toString());
  }

  @override
  void dispose() {
    _dateCtrl.dispose();
    _lengthCtrl.dispose();
    _cycleCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_dateCtrl.text) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      _dateCtrl.text =
          '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    }
  }

  Future<void> _submit() async {
    if (_submitting) return; // 防连点：请求中不重复发
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _submitting = true;
      _inlineError = null;
    });

    final ctrl = ref.read(periodControllerProvider.notifier);
    final date = _dateCtrl.text.trim();
    final content = _contentCtrl.text.trim();
    String? err;
    if (_editing) {
      // 回填铁律：edit() 内部以原始 body 为底 merge，这里只给改动键。
      final changes = <String, dynamic>{
        if (_isEpisode) ...{
          'start': date,
          'length': int.parse(_lengthCtrl.text.trim()),
          'cycle': int.parse(_cycleCtrl.text.trim()),
        } else ...{
          'date': date,
        },
        'content': content,
      };
      err = await ctrl.edit(widget.record!, changes);
    } else if (_isEpisode) {
      err = await ctrl.addEpisode(
        start: date,
        length: int.parse(_lengthCtrl.text.trim()),
        cycle: int.parse(_cycleCtrl.text.trim()),
        content: content,
        clientId: _clientId,
      );
    } else {
      err = await ctrl.addDay(
          date: date, content: content, clientId: _clientId);
    }
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
    ref.read(chatToastProvider.notifier).show(
        _editing ? '已保存' : '已记下',
        tone: ChatToastTone.success);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final title = _editing
        ? (_isEpisode ? '编辑这次经期' : '编辑这一天')
        : (_isEpisode ? '记一次经期' : '记这一天');
    return AlertDialog(
      title: Text(title),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    controller: _dateCtrl,
                    readOnly: true,
                    decoration: InputDecoration(
                        labelText: _isEpisode ? '这次经期开始于' : '日期'),
                    onTap: _pickDate,
                    validator: (v) =>
                        (v ?? '').length == 10 ? null : '请选择日期',
                  ),
                  if (_isEpisode) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                        child: TextFormField(
                          controller: _lengthCtrl,
                          keyboardType: TextInputType.number,
                          decoration:
                              const InputDecoration(labelText: '经期几天'),
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
                          decoration:
                              const InputDecoration(labelText: '周期几天'),
                          validator: (v) {
                            final n = int.tryParse((v ?? '').trim());
                            return n != null && n >= 15 && n <= 60
                                ? null
                                : '周期需在 15–60 天之间';
                          },
                        ),
                      ),
                    ]),
                  ],
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _contentCtrl,
                    maxLines: 3,
                    maxLength: 2000,
                    decoration: const InputDecoration(
                        labelText: '想说的话（可选）', counterText: ''),
                  ),
                  if (_inlineError != null) ...[
                    const SizedBox(height: 8),
                    Text(_inlineError!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.error)),
                  ],
                ]),
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed:
                _submitting ? null : () => Navigator.of(context).pop(false),
            child: const Text('取消')),
        FilledButton(
            onPressed: _submitting ? null : _submit,
            child: Text(_editing ? '保存' : '记下')),
      ],
    );
  }
}
