/// 消息（悄悄话）页 · 段一：文本消息 + 撤回态 + 时间分隔条 + 发送三态 + SSE 对账。
/// 对照 Web（static/chat.js）：头部「昵称 / 我们的悄悄话 · 仅彼此可见」；空态
/// 「今天，有什么想对 TA 说？/ 说说日常，也说说想念。」；撤回行「你/对方撤回了一条消息」；
/// 发送中三点动效 / 失败标红「未发出 · 点击重试」（重试复用同一 client_id）。
/// 段一渲染边界：媒体/贴纸/歌曲/位置/引用渲染中性占位（chat_models.placeholderLines），
/// 绝不能崩；完整渲染在段二/段三。pinned 段一忽略（置顶栏属段三）。
/// 列表用 reverse ListView：底端=最新，天然贴底跟随、上翻预拉不跳位置。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/chat/chat_models.dart';
import '../../core/chat/chat_state.dart';
import '../../core/chat/chat_time.dart';
import '../../core/sse/sse_client.dart';
import '../auth/auth_state.dart';

class MessagesPage extends ConsumerStatefulWidget {
  const MessagesPage({super.key});

  @override
  ConsumerState<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends ConsumerState<MessagesPage> {
  final _input = TextEditingController();
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    // 页面在栈标志：SSE chat 事件只在页面未打开时才去刷 me 更新角标
    ref.read(chatPageActiveProvider.notifier).state = true;
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
    ref.read(chatPageActiveProvider.notifier).state = false;
    _lifecycle?.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    try {
      await ref.read(chatControllerProvider.notifier).send(text);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(errorDetail(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // SSE chat 事件 → 对账重拉（按 id 原地合并，不整列表重建）。
    // 流是全局的，监听随页面生命周期自动挂摘，不会重复累积。
    ref.listen(sseEventsProvider, (prev, next) {
      if (next.value?.chat == true) {
        ref.read(chatControllerProvider.notifier).reconcile();
      }
    });
    final me = ref.watch(authProvider.notifier).me;
    final chat = ref.watch(chatControllerProvider);
    if (me == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final partner = me.users.where((u) => u.id != me.user.id).firstOrNull;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
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
                        ?.copyWith(color: Theme.of(context).colorScheme.outline)),
              ],
            ),
          ),
          const SizedBox(width: 16),
        ]),
      ),
      body: Column(children: [
        Expanded(child: _buildList(context, me, chat)),
        _buildInputBar(context),
      ]),
    );
  }

  Widget _buildList(BuildContext context, MeData me, ChatState chat) {
    if (chat.rows.isEmpty) {
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
    for (final row in chat.rows) {
      switch (row) {
        case ChatRecordRow(:final record):
          final label = chatTimeLabel(record.created, lastTs);
          lastTs = record.created;
          if (label != null) items.add(_DividerItem(label));
          items.add(_RecordItem(record, mine: record.author == me.user.id));
        case ChatPendingRow(:final clientId, :final content, :final failed):
          items.add(_PendingItem(clientId, content, failed));
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
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline))),
            ),
          _RecordItem(:final record, :final mine) => record.body.recalled
              ? _RecallLine(mine: mine)
              : _BubbleRow(me: me, record: record, mine: mine),
          _PendingItem(:final clientId, :final content, :final failed) =>
            _PendingBubbleRow(
                content: content, failed: failed,
                onRetry: () => ref
                    .read(chatControllerProvider.notifier)
                    .retry(clientId)),
        };
      },
    );
  }

  Widget _buildInputBar(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              // placeholder 对齐 Web composeBar：placeholder="发消息"
              decoration: InputDecoration(
                hintText: '发消息',
                isDense: true,
                filled: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: _send,
            icon: const Icon(Icons.send_rounded, size: 20),
          ),
        ]),
      ),
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
  const _PendingItem(this.clientId, this.content, this.failed);
  final String clientId;
  final String content;
  final bool failed;
}

// ── 行组件 ─────────────────────────────────────────────────────────

/// 撤回态行：「你/对方撤回了一条消息」（对齐 Web chat-recall）
class _RecallLine extends StatelessWidget {
  const _RecallLine({required this.mine});
  final bool mine;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Text('${mine ? '你' : '对方'}撤回了一条消息',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.outline)),
      ),
    );
  }
}

/// 消息行：文本气泡（我/对方左右分侧 + 头像，头像规则对齐 Web avatar()：
/// 无图显昵称首字，有图走共享 dio 带 Cookie 取字节——账号页同款模式）
class _BubbleRow extends ConsumerWidget {
  const _BubbleRow({required this.me, required this.record, required this.mine});
  final MeData me;
  final ChatRecord record;
  final bool mine;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final lines = record.placeholderLines();
    final author = mine
        ? me.user
        : (me.byId(record.author) ??
            SpaceUser(id: record.author, name: '?', username: ''));
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: mine
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.6)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
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
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text(line, style: theme.textTheme.bodyMedium),
            ),
        ],
      ),
    );
    final avatar = _ChatAvatar(user: author, size: 34);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Row(
        mainAxisAlignment:
            mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: mine
            ? [Flexible(child: bubble), const SizedBox(width: 6), avatar]
            : [avatar, const SizedBox(width: 6), Flexible(child: bubble)],
      ),
    );
  }
}

/// 待发行：发送中=三点跳动动效；失败=标红「未发出」+「点击重试」
/// （对齐 Web snd-dots / snd-fail 语义，附录 B·发送三态）
class _PendingBubbleRow extends StatelessWidget {
  const _PendingBubbleRow({
    required this.content,
    required this.failed,
    required this.onRetry,
  });
  final String content;
  final bool failed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
      child: Text(content, style: theme.textTheme.bodyMedium),
    );
    final status = failed
        ? Row(mainAxisSize: MainAxisSize.min, children: [
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
          ])
        : const _SendingDots();
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

/// 头像（对齐 Web avatar()：有图走共享 dio 带 Cookie 取字节，无图显昵称首字；
/// 与账号页 _Avatar 同款模式，失败静默回退首字）
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
