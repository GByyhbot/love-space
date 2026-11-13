/// 共同歌单（条目 6 · 段 D，kind=music，定案：只试听）：
/// 列表（在线歌 body.song / 本地音频 media 附件两种形态都渲染）+ 搜索入单
/// + 本地音频上传（与 Web musicForm 同构管线，返修 2.1.4 补齐）。
/// 🔴 试听走**下载优先**（语音同款）：downloadAudioToCache 全量 GET（无 Range）
/// → 本地缓存文件 → setFilePath 播本地——中转线（iepose）对原生播放器 Range
/// 请求有已知缺陷（语音栽过），绝不 setUrl 拉远程流。
/// 🔴 play() 的 Future 在整段音频播完才完成（just_audio 契约）——绝不当
/// 「开始播放」的完成信号 await；播放态以 playerStateStream 为准
/// （2.1.3 真机假失败根因：8s 守卫误杀 30 秒试听）。
/// 播放呈现：底部控制条（歌名/播放暂停/停止/进度），播完或离页自动收起。
library;

import 'dart:async';

import 'package:dio/dio.dart' show Dio;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/chat/chat_media.dart'
    show chatBaseProvider, downloadAudioToCache, uploadChatMedia, validateUploadFile;
import '../../core/together/together_data.dart';
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'together_controller.dart';
import 'tool_pages.dart' show ToolTile;

/// 音乐上传允许的扩展名（对齐 Web musicForm：建议 mp3，≤20MB——Web 口径）
const _musicUploadExts = ['mp3', 'm4a', 'wav', 'aac', 'ogg'];
const _musicUploadMaxBytes = 20 * 1024 * 1024;

/// 底部播放条元数据
class _PreviewMeta {
  const _PreviewMeta({required this.key, required this.title, required this.artist});
  final String key;
  final String title;
  final String artist;
}

