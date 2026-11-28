/// 2.8.7 自动报备：设备状态采集的**端上聚合/节流纯函数**。
///
/// 为什么单独抽出来：阈值、窗口、会话口径是这段逻辑里唯一"会算错"的部分，
/// 挂在原生回调里就没法单测；这里全部做成无副作用的纯计算，原生侧只负责
/// 喂事件、取结果、入队（阈值与防抖口径见设计回执 §五）。
///
/// 🔴 本段不做静默期（机主改裁）：夜间照发，本地累计口径不变。
library;

/// 电量上报门限：变化 ≥2% 才报、充电状态翻转即时报（设计 §4.2）。
const int kStateBatteryDeltaPercent = 2;

/// 各类事件的最小上报间隔（防抖）。同一类在窗口内的重复读数一律丢弃。
const Duration kBatteryMinInterval = Duration(seconds: 60);
const Duration kNetMinInterval = Duration(seconds: 30);

/// SSID 变化的冷却：Wi-Fi 名在同一网络内会抖动（漫游/隐藏 SSID → 空串），
/// 5 分钟内只认一次，避免把 `home → '' → home` 刷成三条事件。
const Duration kSsidCooldown = Duration(minutes: 5);

/// 解锁聚合窗口（设计 §2.2：端上 10 分钟窗口聚合，不逐条）。
const Duration kUnlockWindow = Duration(minutes: 10);

/// 一条待入队的状态事件（与后端 payload 同形，未编码成 JSON）。
class StateSample {
  const StateSample(this.kind, this.payload);
  final String kind;
  final Map<String, Object?> payload;
}

/// 电量/充电采样门。
class BatteryGate {
  /// 「上次**上报过**的电量」——注意不是上次读数：逐 1% 变化的读数如果跟读数
  /// 比，永远攒不到 2%（80→81→82 每次都只差 1）。必须与已报值比才能累积。
  int? _emittedLevel;

  /// 上次**看到的**充电状态，用于识别翻转（翻转与累积无关，看到即算）。
  bool? _seenCharging;
  int? _lastEmitMs;

  /// 喂一次采样；返回 null = 不达门限（静默丢弃），非 null = 该入队。
  ///
  /// 判定顺序很重要：**充电状态翻转优先于百分比阈值**——插上充电的瞬间
  /// 即使电量没动也是用户关心的信号；反之拔掉充电同样。
  StateSample? onReading({required int level, required bool charging, required int nowMs}) {
    if (level < 0 || level > 100) return null; // 读不到（原生给 -1）不报

    final flipped = _seenCharging != null && _seenCharging != charging;
    _seenCharging = charging;

    final emitted = _emittedLevel;
    final moved = emitted == null || (level - emitted).abs() >= kStateBatteryDeltaPercent;
    if (!flipped && !moved) return null;

    final last = _lastEmitMs;
    if (last != null && nowMs - last < kBatteryMinInterval.inMilliseconds) {
      // 防抖窗口内压住，但**不更新已报值**——下一次读数仍与旧值比，
      // 变化不会因为被压住而丢掉。
      return null;
    }
    _lastEmitMs = nowMs;
    _emittedLevel = level;
    return StateSample('state.battery', {'level': level, 'charging': charging});
  }

  /// 用于「重新开始采集」时清基线（toggle on）。
  void reset() {
    _emittedLevel = null;
    _seenCharging = null;
    _lastEmitMs = null;
  }
}

/// 网络类型/SSID 采样门。
class NetGate {
  String? _lastNet;
  String? _lastSsid;
  int? _lastEmitMs;
  int? _lastSsidEmitMs;

