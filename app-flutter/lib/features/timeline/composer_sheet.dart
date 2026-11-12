/// Composer 基础态（条目 4 · 段一，决策 4 定版：页头按钮+FAB 双入口即接）：
/// 标题（≤200 可选）/内容（≤20000）/日期（原生 showDatePicker）/媒体上传
/// （图视频多选+音频文件，≤30、进度、可前移/移除——复用段二聊天上传链路：
/// 白名单/250MB 预检/顺序上传/限流策略）；发布=POST /api/records {kind:'post',
/// body, client_id}（client_id 幂等复用，成功清空表单+reset 列表+toast）。
/// 草稿/录音/相册分类/本地暂存恢复归段二。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/api_client.dart';
import '../../core/chat/chat_media.dart';
import '../../core/chat/chat_models.dart' show ChatLocalFile;
import 'timeline_controller.dart';

/// 打开 composer 弹层（FAB 与页头「记录此刻」共用入口）
Future<void> showComposerSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => const ComposerSheet(),
  );
}

/// 一条待发媒体：先选本机文件 → 顺序上传拿 id → 发布进 body.media
class ComposerMedia {
  ComposerMedia({required this.localFile});
  final ChatLocalFile localFile;
  String? uploadedId;
  double progress = 0; // 0..1（上传中）
}

class ComposerSheet extends ConsumerStatefulWidget {
  const ComposerSheet({super.key});

  @override
  ConsumerState<ComposerSheet> createState() => _ComposerSheetState();
}