class MusicPage extends ConsumerStatefulWidget {
  const MusicPage({super.key});
  @override
  ConsumerState<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends ConsumerState<MusicPage> {
  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _playerSub;
  /// 当前试听（key + 展示信息）——底部播放条据此渲染；null=无播放
  _PreviewMeta? _previewMeta;
  String? _playingKey;
  String? _loadingKey;
  bool _paused = false; // 播放/暂停按钮态（playerStateStream 驱动）

  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(togetherControllerProvider.notifier).bootstrap());
  }

  @override
  void dispose() {
    _playerSub?.cancel();
    try {
      _player?.dispose().timeout(const Duration(seconds: 3));
    } catch (_) {// 插件不可用（测试环境）时直接忽略
    }
    super.dispose();
  }

  /// 🔴 play() 的 Future **在整段音频播完才完成**（just_audio 契约），绝不能
  /// 当「开始播放」的完成信号 await——2.1.3 真机假失败的根因（8s 守卫误杀
  /// 30 秒试听，声音在播却弹「试听失败」）。播放/暂停一律不 await，状态以
  /// playerStateStream 为准；超时守卫只留真正会完成的加载步骤。
  void _startPlay(AudioPlayer player) {
    unawaited(player.play());
  }

  /// 订阅播放状态：播完（processingState==completed）自动归位收条。
  void _listenPlayer(AudioPlayer player) {
    _playerSub?.cancel();
    _playerSub = player.playerStateStream.listen((st) {
      if (!mounted) return;
      setState(() => _paused = !st.playing);
      if (st.processingState == ProcessingState.completed) {
        _stopPlayer();
        if (mounted) {
          setState(() {
            _playingKey = null;
            _previewMeta = null;
            _paused = false;
          });
        }
      }
    });
  }

  /// 试听入口：先下载到本地缓存（全量 GET，无 Range），再 setFilePath 播本地。
  /// [urlPath] / [query]：在线歌 = /api/music/stream + {u: src}；
  /// 本地音频 = /media/{mid} + {preview: true}（与语音下载同口径）。
  Future<void> _preview({
    required String key,
    required String urlPath,
    required Map<String, String> query,
    required String title,
    required String artist,
  }) async {
    if (_loadingKey != null) return; // 一次一个，防连点
    // 再点正在播的 → 播放/暂停切换（不 stop，保进度）
    if (_playingKey == key && _player != null) {
      if (_paused) {
        _startPlay(_player!);
        setState(() => _paused = false);
      } else {
        unawaited(_player!.pause().timeout(_playerTimeout)
            .catchError((_) {}));
        setState(() => _paused = true);
      }
      return;
    }
    // 切歌：先停旧的
    await _stopPlayer();
    setState(() {
      _loadingKey = key;
      _previewMeta = _PreviewMeta(key: key, title: title, artist: artist);
    });
    try {
      final dio = await ref.read(api.dioProvider.future);
      final filePath = await downloadAudioToCache(dio,
          cacheKey: key, urlPath: urlPath, query: query);
      final player = _player ??= AudioPlayer();
      // 会完成的加载步骤才上超时守卫
      await player.stop().timeout(_stopTimeout);
      await player.setFilePath(filePath).timeout(_loadTimeout);
      await player.seek(Duration.zero).timeout(_stopTimeout);
      _listenPlayer(player);
      setState(() {
        _playingKey = key;
        _paused = false;
      });
      _startPlay(player);
    } catch (e) {
      if (mounted) {
        ref.read(chatToastProvider.notifier).show('试听失败：$e',
            tone: ChatToastTone.error);
        setState(() {
          _playingKey = null;
          _previewMeta = null;
        });
      }
    } finally {
      if (mounted) setState(() => _loadingKey = null);
    }
  }

  Future<void> _stopPlayer() async {
    _playerSub?.cancel();
    try {
      await _player?.stop().timeout(_stopTimeout);
      await _player?.seek(Duration.zero).timeout(_stopTimeout);
    } catch (_) {// 停止失败不阻断 UI
    }
  }

  /// stop/seek：秒级会完成；setFilePath：本地读文件+解码，放宽到 15s
  static const _stopTimeout = Duration(seconds: 3);
  static const _loadTimeout = Duration(seconds: 15);
  static const _playerTimeout = Duration(seconds: 8);

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(togetherControllerProvider);
    final base = ref.watch(chatBaseProvider).valueOrNull ?? '';
    final me = ref.watch(authProvider.notifier).me;
    final songs = ref.read(togetherControllerProvider.notifier).recordsOf('music');
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('共同歌单'),
        actions: [
          // 上传本地歌曲（Web musicForm 同构管线：POST /api/media → mid →
          // body.media；决策：与 Web 同构，本轮补齐——返修 2.1.4）
          IconButton(
            tooltip: '上传本地歌曲',
            onPressed: () => _pickAndUpload(),
            icon: const Icon(Icons.upload_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        tooltip: '搜歌入单',
        onPressed: () => _showSearch(context, ref),
        icon: const Icon(Icons.search_rounded),
        label: const Text('搜歌入单'),
      ),
      // 底部播放条（App 内播放器）：试听开始出现，播完/停止/离页自动收起
      bottomNavigationBar:
          (_previewMeta != null && _player != null)
              ? _PreviewBar(
                  player: _player!,
                  meta: _previewMeta!,
                  paused: _paused,
                  onTogglePlay: () {
                    if (_paused) {
                      if (_player != null) _startPlay(_player!);
                      setState(() => _paused = false);
                    } else {
                      unawaited(_player!.pause()
                          .timeout(_playerTimeout).catchError((_) {}));
                      setState(() => _paused = true);
                    }
                  },
                  onStop: () async {
                    await _stopPlayer();
                    if (mounted) {
                      setState(() {
                        _playingKey = null;
                        _previewMeta = null;
                        _paused = false;
                      });
                    }
                  },
                )
              : null,
      body: RefreshIndicator(
        onRefresh: () => ref.read(togetherControllerProvider.notifier).load(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
          children: [
            Text('把属于我们的歌，放在一起。试听片段约 30 秒（Apple 搜索接口），只试听不上传。',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
            const SizedBox(height: 8),
            if (songs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Column(children: [
                  Icon(Icons.music_note_rounded, size: 44, color: cs.outline),
                  const SizedBox(height: 12),
                  Text('还没有歌', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text('去放一首属于你们的第一首。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.outline)),
                ]),
              )
            else
              for (final r in songs)
                ToolTile(
                  record: r,
                  onEdit: () => _showEditMeta(context, ref, r),
                  child: _songBody(context, r, base, me),
                ),
            if (st.error != null) ...[
              const SizedBox(height: 10),
              Text(st.error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _songBody(
      BuildContext context, TogetherRecord r, String base, MeData? me) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final song = (r.body['song'] ?? {}) as Map;
    final online = (song['src'] ?? '').toString().isNotEmpty;
    final mid = r.audioMid;
    final key = online ? 'song:${r.id}' : 'mid:${r.id}:$mid';
    final artist = online
        ? (song['artist'] ?? '').toString()
        : (r.body['content'] ?? '').toString();
    final loading = _loadingKey == key;
    final playing = _playingKey == key;
    final canPlay = online || mid.isNotEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((r.body['title'] ?? '未命名').toString(),
                style: theme.textTheme.titleMedium),
            if (artist.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(artist,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.outline)),
              ),
          ]),
        ),
        if (canPlay)
          IconButton(
            tooltip: loading
                ? '准备中…'
                : (playing ? (_paused ? '继续试听' : '暂停试听') : '试听'),
            onPressed: loading
                ? null
                : () => online
                    ? _preview(
                        key: key,
                        urlPath: '/api/music/stream',
                        query: {'u': (song['src'] ?? '').toString()},
                        title: (r.body['title'] ?? '未命名').toString(),
                        artist: artist,
                      )
                    : _preview(
                        key: key,
                        urlPath: '/media/$mid',
                        query: const {'preview': 'true'},
                        title: (r.body['title'] ?? '未命名').toString(),
                        artist: artist,
                      ),
            icon: loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(playing && !_paused
                    ? Icons.pause_circle_rounded
                    : Icons.play_circle_rounded,
                    size: 30, color: cs.primary),
          ),
      ]),
      if (online && (song['dur'] ?? 0) > 0)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text('在线试听片段 · ${song['dur']} 秒',
              style: theme.textTheme.labelSmall?.copyWith(color: cs.outline)),
        ),
      if (!online && mid.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text('这首歌还没有音频文件。',
              style: theme.textTheme.labelSmall?.copyWith(color: cs.outline)),
        ),
      if (me == null) const SizedBox.shrink(),
    ]);
  }

  /// 选本地音频 → 上传 → 建记录（body.media=[mid]，Web musicForm 同构）。
  Future<void> _pickAndUpload() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: _musicUploadExts,
        withData: true,
      );
      final file = picked?.files.single;
      if (file == null) return; // 取消
      final bytes = file.bytes;
      if (bytes == null) {
        if (!mounted) return;
        ref.read(chatToastProvider.notifier).show('读取文件失败',
            tone: ChatToastTone.error);
        return;
      }
      if (!mounted) return;
      await _uploadAndCreate(file.name, bytes);
    } catch (e) {
      if (!mounted) return;
      ref.read(chatToastProvider.notifier).show('选择文件失败：$e',
          tone: ChatToastTone.error);
    }
  }

  /// 选定文件后的上传建单流程：本地预检 → 弹表单确认歌名 → [uploadMusicToPlaylist]。
  Future<void> _uploadAndCreate(String filename, List<int> bytes) async {
    final precheck = validateUploadFile(filename, bytes.length);
    if (precheck != null) {
      ref.read(chatToastProvider.notifier).show(precheck,
          tone: ChatToastTone.error);
      return;
    }
    if (bytes.length > _musicUploadMaxBytes) {
      ref.read(chatToastProvider.notifier).show('音频超过 20 MB，换个小一点的吧',
          tone: ChatToastTone.error);
      return;
    }
    if (!mounted) return;
    // 弹表单确认歌名/想说的话（歌名预填文件名去扩展）
    final defaultTitle = filename.replaceAll(RegExp(r'\.[^.]+$'), '');
    final titleCtrl = TextEditingController(text: defaultTitle);
    final contentCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('上传本地歌曲'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('已选：$filename（${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB）',
                  style: Theme.of(dctx).textTheme.bodySmall),
              TextFormField(
                controller: titleCtrl,
                maxLength: 120,
                decoration: const InputDecoration(
                    labelText: '歌名', counterText: ''),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? '歌名不能为空' : null,
              ),
              TextFormField(
                controller: contentCtrl,
                maxLength: 200,
                decoration: const InputDecoration(
                    labelText: '歌手，或者想说的话', counterText: ''),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.of(dctx).pop(true);
                }
              },
              child: const Text('上传并放入歌单')),
        ],
      ),
    );
    if (saved != true) return;
    if (!mounted) return;
    await uploadMusicToPlaylist(ProviderScope.containerOf(context),
        filename: filename, bytes: bytes, title: titleCtrl.text.trim(),
        content: contentCtrl.text.trim());
  }

