/// 媒体气泡组件（段二 · Step 5 渲染）：
/// · 图片：/media/{mid}?preview=true（cached_network_image，httpHeaders 带 Cookie，
///   缓存键=URL 天然含 mid+preview）；加载失败中性占位绝不崩；
/// · 视频：poster 封面 + 播放角标 → 点击全屏播放（video_player_page）；
/// · 语音：voice chip（时长 + 点击整 chip 播放，对齐 Web voice-chip）；
/// · 贴纸：内置包走公开静态（无需 Cookie），webm 循环视频 / 其余静态图；
///   ListView.builder 惰性构建 = 可视区才解码/播放，滚出屏 item 被 dispose 即停
///   （对齐 Web lazyStickerVideos 的 IO 门控语义）。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

import '../../core/chat/chat_media.dart';
import '../../core/chat/chat_models.dart';
import '../../core/chat/map_launcher.dart';
import 'video_player_page.dart';

/// 统一的媒体中性占位（加载中 / 失败 / 数据未就绪）
class MediaPlaceholder extends StatelessWidget {
  const MediaPlaceholder({super.key, this.label = '[图片]', this.size = 96});
  final String label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(label,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline)),
    );
  }
}

/// 图片媒体（preview 图；点按行为段三再扩展大图浏览）
class MediaImageView extends ConsumerWidget {
  const MediaImageView({super.key, required this.mid, this.size = 180});
  final String mid;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final base = ref.watch(chatBaseProvider).valueOrNull;
    if (base == null) return MediaPlaceholder(size: size);
    final headers = ref.watch(mediaCookieHeadersProvider).valueOrNull;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: CachedNetworkImage(
        imageUrl: mediaUrl(base, mid),
        httpHeaders: headers,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, _) => MediaPlaceholder(size: size),
        errorWidget: (_, _, _) => MediaPlaceholder(size: size),
      ),
    );
  }
}

/// 视频卡片：poster 封面 + 播放角标（对齐 Web media-video：poster + play-badge），
/// 点击进全屏播放页
class VideoCardView extends ConsumerWidget {
  const VideoCardView({super.key, required this.mid, this.size = 200});
  final String mid;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final base = ref.watch(chatBaseProvider).valueOrNull;
    if (base == null) return MediaPlaceholder(label: '[视频]', size: size);
    final headers = ref.watch(mediaCookieHeadersProvider).valueOrNull;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => VideoPlayerPage(mid: mid))),
      child: Stack(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: CachedNetworkImage(
            imageUrl: mediaUrl(base, mid, preview: false, poster: true),
            httpHeaders: headers,
            width: size,
            height: size,
            fit: BoxFit.cover,
            placeholder: (_, _) => MediaPlaceholder(label: '[视频]', size: size),
            errorWidget: (_, _, _) => MediaPlaceholder(label: '[视频]', size: size),
          ),
        ),
        Positioned.fill(
          child: Center(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: const BoxDecoration(
                  color: Colors.black45, shape: BoxShape.circle),
              child: const Icon(Icons.play_arrow_rounded,
                  color: Colors.white, size: 30),
            ),
          ),
        ),
      ]),
    );
  }
}

/// 语音 chip：时长 + 点击整 chip 播放/暂停（对齐 Web voice-chip；时长未加载显示 --）
class VoiceChipView extends ConsumerStatefulWidget {
  const VoiceChipView({super.key, required this.mid});
  final String mid;

  @override
  ConsumerState<VoiceChipView> createState() => _VoiceChipViewState();
}

class _VoiceChipViewState extends ConsumerState<VoiceChipView> {
  AudioPlayer? _player;
  bool _playing = false;
  Duration? _duration;
  bool _loading = false;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_loading) return;
    var player = _player;
    if (player == null) {
      setState(() => _loading = true);
      try {
        final base = await ref.read(chatBaseProvider.future);
        final headers = await ref.read(mediaCookieHeadersProvider.future);
        player = AudioPlayer();
        final duration =
            await player.setUrl(mediaUrl(base, widget.mid), headers: headers);
        player.playerStateStream.listen((s) {
          if (mounted) setState(() => _playing = s.playing);
        });
        _player = player;
        if (mounted) setState(() => _duration = duration);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('语音加载失败，稍后再试')));
        }
        return;
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    }
    if (_playing) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  String get _durText {
    final d = _duration;
    if (d == null) return '--';
    final mm = d.inMinutes.toString();
    final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: _toggle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_playing ? Icons.pause_rounded : Icons.volume_up_rounded,
              size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text(_durText, style: theme.textTheme.bodyMedium),
        ]),
      ),
    );
  }
}

/// 贴纸（无气泡整条渲染）：内置包 = 公开静态（无需 Cookie）；
/// 自定义表情 = 媒体 id（需 Cookie）。webm → 循环视频，其余静态图。
class StickerView extends ConsumerWidget {
  const StickerView({super.key, required this.sticker});
  final ChatStickerVisual sticker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final base = ref.watch(chatBaseProvider).valueOrNull;
    if (base == null) return const MediaPlaceholder(label: '[贴纸]');
    final url = sticker.mid != null
        ? mediaUrl(base, sticker.mid!)
        : '$base${sticker.path ?? ''}';
    if (sticker.isVideo) {
      // 自定义表情 video/webm 走 /media/{mid} 需要 Cookie；内置包 /static 公开不带
      return StickerVideoView(
          url: url,
          headers:
              sticker.mid != null ? ref.watch(mediaCookieHeadersProvider).valueOrNull : null);
    }
    final headers = sticker.mid != null
        ? ref.watch(mediaCookieHeadersProvider).valueOrNull
        : null; // 公开静态无需 Cookie
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: CachedNetworkImage(
        imageUrl: url,
        httpHeaders: headers,
        width: 140,
        height: 140,
        fit: BoxFit.contain,
        placeholder: (_, _) => const MediaPlaceholder(label: '[贴纸]'),
        errorWidget: (_, _, _) => const MediaPlaceholder(label: '[贴纸]'),
      ),
    );
  }
}

