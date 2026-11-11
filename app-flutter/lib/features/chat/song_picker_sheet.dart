/// 在线搜歌（段三 · Step 8，对齐 Web music.js songPicker 在线 tab）：
/// 输入防抖搜索 GET /api/music/search?q=&limit=20 → {items:[{title,artist,album,
/// art,preview,dur}], error?}；行=封面+歌名+歌手+30 秒试听按钮；点行发送
/// song{title,artist,mid:'',src:preview,art,dur}（对齐 Web sendOnlineSong）。
/// 「从歌单选」入口不出现（主人定版，歌单属条目 6）。文案对照 Web：
/// 提示「接的是 Apple 公开曲库，听到的是 30 秒试听片段。搜中文歌名或英文都行。」
/// 搜索框 placeholder「搜歌名或歌手，例如：晚安」；空结果「没搜到，换个关键词试试。」
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/api/api_client.dart';
import '../../core/chat/chat_media.dart';
import '../../core/chat/chat_state.dart';

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

  @override
  void dispose() {
    _q.dispose();
    _previewPlayer?.dispose();
    super.dispose();
  }

  /// 30 秒试听（单播放器：点另一行切歌；再点当前行暂停）
  Future<void> _togglePreview(int i, MusicSearchResult it) async {
    if (it.preview.isEmpty) return;
    if (_previewingIdx == i && _previewPlayer != null) {
      final st = _previewPlayer!.playerState;
      if (st.playing) {
        await _previewPlayer!.pause();
      } else {
        await _previewPlayer!.play();
      }
      return;
    }
    try {
      final base = await ref.read(chatBaseProvider.future);
      final headers = await ref.read(mediaCookieHeadersProvider.future);
      final player = _previewPlayer ?? AudioPlayer();
      await player.setUrl(musicStreamUrl(base, it.preview), headers: headers);
      await player.play();
      _previewPlayer = player;
      setState(() => _previewingIdx = i);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('试听加载失败，稍后再试')));
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
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('音乐', style: theme.textTheme.titleMedium),
                Text('在线搜歌', style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
              ]),
            ),
            IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded)),
          ]),
        ),
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
        Divider(height: 12, color: theme.colorScheme.outlineVariant),
        Expanded(child: _results(theme)),
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
