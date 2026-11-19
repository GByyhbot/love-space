/// 纪念日管理页（条目 6 · 段 B，kind=anniversary）：
/// 列表按 Web recordCard 口径：标题、日期、重复方式（每年公历/每年农历/
/// 只纪念一次）、提前提醒天数、倒计时（🔴 复用 together_data.anniversaryDue
/// 唯一实现——首页/hub/管理页三处数字永远一致）。
/// 新增/编辑/删除齐全：date 必填，annual 三态逐字对齐 Web recordForm
/// （app.js:1841）；编辑走回填铁律；删除软删 + 确认弹层；结果提示走顶部通知。
/// 对方的纪念日只读（⋯ 菜单仅本人，与段 A 同口径）。
/// 入口：首页纪念日区 / 「我们」hub 展示卡两路直达（决策点①）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/together/together_data.dart';
import '../../core/ui/avatar_media.dart';
import '../../core/ui/empty_view.dart';
import '../../core/ui/error_view.dart';
import '../../core/ui/selection_sheet.dart';
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../settings/settings_widgets.dart'
    show filledFieldDecoration, showFormSheet;
import 'together_controller.dart';
import 'tool_pages.dart' show toolFab, toolMetaChip;
import '../../core/theme/tokens.dart';

/// annual 三态显示文案（逐字对齐 Web recordCard anniversary meta，app.js:857）
String annualLabel(dynamic annual) =>
    annual == 'lunar'
        ? '每年农历日期'
        : annual == false
            ? '只纪念一次'
            : '每年公历日期';

class AnniversaryPage extends ConsumerStatefulWidget {
  const AnniversaryPage({super.key});
  @override
  ConsumerState<AnniversaryPage> createState() => _AnniversaryPageState();
}

class _AnniversaryPageState extends ConsumerState<AnniversaryPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(togetherControllerProvider.notifier).bootstrap());
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(togetherControllerProvider);
    final me = ref.watch(authProvider.notifier).me;
    final anns =
        ref.read(togetherControllerProvider.notifier).recordsOf('anniversary');
    final theme = Theme.of(context);
    final today = todayDateStr();

    return Scaffold(
      appBar: AppBar(title: const Text('纪念日')),
      // 主题色实心胶囊悬浮钮（2.4.7 乙组，与甲组同源）。
      floatingActionButton:
          toolFab(context, tooltip: '添加纪念日', onPressed: () => _showForm(context, ref, null)),
      body: RefreshIndicator(
        onRefresh: () => ref.read(togetherControllerProvider.notifier).load(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, Spacing.pageBottom),
          children: [
            Text('每个重要的日子，都认真对待。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const SizedBox(height: Spacing.gap),
            if (anns.isEmpty)
              // 空态共享语言（2.4.7 乙组）：AppEmptyView，文案逐字保留。
              AppEmptyView(
                icon: Icons.event_available_rounded,
                title: '给我们，多一点小小的仪式感',
                hint: '把值得记住的日子放进来，到点就会提醒。',
              )
            else
              for (final r in anns) _buildTile(context, ref, r, me, today),
            if (st.error != null) ...[
              const SizedBox(height: 10),
              AppErrorText(st.error!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTile(BuildContext context, WidgetRef ref, TogetherRecord r,
      MeData? me, String today) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final own = me != null && me.user.id == r.author;
    final author = me?.byId(r.author);
    final authorName = author?.name ?? '?';
    final due = anniversaryDue(r.body, today);
    final countLabel = due == null
        ? '已过去 · 留在回忆里'
        : due.days == 0
            ? '就是今天'
            : '还有 ${due.days} 天';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            // 作者行带头像（2.4.7 乙组）：与 ToolTile 同构；无头像字母兜底。
            if ((author?.avatar ?? '').isNotEmpty)
              AvatarMedia(avatarId: author!.avatar, name: authorName, radius: 12)
            else
              CircleAvatar(
                radius: 12,
                backgroundColor: cs.primaryContainer,
                child: Text(authorName.isEmpty ? '?' : authorName.characters.first,
                    style: TextStyle(fontSize: 10, color: cs.onPrimaryContainer)),
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Text('$authorName · ${(r.body['date'] ?? '')}',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: cs.outline)),
            ),
            if (own)
              PopupMenuButton<String>(
                tooltip: '更多操作',
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('编辑')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
                onSelected: (v) {
                  if (v == 'edit') _showForm(context, ref, r);
                  if (v == 'delete') _confirmDelete(context, ref, r);
                },
              ),
          ]),
          const SizedBox(height: Spacing.gap),
          Text((r.body['title'] ?? '').toString(),
              style: theme.textTheme.titleMedium),
          if ((r.body['content'] ?? '').toString().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text((r.body['content'] ?? '').toString(),
                style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: Spacing.gap),
          Row(children: [
            Expanded(
              child: Text(
                '${annualLabel(r.body['annual'])}'
                ' · 提前 ${r.body['remind_days'] ?? 1} 天提醒',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: cs.outline),
              ),
            ),
            // 倒计时主题色浅底胶囊（2.4.7 乙组；文案逐字保留）。
            toolMetaChip(theme, cs, countLabel,
                emphasized: due != null),
          ]),
        ]),
      ),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, TogetherRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('删除这条纪念日'),
        content: Text(
            '确定删除「${(record.body['title'] ?? '纪念日')}」吗？\n\n删除后保留在回收站 30 天，可恢复。'),
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
    if (confirmed != true) return; // 取消：不删
    final err = await ref
        .read(togetherControllerProvider.notifier)
        .delete(record.id);
    if (!context.mounted) return;
    ref.read(chatToastProvider.notifier).show(
        err == null ? '已删除' : '删除失败：$err',
        tone: err == null ? ChatToastTone.success : ChatToastTone.error);
  }
}

