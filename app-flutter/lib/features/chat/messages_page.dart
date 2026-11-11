/// 消息（悄悄话）页 · 段三：长按操作菜单（1.02 微放大就近展开）/ 引用块跳转高亮 /
/// 置顶栏 / 位置与歌卡 / 页内搜索 / 聊天背景（沉浸式）与气泡皮肤（九宫格）。
/// 对照 Web（chat.js/app.js）：置顶栏「📌 置顶 + 摘要 slice42 + 共 N 条」；引用
/// slice60 可点跳回+flash 1.4s；长按菜单项「复制/引用/置顶/记入时光/撤回（仅本人
/// 2 分钟内）」；位置卡「位置 · 点开用高德地图看」；歌卡封面+试听；搜索只筛最近
/// 加载窗口；背景每人一份（chat_bg_users）+ dim 0–80；皮肤九宫格 slice 42。
library;

import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, SystemUiOverlayStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/chat/chat_bubbles.dart';
import '../../core/chat/chat_media.dart';
import '../../core/chat/chat_models.dart';
import '../../core/chat/chat_state.dart';
import '../../core/chat/chat_time.dart';
import '../../core/chat/chat_wallpaper.dart';
import '../../core/sse/sse_client.dart';
import '../auth/auth_state.dart';
import '../home/home_page.dart' show todayStr;
import 'bubble_skin_sheet.dart';
import 'chat_compose.dart';
import 'media_bubble_widgets.dart';
import 'wallpaper_sheet.dart';

class MessagesPage extends ConsumerStatefulWidget {
  const MessagesPage({super.key});

