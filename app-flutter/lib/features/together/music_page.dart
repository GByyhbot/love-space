/// 共同歌单（条目 6 · 段 D，kind=music，定案：只试听）：
/// 列表（在线歌 body.song / 本地音频 media 附件两种形态都渲染）+ 搜索入单
/// （GET /api/music/search?q=&limit=20 → 加入歌单 POST body 带 song 字段）。
/// 🔴 试听走**下载优先**（语音同款）：Dio 全量 GET（无 Range）→ 本地缓存文件
/// → setFilePath 播本地——中转线（iepose）对原生播放器 Range 请求有已知缺陷
/// （语音栽过），绝不 setUrl 拉远程流；在线歌经 /api/music/stream?u= 转发。
/// 本地音频上传（Web musicForm 的 file input）Flutter 未做——入单只走在线搜索。
library;

import 'dart:io';

import 'package:dio/dio.dart' show Dio, Options, ResponseType;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/chat/chat_media.dart'
    show chatBaseProvider, uploadChatMedia, validateUploadFile;
import '../../core/together/together_data.dart';
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'together_controller.dart';
import 'tool_pages.dart' show ToolTile;

/// 音乐上传允许的扩展名（对齐 Web musicForm：建议 mp3，≤20MB——Web 口径）
const _musicUploadExts = ['mp3', 'm4a', 'wav', 'aac', 'ogg'];
const _musicUploadMaxBytes = 20 * 1024 * 1024;

class MusicPage extends ConsumerStatefulWidget {
  const MusicPage({super.key});
  @override
  ConsumerState<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends ConsumerState<MusicPage> {
  AudioPlayer? _player;
  String? _playingKey; // 正在试听的 key（'song:{rid}' / 'mid:{mid}'）
  String? _loadingKey;

  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(togetherControllerProvider.notifier).bootstrap());
  }

  @override
  void dispose() {
    try {
      _player?.dispose().timeout(const Duration(seconds: 3));
    } catch (_) {// 插件不可用（测试环境）时直接忽略
    }
    super.dispose();
  }

  /// 试听入口：先下载到本地缓存（全量 GET，无 Range），再 setFilePath 播本地。
  /// [urlPath] / [query]：在线歌 = /api/music/stream + {u: src}；
  /// 本地音频 = /media/{mid} + {preview: true}（与语音下载同口径）。
  Future<void> _preview({
    required String key,
    required String urlPath,
    required Map<String, String> query,
  }) async {
    if (_loadingKey != null) return; // 一次一个，防连点
    // 再点正在播的 → 停止
    if (_playingKey == key) {
      await _stopPlayer();
      setState(() => _playingKey = null);
      return;
    }
    setState(() => _loadingKey = key);
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.get(urlPath,
          queryParameters: query,
          options: Options(responseType: ResponseType.bytes));
      final code = r.statusCode ?? 0;
      if (code < 200 || code >= 300) {
        throw Exception('HTTP $code');
      }
      final bytes = (r.data as List?)?.cast<int>() ?? const <int>[];
      if (bytes.isEmpty) throw Exception('空响应体');
      final dir = await getTemporaryDirectory();
      final cacheDir = Directory('${dir.path}${Platform.pathSeparator}music_preview');
      if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
      final file = File(
          '${cacheDir.path}${Platform.pathSeparator}${key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}.m4a');
      await file.writeAsBytes(bytes, flush: true);
      final player = _player ??= AudioPlayer();
      // 播放器操作全部带超时守卫（语音同款）：插件不可用/挂起时不卡死调用方
      await player.stop().timeout(_playerTimeout);
      await player.setFilePath(file.path).timeout(_playerTimeout);
      setState(() => _playingKey = key);
      await player.play().timeout(_playerTimeout);
    } catch (e) {
      if (mounted) {
        ref.read(chatToastProvider.notifier).show('试听失败：$e',
            tone: ChatToastTone.error);
        setState(() => _playingKey = null);
      }
    } finally {
      if (mounted) setState(() => _loadingKey = null);
    }
  }

  static const _playerTimeout = Duration(seconds: 8);

  Future<void> _stopPlayer() async {
    try {
      await _player?.stop().timeout(_playerTimeout);
    } catch (_) {// 停止失败不阻断 UI（含插件不可用的测试环境）
    }
  }

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
            tooltip: loading ? '准备中…' : (playing ? '停止试听' : '试听'),
            onPressed: loading
                ? null
                : () => online
                    ? _preview(
                        key: key,
                        urlPath: '/api/music/stream',
                        query: {'u': (song['src'] ?? '').toString()},
                      )
                    : _preview(
                        key: key,
                        urlPath: '/media/$mid',
                        query: const {'preview': 'true'},
                      ),
            icon: loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(playing
                    ? Icons.stop_circle_rounded
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
