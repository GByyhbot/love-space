/// 「个人角落」段 7-A 页面（条目 7）。
///
/// · heading「我的小角落」/ 副标题「有些心事留给自己，有些惊喜留给未来。」；
/// · tab 结构 = 可扩展数据表 [personalTabs]，**本段只 diary / draft 两项**，
///   7-B（surprise/trash）、7-C（personal_wish）的 tab 一律不预置（无死卡纪律）；
/// · 两 tab 顶部提示文案逐字对齐 Web app.js:1489；空态/入口按钮逐字对齐；
/// · 二级页（日记表单 / 草稿发布选择）一律 context.push（AppBar 自动返回 +
///   系统手势都能回上一页）；tab 间切换用 IndexedStack 常驻，不丢状态；
/// · 草稿「继续编辑 / 写一份草稿」直接对接正式 composer（不另造编辑器）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/together/together_data.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../timeline/composer_sheet.dart';
import 'personal_controller.dart';

/// 7-A tab 数据表（可扩展：7-B/7-C 落地时在此追加，绝不预置死卡）。
/// hint 两 tab 同句——Web app.js:1489 只有 surprise 用另一句。
const List<({String id, String label, String hint})> personalTabs = [
  (
    id: 'diary',
    label: '私密日记',
    hint: '这个角落只有你能看见。草稿主动发布后，才会进入共同空间。'
  ),
  (
    id: 'draft',
    label: '草稿箱',
    hint: '这个角落只有你能看见。草稿主动发布后，才会进入共同空间。'
  ),
];

/// 私密类删除确认专用文案（7-A 暂时口径；与共享类 post_card.dart:271 /
/// tool_pages.dart:160 的「删除后会进入回收站，30 天内可以恢复。」分开）。
/// 🔴 主人 2026-11-14 12:10 定案**对齐 Web**（作废此前「App 内收紧」）：
/// ① 事实层：main.py:1150-1156 的 `kind NOT IN (私密三类)` 只在**非 trash 且
///   不带 kind** 的 else 分支；trash 分支只加 author + deleted；app.js:468 的
///   kind 串来自 kindLabel（含 diary/draft/surprise），main.py:1443 restore 不区分
///   kind → Web 上本人删掉的私密日记/草稿**会进回收站并可恢复**。
/// ② 7-B 回收站按 Web 口径：kind 串含三类、restore 可用、后端零改动。
/// ③ **本常量与相关测试断言本轮保持原样**，随 7-B 的包（2.1.8）改回标准
///   口径「删除后进回收站、30 天内可恢复」，不单独出返修包。
/// 详见 docs/personal-corner-plan.md「删除口径」。
const String privateDeleteText = '私密内容删除后不进回收站、不可恢复';

class PersonalPage extends ConsumerStatefulWidget {
  const PersonalPage({super.key});

  @override
  ConsumerState<PersonalPage> createState() => _PersonalPageState();
}

class _PersonalPageState extends ConsumerState<PersonalPage> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(personalControllerProvider.notifier).bootstrap());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('我的小角落', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  Text('有些心事留给自己，有些惊喜留给未来。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
                ]),
          ),
          // 可扩展 tab 行：只按 personalTabs 表渲染（本段 2 项）
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                for (var i = 0; i < personalTabs.length; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Center(child: Text(personalTabs[i].label)),
                        selected: _tab == i,
                        onSelected: (_) => setState(() => _tab = i),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // IndexedStack 常驻：两 tab 各自状态（滚动位置/加载态）切换不丢
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: const [_DiaryTab(), _DraftTab()],
            ),
          ),
        ]),
      ),
    );
  }
}

/// 提示 + 入口按钮 + 空态/列表的公共骨架（两 tab 共用，文案逐字 Web）。
class _TabFrame extends ConsumerWidget {
  const _TabFrame({
    required this.hint,
    required this.entryLabel,
    required this.onEntry,
    required this.emptyTitle,
    required this.items,
    required this.tileBuilder,
  });
  final String hint;
  final String entryLabel;
  final VoidCallback onEntry;
  final String emptyTitle;
  final List<TogetherRecord> items;
  final Widget Function(TogetherRecord record) tileBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: () => ref.read(personalControllerProvider.notifier).load(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(hint,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              onPressed: onEntry,
              child: Text(entryLabel),
            ),
          ),
          const SizedBox(height: 8),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Column(children: [
                Icon(Icons.lock_outline_rounded,
                    size: 44, color: theme.colorScheme.outline),
                const SizedBox(height: 12),
                Text(emptyTitle, style: theme.textTheme.titleMedium),
                const SizedBox(height: 6),
                Text('慢慢写，不着急。',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              ]),
            )
          else
            for (final r in items) tileBuilder(r),
        ],
      ),
    );
  }
}