  @override
  ConsumerState<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends ConsumerState<MessagesPage> {
  AppLifecycleListener? _lifecycle;
  // 页面在栈标志的 notifier 提前捕获：dispose 时 ref 已不可用
  //（unmount 后 ref.read 抛 StateError——复验排查中实证）
  StateController<bool>? _pageActive;
  final _replyNotifier = ValueNotifier<(String, String)?>(null);
  final _rowKeys = <String, GlobalKey>{};
  final _searchCtrl = TextEditingController();
  bool _searchOpen = false;
  String _flashId = '';
  int _flashTick = 0;
  String? _pressedId; // 长按菜单打开中的记录 id（气泡 1.02 微放大）

  @override
  void initState() {
    super.initState();
    // 页面在栈标志：SSE chat 事件只在页面未打开时才去刷 me 更新角标。
    // 微任务包裹：initState 里同步改 provider 会触发 riverpod 的
    // 「Tried to modify a provider while the widget tree was building」断言
    _pageActive = ref.read(chatPageActiveProvider.notifier);
    Future.microtask(() => _pageActive?.state = true);
    Future.microtask(() async {
      final me = ref.read(authProvider.notifier).me;
      final controller = ref.read(chatControllerProvider.notifier);
      // 进页初始化：缓存秒出 → 首屏对账 → 清未读（Web navigate('messages') 行为）
      await controller.bootstrap(me?.user.id ?? '');
      await controller.markRead();
    });
    // 回前台补拉：后台期间 SSE 已断开（SseClient 负责重连），先对账一次
    _lifecycle = AppLifecycleListener(onResume: () {
      ref.read(chatControllerProvider.notifier).reconcile();
    });
  }

  @override
  void dispose() {
    _pageActive?.state = false;
    _lifecycle?.dispose();
    _replyNotifier.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  GlobalKey _keyFor(String id) =>
      _rowKeys.putIfAbsent(id, () => GlobalKey(debugLabel: 'chat-row-$id'));

  /// 跳回原消息 + 高亮闪烁 1.4s（对齐 Web chat-jump：滚动居中 + flash）
  void _jumpTo(String id) {
    final ctx = _keyFor(id).currentContext;
    if (ctx == null) {
      _snack('这条消息不在最近加载的范围里');
      return;
    }
    Scrollable.ensureVisible(ctx,
        duration: const Duration(milliseconds: 300), alignment: 0.5);
    setState(() {
      _flashId = id;
      _flashTick++;
    });
  }

  Future<void> _retry(String clientId) async {
    try {
      await ref.read(chatControllerProvider.notifier).retry(clientId);
    } catch (e) {
      if (mounted) _snack(errorDetail(e));
    }
  }

  // ── 长按操作菜单（附录 B：气泡 1.02 微放大 + 就近展开）────────────────

  Future<void> _showActions(
      BuildContext rowContext, ChatRecord record, bool mine) async {
    final me = ref.read(authProvider.notifier).me;
    if (me == null) return;
    final ro = rowContext.findRenderObject();
    final box = ro is RenderBox ? ro : null;
    final overlayRo = Overlay.of(context).context.findRenderObject();
    final overlay = overlayRo is RenderBox ? overlayRo : null;
    if (box == null || overlay == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;
    setState(() => _pressedId = record.id);
    final action = await showMenu<String>(
      context: context,
      // 就近展开：气泡下方（超出屏幕时由 showMenu 自适应）
      position: RelativeRect.fromLTRB(
          pos.dx.clamp(0.0, overlay.size.width - 8),
          pos.dy + size.height,
          (overlay.size.width - pos.dx - size.width).clamp(0.0, overlay.size.width - 8),
          0),
      items: [
        const PopupMenuItem(value: 'copy', height: 40, child: Text('复制')),
        const PopupMenuItem(value: 'reply', height: 40, child: Text('引用')),
        PopupMenuItem(
            value: 'pin',
            height: 40,
            child: Text(record.body.pinned ? '取消置顶' : '置顶')),
        const PopupMenuItem(value: 'moment', height: 40, child: Text('记入时光')),
        // 撤回仅本人且 2 分钟窗口内显示（对齐 Web ops；服务端同口径校验）
        if (canRecallChat(record, me.user.id))
          const PopupMenuItem(value: 'recall', height: 40, child: Text('撤回')),
      ],
    );
    if (mounted) setState(() => _pressedId = null);
    switch (action) {
      case 'copy':
        final text = record.body.content;
        if (text.isNotEmpty) {
          await Clipboard.setData(ClipboardData(text: text));
          _snack('已复制');
        }
      case 'reply':
        _replyNotifier.value = (record.id, record.body.content);
      case 'pin':
        try {
          await ref.read(chatControllerProvider.notifier).pinMessage(record.id);
        } catch (e) {
          _snack(errorDetail(e));
        }
      case 'moment':
        await _sendToMoment(record);
      case 'recall':
        await _confirmRecall(record);
    }
  }

  /// 记入时光（主人定版=最小发布弹窗）：预填消息文本可编辑 + 沿用媒体
  Future<void> _sendToMoment(ChatRecord record) async {
    final ctrl = TextEditingController(text: record.body.content);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('记入时光'),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          maxLength: 2000,
          decoration: const InputDecoration(
              hintText: '这一刻想说点什么（可编辑）', counterText: ''),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('发布')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(chatControllerProvider.notifier).sendToMoment(
            ctrl.text.trim(),
            todayStr(),
            record.body.mediaIds,
          );
      _snack('这一刻，已经好好收藏');
    } catch (e) {
      _snack(errorDetail(e));
    }
  }

  /// 撤回确认（对齐 Web confirmAction：'撤回这条悄悄话？'/'撤回后双方都不会再看到这条消息。'）
  Future<void> _confirmRecall(ChatRecord record) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤回这条悄悄话？'),
        content: const Text('撤回后双方都不会再看到这条消息。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('再想想')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(chatControllerProvider.notifier).recallMessage(record.id);
      _snack('已撤回');
    } catch (e) {
      _snack(errorDetail(e));
    }
  }

  /// 页内搜索过滤（对齐 Web openSearchPanel('chat')：只筛已加载的最近消息，
  /// 不做全量；recalled 排除；content/reply_to.text 大小写不敏感）
  bool _matches(ChatRecord r, String q) {
    if (r.body.recalled) return false;
    final low = q.toLowerCase();
    return r.body.content.toLowerCase().contains(low) ||
        (r.body.replyToText ?? '').toLowerCase().contains(low);
  }

  @override
  Widget build(BuildContext context) {
    // SSE chat 事件 → 对账重拉（按 id 原地合并，不整列表重建）。
    ref.listen(sseEventsProvider, (prev, next) {
      final ev = next.value;
      if (ev?.chat == true) {
        ref.read(chatControllerProvider.notifier).reconcile();
      } else if (ev?.other == true || ev?.refresh == true) {
        // 背景/皮肤在对端变更：me 重拉后 bump 本地时钟刷新排版
        ref
            .read(authProvider.notifier)
            .reload()
            .then((_) => ref.read(chatUiTickProvider.notifier).state++);
      }
    });
    final me = ref.watch(authProvider.notifier).me;
    ref.watch(chatUiTickProvider); // 背景皮肤本地即时生效
    final chat = ref.watch(chatControllerProvider);
    if (me == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final partner = me.users.where((u) => u.id != me.user.id).firstOrNull;
    final wp = chatBgOf(me.spaceRaw, me.user.id);
    final skin = ChatSkin.fromSpace(me.spaceRaw);
    final immersive = wp.isPhoto;

    return Scaffold(
      backgroundColor: immersive ? Colors.black : null,
      appBar: AppBar(
        titleSpacing: 0,
        backgroundColor: immersive ? Colors.black54 : null,
        foregroundColor: immersive ? Colors.white : null,
        // 状态栏图标亮度随顶栏明暗联动（沉浸式顶栏为深色 → 白图标）
        systemOverlayStyle: immersive
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        // 二级页通则：automaticallyImplyLeading 不关，自动返回箭头 + 手势都回上一页
        title: Row(children: [
          const SizedBox(width: 4),
          partner == null
              ? CircleAvatar(
                  radius: 18,
                  backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                  child: Text('♡',
                      style: TextStyle(
                          fontSize: 16,
                          color: Theme.of(context).colorScheme.onPrimaryContainer)))
              : _ChatAvatar(user: partner, size: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(partner?.name ?? '等待另一半加入',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall),
                Text('我们的悄悄话 · 仅彼此可见',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(
                            color: immersive
                                ? Colors.white70
                                : Theme.of(context).colorScheme.outline)),
              ],
            ),
          ),
          IconButton(
            tooltip: '聊天气泡',
            onPressed: () => showBubbleSkinSheet(context),
            icon: const Icon(Icons.format_paint_rounded),
          ),
          IconButton(
            tooltip: '聊天背景',
            onPressed: () => showWallpaperSheet(context),
            icon: const Icon(Icons.wallpaper_rounded),
          ),
          IconButton(
            tooltip: '搜索',
            onPressed: () => setState(() { _searchOpen = true; _searchCtrl.clear(); }),
            icon: const Icon(Icons.search_rounded),
          ),
          const SizedBox(width: 4),
        ]),
      ),
      body: Stack(children: [
        // 背景层：整屏铺（头部/输入栏压图上，像聊天 App 那样——对齐 Web 挂 .chat-panel）
        if (wp.isPhoto && ref.watch(chatBaseProvider).valueOrNull != null)
          Positioned.fill(
            child: CachedNetworkImage(
              imageUrl: mediaUrl(ref.watch(chatBaseProvider).valueOrNull!, wp.media),
              httpHeaders: ref.watch(mediaCookieHeadersProvider).valueOrNull,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => const SizedBox(),
            ),
          )
        else if (wp.hasWallpaper)
          Positioned.fill(child: Container(color: _presetColor(wp.bg))),
        if (wp.isPhoto)
          // dim 遮罩：0–80%，只为一件事——气泡文字在任何底图上都读得清
          Positioned.fill(
            child: Container(
                color: Colors.black.withValues(alpha: wp.dim.clamp(0, 80) / 100)),
          ),
        Column(children: [
          if (_searchOpen) _buildSearchBar(immersive),
          _buildPinnedBar(chat, immersive),
          Expanded(child: _buildList(context, me, chat, skin, immersive)),
          ChatCompose(
            immersive: immersive,
            replyNotifier: _replyNotifier,
            onOpenSearch: () => setState(() {
              _searchOpen = true;
              _searchCtrl.clear();
            }),
            onOpenWallpaper: () => showWallpaperSheet(context),
          ),
        ]),
      ]),
    );
  }

