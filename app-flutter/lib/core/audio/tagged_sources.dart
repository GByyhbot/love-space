/// 2.4.13 根因修复：just_audio_background 的 _PlayerAudioHandler.customLoad
/// 对每次加载的 AudioSource 做 `source.tag as MediaItem` 硬转型——无 tag 的
/// AudioSource 必抛 TypeError（真机「下载成功、load 即死」）。
///
/// 本 helper 是全仓唯一允许构造 AudioSource 的地方（源码护栏白名单）：
/// 每个叶子源必须带 MediaItem tag；队列用 ConcatenatingAudioSource，
/// 每个子源各自带 tag。禁止再有裸 setFilePath()/setUrl() 加载。
library;

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

export 'package:audio_service/audio_service.dart' show MediaItem;

/// 本地文件叶子源：必须带 MediaItem tag。
AudioSource taggedFileSource(String path, MediaItem tag) =>
    AudioSource.uri(Uri.file(path), tag: tag);

/// 队列源：每个子源各自带自己的 MediaItem tag。
/// just_audio 0.10.6 用 setAudioSources(List) 承载队列（ConcatenatingAudioSource 已 deprecated）。
List<AudioSource> taggedQueueSource(List<(String, MediaItem)> files) =>
    [for (final (path, tag) in files) taggedFileSource(path, tag)];

/// 语音 tag：消息唯一标识 + 固定标题。
MediaItem voiceMediaItem(String mid) =>
    MediaItem(id: 'voice:$mid', title: '语音消息');

/// 断言/诊断用：取出叶子源的 tag（队列源取第一个）。
Object? taggedTagOf(AudioSource source) {
  if (source is UriAudioSource) return source.tag;
  return null;
}