/// 搜索入单：GET /api/music/search?q=&limit=20（服务端缓存 10 分钟，main.py:1780）。
  /// 返回 items: {title, artist, album, preview, art, dur}。
  /// 加入歌单 = POST /api/records kind=music，body 带 song 字段（clean_body
  /// permitted 含 song，main.py:949-973 会校验并归一化 src/art 白名单）。
  Future<void> _showSearch(BuildContext context, WidgetRef ref) async {
    final queryCtrl = TextEditingController();
    final results = <Map<String, String>>[];
    var searching = false;
    String? tip;
    await showDialog<void>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDialogState) => AlertDialog(
          title: const Text('搜歌入单'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: queryCtrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: '歌名或歌手'),
                onSubmitted: (_) async {
                  final q = queryCtrl.text.trim();
                  if (q.isEmpty || searching) return;
                  setDialogState(() {
                    searching = true;
                    tip = null;
                  });
                  try {
                    final dio = await ref.read(api.dioProvider.future);
                    final r = await dio.get('/api/music/search',
                        queryParameters: {'q': q, 'limit': 20});
                    results
                      ..clear()
                      ..addAll([
                        for (final e in ((r.data as Map)['items'] ?? []) as List)
                          if (e is Map)
                            {
                              for (final k in ['title', 'artist', 'album',
                                    'preview', 'art', 'dur'])
                                if (e[k] != null) k: e[k].toString(),
                            },
                      ]);
                    tip = results.isEmpty ? '没搜到，换个关键词试试。' : null;
                  } catch (e) {
                    tip = '搜索失败：$e';
                  }
                  setDialogState(() => searching = false);
                },
              ),
              const SizedBox(height: 8),
              if (searching)
                const Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator()),
              if (!searching && tip != null)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(tip!,
                        style: Theme.of(dctx).textTheme.bodySmall)),
              if (!searching)
                for (final it in results.take(20))
                  ListTile(
                    dense: true,
                    title: Text((it['title'] ?? '').toString(),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text((it['artist'] ?? '').toString(),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      tooltip: '加入歌单',
                      icon: const Icon(Icons.playlist_add_rounded),
                      onPressed: () async {
                        final err = await ref
                            .read(togetherControllerProvider.notifier)
                            .add('music', {
                          'title': (it['title'] ?? '').toString(),
                          'content': (it['artist'] ?? '').toString(),
                          'song': {
                            'title': (it['title'] ?? '').toString(),
                            'artist': (it['artist'] ?? '').toString(),
                            'src': (it['preview'] ?? '').toString(),
                            'art': (it['art'] ?? '').toString(),
                            'dur': int.tryParse(it['dur'] ?? '') ?? 0,
                          },
                        });
                        if (!dctx.mounted) return;
                        ref.read(chatToastProvider.notifier).show(
                            err == null ? '已经放进歌单了' : '添加失败：$err',
                            tone: err == null
                                ? ChatToastTone.success
                                : ChatToastTone.error);
                        if (err == null) Navigator.of(dctx).pop();
                      },
                    ),
                  ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(dctx).pop(),
                child: const Text('关闭')),
          ],
        ),
      ),
    );
  }

  /// 编辑歌名/歌手（本地音频上传 Flutter 未做，编辑不提供媒体入口——与提问
  /// 禁附件同口径；Web musicForm 的换文件能力归后续段）。
  Future<void> _showEditMeta(
      BuildContext context, WidgetRef ref, TogetherRecord record) async {
    final b = record.body;
    final titleCtrl = TextEditingController(text: (b['title'] ?? '').toString());
    final contentCtrl = TextEditingController(text: (b['content'] ?? '').toString());
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('编辑这首歌'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(
                controller: titleCtrl,
                maxLength: 120,
                decoration: const InputDecoration(
                    labelText: '歌名', counterText: ''),
                validator: (v) => (v ?? '').trim().isEmpty ? '歌名不能为空' : null,
              ),
              TextFormField(
                controller: contentCtrl,
                maxLength: 200,
                decoration: const InputDecoration(
                    labelText: '歌手，或者想说的话', counterText: ''),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.of(dctx).pop(true);
                }
              },
              child: const Text('保存')),
        ],
      ),
    );
    if (saved != true) return;
    final err = await ref
        .read(togetherControllerProvider.notifier)
        .edit(record.id, 'music', record.body, {
      'title': titleCtrl.text.trim(),
      'content': contentCtrl.text.trim(),
    });
    if (!context.mounted) return;
    ref.read(chatToastProvider.notifier).show(
        err == null ? '已保存' : '保存失败：$err',
        tone: err == null ? ChatToastTone.success : ChatToastTone.error);
  }
}

