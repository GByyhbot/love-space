/// 传照片专属 sheet（2.4.1 第 16 项）：发布抽屉「传照片」不再借用 composer
/// 完整态弹层，改开本 sheet——外壳同 composer（抓手 + 标题 + 关闭圆钮）。
/// 媒体区 = 虚线描边「+ 添加照片/视频」格 + 已选缩略网格（视频播放徽标 +
/// 可移除）；选图/上传走 composer 现有链路（pickImageVideoFiles +
/// validateUploadFile + uploadChatMedia 两段式，行为等价，不新写通道）；
/// 相册选择框同第 12 项第 5 点（showSelectionSheet，首行「暂不分类」）。
/// 玻璃栏「上传 N 项」未选禁用；上传中「上传中…」双钮禁用；失败顶部
/// toast 原文；成功关 sheet + toast「已上传到相册」。
/// 提交：POST /api/records kind=post，body 只含 media+album（正文空），
/// client_id 幂等（失败重试复用同一 id）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/chat/chat_media.dart';
import '../../core/chat/chat_models.dart' show ChatLocalFile;
import '../../core/chat/chat_repository.dart' show newChatClientId;
import '../../core/theme/tokens.dart';
import '../../core/ui/selection_sheet.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../settings/settings_widgets.dart' show GlassActionBar;
import 'composer_sheet.dart' show AlbumChoice, ComposerMedia, fetchAlbumList,
    pickImageVideoFiles;

/// 打开传照片 sheet（发布抽屉「传照片」入口）。
Future<void> showPhotoUploadSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg))),
    builder: (_) => const PhotoUploadSheet(),
  );
}

class PhotoUploadSheet extends ConsumerStatefulWidget {
  const PhotoUploadSheet({super.key});
  @override
  ConsumerState<PhotoUploadSheet> createState() => _PhotoUploadSheetState();
}

class _PhotoUploadSheetState extends ConsumerState<PhotoUploadSheet> {
  final _media = <ComposerMedia>[];
  String? _album; // 选中相册 id；null=暂不分类
  List<AlbumChoice> _albums = const [];
  bool _albumsLoading = true;
  bool _uploading = false;
  String? _error;

  /// client_id 幂等：sheet 存续期固定一个 id，失败重试复用；
  /// 关闭重开（sheet 重建）= 新 id，与 composer 语义一致。
  late final String _clientId = newChatClientId();

  @override
  void initState() {
    super.initState();
    Future.microtask(_fetchAlbums);
  }

  void _toast(String msg, {ChatToastTone tone = ChatToastTone.info}) {
    ref.read(chatToastProvider.notifier).show(msg, tone: tone);
  }

