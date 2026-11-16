/// 「个人角落」段 7-A / 7-B / 7-C 页面（条目 7 收尾段）。
///
/// · heading「我的小角落」/ 副标题「有些心事留给自己，有些惊喜留给未来。」；
/// · tab 结构 = 可扩展数据表 [personalTabs]：7-A 上 diary / draft，7-B 增补
///   surprise / trash，7-C 收尾增补 personal_wish 共**五项**（无死卡纪律：
///   Web 能点的 App 才有去向，7-C 后条目 7 无后续段）；
/// · 各 tab 顶部提示文案逐字对齐 Web app.js:1484-1490 / :1302；
/// · 二级页（日记表单 / 草稿发布选择 / 惊喜表单 / 个人心愿创建 / 解锁）一律
///   context.push（AppBar 自动返回按钮 + 系统手势都能回上一页）；tab 间切换用
///   IndexedStack 常驻，不丢状态；
/// · 草稿「继续编辑 / 写一份草稿」直接对接正式 composer（不另造编辑器）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/chat/chat_repository.dart' show newChatClientId;
import '../../core/together/together_data.dart';
import '../../core/ui/error_view.dart';
import '../../core/ui/progress.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../timeline/composer_sheet.dart';
import 'personal_controller.dart';
import '../../core/theme/tokens.dart';

/// tab 数据表（可扩展：7-C 追加第 5 项 personal_wish，绝不预置死卡）。
/// hint 逐字对齐 Web app.js:1489 / :1302：
/// · diary / draft 同句「这个角落只有你能看见。草稿主动发布后，才会进入共同空间。」
/// · surprise 用「到约定的时间，惊喜才会被另一半看见。」
/// · trash 用 app.js:1488「删除的内容保留三十天，你可以恢复自己的记录。」
/// · personal_wish 用 app.js:1302 personalWishPage 的 hint（逐字）。
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
  (
    id: 'surprise',
    label: '定时惊喜',
    hint: '到约定的时间，惊喜才会被另一半看见。'
  ),
  (
    id: 'trash',
    label: '回收站',
    hint: '删除的内容保留三十天，你可以恢复自己的记录。'
  ),
  (
    id: 'personal_wish',
    label: '个人心愿',
    hint: '心愿名称彼此可见。密码至少 6 位（建议纯数字），每条心愿都要不同；告诉对方后，对方解锁一次即可永久查看。'
  ),
];

/// Web personalWishPage 页头副标题（app.js:1302 heading 第二参，逐字）。
/// App 是「我的小角落」下的第 5 个 tab，页头标题由 tab 标签承担，副标题在
/// tab 内单独呈现，不自创文案。
const String personalWishSubtitle =
    '写下的人可以直接回看，对方输入一次密码后就能一直看到。';

