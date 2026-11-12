/// 全局语音播放管理器（聊天页语音消息互斥播放 + 时长探测）。
///
/// · 全局唯一播放实例：同一时刻最多一条语音在播；点 B 打断 A（A 立即
///   stop+seek(0)+状态复位），B 从头播；点正在播的 → 停止复位；
///   playerStateStream 的 completed → 自动复位到未播放态。
///   复位定义：playingMid 置 null（消费端图标回未播放、波形回静态）。
/// · 专用探测器（第二个播放器实例，串行队列）：prefetchDuration 用 setUrl
///   读时长后缓存（秒），**绝不 play、绝不打断当前播放**；结果供 chip 显示
///   `<60s → N″ / ≥60s → M:SS`。
/// · 消费端只从 voicePlaybackProvider 的状态流读（不自持播放器）；
///   离开聊天页 / 开始录音由调用方触发 stop()。
/// · 可注入点（playerFactory/proberFactory/urlResolver/headersLoader）
///   供互斥状态机单测换 fake。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/chat/chat_media.dart';
import 'chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'voice_recorder.dart' show voiceDbg;

/// 网络步（resolve/headers/setUrl/play/stop/seek）统一超时：
/// 任一步挂起都会让 toggle 的 await 卡住 → finally 永不执行 →
/// _busy 永久为 true，之后所有点击被静默挡掉（真机现象「点击没有反应」）。
const Duration _netTimeout = Duration(seconds: 10);

/// 统一播放状态（抽象层，屏蔽 just_audio 类型；单测可直接构造）
class VoiceAudioStatus {
  const VoiceAudioStatus({required this.playing, required this.completed});
  final bool playing;

  /// 播放到末尾（playerStateStream 的 processingState == completed）
  final bool completed;
}

/// 可注入播放器接口：控制器只依赖此抽象（互斥状态机单测用 fake 实现）
abstract class VoiceAudioPlayer {
  Stream<VoiceAudioStatus> get statusStream;
  Future<Duration?> setUrl(String url, {Map<String, String>? headers});
  Future<void> play();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> dispose();
}

/// just_audio 实现（全局播放实例与探测器共用同一实现类）
class JustAudioVoicePlayer implements VoiceAudioPlayer {
  final AudioPlayer _player = AudioPlayer();

  @override
  Stream<VoiceAudioStatus> get statusStream =>
      _player.playerStateStream.map((s) => VoiceAudioStatus(
            playing: s.playing,
            completed: s.processingState == ProcessingState.completed,
          ));

  @override
  Future<Duration?> setUrl(String url, {Map<String, String>? headers}) =>
      _player.setUrl(url, headers: headers);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> dispose() => _player.dispose();
}

/// 对外暴露的播放状态（消费端 ref.watch(voicePlaybackProvider) 读取）
class VoicePlaybackState {
  const VoicePlaybackState({
    this.playingMid,
    this.playing = false,
    this.loadedSec,
    this.durationRev = 0,
  });

  /// 正在播放的消息媒体 id（null = 空闲复位态）
  final String? playingMid;
  final bool playing;

  /// 当前播放项已加载的时长（秒；chip 在 cachedDuration 缺失时的次级来源）
  final int? loadedSec;

  /// 时长缓存版本号：探测落缓存后 +1，触发 chip 重建刷新显示
  final int durationRev;
}

/// 全局唯一语音播放控制器（Riverpod 单例）
class VoicePlaybackController extends Notifier<VoicePlaybackState> {
  VoiceAudioPlayer? _player;
  StreamSubscription<VoiceAudioStatus>? _statusSub;
  VoiceAudioPlayer? _prober;
  Future<void> _probeChain = Future<void>.value();
  final Map<String, int> _durationCache = <String, int>{};
  bool _busy = false;

  // ── 可注入点（单测换 fake）────────────────────────────────────────
  VoiceAudioPlayer Function() get playerFactory => JustAudioVoicePlayer.new;

  /// 探测器工厂（第二个实例，与播放实例互不干扰）
  VoiceAudioPlayer Function() get proberFactory => JustAudioVoicePlayer.new;

  /// 媒体地址解析（返回 null 表示无法解析，直接放弃播放/探测）
  Future<String?> Function(String mid) get urlResolver => defaultUrlResolver;

  /// Cookie 头（/media/{mid} 需登录态）
  Future<Map<String, String>> Function() get headersLoader =>
      () => ref.read(mediaCookieHeadersProvider.future);

  Future<String?> defaultUrlResolver(String mid) async {
    final base = await ref.read(chatBaseProvider.future);
    return mediaUrl(base, mid);
  }

  // ── 生命周期 ─────────────────────────────────────────────────────
  @override
  VoicePlaybackState build() {
    ref.onDispose(_teardown);
    return const VoicePlaybackState();
  }

  void _teardown() {
    _statusSub?.cancel();
    _statusSub = null;
    _player?.dispose();
    _player = null;
    _prober?.dispose();
    _prober = null;
  }

  // ── 播放互斥 ─────────────────────────────────────────────────────

