/// 「我们」工具页三件（条目 6 · 段 A）：心情手记 / 悄悄留言 / 共同愿望。
/// 共用 togetherControllerProvider 一次全量数据；行卡片/表单按 kind 差异化，
/// 横切口径统一：
/// · 编辑一律回填铁律（打开表单时持有原始 body，PUT 只盖改动键）；
/// · 删除确认弹层可取消 → DELETE（服务端软删，回收站 30 天；非本人 403）；
/// · 结果提示一律顶部通知（全局 ChatToastHost）；
/// · 表单字段逐字对齐 Web recordForm（app.js:1833）：
///   mood = emoji(十选一) + date 必填 + content 可选；
///   note = content 必填（无 title）；
///   wish = title 必填 + category 五选 + target 可选 + content 可选。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/together/together_data.dart';
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'together_controller.dart';

String _createdLabel(double created) {
  if (created <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch((created * 1000).round());
  final now = DateTime.now();
  final prefix = d.year == now.year ? '' : '${d.year}-';
  return '$prefix${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// 工具页骨架（通用件）：heading + 列表 + 空态 + FAB + 下拉刷新。
/// [tiles] 由各页用当前 records 构建行卡片。
class ToolScaffold extends ConsumerWidget {
  const ToolScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.tiles,
    required this.isEmpty,
    required this.emptyTitle,
    required this.emptyHint,
    required this.fabTooltip,
    required this.onFab,
    this.error,
  });
  final String title;
  final String subtitle;
  final List<Widget> tiles;
  final bool isEmpty;
  final String emptyTitle;
  final String emptyHint;
  final String fabTooltip;
  final VoidCallback onFab;
  final String? error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      floatingActionButton: FloatingActionButton.extended(
        tooltip: fabTooltip,
        onPressed: onFab,
        icon: const Icon(Icons.add_rounded),
        label: Text(fabTooltip),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(togetherControllerProvider.notifier).load(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
          children: [
            Text(subtitle,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const SizedBox(height: 8),
            if (isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Column(children: [
                  Icon(Icons.favorite_border_rounded,
                      size: 44, color: theme.colorScheme.outline),
                  const SizedBox(height: 12),
                  Text(emptyTitle, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(emptyHint,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
                ]),
              )
            else ...tiles,
            if (error != null) ...[
              const SizedBox(height: 10),
              Text(error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 行卡片通用容器：作者 + 日期头部 + ⋯ 菜单（仅本人：编辑/删除）。
class ToolTile extends ConsumerWidget {
  const ToolTile({
    super.key,
    required this.record,
    required this.child,
    required this.onEdit,
  });
  final TogetherRecord record;
  final Widget child;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final me = ref.watch(authProvider.notifier).me;
    final own = me != null && me.user.id == record.author;
    final authorName = me?.byId(record.author)?.name ?? '?';
    final dateLabel =
        record.date.isNotEmpty ? record.date : _createdLabel(record.created);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('$authorName · $dateLabel',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ),
            if (own)
              PopupMenuButton<String>(
                tooltip: '更多操作',
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('编辑')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
                onSelected: (v) {
                  if (v == 'edit') onEdit();
                  if (v == 'delete') _confirmDelete(context, ref, record);
                },
              ),
          ]),
          const SizedBox(height: 6),
          child,
        ]),
      ),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, TogetherRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('删除这条记录'),
        content: const Text('删除后可在网页端「我的小角落 → 回收站」里保留 30 天，可恢复。'),
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

void _toast(BuildContext context, WidgetRef ref, String? err,
    {required String okMsg}) {
  ref.read(chatToastProvider.notifier).show(err == null ? okMsg : '保存失败：$err',
      tone: err == null ? ChatToastTone.success : ChatToastTone.error);
}

// ── 心情手记 ──────────────────────────────────────────────────────
class MoodPage extends ConsumerStatefulWidget {
  const MoodPage({super.key});
  @override
  ConsumerState<MoodPage> createState() => _MoodPageState();
}

class _MoodPageState extends ConsumerState<MoodPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(togetherControllerProvider.notifier).bootstrap());
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(togetherControllerProvider);
    final moods = ref.read(togetherControllerProvider.notifier).moods();
    return ToolScaffold(
      title: '心情手记',
      subtitle: '晴天雨天，都想陪着你。',
      isEmpty: moods.isEmpty,
      emptyTitle: '给我们，多一点小小的仪式感',
      emptyHint: '记下今天的心情，晴天雨天都是回忆。',
      fabTooltip: '记心情',
      error: st.error,
      onFab: () => _showMoodForm(context, ref, null),
      tiles: [
        for (final r in moods)
          ToolTile(
            record: r,
            onEdit: () => _showMoodForm(context, ref, r),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((r.body['emoji'] ?? '☀️').toString(),
                  style: const TextStyle(fontSize: 30)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  (r.body['content'] ?? '').toString().isEmpty
                      ? '只记了一个心情'
                      : (r.body['content'] ?? '').toString(),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ]),
          ),
      ],
    );
  }
}

Future<void> _showMoodForm(
    BuildContext context, WidgetRef ref, TogetherRecord? record) async {
  final editing = record != null;
  final b = record?.body ?? const {};
  var emoji = ((b['emoji'] ?? '☀️') as String);
  if (!moodOptions.containsKey(emoji)) emoji = '☀️';
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
        title: Text(editing ? '编辑心情' : '今天的心情'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final e in moodOptions.keys)
                    ChoiceChip(
                      label: Text(e, style: const TextStyle(fontSize: 18)),
                      selected: emoji == e,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setDialogState(() => emoji = e),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: dateCtrl,
                readOnly: true,
                decoration: const InputDecoration(labelText: '心情日期'),
                onTap: () async {
                  final picked = await showDatePicker(
                      context: dctx,
                      initialDate: DateTime.tryParse(dateCtrl.text) ?? DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100));
                  if (picked != null) {
                    dateCtrl.text =
                        '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                  }
                },
                validator: (v) =>
                    (v ?? '').length == 10 ? null : '请选择心情日期',
              ),
              TextFormField(
                controller: contentCtrl,
                maxLines: 3,
                maxLength: 2000,
                decoration: const InputDecoration(
                    labelText: '再说一句今天的心情', counterText: ''),
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
              child: Text(editing ? '保存' : '记下今天')),
        ],
      ),
    ),
  );
  if (saved != true) return; // 取消：不误写
  final changes = <String, dynamic>{
    'emoji': emoji,
    'date': dateCtrl.text.trim(),
    'content': contentCtrl.text.trim(),
  };
  final err = editing
      ? await ref.read(togetherControllerProvider.notifier).edit(
          record.id, 'mood', record.body, changes)
      : await ref.read(togetherControllerProvider.notifier).add('mood', changes);
  if (!context.mounted) return;
  _toast(context, ref, err, okMsg: editing ? '已保存' : '已记下今天的心情');
}