  /// 预设背景底色（浅色渐变的近似主色；photo 走图片层不走这里）
  Color _presetColor(String bg) {
    switch (bg) {
      case 'sakura':
        return const Color(0xFFFFE4EC);
      case 'cream':
        return const Color(0xFFFFF3DC);
      case 'mint':
        return const Color(0xFFDFF5EA);
      case 'stars':
      case 'night':
        return const Color(0xFF1D2036);
      default:
        return Colors.transparent;
    }
  }

  /// 搜索栏（带清空；placeholder 对齐 Web「搜索最近的消息…」）
  Widget _buildSearchBar(bool immersive) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface.withValues(alpha: immersive ? 0.85 : 1),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _searchCtrl,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: '搜索最近的消息…',
              prefixIcon: Icon(Icons.search_rounded),
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
            ),
          ),
        ),
        IconButton(
          tooltip: '关闭搜索',
          onPressed: () => setState(() {
            // 清空搜索词并收起搜索栏，恢复完整列表（真机缺陷 3：此前只清文本）
            _searchOpen = false;
            _searchCtrl.clear();
          }),
          icon: const Icon(Icons.close_rounded),
        ),
      ]),
    );
  }

  /// 置顶栏：最新一条 + 总数（对齐 Web pinnedBar；点开跳过去）
  Widget _buildPinnedBar(ChatState chat, bool immersive) {
    final records =
        chat.rows.whereType<ChatRecordRow>().map((r) => r.record).toList();
    final pinned = pinnedBarInfo(records);
    if (pinned == null) return const SizedBox();
    final theme = Theme.of(context);
    return SafeArea(
      bottom: false,
      child: InkWell(
        onTap: () => _jumpTo(pinned.latest.id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: immersive ? 0.8 : 0.6),
          child: Row(children: [
            Text('📌 置顶', style: theme.textTheme.labelMedium),
            const SizedBox(width: 8),
            Expanded(
              child: Text(pinnedBarText(pinned.latest),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall),
            ),
            if (pinned.total > 1)
              Text('共 ${pinned.total} 条',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
          ]),
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context, MeData me, ChatState chat,
      ChatSkin skin, bool immersive) {
    final q = _searchCtrl.text.trim();
    final rows = q.isEmpty
        ? chat.rows
        : chat.rows
            .where((row) => row is ChatPendingRow || _matches((row as ChatRecordRow).record, q))
            .toList();
    if (rows.isEmpty) {
      // 空态（对齐 Web empty('今天，有什么想对 TA 说？','说说日常，也说说想念。')）
      final theme = Theme.of(context);
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.favorite_border_rounded, size: 44, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text('今天，有什么想对 TA 说？', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text('说说日常，也说说想念。',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
        ]),
      );
    }

    // 展示行：记录行前按 chatTimeLabel 插时间分隔条（对齐 Web chatRows 语义）
    final items = <_ChatItem>[];
    double? lastTs;
    for (final row in rows) {
      switch (row) {
        case ChatRecordRow(:final record):
          final label = chatTimeLabel(record.created, lastTs);
          lastTs = record.created;
          if (label != null) items.add(_DividerItem(label));
          items.add(_RecordItem(record, mine: record.author == me.user.id));
        case ChatPendingRow():
          items.add(_PendingItem(row));
      }
    }

    final count = items.length + (chat.loadingOlder ? 1 : 0);
    return ListView.builder(
      // reverse：底端=最新 → 新消息自动贴底跟随；上翻翻历史不打扰（位置不跳）
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: count,
      itemBuilder: (context, i) {
        if (i >= items.length) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(
                child: SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        // 接近列表顶部（最老一端）预拉更早历史（对齐 Web 无限滚动思路）
        if (chat.hasMoreHistory && !chat.loadingOlder && i >= items.length - 8) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) ref.read(chatControllerProvider.notifier).loadOlder();
          });
        }
        final item = items[items.length - 1 - i];
        final theme = Theme.of(context);
        return switch (item) {
          _DividerItem(:final label) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                  child: Text(label,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: immersive ? Colors.white60 : theme.colorScheme.outline))),
            ),
          _RecordItem(:final record, :final mine) => KeyedSubtree(
              key: _keyFor(record.id),
              child: record.body.recalled
                  ? _RecallLine(mine: mine, immersive: immersive)
                  : _BubbleRow(
                      me: me,
                      record: record,
                      mine: mine,
                      skin: skin,
                      immersive: immersive,
                      pressed: _pressedId == record.id,
                      flashTick: _flashId == record.id ? _flashTick : 0,
                      onLongPress: () {
                        // 必须传「行级」context：itemBuilder 的 context 的
                        // renderObject 是 RenderSliverList（非 RenderBox），
                        // 直接 as RenderBox 会 TypeError 炸掉整个长按链路
                        // （菜单不弹/缩放不动/撤回入口全失效——复验缺陷 2/3 共同根因）
                        final rowCtx = _keyFor(record.id).currentContext;
                        if (rowCtx != null) _showActions(rowCtx, record, mine);
                      },
                      onJump: _jumpTo,
                    ),
            ),
          _PendingItem(:final row) =>
            _PendingBubbleRow(row: row, onRetry: () => _retry(row.clientId)),
        };
      },
    );
  }
}

