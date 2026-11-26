/// 2.8.7 设备状态事件的**呈现文案纯函数**（简行与状态卡共用）。
///
/// 单独抽出的理由：文案口径（「取不到 SSID 就只说类型」「已关闭不显示 0」）
/// 是容易被改坏的地方，做成纯函数才能用单测钉住；页面只负责排版。
library;

import 'peer_report_api.dart';

/// 时间线里一条事件的文案（**任何情况下都不许返回空串**）。
///
/// 优先级按施工令：**服务器现成的中文**（`summary`，空白行事故已由后端
/// `state_summary` 修掉）→ 状态事件按 `payload` 生成 → 按类型兜底。
/// 手填报备没有 summary 时退到备注，再不济给一句「报备」。
String timelineEventText(PeerEventItem e) {
  final s = e.summary.trim();
  if (s.isNotEmpty) return s;
  if (e.isStateEvent) return stateEventText(e); // 内含 payload→类型 双兜底
  if (e.isManualReport) {
    final note = e.note.trim();
    return note.isEmpty ? '报备' : note;
  }
  return '有一条动态';
}

/// 状态事件的一行文案（简行用）。
///
/// 未知类型回落到后端 `summary`（旧后端/未来新类型都不会出现空白行）。
String stateEventText(PeerEventItem e) {
  final text = _stateEventText(e);
  if (text.isNotEmpty) return text;
  // 双兜底（2026-11-26 真机事故）：后端没给 summary、payload 又是空的时候，
  // 早先版本会渲染出**一整行空白**。任何情况下都要有一句话。
  return _typeFallback(e.type);
}

String _typeFallback(String type) {
  switch (type) {
    case 'state.battery':
      return '电量发生变化';
    case 'state.net':
      return '网络发生变化';
    case 'state.unlock':
      return '有解锁';
    case 'state.screen':
      return '亮屏';
  }
  return '设备状态发生变化';
}

String _stateEventText(PeerEventItem e) {
  final p = e.payload;
  switch (e.type) {
    case 'state.battery':
      final level = (p['level'] as num?)?.toInt();
      final charging = p['charging'] == true;
      if (level == null) return e.summary;
      return charging ? '电量 $level%，充电中' : '电量 $level%';
    case 'state.net':
      final net = (p['net'] ?? '').toString();
      final ssid = (p['ssid'] ?? '').toString();
      switch (net) {
        case 'wifi':
          // SSID 取不到就只说类型：不许编一个「未知网络」出来
          return ssid.isEmpty ? '连上 Wi-Fi' : '连上 Wi-Fi（$ssid）';
        case 'cell':
          return '切到移动数据';
        case 'none':
          return '断开网络';
      }
      return e.summary;
    case 'state.unlock':
      final n = (p['count'] as num?)?.toInt();
      if (n == null) return e.summary;
      return '解锁 $n 次';
    case 'state.screen':
      final sec = (p['session_sec'] as num?)?.toInt();
      if (sec == null) return e.summary;
      return '亮屏 ${durationTextZh(sec)}';
  }
  return e.summary;
}

/// 秒 → 人话时长（`<1 分钟` / `12 分钟` / `1 小时 5 分钟`）。
String durationTextZh(int seconds) {
  if (seconds <= 0) return '不足 1 分钟';
  if (seconds < 60) return '不足 1 分钟';
  final m = seconds ~/ 60;
  if (m < 60) return '$m 分钟';
  final h = m ~/ 60;
  final rest = m % 60;
  return rest == 0 ? '$h 小时' : '$h 小时 $rest 分钟';
}

/// 状态卡里「今日亮屏」那一行的文案；`null` = 整行不渲染。
///
/// 🔴 对方关闭共享时不返回 0：那不是「没亮屏」，而是「看不到」。
String? peerScreenLine(bool closedOff, int screenSec, int unlocks) {
  if (closedOff) return null;
  if (screenSec <= 0 && unlocks <= 0) return null; // 今天还没有数据，不显示 0
  final parts = <String>[
    if (screenSec > 0) '亮屏 ${durationTextZh(screenSec)}',
    if (unlocks > 0) '解锁 $unlocks 次',
  ];
  return parts.join(' · ');
}