/// 新增/编辑表单（字段逐字对齐 Web recordForm anniversary 分支）：
/// title 必填 + date 必填 + annual 三态 + remind_days 0-365（默认 1）+
/// content 可选。编辑以打开时持有的原始 body 为底（回填铁律）。
Future<void> _showForm(
    BuildContext context, WidgetRef ref, TogetherRecord? record) async {
  final editing = record != null;
  final b = record?.body ?? const {};
  final titleCtrl = TextEditingController(text: (b['title'] ?? '').toString());
  final dateCtrl = TextEditingController(text: (b['date'] ?? '').toString());
  var annual = b['annual'] == null || b['annual'] == true
      ? 'true'
      : b['annual'] == 'lunar'
          ? 'lunar'
          : 'false';
  final remindCtrl =
      TextEditingController(text: '${b['remind_days'] ?? 1}');
  final contentCtrl = TextEditingController(text: (b['content'] ?? '').toString());
  final formKey = GlobalKey<FormState>();
  // 2.4.1 通则 A：底部表单 sheet；通则 B：重复方式下拉改底部选择单；
  // 日期改整行选择框。annual 三态与 remind_days 校验口径零变化。
  final saved = await showFormSheet(
    context,
    title: editing ? '编辑纪念日' : '添加纪念日',
    saveLabel: editing ? '保存' : '添加',
    cancelLabel: '取消',
    builder: (setSheetState) => Form(
      key: formKey,
      child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('纪念日名称', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 6),
          TextFormField(
            controller: titleCtrl,
            autofocus: !editing,
            maxLength: 200,
            decoration: filledFieldDecoration(counterText: ''),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? '请填写标题' : null,
          ),
        ]),
        const SizedBox(height: 10),
        // 日期：整行选择框（date 必填，校验留在保存口）。
        InkWell(
          key: const Key('anniv-date-field'),
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            final picked = await showDatePicker(
                context: context,
                initialDate:
                    DateTime.tryParse(dateCtrl.text) ?? DateTime.now(),
                firstDate: DateTime(1900),
                lastDate: DateTime(2100));
            if (picked != null) {
              setSheetState(() {
                dateCtrl.text =
                    '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
              });
            }
          },
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Text('日期', style: Theme.of(context).textTheme.labelSmall),
              const Spacer(),
              Text(dateCtrl.text.isEmpty ? '请选择' : dateCtrl.text,
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: Theme.of(context).colorScheme.outline),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        // 重复方式：整行选择框 + 底部选择单（通则 B）。
        InkWell(
          key: const Key('anniv-annual-field'),
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            final picked = await showSelectionSheet<String>(
              context: context,
              title: '重复方式',
              selected: annual,
              options: const [
                SelectionOption(value: 'true', label: '每年公历日期'),
                SelectionOption(value: 'lunar', label: '每年农历日期'),
                SelectionOption(value: 'false', label: '只纪念一次'),
              ],
            );
            if (picked != null) setSheetState(() => annual = picked);
          },
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Text('重复方式', style: Theme.of(context).textTheme.labelSmall),
              const Spacer(),
              Text(annualLabel(annual == 'true'
                  ? true
                  : (annual == 'lunar' ? 'lunar' : false)),
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: Theme.of(context).colorScheme.outline),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('提前几天提醒', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 6),
          TextFormField(
            controller: remindCtrl,
            keyboardType: TextInputType.number,
            decoration: filledFieldDecoration(counterText: ''),
            validator: (v) {
              final n = int.tryParse(v ?? '');
              if (n == null || n < 0 || n > 365) return '提前提醒天数需在 0–365 之间';
              return null;
            },
          ),
        ]),
        const SizedBox(height: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('补充一些小细节（可选）',
              style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 6),
          TextFormField(
            controller: contentCtrl,
            maxLines: 2,
            maxLength: 20000,
            decoration: filledFieldDecoration(counterText: ''),
          ),
        ]),
      ]),
    ),
    onSave: (closeOk, _) {
      // date 由整行选择框维护，不走 Form 校验
      if (dateCtrl.text.trim().length != 10) {
        ref.read(chatToastProvider.notifier).show('请选择日期',
            tone: ChatToastTone.error);
        return;
      }
      if (formKey.currentState?.validate() ?? false) closeOk();
    },
  );
  if (saved != true) return; // 取消：不误写
  final changes = <String, dynamic>{
    'title': titleCtrl.text.trim(),
    'date': dateCtrl.text.trim(),
    'annual': annual == 'true' ? true : (annual == 'lunar' ? 'lunar' : false),
    'remind_days': int.parse(remindCtrl.text.trim()),
    'content': contentCtrl.text.trim(),
  };
  final err = editing
      ? await ref
          .read(togetherControllerProvider.notifier)
          .edit(record.id, 'anniversary', record.body, changes)
      : await ref
          .read(togetherControllerProvider.notifier)
          .add('anniversary', changes);
  if (!context.mounted) return;
  ref.read(chatToastProvider.notifier).show(
      err == null ? (editing ? '已保存' : '已添加纪念日') : '保存失败：$err',
      tone: err == null ? ChatToastTone.success : ChatToastTone.error);
}