// ── 展示行模型 ──────────────────────────────────────────────────────

sealed class _ChatItem {
  const _ChatItem();
}

class _DividerItem extends _ChatItem {
  const _DividerItem(this.label);
  final String label;
}

class _RecordItem extends _ChatItem {
  const _RecordItem(this.record, {required this.mine});
  final ChatRecord record;
  final bool mine;
}

class _PendingItem extends _ChatItem {
  const _PendingItem(this.row);
  final ChatPendingRow row;
}

// ── 行组件 ─────────────────────────────────────────────────────────

/// 撤回态行：「你/对方撤回了一条消息」（对齐 Web chat-recall）
class _RecallLine extends StatelessWidget {
  const _RecallLine({required this.mine, this.immersive = false});
  final bool mine;
  final bool immersive;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Text('${mine ? '你' : '对方'}撤回了一条消息',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: immersive
                    ? Colors.white60
                    : Theme.of(context).colorScheme.outline)),
      ),
    );
  }
}

/// 引用块（段三：点击跳回原消息+高亮；对齐 Web chat-quote，文本 slice60 由
/// quoteSnippet 保证存储端截断，展示端同样截断）
class _QuoteBlock extends StatelessWidget {
  const _QuoteBlock({required this.quote, required this.onJump});
  final (String, String) quote;
  final VoidCallback onJump;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onJump,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(6),
          border: Border(
              left: BorderSide(width: 3, color: theme.colorScheme.primary)),
        ),
        child: Text('↩ ${quoteSnippet(quote.$2)}',
            maxLines: 2, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline)),
      ),
    );
  }
}

