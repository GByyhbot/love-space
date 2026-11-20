/// 2.4.14：歌曲专用 AudioHandler（audio_service 原生架构）。
///
/// 根因（主人已坐实，勿重新论证）：旧桥接包只允许单一
/// AudioPlayer 实例（init 对第二个 player 抛 PlatformException），与本 App
/// 「语音 + 探测 + 歌曲 + 选歌试听」多 player 模型不兼容——已彻底移除。
///
/// 架构口径：
/// · 本 handler 内部持有**全 App 唯一的「歌曲专用」AudioPlayer**；
///   语音家族（播放/探测）与选歌试听回归普通 just_audio（互不相干）；
/// · 队列语义：handler 记住队列与下标，skipToNext/skipToPrevious 用缓存的
///   resolve 重新装载相邻曲目（download-first 家法不整队预下载）；
///   单曲/在线 30 秒试听播完即止不连播；歌单播完最后一首即止；
/// · 🔴 通知状态单一事实源 = 本 handler 的 playbackState/mediaItem/queue
///   广播（按当前源 tag 与 player 播放态），引擎不再手工推；
/// · 每个叶子源必须带 MediaItem tag（customLoad 硬转型前提，tagged_sources
///   helper 是全仓唯一构造点）；
/// · Android Manifest 声明 com.ryanheise.audioservice.AudioService
///   （mediaPlayback 类型）+ MediaButtonReceiver；与 2.4.5 specialUse SSE
///   前台服务并存不合并（裁定⑥）。
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import 'tagged_sources.dart' show taggedFileSource;

/// 播放项（引擎与 handler 共用）。
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

  /// 队列标识：同曲判定（页面级 toggle 用）。
  bool sameAs(SongItem other) => mid == other.mid && src == other.src;
}

/// 队列游标（纯逻辑，无 IO）：方法级替身测试直接构造。
class SongQueue {
  SongQueue(this.items, {required this.queueMode, required this.index});
  final List<SongItem> items;
  final bool queueMode;
  int index;

  SongItem? get current => index >= 0 && index < items.length ? items[index] : null;
  bool get canSkip => queueMode && items.length > 1;

  /// 下一首游标：队列内前进；越界返回 null（播完即止）。
  int? nextIndex() {
    final i = index + 1;
    return (canSkip && i < items.length) ? i : null;
  }

  /// 上一首游标：队列内后退；首曲返回 null。
  int? previousIndex() {
    final i = index - 1;
    return (canSkip && i >= 0) ? i : null;
  }
}

/// 歌曲专用 handler：App 内唯一持「歌曲 AudioPlayer」的地方。
class SongAudioHandler extends BaseAudioHandler {
  SongAudioHandler();

  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<PlayerState>? _stateSub;
  SongQueue _queue = SongQueue(const [], queueMode: false, index: -1);
  bool _observed = false;
  Future<String> Function(SongItem)? _resolve;
  bool _loading = false;

  /// UI 只读访问（进度条 StreamBuilder 用）。播控必须走 handler 方法。
  AudioPlayer get player => _player;

  /// 当前队列快照（引擎 state 同步用）。
  (List<SongItem>, bool, int) get snapshot =>
      (_queue.items, _queue.queueMode, _queue.index);

  SongItem? get current => _queue.current;

  bool get playing => _player.playing;

  bool get loading => _loading;

  bool get canSkip => _queue.canSkip;

  /// 启动订阅：播放态 → 广播 playbackState；播完 → 队列语义。
  /// handler 首次被引擎使用时调用一次（幂等）。
  void observe(Future<String> Function(SongItem) resolve) {
    _resolve = resolve;
    if (_observed) return;
    unawaited(_stateSub?.cancel());
    _observed = true;
    _stateSub = _player.playerStateStream.listen((st) {
      if (st.processingState == ProcessingState.completed) {
        unawaited(_onCompleted());
        return;
      }
      _broadcast(playing: st.playing);
    });
  }

  /// 装载并播放当前曲（单源带 tag；skip 由本方法按队列下标重入）。
  Future<void> _loadCurrent() async {
    final item = current;
    if (item == null || _resolve == null) return;
    _loading = true;
    _broadcast(playing: false);
    try {
      final file = await _resolve!(item);
      final player = _player;
      await player.stop();
      await player.setAudioSource(taggedFileSource(file, item.toMediaItem()))
          .timeout(const Duration(seconds: 15));
      // 广播当前曲目/队列（通知按钮与 App 内按钮双向同步的单一事实源）
      queue.add([for (final q in _queue.items) q.toMediaItem()]);
      mediaItem.add(item.toMediaItem());
      queueTitle.add(_queue.queueMode ? '共同歌单' : '单曲');
      _broadcast(playing: true);
      unawaited(player.play());
    } finally {
      _loading = false;
    }
  }

  /// 引擎入口：装载指定曲目（带队列上下文）并播放。
  Future<void> load(SongItem item, {required List<SongItem> items,
      required int index, required bool queueMode}) async {
    _queue = SongQueue(items, queueMode: queueMode, index: index);
    await _loadCurrent();
  }

  @override
  /// 通知栏播放键回调 → 续播
  @override
  Future<void> play() => resume();

  @override
  Future<void> pause() => _player.pause();

  Future<void> resume() => _player.play();

  /// 通知栏停止键回调 → 停播并撤下前台
  @override
  Future<void> stop() => stopPlayback();

  /// 停止并复位（离页/互斥/手动停止/通知关闭）。
  Future<void> stopPlayback() async {
    await _player.stop();
    await _player.seek(Duration.zero);
    _broadcast(playing: false);
  }

  /// 通知/锁屏拖动进度回调。
  @override
  Future<void> seek(Duration position) => _player.seek(position);


  /// 通知按钮「下一首」：队列内前进（download-first 重新装载）。
  @override
  Future<void> skipToNext() async {
    final i = _queue.nextIndex();
    if (i == null) return;
    _queue.index = i;
    await _loadCurrent();
  }

  /// 通知按钮「上一首」：队列内后退。
  @override
  Future<void> skipToPrevious() async {
    final i = _queue.previousIndex();
    if (i == null) return;
    _queue.index = i;
    await _loadCurrent();
  }

  /// 播完：队列模式自动下一首；单曲/最后一首播完即止。
  Future<void> _onCompleted() async {
    final i = _queue.nextIndex();
    if (i == null) {
      await stopPlayback();
    } else {
      _queue.index = i;
      await _loadCurrent();
    }
  }

  /// 广播播放态（audio_service 转成通知/锁屏按钮态）。
  void _broadcast({required bool playing}) {
    playbackState.add(PlaybackState(
      playing: playing,
      processingState: _loading
          ? AudioProcessingState.buffering
          : (playing ? AudioProcessingState.ready : AudioProcessingState.idle),
      controls: [
        if (canSkip) MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        if (canSkip) MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek},
    ));
  }
}