/// 🔴 7-B 搭载修正：删除文案统一标准口径（主人 2026-11-14「甲·对齐 Web」定案）。
/// 三类（日记 / 草稿 / 惊喜）与共享类 post_card.dart:271 完全一致：
/// 服务端 DELETE 是软删（main.py:1424），确实进回收站且 30 天内可 restore。
/// 7-A 的「不进回收站、不可恢复」临时口径作废。
const String privateDeleteText = '删除后会进入回收站，30 天内可以恢复。';

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
          // 可扩展 tab 行：只按 personalTabs 表渲染（7-A 2 项 → 7-B 4 项 → 7-C 5 项）
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                for (var i = 0; i < personalTabs.length; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: ChoiceChip(
                        label: Center(
                            child: Text(personalTabs[i].label,
                                style: theme.textTheme.bodySmall)),
                        selected: _tab == i,
                        onSelected: (_) => setState(() => _tab = i),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // IndexedStack 常驻：五 tab 各自状态（滚动位置/加载态）切换不丢
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: const [
                _DiaryTab(),
                _DraftTab(),
                _SurpriseTab(),
                _TrashTab(),
                _WishTab(),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// 提示 + 入口按钮 + 空态/列表的公共骨架（五 tab 共用，文案逐字 Web）。
/// [entryLabel] / [onEntry] 为空时不显示新建按钮（回收站无新建入口）；
/// [subtitle] 为 Web 页头副标题（7-C 个人心愿 tab 用）；[emptyEntryLabel]
/// 为 Web 空态里的第二入口按钮（如「许下第一份心愿」），复用 [onEntry]。
class _TabFrame extends ConsumerWidget {
  const _TabFrame({
    required this.hint,
    this.subtitle,
    this.entryLabel,
    this.onEntry,
    this.emptyEntryLabel,
    required this.emptyTitle,
    this.emptyHint = '慢慢写，不着急。',
    required this.items,
    required this.tileBuilder,
    this.loading = false,
    this.error,
    this.onRetry,
  });
  final String hint;
  final String? subtitle;
  final String? entryLabel;
  final VoidCallback? onEntry;
  final String? emptyEntryLabel;
  final String emptyTitle;
  final String emptyHint;
  final List<TogetherRecord> items;
  final Widget Function(TogetherRecord record) tileBuilder;

  /// 首拉 loading（段 C 2.3.0 防闪空态）：controller 各路 loading 原样透传。
  final bool loading;

  /// 加载失败 detail 原文（非空且列表为空时呈现可重试错误态）。
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: () async {
        await ref.read(personalControllerProvider.notifier).load();
        await ref.read(personalControllerProvider.notifier).loadTrash();
        await ref.read(personalControllerProvider.notifier).loadWishes();
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, Spacing.pageBottom),
        children: [
          if (subtitle != null) ...[
            Text(subtitle!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const SizedBox(height: Spacing.gap),
          ],
          Text(hint,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
          if (entryLabel != null && onEntry != null) ...[
            const SizedBox(height: Spacing.gap),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: onEntry,
                child: Text(entryLabel!),
              ),
            ),
          ],
          const SizedBox(height: Spacing.gap),
          // 三态优先级（段 C）：首拉 loading 防闪空态 → 空态且加载失败 →
          // 可重试错误态 → 空态 → 列表。
          if (loading && items.isEmpty)
            const AppProgress()
          else if (error != null && items.isEmpty)
            Center(
              child: AppErrorView(
                detail: error!,
                onRetry: onRetry ?? () {},
              ),
            )
          else if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Column(children: [
                Icon(Icons.lock_outline_rounded,
                    size: 44, color: theme.colorScheme.outline),
                const SizedBox(height: 12),
                Text(emptyTitle, style: theme.textTheme.titleMedium),
                const SizedBox(height: Spacing.gap),
                Text(emptyHint,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
                if (emptyEntryLabel != null && onEntry != null) ...[
                  const SizedBox(height: 14),
                  FilledButton.tonal(
                    onPressed: onEntry,
                    child: Text(emptyEntryLabel!),
                  ),
                ],
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
/// [wish] = true 时走 7-C 的 [PersonalController.deleteWish]（重拉 wishes +
/// trash）；确认弹层文案两路都是 7-B 统一的 [privateDeleteText] 标准口径。
Future<void> confirmPrivateDelete(
    BuildContext context, WidgetRef ref, String rid,
    {bool wish = false}) async {
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
  final ctrl = ref.read(personalControllerProvider.notifier);
  final err = wish ? await ctrl.deleteWish(rid) : await ctrl.delete(rid);
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
    final st = ref.watch(personalControllerProvider); // 列表变更时重建本 tab
    final diaries = ref.read(personalControllerProvider.notifier).diaries();
    return _TabFrame(
      hint: personalTabs[0].hint,
      entryLabel: '开始记录',
      onEntry: () => context.push('/personal/diary-form'),
      emptyTitle: '给自己，留一点心里话',
      items: diaries,
      tileBuilder: (r) => _DiaryTile(record: r),
      loading: st.loading,
      error: st.error,
      onRetry: () => ref.read(personalControllerProvider.notifier).load(),
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
    final st = ref.watch(personalControllerProvider); // 列表变更时重建本 tab
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
      loading: st.loading,
      error: st.error,
      onRetry: () => ref.read(personalControllerProvider.notifier).load(),
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
          const SizedBox(height: Spacing.gap),
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
          const SizedBox(height: Spacing.gap),
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
            const SizedBox(height: Spacing.gap),
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

// ── tab ③ 定时惊喜（7-B） ─────────────────────────────────────────

/// epoch 秒 → 'yyyy-MM-dd HH:mm'（本地时区；与 Web dateLabel 呈现同口径）
String _fmtStamp(double seconds) {
  if (seconds <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

class _SurpriseTab extends ConsumerWidget {
  const _SurpriseTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(personalControllerProvider); // 列表变更时重建本 tab
    final items = ref.read(personalControllerProvider.notifier).surprises();
    return _TabFrame(
      hint: personalTabs[2].hint, // app.js:1489 惊喜口径，逐字
      entryLabel: '准备惊喜',
      onEntry: () => context.push('/personal/surprise-form'),
      emptyTitle: '提前准备一份温柔的惊喜',
      items: items,
      tileBuilder: (r) => _SurpriseTile(record: r),
      loading: st.loading,
      error: st.error,
      onRetry: () => ref.read(personalControllerProvider.notifier).load(),
    );
  }
}

class _SurpriseTile extends ConsumerWidget {
  const _SurpriseTile({required this.record});
  final TogetherRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final at = (record.body['publish_at'] as num?)?.toDouble() ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    final revealed = at > 0 && at <= now;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(
                  revealed ? '已到约定时间 · 等待公开' : '待揭示',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: cs.outline)),
            ),
            IconButton(
              tooltip: '编辑惊喜',
              visualDensity: VisualDensity.compact,
              onPressed: () => context.push('/personal/surprise-form',
                  extra: <String, Object?>{'record': record}),
              icon: const Icon(Icons.edit_outlined, size: 20),
            ),
            IconButton(
              tooltip: '删除惊喜',
              visualDensity: VisualDensity.compact,
              onPressed: () => confirmPrivateDelete(context, ref, record.id),
              icon: Icon(Icons.delete_outline_rounded,
                  size: 20, color: cs.error),
            ),
          ]),
          Text(_recordTitle(record), style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text((record.body['content'] ?? '').toString(),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: Spacing.gap),
          Row(children: [
            Icon(Icons.schedule_rounded, size: 14, color: cs.outline),
            const SizedBox(width: 4),
            Text('公开时间：${_fmtStamp(at)}',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: cs.outline)),
          ]),
        ]),
      ),
    );
  }
}

/// 惊喜简洁表单（正文 + 发布时间选择器；新建/编辑共用）。
/// · publish_at 必填且未来（main.py:1127 窗口：now < t < now+50 年）；
/// · 服务端 422 原文案经 api.errorDetail 透传到**顶部通知**，绝不静默失败；
/// · 编辑走回填铁律（mergeRecordBody 全量 body，改期也走它）。
/// 二级页：context.push 打开，AppBar 自动返回按钮 + 系统手势都能回上一页。
class SurpriseFormPage extends ConsumerStatefulWidget {
  const SurpriseFormPage({super.key, this.record});
  final TogetherRecord? record;

  @override
  ConsumerState<SurpriseFormPage> createState() => _SurpriseFormPageState();
}

class _SurpriseFormPageState extends ConsumerState<SurpriseFormPage> {
  late final TextEditingController _content = TextEditingController(
      text: (widget.record?.body['content'] ?? '').toString());
  DateTime? _publishAt;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final at = (widget.record?.body['publish_at'] as num?)?.toDouble();
    if (at != null && at > 0) {
      _publishAt = DateTime.fromMillisecondsSinceEpoch((at * 1000).round());
    }
  }

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _publishAt ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365 * 50)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
          _publishAt ?? now.add(const Duration(hours: 1))),
    );
    if (t == null || !mounted) return;
    setState(() {
      _publishAt = DateTime(d.year, d.month, d.day, t.hour, t.minute);
      _error = null;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final text = _content.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '写点什么吧');
      return;
    }
    final at = _publishAt;
    if (at == null || !at.isAfter(DateTime.now())) {
      setState(() => _error = '请选择未来的公开时间');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final ctrl = ref.read(personalControllerProvider.notifier);
    final err = widget.record == null
        ? await ctrl.addSurprise(text, at)
        : await ctrl.editSurprise(widget.record!, text, at);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _error = err;
        _saving = false;
      });
      // 🔴 服务端 422 原文案（如「请选择未来的公开时间」）走顶部通知，
      // 与表单内错误态双呈现，绝不静默失败。
      ref.read(chatToastProvider.notifier).show(err,
          tone: ChatToastTone.error);
      return;
    }
    _toast(ref, null,
        okMsg: widget.record == null ? '惊喜已藏好' : '已保存修改');
    Navigator.of(context).pop(); // push 的返回路径：按钮/手势同栈
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.record == null ? '准备惊喜' : '编辑惊喜')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(personalTabs[2].hint,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 12),
          TextField(
            controller: _content,
            maxLines: 8,
            minLines: 4,
            maxLength: 20000,
            autofocus: widget.record == null,
            decoration: const InputDecoration(
              labelText: '想说的话',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule_rounded),
            title: Text(_publishAt == null
                ? '选择未来的公开时间'
                : '公开时间：${_fmtStamp(_publishAt!.millisecondsSinceEpoch / 1000)}'),
            subtitle: const Text('到约定时间，惊喜才会被另一半看见'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: _pick,
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
            child: Text(_saving ? '保存中…' : '保存惊喜'),
          ),
        ],
      ),
    );
  }
}

