/// 2.8.0 第 0 步 fix6 · 期望态（用户意图）落盘（**独立模块**）。
///
/// 🔴 边界（三句）：
/// ① 期望态只用于**显示与恢复入口提示**——期望开而实态停时卡面出黄色
///    提示；**永不自动启动采集**（A2 自动恢复明确缓办，本模块不含任何
///    启动钩子）。
/// ② 实态的唯一事实源仍是原生 `status`；期望态不得参与开关判定，
///    也不得覆盖 status 的回填结果。
/// ③ 落盘/读回全走本模块，`peer_locator.dart` 只调用、不直引持久化包
///    （该文件有既有「peer 链禁 import 持久化插件」护栏，口径不变）。
///
/// 为什么独立成文件：与 peer_fatal_log.dart 同一模式——诊断/意图这类旁路
/// 状态不塞进胶水层，胶水层继续只做「搬运与渲染」。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// 期望态 key（本机偏好，等价 Web localStorage 口径）。
const String kPeerExpectedKey = 'peer_verify_expected_on';

/// 读期望态（缺失/异常一律按「关」，避免误报恢复提示）。
Future<bool> readPeerExpectedOn() async {
  try {
    final p = await SharedPreferences.getInstance();
    return p.getBool(kPeerExpectedKey) ?? false;
  } catch (_) {
    return false;
  }
}

/// 写期望态（尽力而为，失败不抛——不得因落盘失败打断开关链）。
Future<void> writePeerExpectedOn(bool on) async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kPeerExpectedKey, on);
  } catch (_) {
    // 静默：期望态是旁路信息，丢了只影响提示，不影响采集
  }
}
