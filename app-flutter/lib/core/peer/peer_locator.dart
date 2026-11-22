/// 2.8.0 定位守护第 0 步 · 路线 B 验证包控制器（experiment/peer-loc-verify 分支）。
///
/// 架构：采集/转换/队列/上报全在原生层（PeerLocNative.kt，FGS 进程内自足，
/// 不依赖 Flutter isolate——flutter_foreground_task 的服务 isolate 是独立
/// engine，主 engine 的 channel 服务侧收不到，故 Dart 只发 start/stop 指令
/// 与凭据注入）。本文件职责：
/// · 权限引导：定位「始终允许」（ACCESS_BACKGROUND_LOCATION 需单独授予），
///   不许反复弹窗（红线：权限被拒降级显示，不崩不催）；
/// · 会话凭据注入（secure_storage 主本 → 原生 Cookie + baseUrl）；
/// · 开关状态持久化（SharedPreferences，App 冷启动自动恢复采集）。
///
/// [peer-loc] 日志与原生 TAG 同前缀口径，本段保留不删（第 0 步取证用）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';

import '../api/api_client.dart';

const _channel = MethodChannel('peer_loc/native');

// 2.7.1 风格真机 fix2 后再实证：SharedPreferencesApi(Pigeon) 在真机主
// isolate 上仍抛 unregistered-instance（shared_preferences 2.5.6 后端路由
// 异常，全量堆栈见 docs/fatal 落盘）——toggle 链**彻底去 shared_preferences**：
// 开关态改 path_provider 文件持久化（该通道在真机服务 isolate 已被录音链
// （getApplicationDocumentsDirectory）验证可用，与插件注册状态解耦）。
const _persistFile = 'peer_verify_state.json';

/// 测试注入点（fix3 实证：path_provider 的 Pigeon 通道在 test binding 下
/// 无 mock 时 future 永挂——_toggle 卡死在 _writePersisted，呈现层同样
/// 「无提示回弹」）。生产恒为 null 走真实目录。
@visibleForTesting
Future<Directory> Function()? stateDirFactory;

Future<File> _stateFile() async {
  final dir = stateDirFactory != null
      ? await stateDirFactory!()
      : await getApplicationDocumentsDirectory();
  return File('${dir.path}${Platform.pathSeparator}$_persistFile');
}

/// 开关态读盘（文件损坏/缺失一律按关处理，不抛）。
Future<bool> _readPersisted() async {
  try {
    final f = await _stateFile();
    if (!f.existsSync()) return false;
    return jsonDecode(f.readAsStringSync())['on'] == true;
  } catch (e) {
    peerLocLog('read persisted error: $e');
    return false;
  }
}

Future<bool> _writePersisted(bool v) async {
  try {
    final f = await _stateFile();
    f.writeAsStringSync(jsonEncode({'on': v}), flush: true);
    return v;
  } catch (e) {
    peerLocLog('write persisted error: $e');
    return false;
  }
}

/// 🔴 fatal 全量堆栈落盘（logcat 按行截断/机主截图截断的兜底——注册类
/// 问题必须在开发期炸出来，堆栈原文留在文档目录可直接导出）。
Future<void> _dumpFatal(String where, Object e, StackTrace stack) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    File('${dir.path}${Platform.pathSeparator}peer-loc-fatal.txt')
        .writeAsStringSync(
            '[${DateTime.now().toIso8601String()}] $where\n$e\n\n$stack\n\n',
            mode: FileMode.append, flush: true);
  } catch (_) {}
  peerLocLog('$where fatal: $e\n${stack.toString().split('\n').take(14).join('\n')}');
}

/// 验证开关（App 冷启动按此自动恢复采集）。
bool peerVerifyOn = false;

void peerLocLog(String msg) =>
    debugPrint('[peer-loc] ${DateTime.now().millisecondsSinceEpoch} $msg');


/// 开关切换返回结构：ok + 用户可见说明（启用失败必须给说明，不许静默回弹）。
class PeerVerifyResult {
  const PeerVerifyResult(this.ok, this.reason);
  final bool ok;
  final String reason;

  @override
  String toString() => ok ? 'ok' : reason;
}

/// 开关切换（验证包临时开关行调用）。开启走权限引导；失败必给原因。
Future<PeerVerifyResult> peerVerifyToggle(bool on) async {
  // 🔴 全程 try：任何异常都必须产出结构化原因——且 fatal 全量堆栈落盘
  //（文档目录 peer-loc-fatal.txt），注册类问题开发期炸出来不许吞。
  try {
    if (on) {
      final deny = await _ensurePermission();
      if (deny != null) {
        peerLocLog('toggle-on aborted: $deny');
        peerVerifyOn = false;
        await _writePersisted(false);
        return PeerVerifyResult(false, deny);
      }
      final r = await _startNative();
      peerVerifyOn = r.ok;
      await _writePersisted(r.ok);
      return r;
    }
    peerVerifyOn = false;
    await _writePersisted(false);
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      peerLocLog('stop error: $e');
    }
    return const PeerVerifyResult(false, '');
  } catch (e, stack) {
    await _dumpFatal('peerVerifyToggle', e, stack);
    peerVerifyOn = false;
    await _writePersisted(false);
    return PeerVerifyResult(
        false, '启用失败（内部错误）：${e.toString().substring(0, e.toString().length.clamp(0, 120))}');
  }
}

