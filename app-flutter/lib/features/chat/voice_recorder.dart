/// 语音录制（段二 · 对齐 Web chatVoiceToggle：点一下开始，再点一下结束并发送）。
/// record 5.2.1（AudioRecorder）录 m4a/AAC-LC 44.1kHz，产物走 Step 5 上传链路。
/// 需要的 RECORD_AUDIO 权限已在 AndroidManifest 声明（本条目唯一清单改动）。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../core/chat/chat_models.dart';

class VoiceRecorder {
  final AudioRecorder _rec = AudioRecorder();
  String? _path;

  Future<bool> hasPermission() => _rec.hasPermission();

  Future<void> start() async {
    final dir = await getApplicationDocumentsDirectory();
    _path =
        '${dir.path}${Platform.pathSeparator}voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _rec.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 96000,
        sampleRate: 44100,
        numChannels: 1,
      ),
      path: _path!,
    );
  }

  /// 结束录制；没有录到声音（空文件/失败）返回 null
  Future<ChatLocalFile?> stop() async {
    final p = await _rec.stop();
    if (p == null || p.isEmpty) return null;
    final f = File(p);
    if (!await f.exists() || await f.length() == 0) return null;
    return ChatLocalFile(path: p, name: '语音.m4a');
  }

  Future<void> dispose() => _rec.dispose();
}
