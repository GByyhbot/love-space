/// 「我们」工具页两件（条目 6 · 段 C）：情侣问答 / 共同打卡。
/// 走段 A 通用列表件（ToolScaffold/ToolTile）；子资源操作口径：
/// · 回答 = POST /records/{rid}/answer（每人一条、可覆盖改写；内容双方都答
///   了才互相可见——揭晓态以服务端 answer_count/answers 过滤为准，UI 不自算）；
/// · 打卡 = POST /records/{rid}/check（同日幂等 INSERT OR IGNORE；状态以后端
///   为准，点完 reload 不回弹）；
/// · 提问/习惯本身的编辑走记录 PUT 回填铁律；question 禁附件（无媒体入口）；
/// · 结果提示一律顶部通知；⋯ 菜单仅本人（段 A/B 同口径）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/together/together_data.dart';
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'together_controller.dart';
import 'tool_pages.dart' show ToolTile;

// ── 情侣问答 ──────────────────────────────────────────────────────
class QuestionPage extends ConsumerStatefulWidget {
  const QuestionPage({super.key});
  @override
  ConsumerState<QuestionPage> createState() => _QuestionPageState();
}

class _QuestionPageState extends ConsumerState<QuestionPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(togetherControllerProvider.notifier).bootstrap());
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(togetherControllerProvider);
    final questions =
        ref.read(togetherControllerProvider.notifier).recordsOf('question');
    final me = ref.watch(authProvider.notifier).me;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('情侣问答')),
      floatingActionButton: FloatingActionButton.extended(
        tooltip: '提个问题',
        onPressed: () => _showAskForm(context, ref, null),
        icon: const Icon(Icons.add_rounded),
        label: const Text('提个问题'),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(togetherControllerProvider.notifier).load(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
          children: [
            Text('可以写下自己的问题，也可以从内置题目里挑一个。双方回答后才揭晓彼此的答案。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const SizedBox(height: 8),
            if (questions.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Column(children: [
                  Icon(Icons.help_outline_rounded,
                      size: 44, color: theme.colorScheme.outline),
                  const SizedBox(height: 12),
                  Text('给我们，多一点小小的仪式感',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text('每天再多了解彼此一点。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
                ]),
              )
            else
              for (final r in questions)
                ToolTile(
                  record: r,
                  onEdit: () => _showAskForm(context, ref, r),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((r.body['title'] ?? '').toString(),
                            style: theme.textTheme.titleMedium),
                        if ((r.body['content'] ?? '').toString().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text((r.body['content'] ?? '').toString(),
                                style: theme.textTheme.bodySmall),
                          ),
                        const SizedBox(height: 6),
                        Text(
                          r.answerCount == 2
                              ? '两个人的答案都到齐啦'
                              : '双方回答后，才会揭晓彼此的答案',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: theme.colorScheme.outline),
                        ),
                        ..._answerBoxes(context, r, me),
                      ]),
                ),
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

  List<Widget> _answerBoxes(
      BuildContext context, TogetherRecord r, MeData? me) {
    final theme = Theme.of(context);
    final myId = me?.user.id ?? '';
    final mine = r.answers.where((a) => a['author'] == myId).toList();
    final partner =
        r.answers.where((a) => a['author'] != myId).toList();
    final widgets = <Widget>[];
    // 自己的答案（存了就能看到，可改）
    if (mine.isNotEmpty) {
      widgets.add(_answerBox(theme, '我的答案', mine.first['content'] ?? ''));
    }
    // 对方的答案：answerCount==2（双方都答）服务端才会下发
    if (partner.isNotEmpty) {
      for (final a in partner) {
        final name = me?.byId(a['author'] ?? '')?.name ?? 'TA';
        widgets.add(_answerBox(theme, '$name 的答案', a['content'] ?? ''));
      }
    }
    if (r.answerCount < 2) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text('对方的答案要等 TA 也回答后才会揭晓。',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.outline)),
      ));
    }
    // 写下/修改我的答案：双方都可答、可改（服务端 ON CONFLICT UPDATE）
    widgets.add(Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextButton.icon(
        onPressed: () => _showAnswerForm(context, ref, r),
        icon: const Icon(Icons.edit_note_rounded, size: 18),
        label: Text(mine.isEmpty ? '写下我的答案' : '修改我的答案'),
      ),
    ));
    return widgets;
  }

  Widget _answerBox(ThemeData theme, String label, String content) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.outline)),
        const SizedBox(height: 2),
        Text(content, style: theme.textTheme.bodyMedium),
      ]),
    );
  }

  /// 提问/编辑表单：title 必填 + 内置题库挑选（对齐 Web QUESTION_BANK
  /// optgroup）+ content 可选；🔴 question 禁附件——无任何媒体入口。
  Future<void> _showAskForm(
      BuildContext context, WidgetRef ref, TogetherRecord? record) async {
    final editing = record != null;
    final b = record?.body ?? const {};
    final titleCtrl = TextEditingController(text: (b['title'] ?? '').toString());
    final contentCtrl = TextEditingController(text: (b['content'] ?? '').toString());
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(editing ? '编辑问题' : '提个问题'),
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
                    const InputDecoration(labelText: '想问 TA 的问题', counterText: ''),
                validator: (v) => (v ?? '').trim().isEmpty ? '请填写标题' : null,
              ),
              DropdownButtonFormField<String>(
                initialValue: null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '或从题库挑一个'),
                items: [
                  for (final entry in questionBank.entries)
                    for (final q in entry.value)
                      DropdownMenuItem(
                          value: q,
                          child: Text('${entry.key} · $q',
                              maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) {
                  if (v != null) titleCtrl.text = v;
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
              child: Text(editing ? '保存' : '提问')),
        ],
      ),
    );
    if (saved != true) return; // 取消：不误写
    final changes = <String, dynamic>{
      'title': titleCtrl.text.trim(),
      'content': contentCtrl.text.trim(),
    };
    final err = editing
        ? await ref
            .read(togetherControllerProvider.notifier)
            .edit(record.id, 'question', record.body, changes)
        : await ref
            .read(togetherControllerProvider.notifier)
            .add('question', changes);
    if (!context.mounted) return;
    ref.read(chatToastProvider.notifier).show(
        err == null ? (editing ? '已保存' : '问题已提出，等 TA 一起回答') : '保存失败：$err',
        tone: err == null ? ChatToastTone.success : ChatToastTone.error);
  }

  /// 回答表单（子资源 POST，非记录 PUT）：预填自己已存答案（可改，服务端
  /// ON CONFLICT UPDATE 覆盖）；content 1..5000。
  Future<void> _showAnswerForm(
      BuildContext context, WidgetRef ref, TogetherRecord r) async {
    final me = ref.read(authProvider.notifier).me;
    final myId = me?.user.id ?? '';
    final mine = r.answers.where((a) => a['author'] == myId).toList();
    final contentCtrl = TextEditingController(
        text: mine.isNotEmpty ? (mine.first['content'] ?? '') : '');
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text((r.body['title'] ?? '问答').toString()),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 360,
            child: TextFormField(
              controller: contentCtrl,
              maxLines: 5,
              maxLength: 5000,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: '我的答案', counterText: ''),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? '写下你的答案再提交吧' : null,
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
              child: Text(mine.isEmpty ? '提交答案' : '更新答案')),
        ],
      ),
    );
    if (saved != true) return;
    final err = await ref
        .read(togetherControllerProvider.notifier)
        .answer(r.id, contentCtrl.text.trim());
    if (!context.mounted) return;
    ref.read(chatToastProvider.notifier).show(
        err == null ? (mine.isEmpty ? '已提交答案' : '答案已更新') : '提交失败：$err',
        tone: err == null ? ChatToastTone.success : ChatToastTone.error);
  }
}