// ── tab ④ 回收站（7-B） ───────────────────────────────────────────

class _TrashTab extends ConsumerStatefulWidget {
  const _TrashTab();

  @override
  ConsumerState<_TrashTab> createState() => _TrashTabState();
}

class _TrashTabState extends ConsumerState<_TrashTab> {
  @override
  void initState() {
    super.initState();
    // 进页/切到本 tab 时重拉一次：回收站数据可能在别的 tab 被删改。
    Future.microtask(
        () => ref.read(personalControllerProvider.notifier).loadTrash());
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(personalControllerProvider);
    final items = ref.read(personalControllerProvider).trash;
    return _TabFrame(
      hint: personalTabs[3].hint, // app.js:1488 逐字
      // 🔴 Web 回收站只有「恢复」，没有「彻底删除」；App 不自创入口。
      emptyTitle: '回收站是空的',
      emptyHint: '你的回忆都在好好保存。',
      items: items,
      tileBuilder: (r) => _TrashTile(record: r),
      loading: st.loading || st.trashLoading,
      error: st.error,
      onRetry: () => ref.read(personalControllerProvider.notifier).loadTrash(),
    );
  }
}

class _TrashTile extends ConsumerWidget {
  const _TrashTile({required this.record});
  final TogetherRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_recordTitle(record), style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text('${kindLabel[record.kind] ?? record.kind} · '
              '${_fmtStamp(record.deleted)} 删除',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: cs.outline)),
          const SizedBox(height: Spacing.gap),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              // Web app.js:1488 按钮文案「恢复这份回忆」逐字
              onPressed: () async {
                final err = await ref
                    .read(personalControllerProvider.notifier)
                    .restore(record.id, kind: record.kind);
                if (context.mounted) {
                  _toast(ref, err, okMsg: '回忆已恢复');
                }
              },
              icon: const Icon(Icons.restore_rounded, size: 18),
              label: const Text('恢复这份回忆'),
            ),
          ),
        ]),
      ),
    );
  }
}