// ── 悄悄留言 ──────────────────────────────────────────────────────
class NotePage extends ConsumerStatefulWidget {
  const NotePage({super.key});
  @override
  ConsumerState<NotePage> createState() => _NotePageState();
}

class _NotePageState extends ConsumerState<NotePage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(togetherControllerProvider.notifier).bootstrap());
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(togetherControllerProvider);
    final notes = ref.read(togetherControllerProvider.notifier).recordsOf('note');
    return ToolScaffold(
      title: '悄悄留言',
      subtitle: '有些喜欢，值得慢慢读。',
      isEmpty: notes.isEmpty,
      emptyTitle: '给我们，多一点小小的仪式感',
      emptyHint: '写一句话给 TA，慢慢读，慢慢懂。',
      fabTooltip: '写留言',
      error: st.error,
      onFab: () => _showNoteForm(context, ref, null),
      tiles: [
        for (final r in notes)
          ToolTile(
            record: r,
            onEdit: () => _showNoteForm(context, ref, r),
            child: SelectableText((r.body['content'] ?? '').toString(),
                style: Theme.of(context).textTheme.bodyMedium),
          ),
      ],
    );
  }
}

Future<void> _showNoteForm(
    BuildContext context, WidgetRef ref, TogetherRecord? record) async {
  final editing = record != null;
  final contentCtrl =
      TextEditingController(text: (record?.body['content'] ?? '').toString());
  final formKey = GlobalKey<FormState>();
  final saved = await showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: Text(editing ? '编辑留言' : '悄悄留言'),
      content: Form(
        key: formKey,
        child: SizedBox(
          width: 360,
          child: TextFormField(
            controller: contentCtrl,
            maxLines: 6,
            maxLength: 20000,
            autofocus: !editing,
            decoration: const InputDecoration(
                labelText: '想对 TA 说的话', counterText: ''),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? '写点什么再保存吧' : null,
          ),
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
            child: Text(editing ? '保存' : '写下来')),
      ],
    ),
  );
  if (saved != true) return;
  final changes = <String, dynamic>{'content': contentCtrl.text.trim()};
  final err = editing
      ? await ref
          .read(togetherControllerProvider.notifier)
          .edit(record.id, 'note', record.body, changes)
      : await ref.read(togetherControllerProvider.notifier).add('note', changes);
  if (!context.mounted) return;
  _toast(context, ref, err, okMsg: editing ? '已保存' : '已写下这条留言');
}

