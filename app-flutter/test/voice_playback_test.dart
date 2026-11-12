/* 全局语音播放管理器单测：
   ① 纯函数 voiceChipWidth（基线 72 + 4.5/秒，夹 72~200）与
      voiceDurationText（<60s → N″ / ≥60s → M:SS / 无数据 --）；
   ② 互斥状态机四场景（fake 播放器注入）：
      A 播放中 toggle(B) → A 复位 B 从头播；
      toggle(自身) → 停止复位；
      completed → 自动复位；
      stop() → 复位；
   ③ 时长探测：落缓存、绝不 play、不打断当前播放、二次探测命中缓存。 */
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/features/chat/media_bubble_widgets.dart'
    show voiceChipWidth, voiceDurationText;
import 'package:love_space/features/chat/voice_playback.dart';

/// fake 播放器：记录调用序列，手工驱动 completed 事件
class FakeVoicePlayer implements VoiceAudioPlayer {
  FakeVoicePlayer(this.tag);
  final String tag;
  final List<String> calls = <String>[];
  final StreamController<VoiceAudioStatus> _ctrl =
      StreamController<VoiceAudioStatus>.broadcast();

  @override
  Stream<VoiceAudioStatus> get statusStream => _ctrl.stream;

  @override
  Future<Duration?> setUrl(String url, {Map<String, String>? headers}) async {
    calls.add('$tag.setUrl:$url');
    return const Duration(seconds: 7);
  }

  @override
  Future<void> play() async => calls.add('$tag.play');

  @override
  Future<void> stop() async => calls.add('$tag.stop');

  @override
  Future<void> seek(Duration position) async => calls.add('$tag.seek');

  @override
  Future<void> dispose() async => calls.add('$tag.dispose');

  void complete() =>
      _ctrl.add(const VoiceAudioStatus(playing: true, completed: true));
}

/// 注入 fake 的控制器：播放实例/探测器/URL/Cookie 全部假实现
class FakePlaybackController extends VoicePlaybackController {
  FakePlaybackController(this.player, this.prober);
  final FakeVoicePlayer player;
  final FakeVoicePlayer prober;

  @override
  VoiceAudioPlayer Function() get playerFactory => () => player;

  @override
  VoiceAudioPlayer Function() get proberFactory => () => prober;

  @override
  Future<String?> Function(String mid) get urlResolver =>
      (mid) async => 'https://fake/$mid.m4a';

  @override
  Future<Map<String, String>> Function() get headersLoader =>
      () async => const <String, String>{};
}