// ── tab ⑤ 个人心愿（7-C · 条目 7 收尾段） ─────────────────────────

/// 三态列表（作者免密 / 对方已解锁 / 对方待解锁），文案逐字 Web
/// personalWishPage（app.js:1302）+ personalWishCard（app.js:2009）。
/// 数据来自独立的 PersonalController.loadWishes（不按 author 过滤）。
class _WishTab extends ConsumerWidget {
  const _WishTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(personalControllerProvider); // 列表变更时重建本 tab
    final items = ref.read(personalControllerProvider.notifier).wishes();
    return _TabFrame(
      subtitle: personalWishSubtitle,
      hint: personalTabs[4].hint,
      entryLabel: '许下心愿',
      onEntry: () => context.push('/personal/wish-form'),
      emptyTitle: '留一份只差密码就能打开的心愿',
      emptyHint: '对方能看见心愿名称，具体内容仍由你掌握。',
      emptyEntryLabel: '许下第一份心愿',
      items: items,
      tileBuilder: (r) => _WishTile(record: r),
      loading: st.loading || st.wishLoading,
      error: st.error,
      onRetry: () => ref.read(personalControllerProvider.notifier).loadWishes(),
    );
  }
}

class _WishTile extends ConsumerWidget {
  const _WishTile({required this.record});
  final TogetherRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // 🔴 隐私红线（serializers.py:23-36 实读；数据层 sanitizeWishBody 已收敛一次）：
    // 只取 title / locked / content 三个键，其余字段（作者额外下发的 sealed
    // 密文、以及任何 stored/畸形字段）一律忽略——不渲染、不缓存、不进日志/
    // 通知/搜索。locked 态绝不呈现 content，即便响应里被畸形塞进来。
    final String title = (record.body['title'] ?? '').toString();
    final bool open = record.body['locked'] == false;
    final String content =
        open ? (record.body['content'] ?? '').toString() : '';
    final String uid = ref.read(personalCurrentUserProvider);
    final bool own = record.author == uid;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(own ? '你的个人心愿' : 'TA的个人心愿',
                        style: theme.textTheme.labelLarge),
                    const SizedBox(height: 2),
                    Text(
                        open
                            ? '已解锁 · 内容只有你们两人能看见'
                            : '具体内容已加密保存',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: cs.outline)),
                  ]),
            ),
            // 🔴 Web 无编辑（personalWishCard 只有作者卡片菜单「删除」）；
            // clean_body 对 personal_wish 明确 422「个人心愿请使用专属加密接口
            // 保存」→ App 不自创编辑入口，也不自创彻底删除。
            if (own)
              IconButton(
                tooltip: '删除心愿',
                visualDensity: VisualDensity.compact,
                onPressed: () => confirmPrivateDelete(context, ref, record.id,
                    wish: true),
                icon: Icon(Icons.delete_outline_rounded,
                    size: 20, color: cs.error),
              ),
          ]),
          const SizedBox(height: Spacing.gap),
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          if (open)
            Text(content, style: theme.textTheme.bodyMedium)
          else ...[
            Text(
                own
                    ? '这是你写下的个人心愿，输入密码即可回看内容。'
                    : 'TA 留了一份心愿给你，输入一次密码后就能一直读到内容。',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: cs.outline)),
            // 🔴 作者免密直达：作者态列表恒下发 locked:false + content，
            // 不需要任何额外请求。仅「对方待解锁」出现解锁入口，避免作者
            // 误发解锁请求（服务端退化锁定态也不自发重试）。
            if (!own) ...[
              const SizedBox(height: Spacing.gap),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => context.push('/personal/wish-unlock',
                      extra: <String, Object?>{
                        'rid': record.id,
                        'title': title,
                      }),
                  icon: const Icon(Icons.lock_outline_rounded, size: 18),
                  label: const Text('输入密码查看'),
                ),
              ),
            ],
          ],
        ]),
      ),
    );
  }
}