/// 选定文件后的上传建单（公开以便单测；_pickAndUpload 的表单确认后调这里）：
/// POST /api/media（multipart，App 与 Web 同构管线）→ mid →
/// POST /api/records kind=music body.media=[mid]。
/// 🔴 单测注意：Dio multipart POST 在 FakeAsync 测试环境会挂起（套件从未
/// 测过该路径），测试须以 [upload] 桩替换真实管线；真实管线=uploadChatMedia
/// （与聊天上传同构、真机已验证）。
Future<void> uploadMusicToPlaylist(
    ProviderContainer container,
    {required String filename,
    required List<int> bytes,
    required String title,
    required String content,
    Future<String> Function(Dio dio, String filename, List<int> bytes)? upload}) async {
  container.read(chatToastProvider.notifier).show('正在上传…',
      tone: ChatToastTone.info);
  final dio = await container.read(api.dioProvider.future);
  try {
    final mid = await (upload ?? uploadChatMedia)(dio, filename, bytes);
    final err = await container
        .read(togetherControllerProvider.notifier)
        .add('music', {
      'title': title,
      'content': content,
      'media': [mid],
    });
    container.read(chatToastProvider.notifier).show(
        err == null ? '已经放进歌单了' : '添加失败：$err',
        tone: err == null ? ChatToastTone.success : ChatToastTone.error);
  } catch (e) {
    container.read(chatToastProvider.notifier).show('上传失败：$e',
        tone: ChatToastTone.error);
  }
}

