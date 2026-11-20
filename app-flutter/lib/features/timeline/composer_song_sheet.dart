/// 2.4.12 条目一：发布器「音乐」入口选择单。
/// 底部弹层 + 页签分段器（库音乐 | 在线音乐），与 2.4.1 showFormSheet 家族同语言。
/// 库音乐 = kind='music' 记录（togetherControllerProvider 同源 provider，不新建请求）；
/// 在线音乐 = 复用 chat/song_picker_sheet.dart 的 searchOnlineMusic（GET /api/music/search）。
/// 返回 song Map {title,artist,mid,src,art,dur}；在线歌点选走既有落库路径
/// （togetherController.add('music', …)）——在线歌必须先落成 music 记录再被动态引用。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/theme/tokens.dart';
import '../chat/song_picker_sheet.dart' show MusicSearchResult, searchOnlineMusic;
import '../together/together_controller.dart' show togetherControllerProvider;

/// 打开选择单，返回选中的 song Map（null=取消/移除由调用方处理）。
Future<Map<String, dynamic>?> showComposerSongSheet(BuildContext context) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg))),
    builder: (_) => const _ComposerSongSheet(),
  );
}

class _ComposerSongSheet extends ConsumerStatefulWidget {
  const _ComposerSongSheet();

  @override
  ConsumerState<_ComposerSongSheet> createState() => _ComposerSongSheetState();
}

class _ComposerSongSheetState extends ConsumerState<_ComposerSongSheet> {
  int _tab = 0; // 0=库音乐 1=在线音乐
  final _query = TextEditingController();
  List<MusicSearchResult> _online = const [];
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    try {
      final dio = await ref.read(api.dioProvider.future);
      final (items, err) = await searchOnlineMusic(dio, q);
      if (mounted) {
        setState(() {
          _online = items;
          _error = err;
          _searching = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '搜索失败，稍后再试';
          _searching = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final songs = ref.watch(togetherControllerProvider).records
        .where((r) => r.kind == 'music')
        .toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.92,
      minChildSize: 0.4,
      builder: (context, scrollCtrl) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(children: [
          Text('选一首歌', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          // 页签分段器
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppRadius.sm)),
            child: Row(children: [
              Expanded(child: _tabButton(0, '库音乐')),
              Expanded(child: _tabButton(1, '在线音乐')),
            ]),
          ),
          const SizedBox(height: 10),
          if (_tab == 1)
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _query,
                  decoration: InputDecoration(
                    hintText: '搜歌名或歌手，例如：晚安',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _searching ? null : _search,
                child: Text(_searching ? '搜索中' : '搜索'),
              ),
            ]),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(color: cs.error))),
          const SizedBox(height: 8),
          Expanded(
            child: _tab == 0
                ? _libraryList(songs, scrollCtrl)
                : _onlineList(scrollCtrl),
          ),
        ]),
      ),
    );
  }

  Widget _tabButton(int idx, String label) => ChoiceChip(
        label: Center(child: Text(label)),
        selected: _tab == idx,
        onSelected: (_) => setState(() => _tab = idx),
      );

  Widget _libraryList(List records, ScrollController ctrl) {
    if (records.isEmpty) {
      return const Center(child: Text('歌单还是空的，先去歌单页加几首吧。'));
    }
    final filtered = _query.text.trim().isEmpty
        ? records
        : records.where((r) => (r.body['title'] ?? '').toString()
            .contains(_query.text.trim())).toList();
    return ListView.builder(
      controller: ctrl,
      itemCount: filtered.length,
      itemBuilder: (_, i) {
        final r = filtered[i];
        final song = (r.body['song'] ?? {}) as Map;
        final online = (song['src'] ?? '').toString().isNotEmpty;
        final artist = online
            ? (song['artist'] ?? '').toString()
            : (r.body['content'] ?? '').toString();
        final result = Map<String, dynamic>.from(song);
        result['title'] ??= (r.body['title'] ?? '').toString();
        result['artist'] ??= artist;
        if (!online) result['mid'] ??= r.audioMid;
        result.putIfAbsent('src', () => '');
        result.putIfAbsent('art', () => '');
        result.putIfAbsent('dur', () => 0);
        return ListTile(
          title: Text(result['title'].toString(), maxLines: 1),
          subtitle: Text(artist, maxLines: 1),
          onTap: () => Navigator.of(context).pop(result),
        );
      },
    );
  }

  Widget _onlineList(ScrollController ctrl) {
    if (_online.isEmpty) {
      return const Center(child: Text('搜一首歌，点选即挂到动态上。'));
    }
    return ListView.builder(
      controller: ctrl,
      itemCount: _online.length,
      itemBuilder: (_, i) {
        final it = _online[i];
        return ListTile(
          title: Text(it.title, maxLines: 1),
          subtitle: Text(it.artist, maxLines: 1),
          onTap: () async {
            // 先走既有落库路径生成/命中 music 记录（裁定：在线歌先落库再引用）
            final err = await ref.read(togetherControllerProvider.notifier).add('music', {
              'title': it.title,
              'content': it.artist,
              'song': {
                'title': it.title, 'artist': it.artist,
                'src': it.preview, 'art': it.art, 'dur': it.dur.round(),
              },
            });
            if (err != null && mounted) {
              setState(() => _error = err);
              return;
            }
            if (mounted) {
              Navigator.of(context).pop({
                'title': it.title, 'artist': it.artist, 'mid': '',
                'src': it.preview, 'art': it.art, 'dur': it.dur.round(),
              });
            }
          },
        );
      },
    );
  }
}
