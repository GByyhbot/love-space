/// 语音诊断：把播放/探测失败的原始异常与请求上下文暴露到 App 内 UI，
/// 免去 logcat（真机连不上 USB 时的替代手段）。
///
/// 仅做「观测 + 记录」，不改动任何播放逻辑（setUrl/play 流程、超时、
/// _busy 互斥均保持原样）。play/prefetch 两处 catch 在失败时会调 record()。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 单条语音失败诊断（最近一次或历史列表中的一条）
class VoiceDiagRecord {
  const VoiceDiagRecord({
    required this.ts,
    required this.kind, // 'play' | 'prefetch'
    required this.mid,
    required this.url,
    required this.cookiePresent,
    required this.cookieLen,
    required this.exception,
    required this.exceptionType,
  });

  final DateTime ts;
  final String kind;
  final String mid;
  final String url;
  final bool cookiePresent;
  final int cookieLen;
  final String exception;
  final String exceptionType;

  /// 列表里的简短一行
  String get summary =>
      '[$kind] mid=$mid · ${cookiePresent ? "Cookie($cookieLen)" : "无Cookie"}';

  /// 完整可复制原文（含 URL / Cookie 头状态 / 异常类型与全文）
  String get detail {
    final cookieLine = cookiePresent
        ? 'Cookie头: 存在，长度 $cookieLen'
        : 'Cookie头: 缺失';
    final tsLine =
        '${ts.year}-${_pad(ts.month)}-${_pad(ts.day)} '
        '${_pad(ts.hour)}:${_pad(ts.minute)}:${_pad(ts.second)}';
    return '类型: $kind\n'
        '时间: $tsLine\n'
        'mid: $mid\n'
        'URL: $url\n'
        '$cookieLine\n'
        '异常类型: $exceptionType\n'
        '异常原文:\n'
        '$exception';
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');
}

/// 累积最近若干条诊断记录（最新在前）
class VoiceDiagController extends Notifier<List<VoiceDiagRecord>> {
  static const int _max = 20;

  @override
  List<VoiceDiagRecord> build() => const [];

  void record(VoiceDiagRecord r) {
    state = [r, ...state].take(_max).toList();
  }

  void clear() => state = const [];
}

final voiceDiagProvider =
    NotifierProvider<VoiceDiagController, List<VoiceDiagRecord>>(
        VoiceDiagController.new);
