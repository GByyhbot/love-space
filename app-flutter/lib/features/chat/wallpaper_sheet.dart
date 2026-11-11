/// 聊天背景弹层（段三 · Step 9，对齐 Web chatBgForm）：
/// 「设给谁」选择器（自己 / TA 的手机——每人一份，谁都能替对方换）+ 7 预设色卡
/// + dim 0–80 滑杆（默认 35）+「用照片」（本机上传 / 从服务器媒体库选）。
/// PUT /api/space 全量覆盖只改 chat_bg* 四键（applyChatBgPayload）。
/// 文案逐字对照 Web：标题「聊天背景」；说明「你们各看各的背景，互不打扰；
/// 但谁都能替对方换一张——上面选「TA 的手机」就行。」；照片格「用你们的照片」。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/api_client.dart';
import '../../core/chat/chat_media.dart';
import '../../core/chat/chat_state.dart';
import '../../core/chat/chat_wallpaper.dart';
import '../auth/auth_state.dart';

Future<void> showWallpaperSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => const _WallpaperSheet(),
  );
}

class _WallpaperSheet extends ConsumerStatefulWidget {
  const _WallpaperSheet();

  @override
  ConsumerState<_WallpaperSheet> createState() => _WallpaperSheetState();
}

class _WallpaperSheetState extends ConsumerState<_WallpaperSheet> {
  String _target = ''; // '' = 自己（initState 里填）
  String _bg = '';
  String _media = '';
  double _dim = 35;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final me = ref.read(authProvider.notifier).me;
    _target = me?.user.id ?? '';
    final wp = chatBgOf(me?.spaceRaw ?? const {}, _target);
    _bg = wp.bg;
    _media = wp.media;
    _dim = wp.dim.toDouble();
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  /// 切「设给谁」：按目标用户当前那份重绘色卡（对齐 Web bg-target change）
  void _switchTarget(String uid) {
    final me = ref.read(authProvider.notifier).me;
    final wp = chatBgOf(me?.spaceRaw ?? const {}, uid);
    setState(() {
      _target = uid;
      _bg = wp.bg;
      _media = wp.media;
      _dim = wp.dim.toDouble();
    });
  }

  Future<void> _pickPhoto() async {
    final x = await ImagePicker().pickImage(
        source: ImageSource.gallery, maxWidth: 2048, imageQuality: 90);
    if (x == null) return;
    try {
      final bytes = await x.readAsBytes();
      final dio = await ref.read(dioProvider.future);
      final err = validateUploadFile(x.name, bytes.length);
      if (err != null) { _snack(err); return; }
      final mid = await uploadChatMedia(dio, x.name, bytes);
      setState(() { _bg = 'photo'; _media = mid; });
    } catch (e) {
      _snack(errorDetail(e));
    }
  }

