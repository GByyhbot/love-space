/// 主页背景（2.4.0 设置拆分段）：原全量 /settings 的「主页背景」节整节
/// 搬入独立页，代码原样搬移零逻辑改动。保存链不变：uploadMedia +
/// saveSpaceChanges(coverSpaceChanges)（全量 space 合并 PUT，绝不丢字段）；
/// 失败行内保留 + 顶部 toast、成功顶部 toast 并清空本地待选。
/// Web 出处 homeBgForm :1943-1956。
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
import 'settings_state.dart';

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
    return Scaffold(
      appBar: AppBar(title: const Text('主页背景')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('首页封面照片', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: Spacing.gap),
            _coverPreview(context, cover),
            const SizedBox(height: 10),
            Row(
              children: [
                OutlinedButton.icon(
                  key: const Key('settings-cover-pick'),
                  onPressed: _coverBusy ? null : _pickCover,
                  icon: const Icon(Icons.image_outlined),
                  label: Text(_picked == null ? '选择封面照片' : '重新选择'),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  key: const Key('settings-cover-save'),
                  onPressed: _coverBusy || _picked == null ? null : _saveCover,
                  child: _coverBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('保存'),
                ),
              ],
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
            const SizedBox(height: Spacing.gap),
            Text(
              '换好照片保存后会直接更新首页封面；想再换，回这里重选就行。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _coverPreview(BuildContext context, String cover) {
    final cs = Theme.of(context).colorScheme;
    final headers = ref.watch(mediaCookieHeadersProvider).valueOrNull;
    final base = ref.watch(chatBaseProvider).valueOrNull;
    final bytes = _pickedBytes;
    Widget image;
    if (bytes != null) {
      image = Image.memory(bytes, fit: BoxFit.cover);
    } else if (cover.isNotEmpty && base != null) {
      image = Image.network(
        '$base/media/$cover?preview=true',
        fit: BoxFit.cover,
        headers: headers,
        errorBuilder: (_, _, _) => _coverPlaceholder(cs),
      );
    } else {
      image = _coverPlaceholder(cs);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: SizedBox(height: 120, width: double.infinity, child: image),
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
