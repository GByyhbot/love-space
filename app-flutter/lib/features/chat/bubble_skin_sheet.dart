/// 气泡皮肤弹层（段三 · Step 9，对齐 Web bubblePicker；2.4.6 改按人）：
/// GET /api/bubbles 分组 tab（第 N 组）+ 网格分批渲染（BP_PAGE=90，滚到底续载）
/// + 预览行（左右两侧各自实际皮肤）+ 字色深/浅 + 作者互换 + 恢复默认。
/// 保存走按人端点 PUT /api/profile 的 bubble_skin/bubble_fg/bubble_swap
/// 三键（yang 2026-11-18 定案「各发各的」+ AskUserQuestion 拍板按人三键）——
/// 只换你发出的气泡，对方的由对方设置；硬性护栏：不得再走 PUT /api/space
/// 写空间字段（空间级 chat_bubble* 仅作渲染回退基底与 Web 数据源）。
/// 文案对照 Web：字色「气泡图有深有浅，按这张图选」；互换「气泡的装饰朝哪边，
/// 看着别扭就勾一下」；空素材「服务器上还没有气泡素材…」；计数「共 N 张 · 这一组 N 张」。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/cache/low_freq_cache.dart';
import '../../core/chat/chat_bubbles.dart';
import '../../core/chat/chat_media.dart';
import '../../core/chat/chat_state.dart';
import '../auth/auth_state.dart';
import '../../core/ui/jelly_switch.dart' show JellySwitch;
import '../../core/ui/submit_morph.dart' show SubmitMorphButton;
import 'chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'skin_bubble.dart';
import '../../core/theme/tokens.dart';

Future<void> showBubbleSkinSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg))),
    builder: (_) => const BubbleSkinSheet(),
  );
}

