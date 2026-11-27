/// 2.8.0 定位守护 · 胶水层（fix4 重做：原生一口价）。
///
/// 🔴 架构铁律（胶水重做令）：Dart 只做**搬运与渲染**——
/// · toggle 单一原生入口：入参 {enable, 线路, 凭据}（凭据从 secure_storage
///   正本读出后下传，Dart 不做任何权限判定、不做任何状态推断）；
/// · 返回 {ok, reason, detail}，Dart 只渲染；原生权限两值分开回报
///   （缺前台/缺后台两种 reason），Dart 据此显示对应引导；
/// · 开关态以**原生为单一事实源**：`peerVerifyStatus()` 查询服务是否在跑
///   + 最近回调计数，页面进入与 toggle 后都以查询结果回填；
/// · 整段删除：geolocator 权限判定、shared_preferences/path_provider
///   持久化链（前三轮病都在开关胶水层）。
///
/// fatal 落盘在原生侧（external files peer-loc/fatal-native.txt），验证卡
/// 提供导出/分享入口——机主能把文件拿出来才算落盘完成。
/// [peer-loc] 日志与原生 TAG 同前缀口径，本段保留不删。
library;

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
// fix5：诊断落盘独立成模块（同类目内），本文件不直引 path_provider——
// 既有「peer 链禁持久化插件」护栏口径不变（详见 peer_fatal_log.dart 头注）。
import 'peer_fatal_log.dart';
// fix6：期望态（用户意图）落盘同样独立成模块，本文件不直引
// shared_preferences；期望态只用于显示与恢复提示，永不自启采集。
import 'peer_expected_state.dart';

const _channel = MethodChannel('peer_loc/native');

/// 页面回填的开关态（原生 status.running 为单一事实源）。
bool peerVerifyOn = false;

void peerLocLog(String msg) =>
    debugPrint('[peer-loc] ${DateTime.now().millisecondsSinceEpoch} $msg');

/// toggle 结构化结果（原生返回直通）。
class PeerVerifyResult {
  const PeerVerifyResult(this.ok, this.reason, this.detail);
  final bool ok;
  final String reason;
  final Map<Object?, Object?> detail;

  @override
  String toString() => 'PeerVerifyResult(ok=$ok, reason=$reason, detail=$detail)';
}

/// 开关切换：单一原生入口。凭据从 secure_storage 正本读出后下传。
/// 任何通道异常产出结构化原因（不许静默回弹），fatal 由原生落盘。
///
/// fix5：Dart 侧同时落盘诊断（peer_fatal_log.dart）——MissingPluginException
/// 属致命态：原生根本不执行，原生 fatal 文件不可能生成，故此处必须自己写，
/// 且写入内容含 toggle 结构化结果与 status 快照，保证导出永远有内容可导。
Future<PeerVerifyResult> peerVerifyToggle(bool on) async {
  try {
    final token = await readSessionToken();
    if (token == null || token.isEmpty) {
      peerLocLog('toggle aborted: no session token');
      const res = PeerVerifyResult(false, '未登录或会话已失效，请重新登录后再开启',
          {'fine': 'unknown', 'background': 'unknown'});
      await _recordToggle('toggle-aborted(no-token)', res);
      return res;
    }
    final base = await readLastRoute();
    if (base == null || base.isEmpty) {
      peerLocLog('toggle aborted: no base url');
      const res = PeerVerifyResult(false, '线路未就绪，请先登录并进入过空间后再开启',
          {'fine': 'unknown', 'background': 'unknown'});
      await _recordToggle('toggle-aborted(no-route)', res);
      return res;
    }
    // 原生 toggle 全同步返回 map，无挂点——不加 .timeout（test binding 下
    // timeout 的 Timer 会以 pending 状态炸掉整页 widget 测试）
    final r = await _channel
        .invokeMethod<Map<Object?, Object?>>('toggle', {
      'enable': on,
      'cookie': 'love_session=$token',
      'baseUrl': base,
    });
    final ok = r?['ok'] == true;
    final reason = (r?['reason'] as String?) ?? '';
    final detail = (r?['detail'] as Map<Object?, Object?>?) ?? const {};
    peerLocLog('toggle result: ok=$ok reason=$reason detail=$detail');
    final res = PeerVerifyResult(ok, reason, detail);
    await _recordToggle('toggle-result', res);
    await _recordExpected(on, ok);
    return res;
  } catch (e, stack) {
    final brief = _stackBrief(stack);
    peerLocLog('toggle fatal: $e stack=$brief');
    if (e is MissingPluginException) {
      const res = PeerVerifyResult(
          false,
          '通道未注册（致命）：原生层未能挂接到本 App 进程，请立即上报并导出'
              ' peer-loc-fatal 日志',
          {'fatal': 'unregistered'});
      // 致命态：原文 + 栈摘要 + 结果 + status（此时 status 亦不可用 → unregistered）
      await _recordToggle('toggle-missing-plugin', res,
          extra: {'exception': e.toString(), 'stack': brief, 'enable': on});
      await _recordExpected(on, false);
      return res;
    }
    final res = PeerVerifyResult(
        false,
        '启用失败（内部错误）：${e.toString().substring(0, e.toString().length.clamp(0, 120))}',
        const {});
    await _recordToggle('toggle-error', res,
        extra: {'exception': e.toString(), 'stack': brief, 'enable': on});
    await _recordExpected(on, false);
    return res;
  }
}

