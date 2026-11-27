/// 「我们」工具页三件（条目 6 · 段 A）：心情手记 / 悄悄留言 / 共同愿望。
/// 共用 togetherControllerProvider 一次全量数据；行卡片/表单按 kind 差异化，
/// 横切口径统一：
/// · 编辑一律回填铁律（打开表单时持有原始 body，PUT 只盖改动键）；
/// · 删除确认弹层可取消 → DELETE（服务端软删，回收站不自动删除；非本人 403）；
/// · 结果提示一律顶部通知（全局 ChatToastHost）；
/// · 表单字段逐字对齐 Web recordForm（app.js:1833）：
///   mood = emoji(十选一) + date 必填 + content 可选；
///   note = content 必填（无 title）；
///   wish = title 必填 + category 五选 + target 可选 + content 可选。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/together/together_data.dart';
import '../../core/ui/stagger_in.dart' show StaggerIn;
import '../../core/ui/hold_to_confirm.dart' show HoldToConfirmButton;
import '../../core/ui/avatar_media.dart';
import '../../core/ui/empty_view.dart';
import '../../core/ui/error_view.dart';
import '../../core/ui/progress.dart';
import '../../core/ui/selection_sheet.dart';
import '../auth/auth_state.dart';
import '../settings/settings_state.dart' show spaceAppearanceProvider;
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../settings/settings_widgets.dart'
    show filledFieldDecoration, showFormSheet;
import 'together_controller.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/tokens.dart';

