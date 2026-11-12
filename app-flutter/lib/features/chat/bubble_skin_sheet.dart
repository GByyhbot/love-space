/// 气泡皮肤弹层（段三 · Step 9，对齐 Web bubblePicker）：
/// GET /api/bubbles 分组 tab（第 N 组）+ 网格分批渲染（BP_PAGE=90，滚到底续载）
/// + 预览行（与实际气泡相同的左右规则）+ 字色深/浅 + 左右互换 + 恢复默认。
/// 落库 PUT /api/space 的 chat_bubble/chat_bubble_fg/chat_bubble_swap 三键。
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
import 'skin_bubble.dart';

Future<void> showBubbleSkinSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => const _BubbleSkinSheet(),
  );
}

class _BubbleSkinSheet extends ConsumerStatefulWidget {
  const _BubbleSkinSheet();

  @override
  ConsumerState<_BubbleSkinSheet> createState() => _BubbleSkinSheetState();
}

class _BubbleSkinSheetState extends ConsumerState<_BubbleSkinSheet> {
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
    final skin = ChatSkin.fromSpace(me?.spaceRaw ?? const {});
    _pick = skin.skin;
    _fg = skin.fg;
    _swap = skin.swap;
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

  Future<void> _save(ChatSkin skin) async {
    if (_saving) return;
    final me = ref.read(authProvider.notifier).me;
    if (me == null) return;
    setState(() => _saving = true);
    try {
      final dio = await ref.read(dioProvider.future);
      final payload =
          applyChatSkinPayload(me.spaceRaw, skin: skin.skin, fg: skin.fg, swap: skin.swap);
      await dio.put('/api/space', data: payload);
      await ref.read(authProvider.notifier).reload();
      ref.read(chatUiTickProvider.notifier).state++;
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(errorDetail(e))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = ref.watch(chatBaseProvider).valueOrNull;
    final height = MediaQuery.of(context).size.height * 0.68;
    final total = _groups.fold<int>(0, (n, g) => n + g.count);
    return SizedBox(
      height: height,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('聊天气泡', style: theme.textTheme.titleMedium),
                if (_groups.isNotEmpty)
                  Text('共 $total 张 · 这一组 ${_currentGroup?.count ?? 0} 张',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
              ]),
            ),
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
              Switch(value: _swap, onChanged: (v) => setState(() => _swap = v)),
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
                      : () => _save(const ChatSkin()), // 恢复默认（不用皮肤）
                  child: const Text('不用皮肤'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _saving || _pick.isEmpty
                      ? null
                      : () => _save(ChatSkin(skin: _pick, fg: _fg, swap: _swap)),
                  child: _saving
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('使用这个'),
                ),
              ),
            ]),
          ]),
        ),
      ]),
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

  /// 预览行：与实际气泡相同的左右规则（左=对方用 left 图，右=我用 right 图，
  /// ChatSkin.leftRightUrls 已按 swap 对调），字色按 fg
  Widget _previewRow(ThemeData theme, String? base) {
    if (base == null || _pick.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(child: Text('未选择皮肤（使用默认气泡）',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline))),
      );
    }
    final skin = ChatSkin(skin: _pick, fg: _fg, swap: _swap);
    final (left, right) = skin.leftRightUrls;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        Expanded(child: _skinBubble(theme, base, left, mine: false)),
        const SizedBox(width: 8),
        Expanded(child: _skinBubble(theme, base, right, mine: true)),
      ]),
    );
  }

  Widget _skinBubble(ThemeData theme, String base, String packName,
      {required bool mine}) {
    // 预览与实际气泡共用 SkinBubble：同一 NinePatch painter（42 源角→16 目标角）、
    // 同一 CSS 盒模型内边距（padding 3/7 + border 16）、同一字色契约，
    // 保证「预览=实际」。内容高 24 + 上下各 19 → 预览总高 62，与单行真气泡接近。
    // mine 侧 url 已是服务器 -r 镜像图。
    return SkinBubble(
      url: bubbleSkinUrl(base, packName),
      fgLight: _fg == 'light',
      child: SizedBox(
        height: 24,
        child: Align(
          alignment: Alignment.center,
          child: Text(mine ? '我们的小气泡' : '这是对方说的',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: skinTextStyle(theme.textTheme.bodySmall,
                  fgLight: _fg == 'light')),
        ),
      ),
    );
  }
}