/// 顶部结果提示（复用全局 ChatToastHost 同一 provider）
void _toast(WidgetRef ref, String? err, {required String okMsg}) {
  ref.read(chatToastProvider.notifier).show(
      err == null ? okMsg : '操作失败：$err',
      tone: err == null ? ChatToastTone.success : ChatToastTone.error);
}

/// 私密类删除确认（可取消）→ DELETE → 本地移除。
Future<void> confirmPrivateDelete(
    BuildContext context, WidgetRef ref, String rid) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: const Text('删除这条记录'),
      content: const Text(privateDeleteText),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error),
          onPressed: () => Navigator.of(dctx).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  final err = await ref.read(personalControllerProvider.notifier).delete(rid);
  if (context.mounted) _toast(ref, err, okMsg: '已删除');
}

String _recordTitle(TogetherRecord r) {
  final title = (r.body['title'] ?? '').toString().trim();
  if (title.isNotEmpty) return title;
  final content = (r.body['content'] ?? '').toString().trim();
  return content.length > 24 ? '${content.substring(0, 24)}…' : content;
}

// ── tab ① 私密日记 ─────────────────────────────────────────────────

class _DiaryTab extends ConsumerWidget {
  const _DiaryTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(personalControllerProvider); // 列表变更时重建本 tab
    final diaries = ref.read(personalControllerProvider.notifier).diaries();
    return _TabFrame(
      hint: personalTabs[0].hint,
      entryLabel: '开始记录',
      onEntry: () => context.push('/personal/diary-form'),
      emptyTitle: '给自己，留一点心里话',
      items: diaries,
      tileBuilder: (r) => _DiaryTile(record: r),
    );
  }
}

class _DiaryTile extends ConsumerWidget {
  const _DiaryTile({required this.record});
  final TogetherRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(record.date.isNotEmpty ? record.date : '私密日记',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ),
            IconButton(
              tooltip: '编辑日记',
              visualDensity: VisualDensity.compact,
              onPressed: () => context.push('/personal/diary-form',
                  extra: <String, Object?>{'record': record}),
              icon: const Icon(Icons.edit_outlined, size: 20),
            ),
            IconButton(
              tooltip: '删除日记',
              visualDensity: VisualDensity.compact,
              onPressed: () => confirmPrivateDelete(context, ref, record.id),
              icon: Icon(Icons.delete_outline_rounded,
                  size: 20, color: theme.colorScheme.error),
            ),
          ]),
          Text(_recordTitle(record), style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text((record.body['content'] ?? '').toString(),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium),
        ]),
      ),
    );
  }
}

/// 日记简洁表单（多行 content 必填；新建/编辑共用）。
/// 二级页：context.push 打开，AppBar 自动返回按钮 + 系统手势都能回上一页。
class DiaryFormPage extends ConsumerStatefulWidget {
  const DiaryFormPage({super.key, this.record});
  final TogetherRecord? record;

  @override
  ConsumerState<DiaryFormPage> createState() => _DiaryFormPageState();
}

class _DiaryFormPageState extends ConsumerState<DiaryFormPage> {
  late final TextEditingController _content =
      TextEditingController(text: (widget.record?.body['content'] ?? '').toString());
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final text = _content.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '写点什么吧');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final ctrl = ref.read(personalControllerProvider.notifier);
    final err = widget.record == null
        ? await ctrl.addDiary(text)
        : await ctrl.editDiary(widget.record!, text);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _error = err;
        _saving = false;
      });
      return;
    }
    _toast(ref, null, okMsg: widget.record == null ? '已记下' : '已保存修改');
    Navigator.of(context).pop(); // push 的返回路径：按钮/手势同栈
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.record == null ? '写日记' : '编辑日记')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('只有你能看见，放心写吧',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 10),
          TextField(
            controller: _content,
            maxLines: 8,
            minLines: 4,
            maxLength: 20000,
            autofocus: widget.record == null,
            decoration: const InputDecoration(
              labelText: '给自己的心里话',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中…' : '保存日记'),
          ),
        ],
      ),
    );
  }
}

// ── tab ② 草稿箱 ───────────────────────────────────────────────────