String _createdLabel(double created) {
  if (created <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch((created * 1000).round());
  final now = DateTime.now();
  final prefix = d.year == now.year ? '' : '${d.year}-';
  return '$prefix${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// 主题色实心胶囊悬浮钮（2.4.7 甲组统一主操作语言）：cs.primary 实心 +
/// onPrimary 白字 + 胶囊 + 主题色柔和阴影；退役 M3 默认 primaryContainer 观感。
/// ToolScaffold / QuestionPage / HabitPage / 乙组四页同源。
Widget toolFab(BuildContext context,
    {required String tooltip,
    required VoidCallback onPressed,
    IconData icon = AppIcons.add}) {
  final cs = Theme.of(context).colorScheme;
  return FloatingActionButton.extended(
    tooltip: tooltip,
    onPressed: onPressed,
    backgroundColor: cs.primary,
    foregroundColor: cs.onPrimary,
    elevation: 3,
    icon: Icon(icon),
    label: Text(tooltip),
  );
}

/// 列表 meta 浅底胶囊 chip（2.4.7 甲组）；[emphasized] 用主题色浅底浅字，
/// 其余中性浅底。
Widget toolMetaChip(ThemeData theme, ColorScheme cs, String label,
    {bool emphasized = false}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 3),
    decoration: BoxDecoration(
        color: emphasized
            ? cs.primary.withValues(alpha: 0.12)
            : cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppRadius.pill)),
    child: Text(label,
        style: theme.textTheme.labelSmall?.copyWith(
            color: emphasized
                ? cs.primary
                : cs.onSurface.withValues(alpha: 0.7))),
  );
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
    this.loading = false,
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

  /// 首拉 loading（防闪空态，段 C 2.3.0）：controller.loading 原样透传。
  final bool loading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // 2.4.10 附录 B ①：错峰入场受动效总开关门控。
    final motionOn = ref.watch(spaceAppearanceProvider).motion;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      floatingActionButton:
          toolFab(context, tooltip: fabTooltip, onPressed: onFab),
      body: RefreshIndicator(
        onRefresh: () => ref.read(togetherControllerProvider.notifier).load(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, Spacing.pageBottom),
          children: [
            Text(subtitle,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const SizedBox(height: Spacing.gap),
            // 三态优先级：loading → error（可重试）→ empty → data。
            // 已出数据后的局部刷新失败维持行内错误文本（AppErrorText）。
            if (loading && isEmpty)
              const AppProgress()
            else if (isEmpty && error != null)
              Center(
                child: AppErrorView(
                  detail: error!,
                  onRetry: () =>
                      ref.read(togetherControllerProvider.notifier).load(),
                ),
              )
            else if (isEmpty)
              AppEmptyView(
                icon: Icons.favorite_border_rounded,
                title: emptyTitle,
                hint: emptyHint,
              )
            else ...[
              // 2.4.10 附录 B ①：主要列表首屏错峰入场（步进 40ms 封顶
              // 600ms，只动 transform/opacity；滚动后续批次不做）。
              for (final (i, t) in tiles.indexed)
                StaggerIn(index: i, enable: motionOn, child: t),
            ],
            if (error != null && !isEmpty) ...[
              const SizedBox(height: 10),
              AppErrorText(error!),
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
    final author = me?.byId(record.author);
    final authorName = author?.name ?? '?';
    final dateLabel =
        record.date.isNotEmpty ? record.date : _createdLabel(record.created);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            // 作者行带头像（2.4.7 甲组）：头像圆 24（AvatarMedia 统一鉴权
            // 缓存路径）；无头像走字母兜底。
            if ((author?.avatar ?? '').isNotEmpty)
              AvatarMedia(
                  avatarId: author!.avatar, name: authorName, radius: 12)
            else
              CircleAvatar(
                radius: 12,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Text(
                  authorName.isEmpty ? '?' : authorName.characters.first,
                  style: TextStyle(
                      fontSize: 10,
                      color: theme.colorScheme.onPrimaryContainer),
                ),
              ),
            const SizedBox(width: 8),
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
          const SizedBox(height: Spacing.gap),
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
        content: const Text('删除后可在网页端「我的小角落 → 回收站」里恢复，回收站不会自动删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: const Text('取消')),
          // 2.4.10 第 04 项：删除确认改长按确认。
          HoldToConfirmButton(onConfirm: () => Navigator.of(dctx).pop(true)),
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
    // 表情彩色浅底圆角方形底座（2.4.7 甲组）：46/圆角 14，柔和 tint 轮转
    // （primary/secondary/tertiary 14% 浅底按序循环，写死色零新增）。
    final cs = Theme.of(context).colorScheme;
    final tints = [cs.primary, cs.secondary, cs.tertiary];
    return ToolScaffold(
      title: '心情手记',
      subtitle: '晴天雨天，都想陪着你。',
      isEmpty: moods.isEmpty,
      emptyTitle: '给我们，多一点小小的仪式感',
      emptyHint: '记下今天的心情，晴天雨天都是回忆。',
      fabTooltip: '记心情',
      error: st.error,
      loading: st.loading,
      onFab: () => _showMoodForm(context, ref, null),
      tiles: [
        for (final (i, r) in moods.indexed)
          ToolTile(
            record: r,
            onEdit: () => _showMoodForm(context, ref, r),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                    color: tints[i % tints.length].withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14)),
                alignment: Alignment.center,
                child: Text((r.body['emoji'] ?? '☀️').toString(),
                    style: const TextStyle(fontSize: 24)),
              ),
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
  /// 2.4.1 通则 A：居中弹窗改底部表单 sheet（外壳同 composer：抓手 +
  /// 标题 + 关闭圆钮 + 玻璃栏）；字段圆角填充；日期改整行选择框。
  /// 数据口径（emoji 十选一 + date 必填 + content 可选）零变化。
  await showFormSheet(
    context,
    title: editing ? '编辑心情' : '今天的心情',
    saveLabel: editing ? '保存' : '记下今天',
    cancelLabel: '取消',
    builder: (setSheetState) => Form(
      key: formKey,
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
                onSelected: (_) => setSheetState(() => emoji = e),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('心情日期', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 6),
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () async {
              final picked = await showDatePicker(
                  context: context,
                  initialDate:
                      DateTime.tryParse(dateCtrl.text) ?? DateTime.now(),
                  firstDate: DateTime(2000),
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
                Text('心情日期', style: Theme.of(context).textTheme.labelSmall),
                const Spacer(),
                Text(dateCtrl.text.isEmpty ? '请选择' : dateCtrl.text,
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right_rounded,
                    size: 18, color: Theme.of(context).colorScheme.outline),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('再说一句今天的心情',
              style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 6),
          TextFormField(
            controller: contentCtrl,
            maxLines: 3,
            maxLength: 2000,
            decoration: filledFieldDecoration(counterText: ''),
          ),
        ]),
      ]),
    ),
    onSave: (closeOk, _) {},
    // 2.4.10：保存走三连变（请求中弹层保持打开，成功对勾驻留后关）。
    asyncSave: () async {
      if (dateCtrl.text.trim().length != 10) {
        ref.read(chatToastProvider.notifier).show('请选择心情日期',
            tone: ChatToastTone.error);
        return false;
      }
      if (!(formKey.currentState?.validate() ?? false)) return false;
      final changes = <String, dynamic>{
        'emoji': emoji,
        'date': dateCtrl.text.trim(),
        'content': contentCtrl.text.trim(),
      };
      final err = editing
          ? await ref
              .read(togetherControllerProvider.notifier)
              .edit(record.id, 'mood', record.body, changes)
          : await ref
              .read(togetherControllerProvider.notifier)
              .add('mood', changes);
      if (!context.mounted) return false;
      _toast(context, ref, err, okMsg: editing ? '已保存' : '已记下今天的心情');
      return err == null;
    },
  );
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
      loading: st.loading,
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
  // 2.4.1 通则 A：底部表单 sheet（外壳同 composer），字段圆角填充。
  await showFormSheet(
    context,
    title: editing ? '编辑留言' : '悄悄留言',
    saveLabel: editing ? '保存' : '写下来',
    cancelLabel: '取消',
    builder: (_) => Form(
      key: formKey,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('想对 TA 说的话', style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 6),
        TextFormField(
          controller: contentCtrl,
          maxLines: 6,
          maxLength: 20000,
          autofocus: !editing,
          decoration: filledFieldDecoration(counterText: ''),
          validator: (v) =>
              (v ?? '').trim().isEmpty ? '写点什么再保存吧' : null,
        ),
      ]),
    ),
    onSave: (closeOk, _) {},
    // 2.4.10：保存走三连变。
    asyncSave: () async {
      if (!(formKey.currentState?.validate() ?? false)) return false;
      final changes = <String, dynamic>{'content': contentCtrl.text.trim()};
      final err = editing
          ? await ref
              .read(togetherControllerProvider.notifier)
              .edit(record.id, 'note', record.body, changes)
          : await ref
              .read(togetherControllerProvider.notifier)
              .add('note', changes);
      if (!context.mounted) return false;
      _toast(context, ref, err, okMsg: editing ? '已保存' : '已写下这条留言');
      return err == null;
    },
  );
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
      loading: st.loading,
      onFab: () => _showWishForm(context, ref, null),
      tiles: [
        // 2.4.10 附录 B ④：愿望进度底色——填充宽度=完成比例，勾选时
        // 平滑前推（320ms），全部完成时轻微提亮。
        if (wishes.isNotEmpty)
          _WishProgressBar(done: wishes.where((r) => r.body['done'] == true).length,
              total: wishes.length),
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
              // 分类/约定/完成态改浅底胶囊 chips（2.4.7 甲组；文案逐字保留）。
              Wrap(spacing: 6, runSpacing: 4, children: [
                toolMetaChip(
                    theme, theme.colorScheme,
                    (r.body['category'] ?? '小心愿').toString()),
                if ((r.body['target'] ?? '').toString().isNotEmpty)
                  toolMetaChip(theme, theme.colorScheme,
                      '约定 ${(r.body['target'] ?? '')}'),
                if (r.body['done'] == true)
                  toolMetaChip(theme, theme.colorScheme, '已完成',
                      emphasized: true),
              ]),
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
  // 2.4.1 通则 A：底部表单 sheet；通则 B：分类下拉改底部选择单；
  // 约定日期改整行选择框。数据口径（title 必填 + category 五选 +
  // target 可选 + content 可选）零变化。
  await showFormSheet(
    context,
    title: editing ? '编辑愿望' : '许个心愿',
    saveLabel: editing ? '保存' : '许下心愿',
    cancelLabel: '取消',
    builder: (setSheetState) => Form(
      key: formKey,
      child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('愿望标题', style: Theme.of(context).textTheme.labelSmall),
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
        // 分类：整行选择框 + 底部选择单（通则 B）。
        InkWell(
          key: const Key('wish-category-field'),
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            final picked = await showSelectionSheet<String>(
              context: context,
              title: '分类',
              selected: category,
              options: [
                for (final c in wishCategories) SelectionOption(value: c, label: c),
              ],
            );
            if (picked != null) setSheetState(() => category = picked);
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
              Text('分类', style: Theme.of(context).textTheme.labelSmall),
              const Spacer(),
              Text(category, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: Theme.of(context).colorScheme.outline),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        // 约定日期（可选）：整行选择框（可清空=再次点开重选遮罩关闭不改）。
        InkWell(
          key: const Key('wish-target-field'),
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            final picked = await showDatePicker(
                context: context,
                initialDate:
                    DateTime.tryParse(targetCtrl.text) ?? DateTime.now(),
                firstDate: DateTime(2000),
                lastDate: DateTime(2100));
            if (picked != null) {
              setSheetState(() {
                targetCtrl.text =
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
              Text('约定日期（可选）',
                  style: Theme.of(context).textTheme.labelSmall),
              const Spacer(),
              Text(targetCtrl.text.isEmpty ? '未设置' : targetCtrl.text,
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: Theme.of(context).colorScheme.outline),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('补充一些小细节（可选）',
              style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 6),
          TextFormField(
            controller: contentCtrl,
            maxLines: 3,
            maxLength: 20000,
            decoration: filledFieldDecoration(counterText: ''),
          ),
        ]),
      ]),
    ),
    onSave: (closeOk, _) {},
    // 2.4.10：保存走三连变。
    asyncSave: () async {
      if (!(formKey.currentState?.validate() ?? false)) return false;
      final changes = <String, dynamic>{
        'title': titleCtrl.text.trim(),
        'category': category,
        'target': targetCtrl.text.trim(),
        'content': contentCtrl.text.trim(),
      };
      final err = editing
          ? await ref
              .read(togetherControllerProvider.notifier)
              .edit(record.id, 'wish', record.body, changes)
          : await ref
              .read(togetherControllerProvider.notifier)
              .add('wish', changes);
      if (!context.mounted) return false;
      _toast(context, ref, err, okMsg: editing ? '已保存' : '已许下这份心愿');
      return err == null;
    },
  );
}


// ── 2.4.10 附录 B ④：愿望进度底色 ────────────────────────────────
/// 填充宽度 = 已完成/总数（AnimatedFractionallySizedBox 平滑前推）；
/// 全部完成时轻微提亮（底座/填充转 primary 系亮色）。
class _WishProgressBar extends StatelessWidget {
  const _WishProgressBar({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ratio = total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    final complete = ratio >= 1.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOut,
          height: 10,
          decoration: BoxDecoration(
            color: complete
                ? cs.primary.withValues(alpha: 0.18)
                : cs.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(999),
          ),
          child: AnimatedFractionallySizedBox(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOut,
            alignment: Alignment.centerLeft,
            widthFactor: ratio,
            child: Container(
              decoration: BoxDecoration(
                color: complete ? cs.primary : cs.primary.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text('已完成 $done / $total',
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(
                    color: complete ? cs.primary : cs.outline,
                    fontWeight: complete ? FontWeight.w600 : null)),
      ]),
    );
  }
}