/// webm 循环视频贴纸：initState 才初始化播放器（ListView.builder 惰性构建，
/// 滚出屏 dispose → 解码停止），对齐 Web「可视区才解码/播放」。
/// [headers] 供 /media/{mid} 自定义表情带 Cookie；/static 内置包传 null。
class StickerVideoView extends ConsumerStatefulWidget {
  const StickerVideoView({super.key, required this.url, this.headers});
  final String url;
  final Map<String, String>? headers;

  @override
  ConsumerState<StickerVideoView> createState() => _StickerVideoState();
}

class _StickerVideoState extends ConsumerState<StickerVideoView> {
  VideoPlayerController? _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    final c = VideoPlayerController.networkUrl(
        Uri.parse(widget.url),
        httpHeaders: widget.headers ?? const <String, String>{});
    _controller = c;
    try {
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      await c.setLooping(true);
      await c.setVolume(0);
      await c.play();
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _ready = false);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready || _controller == null) {
      return const MediaPlaceholder(label: '[贴纸]', size: 140);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 140,
        height: 140,
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: _controller!.value.size.width,
            height: _controller!.value.size.height,
            child: VideoPlayer(_controller!),
          ),
        ),
      ),
    );
  }
}

/// 歌卡（段三 · Step 8，对齐 Web songCardMarkup 语义）：封面 + 歌名 + 歌手 +
/// 30 秒试听（同源 /api/music/stream 转发，just_audio 带 Cookie 头）。
/// 点击卡片除按钮区外不触发播放（对齐 Web：试听只走右侧小按钮）。
class SongCardView extends ConsumerStatefulWidget {
  const SongCardView({super.key, required this.song});
  final ChatSong song;

  @override
  ConsumerState<SongCardView> createState() => _SongCardViewState();
}

class _SongCardViewState extends ConsumerState<SongCardView> {
  AudioPlayer? _player;
  bool _playing = false;
  bool _loading = false;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    // Web 口径：mid（歌单本地音频）优先于 src（在线 30s 试听）
    final hasMid = widget.song.mid.isNotEmpty;
    final hasSrc = widget.song.src.isNotEmpty;
    if ((!hasMid && !hasSrc) || _loading) return;
    var player = _player;
    if (player == null) {
      setState(() => _loading = true);
      try {
        final base = await ref.read(chatBaseProvider.future);
        final headers = await ref.read(mediaCookieHeadersProvider.future);
        player = AudioPlayer();
        await player.setUrl(
            hasMid
                ? mediaUrl(base, widget.song.mid)
                : musicStreamUrl(base, widget.song.src),
            headers: headers);
        player.playerStateStream.listen((st) {
          if (mounted) setState(() => _playing = st.playing);
        });
        _player = player;
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('试听加载失败，稍后再试')));
        }
        return;
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    }
    if (_playing) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = ref.watch(chatBaseProvider).valueOrNull;
    final headers = ref.watch(mediaCookieHeadersProvider).valueOrNull;
    return Container(
      width: 230,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: (base != null && widget.song.art.isNotEmpty)
              ? CachedNetworkImage(
                  imageUrl: musicStreamUrl(base, widget.song.art),
                  httpHeaders: headers,
                  width: 46, height: 46, fit: BoxFit.cover,
                  placeholder: (_, _) => _noteIcon(theme),
                  errorWidget: (_, _, _) => _noteIcon(theme))
              : _noteIcon(theme),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min, children: [
            Text(widget.song.title,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall),
            Text(widget.song.artist,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ]),
        ),
        IconButton(
          tooltip: '试听',
          onPressed: _toggle,
          icon: Icon(_loading
              ? Icons.hourglass_top_rounded
              : (_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              color: theme.colorScheme.primary),
        ),
      ]),
    );
  }

  Widget _noteIcon(ThemeData theme) => Container(
        width: 46, height: 46,
        decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer, borderRadius: BorderRadius.circular(8)),
        child: Icon(Icons.music_note_rounded, color: theme.colorScheme.onPrimaryContainer),
      );
}

/// 位置卡片（段三 · Step 8，对齐 Web chat-loc）：「位置 · 点开用高德地图看」
/// → androidamap:// scheme，未装回退网页地图（openAmap）
class LocationCardView extends StatelessWidget {
  const LocationCardView({super.key, required this.location});
  final ChatLocation location;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => openAmap(location.lat, location.lng),
      child: Container(
        width: 230,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8)),
            child: Icon(Icons.location_on_rounded, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min, children: [
            Text('位置', style: theme.textTheme.titleSmall),
            Text('点开用高德地图看',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ])),
          Icon(Icons.chevron_right_rounded, color: theme.colorScheme.outline),
        ]),
      ),
    );
  }
}