  StateSample? onNetwork({required String net, String ssid = '', required int nowMs}) {
    if (!const {'wifi', 'cell', 'none'}.contains(net)) return null; // 未知类型不报
    final netChanged = _lastNet != null && _lastNet != net;
    final first = _lastNet == null;
    final ssidChanged = net == 'wifi' && _lastSsid != null && _lastSsid != ssid;
    // 与 Kotlin StateGates.net 逐字一致（2.8.7 傍晚批 1-2 采集侧）：
    // ① 从「断网」恢复必报；② Wi-Fi 初连 SSID 由空串补齐必报。
    final recoveredFromNone = _lastNet == 'none' && net != 'none';
    final ssidResolved =
        net == 'wifi' && _lastNet == 'wifi' && (_lastSsid ?? '').isEmpty && ssid.isNotEmpty;

    if (!first && !netChanged && !ssidChanged && !ssidResolved && !recoveredFromNone) {
      // 🔴 基线只在真正上报后才前进：被防抖压住时保留旧基线，否则切换被永久吞掉
      return null;
    }
    _lastNet = net;
    _lastSsid = ssid;

    // SSID 抖动单独冷却；网络类型变化 / 断网恢复 / SSID 补齐不受 SSID 冷却影响
    final lastSsid = _lastSsidEmitMs;
    if (ssidChanged && !netChanged && !recoveredFromNone &&
        lastSsid != null &&
        nowMs - lastSsid < kSsidCooldown.inMilliseconds) {
      return null;
    }

    final last = _lastEmitMs;
    if (!recoveredFromNone && !ssidResolved &&
        last != null && nowMs - last < kNetMinInterval.inMilliseconds) {
      return null;
    }

    _lastEmitMs = nowMs;
    if (net == 'wifi') _lastSsidEmitMs = nowMs;
    return StateSample('state.net', {
      'net': net,
      // 取不到 SSID 就降级 type-only：给空串，绝不伪造名字
      'ssid': net == 'wifi' ? ssid : '',
    });
  }

  void reset() {
    _lastNet = null;
    _lastSsid = null;
    _lastEmitMs = null;
    _lastSsidEmitMs = null;
  }
}

/// 解锁窗口聚合器。
class UnlockAggregator {
  /// 可空：0 是合法时间戳（测试/冷启动），不能拿它当"未开始"的哨兵。
  int? _windowStartMs;
  int _count = 0;

  /// 记一次解锁。
  void onUnlock(int nowMs) {
    _windowStartMs ??= nowMs;
    _count += 1;
  }

  /// 取出已满窗口的聚合（不足一窗返回 null）。
  StateSample? drainIfDue(int nowMs) {
    final start = _windowStartMs;
    if (_count == 0 || start == null) return null;
    if (nowMs - start < kUnlockWindow.inMilliseconds) return null;
    return drain(nowMs: nowMs);
  }

  /// 强制取出当前窗口（满窗判定由调用方决定）。
  ///
  /// [nowMs] 给了就按实际跨度算 `window_sec`（stop 时可能不足一窗），
  /// 不给则按整窗 `kUnlockWindow` 报——两种都是真实跨度，不硬编。
  StateSample? drain({int? nowMs}) {
    final start = _windowStartMs;
    if (_count == 0 || start == null) return null;
    final spanSec = nowMs == null
        ? kUnlockWindow.inSeconds
        : ((nowMs - start) / 1000).round().clamp(0, kUnlockWindow.inSeconds);
    final sample = StateSample('state.unlock', {
      'count': _count,
      'window_sec': spanSec,
    });
    _count = 0;
    _windowStartMs = null;
    return sample;
  }

  int get pending => _count;
}

/// 亮屏会话跟踪：ON 记起点，OFF 算时长。
class ScreenSessionTracker {
  int? _onMs;

  void onScreenOn(int nowMs) => _onMs ??= nowMs;

  /// 亮屏结束；返回会话事件（未记录起点 / 时长为 0 → null 不报）。
  StateSample? onScreenOff(int nowMs) {
    final start = _onMs;
    _onMs = null;
    if (start == null) return null;
    final sec = ((nowMs - start) / 1000).round();
    if (sec <= 0) return null;
    return StateSample('state.screen', {'session_sec': sec, 'on': false});
  }

  bool get inSession => _onMs != null;
}
