/// 2.5.9 裁定⑥：通知服务诊断状态（主 isolate 只读快照）。
///
/// 服务 isolate 经既有数据通道推 {type:'status'}（变化时 + statusQuery 时），
/// NotifyCoordinator.onTaskData 写入 notifyStatusProvider；
/// 设置页「关于」区渲染「通知服务状态」行。不新增后端接口。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
// 3.x：StateProvider 移到 legacy 入口（官方保留兼容，行为不变）
import 'package:flutter_riverpod/legacy.dart';

class NotifyDiag {
  const NotifyDiag({
    this.running = false,
    this.connected = false,
    this.lastEventAtMs = 0,
    this.decision = '',
    this.error = '',
  });

  final bool running;
  final bool connected;
  final int lastEventAtMs;
  final String decision;
  final String error;

  static NotifyDiag fromJson(Map<String, dynamic> j) => NotifyDiag(
        running: j['running'] == true,
        connected: j['connected'] == true,
        lastEventAtMs: (j['lastEventAt'] as num?)?.toInt() ?? 0,
        decision: (j['decision'] ?? '').toString(),
        error: (j['error'] ?? '').toString(),
      );
}

final notifyStatusProvider = StateProvider<NotifyDiag>(
    (ref) => const NotifyDiag());
