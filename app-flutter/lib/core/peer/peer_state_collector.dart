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

import 'peer_policy.dart';
import 'peer_report_api.dart';
import 'peer_report_queue.dart';

const MethodChannel _stateChannel = MethodChannel('peer_loc/native');

/// 样本 client_id 自增序号（同毫秒多事件也不会撞）。
int _seq = 0;

/// 已安装 handler 标记：MethodChannel 只允许一个 handler，重复安装会顶掉旧的。
bool _installed = false;

/// 最近一次下发给原生的 policy（避免重复下发；null = 还没下发过）。
PeerPolicy? _appliedPolicy;

/// 安装样本 handler（App 启动时调用一次）。
///
/// 两类样本走同一条通道、同一个队列：
/// · `onStateSample` —— 电量/网络/解锁/亮屏；
/// · `onUsageSample` —— 应用会话 / 正在使用（2.8.7 全量，`usage.*`）。
///
/// 收到样本 → 脱敏复核 → 入队 → 立刻冲一次。冲刷失败不抛（队列会保留），
/// 这样原生投递永远不会因为网络问题而「看起来失败」。
void installStateSampleHandler({
  required Future<Dio> Function() dio,
}) {
  if (_installed) return;
  _installed = true;
  _stateChannel.setMethodCallHandler((MethodCall call) async {
    if (call.method != 'onStateSample' && call.method != 'onUsageSample') {
      return null;
    }
    final args = (call.arguments as Map?)?.cast<Object?, Object?>();
    final kind = (args?['kind'] ?? '').toString();
    final rawPayload = args?['payload'];
    if (kind.isEmpty || rawPayload is! Map) return null;

    final payload = sanitizeTelemetryPayload(kind, rawPayload.cast<String, Object?>());
    if (payload == null) return null; // 脱敏失败/载荷非法：宁可丢一条，也不出设备
    final now = DateTime.now();
    try {
      await reportOutbox.enqueue(PendingReport(
        // 遥测事件没有 scene（后端 scene 语义只属主动报备）
        scene: '',
        clientId: '${kind.replaceAll('.', '-')}-'
            '${now.microsecondsSinceEpoch}-${_seq++}',
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

/// 端侧最后一道脱敏/校验（**入队之前**执行，与原生脱敏互为双保险）。
///
/// 🔴 真实包名永不出设备：命中的包名在这里被改写为哨兵；若原生漏了脱敏
/// （或旧版本原生没有脱敏逻辑），这里按 policy 的敏感清单再兜一次。
/// 返回 null = 本条不上报（宁可丢一条，也不许把敏感包名送出去）。
Map<String, Object?>? sanitizeTelemetryPayload(
  String kind,
  Map<String, Object?> payload, {
  PeerPolicy? policy,
}) {
  if (!kind.startsWith('usage.')) return payload;
  final pol = policy ?? _appliedPolicy ?? PeerPolicy.defaults;
  final masked = payload['masked'] == true;
  final pkg = (payload['pkg'] ?? '').toString();
  final app = (payload['app'] ?? '').toString();
  if (masked) {
    // 已声明脱敏：包名必须已经是哨兵，否则一律拦掉（服务端也会 422）
    if (pkg.isNotEmpty && pkg != kMaskedPkg) return null;
    return {
      ...payload,
      'pkg': kMaskedPkg,
      'app': kMaskedAppName,
    };
  }
  if (pkg.isNotEmpty && pol.sensitivePkgs.contains(pkg)) {
    return {
      ...payload,
      'pkg': kMaskedPkg,
      'app': kMaskedAppName,
      'masked': true,
    };
  }
  if (app.isEmpty) return null;
  return payload;
}

/// 脱敏哨兵（与服务端 `SENSITIVE_MASK_PKG/NAME` 逐字同源）。
const String kMaskedPkg = 'masked.other';
const String kMaskedAppName = '其他应用';

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

/// 把分档 policy 下发给原生（采集端据此启停与脱敏）。
///
/// 🔴 停用（完全关闭 / 暂停中）生效时同步**清掉队列里的遥测条目**：
/// 恢复后不补报这段（方案册 §4.1）；手动报备条目保留。
/// 幂等：与上次下发的 policy 相同则只做一次（[force] 可强制）。
Future<bool> applyPeerPolicy(PeerPolicy policy, {bool force = false}) async {
  final changed = force || _appliedPolicy != policy;
  _appliedPolicy = policy;
  var ok = false;
  if (changed) {
    try {
      final r = await _stateChannel.invokeMethod<Map<Object?, Object?>>(
        'applyPolicy',
        {'policy': policy.toJson()},
      );
      ok = r?['ok'] == true;
    } catch (_) {
      // 旧包/通道未注册：不炸主链（服务端裁剪仍是第二道防线）
    }
  }
  if (policy.isHalted) {
    await reportOutbox.clearTelemetry();
  }
  return ok;
}

/// 拉一次应用会话增量（骑既有唤醒点：回前台/切页时调用，不新增定时器）。
Future<int> pullUsageSamples() async {
  try {
    final r = await _stateChannel
        .invokeMethod<Map<Object?, Object?>>('pullUsage');
    final n = r?['sessions'];
    return n is int ? n : 0;
  } catch (_) {
    return 0;
  }
}

/// 应用使用授权状态（`PACKAGE_USAGE_STATS`，AppOps 检测）。
///
/// 返回 `{granted, enabled, supported}`；通道不可用一律按「未授权」处理。
Future<Map<String, Object?>> usagePermissionStatus() async {
  try {
    final r = await _stateChannel
        .invokeMethod<Map<Object?, Object?>>('usageStatus');
    if (r == null) return const {'granted': false, 'enabled': false};
    return {
      'granted': r['granted'] == true,
      'enabled': r['enabled'] == true,
      'supported': r['supported'] != false,
    };
  } catch (_) {
    return const {'granted': false, 'enabled': false, 'supported': true};
  }
}

/// 跳系统「使用情况访问」授权页（用户在系统页手动授权，App 不催）。
Future<bool> openUsageAccessSettings() async {
  try {
    final r = await _stateChannel.invokeMethod<bool>('openUsageSettings');
    return r == true;
  } catch (_) {
    return false;
  }
}

/// 已安装应用清单（敏感清单多选用；原生按启动器入口枚举，排除本 App）。
///
/// 通道不可用/旧包 → 返回空表（页面显示「本机拿不到应用清单」），不抛。
Future<List<Map<String, String>>> fetchInstalledApps() async {
  try {
    final r = await _stateChannel
        .invokeMethod<Map<Object?, Object?>>('installedApps');
    final raw = (r?['apps'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((e) => {
              'pkg': (e['pkg'] ?? '').toString(),
              'label': (e['label'] ?? '').toString(),
            })
        .where((e) => (e['pkg'] ?? '').isNotEmpty)
        .toList(growable: false);
  } catch (_) {
    return const [];
  }
}

/// 冷启动自举：装 handler + 读一次设置（四开关 + policy）并同步。
///
/// 失败静默（未登录/网络差时不该弹错）；进入报备页与设置页保存后还会再同步。
Future<void> peerStateCollectionAutoStart({
  required Future<Dio> Function() dio,
}) async {
  installStateSampleHandler(dio: dio);
  try {
    final settings = await fetchPeerSettings(await dio());
    await syncStateCollection(eventsOn: settings.events);
    await applyPeerPolicy(settings.policy);
    await pullUsageSamples();
  } catch (_) {
    // 未登录 / 网络不可用：保持原生默认（未开），下次进页面再同步
  }
}