/// 权限引导（2.4.6 风格：一次引导不反复弹）。
///
/// 🔴 2.7.1 风格真机实证修正（小米）：geolocator 的枚举在部分 ROM 上
/// 「已授仍报 denied/deniedForever」（Android 11+ 对
/// ACCESS_BACKGROUND_LOCATION 的 checkSelfPermission 误报）——geolocator
/// 只用来**弹系统对话框引导**，最终判定以原生 hasPermission 为事实源
/// （AppOps noteOpNoThrow(OP_ACCESS_BACKGROUND_LOCATION) 复核）。
/// 返回 null=通过；非 null=用户可见的失败原因。
Future<String?> _ensurePermission() async {
  final nativeHas = await _channel
      .invokeMethod<bool>('hasPermission')
      .then((v) => v ?? false)
      .catchError((_) => false);
  if (nativeHas) {
    peerLocLog('permission ok (native appops verdict)');
    return null;
  }
  // 原生判定未过 → 引导一次：denied 时弹系统对话框（FINE）；「始终允许」
  // 在 Android 10+ 只能进系统设置单独授——引导 openAppSettings 一次。
  // 🔴 geolocator 调用全程 try：MIUI 上 checkPermission/requestPermission
  // 可能抛平台异常（真机 fix1 实证：异常在 PeerVerifyResult 产生前炸掉
  // 整条 toggle 链，UI 无任何提示直接回弹）——异常时跳过引导直接走原生终判。
  try {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
      peerLocLog('requestPermission result: $perm');
    }
  } catch (e) {
    peerLocLog('geolocator guide error (skip guide, native verdict): $e');
  }
  // 无论 geolocator 怎么报，终判回原生（AppOps 口径）
  final after = await _channel
      .invokeMethod<bool>('hasPermission')
      .then((v) => v ?? false)
      .catchError((_) => false);
  if (after) {
    peerLocLog('permission ok after request (native verdict)');
    return null;
  }
  peerLocLog('permission still denied after guide');
  return '需要定位权限，且在系统设置里设为「始终允许」后重试';
}

Future<PeerVerifyResult> _startNative() async {
  try {
    // 会话凭据：secure_storage 正本（api_client 同源）→ 原生 Cookie
    final token = await readSessionToken();
    if (token == null || token.isEmpty) {
      peerLocLog('start aborted: no session token');
      return const PeerVerifyResult(false, '未登录或会话已失效，请重新登录后再开启');
    }
    final base = await readLastRoute();
    if (base == null || base.isEmpty) {
      peerLocLog('start aborted: no base url');
      return const PeerVerifyResult(false, '线路未就绪，请先登录并进入过空间后再开启');
    }
    final r = await _channel.invokeMethod<Map<Object?, Object?>>(
        'start', {'cookie': 'love_session=$token', 'baseUrl': base});
    final started = r?['started'] == true;
    final reason = (r?['reason'] as String?) ?? '';
    if (started) {
      peerLocLog('native start ok (base=$base)');
      // 回调实证探针：start 后 3 min 内 0 真实回调 = 后台定位未生效
      //（权限 API 在部分 ROM 上已授仍报 denied，回调是唯一事实源）
      _probeBackground();
      return const PeerVerifyResult(true, '');
    }
    peerLocLog('native start rejected: $reason');
    return PeerVerifyResult(false, reason.isEmpty ? '启用失败，请重试' : reason);
  } catch (e) {
    peerLocLog('start error: $e');
    return PeerVerifyResult(false, '启用失败：$e');
  }
}

Timer? _probeTimer;
int _probeCheckN = 0;

/// 后台定位回调实证探针：每 30s 查一次 stats（received 计数），共 6 次
/// （3 min）。0 回调 → 给用户可见说明（设置卡 SnackBar 经回调透传）。
/// 有回调即探针通过，静默结束。
void _probeBackground() {
  _probeTimer?.cancel();
  _probeCheckN = 0;
  _probeTimer = Timer.periodic(const Duration(seconds: 30), (t) async {
    _probeCheckN++;
    try {
      final stats = await _channel
          .invokeMethod<Map<Object?, Object?>>('stats')
          .then((v) => v ?? const {});
      final received = (stats['received'] as num?)?.toInt() ?? 0;
      peerLocLog('probe #$_probeCheckN: received=$received');
      if (received > 0) {
        peerLocLog('probe pass: location callbacks flowing');
        t.cancel();
        return;
      }
      if (_probeCheckN >= 6) {
        t.cancel();
        peerLocLog('probe FAIL: 0 callback in 3min -> background likely off');
        onProbeFail?.call();
      }
    } catch (e) {
      peerLocLog('probe error: $e');
    }
  });
}

/// 探针失败回调（设置卡接线：SnackBar「后台定位未生效」可见说明）。
void Function()? onProbeFail;

/// （保留）JSON 序列化占位：原生层 JSON 直接构建，Dart 侧无序列化职责。
String debugDump(Object o) => jsonEncode(o);

/// App 启动钩子（main.dart 初始化后调用一次）：开关开 → 自动恢复采集。
Future<void> peerLocatorAutoStart() async {
  try {
    peerVerifyOn = await _readPersisted();
    peerLocLog('auto-start check: on=$peerVerifyOn');
    if (!peerVerifyOn) return;
    final deny = await _ensurePermission();
    if (deny != null) {
      peerLocLog('auto-start skipped: $deny');
      return; // 不反复弹窗：未授权保持开关但本次不启，下次 tap 再引导
    }
    final r = await _startNative();
    peerLocLog('auto-start native: ok=${r.ok} ${r.reason}');
  } catch (e, stack) {
    await _dumpFatal('peerLocatorAutoStart', e, stack);
  }
}