void main() {
  // ── ① 纯函数 ─────────────────────────────────────────────────────
  group('① voiceChipWidth / voiceDurationText（纯函数）', () {
    test('宽度：0→72、3→85.5、10→117、28→198、30→200、60→200、null→72', () {
      // 注：任务单写的「28→200」与公式 (72+28*4.5)=198 数学上不自洽
      //（4.5/秒到 28.5s 才触顶 200）；以任务单明确给出的公式为正本，
      // 测试期望按公式实算修正。
      expect(voiceChipWidth(0), 72.0);
      expect(voiceChipWidth(3), 85.5);
      expect(voiceChipWidth(10), 117.0);
      expect(voiceChipWidth(28), 198.0); // 72+126=198（尚未触顶）
      expect(voiceChipWidth(30), 200.0); // 202.5 → clamp 200（触顶）
      expect(voiceChipWidth(60), 200.0);
      expect(voiceChipWidth(null), 72.0);
    });

    test('时长文本：<60s → N″、≥60s → M:SS、无数据 --', () {
      expect(voiceDurationText(null), '--');
      expect(voiceDurationText(0), '0″');
      expect(voiceDurationText(5), '5″');
      expect(voiceDurationText(59), '59″');
      expect(voiceDurationText(60), '1:00');
      expect(voiceDurationText(65), '1:05');
      expect(voiceDurationText(125), '2:05');
    });
  });

  // ── ② 互斥状态机 ─────────────────────────────────────────────────
  group('② 互斥状态机（fake 播放器注入）', () {
    late FakeVoicePlayer player;
    late FakeVoicePlayer prober;
    late ProviderContainer container;
    late VoicePlaybackController ctrl;

    setUp(() {
      player = FakeVoicePlayer('p');
      prober = FakeVoicePlayer('q');
      container = ProviderContainer(overrides: [
        voicePlaybackProvider
            .overrideWith(() => FakePlaybackController(player, prober)),
      ]);
      addTearDown(container.dispose);
      ctrl = container.read(voicePlaybackProvider.notifier);
    });

    test('场景 1 切换：A 播放中 toggle(B) → A 复位、B 从头播', () async {
      await ctrl.toggle('a');
      expect(ctrl.state.playingMid, 'a');
      expect(ctrl.state.playing, true);
      expect(player.calls, contains('p.play'));

      player.calls.clear();
      await ctrl.toggle('b');
      // A 被 stop + seek(0) 复位，B setUrl 后从头 play
      expect(
          player.calls,
          containsAllInOrder(
              ['p.stop', 'p.seek', 'p.setUrl:https://fake/b.m4a', 'p.play']));
      expect(ctrl.state.playingMid, 'b');
      expect(ctrl.state.playing, true);
    });

    test('场景 2 自身：toggle 正在播的 → 停止复位（不再播放）', () async {
      await ctrl.toggle('a');
      player.calls.clear();
      await ctrl.toggle('a');
      expect(ctrl.state.playingMid, isNull);
      expect(ctrl.state.playing, false);
      expect(player.calls, containsAllInOrder(['p.stop', 'p.seek']));
      expect(player.calls, isNot(contains('p.play')));
    });

    test('场景 3 播完：playerStateStream completed → 自动复位', () async {
      await ctrl.toggle('a');
      expect(ctrl.state.playingMid, 'a');
      player.complete();
      await pumpEventQueue();
      expect(ctrl.state.playingMid, isNull);
      expect(ctrl.state.playing, false);
    });

    test('场景 4 stop()：离页/开始录音 → 停止复位', () async {
      await ctrl.toggle('a');
      player.calls.clear();
      await ctrl.stop();
      expect(ctrl.state.playingMid, isNull);
      expect(ctrl.state.playing, false);
      expect(player.calls, containsAllInOrder(['p.stop', 'p.seek']));
    });

    test('复位保留 durationRev：时长缓存版本不因复位丢失', () async {
      await ctrl.prefetchDuration('m1');
      final rev = container.read(voicePlaybackProvider).durationRev;
      expect(rev, 1);
      await ctrl.toggle('m1'); // 自身 → 复位
      expect(container.read(voicePlaybackProvider).durationRev, rev);
      expect(ctrl.cachedDuration('m1'), 7);
    });
  });

  // ── ③ 时长探测 ───────────────────────────────────────────────────
  group('③ 时长探测（专用实例 + 串行队列）', () {
    late FakeVoicePlayer player;
    late FakeVoicePlayer prober;
    late ProviderContainer container;
    late VoicePlaybackController ctrl;

    setUp(() {
      player = FakeVoicePlayer('p');
      prober = FakeVoicePlayer('q');
      container = ProviderContainer(overrides: [
        voicePlaybackProvider
            .overrideWith(() => FakePlaybackController(player, prober)),
      ]);
      addTearDown(container.dispose);
      ctrl = container.read(voicePlaybackProvider.notifier);
    });

    test('prefetchDuration 落缓存（秒）、探测器绝不 play', () async {
      final sec = await ctrl.prefetchDuration('m1');
      expect(sec, 7);
      expect(ctrl.cachedDuration('m1'), 7);
      expect(prober.calls, contains('q.setUrl:https://fake/m1.m4a'));
      expect(prober.calls, isNot(contains('q.play')));
      // 版本号 +1 通知 chip 刷新
      expect(container.read(voicePlaybackProvider).durationRev, 1);
    });

    test('探测绝不打断当前播放', () async {
      await ctrl.toggle('a');
      prober.calls.clear();
      final sec = await ctrl.prefetchDuration('m2');
      expect(sec, 7);
      expect(ctrl.state.playingMid, 'a'); // 播放未受影响
      expect(player.calls.where((c) => c == 'p.stop'), isEmpty);
      expect(prober.calls, contains('q.setUrl:https://fake/m2.m4a'));
    });

    test('二次探测命中缓存，不再发 setUrl', () async {
      await ctrl.prefetchDuration('m1');
      prober.calls.clear();
      expect(await ctrl.prefetchDuration('m1'), 7);
      expect(prober.calls, isEmpty);
    });
  });
}
