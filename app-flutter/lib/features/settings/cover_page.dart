/// 主页背景（2.4.1 修复包第 3 项改版；上传与保存链全不动）：
/// ①「当前封面」徽标 + 「两个人共用这张封面」小字；
/// ②「首页效果预览」卡——候选封面按首页 hero 真实布局渲染
///   （HeroPreviewCard，数值与首页 2.3.8 实现逐位一致），选了新图未保存
///   时预览先行变化；
/// ③「选择封面照片」整行实心主按钮；
/// ④保存移入底部玻璃操作栏（SettingsGlassBar 共享组件，单动作整行）；
/// ⑤说明小字注脚样式（SettingsFootnote）。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import '../../core/theme/tokens.dart';
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'hero_preview_card.dart';
import 'settings_state.dart';
import 'settings_widgets.dart';

class CoverPage extends ConsumerStatefulWidget {
  const CoverPage({super.key});

  @override
  ConsumerState<CoverPage> createState() => _CoverPageState();
}

class _CoverPageState extends ConsumerState<CoverPage> {
  XFile? _picked;
  Uint8List? _pickedBytes;
  String? _coverError;
  bool _coverBusy = false;

  Map<String, dynamic>? get _knownSpace =>
      ref.read(authProvider.notifier).me?.spaceRaw;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final cover = (_knownSpace?['cover'] ?? '').toString();
    final me = ref.watch(authProvider.notifier).me;
    // 预览：已选字节优先（未保存先行变化），否则当前封面网络图，无则占位。
    final bytes = _pickedBytes;
    final base = ref.watch(chatBaseProvider).valueOrNull;
    final headers = ref.watch(mediaCookieHeadersProvider).valueOrNull;
    Widget previewImage;
    if (bytes != null) {
      previewImage = Image.memory(bytes, fit: BoxFit.cover);
    } else if (cover.isNotEmpty && base != null) {
      previewImage = Image.network(
        '$base/media/$cover?preview=true',
        fit: BoxFit.cover,
        headers: headers,
        errorBuilder: (_, _, _) => _coverPlaceholder(cs),
      );
    } else {
      previewImage = _coverPlaceholder(cs);
    }
    // 名字行/天数/日期取真实 me（预览数值与首页一致）。
    final names = me == null
        ? '…'
        : me.users.map((u) => u.name).join(' ♥ ');
    final since = me?.spaceSince ?? '';
    final days = (me?.spaceSince.isNotEmpty ?? false)
        ? DateTime.now().difference(DateTime.parse(me!.spaceSince)).inDays + 1
        : 0;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(title: const Text('主页背景')),
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                  16, 12, 16, SettingsGlassBar.barReserveHeight + 12),
              children: [
                // ① 封面预览 + 「当前封面」徽标 + 共用小字。
                Stack(
                  children: [
                    HeroPreviewCard(
                      names: names,
                      days: days,
                      since: since,
                      coverImage: previewImage,
                    ),
                    if (cover.isNotEmpty && bytes == null)
                      Positioned(
                        right: 10,
                        top: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 9, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text('当前封面',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                      color: Colors.white
                                          .withValues(alpha: 0.92))),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                const SettingsFootnote('两个人共用这张封面'),
                const SizedBox(height: 14),
                // ③ 整行实心主按钮。
                FilledButton.icon(
                  key: const Key('settings-cover-pick'),
                  onPressed: _coverBusy ? null : _pickCover,
                  icon: const Icon(Icons.image_outlined),
                  label: Text(_picked == null ? '选择封面照片' : '重新选择'),
                ),
                if (_picked != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _picked!.name,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                if (_coverError != null) ...[
                  const SizedBox(height: Spacing.gap),
                  Text(
                    _coverError!,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: cs.error),
                  ),
                ],
                const SizedBox(height: 12),
                // ⑤ 说明注脚（预览卡下方）。
                const SettingsFootnote(
                    '换好照片保存后会直接更新首页封面；想再换，回这里重选就行。'),
              ],
            ),
          ),
          // ④ 底部玻璃操作栏（单动作 → 整行保存）。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SettingsGlassBar(
              saveLabel: '保存',
              onSave: _saveCover,
              saveEnabled: _picked != null,
              busy: _coverBusy,
            ),
          ),
        ],
      ),
    );
  }

  Widget _coverPlaceholder(ColorScheme cs) => Container(
        color: cs.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🖼️', style: TextStyle(fontSize: 26)),
            const SizedBox(height: 4),
            Text(
              '选择一张照片作为我们的空间封面',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: cs.outline),
            ),
          ],
        ),
      );

  Future<void> _pickCover() async {
    try {
      final x = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        imageQuality: 88,
      );
      if (x == null) return;
      final bytes = await x.readAsBytes();
      if (!mounted) return;
      setState(() {
        _picked = x;
        _pickedBytes = Uint8List.fromList(bytes);
        _coverError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _coverError = api.errorDetail(e));
    }
  }

  Future<void> _saveCover() async {
    final x = _picked;
    final bytes = _pickedBytes;
    if (x == null || bytes == null) return;
    setState(() {
      _coverBusy = true;
      _coverError = null;
    });
    try {
      final dio = await ref.read(api.dioProvider.future);
      final id = await api.uploadMedia(dio, x.name, bytes);
      final (merged, err) = await saveSpaceChanges(
        dio,
        coverSpaceChanges(cover: id),
        knownSpace: _knownSpace,
      );
      if (err != null) {
        if (mounted) setState(() => _coverError = err);
        ref.read(chatToastProvider.notifier).show('封面保存失败：$err',
            tone: ChatToastTone.error);
        return;
      }
      if (merged != null) {
        ref.read(spaceAppearanceProvider.notifier).commit(merged);
      }
      await ref.read(authProvider.notifier).reload();
      if (!mounted) return;
      setState(() {
        _picked = null;
        _pickedBytes = null;
      });
      ref.read(chatToastProvider.notifier).show('主页封面换好了');
    } catch (e) {
      if (mounted) setState(() => _coverError = api.errorDetail(e));
      ref.read(chatToastProvider.notifier).show(
          '封面保存失败：${api.errorDetail(e)}',
          tone: ChatToastTone.error);
    } finally {
      if (mounted) setState(() => _coverBusy = false);
    }
  }
}
