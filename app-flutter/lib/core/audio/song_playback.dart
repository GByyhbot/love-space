/// 2.4.12 条目五：全局单一歌曲播放引擎 + 通知栏/锁屏媒体控制。
///
/// 架构口径（主人裁定）：
/// · 歌单页 / 动态歌曲卡 / 聊天歌曲卡三处共用本引擎，同一时刻只有一首歌在播
///   （「歌曲卡自持 player」旧口径作废）；
/// · 与语音互斥：播歌先停语音、播语音先停歌（voicePlaybackProvider.stop()）；
/// · 队列：从歌单点播 = 当前列表顺序（next/prev/播完自动下一首）；
///   从动态/聊天歌曲卡点播 = 单曲模式（无队列，next/prev 置灰，播完即止）；
///   在线 30 秒试听同样走引擎，播完即止不自动连播；
/// · 通知栏/锁屏走 audio_service + just_audio_background（MediaSession/MediaStyle），
///   引擎是播放状态单一事实源，通知按钮与 App 内播放按钮双向同步；
/// · 后台续播限完整音频（本地上传 + 投放入库的 mid）——download-first 家法：
///   Dio 全量 GET → song_cache → setFilePath，不依赖网络。
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../api/api_client.dart' as api;
import '../chat/chat_media.dart' show downloadAudioToCache;
import '../chat/chat_models.dart' show ChatSong;
import '../../features/chat/voice_playback.dart' show voicePlaybackProvider;

/// 播放项：媒体 id（本地完整音频）或在线试听 src（30 秒）。
class SongItem {
  const SongItem({
    required this.title,
    required this.artist,
    this.mid = '',
    this.src = '',
    this.art = '',
    this.duration = Duration.zero,
  });

  final String title;
  final String artist;
  final String mid;
  final String src;
  final String art;
  final Duration duration;

  bool get isOnline => mid.isEmpty && src.isNotEmpty;

  MediaItem toMediaItem() => MediaItem(
        id: mid.isNotEmpty ? 'mid:$mid' : 'src:$src',
        title: title,
        artist: artist,
        artUri: art.isEmpty ? null : Uri.parse(art),
        duration: duration == Duration.zero ? null : duration,
        playable: true,
      );
}

/// 引擎状态（UI 只读这个，不各自持 player）。
class SongPlaybackState {
  const SongPlaybackState({
    this.current,
    this.playing = false,
    this.loading = false,
    this.index = -1,
    this.queueLength = 0,
    this.queueMode = false,
  });

  final SongItem? current;
  final bool playing;
  final bool loading;
  final int index;
  final int queueLength;
  final bool queueMode;

  bool get canSkip => queueMode && queueLength > 1;
}

/// 全局引擎：单例（由 [songPlaybackProvider] 持有），底层一个 AudioPlayer。
/// 通知栏由 audio_service 的 JustAudioBackground handler 驱动（见 entrypoint 注入）。
class SongPlaybackController extends Notifier<SongPlaybackState> {
  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration?>? _doneSub;
  List<SongItem> _queue = const [];
  bool _queueMode = false;
  bool _busy = false;
  BaseAudioHandler? _handler;

  @override
  SongPlaybackState build() {
    ref.onDispose(_teardown);
    return const SongPlaybackState();
  }

  /// 注入 audio_service handler（由 main 启动后调用一次），用于通知状态同步。
  void attachHandler(BaseAudioHandler handler) => _handler = handler;

  /// UI 只读访问引擎持有的唯一 player（进度条 StreamBuilder 用），
  /// 严禁外部 setFilePath/play——所有播控必须走本引擎方法。
  AudioPlayer? get player => _player;

  Future<void> _teardown() async {
    await _stateSub?.cancel();
    await _doneSub?.cancel();
    await _player?.dispose();
    _player = null;
  }

  AudioPlayer get _ensurePlayer {
    final p = _player ??= AudioPlayer();
    _stateSub ??= p.playerStateStream.listen((st) {
      if (st.processingState == ProcessingState.completed) {
        unawaited(_onCompleted());
        return;
      }
      _sync(playing: st.playing);
    });
    return p;
  }

