/// 在线搜歌（段三 · Step 8，对齐 Web music.js songPicker 在线 tab）：
/// 输入防抖搜索 GET /api/music/search?q=&limit=20 → {items:[{title,artist,album,
/// art,preview,dur}], error?}；行=封面+歌名+歌手+30 秒试听按钮；点行发送
/// song{title,artist,mid:'',src:preview,art,dur}（对齐 Web sendOnlineSong）。
/// 「从歌单选」入口不出现（主人定版，歌单属条目 6）。文案对照 Web：
/// 提示「接的是 Apple 公开曲库，听到的是 30 秒试听片段。搜中文歌名或英文都行。」
/// 搜索框 placeholder「搜歌名或歌手，例如：晚安」；空结果「没搜到，换个关键词试试。」
library;

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/chat/chat_models.dart';

import '../../core/api/api_client.dart';
import '../../core/chat/chat_media.dart';
import '../../core/chat/chat_state.dart';
import 'chat_toast.dart' show ChatToastTone, chatToastProvider;

class MusicSearchResult {
  const MusicSearchResult({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.art = '',
    this.preview = '',
    this.dur = 0,
  });
  final String title;
  final String artist;
  final String album;
  final String art;
  final String preview;
  final double dur;

  factory MusicSearchResult.fromJson(Map<String, dynamic> j) =>
      MusicSearchResult(
        title: (j['title'] ?? '').toString(),
        artist: (j['artist'] ?? '').toString(),
        album: (j['album'] ?? '').toString(),
        art: (j['art'] ?? '').toString(),
        preview: (j['preview'] ?? '').toString(),
        dur: (j['dur'] as num?)?.toDouble() ?? 0,
      );
}

/// 在线搜歌（GET /api/music/search?q=&limit=20；返回 items 与 error 文案）
Future<(List<MusicSearchResult>, String?)> searchOnlineMusic(
    Dio dio, String q) async {
  final r = await dio
      .get('/api/music/search', queryParameters: {'q': q, 'limit': 20});
  final data = (r.data ?? const {}) as Map;
  final items = ((data['items'] ?? const []) as List)
      .whereType<Map>()
      .map((e) => MusicSearchResult.fromJson(e.cast<String, dynamic>()))
      .toList();
  final error = data['error']?.toString();
  return (items, error);
}

Future<void> showSongPicker(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => const _SongSheet(),
  );
}

class _SongSheet extends ConsumerStatefulWidget {
  const _SongSheet();

  @override
  ConsumerState<_SongSheet> createState() => _SongSheetState();
}

class _SongSheetState extends ConsumerState<_SongSheet> {
  final _q = TextEditingController();
  List<MusicSearchResult> _items = const [];
  String? _error;
  bool _searching = false;
  int _seq = 0;
  AudioPlayer? _previewPlayer;
  int? _previewingIdx;
  StreamSubscription<PlayerState>? _previewSub; // 播完归位订阅
  // 共同歌单 tab（定版反转补齐：只做选择+发送，歌单管理归条目 6）
  String _tab = 'online';
  List<ChatRecord> _playlist = const [];
  bool _playlistLoading = false;

  @override
  void dispose() {
    _q.dispose();
    _previewSub?.cancel();
    _previewPlayer?.dispose();
    super.dispose();
  }