/// 创建表单（Web personalWishForm，app.js:1801 逐字）。
/// · 二级页 context.push：AppBar 自动返回按钮 + 系统手势都能回上一页；
/// · 客户端先拦空（title/content 非空、password 6..128）再发请求；
/// · 422 原文（撞密码等）**表单内联 + 顶部通知双呈现**，绝不吞。
/// 🔴 密码只在请求里过一遍：三个 controller 用完 dispose，不设 autofillHints
/// （避免系统密码管理器落盘）、不写任何本地存储、不打印、不进任何缓存；
/// 加解密全在服务端（main.py:1306-1332），客户端不实现任何加密。
class PersonalWishFormPage extends ConsumerStatefulWidget {
  const PersonalWishFormPage({super.key});

  @override
  ConsumerState<PersonalWishFormPage> createState() =>
      _PersonalWishFormPageState();
}

class _PersonalWishFormPageState
    extends ConsumerState<PersonalWishFormPage> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _content = TextEditingController();
  final TextEditingController _password = TextEditingController();
  // 🔴 7-C 返修：client_id 在表单生命周期内只生成**一次**，失败重试复用同值，
  // 逐字对齐 Web app.js:1801（打开表单生成一次、失败重试不换 id）。
  // 服务端按 (author, client_id) 幂等，重试换 id 会重复创建。
  late final String _clientId;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _clientId = newChatClientId();
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return; // 请求中按钮禁用，不连点叠加
    setState(() {
      _saving = true;
      _error = null;
    });
    final err = await ref
        .read(personalControllerProvider.notifier)
        .addPersonalWish(_title.text, _content.text, _password.text,
            clientId: _clientId);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _error = err;
        _saving = false;
      });
      // 🔴 失败一律走错误通知：err 是服务端 data['detail'] 原文（422 撞密码 /
      // 409 冲突），或客户端本地校验文案；表单内联 + 顶部通知双呈现，绝不吞。
      // 表单不 pop、密码框保留、按钮恢复可用 → 可原地重输重试（复用 _clientId）。
      ref.read(chatToastProvider.notifier).show(err,
          tone: ChatToastTone.error);
      return;
    }
    // 🔴 只有控制器返回 null 才发成功通知；4xx 已被 writeResponseError 拦下，
    // 不会再出现「失败却弹已加密保存」的真机阻断级现象。
    _toast(ref, null, okMsg: '这份个人心愿已加密保存');
    Navigator.of(context).pop(); // push 的返回路径：按钮/手势同栈
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('许下一份个人心愿')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(personalTabs[4].hint,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            maxLength: 100,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '心愿名称（对方可见）',
              hintText: '例如：有一天想和你去看海',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _content,
            maxLines: 8,
            minLines: 4,
            maxLength: 20000,
            decoration: const InputDecoration(
              labelText: '具体心愿内容（需要密码才能查看）',
              hintText: '写下想留给自己的心愿…',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            maxLength: 128,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '这条心愿的独立密码',
              hintText: '至少 6 位，建议纯数字',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Spacing.gap),
          Text(
            '每条心愿都要设置不同密码。写下心愿的你可以直接回看内容；把密码告诉对方后，对方输入一次就能看到，之后不必再输。忘记密码无法找回。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
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
            child: Text(_saving ? '加密保存中…' : '加密保存'),
          ),
        ],
      ),
    );
  }
}

