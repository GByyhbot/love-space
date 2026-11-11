/// 全屏视频播放页（段二）：/media/{mid}?preview=true（H.264 preview.mp4，
/// httpHeaders 带 Cookie）。极简控制：点画面播放/暂停 + 底部进度条，返回即释放。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/chat/chat_media.dart';

class VideoPlayerPage extends ConsumerStatefulWidget {
  const VideoPlayerPage({super.key, required this.mid});
  final String mid;

  @override
  ConsumerState<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends ConsumerState<VideoPlayerPage> {
  VideoPlayerController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    try {
      final base = await ref.read(chatBaseProvider.future);
      final headers = await ref.read(mediaCookieHeadersProvider.future);
      final c = VideoPlayerController.networkUrl(
          Uri.parse(mediaUrl(base, widget.mid)),
          httpHeaders: headers);
      _controller = c;
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      await c.play();
      setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = '视频加载失败，稍后再试');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('视频播放'),
      ),
      body: Center(
        child: _error != null
            ? Text(_error!, style: const TextStyle(color: Colors.white70))
            : c == null || !c.value.isInitialized
                ? const CircularProgressIndicator(color: Colors.white70)
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    GestureDetector(
                      onTap: () =>
                          setState(() => c.value.isPlaying ? c.pause() : c.play()),
                      child: AspectRatio(
                        aspectRatio: c.value.aspectRatio,
                        child: VideoPlayer(c),
                      ),
                    ),
                    VideoProgressIndicator(c, allowScrubbing: true,
                        colors: const VideoProgressColors(
                            playedColor: Color(0xFFE56B8C))),
                  ]),
      ),
    );
  }
}
