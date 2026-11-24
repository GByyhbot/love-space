/// `/notices` 通知中心二级页（「数据管理与通知渠道」章 · 段 A · 2.2.5/VC225）。
///
/// 契约（对齐 Web `static/app.js:1492` / `main.py:1955-1983`）：
/// · `GET /api/notices` 最多 200 条、仅本人、created 倒序；**内容只来自
///   服务端**：不本地造通知文案 / 不本地造 event / 不本地推断未读。
/// · 首行过滤 `event != 'chat'`（聊天消息不在通知中心呈现），空态
///   「还没有新的提醒…聊天消息请在私聊中查看」。
/// · `POST /api/notices/read`：空参数＝全部已读；`record_id`＝单条已读
///   （查看时对齐 `app.js:2613`）；
///   `DELETE /api/notices/read`：删已读，删前确认文案对齐 `app.js:2572`。
/// · 🔴 全部写方法经 `NotifyApi._write` → `writeResponseError`，4xx 服务端
///   `detail` 原文经「顶部通知(error) + 页面内联错误区」双呈现；失败不发成功
///   通知 / 不 pop / 输入保留 / 不自动重试 / 不本地改动列表，成功才重拉。
/// · 铃铛角标联动：进页 / 全部已读 / 删已读 / 查看后 `authProvider.reload()`
///   重拉 `GET /api/me`，`systemUnreadProvider` 由服务端 `unread` 播种
///   （**以服务端为准，不本地推算**）。
/// · 不自创：没有本地通知生成、没有免打扰设置、没有推送开关、没有 WebPush。
/// · 二级页 `context.push` 打开，AppBar `automaticallyImplyLeading` 不关 →
///   返回按钮 + 系统返回手势都能回上一页。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/notify/notify_decision.dart'
    show NoticeTargetKind, noticeTargetOf;
import '../../core/theme/tokens.dart';
import '../../core/ui/progress.dart';
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../timeline/record_story_sheet.dart' show showRecordStorySheet;
import 'notify_api.dart';
import 'notify_models.dart';
import 'notify_widgets.dart';
import '../../core/ui/hold_to_confirm.dart' show HoldToConfirmButton;
import '../../core/ui/stagger_in.dart' show StaggerIn;
import '../settings/settings_state.dart' show spaceAppearanceProvider;

class NoticesPage extends ConsumerStatefulWidget {
  const NoticesPage({super.key});

  @override
  ConsumerState<NoticesPage> createState() => _NoticesPageState();
}