/// 解锁页（Web unlockPersonalWish，app.js:1802 逐字）。
/// · 二级页 context.push；只传 rid + title（title 双方本就可见），不传 body；
/// · 作者本人 / 已解锁者列表已下发 content，不会走到这里；
/// · 403「密码不正确，请向心愿本人确认」/ 429「尝试过于频繁，请 15 分钟后再试」
///   服务端原文双呈现（表单内联 + 顶部通知），不吞、不自动重试；
/// · 成功后服务端写 readers_sealed，控制器重拉列表确认状态，客户端不自记
///   解锁态、不本地缓存 content。
/// 🔴 密码只在请求里过一遍：controller 用完 dispose，不设 autofillHints、
/// 不落本地存储、不进日志；请求中标量标志禁用按钮，不连点叠加。
class PersonalWishUnlockPage extends ConsumerStatefulWidget {
  const PersonalWishUnlockPage(
      {super.key, required this.rid, required this.title});
  final String rid;
  final String title;

  @override
  ConsumerState<PersonalWishUnlockPage> createState() =>
      _PersonalWishUnlockPageState();
}

class _PersonalWishUnlockPageState
    extends ConsumerState<PersonalWishUnlockPage> {
  final TextEditingController _password = TextEditingController();
  String? _error;
  bool _unlocking = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_unlocking) return; // 🔴 请求中直接丢弃后续点击，绝不叠加请求
    if (_password.text.isEmpty) {
      setState(() => _error = '请输入心愿密码');
      return;
    }
    setState(() {
      _unlocking = true;
      _error = null;
    });
    final err = await ref
        .read(personalControllerProvider.notifier)
        .unlockPersonalWish(widget.rid, _password.text);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _error = err;
        _unlocking = false; // 按钮恢复可用，不禁用
      });
      // 🔴 7-C 返修：失败一律走错误通知。err 是服务端 data['detail'] 原文
      //（403「密码不正确，请向心愿本人确认」/ 429「尝试过于频繁，请 15 分钟后再试」），
      // 或双条件门控未通过的失败文案；表单内联 + 顶部通知双呈现，绝不静默
      // 失败、**不自动重试**（限流配额敏感）。不清空 _password、不 pop →
      // 密码框保留可原地重输；卡片保持锁定态。
      ref.read(chatToastProvider.notifier).show(err,
          tone: ChatToastTone.error);
      return;
    }
    // 🔴 只有控制器双条件门控全通过才返回 null：
    //   ① 服务端确认成功（HTTP 2xx 且响应体含 content）；
    //   ② 重拉列表后该条 locked == false。
    // 任一不满足控制器已返回非 null，绝不会走到这里的成功通知（真机阻断级根修）。
    _toast(ref, null, okMsg: '已解锁，内容现在直接显示在心愿卡片里');
    Navigator.of(context).pop(); // push 的返回路径：按钮/手势同栈
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('打开这份个人心愿')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('「${widget.title}」的内容已加密，请输入心愿本人交给你的密码。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            maxLength: 128,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '心愿密码',
              hintText: '向心愿本人获取这条心愿的密码',
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
            onPressed: _unlocking ? null : _unlock,
            child: Text(_unlocking ? '解锁中…' : '解锁心愿'),
          ),
        ],
      ),
    );
  }
}