// ── 共同打卡 ──────────────────────────────────────────────────────
class HabitPage extends ConsumerStatefulWidget {
  const HabitPage({super.key});
  @override
  ConsumerState<HabitPage> createState() => _HabitPageState();
}

class _HabitPageState extends ConsumerState<HabitPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(togetherControllerProvider.notifier).bootstrap());
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(togetherControllerProvider);
    final habits =
        ref.read(togetherControllerProvider.notifier).recordsOf('habit');
    final me = ref.watch(authProvider.notifier).me;
    final myId = me?.user.id ?? '';
    final today = todayDateStr();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('共同打卡')),
      floatingActionButton: FloatingActionButton.extended(
        tooltip: '立个目标',
        onPressed: () => _showHabitForm(context, ref, null),
        icon: const Icon(Icons.add_rounded),
        label: const Text('立个目标'),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(togetherControllerProvider.notifier).load(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
          children: [
            Text('和你一起，成为更好的我们。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const SizedBox(height: 8),
            if (habits.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Column(children: [
                  Icon(Icons.eco_rounded,
                      size: 44, color: theme.colorScheme.outline),
                  const SizedBox(height: 12),
                  Text('给我们，多一点小小的仪式感',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text('立一个一起坚持的小目标。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
                ]),
              )
            else
              for (final r in habits)
                ToolTile(
                  record: r,
                  onEdit: () => _showHabitForm(context, ref, r),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((r.body['title'] ?? '').toString(),
                            style: theme.textTheme.titleMedium),
                        if ((r.body['content'] ?? '').toString().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text((r.body['content'] ?? '').toString(),
                                style: theme.textTheme.bodySmall),
                          ),
                        const SizedBox(height: 6),
                        // 对齐 Web recordCard habit meta（app.js:857）：
                        // 总次数 + 今天 X/2 人完成（按 author 去重）
                        Text(
                          '${r.checks.length} 次用心坚持 · 今天 '
                          '${r.checks.where((c) => c['day'] == today).map((c) => c['author']).toSet().length}/2 人完成',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: theme.colorScheme.outline),
                        ),
                        // 对方状态（今天是否已打卡）——双方可见口径
                        if (me != null)
                          for (final u in me.users)
                            if (u.id != myId)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  '${u.name}今天${_checkedToday(r, u.id, today) ? '已打卡 ✓' : '还没打卡'}',
                                  style: theme.textTheme.labelSmall
                                      ?.copyWith(color: theme.colorScheme.outline),
                                ),
                              ),
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: FilledButton.tonalIcon(
                            onPressed: () async {
                              // 同一天重复点：服务端 INSERT OR IGNORE 幂等，
                              // 不产生脏数据；状态以后端 reload 为准
                              final err = await ref
                                  .read(togetherControllerProvider.notifier)
                                  .checkHabit(r.id);
                              if (!context.mounted) return;
                              ref.read(chatToastProvider.notifier).show(
                                  err == null ? '今天也一起向前了一小步' : '打卡失败：$err',
                                  tone: err == null
                                      ? ChatToastTone.success
                                      : ChatToastTone.error);
                            },
                            icon: Icon(_checkedToday(r, myId, today)
                                ? Icons.check_circle_rounded
                                : Icons.circle_outlined,
                                size: 18),
                            label: Text(_checkedToday(r, myId, today)
                                ? '今天已打卡'
                                : '今天也一起坚持'),
                          ),
                        ),
                      ]),
                ),
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

  bool _checkedToday(TogetherRecord r, String author, String today) =>
      r.checks.any((c) => c['author'] == author && c['day'] == today);

  /// 立目标/编辑表单（对齐 Web recordForm habit：title 必填 + content 可选）
  Future<void> _showHabitForm(
      BuildContext context, WidgetRef ref, TogetherRecord? record) async {
    final editing = record != null;
    final b = record?.body ?? const {};
    final titleCtrl = TextEditingController(text: (b['title'] ?? '').toString());
    final contentCtrl = TextEditingController(text: (b['content'] ?? '').toString());
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(editing ? '编辑目标' : '立个目标'),
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
                    labelText: '目标名称', counterText: ''),
                validator: (v) => (v ?? '').trim().isEmpty ? '请填写标题' : null,
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
              child: Text(editing ? '保存' : '开始坚持')),
        ],
      ),
    );
    if (saved != true) return;
    final changes = <String, dynamic>{
      'title': titleCtrl.text.trim(),
      'content': contentCtrl.text.trim(),
    };
    final err = editing
        ? await ref
            .read(togetherControllerProvider.notifier)
            .edit(record.id, 'habit', record.body, changes)
        : await ref
            .read(togetherControllerProvider.notifier)
            .add('habit', changes);
    if (!context.mounted) return;
    ref.read(chatToastProvider.notifier).show(
        err == null ? (editing ? '已保存' : '目标已立，今天就开始') : '保存失败：$err',
        tone: err == null ? ChatToastTone.success : ChatToastTone.error);
  }
}