class _NoticesPageState extends ConsumerState<NoticesPage> {
  List<NoticeItem> _notices = const <NoticeItem>[];
  bool _loading = true;
  bool _busy = false;
  String? _pageError;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await _load();
      await _refreshBadge(); // 进页即以服务端 me.unread 校正铃铛角标
    });
  }

  Future<NotifyApi> _service() async =>
      NotifyApi(await ref.read(api.dioProvider.future));

  /// 角标唯一数据源：`GET /api/me` 的 `unread`（`main.py:723`）。
  Future<void> _refreshBadge() async =>
      ref.read(authProvider.notifier).reload();

  /// 全量拉取（进页 / 下拉刷新 / 写成功后）。
  Future<void> _load() async {
    try {
      final NotifyApi svc = await _service();
      final List<NoticeItem> notices = await svc.loadNotices();
      if (!mounted) return;
      setState(() {
        _notices = notices;
        _loading = false;
        _pageError = null;
      });
    } on NotifyFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _pageError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _pageError = api.errorDetail(e);
      });
    }
  }

  void _toast(String text, {ChatToastTone tone = ChatToastTone.info}) {
    ref.read(chatToastProvider.notifier).show(text, tone: tone);
  }

  /// Web `app.js:1492` 首行 `filter(n => n.event !== 'chat')`。
  List<NoticeItem> get _visible => _notices
      .where((NoticeItem n) => n.event != 'chat')
      .toList(growable: false);

  /// 已读条数（Web 同款：过滤 chat 之后再数 seen）。
  int get _readCount => _visible.where((NoticeItem n) => n.seen).length;

  /// 🔴 统一写后处理：失败＝原文双呈现且不重拉 / 不改列表 / 不重试；
  /// 成功＝顶部成功通知 + 重拉 me 校正角标 + 重拉 GET 确认结果。
  Future<void> _runWrite(
    Future<String?> Function(NotifyApi svc) action, {
    required String successText,
    bool silent = false,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _actionError = null;
    });
    String? err;
    try {
      final NotifyApi svc = await _service();
      err = await action(svc);
    } catch (e) {
      err = api.errorDetail(e);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      setState(() => _actionError = err);
      _toast(err, tone: ChatToastTone.error);
      return;
    }
    setState(() => _actionError = null);
    // 2.5.9：silent=true 供多事件循环（markAllRead 逐事件调用），
    // 成功 toast 与刷新由调用方收尾统一做一次。
    if (!silent) {
      _toast(successText, tone: ChatToastTone.success);
      await _refreshBadge();
      await _load();
    }
  }

  /// 2.5.9 条目三裁定④：全部已读只清非 chat 事件——按当前列表涉及的
  /// 未读事件逐个调 `POST /api/notices/read?event=<e>`；私聊未读只能由
  /// 进入聊天页清除（chat 不进此循环）。单条已读（record_id）行为不变。
  Future<void> _markAllRead() async {
    final events = _notices
        .where((n) => !n.seen && n.event != 'chat')
        .map((n) => n.event)
        .toSet();
    if (events.isEmpty) {
      _toast('没有可标记的未读提醒');
      return;
    }
    setState(() {
      _busy = true;
      _actionError = null;
    });
    String? err;
    try {
      final NotifyApi svc = await _service();
      for (final e in events) {
        err = await svc.markNoticesRead(event: e);
        if (err != null) break;
      }
    } catch (e) {
      err = api.errorDetail(e);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      setState(() => _actionError = err);
      _toast(err, tone: ChatToastTone.error);
      return;
    }
    setState(() => _actionError = null);
    _toast('已全部标记为已读', tone: ChatToastTone.success);
    await _refreshBadge();
    await _load();
  }

  /// 删除已读：确认文案逐字对齐 `app.js:2572`。
  Future<void> _deleteRead() async {
    final int count = _readCount;
    if (count == 0) {
      _toast('没有可删除的已读提醒');
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除已读提醒？'),
        content: Text(
          '将删除 $count 条已读提醒，不会影响未读提醒、动态或聊天记录。',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('notices-delete-cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          // 2.4.10 第 04 项：确认改长按确认（key 保留供测试）。
          HoldToConfirmButton(
            key: const Key('notices-delete-confirm'),
            onConfirm: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok != true) return; // 可取消
    await _runWrite(
      (NotifyApi svc) => svc.deleteReadNotices(),
      successText: '已删除 $count 条已读提醒',
    );
  }

  /// 查看详情（2.4.5 乙组第 4 项改造：点击一条通知 → 跳到它指的内容，
  /// 落点判定走 noticeTargetOf 逐类映射表；已读逻辑保持现行——查看后按
  /// record_id 单条已读（notices_page.dart 原语义，app.js:2613 口径））：
  /// · route：push 功能页（anniversary/period/wish/habit）后标已读；
  /// · fallback：原弹层（服务端 title + 事件名 + 时间）后标已读；
  /// · recordStory 由 _openRecordStory 处理（本函数兜不住，见 _noticeRow）。
  Future<void> _onDetail(NoticeItem n) async {
    final target = noticeTargetOf(n.event, n.recordId);
    if (target.kind == NoticeTargetKind.route) {
      if (!mounted) return;
      await _runWrite(
        (NotifyApi svc) => svc.markNoticesRead(recordId: n.recordId),
        successText: '已标记为已读',
      );
      if (mounted) context.push(target.route);
      return;
    }
    // 兜底弹层（fallback 落点）
    if (!mounted) return;
    await _showFallbackDialog(n);
    if (!mounted) return;
    await _runWrite(
      (NotifyApi svc) => svc.markNoticesRead(recordId: n.recordId),
      successText: '已标记为已读',
    );
  }

  /// recordStory 落点（2.8.1：取到记录后按 kind 二次分流）。
  ///
  /// 通知行只有 event + record_id，没有 kind。所以统一先取记录：
  /// · 取不到（记录已删 / 404）→ toast「这条记录已不存在」，留在通知中心，
  ///   标已读、不崩溃、不跳空白页；
  /// · kind=anniversary → 纪念日列表页；kind=period → 生理期页；
  /// · 其余 → 「历史上的今天」同款记录底部弹层。
  Future<void> _openRecordStory(NoticeItem n) async {
    api.Record? record;
    // 404 = 记录确实被删了（走 toast）；网络/5xx 不当成"已删"（走既有兜底弹层）
    var gone = false;
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.get('/api/records/${n.recordId}');
      if (r.statusCode == 200 && r.data is Map) {
        record = api.Record.fromJson((r.data as Map).cast<String, dynamic>());
      } else if (r.statusCode == 404) {
        gone = true;
      }
    } catch (_) {
      gone = false;
    }
    if (!mounted) return;
    if (record == null) {
      if (gone) {
        _toast('这条记录已不存在', tone: ChatToastTone.warning);
      } else {
        await _showFallbackDialog(n);
      }
      if (!mounted) return;
      await _runWrite(
        (NotifyApi svc) => svc.markNoticesRead(recordId: n.recordId),
        successText: '已标记为已读',
      );
      return;
    }
    final target = noticeTargetOf(n.event, n.recordId, record.kind);
    if (target.kind == NoticeTargetKind.route) {
      await _runWrite(
        (NotifyApi svc) => svc.markNoticesRead(recordId: n.recordId),
        successText: '已标记为已读',
      );
      if (mounted) context.push(target.route);
      return;
    }
    final me = ref.read(authProvider.notifier).me;
    if (me != null) {
      await showRecordStorySheet(context, record: record, me: me);
    }
    if (!mounted) return;
    await _runWrite(
      (NotifyApi svc) => svc.markNoticesRead(recordId: n.recordId),
      successText: '已标记为已读',
    );
  }

  /// 原兜底弹层（fallback 落点；与 recordStory 拉取失败共用）。
  Future<void> _showFallbackDialog(NoticeItem n) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('这一刻的故事'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(n.title),
            const SizedBox(height: Spacing.gap),
            Text(
              '${eventLabel(n.event)} · ${noticeTimeLabel(n.created)}',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<NoticeItem> visible = _visible;
    final int readCount = _readCount;
    return Scaffold(
      // automaticallyImplyLeading 不关：返回按钮 + 系统手势都能回上一页。
      appBar: AppBar(
        title: const Text('小小的提醒'),
        actions: <Widget>[
          TextButton(
            key: const Key('notices-read-all'),
            onPressed: _busy ? null : _markAllRead,
            child: const Text('全部已读'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, Spacing.pageBottom),
          children: <Widget>[
            const NotifyInfoCard(
              title: '每一份回应，都值得被看见',
              subtitle: '聊天消息不在通知中心呈现，请到私聊中查看。',
              lines: <String>[
                '这里的提醒全部来自服务端：留言、互动、纪念日与生理期提醒等。',
                '浏览器系统通知仅网页端可用，原生端请使用第三方渠道。',
              ],
            ),
            if (readCount > 0)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('notices-delete-read'),
                  onPressed: _busy ? null : _deleteRead,
                  child: Text('删除已读提醒（$readCount）'),
                ),
              ),
            if (_pageError != null) NotifyErrorBanner(text: _pageError!),
            if (_actionError != null) NotifyErrorBanner(text: _actionError!),
            if (_busy) const LinearProgressIndicator(),
            if (_loading && visible.isEmpty)
              // G16 收编：统一 spinner 包装（原 Padding(28) 散形态）
              const AppProgress()
            else if (visible.isEmpty)
              const NotifyEmptyCard(
                title: '还没有新的提醒',
                detail:
                    '收到留言、互动和纪念日提醒时，会出现在这里。聊天消息请在私聊中查看。',
              )
            else
              Card(
                margin: EdgeInsets.zero,
                child: Column(
                  children: <Widget>[
                    // 2.4.10 附录 B ①：首屏错峰入场。
                    for (final (i, n) in visible.indexed)
                      StaggerIn(
                          index: i,
                          enable: ref.watch(spaceAppearanceProvider).motion,
                          child: _noticeRow(theme, n)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _noticeRow(ThemeData theme, NoticeItem n) {
    final ColorScheme cs = theme.colorScheme;
    final target = noticeTargetOf(n.event, n.recordId);
    return ListTile(
      key: Key('notice-card-${n.id}'),
      // 2.4.5 乙组第 4 项：整行可点，不许留「点了没反应」的死条目；
      // recordStory 落点走弹层拉取（非 _busy 限定），其余同原「查看」入口。
      onTap: _busy
          ? null
          : () {
              if (target.kind == NoticeTargetKind.recordStory) {
                _openRecordStory(n);
              } else {
                _onDetail(n);
              }
            },
      leading: Icon(
        n.seen ? Icons.notifications_none_rounded : Icons.notifications_rounded,
        size: 20,
        color: n.seen ? cs.outline : cs.primary,
      ),
      title: Text(
        n.title,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: n.seen ? FontWeight.normal : FontWeight.w600,
        ),
      ),
      subtitle: Text(
        '${eventLabel(n.event)} · ${noticeTimeLabel(n.created)}',
        style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
      ),
      trailing: n.recordId.isEmpty
          ? (n.seen
              ? null
              : Icon(Icons.brightness_1, size: 8, color: cs.primary))
          : TextButton(
              key: Key('notice-detail-${n.id}'),
              onPressed: _busy
                  ? null
                  : () {
                      if (target.kind == NoticeTargetKind.recordStory) {
                        _openRecordStory(n);
                      } else {
                        _onDetail(n);
                      }
                    },
              child: const Text('查看'),
            ),
    );
  }
}