  Future<void> _fetchAlbums() async {
    try {
      final list = await fetchAlbumList(() => ref.read(dioProvider.future));
      if (!mounted) return;
      setState(() {
        _albums = list;
        _albumsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _albumsLoading = false);
    }
  }

  Future<void> _pick() async {
    final picked = await pickImageVideoFiles();
    if (picked.isEmpty || !mounted) return;
    for (final x in picked) {
      final bytes = await File(x.path).length();
      final err = validateUploadFile(x.name, bytes);
      if (err != null) {
        _toast('${x.name}：$err', tone: ChatToastTone.warning);
        continue;
      }
      setState(() => _media
          .add(ComposerMedia(localFile: ChatLocalFile(path: x.path, name: x.name))));
    }
    if (_media.length > maxMediaPerRecord) {
      _toast('一条记录最多 $maxMediaPerRecord 个附件，多出的已忽略',
          tone: ChatToastTone.warning);
      setState(() {
        while (_media.length > maxMediaPerRecord) {
          _media.removeLast();
        }
      });
    }
  }

  void _remove(int i) => setState(() => _media.removeAt(i));

  bool _isVideo(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.3gp');
  }

  Future<void> _submit() async {
    if (_uploading || _media.isEmpty) return;
    setState(() { _uploading = true; _error = null; });
    try {
      // 两段式上传（同 composer 链路）：本机文件逐个 POST /api/media 拿 id。
      final ids = <String>[];
      final dio = await ref.read(dioProvider.future);
      for (final m in _media) {
        if (m.uploadedId != null) {
          ids.add(m.uploadedId!);
          continue;
        }
        final bytes = await File(m.localFile.path).readAsBytes();
        final id = await uploadChatMedia(dio, m.localFile.name, bytes,
            onProgress: (p) {
          if (!mounted) return;
          setState(() => m.progress = p);
        });
        m.uploadedId = id;
        ids.add(id);
        if (mounted) setState(() {});
      }
      // 发布：kind=post，body 只含 media+album（正文空）、client_id 幂等。
      final r = await dio.post('/api/records', data: {
        'kind': 'post',
        'body': {
          'media': ids,
          if (_album != null && _album!.isNotEmpty) 'album': _album,
        },
        'client_id': _clientId,
      });
      if ((r.statusCode ?? 500) >= 400) {
        final data = r.data;
        final msg = (data is Map && data['detail'] != null)
            ? data['detail'].toString()
            : '上传失败，请重试';
        setState(() { _error = msg; _uploading = false; });
        _toast(msg, tone: ChatToastTone.error);
        return;
      }
      if (!mounted) return;
      // 成功：顶部通知（先发再关弹层，宿主接棒显示同一 provider 的通知）。
      _toast('已上传到相册', tone: ChatToastTone.success);
      Navigator.of(context).pop();
    } catch (e) {
      final msg = e is MediaValidationError ? e.message : errorDetail(e);
      setState(() { _error = msg; _uploading = false; });
      _toast(msg, tone: ChatToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 12, bottom: 12),
      child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // 外壳（同 composer sheet）：抓手 + 标题 + 关闭圆钮。
        Column(children: [
          Center(
            child: Container(
              width: 38,
              height: 4.5,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          Row(children: [
            Expanded(child: Text('传照片', style: theme.textTheme.titleMedium)),
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.6),
              ),
              child: IconButton(
                  tooltip: '关闭',
                  visualDensity: VisualDensity.compact,
                  onPressed: _uploading ? null : () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, size: 18)),
            ),
          ]),
        ]),
        const SizedBox(height: 10),
        // 媒体区：虚线「+ 添加照片/视频」格 + 已选缩略网格（视频播放徽标 +
        // 可移除；上传中进度条）。🔴 限高容器：min Column 内 Flexible 包
        // shrinkWrap GridView 会取内容全高溢出（C 组门禁 widget 场景抓出），
        // 用 maxHeight 0.35 屏高夹住，内容少收缩、多滚动。
        ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.35),
          child: GridView.count(
            shrinkWrap: true,
            crossAxisCount: 3,
            childAspectRatio: 1,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            padding: EdgeInsets.zero,
            children: [
              // 虚线添加格
              InkWell(
                key: const Key('photo-add-tile'),
                borderRadius: BorderRadius.circular(12),
                onTap: _uploading ? null : _pick,
                child: CustomPaint(
                  painter: _DashedRectPainter(
                      color: theme.colorScheme.outline.withValues(alpha: 0.7)),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_rounded, size: 26,
                          color: theme.colorScheme.primary),
                      const SizedBox(height: 4),
                      Text('添加照片/视频',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: theme.colorScheme.primary)),
                    ],
                  ),
                ),
              ),
              for (var i = 0; i < _media.length; i++)
                Stack(children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Stack(fit: StackFit.expand, children: [
                        if (!_isVideo(_media[i].localFile.name))
                          Image.file(
                            File(_media[i].localFile.path),
                            fit: BoxFit.cover,
                            cacheWidth: 300,
                            errorBuilder: (_, _, _) => Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: Icon(Icons.broken_image_rounded,
                                  size: 22, color: theme.colorScheme.outline),
                            ),
                          )
                        else ...[
                          Container(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: Icon(Icons.play_circle_fill_rounded,
                                size: 32, color: theme.colorScheme.primary),
                          ),
                          Positioned(
                            left: 6,
                            bottom: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text('视频',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                      color: Colors.white, fontSize: 10)),
                            ),
                          ),
                        ],
                        if (_media[i].uploadedId == null &&
                            _media[i].progress > 0)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: LinearProgressIndicator(
                                value: _media[i].progress, minHeight: 3),
                          ),
                        if (_media[i].uploadedId != null)
                          Positioned(
                            left: 6,
                            top: 6,
                            child: Icon(Icons.check_rounded,
                                size: 16,
                                color: theme.colorScheme.primary),
                          ),
                      ]),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    child: InkWell(
                      onTap: _uploading ? null : () => _remove(i),
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withValues(alpha: 0.55),
                        ),
                        child: Icon(Icons.close_rounded,
                            size: 14, color: Colors.white),
                      ),
                    ),
                  ),
                ]),
            ],
          ),
        ),
        // 相册分类选择框（同第 12 项第 5 点）。
        if (_albums.isNotEmpty || _albumsLoading)
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: InkWell(
              key: const Key('photo-album-field'),
              borderRadius: BorderRadius.circular(12),
              onTap: _albumsLoading || _uploading
                  ? null
                  : () async {
                      final picked = await showSelectionSheet<String>(
                        context: context,
                        title: '相册分类',
                        selected: _album ?? '',
                        options: [
                          const SelectionOption(value: '', label: '暂不分类'),
                          for (final a in _albums)
                            SelectionOption(value: a.id, label: a.title),
                        ],
                      );
                      if (picked != null) {
                        setState(() => _album = picked);
                      }
                    },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(children: [
                  Text('相册', style: theme.textTheme.labelSmall),
                  const Spacer(),
                  Flexible(
                    child: Text(_albumLabel(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.chevron_right_rounded,
                      size: 18, color: theme.colorScheme.outline),
                ]),
              ),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
          ),
        const SizedBox(height: 10),
        // 玻璃栏：取消 1/3 + 「上传 N 项」2/3；未选禁用、上传中双钮禁用
        // （保存钮文案切「上传中…」，不用 busy spinner 以保文字提示）。
        GlassActionBar(
          safeAreaBottom: false,
          cancelLabel: '取消',
          onCancel: () {
            if (!_uploading) Navigator.of(context).pop();
          },
          saveLabel: _uploading ? '上传中…' : '上传 ${_media.length} 项',
          onSave: _submit,
          saveEnabled: !_uploading && _media.isNotEmpty,
        ),
      ]),
    );
  }

  String _albumLabel() {
    if (_albumsLoading) return '加载中…';
    if (_album == null) return '暂不分类';
    for (final a in _albums) {
      if (a.id == _album) return a.title;
    }
    return '暂不分类';
  }
}

/// 虚线圆角描边（添加格用）：沿 RRect 路径等步长画短划。
class _DashedRectPainter extends CustomPainter {
  _DashedRectPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(12));
    final path = Path()..addRRect(rrect);
    const dashW = 6.0, gapW = 4.0;
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final end = (dist + dashW) > metric.length
            ? metric.length
            : dist + dashW;
        canvas.drawPath(metric.extractPath(dist, end), paint);
        dist += dashW + gapW;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRectPainter oldDelegate) =>
      oldDelegate.color != color;
}
