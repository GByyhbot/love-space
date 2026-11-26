/// 2.8.7 报备页「TA 的状态」卡的数据装配（**纯函数**，页面只负责排版）。
///
/// 单独抽成纯函数的理由：这张卡的四条铁律都是「容易在排版里被改坏」的口径，
/// 只有脱离 Widget 才钉得住：
/// ① **取不到数就整行不显示**（不写「未知」占位、更不写 0）；
/// ② 一行都取不到 → 返回 null，整卡不显示（不摆空壳卡）；
/// ③ 最后活跃超过 6 小时 → 明写「长时间无更新」（不拿「3 天前」装作没事）；
/// ④ 对方关闭共享时今日使用那行不显示（`closed_off` 的 0 是「看不到」）。
///
/// 数据来源全部既有两个 GET，**不新增接口、不新增轮询**：
/// `GET /api/peer/status`（battery/charging/net/wifi/updated/state_updated）
/// + `GET /api/peer/state-daily`（今日亮屏/解锁）。
library;

import 'peer_report_api.dart';
import 'peer_report_data.dart'
    show
        PeerLatest,
        absoluteTimeZh,
        batteryText,
        chargingText,
        relativeTimeZh;
import 'state_event_text.dart';

/// 「最后活跃」超过这个时长就明写「长时间无更新」。
const Duration kPeerStaleAfter = Duration(hours: 6);

/// 卡里的一行（[id] 只用于 UI 侧拼 key：`peer-card-battery` 等）。
class PeerStatusRow {
  const PeerStatusRow({
    required this.id,
    required this.label,
    required this.value,
    this.warn = false,
  });

  final String id;
  final String label;
  final String value;

  /// 只有「长时间无更新」为真（渲染成警示色）。
  final bool warn;
}

class PeerStatusCardData {
  const PeerStatusCardData({required this.rows, required this.stale});

  final List<PeerStatusRow> rows;

  /// 最后活跃超过 [kPeerStaleAfter]（无活跃时间时为 false）。
  final bool stale;

  bool get isEmpty => rows.isEmpty;
}

/// 装配状态卡；**返回 null = 整卡不显示**（一行都取不到）。
///
/// [peer] 为 null（对方从无定位快照）时同样返回 null：那种情况下没有任何
/// 可用数据，卡片会变成一个空壳，交给页面既有的空态文案说明。
PeerStatusCardData? buildPeerStatusCard({
  required PeerLatest? peer,
  PeerStateDaily? daily,
  DateTime? now,
}) {
  if (peer == null) return null;
  final rows = <PeerStatusRow>[];

  // ① 电量（+ 充电）：电量取不到就整行不显示；充电未知时只写百分比，
  //    不编「未充电」。电量 0 是**真实值**（电量耗尽），照常显示 0%。
  final b = peer.battery;
  if (b != null) {
    final c = peer.charging;
    rows.add(PeerStatusRow(
      id: 'battery',
      label: '电量',
      value: c == null
          ? batteryText(b)
          : '${batteryText(b)} · ${chargingText(c)}',
    ));
  }

  // ② 网络：Wi-Fi 有名字写名字，没名字只写类型；移动数据/无网络说人话。
  final net = _netValue(peer.net, peer.wifi);
  if (net != null) {
    rows.add(PeerStatusRow(id: 'net', label: '网络', value: net));
  }

  // ③ 最后活跃：定位与状态快照两个时刻取**较新**的那个（都是「有动静」）。
  final active = _latestActive(peer);
  var stale = false;
  if (active != null) {
    final at = DateTime.fromMillisecondsSinceEpoch((active * 1000).round());
    // 「超过 6 小时」按严格大于判：正好 6 小时不算超时
    stale = (now ?? DateTime.now()).difference(at) > kPeerStaleAfter;
    rows.add(PeerStatusRow(
      id: 'active',
      label: '最后活跃',
      warn: stale,
      value: stale
          ? '长时间无更新（最近一次 ${absoluteTimeZh(active)}）'
          : '${relativeTimeZh(active, now: now)} · ${absoluteTimeZh(active)}',
    ));
  }

  // ④ 今日使用（亮屏 + 解锁）：走既有 [peerScreenLine] 的同一口径——
  //    对方关闭共享、或今天还没有任何数据 → 返回 null，整行不显示。
  final d = daily;
  if (d != null) {
    final line =
        peerScreenLine(d.peerClosedOff, d.peerScreenSec, d.peerUnlocks);
    if (line != null) {
      rows.add(PeerStatusRow(id: 'usage', label: '今日使用', value: line));
    }
  }

  if (rows.isEmpty) return null;
  return PeerStatusCardData(rows: rows, stale: stale);
}

/// 定位时刻与状态快照时刻取较新者；两者都无效 → null。
double? _latestActive(PeerLatest p) {
  final loc = (p.updated != null && p.updated! > 0) ? p.updated : null;
  final state =
      (p.stateUpdated != null && p.stateUpdated! > 0) ? p.stateUpdated : null;
  if (loc == null) return state;
  if (state == null) return loc;
  return loc >= state ? loc : state;
}

/// 网络一行文案；`net` 缺失 → null（整行不显示）。
String? _netValue(String? net, String? wifi) {
  if (net == null || net.isEmpty) return null;
  switch (net) {
    case 'wifi':
      final ssid = (wifi ?? '').trim();
      // SSID 取不到就只说类型：不许编一个「未知网络」出来
      return ssid.isEmpty ? 'Wi-Fi' : 'Wi-Fi（$ssid）';
    case 'cell':
      return '移动数据';
    case 'none':
      return '无网络';
  }
  // 旧后端 / 未枚举取值：原样呈现，不猜测
  return net;
}