String _stackBrief(StackTrace stack) =>
    stack.toString().split('\n').take(10).join(' | ');

/// 期望态落盘（fix6 A1）：只在「开关被拨到关闭」或「开启成功」时写入。
/// 开启失败（权限缺失/通道未注册）不写——避免制造「期望开」的假象。
Future<void> _recordExpected(bool enable, bool ok) async {
  if (!enable) {
    await writePeerExpectedOn(false);
    return;
  }
  if (ok) await writePeerExpectedOn(true);
}

/// 期望态读回（卡面提示用；**只读**，不参与开关判定、不触发采集）。
Future<bool> peerExpectedOn() => readPeerExpectedOn();

/// 诊断落盘：toggle 结构化结果 + status 快照一并写入（Dart 侧文件）。
/// 诊断链失败不影响开关链（peerFatalRecord 内部吞异常）。
Future<void> _recordToggle(String event, PeerVerifyResult res,
    {Map<String, Object?> extra = const {}}) async {
  await peerFatalRecord(event, {
    'ok': res.ok,
    'reason': res.reason,
    'detail': res.detail,
    'status': await _statusSnapshot(),
    ...extra,
  });
}

/// status 快照：通道不可用时给明确标记，不抛。
Future<Object?> _statusSnapshot() async {
  try {
    return await _channel.invokeMethod<Map<Object?, Object?>>('status');
  } on MissingPluginException {
    return 'unregistered';
  } catch (e) {
    return 'error: $e';
  }
}

/// 开关态查询（原生单一事实源）：页面进入与 toggle 后回填。
Future<Map<Object?, Object?>> peerVerifyStatus() async {
  try {
    final r = await _channel
        .invokeMethod<Map<Object?, Object?>>('status');
    return r ?? const {};
  } catch (e) {
    peerLocLog('status error: $e');
    return const {};
  }
}

/// fatal 日志导出（验证卡导出/分享入口）。
///
/// fix5 主从关系（定夺令）：**主路径 = Dart 侧文件**（peer_fatal_log.dart），
/// 原生 exportFatal 降为补充源——通道未注册（MissingPluginException）时
/// 补充源整段消失，导出仍须凭 Dart 侧文件成功返回，不许抛、不许空。
Future<({String path, String content})> exportPeerFatalLog() async {
  final dart = await peerFatalRead();
  var nativePath = '';
  var nativeContent = '';
  try {
    final r = await _channel.invokeMethod<Map<Object?, Object?>>('exportFatal');
    nativePath = (r?['path'] as String?) ?? '';
    nativeContent = (r?['content'] as String?) ?? '';
  } on MissingPluginException {
    // 通道未注册：补充源缺位属预期，主路径照常返回（定夺令约束②）
    peerLocLog('exportFatal: native channel unregistered (Dart file is primary)');
  } catch (e) {
    peerLocLog('exportFatal: native supplement failed ($e)');
  }
  if (dart.content.isNotEmpty) {
    final extra = nativeContent.isEmpty
        ? ''
        : '\n\n──── 原生补充源（${nativePath.isEmpty ? '无路径' : nativePath}）────\n'
            '$nativeContent';
    return (path: dart.path, content: '${dart.content}$extra');
  }
  return (path: nativePath, content: nativeContent);
}

/// App 启动钩子：以原生 status 回填开关态；冷启动传 [resumeIfExpected]=true 时
/// 若持久化期望态为开且当前采集未运行，则按原路径自动恢复后台定位采集。
Future<void> peerLocatorAutoStart({bool resumeIfExpected = false}) async {
  try {
    final status = await peerVerifyStatus();
    peerVerifyOn = status['running'] == true;
    peerLocLog('auto-start check: running=${status['running']} '
        'received=${status['received']}');
    if (resumeIfExpected && !peerVerifyOn) {
      final expected = await readPeerExpectedOn();
      if (expected) {
        final res = await peerVerifyToggle(true);
        peerVerifyOn = res.ok;
        peerLocLog('auto-start resume: ok=${res.ok} reason=${res.reason}');
      }
    }
  } catch (e) {
    peerLocLog('auto-start error: $e');
  }
}

/// 电池优化豁免状态（fix6 B3）：true=已豁免 / false=未豁免 / null=读不到
/// （通道不可用）。系统 API 读回，Dart 不做任何推断。
Future<bool?> peerBatteryIgnored() async {
  try {
    return await _channel.invokeMethod<bool>('batteryIgnored');
  } on MissingPluginException {
    return null;
  } catch (_) {
    return null;
  }
}

/// 拉起系统「忽略电池优化」对话框（fix6 B3）。
/// 返回值只代表**意图已送出**；是否豁免必须随后用 [peerBatteryIgnored] 复读。
Future<bool> requestPeerBatteryExemption() async {
  try {
    return await _channel.invokeMethod<bool>('requestIgnoreBattery') == true;
  } catch (e) {
    peerLocLog('requestIgnoreBattery error: $e');
    return false;
  }
}
