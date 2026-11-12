/// 图片查看器基础版（条目 4 · 段一，决策 1）：
/// 全屏（PageView 同卡多图左右切换 + InteractiveViewer 双指缩放/拖动）+
/// 下载原文件（download 参数带 Cookie → 应用文档目录 downloads/）+ 关闭。
/// （替换上一行之前：先修 doc 角括号——download 参数说明改双下划线内联）共享元素转场等增强归条目 5。不加新依赖。
library;

import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/api/api_client.dart';
import '../../core/chat/chat_media.dart';
import 'package:dio/dio.dart' show Options, ResponseType;
import '../../core/chat/chat_models.dart';

/// 下载扩展名推断（mime → 常见后缀；未知回退 .bin）。
/// 抽成顶层纯函数：下载链涉及 widget/fake-async/文件 IO，把「映射规则」单独
/// 拿出来做单测，避免整条 UI 链在 flutter test 里挂死。
String mediaFileExtension(String mime) {
  const map = {
    'image/jpeg': '.jpg',
    'image/png': '.png',
    'image/webp': '.webp',
    'image/gif': '.gif',
    'image/heic': '.heic',
    'video/mp4': '.mp4',
    'video/webm': '.webm',
    'video/mov': '.mov',
    'audio/mp4': '.m4a',
    'audio/mpeg': '.mp3',
    'audio/wav': '.wav',
    'audio/aac': '.aac',
    'audio/ogg': '.ogg',
  };
  return map[mime.toLowerCase()] ?? '.bin';
}

class ImageViewerPage extends ConsumerStatefulWidget {
  const ImageViewerPage({super.key, required this.images, this.initialIndex = 0});
  final List<ChatMedia> images;
  final int initialIndex;

  @override
  ConsumerState<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends ConsumerState<ImageViewerPage> {
  late int _index = widget.initialIndex.clamp(0, widget.images.length - 1);
  bool _saving = false;

  String get _base => ref.watch(chatBaseProvider).valueOrNull ?? '';
  Map<String, String>? get _headers => ref.watch(mediaCookieHeadersProvider).valueOrNull;

  ChatMedia get _current => widget.images[_index];

  /// 扩展名推断委托顶层纯函数（便于单测）
  String _extOf(String mime) => mediaFileExtension(mime);

  /// 下载原文件（download 参数带 Cookie → 应用文档目录
  /// downloads 目录，文件名为 mid 加扩展名；无系统相册插件（禁新依赖），落应用目录并提示路径
  Future<void> _download() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final dio = await ref.read(dioProvider.future);
      final mid = _current.id;
      final rsp = await dio.get<List<int>>('/media/$mid',
          queryParameters: {'download': 'true'},
          options: Options(responseType: ResponseType.bytes));
      final dir = await getApplicationDocumentsDirectory();
      final downloads = Directory('${dir.path}${Platform.pathSeparator}downloads');
      if (!await downloads.exists()) await downloads.create(recursive: true);
      final path =
          '${downloads.path}${Platform.pathSeparator}$mid${_extOf(_current.mime)}';
      final file = File(path);
      await file.writeAsBytes(rsp.data ?? const []);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('已保存到本地：downloads/$mid${_extOf(_current.mime)}')));
      }
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
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        title: Text('${_index + 1} / ${widget.images.length}'),
        actions: [
          IconButton(
            tooltip: '下载原文件',
            onPressed: _saving ? null : _download,
            icon: _saving
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.download_rounded),
          ),
        ],
      ),
      body: widget.images.isEmpty
          ? const SizedBox()
          : PageView.builder(
              itemCount: widget.images.length,
              controller: PageController(initialPage: _index),
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) {
                final m = widget.images[i];
                return InteractiveViewer(
                  maxScale: 5,
                  child: Center(
                    child: CachedNetworkImage(
                      imageUrl: mediaUrl(_base, m.id),
                      httpHeaders: _headers,
                      fit: BoxFit.contain,
                      placeholder: (_, _) => const Center(
                          child: CircularProgressIndicator(color: Colors.white70)),
                      errorWidget: (_, _, _) => const Center(
                          child: Text('[图片加载失败]',
                              style: TextStyle(color: Colors.white70))),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// 打开查看器（卡片图片点击入口）
void openImageViewer(BuildContext context, List<ChatMedia> images,
    {int initialIndex = 0}) {
  if (images.isEmpty) return;
  Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) =>
          ImageViewerPage(images: images, initialIndex: initialIndex)));
}