/// 消息行（段三）：气泡支持皮肤九宫格/长按 1.02 微放大/引用块/位置与歌卡
class _BubbleRow extends ConsumerWidget {
  const _BubbleRow({
    required this.me,
    required this.record,
    required this.mine,
    required this.skin,
    required this.immersive,
    required this.pressed,
    required this.flashTick,
    required this.onLongPress,
    required this.onJump,
  });
  final MeData me;
  final ChatRecord record;
  final bool mine;
  final ChatSkin skin;
  final bool immersive;
  final bool pressed;
  final int flashTick; // >0 表示本行正在闪烁（值变化触发动画）
  final VoidCallback onLongPress;
  final void Function(String id) onJump; // 引用块跳回原消息+高亮

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final visual = chatVisualOf(record);
    final author = mine
        ? me.user
        : (me.byId(record.author) ??
            SpaceUser(id: record.author, name: '?', username: ''));
    final base = ref.watch(chatBaseProvider).valueOrNull;

    // 贴纸：整条无气泡（对齐 Web chat-sticker），按分侧对齐
    if (visual.sticker != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Row(
          mainAxisAlignment:
              mine ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (mine) ...[
              StickerView(sticker: visual.sticker!),
              const SizedBox(width: 6),
              _ChatAvatar(user: author, size: 34),
            ] else ...[
              _ChatAvatar(user: author, size: 34),
              const SizedBox(width: 6),
              StickerView(sticker: visual.sticker!),
            ],
          ],
        ),
      );
    }

    // 皮肤九宫格（对齐 Web border-image slice 42 fill / 16px）：
    // 左=对方图，右=我的图；swap 由 ChatSkin.leftRightUrls 对调
    final useSkin = skin.enabled && base != null;
    final (leftSkin, rightSkin) = skin.leftRightUrls;
    final skinName = mine ? rightSkin : leftSkin;
    final lightText = skin.fg == 'light';

    // 歌卡 / 位置卡：整条卡片渲染（对齐 Web songCard/locCard 分支）
    Widget? card;
    if (visual.song != null) card = SongCardView(song: visual.song!);
    if (visual.location != null) {
      card = LocationCardView(location: visual.location!);
    }

    final bubble = _FlashWrapper(
      flashTick: flashTick,
      child: AnimatedScale(
        scale: pressed ? 1.02 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: useSkin
              ? const EdgeInsets.symmetric(horizontal: 14, vertical: 8)
              : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: useSkin
              ? BoxDecoration(
                  image: DecorationImage(
                    image: NetworkImage(bubbleSkinUrl(base, skinName)),
                    centerSlice: const Rect.fromLTWH(42, 42, 44, 28),
                  ),
                )
              : BoxDecoration(
                  color: mine
                      ? theme.colorScheme.primaryContainer.withValues(alpha: 0.6)
                      : theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: immersive ? 0.85 : 0.6),
                  boxShadow: pressed
                      ? [BoxShadow(
                          blurRadius: 8,
                          color: theme.colorScheme.shadow.withValues(alpha: 0.3))]
                      : null,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(mine ? 16 : 4),
                    bottomRight: Radius.circular(mine ? 4 : 16),
                  ),
                ),
          child: Column(
            crossAxisAlignment:
                mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (visual.quote != null)
                _QuoteBlock(
                    quote: visual.quote!,
                    onJump: () => onJump(visual.quote!.$1)),
              ?card,
              for (final line in visual.textLines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(line,
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: useSkin && lightText ? Colors.white : null)),
                ),
              if (visual.imageMids.length == 1)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: MediaImageView(mid: visual.imageMids.first),
                )
              else if (visual.imageMids.length > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final mid in visual.imageMids)
                          MediaImageView(mid: mid, size: 96)
                      ]),
                ),
              if (visual.videoMids.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                      spacing: 4,
                      children: [
                        for (final mid in visual.videoMids)
                          VideoCardView(mid: mid, size: 180)
                      ]),
                ),
              if (visual.voiceMids.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                      spacing: 4,
                      children: [
                        for (final mid in visual.voiceMids) VoiceChipView(mid: mid)
                      ]),
                ),
            ],
          ),
        ),
      ),
    );
    final avatar = _ChatAvatar(user: author, size: 34);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: GestureDetector(
        onLongPress: onLongPress,
        behavior: HitTestBehavior.opaque, // 整行热区，防内层透明区域吞长按
        child: Row(
          mainAxisAlignment:
              mine ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: mine
              ? [Flexible(child: bubble), const SizedBox(width: 6), avatar]
              : [avatar, const SizedBox(width: 6), Flexible(child: bubble)],
        ),
      ),
    );
  }
}

