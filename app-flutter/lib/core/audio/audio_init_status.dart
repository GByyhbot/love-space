/// 2.4.15：AudioService.init 结果可见（主人指令「先让失败可见，再修真正的门」）。
///
/// main 在启动时记录 init 成败与错误原文；设置页「关于」区读此状态渲染
/// 「系统媒体播放器：已就绪 / 未就绪（+错误摘要）」。生产禁止裸 catch 吞错。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
// 3.x：StateProvider 移到 legacy 入口（官方保留兼容，行为不变）
import 'package:flutter_riverpod/legacy.dart';

/// init 结果快照。
class AudioInitStatus {
  const AudioInitStatus({this.ready = false, this.error});

  /// init 成功且 handler 已注入引擎。
  final bool ready;

  /// 失败时错误原文（完整 toString，设置页截断显示摘要）。
  final String? error;
}

/// 顶层只写一次的 init 状态（main 启动期写入，UI 只读）。
final audioInitStatusProvider = StateProvider<AudioInitStatus>(
    (ref) => const AudioInitStatus());