  /// 共同歌单：GET /api/records?kind=music（对齐 Web renderSongPane 歌单 tab）
  Future<void> _loadPlaylist() async {
    if (_playlistLoading) return;
    _playlistLoading = true;
    try {
      final dio = await ref.read(dioProvider.future);
      final r = await dio
          .get('/api/records', queryParameters: {'kind': 'music', 'limit': 100});
      final list = ((r.data ?? const []) as List)
          .whereType<Map>()
          .map((e) => ChatRecord.fromJson(e.cast<String, dynamic>()))
          .toList()
        ..sort((a, b) => b.created.compareTo(a.created));
      if (mounted) setState(() { _playlist = list; _playlistLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _playlistLoading = false);
    }
  }

  /// 歌单记录的音频媒体（对齐 Web songMedia：首个 audio/* 附件）
  ChatMedia? _songMedia(ChatRecord r) {
    for (final m in r.media) {
      if (m.mime.startsWith('audio/')) return m;
    }
    return null;
  }

  /// 发送歌单里的歌（对齐 Web sendSong body：song{title,artist,mid}）
  Future<void> _sendPlaylistSong(ChatRecord r) async {
    final m = _songMedia(r);
    _previewPlayer?.dispose();
    _previewPlayer = null;
    Navigator.of(context).pop();
    final title = r.body.title;
    final artist = r.body.content;
    await ref.read(chatControllerProvider.notifier).sendPlaylistSong(
          title: title.isEmpty
              ? '未命名'
              : (title.length > 120 ? title.substring(0, 120) : title),
          artist: artist.length > 200 ? artist.substring(0, 200) : artist,
          mid: m?.id ?? '',
        );
  }

  /// 歌单歌曲试听：mid 走 /media/{mid} preview（带 Cookie）。
  /// 🔴 下载优先（与语音/歌单同款）：downloadAudioToCache 全量 GET（无
  /// Range）→ 本地 → setFilePath——中转线对原生播放器 Range 请求有缺陷。
  /// 🔴 play() 不 await（just_audio 的 Future 在播完才完成——2.1.3 真机
  /// 假失败根因），播完经 playerStateStream 自动归位。
  Future<void> _togglePlaylistPreview(int i, ChatRecord r) async {
    final m = _songMedia(r);
    if (m == null) return;
    if (_previewingIdx == i && _previewPlayer != null) {
      final st = _previewPlayer!.playerState;
      if (st.playing) {
        await _previewPlayer!.pause();
      } else {
        unawaited(_previewPlayer!.play());
      }
      return;
    }
    try {
      final dio = await ref.read(dioProvider.future);
      final file = await downloadAudioToCache(dio,
          cacheKey: 'mid_${m.id}',
          urlPath: '/media/${m.id}',
          query: const {'preview': 'true'});
      final player = _previewPlayer ?? AudioPlayer();
      await player.stop().timeout(const Duration(seconds: 3));
      await player.setFilePath(file).timeout(const Duration(seconds: 15));
      _listenPreviewEnd(player);
      _previewPlayer = player;
      setState(() => _previewingIdx = i);
      unawaited(player.play());
    } catch (_) {
      if (mounted) {
        ref.read(chatToastProvider.notifier).show('试听加载失败，稍后再试',
            tone: ChatToastTone.error);
      }
    }
  }

  /// 订阅播完归位（processingState==completed）
  void _listenPreviewEnd(AudioPlayer player) {
    _previewSub?.cancel();
    _previewSub = player.playerStateStream.listen((st) {
      if (st.processingState == ProcessingState.completed && mounted) {
        _previewSub?.cancel();
        setState(() => _previewingIdx = null);
      }
    });
  }

  /// 30 秒试听（单播放器：点另一行切歌；再点当前行暂停）
  Future<void> _togglePreview(int i, MusicSearchResult it) async {
    if (it.preview.isEmpty) return;
    if (_previewingIdx == i && _previewPlayer != null) {
      final st = _previewPlayer!.playerState;
      if (st.playing) {
        await _previewPlayer!.pause();
      } else {
        unawaited(_previewPlayer!.play());
      }
      return;
    }
    try {
      final dio = await ref.read(dioProvider.future);
      final file = await downloadAudioToCache(dio,
          cacheKey: 'src_${it.preview.hashCode}',
          urlPath: '/api/music/stream',
          query: {'u': it.preview});
      final player = _previewPlayer ?? AudioPlayer();
      await player.stop().timeout(const Duration(seconds: 3));
      await player.setFilePath(file).timeout(const Duration(seconds: 15));
      _listenPreviewEnd(player);
      _previewPlayer = player;
      setState(() => _previewingIdx = i);
      unawaited(player.play());
    } catch (_) {
      if (mounted) {
        ref.read(chatToastProvider.notifier).show('试听加载失败，稍后再试',
            tone: ChatToastTone.error);
      }
    }
  }

  /// 480ms 防抖（对齐 Web runSongSearch 的 debounce）
  void _onQueryChanged(String v) {
    final seq = ++_seq;
    Future.delayed(const Duration(milliseconds: 480), () async {
      if (seq != _seq || !mounted) return;
      await _runSearch();
    });
  }

  Future<void> _runSearch() async {
    final q = _q.text.trim();
    if (q.isEmpty) {
      setState(() { _items = const []; _error = null; });
      return;
    }
    final seq = ++_seq;
    setState(() => _searching = true);
    try {
      final dio = await ref.read(dioProvider.future);
      final (items, error) = await searchOnlineMusic(dio, q);
      if (seq != _seq || !mounted) return;
      setState(() { _items = items; _error = error; _searching = false; });
    } catch (e) {
      if (seq != _seq || !mounted) return;
      setState(() { _error = errorDetail(e); _searching = false; });
    }
  }

  void _send(MusicSearchResult it) {
    if (it.preview.isEmpty) return;
    _previewPlayer?.dispose();
    _previewPlayer = null;
    Navigator.of(context).pop();
    ref.read(chatControllerProvider.notifier).sendOnlineSong(
          title: it.title.isEmpty ? '未命名' : it.title.substring(0, it.title.length.clamp(0, 120)),
          artist: it.artist.isEmpty ? '' : it.artist.substring(0, it.artist.length.clamp(0, 200)),
          src: it.preview,
          art: it.art,
          dur: it.dur,
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = MediaQuery.of(context).size.height * 0.62;
    return SizedBox(
      height: height,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(children: [
            Expanded(
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'online', label: Text('在线搜歌')),
                  ButtonSegment(value: 'playlist', label: Text('共同歌单')),
                ],
                selected: {_tab},
                onSelectionChanged: (s) {
                  setState(() => _tab = s.first);
                  if (s.first == 'playlist') _loadPlaylist();
                },
              ),
            ),
            IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded)),
          ]),
        ),
        if (_tab == 'online') ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _q,
              onChanged: _onQueryChanged,
              onSubmitted: (_) => _runSearch(),
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: '搜歌名或歌手，例如：晚安',
                prefixIcon: Icon(Icons.search_rounded),
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('接的是 Apple 公开曲库，听到的是 30 秒试听片段。搜中文歌名或英文都行。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ),
        ] else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('点一首直接发出去，右边的小按钮只在本机试听。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ),
        Divider(height: 12, color: theme.colorScheme.outlineVariant),
        Expanded(
            child: _tab == 'online' ? _results(theme) : _playlistList(theme)),
      ]),
    );
  }

  Widget _results(ThemeData theme) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return Center(child: Text(_error!, style: theme.textTheme.bodyMedium));
    }
    if (_q.text.trim().isEmpty) {
      return Center(child: Text('输入歌名或歌手，开始搜。',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline)));
    }
    if (_items.isEmpty) {
      return Center(child: Text('没搜到，换个关键词试试。',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline)));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final it = _items[i];
        final sub = [it.artist, it.album].where((s) => s.isNotEmpty).join(' · ');
        return ListTile(
          leading: _cover(it, theme),
          title: Text(it.title.isEmpty ? '未命名' : it.title,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(sub.isEmpty ? '在线试听' : sub,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => _send(it),
          trailing: IconButton(
            tooltip: '试听',
            onPressed:
                it.preview.isEmpty ? null : () => _togglePreview(i, it),
            icon: Icon(_previewingIdx == i
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded),
          ),
        );
      },
    );
  }

  Widget _playlistList(ThemeData theme) {
    if (_playlistLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_playlist.isEmpty) {
      return Center(
        child: Text('共同歌单还空着。去「我们」页的歌单添加歌曲，或用上面的「在线搜歌」直接发一首。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.outline)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: _playlist.length,
      itemBuilder: (context, i) {
        final r = _playlist[i];
        final m = _songMedia(r);
        final title = r.body.title;
        final sub = r.body.content;
        return ListTile(
          leading: _noteIcon(theme),
          title: Text(title.isEmpty ? '未命名' : title,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
              sub.isEmpty
                  ? (m != null ? '你们放进来的音频' : '没配音频文件')
                  : sub,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => _sendPlaylistSong(r),
          trailing: IconButton(
            tooltip: '试听',
            onPressed: m == null ? null : () => _togglePlaylistPreview(i, r),
            icon: Icon(_previewingIdx == i
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded),
          ),
        );
      },
    );
  }

  Widget _cover(MusicSearchResult it, ThemeData theme) {
    final base = ref.watch(chatBaseProvider).valueOrNull;
    if (base == null || it.art.isEmpty) return _noteIcon(theme);
    final headers = ref.watch(mediaCookieHeadersProvider).valueOrNull;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: musicStreamUrl(base, it.art),
        httpHeaders: headers,
        width: 46, height: 46, fit: BoxFit.cover,
        placeholder: (_, _) => _noteIcon(theme),
        errorWidget: (_, _, _) => _noteIcon(theme),
      ),
    );
  }

  Widget _noteIcon(ThemeData theme) => Container(
        width: 46, height: 46,
        decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(8)),
        child: Icon(Icons.music_note_rounded, color: theme.colorScheme.onPrimaryContainer),
      );
}
