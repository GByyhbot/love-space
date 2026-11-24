/// 2.4.14：audio_service 原生架构护栏（桥接包移除后）。
/// 锁死：① 队列游标纯逻辑（SongQueue）方法级替身测试；
/// ② 通知按钮回调映射（play/pause/stop/skipToNext/Previous → 引擎语义）；
/// ③ lib 内零旧桥接包引用；④ Manifest 按 audio_service 官方要求声明；
/// ⑤ 语音/选歌试听回归普通 just_audio（tagged 加载保留）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/audio/song_audio_handler.dart'
    show SongItem, SongQueue;

void main() {
  final root = Directory.current.path;
  String src(String rel) => File('$root/$rel').readAsStringSync();

  SongItem song(String id) => SongItem(title: '歌$id', artist: '歌手');

  group('SongQueue 纯游标逻辑（方法级替身）', () {
    test('歌单队列：next/prev 边界与 canSkip', () {
      final q = SongQueue([song('a'), song('b'), song('c')],
          queueMode: true, index: 0);
      expect(q.canSkip, isTrue);
      expect(q.nextIndex(), 1);
      q.index = 1;
      expect(q.previousIndex(), 0);
      expect(q.nextIndex(), 2);
      q.index = 2;
      expect(q.nextIndex(), isNull, reason: '最后一首播完即止');
      expect(q.previousIndex(), 1);
      expect(q.current!.title, '歌c');
    });

    test('单曲模式：next/prev 不可用（播完即止）', () {
      final q = SongQueue([song('a')], queueMode: false, index: 0);
      expect(q.canSkip, isFalse);
      expect(q.nextIndex(), isNull, reason: '在线 30 秒试听不自动连播');
      expect(q.previousIndex(), isNull);
    });

    test('在线歌与本地歌 sameAs 同曲判定', () {
      final online = SongItem(title: 'x', artist: 'y', src: 'https://a');
      final local = SongItem(title: 'x', artist: 'y', mid: 'm1');
      expect(online.sameAs(online), isTrue);
      expect(online.sameAs(local), isFalse);
    });
  });

  group('通知按钮回调映射（源码护栏）', () {
    test('handler override 齐备且落到引擎语义', () {
      final handler = src('lib/core/audio/song_audio_handler.dart');
      // play 键 → resume（继续播）
      expect(handler.contains('Future<void> play() => resume();'), isTrue);
      // pause 键 → _player.pause
      expect(handler.contains('Future<void> pause() => _player.pause();'),
          isTrue);
      // stop 键 → 停播并撤下（stopPlayback）
      expect(handler.contains('Future<void> stop() => stopPlayback();'), isTrue);
      // skip 键 → 队列前进/后退（重新装载）
      expect(handler.contains('Future<void> skipToNext()'), isTrue);
      expect(handler.contains('Future<void> skipToPrevious()'), isTrue);
      expect(handler.contains('_queue.nextIndex()'), isTrue);
      // seek 键
      expect(handler.contains('Future<void> seek(Duration position)'),
          isTrue);
      // 播完自动下一首 / 末曲即止
      expect(handler.contains('Future<void> _onCompleted()'), isTrue);
      expect(handler.contains('_queue.nextIndex()'), isTrue);
      // 引擎状态广播为单一事实源
      expect(handler.contains('playbackState.add('), isTrue);
      expect(handler.contains('mediaItem.add('), isTrue);
      expect(handler.contains('queue.add('), isTrue);
    });

    test('引擎薄包装：播控全落 handler，不自建 AudioPlayer', () {
      final engine = src('lib/core/audio/song_playback.dart');
      expect(engine.contains('AudioPlayer('), isFalse,
          reason: '歌曲 player 唯一持有者是 SongAudioHandler');
      expect(engine.contains('attachHandler'), isTrue);
      expect(engine.contains('_requireHandler'), isTrue);
      expect(engine.contains('voicePlaybackProvider.notifier).stop()'), isTrue,
          reason: '播歌先停语音');
    });
  });

  test('lib 内零旧桥接包引用（代码与注释都清）', () {
    final libDir = Directory('$root/lib');
    for (final f in libDir.listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final code = f.readAsStringSync();
      expect(code.contains('just_audio_background'), isFalse,
          reason: '${f.path} 残留旧桥接包引用');
    }
    final pubspec = src('pubspec.yaml');
    expect(pubspec.contains('just_audio_background'), isFalse);
    final lock = src('pubspec.lock');
    expect(lock.contains('just_audio_background'), isFalse,
        reason: 'lockfile 只减不漂移');
  });

  test('Manifest 按 audio_service 官方要求声明（并存裁定⑥不变）', () {
    final manifest = src('android/app/src/main/AndroidManifest.xml');
    expect(
        manifest.contains('com.ryanheise.audioservice.AudioService"'),
        isTrue, reason: 'audio_service 官方服务声明');
    expect(
        manifest
            .contains('android:foregroundServiceType="mediaPlayback"'),
        isTrue);
    expect(
        manifest.contains('com.ryanheise.audioservice.MediaButtonReceiver'),
        isTrue, reason: '锁屏/耳机媒体键 receiver');
    expect(manifest.contains('android.permission.WAKE_LOCK'), isTrue);
    expect(manifest.contains('FOREGROUND_SERVICE_MEDIA_PLAYBACK'), isTrue);
    expect(manifest.contains('FOREGROUND_SERVICE_SPECIAL_USE'), isTrue,
        reason: 'SSE 保活服务原样保留（裁定⑥并存不合并）');
    // fix5（2026-11-23 定案）：本条断言原先是「manifest 主 activity 直接指向
    // com.ryanheise.audioservice.AudioServiceActivity」——那正是 fix0–fix4 真机
    // MissingPluginException 的根因（自有 MainActivity 从不被实例化，
    // PeerLocNative.register 永不执行）。audio_service 官方口径本就是「自家
    // Activity 继承 AudioServiceActivity」，故要求原位搬迁、不减弱：
    // 媒体前台服务/通知能力仍由继承关系保证，实名由注册层守卫另行钉死。
    final mainActivity = src(
        'android/app/src/main/kotlin/cn/iepose/lovespace/love_space/MainActivity.kt');
    expect(mainActivity.contains(': AudioServiceActivity()'), isTrue,
        reason: 'audio_service 要求 Activity 继承官方实现（媒体前台服务/通知保留）');
    expect(
        manifest.contains('cn.iepose.lovespace.love_space.MainActivity'),
        isTrue,
        reason: '主 activity 必须是自有 MainActivity（否则 peer_loc 通道注册不执行，'
            '且 audio_service 的 engine 钩子随 super 链失效）');
    final plist = src('ios/Runner/Info.plist');
    expect(plist.contains('<string>audio</string>'), isTrue);
  });

  test('语音/选歌试听回归普通 just_audio（tagged 保留）', () {
    final voice = src('lib/features/chat/voice_playback.dart');
    expect(voice.contains("import 'package:just_audio/just_audio.dart';"),
        isTrue, reason: '不再受全局替换影响');
    expect(voice.contains('taggedFileSource(path, voiceMediaItem(tagId))'),
        isTrue, reason: '2.4.13 tagged 加载保留');
    final picker = src('lib/features/chat/song_picker_sheet.dart');
    expect(picker.contains('taggedFileSource(file, MediaItem('), isTrue);
  });
}