String _fmtDur(Duration d) {
  final m = d.inMinutes, s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// 底部播放条（App 内播放器，本包底线实现）：歌名/歌手 + 进度 + 播放暂停 +
/// 停止。数据全部来自播放器状态流（position/playerState），不自算。
/// 通知栏媒体显示（audio_service 等重型件）未引入——方案与代价另报等主人定。
class _PreviewBar extends StatelessWidget {
  const _PreviewBar({
    required this.player,
    required this.meta,
    required this.paused,
    required this.onTogglePlay,
    required this.onStop,
  });
  final AudioPlayer player;
  final _PreviewMeta meta;
  final bool paused;
  final VoidCallback onTogglePlay;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dur = player.duration ?? Duration.zero;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: SafeArea(
        top: false,
        child: StreamBuilder<Duration>(
          stream: player.positionStream,
          builder: (context, snap) {
            final pos = snap.data ?? Duration.zero;
            final ratio = dur > Duration.zero
                ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
                : 0.0;
            return Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(meta.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall),
                        if (meta.artist.isNotEmpty)
                          Text(meta.artist,
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: cs.outline)),
                      ]),
                ),
                Text('${_fmtDur(pos)} / ${_fmtDur(dur)}',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: cs.outline)),
              ]),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: ratio, minHeight: 5),
              ),
              const SizedBox(height: 4),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                IconButton(
                  tooltip: paused ? '继续播放' : '暂停',
                  onPressed: onTogglePlay,
                  icon: Icon(paused
                      ? Icons.play_arrow_rounded
                      : Icons.pause_rounded),
                ),
                IconButton(
                  tooltip: '停止',
                  onPressed: onStop,
                  icon: const Icon(Icons.stop_rounded),
                ),
              ]),
            ]);
          },
        ),
      ),
    );
  }
}
