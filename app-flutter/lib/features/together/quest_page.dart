/// 恋爱清单（条目 6 · 段 D，kind=quest）：
/// 进度卡（一起完成 X/Y + 百分比，对齐 Web questPage）+ 清单列表（未完成在前）
/// + 自定义输入 + 精选清单一键添加（QUEST_IDEAS 过滤已存在，40 条逐字对齐）。
/// 完成机制 = **记录级 PUT body 只翻转 done**（app.js:2537 toggle-quest 同口径，
/// 非 check 子资源）；编辑回填铁律；删除软删+确认；⋯ 仅本人。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/together/together_data.dart';
import '../../core/ui/empty_view.dart';
import '../../core/ui/error_view.dart';
import '../../core/ui/progress.dart';
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'together_controller.dart';
import 'tool_pages.dart' show ToolTile;
import '../../core/theme/tokens.dart';

class QuestPage extends ConsumerStatefulWidget {
  const QuestPage({super.key});
  @override
  ConsumerState<QuestPage> createState() => _QuestPageState();
}

class _QuestPageState extends ConsumerState<QuestPage> {
  final _customCtrl = TextEditingController();
  final _customKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(togetherControllerProvider.notifier).bootstrap());
  }

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(togetherControllerProvider);
    final me = ref.watch(authProvider.notifier).me;
    final ctrl = ref.read(togetherControllerProvider.notifier);
    final items = sortQuests(ctrl.recordsOf('quest'));
    final done = items.where((r) => r.body['done'] == true).length;
    final total = items.length;
    final pct = total == 0 ? 0 : (done / total * 100).round();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final ideas = [
      for (final entry in questIdeas.entries)
        for (final t in entry.value)
          if (!items.any((r) => (r.body['title'] ?? '') == t))
            (entry.key, t),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('恋爱清单')),
      floatingActionButton: FloatingActionButton.extended(
        tooltip: '添加小事',
        onPressed: () => _showForm(context, ref, null),
        icon: const Icon(Icons.add_rounded),
        label: const Text('添加小事'),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(togetherControllerProvider.notifier).load(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, Spacing.pageBottom),
          children: [
            Text('一件小事，也是一个故事。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.outline)),
            const SizedBox(height: Spacing.gap),
            if (total > 0) ...[
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(Spacing.cardPad),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('💫 一起完成 $done / $total',
                            style: theme.textTheme.titleMedium),
                        const SizedBox(height: Spacing.gap),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                              value: pct / 100, minHeight: 10),
                        ),
                        const SizedBox(height: Spacing.gap),
                        Text(
                          '$pct% · ${pct >= 100 ? '全部做完了，可以写新的清单了' : pct >= 50 ? '已经过半，继续' : '慢慢来，一件一件做'}',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: cs.outline),
                        ),
                      ]),
                ),
              ),
              const SizedBox(height: 10),
            ],
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
                icon: Icons.auto_awesome_rounded,
                title: '清单还空着',
                hint: '从下面挑几件，或者写下你们自己的。',
              )
            else
              for (final r in items) _buildTile(context, ref, r, me),
            // 自定义输入（对齐 Web quest-custom-form）
            Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Form(
                  key: _customKey,
                  child: Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: _customCtrl,
                        maxLength: 80,
                        decoration: const InputDecoration(
                            hintText: '想一起做的一件小事…',
                            counterText: ''),
                        validator: (v) =>
                            (v ?? '').trim().isEmpty ? null : null,
                      ),
                    ),
                    IconButton(
                      tooltip: '加入清单',
                      onPressed: () async {
                        final title = _customCtrl.text.trim();
                        if (title.isEmpty) return;
                        final err = await ctrl.add('quest',
                            {'title': title, 'category': '日常', 'done': false});
                        if (!context.mounted) return;
                        // 🔴 写失败丢草稿修复（段 C 2.3.0）：原 _customCtrl.clear()
                        // 在 err 判定前执行——写失败后输入已被清空。按全 App
                        // 纪律改齐：只有成功才清空；失败时输入保留、弹层（行）
                        // 不关、错误 detail 原文走 toast error tone，可原地重试。
                        if (err == null) _customCtrl.clear();
                        ref.read(chatToastProvider.notifier).show(
                            err == null ? '已加入清单' : '添加失败：$err',
                            tone: err == null
                                ? ChatToastTone.success
                                : ChatToastTone.error);
                      },
                      icon: const Icon(Icons.add_rounded),
                    ),
                  ]),
                ),
              ),
            ),
            // 精选清单（过滤已添加；对齐 Web ideaBlock）
            if (ideas.isNotEmpty)
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('没灵感？从精选清单里挑（剩余 ${ideas.length} 条）',
                            style: theme.textTheme.labelLarge),
                        const SizedBox(height: Spacing.gap),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final (cat, t) in ideas)
                              ActionChip(
                                label: Text('＋ $t',
                                    style: theme.textTheme.labelSmall),
                                onPressed: () async {
                                  final err = await ctrl.add('quest', {
                                    'title': t,
                                    'category': cat,
                                    'done': false,
                                  });
                                  if (!context.mounted) return;
                                  ref.read(chatToastProvider.notifier).show(
                                      err == null ? '已加入清单' : '添加失败：$err',
                                      tone: err == null
                                          ? ChatToastTone.success
                                          : ChatToastTone.error);
                                },
                              ),
                          ],
                        ),
                      ]),
                ),
              ),
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

  Widget _buildTile(BuildContext context, WidgetRef ref, TogetherRecord r,
      MeData? me) {
    final theme = Theme.of(context);
    final isDone = r.body['done'] == true;
    return ToolTile(
      record: r,
      onEdit: () => _showForm(context, ref, r),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          // 完成勾选：双方可点（Web toggle-quest 口径；非本人 PUT 403 → 错误通知）
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () async {
              final err = await ref
                  .read(togetherControllerProvider.notifier)
                  .toggleQuestDone(r);
              if (!context.mounted) return;
              ref.read(chatToastProvider.notifier).show(
                  err == null ? '已更新' : '更新失败：$err',
                  tone: err == null ? ChatToastTone.success : ChatToastTone.error);
            },
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                isDone
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 26,
                color: isDone
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text((r.body['title'] ?? '').toString(),
                style: theme.textTheme.titleMedium?.copyWith(
                    decoration: isDone
                        ? TextDecoration.lineThrough
                        : TextDecoration.none)),
          ),
        ]),
        const SizedBox(height: 4),
        Text(
          '${(r.body['category'] ?? '日常')}'
          '${(r.body['date'] ?? '').toString().isNotEmpty ? ' · 计划 ${(r.body['date'] ?? '')}' : ''}'
          '${isDone ? ' · 已完成' : ''}',
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
      ]),
    );
  }

  /// 添加/编辑表单（对齐 Web recordForm quest 分支）：title 必填 +
  /// category 六选 + date 可选 + content 可选。编辑回填铁律。
  Future<void> _showForm(
      BuildContext context, WidgetRef ref, TogetherRecord? record) async {
    final editing = record != null;
    final b = record?.body ?? const {};
    final titleCtrl = TextEditingController(text: (b['title'] ?? '').toString());
    var category = ((b['category'] ?? '日常') as String);
    if (!questCategories.contains(category)) category = '日常';
    final dateCtrl = TextEditingController(text: (b['date'] ?? '').toString());
    final contentCtrl = TextEditingController(text: (b['content'] ?? '').toString());
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDialogState) => AlertDialog(
          title: Text(editing ? '编辑小事' : '添加小事'),
          content: Form(
            key: formKey,
            child: SizedBox(
              width: 360,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextFormField(
                  controller: titleCtrl,
                  autofocus: !editing,
                  maxLength: 200,
                  decoration:
                      const InputDecoration(labelText: '标题', counterText: ''),
                  validator: (v) => (v ?? '').trim().isEmpty ? '请填写标题' : null,
                ),
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: '分类'),
                  items: [
                    for (final c in questCategories)
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => setDialogState(() => category = v ?? '日常'),
                ),
                TextFormField(
                  controller: dateCtrl,
                  readOnly: true,
                  decoration: const InputDecoration(labelText: '计划日期（可选）'),
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
                ),
                TextFormField(
                  controller: contentCtrl,
                  maxLines: 2,
                  maxLength: 20000,
                  decoration: const InputDecoration(
                      labelText: '补充一些小细节（可选）', counterText: ''),
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
                child: Text(editing ? '保存' : '添加')),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final changes = <String, dynamic>{
      'title': titleCtrl.text.trim(),
      'category': category,
      'date': dateCtrl.text.trim(),
      'content': contentCtrl.text.trim(),
      if (!editing) 'done': false,
    };
    final err = editing
        ? await ref
            .read(togetherControllerProvider.notifier)
            .edit(record.id, 'quest', record.body, changes)
        : await ref
            .read(togetherControllerProvider.notifier)
            .add('quest', changes);
    if (!context.mounted) return;
    ref.read(chatToastProvider.notifier).show(
        err == null ? (editing ? '已保存' : '已加入清单') : '保存失败：$err',
        tone: err == null ? ChatToastTone.success : ChatToastTone.error);
  }
}
