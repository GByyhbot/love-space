/// 2.4.12 条目五：全局歌曲播放引擎护栏。
/// 锁死：引擎单例、队列口径、与语音互斥、通知状态同步、后台续播 download-first。
library;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current.path;
  String src(String rel) => File('$root/$rel').readAsStringSync();

  test('引擎单例：三处播放器入口全部收敛到 songPlaybackProvider', () {
    final engine = src('lib/core/audio/song_playback.dart');
    expect(engine.contains('final songPlaybackProvider ='), isTrue);
    expect(engine.contains('AudioPlayer('), isFalse,
        reason: '2.4.14 起 player 由 SongAudioHandler 持有，引擎是薄包装');

    // 聊天歌曲卡：不再 new AudioPlayer、读引擎状态
    final chatCard = src('lib/features/chat/media_bubble_widgets.dart');
    expect(chatCard.contains('AudioPlayer()'), isFalse,
        reason: '聊天歌曲卡不许自持 player');
    expect(chatCard.contains('songPlaybackProvider'), isTrue);

    // 歌单页：不再 new AudioPlayer、底部条从引擎读
    final musicPage = src('lib/features/together/music_page.dart');
    expect(musicPage.contains('AudioPlayer()'), isFalse,
        reason: '歌单页不许自持 player');
    expect(musicPage.contains('playQueue('), isTrue);
  });

  test('队列口径：歌单=列表顺序，卡片=单曲，播完自动下一首', () {
    final engine = src('lib/core/audio/song_playback.dart');
    expect(engine.contains('Future<String?> playQueue('), isTrue);
    expect(engine.contains('Future<String?> playSong('), isTrue);
    expect(engine.contains('Future<void> next()'), isTrue);
    expect(engine.contains('Future<void> previous()'), isTrue);
    // 2.4.14：队列游标与播完自动下一首语义在 handler（SongQueue.nextIndex）
    final handler = src('lib/core/audio/song_audio_handler.dart');
    expect(handler.contains('int? nextIndex()'), isTrue);
    expect(handler.contains('int? previousIndex()'), isTrue);
    expect(handler.contains('_queue.nextIndex()'), isTrue,
        reason: '播完自动下一首');
  });

  test('与语音互斥：双向钩子齐备', () {
    final engine = src('lib/core/audio/song_playback.dart');
    expect(engine.contains('voicePlaybackProvider.notifier).stop()'), isTrue,
        reason: '播歌先停语音');
    final voice = src('lib/features/chat/voice_playback.dart');
    expect(voice.contains('voiceInterruptHook'), isTrue,
        reason: '播语音先停歌（可注入钩子，避免循环 import）');
    expect(voice.contains('await voiceInterruptHook?.call()'), isTrue);
  });

  test('通知/锁屏：audio_service 原生 handler 为单一事实源（2.4.14）', () {
    final engine = src('lib/core/audio/song_playback.dart');
    expect(engine.contains('attachHandler'), isTrue,
        reason: 'main 把 AudioService.init 的 handler 注入引擎');
    expect(engine.contains('handlerPlayer'), isTrue,
        reason: 'UI 进度流从 handler 暴露的只读 player 取');
    final handler = src('lib/core/audio/song_audio_handler.dart');
    expect(handler.contains('playbackState.add('), isTrue,
        reason: 'handler 广播播放态（单一事实源）');
    expect(handler.contains('mediaItem.add('), isTrue);
    expect(handler.contains('queue.add('), isTrue);

    final main = src('lib/main.dart');
    expect(main.contains('AudioService.init('), isTrue);
    expect(main.contains('builder: () => SongAudioHandler()'), isTrue);
    expect(main.contains('androidStopForegroundOnPause: false'), isTrue);
    expect(main.contains('androidResumeOnClick: true'), isTrue);

    // 裁定6：两服务并存、不合并
    final manifest =
        src('android/app/src/main/AndroidManifest.xml');
    expect(manifest.contains('FOREGROUND_SERVICE_MEDIA_PLAYBACK'), isTrue);
    expect(manifest.contains('FOREGROUND_SERVICE_SPECIAL_USE'), isTrue,
        reason: 'SSE 保活服务原样保留');
    final plist = src('ios/Runner/Info.plist');
    expect(plist.contains('<string>audio</string>'), isTrue);
  });

  test('后台续播：download-first 本地文件（带 tag 的 AudioSource）', () {
    final handler = src('lib/core/audio/song_audio_handler.dart');
    final engine = src('lib/core/audio/song_playback.dart');
    expect(engine.contains('downloadAudioToCache('), isTrue);
    expect(handler.contains('taggedFileSource('), isTrue,
        reason: '2.4.13 加载必须带 MediaItem tag（helper 是唯一构造点）');
    expect(handler.contains('setUrl('), isFalse,
        reason: '不用 setUrl 直接拉远程流（既定家法）');
    expect(handler.contains('await player.setAudioSource('), isTrue);
  });

  test('回填铁律 song 维度：不编辑音乐时 song 不进 changes', () {
    final composer = src('lib/features/timeline/composer_sheet.dart');
    expect(composer.contains("changes['song'] = _song"), isTrue,
        reason: '只有改动音乐才写 changes');
    expect(composer.contains("final initialSong = _originalBody['song'];"), isTrue,
        reason: '与原始 body 的 song 比对判改动');
    expect(composer.contains("if (rawSong is Map) _song ="), isTrue,
        reason: '编辑回填读原始 song');
    final ctrl = src('lib/features/timeline/timeline_controller.dart');
    expect(ctrl.contains("'song': ?song"), isTrue,
        reason: 'publish 支持挂 song，未选不带');
  });

  test('三呈现面：PostCard / 故事弹层 / OTD 都有歌曲卡分支', () {
    for (final rel in [
      'lib/features/timeline/post_card.dart',
      'lib/features/timeline/record_story_sheet.dart',
    ]) {
      final s = src(rel);
      expect(s.contains("b['song'] is Map") || s.contains("cur.body['song'] is Map"),
          isTrue, reason: '$rel 缺歌曲卡分支');
      expect(s.contains('SongCardView('), isTrue, reason: '$rel 未复用歌曲卡');
      expect(s.contains('unavailable:'), isTrue, reason: '$rel 缺不可用占位');
    }
    final otd = src('lib/features/home/on_this_day_page.dart');
    expect(otd.contains('Icons.music_note_rounded'), isTrue,
        reason: 'OTD 精简卡音符角标');
  });

  test('依赖纪律：仅 audio_service（旧桥接包彻底移除）+ 同源 lockfile', () {
    final pubspec = src('pubspec.yaml');
    expect(pubspec.contains('audio_service:'), isTrue);
    expect(pubspec.contains('just_audio_background'), isFalse,
        reason: '2.4.14：单实例桥接包彻底移除');
    final lock = src('pubspec.lock');
    expect(lock.contains('audio_service:'), isTrue);
    expect(lock.contains('just_audio_background'), isFalse,
        reason: 'lockfile 只减不漂移');
    // 2026-11-26（依赖源切换）：原先这里钉死「不许出现 pub.dev」，切到官方源后
    // 该断言必然误报。改为断言**同源不漂移**这个真正的不变量：lock 里所有
    // hosted url 必须完全一致，且若环境里设了 PUB_HOSTED_URL，两者必须同源
    // （CI 就是这么比的）。这样换源不需要再改测试，只有"锁定分成两个源"才红。
    final urls = RegExp(r'url: "([^"]+)"')
        .allMatches(lock)
        .map((m) => m.group(1)!)
        .toSet();
    expect(urls.length, 1, reason: 'lockfile 必须单一同源，实际：$urls');
    final envSrc = Platform.environment['PUB_HOSTED_URL'];
    if (envSrc != null && envSrc.isNotEmpty) {
      expect(urls.single, envSrc.replaceFirst(RegExp(r'/+$'), ''),
          reason: 'lock 的源必须与 PUB_HOSTED_URL 同源（本地与 CI 同一口径）');
    }
  });
}