  /// 从服务器媒体库选（对齐 Web bg-album：inline 网格选一张）
  Future<void> _pickFromLibrary() async {
    try {
      final dio = await ref.read(dioProvider.future);
      final list = await fetchMediaLibrary(dio, limit: 60);
      if (!mounted) return;
      final picked = await showModalBottomSheet<String>(
        context: context,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (ctx) => SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.5,
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
            itemCount: list.length,
            itemBuilder: (ctx, i) => Consumer(builder: (ctx, ref, _) {
              final base = ref.watch(chatBaseProvider).valueOrNull;
              final headers = ref.watch(mediaCookieHeadersProvider).valueOrNull;
              return InkWell(
                onTap: () => Navigator.pop(ctx, list[i].id),
                child: base == null
                    ? const SizedBox()
                    : CachedNetworkImage(
                        imageUrl: mediaUrl(base, list[i].id),
                        httpHeaders: headers, fit: BoxFit.cover),
              );
            }),
          ),
        ),
      );
      if (picked != null) setState(() { _bg = 'photo'; _media = picked; });
    } catch (e) {
      _snack(errorDetail(e));
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final me = ref.read(authProvider.notifier).me;
    if (me == null) return;
    final (payload, err) = applyChatBgPayload(me.spaceRaw,
        target: _target, bg: _bg, media: _media, dim: _dim.round());
    if (err != null) { _snack(err); return; }
    setState(() => _saving = true);
    try {
      final dio = await ref.read(dioProvider.future);
      await dio.put('/api/space', data: payload);
      // 本地即时生效：重拉 me（space 原样对象已含新背景）+ bump 聊天页 UI 时钟
      await ref.read(authProvider.notifier).reload();
      ref.read(chatUiTickProvider.notifier).state++;
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _snack(errorDetail(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = ref.watch(authProvider.notifier).me;
    if (me == null) return const SizedBox();
    final partner = me.users.where((u) => u.id != me.user.id).firstOrNull;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('聊天背景', style: theme.textTheme.titleMedium)),
            IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded)),
          ]),
          const SizedBox(height: 4),
          if (partner != null)
            Row(children: [
              Text('设给谁', style: theme.textTheme.bodyMedium),
              const SizedBox(width: 12),
              Expanded(
                child: SegmentedButton<String>(
                  segments: [
                    ButtonSegment(value: me.user.id, label: Text('我的手机')),
                    ButtonSegment(value: partner.id, label: Text('TA 的手机')),
                  ],
                  selected: {_target},
                  onSelectionChanged: (s) => _switchTarget(s.first),
                ),
              ),
            ]),
          const SizedBox(height: 12),
          Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (key, label) in chatBgPresets)
                  _Swatch(
                    bgKey: key,
                    label: label,
                    selected: _bg == key,
                    media: key == 'photo' ? _media : '',
                    base: ref.watch(chatBaseProvider).valueOrNull,
                    headers: ref.watch(mediaCookieHeadersProvider).valueOrNull,
                    onTap: () => key == 'photo'
                        ? (_media.isEmpty ? _pickPhoto() : _pickFromLibrary())
                        : setState(() => _bg = key),
                  ),
              ]),
          const SizedBox(height: 12),
          Row(children: [
            Text('背景遮罩', style: theme.textTheme.bodyMedium),
            Expanded(
              child: Slider(
                min: 0, max: 80, divisions: 16, // 0–80 步进 5（对齐 Web range step=5）
                value: _dim.clamp(0, 80).toDouble(),
                onChanged: (v) => setState(() => _dim = v),
              ),
            ),
            Text('${_dim.round()}%',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ]),
          const SizedBox(height: 6),
          Text('你们各看各的背景，互不打扰；但谁都能替对方换一张——上面选「TA 的手机」就行。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('保存'),
          ),
        ]),
      ),
    );
  }
}

/// 色卡（预设渐变缩略 / 照片缩略 / 📷 占位）
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.bgKey,
    required this.label,
    required this.selected,
    required this.media,
    required this.base,
    required this.headers,
    required this.onTap,
  });
  final String bgKey;
  final String label;
  final bool selected;
  final String media;
  final String? base;
  final Map<String, String>? headers;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        width: 86,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          border: Border.all(
              color: selected ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
              width: selected ? 2 : 1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(children: [
          Container(
            width: 72, height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              gradient: presetGradient(bgKey),
            ),
            child: bgKey == 'photo'
                ? (media.isNotEmpty && base != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: CachedNetworkImage(
                            imageUrl: mediaUrl(base!, media),
                            httpHeaders: headers,
                            fit: BoxFit.cover))
                    : const Icon(Icons.photo_camera_rounded, size: 22))
                : null,
          ),
          const SizedBox(height: 4),
          Text(label, style: theme.textTheme.labelSmall),
        ]),
      ),
    );
  }
}

/// 预设渐变（对齐 Web data-bg 色卡的浅色渐变方向；key=''=无背景）
Gradient? presetGradient(String key) {
  switch (key) {
    case 'sakura':
      return const LinearGradient(colors: [Color(0xFFFFE4EC), Color(0xFFFFD3E0)]);
    case 'cream':
      return const LinearGradient(colors: [Color(0xFFFFF3DC), Color(0xFFFFE9C7)]);
    case 'mint':
      return const LinearGradient(colors: [Color(0xFFDFF5EA), Color(0xFFCDEEE0)]);
    case 'stars':
      return const LinearGradient(colors: [Color(0xFF2E3350), Color(0xFF1D2036)]);
    case 'night':
      return const LinearGradient(colors: [Color(0xFF232A45), Color(0xFF141A30)]);
    default:
      return null;
  }
}
