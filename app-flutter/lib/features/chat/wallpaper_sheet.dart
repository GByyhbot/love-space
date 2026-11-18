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
import 'chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../../core/theme/tokens.dart';
import '../settings/settings_widgets.dart' show SettingsSegmented;

Future<void> showWallpaperSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg))),
    builder: (_) => const WallpaperSheet(),
  );
}

/// 聊天背景面板本体（2.4.0 设置拆分段公开化）：聊天页右上角 sheet 与
/// 设置独立页（chat_wallpaper_page）共用**同一组件与同一数据源**——
/// 任何一处修改，另一处即时一致（authProvider.spaceRaw 单一事实）。
/// [embedded] = true 时作为设置页内嵌面板：不渲染关闭钮（关闭钮在
/// sheet 模式下 Navigator.pop 会误关设置页），其余 UI 与保存链逐位一致。
class WallpaperSheet extends ConsumerStatefulWidget {
  const WallpaperSheet({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<WallpaperSheet> createState() => WallpaperSheetState();
}

/// State 公开：设置独立页用 GlobalKey 触发 [WallpaperSheetState.saveNow]
/// （底部玻璃操作栏调同一保存实现，禁止复制第二套保存链）。
class WallpaperSheetState extends ConsumerState<WallpaperSheet> {
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
    ref.read(chatToastProvider.notifier).show(msg,
        tone: ChatToastTone.info);
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
      // 段 A：上传 4xx（detail 原文）以 MediaValidationError 抛出，直通呈现
      _snack(e is MediaValidationError ? e.message : errorDetail(e));
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
            borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg))),
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
      final r = await dio.put('/api/space', data: payload);
      // 段 A：validateAppStatus 放行 4xx——失败原文呈现，不 reload、不 pop
      // （结构沿用上方 _snack(err) 校验分支，只补显式判）
      final err = writeResponseError(r);
      if (err != null) { _snack(err); return; }
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
          // embedded（设置独立页）：标题行不渲染（页 AppBar 已有「聊天背景」，
          // 避免重复）；sheet 模式保留标题 + 关闭钮。
          if (!widget.embedded)
            Row(children: [
              Expanded(
                  child:
                      Text('聊天背景', style: theme.textTheme.titleMedium)),
              IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded)),
            ]),
          SizedBox(height: widget.embedded ? 0 : 4),
          if (partner != null)
            Row(children: [
              // 2.4.1 第 4 项②：「设给谁」三字删除（yang 明确）——分段器
              // 语义自明（我的手机 / TA 的手机）。
              Expanded(
                child: SettingsSegmented<String>(
                  segments: [
                    (me.user.id, '我的手机'),
                    (partner.id, 'TA 的手机'),
                  ],
                  selected: _target,
                  onChanged: _switchTarget,
                ),
              ),
            ]),
          const SizedBox(height: 12),
          // 2.4.2 第 1 项：色卡网格改 GridView 等分拉满（与分段器/预览区
          // 同宽同缘）——原 Wrap+固定宽 86 卡在 393 宽下每行 3 张
          // （3×86+2×8=274，右空 87px）整体偏左；改 4 列等分后行间距与
          // 列间距一致，末行（「用照片」）保持同卡宽左起排列。
          GridView.count(
            key: const Key('wallpaper-swatches'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            crossAxisCount: 4,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.98,
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
            ],
          ),
          const SizedBox(height: 12),
          // 2.4.1 第 4 项④：聊天效果预览——两条样例气泡浮在当前选中背景
          // 之上，遮罩浓度实时跟随滑杆（同一 _bg/_dim 状态，天然同源）。
          _previewZone(theme),
          const SizedBox(height: 12),
          Row(children: [
            Text('背景遮罩', style: theme.textTheme.bodyMedium),
            Expanded(
              child: Slider(
                min: 0, max: 80, divisions: 16, // 0–80 步进 5（对齐 Web range step=5）
                value: _dim.clamp(0, 80).toDouble(),
                // 2.4.1 第 4 项⑤：主题色轨道。
                activeColor: theme.colorScheme.primary,
                onChanged: (v) => setState(() => _dim = v),
              ),
            ),
            // 右端固定百分比读数。
            Text('${_dim.round()}%',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ]),
          const SizedBox(height: Spacing.gap),
          // 2.4.2 第 1 项：面板内说明文案已删（与设置独立页分区末尾注脚
          // 重复——保留注脚位置那份，全文只出现一次）。
          // embedded（设置独立页）：保存移入底部玻璃操作栏（页面层
          // GlobalKey 调 saveNow），此处不渲染；sheet 模式保留原保存钮。
          if (!widget.embedded) ...[
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('保存'),
            ),
          ],
        ]),
      ),
    );
  }

  /// 效果预览区：当前选中背景（预设渐变 / 照片缺省占位）+ 遮罩黑层
  /// （α = dim/100）+ 对方/我方两条样例气泡。
  Widget _previewZone(ThemeData theme) {
    final cs = theme.colorScheme;
    return Container(
      key: const Key('wallpaper-preview'),
      height: 120,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: presetGradient(_bg) ??
            LinearGradient(colors: [
              cs.surfaceContainerHighest,
              cs.surfaceContainerHighest.withValues(alpha: 0.6),
            ]),
      ),
      child: Stack(
        children: [
          // 遮罩黑层实时跟随 _dim。
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: _dim / 100),
            ),
          ),
          Positioned(
            left: 12,
            top: 16,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('这是对方说的',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurface)),
            ),
          ),
          Positioned(
            right: 12,
            bottom: 16,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('我们的一条样例',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.onPrimary)),
            ),
          ),
        ],
      ),
    );
  }

  /// 公开保存入口（设置独立页玻璃操作栏触发，与 sheet 保存同一实现）。
  Future<void> saveNow() => _save();
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
      borderRadius: BorderRadius.circular(AppRadius.sm),
      onTap: onTap,
      child: Container(
        // 2.4.2 第 1 项：去固定宽 86（等分格内自适应），色块按 72:48
        // 比例随格宽缩放，文字 FittedBox 防窄屏溢出。
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          border: Border.all(
              color: selected ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
              width: selected ? 2 : 1),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Column(children: [
          AspectRatio(
            aspectRatio: 72 / 48,
            child: Stack(children: [
              Container(
                width: double.infinity,
                height: double.infinity,
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
              // 2.4.1 第 4 项③：选中态统一勾徽（原只有「用照片」卡有边框，
              // 其余靠色差区分——现在全部主题色描边 + 右上角勾）。
              if (selected)
                Positioned(
                  right: 2,
                  top: 2,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check,
                        size: 11, color: Colors.white),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label,
                maxLines: 1,
                style: theme.textTheme.labelSmall),
          ),
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
