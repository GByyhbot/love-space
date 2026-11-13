/// 消息（悄悄话）页 · 段三：长按操作菜单（1.02 微放大就近展开）/ 引用块跳转高亮 /
/// 置顶栏 / 位置与歌卡 / 页内搜索 / 聊天背景（沉浸式）与气泡皮肤（九宫格）。
/// 对照 Web（chat.js/app.js）：置顶栏「📌 置顶 + 摘要 slice42 + 共 N 条」；引用
/// slice60 可点跳回+flash 1.4s；长按菜单项「复制/引用/置顶/记入时光/撤回（仅本人
/// 2 分钟内）」；位置卡「位置 · 点开用高德地图看」；歌卡封面+试听；搜索只筛最近
/// 加载窗口；背景每人一份（chat_bg_users）+ dim 0–80；皮肤九宫格 slice 42。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/cache/low_freq_cache.dart';
import '../../core/chat/chat_bubbles.dart';
import '../../core/chat/chat_chrome.dart';
import '../../core/chat/chat_media.dart';
import '../../core/chat/chat_models.dart';
import '../../core/chat/chat_state.dart';
import '../../core/chat/chat_time.dart';
import '../../core/chat/chat_wallpaper.dart';
import '../../core/sse/sse_client.dart';
import '../auth/auth_state.dart';
import '../timeline/composer_sheet.dart' show showComposerSheet;
import 'bubble_skin_sheet.dart';
import 'chat_compose.dart';
import 'chat_toast.dart';
import 'chat_wallpaper_frame.dart';
import 'media_bubble_widgets.dart';
import 'skin_bubble.dart';
import 'voice_playback.dart';
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

  /// 语音播放控制器引用（initState 提前捕获：dispose 时 ref 已不可用），
  /// 离开聊天页停止复位在播语音。
  VoicePlaybackController? _voicePlaybackCtrl;

  @override
  void initState() {
    super.initState();
    _voicePlaybackCtrl = ref.read(voicePlaybackProvider.notifier);
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
    // 离开聊天页：在播语音停止复位（全局播放互斥收口）
    // ignore: unawaited_futures
    _voicePlaybackCtrl?.stop();
    super.dispose();
  }

  /// 统一走顶部提示层：底部 SnackBar 会盖住输入栏按钮（真机复验缺陷）。
  void _snack(String msg, {ChatToastTone tone = ChatToastTone.info}) {
    if (mounted) {
      ref.read(chatToastProvider.notifier).show(msg, tone: tone);
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
    final theme = Theme.of(context);
    // 菜单配色与聊天页同体系（surface 容器圆角卡片 + 主题色图标）
    final menuColor = theme.colorScheme.surfaceContainerHighest;
    final itemIconColor = theme.colorScheme.primary;
    PopupMenuItem<String> item(String value, IconData icon, String label,
            {Color? danger}) =>
        PopupMenuItem(
          value: value,
          height: 44,
          child: Row(children: [
            Icon(icon, size: 18, color: danger ?? itemIconColor),
            const SizedBox(width: 10),
            Text(label,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: danger ?? theme.colorScheme.onSurface)),
          ]),
        );
    final action = await showMenu<String>(
      context: context,
      // 就近展开：气泡下方（超出屏幕时由 showMenu 自适应）
      position: RelativeRect.fromLTRB(
          pos.dx.clamp(0.0, overlay.size.width - 8),
          pos.dy + size.height,
          (overlay.size.width - pos.dx - size.width).clamp(0.0, overlay.size.width - 8),
          0),
      color: menuColor,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      items: [
        item('copy', Icons.copy_rounded, '复制'),
        item('reply', Icons.reply_rounded, '引用'),
        item('pin', Icons.push_pin_rounded, record.body.pinned ? '取消置顶' : '置顶'),
        item('moment', Icons.auto_stories_rounded, '记入时光'),
        // 撤回仅本人且 2 分钟窗口内显示（对齐 Web ops；服务端同口径校验）
        if (canRecallChat(record, me.user.id))
          item('recall', Icons.undo_rounded, '撤回',
              danger: theme.colorScheme.error),
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
          _snack(errorDetail(e), tone: ChatToastTone.error);
        }
      case 'moment':
        await _sendToMoment(record);
      case 'recall':
        await _confirmRecall(record);
    }
  }

  /// C4 记入时光（主人定版=正式 composer）：段三最小发布弹窗已替换——
  /// 打开与时光页共用的 ComposerSheet（post 态），预填原消息文本并带入
  /// 原消息媒体 id，发布走同一套本地暂存 + client_id 幂等 + 顶部通知逻辑。
  Future<void> _sendToMoment(ChatRecord record) async {
    await showComposerSheet(
      context,
      initialContent: record.body.content,
      initialMediaIds: record.body.mediaIds,
    );
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
      _snack('已撤回', tone: ChatToastTone.success);
    } catch (e) {
      _snack(errorDetail(e), tone: ChatToastTone.error);
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
    // 背景层固定用完整视口高度：Scaffold 在键盘弹出时会压缩 body，
    // 若背景用 Positioned.fill 会跟着收缩并被 BoxFit.cover 重新裁剪，
    // 视觉上就是「点输入框背景往上跑、点工具栏又落回来」。
    final fullHeight = MediaQuery.sizeOf(context).height;
    return Scaffold(
      backgroundColor: immersive ? Colors.black : null,
      appBar: AppBar(
        titleSpacing: 0,
        // 五处外壳同一底色同一透明度（聊天页外壳契约，见 chat_chrome.dart）
        backgroundColor: chatChromeColor(Theme.of(context), immersive: immersive),
        foregroundColor: immersive ? Colors.white : null,
        systemOverlayStyle:
            chatChromeOverlayStyle(Theme.of(context), immersive: immersive),
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
        // 背景层：按完整视口高度固定铺满（头部/输入栏压图上，对齐 Web .chat-panel）。
        // 高度不随 body 压缩变化，键盘弹出/收起时图片位置与裁剪保持不变。
        if (wp.isPhoto && ref.watch(chatBaseProvider).valueOrNull != null) ...[
          ChatWallpaperFrame(
            viewportHeight: fullHeight,
            child: Builder(builder: (context) {
              final base = ref.watch(chatBaseProvider).valueOrNull!;
              final url = mediaUrl(base, wp.media);
              final headers = ref.watch(mediaCookieHeadersProvider).valueOrNull;
              // 低频缓存（item 5）：壁纸落盘 + 槽位删旧留新（URL 含 mid，换图即换键）
              // ignore: discarded_futures
              LowFreqCache.retainLatest('wallpaper:${me.user.id}', url, headers: headers);
              return CachedNetworkImage(
                imageUrl: url,
                httpHeaders: headers,
                cacheManager: LowFreqCacheManager.instance,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => const SizedBox(),
              );
            }),
          ),
        ]
        else if (wp.hasWallpaper)
          ChatWallpaperFrame(
            viewportHeight: fullHeight,
            child: Container(color: _presetColor(wp.bg)),
          ),
        if (wp.isPhoto)
          // dim 遮罩与背景同尺寸同定位，避免键盘收起时下缘露出未遮罩区域
          ChatWallpaperFrame(
            viewportHeight: fullHeight,
            child: Container(
                color: Colors.black.withValues(alpha: wp.dim.clamp(0, 80) / 100)),
          ),
        Column(children: [
          if (_searchOpen) _buildSearchBar(immersive),
          _buildPinnedBar(chat, immersive),
          Expanded(child: _buildList(context, me, chat, skin, immersive)),
          // 录音态把输入栏整体滑出隐藏（对齐微信：录音时底栏消失，
          // 只剩全屏遮罩上的弧形区）；手势已开始，move/up 仍由原
          // GestureDetector 接收，隐藏不中断录音。高度保留，列表不跳动。
          AnimatedSlide(
            offset: ref.watch(chatRecordProvider) != null
                ? const Offset(0, 1.2)
                : Offset.zero,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: ref.watch(chatRecordProvider) != null ? 0 : 1,
              duration: const Duration(milliseconds: 250),
              child: ChatCompose(
                immersive: immersive,
                dark: true,
                replyNotifier: _replyNotifier,
                onOpenSearch: () => setState(() {
                  _searchOpen = true;
                  _searchCtrl.clear();
                }),
                onOpenWallpaper: () => showWallpaperSheet(context),
              ),
            ),
          ),
        ]),
        // 顶部通知由 App 根部全局 ChatToastHost 承载（覆盖弹层/全屏遮罩），
        // 本页不再单独挂宿主，避免同一条通知渲染两遍。
        // 微信式语音输入全屏遮罩（录音态显示，盖住输入栏与消息列表）：
        // topInset = 状态栏 + AppBar 高，供屏高 58.5% 锚点换算到 body 坐标。
        Positioned.fill(
          child: VoiceRecordOverlay(
            topInset: MediaQuery.paddingOf(context).top + kToolbarHeight,
          ),
        ),
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
  const _QuoteBlock({
    required this.quote,
    required this.onJump,
    this.skinned = false,
    this.mine = false,
    this.skinFg,
  });
  final (String, String) quote;
  final VoidCallback onJump;
  final bool skinned;
  final bool mine;
  final Color? skinFg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Web .chat-panel.skin-on .chat-quote（style.css:2538-2540）：
    // 底色跟着气泡走，别再压一层固定黑灰；默认 rgba(0,0,0,.055)，
    // mine 侧 rgba(255,255,255,.16)；color:inherit（=气泡字色）、
    // border-left-color:currentColor、opacity:.9。
    final Color bg;
    final Color border;
    final Color fg;
    if (skinned) {
      bg = mine
          ? Colors.white.withValues(alpha: 0.16)
          : Colors.black.withValues(alpha: 0.055);
      fg = skinFg ?? skinDarkFg;
      border = fg;
    } else {
      bg = theme.colorScheme.surface.withValues(alpha: 0.55);
      fg = theme.colorScheme.outline;
      border = theme.colorScheme.primary;
    }
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onJump,
      child: Opacity(
        opacity: skinned ? 0.9 : 1.0,
        child: Container(
          // 不写死 width:double.infinity——气泡宽度由内容自适应（外层
          // ChatBubbleFrame 的 ConstrainedBox 夹上下限），引用块随正文一起收缩。
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
            border:
                Border(left: BorderSide(width: 3, color: border)),
          ),
          child: Text('↩ ${quoteSnippet(quote.$2)}',
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: fg)),
        ),
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

    // 皮肤九宫格（对齐 Web border-image slice 42 fill / width 16px）：
    // 左=对方图，右=我的图；swap 由 ChatSkin.leftRightUrls 对调。
    // 渲染走 SkinBubble 自绘九宫格：Flutter 的 centerSlice 没有 border-image-width
    // 「42px 源角 → 16px 目标角」的缩放语义，角饰会按原像素绘制而比例失调
    //（皮肤真机取证根因）；SkinBubble 内部按 url 走低频缓存 + Cookie 头。
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

    // 皮肤态字色（Web .skinned 写死 #2B2029 / .skinned.light #fff + 淡投影），
    // 引用块 color:inherit 也取同一个 fg；默认态沿用主题 bodyMedium。
    final bodyStyle = useSkin
        ? skinTextStyle(theme.textTheme.bodyMedium, fgLight: lightText)
        : theme.textTheme.bodyMedium;
    final skinFg = lightText ? skinLightFg : skinDarkFg;

    // 气泡内容（皮肤态 / 默认态共用同一份 child，保证两者宽度口径一致）
    final content = Column(
      crossAxisAlignment:
          mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (visual.quote != null)
          _QuoteBlock(
              quote: visual.quote!,
              onJump: () => onJump(visual.quote!.$1),
              skinned: useSkin,
              mine: mine,
              skinFg: skinFg),
        ?card,
        for (final line in visual.textLines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Text(line, style: bodyStyle),
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
                  for (final mid in visual.voiceMids)
                    VoiceChipView(mid: mid, mine: mine)
                ]),
          ),
      ],
    );

    final bubbleBody = useSkin
        ? SkinBubble(
            url: bubbleSkinUrl(base, skinName),
            fgLight: lightText,
            child: content,
          )
        : AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: mine
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.6)
                  : theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: immersive ? 0.85 : 0.6),
              boxShadow: pressed
                  ? [
                      BoxShadow(
                          blurRadius: 8,
                          color:
                              theme.colorScheme.shadow.withValues(alpha: 0.3))
                    ]
                  : null,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(mine ? 16 : 4),
                bottomRight: Radius.circular(mine ? 4 : 16),
              ),
            ),
            child: content,
          );

    final bubble = _FlashWrapper(
      flashTick: flashTick,
      child: AnimatedScale(
        scale: pressed ? 1.02 : 1.0,
        duration: const Duration(milliseconds: 150),
        // 宽度随聊天内容自适应：Column 在 loose 约束下自身宽度 = 最大子宽，
        // 由 ConstrainedBox 夹到 Web .chat-bubble 的 44px 下限与
        // .chat-line 85%/92% 上限（短消息窄、长文本宽至上限）。
        // 皮肤图由 SkinBubble 的 CustomPaint 跟着这个最终矩形铺开——旧
        // centerSlice 把 42px 源角按原像素画，角饰吃掉大半气泡、正文挤成
        // 窄缝，才是「气泡不随内容扩展」的视觉根因。
        // 不用 IntrinsicWidth：它给子树无界宽，歌卡/位置卡内的 Expanded 会炸。
        child: ChatBubbleFrame(child: bubbleBody),
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
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = widget.size;
    final id = widget.user.avatar;
    // 低频缓存（item 5）：头像走 LowFreqCacheManager 落盘 + 槽位删旧留新
    if (id.isNotEmpty && ref.watch(chatBaseProvider).valueOrNull != null) {
      final base = ref.watch(chatBaseProvider).valueOrNull!;
      final url = mediaUrl(base, id);
      final headers = ref.watch(mediaCookieHeadersProvider).valueOrNull;
      // ignore: discarded_futures
      LowFreqCache.retainLatest('avatar:${widget.user.id}', url, headers: headers);
      return ClipOval(
        child: CachedNetworkImage(
          imageUrl: url,
          httpHeaders: headers,
          cacheManager: LowFreqCacheManager.instance,
          width: size,
          height: size,
          fit: BoxFit.cover,
          placeholder: (_, _) => _fallback(theme, size),
          errorWidget: (_, _, _) => _fallback(theme, size),
        ),
      );
    }
    return _fallback(theme, size);
  }

  Widget _fallback(ThemeData theme, double size) => CircleAvatar(
        radius: size / 2,
        backgroundColor: theme.colorScheme.primaryContainer,
        child: Text(
          widget.user.name.isEmpty ? '?' : widget.user.name.characters.first,
          style: TextStyle(
              fontSize: size * 0.38,
              color: theme.colorScheme.onPrimaryContainer),
        ),
      );
}
