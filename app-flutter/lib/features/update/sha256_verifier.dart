/// 流式 SHA-256 校验（ORD-UPDATER-HARDENING-01 §三.4）。
///
/// 为什么改：旧实现 `readAsBytes()` 把 27.8MB 安装包整个读进内存再算摘要，
/// 校验那一瞬间既有内存尖峰（低端机可能 OOM），又把哈希计算压在主 isolate
/// 上，下载到 100% 时 UI 会顿一下。
///
/// 现在：`File.openRead()` 分块流式喂入（默认 256KB/块），整个过程扔进
/// `Isolate.run`，主线程只等一个 Future。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// 默认分块大小（§三.4：64KB 或 256KB）。
const int kSha256ChunkSize = 256 * 1024;

/// 计算文件 SHA-256（小写 hex）。
///
/// [chunkSize] 仅测试用；生产走默认值。
Future<String> sha256OfFile(String path, {int chunkSize = kSha256ChunkSize}) {
  // 只把路径与块大小送进 isolate（都可发送），不在闭包里捕获 File 句柄。
  return Isolate.run(() => _digestFile(path, chunkSize));
}

Future<String> _digestFile(String path, int chunkSize) async {
  final sink = _DigestSink();
  final conv = sha256.startChunkedConversion(sink);
  await for (final chunk in File(path).openRead(0, null)) {
    // openRead 的块大小不能直接指定，这里按需再切，保证「单块 ≤ chunkSize」
    for (var off = 0; off < chunk.length; off += chunkSize) {
      final end = (off + chunkSize < chunk.length)
          ? off + chunkSize
          : chunk.length;
      conv.add(chunk.sublist(off, end));
    }
  }
  conv.close();
  return sink.value.toString();
}

/// `ChunkedConversionSink` 的最简实现：只收一个最终摘要。
class _DigestSink implements Sink<Digest> {
  Digest? _value;
  Digest get value => _value ?? (throw StateError('摘要未产出'));
  @override
  void add(Digest data) => _value = data;
  @override
  void close() {}
}

/// 校验用：把字节数换算成人类可读大小（诊断文案用）。
String humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// 取 SHA 前 8 位（弹窗展示用）。
String shortSha(String? sha) {
  if (sha == null || sha.isEmpty) return '—';
  return sha.length <= 8 ? sha : sha.substring(0, 8);
}

/// 供单测直接断言的小工具：判断字符串是否是合法 sha256 hex。
bool isSha256Hex(String s) => RegExp(r'^[0-9a-f]{64}$').hasMatch(s);

/// 便于测试的同步小文件摘要（不走 isolate，仅测试用）。
Future<String> sha256OfBytes(List<int> bytes) async =>
    sha256.convert(bytes).toString();