class _ComposerSheetState extends ConsumerState<ComposerSheet> {
  final _title = TextEditingController();
  final _content = TextEditingController();
  DateTime _date = DateTime.now();
  final _media = <ComposerMedia>[];
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
        context: context,
        initialDate: _date,
        firstDate: DateTime(2000),
        lastDate: DateTime.now().add(const Duration(days: 365)));
    if (d != null) setState(() => _date = d);
  }

  /// 图片/视频多选（对齐 Web composer 的 file input image/*,video/* multiple）
  Future<void> _pickImageVideo() async {
    final picked = await ImagePicker().pickMultiImage();
    if (picked.isEmpty) {
      // 纯视频多选不支持 → 单选视频兜底
      final v = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (v != null) _addMedia([v]);
      return;
    }
    await _addMedia(picked);
  }

  /// 音频文件（走媒体库半屏选择：与聊天「从相册选」同款策略；服务器音频
  /// 已有 id 直接引用，不重复上传）
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
            itemBuilder: (ctx, i) => InkWell(
                onTap: () => Navigator.pop(ctx, list[i].id),
                child: Center(child: Text(list[i].name,
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(ctx).textTheme.labelSmall))),
          ),
        ),
      );
      if (picked != null && picked.isNotEmpty) {
        setState(() => _media.add(ComposerMedia(
            localFile: ChatLocalFile(path: '', name: 'media:$picked'))
          ..uploadedId = picked));
      }
    } catch (e) {
      _snack(errorDetail(e));
    }
  }

  Future<void> _addMedia(List<XFile> files) async {
    for (final x in files) {
      final bytes = await File(x.path).length();
      final err = validateUploadFile(x.name, bytes);
      if (err != null) {
        _snack('${x.name}：$err');
        continue;
      }
      setState(() =>
          _media.add(ComposerMedia(localFile: ChatLocalFile(path: x.path, name: x.name))));
    }
    if (_media.length > maxMediaPerRecord) {
      _snack('一条记录最多 $maxMediaPerRecord 个附件，多出的已忽略');
      setState(() {
        while (_media.length > maxMediaPerRecord) {
          _media.removeLast();
        }
      });
    }
  }

  /// 前移（对齐 Web 媒体排序：把这一条往前挪一位）
  void _moveUp(int i) {
    if (i <= 0) return;
    setState(() {
      final m = _media.removeAt(i);
      _media.insert(i - 1, m);
    });
  }

  void _remove(int i) => setState(() => _media.removeAt(i));

  /// 发布：顺序上传（进度可见）→ POST 记录（client_id 幂等复用）
  Future<void> _submit() async {
    if (_submitting) return;
    final content = _content.text.trim();
    final title = _title.text.trim();
    if (content.isEmpty && _media.isEmpty) {
      setState(() => _error = '写点什么，或加一张照片吧');
      return;
    }
    setState(() { _submitting = true; _error = null; });
    try {
      // ① 顺序上传本机文件（进度逐条可见；媒体库引用项已带 id 跳过）
      final ids = <String>[];
      for (final m in _media) {
        if (m.uploadedId != null) {
          ids.add(m.uploadedId!);
          continue;
        }
        final bytes = await File(m.localFile.path).readAsBytes();
        final dio = await ref.read(dioProvider.future);
        final id = await uploadChatMedia(dio, m.localFile.name, bytes,
            onProgress: (p) {
          if (!mounted) return;
          setState(() => m.progress = p);
        });
        m.uploadedId = id;
        ids.add(id);
        if (mounted) setState(() {});
      }
      // ② 发布（client_id 幂等复用：失败保留 id 重试不重复建记录）
      final err = await ref.read(timelineControllerProvider.notifier).publish(
            content: content,
            date: _fmtDate(_date),
            mediaIds: ids,
            title: title.isEmpty ? null : title,
          );
      if (err != null) {
        setState(() { _error = err; _submitting = false; });
        return;
      }
      // ③ 成功：清空表单 + reset 列表 + toast
      await ref.read(timelineControllerProvider.notifier).resetAfterPublish();
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('这一刻，已经好好收藏')));
      }
    } catch (e) {
      setState(() {
        _error = e is MediaValidationError ? e.message : errorDetail(e);
        _submitting = false;
      });
    }
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
          left: 16, right: 16, top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 12),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('记录此刻', style: theme.textTheme.titleMedium)),
            IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded)),
          ]),
          TextField(
            controller: _title,
            maxLength: 200,
            decoration: const InputDecoration(
                labelText: '标题（可选）', counterText: '', isDense: true),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _content,
            maxLines: 4,
            minLines: 2,
            maxLength: 20000,
            decoration: const InputDecoration(
                labelText: '这一刻想说的话', counterText: '', alignLabelWithHint: true),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.event_rounded, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text('发生日期', style: theme.textTheme.bodyMedium),
            const SizedBox(width: 10),
            TextButton(
              onPressed: _pickDate,
              child: Text(_fmtDate(_date)),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _pickImageVideo,
              icon: const Icon(Icons.image_rounded, size: 18),
              label: const Text('图/视频'),
            ),
            TextButton.icon(
              onPressed: _pickFromLibrary,
              icon: const Icon(Icons.audiotrack_rounded, size: 18),
              label: const Text('音频'),
            ),
          ]),
          if (_media.isNotEmpty)
            ..._buildMediaList(theme),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('发布'),
          ),
        ]),
      ),
    );
  }

  List<Widget> _buildMediaList(ThemeData theme) {
    return [
      const SizedBox(height: 8),
      for (var i = 0; i < _media.length; i++)
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            Icon(Icons.attach_file_rounded, size: 16, color: theme.colorScheme.outline),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min, children: [
                Text(_media[i].localFile.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall),
                if (_media[i].uploadedId == null && _media[i].progress > 0)
                  LinearProgressIndicator(value: _media[i].progress, minHeight: 3),
                if (_media[i].uploadedId != null)
                  Text('已就绪',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.primary)),
              ]),
            ),
            IconButton(
              tooltip: '前移',
              visualDensity: VisualDensity.compact,
              onPressed: i == 0 ? null : () => _moveUp(i),
              icon: const Icon(Icons.arrow_upward_rounded, size: 18),
            ),
            IconButton(
              tooltip: '移除',
              visualDensity: VisualDensity.compact,
              onPressed: () => _remove(i),
              icon: Icon(Icons.close_rounded, size: 18, color: theme.colorScheme.error),
            ),
          ]),
        ),
    ];
  }
}