  void _sync({bool? playing}) {
    final cur = state.current;
    final actual = playing ?? state.playing;
    state = SongPlaybackState(
      current: cur,
      playing: actual,
      index: state.index,
      queueLength: _queue.length,
      queueMode: _queueMode,
    );
    // 通知栏/锁屏与 App 内播放按钮双向同步（引擎是单一事实源）
    final h = _handler;
    if (h != null && cur != null) {
      h.playbackState.add(PlaybackState(
        playing: actual,
        processingState: actual ? AudioProcessingState.buffering : AudioProcessingState.ready,
        controls: const [
          MediaControl.skipToPrevious,
          MediaControl.play,
          MediaControl.pause,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek, MediaAction.skipToNext, MediaAction.skipToPrevious},
      ));
      h.mediaItem.add(cur.toMediaItem());
      h.queue.add(_queue.map((e) => e.toMediaItem()).toList());
    }
  }

  /// 统一入口：播单曲（动态/聊天歌曲卡）——单曲模式、不与语音同播。
  Future<String?> playSong(ChatSong song) => _play(
        SongItem(title: song.title, artist: song.artist, mid: song.mid,
                 src: song.src, art: song.art),
        queue: const [], queueMode: false,
      );

  /// 统一入口：从歌单列表点播——队列=列表顺序，next/prev/自动下一首可用。
  Future<String?> playQueue(List<SongItem> queue, int index) =>
      _play(queue[index], queue: queue, index: index, queueMode: true);

  /// 播/暂停（各处按钮共用）：同一首切换播放态。
  Future<void> toggle() async {
    final p = _player;
    if (p == null || state.current == null) return;
    if (state.playing) {
      await p.pause();
    } else {
      unawaited(p.play());
    }
  }

  Future<void> stop() async {
    await _player?.stop();
    await _player?.seek(Duration.zero);
    _sync(playing: false);
  }

  Future<void> next() async {
    if (!state.canSkip) return;
    final i = state.index + 1;
    if (i >= _queue.length) {
      await stop();
      return;
    }
    await _play(_queue[i], queue: _queue, index: i, queueMode: true);
  }

  Future<void> previous() async {
    if (!state.canSkip || state.index <= 0) return;
    final i = state.index - 1;
    await _play(_queue[i], queue: _queue, index: i, queueMode: true);
  }

  Future<void> _onCompleted() async {
    if (state.canSkip && state.index + 1 < _queue.length) {
      await next();
    } else {
      await stop();
    }
  }

  Future<String?> _play(SongItem item, {required List<SongItem> queue,
      int index = 0, required bool queueMode}) async {
    if (_busy) return null;
    final same = state.current?.mid == item.mid && state.current?.src == item.src;
    if (same) {
      await toggle();
      return null;
    }
    _busy = true;
    state = SongPlaybackState(loading: true, index: index,
        queueLength: queue.length, queueMode: queueMode);
    try {
      // 🔴 与语音互斥：播歌先停语音（反向由语音控制器 toggle 里停歌）
      await ref.read(voicePlaybackProvider.notifier).stop();
      final dio = await ref.read(api.dioProvider.future);
      final file = item.mid.isNotEmpty
          ? await downloadAudioToCache(dio, cacheKey: 'mid_${item.mid}',
              urlPath: '/media/${item.mid}', query: const {'preview': 'true'})
          : await downloadAudioToCache(dio, cacheKey: 'src_${item.src.hashCode}',
              urlPath: '/api/music/stream', query: {'u': item.src});
      final player = _ensurePlayer;
      await player.setFilePath(file).timeout(const Duration(seconds: 15));
      _queue = queue;
      _queueMode = queueMode;
      state = SongPlaybackState(current: item, index: index,
          queueLength: queue.length, queueMode: queueMode);
      unawaited(player.play());
      _sync(playing: true);
      return null;
    } catch (e) {
      state = const SongPlaybackState();
      return '试听加载失败，稍后再试';
    } finally {
      _busy = false;
    }
  }
}

final songPlaybackProvider =
    NotifierProvider<SongPlaybackController, SongPlaybackState>(
        SongPlaybackController.new);
