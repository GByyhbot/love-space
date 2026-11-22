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
Future<PeerVerifyResult> peerVerifyToggle(bool on) async {
  try {
    final token = await readSessionToken();
    if (token == null || token.isEmpty) {
      peerLocLog('toggle aborted: no session token');
      return PeerVerifyResult(false, '未登录或会话已失效，请重新登录后再开启',
          {'fine': 'unknown', 'background': 'unknown'});
    }
    final base = await readLastRoute();
    if (base == null || base.isEmpty) {
      peerLocLog('toggle aborted: no base url');
      return PeerVerifyResult(false, '线路未就绪，请先登录并进入过空间后再开启',
          {'fine': 'unknown', 'background': 'unknown'});
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
    return PeerVerifyResult(ok, reason, detail);
  } catch (e, stack) {
    peerLocLog('toggle fatal: $e stack=${stack.toString().split('\n').take(10).join(' | ')}');
    return PeerVerifyResult(
        false,
        '启用失败（内部错误）：${e.toString().substring(0, e.toString().length.clamp(0, 120))}',
        const {});
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
Future<({String path, String content})> exportPeerFatalLog() async {
  final r = await _channel
      .invokeMethod<Map<Object?, Object?>>('exportFatal');
  return (
    path: (r?['path'] as String?) ?? '',
    content: (r?['content'] as String?) ?? '',
  );
}

/// App 启动钩子：以原生 status 回填开关态（无持久化——服务被杀即显示关）。
Future<void> peerLocatorAutoStart() async {
  try {
    final status = await peerVerifyStatus();
    peerVerifyOn = status['running'] == true;
    peerLocLog('auto-start check: running=${status['running']} '
        'received=${status['received']}');
  } catch (e) {
    peerLocLog('auto-start error: $e');
  }
}
