/// 2.8.0 第 0 步 fix5 · peer-loc 诊断落盘（**Dart 侧**，不经 peer_loc/native）。
///
/// 🔴 边界（三句，不许越界）：
/// ① 本文件只写**诊断**——通道异常原文、toggle 结构化结果、status 快照；
///    fatal 内容**永不读回参与开关判定**，开关态唯一事实源仍是原生 status。
/// ② 落盘/读回全走 Dart 侧文件能力（本模块内部用 path_provider），因此
///    `peer_loc/native` 通道压根不存在（MissingPluginException）时**仍然能
///    写、能读、能导出**——fix4 真机「导出失败因为文件从来没生成」的病根
///    就在这里，导出不许把原生当主路径。
/// ③ 任何 IO 失败一律吞掉（返回空），绝不让诊断链反过来炸掉开关链。
///
/// 为什么独立成文件而不写进 peer_locator.dart：该文件有既有护栏
/// 「peer 链禁 import path_provider」（fix4 胶水令，防持久化链回潮）。
/// 诊断落盘不是开关态持久化，放在独立模块里，两条约束同时成立。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// fatal 单文件上限：超出后只保留尾部，避免长期验证无限增长。
const int _maxBytes = 64 * 1024;

/// fatal 文件（应用私有文档目录，无需存储权限）。
Future<File?> _fatalFile() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final sub = Directory('${dir.path}${Platform.pathSeparator}peer-loc');
    if (!sub.existsSync()) sub.createSync(recursive: true);
    return File('${sub.path}${Platform.pathSeparator}fatal-dart.txt');
  } catch (_) {
    return null; // 平台无实现（测试环境未注入）等：诊断链静默降级
  }
}

/// 追加一条诊断记录（尽力而为，绝不抛）。
///
/// 只允许脱敏字段：出处、方法名、ok/reason/detail、状态快照、异常原文与
/// 栈摘要。**禁止**写入 session cookie / 凭据正本（会把口令落到可导出文件里）。
Future<void> peerFatalRecord(String event, Map<String, Object?> payload) async {
  try {
    final f = await _fatalFile();
    if (f == null) return;
    final body = payload.entries
        .map((e) => '  ${e.key}=${e.value}')
        .join('\n');
    final entry = '[${DateTime.now().toIso8601String()}] $event\n$body\n';
    debugPrint('[peer-loc][fatal] $event');
    f.writeAsStringSync(entry, mode: FileMode.append, flush: true);
    _trimIfNeeded(f);
  } catch (_) {
    // 诊断链失败不影响开关链（边界③）
  }
}

/// 读回 Dart 侧 fatal 文件（不存在返回空）。
Future<({String path, String content})> peerFatalRead() async {
  try {
    final f = await _fatalFile();
    if (f == null) return (path: '', content: '');
    if (!f.existsSync()) return (path: f.path, content: '');
    return (path: f.path, content: f.readAsStringSync());
  } catch (_) {
    return (path: '', content: '');
  }
}

/// 超出上限时保留尾部（按行切，避免切碎半行）。
void _trimIfNeeded(File f) {
  try {
    if (f.lengthSync() <= _maxBytes) return;
    final text = f.readAsStringSync();
    final keep = text.substring(text.length - _maxBytes ~/ 2);
    final cut = keep.indexOf('\n');
    f.writeAsStringSync(
        '…（超出 ${_maxBytes ~/ 1024}KB 已截断，仅保留尾部）…\n'
        '${cut >= 0 ? keep.substring(cut + 1) : keep}',
        flush: true);
  } catch (_) {}
}