/// 高亮闪烁包装（对齐 Web @keyframes chatFlash：1.4s，20%/60% 处最亮）
class _FlashWrapper extends StatefulWidget {
  const _FlashWrapper({required this.flashTick, required this.child});
  final int flashTick;
  final Widget child;

  @override
  State<_FlashWrapper> createState() => _FlashWrapperState();
}

class _FlashWrapperState extends State<_FlashWrapper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400));
  late final Animation<double> _a = TweenSequence<double>([
    TweenSequenceItem(
        tween: Tween<double>(begin: 0, end: 1)
            .chain(CurveTween(curve: const Interval(0, 0.2, curve: Curves.easeOut))),
        weight: 20),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 40),
    TweenSequenceItem(
        tween: Tween<double>(begin: 1, end: 0)
            .chain(CurveTween(curve: const Interval(0.6, 1, curve: Curves.easeIn))),
        weight: 40),
  ]).animate(_c);

  @override
  void didUpdateWidget(_FlashWrapper old) {
    super.didUpdateWidget(old);
    if (widget.flashTick > 0 && widget.flashTick != old.flashTick) {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 高亮底色用 DecoratedBox（不能 Container 负 margin 外扩：margin 非负断言
    // 会炸掉整行构建——段三复验缺陷 3 根因）
    return AnimatedBuilder(
      animation: _a,
      builder: (context, child) {
        final t = _c.isAnimating ? _a.value : 0.0;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: t > 0
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.9 * t)
                : null,
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// 待发行：上传中=进度百分比；发送中=三点跳动动效；失败=标红「未发出」+「点击重试」
class _PendingBubbleRow extends StatelessWidget {
  const _PendingBubbleRow({required this.row, required this.onRetry});
  final ChatPendingRow row;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summaryLines = <String>[
      if (row.content.isNotEmpty) row.content,
      if (row.mediaFiles.isNotEmpty) '[附件] ${row.mediaFiles.length} 个',
    ];
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(4),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
        for (final line in summaryLines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Text(line, style: theme.textTheme.bodyMedium),
          ),
      ]),
    );
    final Widget status;
    if (row.failed) {
      status = Row(mainAxisSize: MainAxisSize.min, children: [
        Text('未发出',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error)),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: onRetry,
          child: Text('点击重试',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.primary)),
        ),
      ]);
    } else if (row.isUploading) {
      status = Text('上传中 ${(row.progress * 100).clamp(0, 100).round()}%',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline));
    } else {
      status = const _SendingDots();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            Flexible(child: bubble),
          ]),
          const SizedBox(height: 2),
          status,
        ],
      ),
    );
  }
}