class _DraftTab extends ConsumerWidget {
  const _DraftTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(personalControllerProvider); // 列表变更时重建本 tab
    final drafts = ref.read(personalControllerProvider.notifier).drafts();
    return _TabFrame(
      hint: personalTabs[1].hint, // 两 tab 顶部 hint 同句（app.js:1489）
      // 「还没写完的故事，在这里等你」是空态标题，不是提示文案
      entryLabel: '写一份草稿',
      onEntry: () async {
        await showComposerSheet(context); // 正式 composer：存草稿 → POST kind=draft
        if (context.mounted) {
          await ref.read(personalControllerProvider.notifier).load();
        }
      },
      emptyTitle: '还没写完的故事，在这里等你',
      items: drafts,
      tileBuilder: (r) => _DraftTile(record: r),
    );
  }
}

class _DraftTile extends ConsumerWidget {
  const _DraftTile({required this.record});
  final TogetherRecord record;

  /// TogetherRecord → composer 编辑态所需的 timeline Record（不另造编辑器）。
  api.Record _toComposerRecord() => api.Record(
        id: record.id,
        kind: record.kind,
        author: record.author,
        body: Map<String, dynamic>.from(record.body),
        created: record.created,
        media: [
          for (final m in record.media) Map<String, dynamic>.from(m),
        ],
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('草稿 · ${record.date}',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ),
            IconButton(
              tooltip: '删除草稿',
              visualDensity: VisualDensity.compact,
              onPressed: () => confirmPrivateDelete(context, ref, record.id),
              icon: Icon(Icons.delete_outline_rounded,
                  size: 20, color: theme.colorScheme.error),
            ),
          ]),
          Text(_recordTitle(record), style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text((record.body['content'] ?? '').toString(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          Row(children: [
            OutlinedButton(
              onPressed: () async {
                // 正式 composer 编辑态：预填草稿 + 保持 kind=draft
                await showComposerSheet(context,
                    editRecord: _toComposerRecord(), editKind: 'draft');
                if (context.mounted) {
                  await ref.read(personalControllerProvider.notifier).load();
                }
              },
              child: const Text('继续编辑'),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: () => context.push('/personal/publish',
                  extra: <String, Object?>{'draft': record}),
              child: const Text('发布'),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// 草稿发布选择（三选一 post / diary / surprise）。
/// surprise 必须额外收集**未来**时间（main.py:1127 否则 422）。
class DraftPublishPage extends ConsumerStatefulWidget {
  const DraftPublishPage({super.key, required this.draft});
  final TogetherRecord draft;

  @override
  ConsumerState<DraftPublishPage> createState() => _DraftPublishPageState();
}

class _DraftPublishPageState extends ConsumerState<DraftPublishPage> {
  String _target = 'post';
  DateTime? _publishAt;
  String? _error;
  bool _saving = false;

  Future<void> _pickPublishAt() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _publishAt ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365 * 10)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
          _publishAt ?? now.add(const Duration(hours: 1))),
    );
    if (t == null || !mounted) return;
    final picked = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    if (!picked.isAfter(DateTime.now())) {
      setState(() => _error = '请选择未来的公开时间');
      return;
    }
    setState(() {
      _publishAt = picked;
      _error = null;
    });
  }

  Future<void> _publish() async {
    if (_saving) return;
    if (_target == 'surprise' && _publishAt == null) {
      setState(() => _error = '请选择未来的公开时间');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final err = await ref.read(personalControllerProvider.notifier).publishDraft(
          widget.draft,
          _target,
          publishAt: _target == 'surprise' ? _publishAt : null,
        );
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _error = err;
        _saving = false;
      });
      return;
    }
    _toast(ref, null,
        okMsg: _target == 'post'
            ? '已发布到时光'
            : _target == 'diary'
                ? '已存为私密日记'
                : '惊喜已藏好');
    Navigator.of(context).pop(); // push 的返回路径
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('发布这份草稿')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('发布后这份草稿会从草稿箱移除。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: _target,
            onChanged: (v) => setState(() => _target = v ?? 'post'),
            child: Column(children: const [
              RadioListTile<String>(
                  value: 'post',
                  title: Text('发布到时光'),
                  subtitle: Text('两个人都能看见')),
              RadioListTile<String>(
                  value: 'diary',
                  title: Text('存为私密日记'),
                  subtitle: Text('只有你能看见')),
              RadioListTile<String>(
                  value: 'surprise',
                  title: Text('定时惊喜'),
                  subtitle: Text('到约定的时间，惊喜才会被另一半看见。')),
            ]),
          ),
          if (_target == 'surprise') ...[
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule_rounded),
              title: Text(_publishAt == null
                  ? '选择未来的公开时间'
                  : '公开时间：${_fmt(_publishAt!)}'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _pickPublishAt,
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _publish,
            child: Text(_saving ? '发布中…' : '确认发布'),
          ),
        ],
      ),
    );
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
}
