/// 相册选择器（段二 · 对齐 Web chatAlbumPick/sendAlbumPick）：
/// 服务器媒体库半屏网格（GET /api/media/images?limit=300），点选只做「引用」
/// （打勾 + 序号角标），底部可写一句描述一起发；「上传」进本机选择器。
/// 文案逐项对照 Web：标题「从相册选」；「相册里 N 张」/「相册还是空的」/「已选 N 张」；
/// 空态「相册里还没有照片。先用上面的「上传」传一张，或者去相册页传。」；
/// 输入框 placeholder「说点什么…（可以留空）」；按钮「发送」/「发送 N」。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/chat/chat_media.dart';

/// 打开半屏相册选择器。
/// [onSend] 点发送（mids 已勾选、caption 已填）；[onUpload] 点「上传」。
Future<void> showAlbumPicker(
  BuildContext context, {
  required void Function(List<String> mids, String caption) onSend,
  required VoidCallback onUpload,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => _AlbumSheet(onSend: onSend, onUpload: onUpload),
  );
}

class _AlbumSheet extends ConsumerStatefulWidget {
  const _AlbumSheet({required this.onSend, required this.onUpload});
  final void Function(List<String> mids, String caption) onSend;
  final VoidCallback onUpload;

  @override
  ConsumerState<_AlbumSheet> createState() => _AlbumSheetState();
}

class _AlbumSheetState extends ConsumerState<_AlbumSheet> {
  final _sel = <String>[];
  final _caption = TextEditingController();
  List<MediaLibraryItem> _list = const [];
  bool _loading = true;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final dio = await ref.read(dioProvider.future);
      final list = await fetchMediaLibrary(dio);
      if (mounted) setState(() { _list = list; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = '相册加载失败，可关闭后重试'; });
    }
  }

  void _toggle(String mid) {
    setState(() {
      final at = _sel.indexOf(mid);
      if (at >= 0) { _sel.removeAt(at); } else { _sel.add(mid); }
    });
  }

  String get _countText {
    if (_sel.isNotEmpty) return '已选 ${_sel.length} 张';
    if (_list.isNotEmpty) return '相册里 ${_list.length} 张';
    return '相册还是空的';
  }

  Future<void> _send() async {
    if (_sel.isEmpty || _sending) return;
    setState(() => _sending = true);
    widget.onSend(List<String>.from(_sel), _caption.text.trim());
    // 发送即关（对齐 Web sendAlbumPick 成功后 closeModal；失败 toast 由页面提示）
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = MediaQuery.of(context).size.height * 0.62;
    return SizedBox(
      height: height,
      child: Column(children: [
        // 头部：标题 + 计数 + 上传 + 关闭（对齐 Web ps-head）
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('从相册选', style: theme.textTheme.titleMedium),
                Text(_countText,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              ]),
            ),
            OutlinedButton(onPressed: widget.onUpload, child: const Text('上传')),
            IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded)),
          ]),
        ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        // 网格
        Expanded(child: _buildGrid(theme)),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        // 底部：已选 chips + 一句话 + 发送（对齐 Web ps-foot）
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_sel.isNotEmpty)
                SizedBox(
                  height: 44,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _sel.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (context, i) => _pickedChip(theme, i),
                  ),
                ),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _caption,
                    maxLength: 200,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                        hintText: '说点什么…（可以留空）', counterText: '', isDense: true),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: _sel.isEmpty || _sending ? null : _send,
                  child: Text(_sel.isEmpty ? '发送' : '发送 ${_sel.length}'),
                ),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _pickedChip(ThemeData theme, int i) {
    return Stack(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: _AlbumThumb(mid: _sel[i], size: 44),
      ),
      Positioned(
        right: 0, top: 0,
        child: InkWell(
          onTap: () => _toggle(_sel[i]),
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
                color: theme.colorScheme.error, shape: BoxShape.circle),
            child: const Icon(Icons.close, size: 10, color: Colors.white),
          ),
        ),
      ),
      Positioned(
        left: 0, bottom: 0,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(6), bottomLeft: Radius.circular(6))),
          child: Text('${i + 1}',
              style: const TextStyle(fontSize: 10, color: Colors.white)),
        ),
      ),
    ]);
  }

  Widget _buildGrid(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text(_error!, style: theme.textTheme.bodyMedium));
    }
    if (_list.isEmpty) {
      // 空态逐字对齐 Web：'相册里还没有照片。先用上面的「上传」传一张，或者去相册页传。'
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text('相册里还没有照片。先用上面的「上传」传一张，或者去相册页传。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline)),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
      itemCount: _list.length,
      itemBuilder: (context, i) {
        final item = _list[i];
        final at = _sel.indexOf(item.id);
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _toggle(item.id),
          child: Stack(fit: StackFit.expand, children: [
            ClipRRect(borderRadius: BorderRadius.circular(8), child: _AlbumThumb(mid: item.id, size: 120)),
            if (at >= 0)
              Positioned(
                right: 4, top: 4,
                child: Container(
                  width: 22, height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: theme.colorScheme.primary, shape: BoxShape.circle),
                  child: Text('${at + 1}',
                      style: const TextStyle(fontSize: 11, color: Colors.white)),
                ),
              ),
          ]),
        );
      },
    );
  }
}

/// 相册缩略图（preview 图带 Cookie；失败灰块）
class _AlbumThumb extends ConsumerWidget {
  const _AlbumThumb({required this.mid, required this.size});
  final String mid;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final base = ref.watch(chatBaseProvider).valueOrNull;
    if (base == null) {
      return Container(width: size, height: size, color: Theme.of(context).colorScheme.surfaceContainerHighest);
    }
    final headers = ref.watch(mediaCookieHeadersProvider).valueOrNull;
    return CachedNetworkImage(
      imageUrl: mediaUrl(base, mid),
      httpHeaders: headers,
      width: size, height: size,
      fit: BoxFit.cover,
      placeholder: (_, _) => Container(width: size, height: size, color: Theme.of(context).colorScheme.surfaceContainerHighest),
      errorWidget: (_, _, _) => Container(width: size, height: size, color: Theme.of(context).colorScheme.surfaceContainerHighest),
    );
  }
}