/// 三点跳动（发送中动效，等价 Web .snd-dots）
class _SendingDots extends StatefulWidget {
  const _SendingDots();

  @override
  State<_SendingDots> createState() => _SendingDotsState();
}

class _SendingDotsState extends State<_SendingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < 3; i++)
        AnimatedBuilder(
          animation: _c,
          builder: (_, _) {
            // 三个点相位错开 1/3：呼吸式明暗（% 保证负数也能取相位）
            final t = (_c.value * 3 - i) % 1;
            final o = 0.25 + 0.6 * (1 - (2 * t - 1).abs());
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Container(
                width: 6,
                height: 6,
                decoration:
                    BoxDecoration(color: color.withValues(alpha: o), shape: BoxShape.circle),
              ),
            );
          },
        ),
    ]);
  }
}

/// 头像（对齐 Web avatar()：有图走共享 dio 带 Cookie 取字节，无图显昵称首字）
class _ChatAvatar extends ConsumerStatefulWidget {
  const _ChatAvatar({required this.user, this.size = 34});
  final SpaceUser user;
  final double size;

  @override
  ConsumerState<_ChatAvatar> createState() => _ChatAvatarState();
}

class _ChatAvatarState extends ConsumerState<_ChatAvatar> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = widget.user.avatar;
    if (id.isEmpty) return;
    try {
      final dio = await ref.read(dioProvider.future);
      final bytes = await fetchMediaBytes(dio, id);
      if (mounted) setState(() => _bytes = Uint8List.fromList(bytes));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = widget.size;
    if (_bytes != null) {
      return ClipOval(
        child: Image.memory(_bytes!,
            width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true),
      );
    }
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: theme.colorScheme.primaryContainer,
      child: Text(
        widget.user.name.isEmpty ? '?' : widget.user.name.characters.first,
        style: TextStyle(
            fontSize: size * 0.38, color: theme.colorScheme.onPrimaryContainer),
      ),
    );
  }
}
