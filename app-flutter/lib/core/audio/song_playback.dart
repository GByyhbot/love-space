/// 2.4.12 条目五 → 2.4.14 重构：全局单一歌曲播放引擎（薄包装层）。
///
/// 架构口径（主人裁定，2.4.13/2.4.14 两轮修订）：
/// · 歌单页 / 动态歌曲卡 / 聊天歌曲卡三处共用本引擎，同一时刻只有一首歌在播；
/// · 🔴 播放本体与通知广播都在 [SongAudioHandler]（App 内唯一持歌曲
///   AudioPlayer 的地方）；本控制器只做：与语音互斥（voiceInterruptHook 反向
///   由语音控制器钩子触发）、错误文案透出、Riverpod state 供 UI 读；
/// · 队列：从歌单点播 = 当前列表顺序（skipToNext/Previous/播完自动下一首）；
///   从动态/聊天歌曲卡点播 = 单曲模式（播完即止）；在线 30 秒试听播完即止；
/// · 后台续播限完整音频（本地上传 + 投放入库的 mid）——download-first 家法；
/// · 通知栏/锁屏走 audio_service（AudioService.init 于 main 注入本 handler）；
///   旧桥接包已彻底移除（单实例模型与本 App 不兼容）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' show AudioPlayer;

import '../api/api_client.dart' as api;
import '../chat/chat_media.dart' show downloadAudioToCache;
import '../chat/chat_models.dart' show ChatSong;
import '../../features/chat/voice_playback.dart' show voicePlaybackProvider;
import 'audio_init_status.dart' show audioInitStatusProvider;
import 'song_audio_handler.dart' show SongAudioHandler, SongItem;

export 'song_audio_handler.dart' show SongItem;

/// 引擎状态（UI 只读这个）。
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

/// 全局引擎：薄包装，播控全落 handler。
class SongPlaybackController extends Notifier<SongPlaybackState> {
  SongAudioHandler? _handler;

  /// 2.4.15：懒创建本地 handler **只允许测试环境**（测试里置 true）；
  /// 生产为 false——AudioService.init 失败时点播走报错通道，绝不本地播放。
  static bool lazyHandlerForTest = false;

  @override
  SongPlaybackState build() {
    ref.onDispose(() {
      // handler 的 player 由 AudioService 生命周期管理；这里只断引用
      _handler = null;
    });
    return const SongPlaybackState();
  }

  /// main 启动时注入（AudioService.init 的产物）。
  void attachHandler(SongAudioHandler handler) {
    _handler = handler;
    handler.observe((item) async {
      final dio = await ref.read(api.dioProvider.future);
      return item.mid.isNotEmpty
          ? downloadAudioToCache(dio, cacheKey: 'mid_${item.mid}',
              urlPath: '/media/${item.mid}', query: const {'preview': 'true'})
          : downloadAudioToCache(dio, cacheKey: 'src_${item.src.hashCode}',
              urlPath: '/api/music/stream', query: {'u': item.src});
    });
    _syncFromHandler();
  }

  /// UI 只读访问 handler 持有的歌曲 player（进度条 StreamBuilder 用）；
  /// 播控仍必须走引擎/handler 方法。
  AudioPlayer? get handlerPlayer => _handler?.player;

  SongAudioHandler get _requireHandler {
    // main 里 AudioService.init 的真 handler 会经 attachHandler 注入（接管
    // 通知/锁屏）。2.4.15：懒创建仅测试环境——生产未就绪时点播必须走报错
    // 通道（真实原因），不得静默本地播放（2.4.14 真机「零媒体会话」教训）。
    final h = _handler;
    if (h != null) return h;
    if (lazyHandlerForTest) return _handler ??= _createLocalHandler();
    throw StateError(
        '系统播放器未就绪：${ref.read(audioInitStatusProvider).error ?? "媒体系统初始化未完成"}');
  }

  SongAudioHandler _createLocalHandler() {
    final h = SongAudioHandler();
    h.observe((item) async {
      final dio = await ref.read(api.dioProvider.future);
      return item.mid.isNotEmpty
          ? downloadAudioToCache(dio, cacheKey: 'mid_${item.mid}',
              urlPath: '/media/${item.mid}', query: const {'preview': 'true'})
          : downloadAudioToCache(dio, cacheKey: 'src_${item.src.hashCode}',
              urlPath: '/api/music/stream', query: {'u': item.src});
    });
    return h;
  }

  void _syncFromHandler() {
    final h = _handler;
    if (h == null) return;
    final (items, queueMode, index) = h.snapshot;
    state = SongPlaybackState(
      current: h.current,
      playing: h.playing,
      loading: h.loading,
      index: index,
      queueLength: items.length,
      queueMode: queueMode,
    );
  }

  /// 统一入口：播单曲（动态/聊天歌曲卡）——单曲模式。
  Future<String?> playSong(ChatSong song) {
    final item = SongItem(title: song.title, artist: song.artist,
        mid: song.mid, src: song.src, art: song.art);
    return _play(item, items: [item], index: 0, queueMode: false);
  }

  /// 统一入口：从歌单列表点播——队列=列表顺序。
  Future<String?> playQueue(List<SongItem> queue, int index) =>
      _play(queue[index], items: queue, index: index, queueMode: true);

  /// 播/暂停（各处按钮共用）：同一首切换播放态。
  Future<void> toggle() async {
    final h = _requireHandler;
    if (h.current == null) return;
    if (h.playing) {
      await h.pause();
    } else {
      unawaited(h.resume());
    }
    _syncFromHandler();
  }

  Future<void> stop() async {
    await _requireHandler.stopPlayback();
    _syncFromHandler();
  }

  Future<void> next() => _skip(_requireHandler.skipToNext);

  Future<void> previous() => _skip(_requireHandler.skipToPrevious);

  Future<void> _skip(Future<void> Function() action) async {
    await action();
    _syncFromHandler();
  }

  Future<String?> _play(SongItem item, {required List<SongItem> items,
      required int index, required bool queueMode}) async {
    final h = _requireHandler;
    final same = state.current?.sameAs(item) ?? false;
    if (same) {
      await toggle();
      return null;
    }
    // 🔴 与语音互斥：播歌先停语音（反向由语音控制器 voiceInterruptHook 停歌）
    try {
      await ref.read(voicePlaybackProvider.notifier).stop();
    } catch (_) {
      // 语音停失败不阻断播歌
    }
    state = SongPlaybackState(loading: true, index: index,
        queueLength: items.length, queueMode: queueMode);
    try {
      await h.load(item, items: items, index: index, queueMode: queueMode);
      _syncFromHandler();
      return null;
    } catch (e) {
      state = const SongPlaybackState();
      // 2.4.13 定案：透出真实异常，不吞成无信息通用文案
      return '试听失败：$e';
    }
  }
}

final songPlaybackProvider =
    NotifierProvider<SongPlaybackController, SongPlaybackState>(
        SongPlaybackController.new);