// ── 共同愿望 ──────────────────────────────────────────────────────
class WishPage extends ConsumerStatefulWidget {
  const WishPage({super.key});
  @override
  ConsumerState<WishPage> createState() => _WishPageState();
}

class _WishPageState extends ConsumerState<WishPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(togetherControllerProvider.notifier).bootstrap());
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(togetherControllerProvider);
    final wishes =
        ref.read(togetherControllerProvider.notifier).recordsOf('wish');
    final theme = Theme.of(context);
    return ToolScaffold(
      title: '共同愿望',
      subtitle: '把一起想做的事，一件件实现。',
      isEmpty: wishes.isEmpty,
      emptyTitle: '一起期待下一件小事',
      emptyHint: '想去的地方，想做的事情，都记在这里。',
      fabTooltip: '许个心愿',
      error: st.error,
      onFab: () => _showWishForm(context, ref, null),
      tiles: [
        for (final r in wishes)
          ToolTile(
            record: r,
            onEdit: () => _showWishForm(context, ref, r),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                // done 勾选：双方都可点（Web toggle-wish 口径；非本人 PUT 403 → 错误通知）
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () async {
                    final err = await ref
                        .read(togetherControllerProvider.notifier)
                        .toggleWishDone(r);
                    if (!context.mounted) return;
                    _toast(context, ref, err, okMsg: '已更新');
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      r.body['done'] == true
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 26,
                      color: r.body['done'] == true
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text((r.body['title'] ?? '').toString(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                          decoration: r.body['done'] == true
                              ? TextDecoration.lineThrough
                              : TextDecoration.none)),
                ),
              ]),
              if ((r.body['content'] ?? '').toString().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text((r.body['content'] ?? '').toString(),
                    style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 4),
              Text(
                '${(r.body['category'] ?? '小心愿')}'
                '${(r.body['target'] ?? '').toString().isNotEmpty ? ' · 约定 ${(r.body['target'] ?? '')}' : ''}'
                '${r.body['done'] == true ? ' · 已完成' : ''}',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ]),
          ),
      ],
    );
  }
}

Future<void> _showWishForm(
    BuildContext context, WidgetRef ref, TogetherRecord? record) async {
  final editing = record != null;
  final b = record?.body ?? const {};
  final titleCtrl = TextEditingController(text: (b['title'] ?? '').toString());
  var category = ((b['category'] ?? '日常') as String);
  if (!wishCategories.contains(category)) category = '日常';
  final targetCtrl = TextEditingController(text: (b['target'] ?? '').toString());
  final contentCtrl = TextEditingController(text: (b['content'] ?? '').toString());
  final formKey = GlobalKey<FormState>();
  final saved = await showDialog<bool>(
    context: context,
    builder: (dctx) => StatefulBuilder(
      builder: (dctx, setDialogState) => AlertDialog(
        title: Text(editing ? '编辑愿望' : '许个心愿'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(
                controller: titleCtrl,
                autofocus: !editing,
                maxLength: 200,
                decoration: const InputDecoration(
                    labelText: '愿望标题', counterText: ''),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? '请填写标题' : null,
              ),
              DropdownButtonFormField<String>(
                initialValue: category,
                decoration: const InputDecoration(labelText: '分类'),
                items: [
                  for (final c in wishCategories)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) => setDialogState(() => category = v ?? '日常'),
              ),
              TextFormField(
                controller: targetCtrl,
                readOnly: true,
                decoration: const InputDecoration(labelText: '约定日期（可选）'),
                onTap: () async {
                  final picked = await showDatePicker(
                      context: dctx,
                      initialDate:
                          DateTime.tryParse(targetCtrl.text) ?? DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100));
                  if (picked != null) {
                    targetCtrl.text =
                        '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                  }
                },
              ),
              TextFormField(
                controller: contentCtrl,
                maxLines: 3,
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
              child: Text(editing ? '保存' : '许下心愿')),
        ],
      ),
    ),
  );
  if (saved != true) return;
  final changes = <String, dynamic>{
    'title': titleCtrl.text.trim(),
    'category': category,
    'target': targetCtrl.text.trim(),
    'content': contentCtrl.text.trim(),
  };
  final err = editing
      ? await ref.read(togetherControllerProvider.notifier).edit(
          record.id, 'wish', record.body, changes)
      : await ref.read(togetherControllerProvider.notifier).add('wish', changes);
  if (!context.mounted) return;
  _toast(context, ref, err, okMsg: editing ? '已保存' : '已许下这份心愿');
}