/// 气泡皮肤面板本体（2.4.0 设置拆分段公开化）：聊天页右上角 sheet 与
/// 设置独立页（chat_bubble_page）共用**同一组件与同一数据源**（GET
/// /api/bubbles 素材 + PUT /api/space 的 chat_bubble* 三键），任何一处
/// 修改另一处即时一致，绝不复制第二套实现。
/// [embedded] = true 时作为设置页内嵌面板：不渲染关闭钮、外层不固定
/// 68% 高（由页面 Scaffold 的有界 body 撑满），其余 UI 与保存链逐位一致。
class BubbleSkinSheet extends ConsumerStatefulWidget {
  const BubbleSkinSheet({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<BubbleSkinSheet> createState() => _BubbleSkinSheetState();
}

class _BubbleSkinSheetState extends ConsumerState<BubbleSkinSheet> {
  List<BubbleGroup> _groups = const [];
  String _pack = '';
  String _pick = '';
  String _fg = 'dark';
  bool _swap = true;
  int _shown = 0; // 本组当前可见数（分批）
  bool _loading = true;
  bool _saving = false;
  final _gridController = ScrollController();

  @override
  void initState() {
    super.initState();
    final me = ref.read(authProvider.notifier).me;
    // 2.4.6 各发各的：面板读写的是「我的」按人皮肤三键（/api/me 的
    // me.user.bubble*）；空间级 chat_bubble* 只作渲染回退基底，不再从
    // 这里写入。fg/swap 初始值：按人未设时回退空间级现值。
    final spaceSkin = ChatSkin.fromSpace(me?.spaceRaw ?? const {});
    final user = me?.user;
    _pick = user?.bubbleSkin ?? '';
    _fg = (user == null || user.bubbleFg.isEmpty) ? spaceSkin.fg : user.bubbleFg;
    _swap = user?.bubbleSwap ?? spaceSkin.swap;
    _pack = _pick.split('/').first;
    _gridController.addListener(_onGridScroll);
    _load();
  }

  @override
  void dispose() {
    _gridController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final dio = await ref.read(dioProvider.future);
      final groups = await fetchBubbleGroups(dio);
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _loading = false;
        if (groups.isNotEmpty) {
          if (!groups.any((g) => g.id == _pack)) _pack = groups.first.id;
          final g = _groups.firstWhere((x) => x.id == _pack);
          _shown = nextBubbleVisible(g.items.length, 0);
        }
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 滚动到底续载（对齐 Web grid.onscroll：距底 180px 内 grow 一批）
  void _onGridScroll() {
    final g = _currentGroup;
    if (g == null || !_gridController.hasClients) return;
    final pos = _gridController.position;
    if (pos.pixels + pos.viewportDimension > pos.maxScrollExtent - 180) {
      final next = nextBubbleVisible(g.items.length, _shown);
      if (next != _shown) setState(() => _shown = next);
    }
  }

  BubbleGroup? get _currentGroup {
    for (final g in _groups) {
      if (g.id == _pack) return g;
    }
    return null;
  }

  void _switchPack(String id) {
    if (id == _pack) return;
    final g = _groups.firstWhere((x) => x.id == id);
    setState(() { _pack = id; _shown = nextBubbleVisible(g.items.length, 0); });
    if (_gridController.hasClients) _gridController.jumpTo(0);
  }

  /// 2.4.6 各发各的：保存走按人端点 PUT /api/profile（服务端强制只能改
  /// 自己，X-Love-Space: 1 由 dio 拦截器统一附加）；name/avatar 必填取现值。
  /// [clear]=true：bubble_skin 传空串，服务端把三键整体清空（恢复未设置，
  /// 渲染回退空间级）；硬性护栏：不得再走 PUT /api/space 写空间字段。
  // 2.4.10：改返 Future<bool> 供三连变驱动（pop 归 onSuccess；clear 路径
  // 走普通按钮不经 morph——恢复未设置是低风险操作，无需三连）。
  Future<bool> _save(ChatSkin skin, {bool clear = false}) async {
    if (_saving) return false;
    final me = ref.read(authProvider.notifier).me;
    if (me == null) return false;
    setState(() => _saving = true);
    try {
      final dio = await ref.read(dioProvider.future);
      final r = await dio.put('/api/profile', data: {
        'name': me.user.name,
        'avatar': me.user.avatar,
        ...(clear
            ? {'bubble_skin': ''}
            : {
                'bubble_skin': skin.skin,
                'bubble_fg': skin.fg,
                'bubble_swap': skin.swap,
              }),
      });
      // 段 A：validateAppStatus 放行 4xx——失败原文呈现，不 reload、不 pop
      // （照 wallpaper_sheet._save 同款结构，只补显式判）
      final err = writeResponseError(r);
      if (err != null) {
        if (mounted) {
          ref.read(chatToastProvider.notifier).show(err,
              tone: ChatToastTone.error);
        }
        return false;
      }
      await ref.read(authProvider.notifier).reload();
      ref.read(chatUiTickProvider.notifier).state++;
      return true;
    } catch (e) {
      if (mounted) {
        ref.read(chatToastProvider.notifier).show(errorDetail(e),
            tone: ChatToastTone.error);
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = ref.watch(chatBaseProvider).valueOrNull;
    final total = _groups.fold<int>(0, (n, g) => n + g.count);
    // sheet 模式固定 68% 屏高；embedded（设置独立页）由 Scaffold body
    // 有界高度撑满，不固定高（Column + Expanded 直接可用）。
    final Widget body = Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('聊天气泡', style: theme.textTheme.titleMedium),
              // 2.4.6 各发各的：点明写的是「我的」按人皮肤
              Text('只换你发出的气泡，对方的由对方设置',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
              if (_groups.isNotEmpty)
                Text('共 $total 张 · 这一组 ${_currentGroup?.count ?? 0} 张',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
            ]),
          ),
          // embedded（设置独立页内嵌）不渲染关闭钮：pop 会误关设置页。
          if (!widget.embedded)
            IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded)),
        ]),
      ),
        // 组 tab（第 N 组，对齐 Web bpPackLabel）
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (var i = 0; i < _groups.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: TextButton(
                    onPressed: () => _switchPack(_groups[i].id),
                    style: TextButton.styleFrom(
                      backgroundColor: _groups[i].id == _pack
                          ? theme.colorScheme.primaryContainer
                          : null,
                      foregroundColor: _groups[i].id == _pack
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.outline,
                    ),
                    child: Text('第 ${i + 1} 组 ${_groups[i].count}'),
                  ),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        Expanded(child: _grid(theme, base)),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        _previewRow(theme, base),
        // 字色 + 互换 + 操作行（对齐 Web bp-fg/bp-swap/ps-row）
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Text('字色', style: theme.textTheme.bodyMedium),
              const SizedBox(width: 10),
              ChoiceChip(
                  label: const Text('深色字'),
                  selected: _fg == 'dark',
                  onSelected: (_) => setState(() => _fg = 'dark')),
              const SizedBox(width: 6),
              ChoiceChip(
                  label: const Text('浅色字'),
                  selected: _fg == 'light',
                  onSelected: (_) => setState(() => _fg = 'light')),
              const SizedBox(width: 8),
              Expanded(child: Text('气泡图有深有浅，按这张图选',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline))),
            ]),
            Row(children: [
              // 2.4.10：开关换果冻开关（取值/保存零改动）。
              JellySwitch(
                  value: _swap, onChanged: (v) => setState(() => _swap = v)),
              const Text('左右互换'),
              const SizedBox(width: 8),
              Expanded(child: Text('气泡的装饰朝哪边，看着别扭就勾一下',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline))),
            ]),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving
                      ? null
                      : () => _save(const ChatSkin(), clear: true), // 恢复未设置（回退空间级）
                  child: const Text('不用皮肤'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                // 2.4.10：使用这个走三连变（对勾驻留后关弹层）。
                child: SubmitMorphButton(
                  label: '使用这个',
                  onSubmit: _pick.isEmpty
                      ? () async => false
                      : () => _save(ChatSkin(skin: _pick, fg: _fg, swap: _swap)),
                  onSuccess: () => Navigator.of(context).pop(),
                ),
              ),
            ]),
          ]),
        ),
      ]);
    // sheet 模式包回 68% 屏高固定容器；embedded（设置独立页）直接用
    // 有界 body 撑满（Column + Expanded 布局与 sheet 模式完全一致）。
    if (widget.embedded) return body;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.68,
      child: body,
    );
  }

  Widget _grid(ThemeData theme, String? base) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final g = _currentGroup;
    if (g == null || g.items.isEmpty) {
      // 空素材文案对照 Web
      return Center(
        child: Text('服务器上还没有气泡素材。把图放进数据卷的 bubbles/ 目录，按包分文件夹即可。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline)),
      );
    }
    final headers = ref.watch(mediaCookieHeadersProvider).valueOrNull;
    return GridView.builder(
      controller: _gridController,
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 5, mainAxisSpacing: 4, crossAxisSpacing: 4),
      itemCount: _shown,
      itemBuilder: (context, i) {
        final name = g.items[i];
        final skinName = '${g.id}/$name';
        final selected = _pick == skinName;
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _pick = skinName),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: selected ? theme.colorScheme.primary : Colors.transparent,
                  width: 2),
            ),
            padding: const EdgeInsets.all(2),
            child: base == null
                ? const SizedBox()
                : CachedNetworkImage(
                    imageUrl: bubbleSkinUrl(base, skinName),
                    fit: BoxFit.contain,
                    // 皮肤图低频资源：首次取回落盘，后续读本地（通则 item 5）
                    httpHeaders: headers,
                    cacheManager: LowFreqCacheManager.instance,
                    placeholder: (_, _) => const SizedBox(),
                    errorWidget: (_, _, _) => const SizedBox()),
          ),
        );
      },
    );
  }

  /// 预览行（2.4.6 各发各的）：与实际气泡同规则——左=对方消息图（对方的
  /// 实际皮肤：按人→空间回退，作者 swap 定原图/镜像），右=我方消息图（所选
  /// 皮肤按作者 swap）；任一侧未启用皮肤 → 默认气泡占位，保证「预览=实际」。
  Widget _previewRow(ThemeData theme, String? base) {
    final me = ref.read(authProvider.notifier).me;
    final spaceSkin = ChatSkin.fromSpace(me?.spaceRaw ?? const {});
    final partner =
        me?.users.where((u) => u.id != me.user.id).firstOrNull;
    final peerSkin = partner == null
        ? spaceSkin
        : ChatSkin.fromAuthor(
            skin: partner.bubbleSkin,
            fg: partner.bubbleFg,
            swap: partner.bubbleSwap,
            fallback: spaceSkin);
    final pickSkin = ChatSkin(skin: _pick, fg: _fg, swap: _swap);
    if (base == null || (!pickSkin.enabled && !peerSkin.enabled)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(child: Text('未选择皮肤（使用默认气泡）',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline))),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        Expanded(child: _skinBubble(
            theme, base, peerSkin,
            label: peerSkin.enabled ? '这是对方说的' : '对方未设置（默认气泡）')),
        const SizedBox(width: 8),
        Expanded(child: _skinBubble(
            theme, base, pickSkin, label: '我们的小气泡')),
      ]),
    );
  }

  Widget _skinBubble(ThemeData theme, String base, ChatSkin skin,
      {required String label}) {
    // 预览与实际气泡共用 SkinBubble：同一 NinePatch painter（42 源角→16 目标角）、
    // 同一 CSS 盒模型内边距（padding 3/7 + border 16）、同一字色契约，
    // 保证「预览=实际」。内容高 24 + 上下各 19 → 预览总高 62，与单行真气泡接近。
    // 图 url 用 authorMessageUrl（作者消息渲染图，与聊天页行级同源）。
    // base 由调用方空判后传入（非空类型）；皮肤未启用走默认占位。
    if (!skin.enabled) {
      // 默认气泡占位（与聊天页默认态同款：圆角灰底 + 常规字色）
      return Container(
        height: 62,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(label,
            maxLines: 2, textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall),
      );
    }
    return SkinBubble(
      url: bubbleSkinUrl(base, skin.authorMessageUrl),
      fgLight: skin.fg == 'light',
      child: SizedBox(
        height: 24,
        child: Align(
          alignment: Alignment.center,
          child: Text(label,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: skinTextStyle(theme.textTheme.bodySmall,
                  fgLight: skin.fg == 'light')),
        ),
      ),
    );
  }
}
