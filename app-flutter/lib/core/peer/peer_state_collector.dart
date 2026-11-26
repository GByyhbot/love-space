/// 2.8.7 自动报备：状态样本入口与采集开关同步。
///
/// 分工（设计回执 §4）：
/// · **原生**负责采集与阈值/窗口筛选（电量 Δ≥2%/翻转/60s、网络 30s/SSID 5min、
///   解锁 10min 窗口、亮屏会话），筛完通过 `peer_loc/native` 投递 `onStateSample`；
/// · **Dart** 负责入队与上行：复用既有文件队列 [reportOutbox] 的
///   去重 / 毒丸 / 整批保留语义，走 `POST /api/peer/report` 的 kind/payload 分支。
///
/// 为什么不做两套上行：令文红线 1 明确「事件骑现有报备队列」，原生侧只发样本
/// 不碰网络，避免在 Kotlin 里再造一个带鉴权/重试的 HTTP 栈。
library;

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import 'peer_report_api.dart';
import 'peer_report_queue.dart';

const MethodChannel _stateChannel = MethodChannel('peer_loc/native');

/// 样本 client_id 自增序号（同毫秒多事件也不会撞）。
int _seq = 0;

/// 已安装 handler 标记：MethodChannel 只允许一个 handler，重复安装会顶掉旧的。
bool _installed = false;

/// 安装状态样本 handler（App 启动时调用一次）。
///
/// 收到样本 → 入队 → 立刻冲一次。冲刷失败不抛（队列会保留，等下次触发），
/// 这样原生投递永远不会因为网络问题而"看起来失败"。
void installStateSampleHandler({
  required Future<Dio> Function() dio,
}) {
  if (_installed) return;
  _installed = true;
  _stateChannel.setMethodCallHandler((MethodCall call) async {
    if (call.method != 'onStateSample') return null;
    final args = (call.arguments as Map?)?.cast<Object?, Object?>();
    final kind = (args?['kind'] ?? '').toString();
    final rawPayload = args?['payload'];
    if (kind.isEmpty || rawPayload is! Map) return null;

    final payload = rawPayload.cast<String, Object?>();
    final now = DateTime.now();
    try {
      await reportOutbox.enqueue(PendingReport(
        // 状态事件没有 scene（后端 scene 语义只属主动报备）
        scene: '',
        clientId: 'state-${now.microsecondsSinceEpoch}-${_seq++}',
        createdAt: now.millisecondsSinceEpoch / 1000,
        kind: kind,
        payload: payload,
        push: false,
      ));
      await reportOutbox.flush(await dio());
    } catch (_) {
      // 入队/冲刷失败都不回抛：队列里留着，下次样本或页面刷新会再冲
    }
    return null;
  });
}

/// 把「events 共享开关」同步给原生采集器。
///
/// 关 → 原生注销全部接收器并清窗口（**不 flush**，停采就停干净）；
/// 服务端 422 是第二道保险（双保险，见令文红线 4）。
Future<bool> syncStateCollection({required bool eventsOn}) async {
  try {
    final r = await _stateChannel
        .invokeMethod<Map<Object?, Object?>>('toggleState', {'enable': eventsOn});
    return r?['ok'] == true;
  } catch (_) {
    // 通道不存在（未注册/旧包）不炸主链
    return false;
  }
}

/// 冷启动自举：装 handler + 读一次共享开关并同步采集态。
///
/// 失败静默（未登录/网络差时不该弹错）；进入报备页与设置页保存后还会再同步。
Future<void> peerStateCollectionAutoStart({
  required Future<Dio> Function() dio,
}) async {
  installStateSampleHandler(dio: dio);
  try {
    final settings = await fetchPeerSettings(await dio());
    await syncStateCollection(eventsOn: settings.events);
  } catch (_) {
    // 未登录 / 网络不可用：保持原生默认（未开），下次进页面再同步
  }
}
