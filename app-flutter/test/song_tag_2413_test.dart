/// 2.4.13 根因回归护栏：桥接层 customLoad 对每个 AudioSource
/// 做 `source.tag as MediaItem` 硬转型——无 tag 必抛 TypeError（真机加载即死）。
/// 锁死：① 构造出的每个叶子源 tag is MediaItem；② lib 内零裸 setFilePath/setUrl
/// 加载调用（白名单=构造 helper + 语音抽象签名）；③ 队列每子源各自带 tag。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show AudioSource;
import 'package:love_space/core/audio/song_playback.dart';
import 'package:love_space/core/audio/tagged_sources.dart';

void main() {
  final root = Directory.current.path;
  String src(String rel) => File('$root/$rel').readAsStringSync();

  test('叶子源 tag is MediaItem（本地文件 + 队列子源）', () {
    final tag = MediaItem(id: 'mid:x', title: '测试歌');
    final leaf = taggedFileSource('$root/fake.m4a', tag);
    expect(leaf, isA<AudioSource>());
    expect(taggedTagOf(leaf), same(tag));

    final tag2 = MediaItem(id: 'mid:y', title: '第二首');
    final queue = taggedQueueSource([
      ('$root/a.m4a', tag),
      ('$root/b.m4a', tag2),
    ]);
    expect(queue.length, 2);
    expect(taggedTagOf(queue[0]), same(tag));
    expect(taggedTagOf(queue[1]), same(tag2));
  });

  test('SongItem.toMediaItem 与语音 tag 都是 MediaItem', () {
    final item = SongItem(title: '歌', artist: '歌手', mid: 'm1');
    expect(item.toMediaItem(), isA<MediaItem>());
    expect(item.toMediaItem().id, 'mid:m1');
    expect(voiceMediaItem('v1'), isA<MediaItem>());
    expect(voiceMediaItem('v1').id, 'voice:v1');
    expect(voiceMediaItem('v1').title, '语音消息');
  });

  test('源码护栏：lib 内零裸 setFilePath/setUrl 加载（白名单仅构造 helper）', () {
    final whitelist = {
      'lib/core/audio/tagged_sources.dart',
      'lib/features/chat/voice_playback.dart', // 抽象签名 + 实现（实现内部走 helper）
      'lib/core/audio/song_playback.dart', // getter 注释
    };
    final libDir = Directory('$root/lib');
    for (final f in libDir.listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final rel = f.path.substring(root.length + 1).replaceAll('\\', '/');
      if (whitelist.contains(rel)) continue;
      final code = f.readAsStringSync();
      expect(code.contains('setFilePath('), isFalse,
          reason: '$rel 不许裸 setFilePath 加载（必须 setAudioSource + tag）');
      expect(code.contains('setUrl('), isFalse,
          reason: '$rel 不许 setUrl 加载');
      if (code.contains('setAudioSource(')) {
        expect(code.contains('taggedFileSource('), isTrue,
            reason: '$rel 的 setAudioSource 必须经 taggedFileSource 带 tag');
      }
    }
  });

  test('语音实现/调用点全部带 tagId', () {
    final voice = src('lib/features/chat/voice_playback.dart');
    expect(voice.contains('setFilePath(String path, {required String tagId})'),
        isTrue);
    expect(voice.contains('taggedFileSource(path, voiceMediaItem(tagId))'),
        isTrue);
    expect(voice.contains('setFilePath(file, tagId: mid)'), isTrue);
    expect(voice.contains('_player.setFilePath('), isFalse,
        reason: '不许绕过 helper 直接 setFilePath');
  });

  test('队列下标：_preview 直接透传 index，不再用 key 反推', () {
    final page = src('lib/features/together/music_page.dart');
    expect(page.contains('required int index'), isTrue);
    expect(page.contains('engine.playQueue(items, index)'), isTrue);
    expect(page.contains("_playingRecordId == recordId"), isTrue,
        reason: '页面级同曲 toggle 用记录 id 对照');
    expect(page.contains(r"'${online ? 'src' : 'mid'}"),
        isFalse, reason: '不许再用 key 字符串反推下标');
  });

  test('引擎异常透出真实原因，不再吞成通用文案', () {
    final engine = src('lib/core/audio/song_playback.dart');
    expect(engine.contains("return '试听失败：" r"$e'"), isTrue);
    expect(engine.contains('试听加载失败，稍后再试'), isFalse);
    final picker = src('lib/features/chat/song_picker_sheet.dart');
    expect(picker.contains("'试听失败：" r"$e'"), isTrue);
  });

  test('接线：voiceInterruptHook 在 main 里用 container 赋值', () {
    final main = src('lib/main.dart');
    expect(main.contains('voiceInterruptHook = () =>'), isTrue);
    expect(main.contains('container.read(songPlaybackProvider.notifier).stop()'),
        isTrue);
    expect(main.contains('UncontrolledProviderScope(container: container'),
        isTrue, reason: '必须与 runApp 用同一个 container');
  });

  test('通知广播单一事实源：handler 广播，引擎零手工推（2.4.14 定位）', () {
    final engine = src('lib/core/audio/song_playback.dart');
    expect(engine.contains('playbackState.add('), isFalse);
    expect(engine.contains('mediaItem.add('), isFalse);
    expect(engine.contains('queue.add('), isFalse);
    expect(engine.contains('MediaControl.'), isFalse,
        reason: '引擎不含通知按钮语义');
    final handler = src('lib/core/audio/song_audio_handler.dart');
    expect(handler.contains('playbackState.add('), isTrue,
        reason: '广播集中在 SongAudioHandler');
    expect(handler.contains('自带 handler'), isFalse);
  });
}