  /// 点击语音 chip：未播的从头播（若有别的在播，立即打断复位）；
  /// 正在播的 → 停止复位。
  Future<void> toggle(String mid) async {
    if (_busy) return;
    _busy = true;
    try {
      final cur = state.playingMid;
      if (cur == mid) {
        // 点正在播的：停止复位
        voiceDbg('vp toggle stop-self mid=$mid');
        await _reset();
        return;
      }
      if (cur != null) {
        // A 在播 → 立即 stop + seek(0) + 状态复位，B 从头播
        voiceDbg('vp toggle interrupt from=$cur to=$mid');
        await _reset();
      }
      await _playFromStart(mid);
    } finally {
      _busy = false;
    }
  }

  /// 停止并复位（离开聊天页 / 开始录音时调用）
  Future<void> stop() async {
    voiceDbg('vp stop enter mid=${state.playingMid}');
    await _reset();
  }

  /// 复位：状态先归零（图标/波形即时回静态），再 stop + seek(0) 归位播放器。
  /// durationRev 必须保留——它承载时长缓存版本，复位不能丢掉 chip 刷新信号。
  Future<void> _reset() async {
    state = VoicePlaybackState(durationRev: state.durationRev);
    final p = _player;
    if (p == null) return;
    try {
      // stop/seek 也守超时：挂起同样会卡住调用方的 busy（toggle/stop）
      await p.stop().timeout(_netTimeout);
      await p.seek(Duration.zero).timeout(_netTimeout);
    } catch (e) {
      voiceDbg('vp reset error e=$e');
    }
  }

  Future<void> _playFromStart(String mid) async {
    try {
      final url = await urlResolver(mid).timeout(_netTimeout);
      if (url == null) {
        voiceDbg('vp play no-url mid=$mid');
        return;
      }
      final headers = await headersLoader().timeout(_netTimeout);
      final p = _ensurePlayer();
      final d = await p.setUrl(url, headers: headers).timeout(_netTimeout);
      await p.seek(Duration.zero).timeout(_netTimeout);
      // 状态先行置为播放（图标/波形即时切换），再驱动真实播放
      state = VoicePlaybackState(
        playingMid: mid,
        playing: true,
        loadedSec: d?.inSeconds,
        durationRev: state.durationRev,
      );
      voiceDbg('vp play begin mid=$mid sec=${d?.inSeconds}');
      await p.play().timeout(_netTimeout);
      voiceDbg('vp play started mid=$mid');
    } catch (e) {
      voiceDbg('vp play error mid=$mid e=$e');
      // 加载失败回复位态（图标回未播放），并给 UI 明确反馈——
      // 静默失败在用户视角就是「点击没有反应」（Web 版同款 toast）
      state = VoicePlaybackState(durationRev: state.durationRev);
      ref.read(chatToastProvider.notifier)
          .show('语音播放失败，请稍后再试', tone: ChatToastTone.error);
    }
  }

  VoiceAudioPlayer _ensurePlayer() {
    var p = _player;
    if (p == null) {
      p = playerFactory();
      _player = p;
      _statusSub = p.statusStream.listen(_onStatus);
    }
    return p;
  }

  /// 播放器状态回调：播完（completed）→ 自动复位到未播放态
  void _onStatus(VoiceAudioStatus s) {
    if (!s.completed) return;
    voiceDbg('vp completed mid=${state.playingMid}');
    state = VoicePlaybackState(durationRev: state.durationRev);
  }

  // ── 时长探测（专用实例 + 串行队列，绝不 play）────────────────────

  /// 探测 [mid] 的时长（秒）并落缓存；串行队列保证探测器独占复用。
  /// 已有缓存直接返回；探测期间当前播放不受任何影响。
  Future<int?> prefetchDuration(String mid) {
    final result = _probeChain.then((_) => _probeOnce(mid));
    // 吞掉异常防断链（_probeOnce 内部已兜底，这里只是双保险）
    _probeChain = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<int?> _probeOnce(String mid) async {
    final cached = _durationCache[mid];
    if (cached != null) return cached;
    try {
      final url = await urlResolver(mid);
      if (url == null) {
        voiceDbg('vp prefetch skip mid=$mid (no url)');
        return null;
      }
      final headers = await headersLoader().timeout(_netTimeout);
      final prober = _ensureProber();
      voiceDbg('vp prefetch begin mid=$mid');
      final d =
          await prober.setUrl(url, headers: headers).timeout(_netTimeout);
      final sec = d?.inSeconds ?? 0;
      _durationCache[mid] = sec;
      voiceDbg('vp prefetch done mid=$mid sec=$sec');
      // 版本号 +1：通知 chip 刷新时长显示
      state = VoicePlaybackState(
        playingMid: state.playingMid,
        playing: state.playing,
        loadedSec: state.loadedSec,
        durationRev: state.durationRev + 1,
      );
      return sec;
    } catch (e) {
      voiceDbg('vp prefetch error mid=$mid e=$e');
      return null;
    }
  }

  VoiceAudioPlayer _ensureProber() {
    var p = _prober;
    if (p == null) {
      p = proberFactory();
      _prober = p;
    }
    return p;
  }

  /// 已缓存的时长（秒；未探测过返回 null）
  int? cachedDuration(String mid) => _durationCache[mid];
}

final voicePlaybackProvider =
    NotifierProvider<VoicePlaybackController, VoicePlaybackState>(
        VoicePlaybackController.new);
