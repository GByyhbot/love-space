/// 语音录制（复验改为长按手势：松开发送 / 左上取消 / 右上转文字）。
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

  /// 取消录制：停止并删掉临时文件（长按滑到左上取消时用，不留脏数据）
  Future<void> cancel() async {
    final p = await _rec.stop();
    final path = p ?? _path;
    _path = null;
    if (path == null) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 临时文件清理失败不阻断手势收尾
    }
  }

  Future<void> dispose() => _rec.dispose();
}
