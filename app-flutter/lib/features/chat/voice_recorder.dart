/// 语音录制（复验改为长按手势：松开发送 / 左上取消 / 右上转文字）。
/// record 5.2.1（AudioRecorder）录 m4a/AAC-LC 44.1kHz，产物走 Step 5 上传链路。
/// 需要的 RECORD_AUDIO 权限已在 AndroidManifest 声明（本条目唯一清单改动）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../core/chat/chat_models.dart';

/// [voice-dbg] 诊断日志（本轮只加日志不改任何控制流，真机取证用）。
/// debugPrint 在 release 包 logcat 同样可见；单行紧凑格式：
/// `[voice-dbg] t=<毫秒时间戳> <节点> <关键值>`。
void voiceDbg(String node, [String extra = '']) => debugPrint(
    '[voice-dbg] t=${DateTime.now().millisecondsSinceEpoch} '
    '$node${extra.isEmpty ? '' : ' $extra'}');

class VoiceRecorder {
  AudioRecorder _rec = AudioRecorder();
  String? _path;

  /// 上一次录音收尾（dispose + 重建）的完成信号。
  ///
  /// 🔴 根因（连录第二条报「录音失败」）：record 库的 `stop()`/`cancel()`
  /// 既不把平台层 `recorder` 置空、也不重置 Dart 层 `_created`，录音线程引用
  /// 同样滞留。连续录制时第二次 `start()` 复用同一个 `AudioRecorder` 实例，
  /// 上一次的录音线程/音频资源尚未完全归零就重开，`start()` 在
  /// `RecordThread.startRecording()` 的 `startLatch.await()` 阶段抛异常，
  /// 被上层 catch 成「录音失败」。
  /// 收尾后 `dispose()` 并重建一个全新实例，再用本信号串行化：下一次 `start()`
  ///（含 `hasPermission()`）会先等收尾完全落定，拿到的必然是干净新实例。
  Completer<void>? _recycled;

  Future<bool> hasPermission() async {
    final willWaitForRecycle = _recycled != null && !_recycled!.isCompleted;
    voiceDbg('recorder hasPermission enter',
        'willWaitForRecycle=$willWaitForRecycle');
    await _awaitRecycled();
    final ok = await _rec.hasPermission();
    voiceDbg('recorder hasPermission return', 'ok=$ok');
    return ok;
  }

  /// 录音实时音量流（dBFS，约 -160..0，越大越响）。
  /// 供气泡真波形使用；仅在 start() 成功后调用。
  Stream<Amplitude> amplitudeStream(Duration interval) =>
      _rec.onAmplitudeChanged(interval);

  /// 等上一次收尾完全落定（防新长按与上一次收尾竞态）。
  Future<void> _awaitRecycled() {
    final c = _recycled;
    if (c == null || c.isCompleted) return Future.value();
    voiceDbg('recorder _awaitRecycled awaiting previous recycle');
    return c.future;
  }

  Future<void> start() async {
    voiceDbg('recorder start enter');
    await _awaitRecycled();
    final dir = await getApplicationDocumentsDirectory();
    _path =
        '${dir.path}${Platform.pathSeparator}voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    voiceDbg('recorder start path', 'path=$_path');
    voiceDbg('recorder start before _rec.start');
    await _rec.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 96000,
        sampleRate: 44100,
        numChannels: 1,
      ),
      path: _path!,
    );
    voiceDbg('recorder start ok');
  }

  /// 暂停录音会话（record 自带 pause；会话保持存活，stop/取消仍有效）。
  /// composer 录音三键用：暂停时计时冻结，继续后接着录。
  Future<void> pause() async {
    voiceDbg('recorder pause enter');
    await _awaitRecycled();
    await _rec.pause();
    voiceDbg('recorder pause ok');
  }

  /// 恢复录音会话（record 自带 resume；暂停后接着录，计时续走）。
  Future<void> resume() async {
    voiceDbg('recorder resume enter');
    await _awaitRecycled();
    await _rec.resume();
    voiceDbg('recorder resume ok');
  }

  /// 结束录制；没有录到声音（空文件/失败）返回 null
  Future<ChatLocalFile?> stop() async {    voiceDbg('recorder stop enter');
    final p = await _rec.stop();
    voiceDbg('recorder stop recStopPath', 'path=$p');
    if (p == null || p.isEmpty) {
      voiceDbg('recorder stop return null (empty-path)');
      return null;
    }
    final f = File(p);
    if (!await f.exists() || await f.length() == 0) {
      voiceDbg('recorder stop return null (empty-file)');
      return null;
    }
    voiceDbg('recorder stop return file', 'path=$p');
    return ChatLocalFile(path: p, name: '语音.m4a');
  }

  /// 取消录制：停止并删掉临时文件（长按滑到左上取消时用，不留脏数据）
  Future<void> cancel() async {
    voiceDbg('recorder cancel enter');
    final p = await _rec.stop();
    final path = p ?? _path;
    _path = null;
    voiceDbg('recorder cancel targetPath', 'path=$path');
    if (path == null) {
      voiceDbg('recorder cancel skip (no path)');
      return;
    }
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
        voiceDbg('recorder cancel deleted');
      } else {
        voiceDbg('recorder cancel file-not-exists');
      }
    } catch (e) {
      // 临时文件清理失败不阻断手势收尾
      voiceDbg('recorder cancel delete-error', 'e=$e');
    }
  }

  /// 完整释放并重建录音器：收尾后调用，确保下一次 start 用全新实例。
  Future<void> recycle() async {
    voiceDbg('recorder recycle enter');
    final c = Completer<void>();
    _recycled = c;
    try {
      await _rec.dispose();
      voiceDbg('recorder recycle disposed');
    } catch (e) {
      // dispose 异常不阻断重建
      voiceDbg('recorder recycle dispose-error', 'e=$e');
    } finally {
      _rec = AudioRecorder();
      voiceDbg('recorder recycle new-instance-created');
      c.complete();
      voiceDbg('recorder recycle completer-completed');
    }
  }

  Future<void> dispose() => _rec.dispose();
}
