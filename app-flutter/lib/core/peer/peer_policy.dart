/// 2.8.7 全量施工令 · 分档策略（policy v2，客户端模型）。
///
/// 与服务端 `app/peer.py:DEFAULT_POLICY` **逐键同构**：缺键即缺省（服务端
/// normalize_policy 也会兜），所以旧后端（无 policy）解析出来就是「全最高档」，
/// 老包读到多出来的 policy 键也不会炸。
///
/// 🔴 单一事实源是 policy，四开关是它的投影（映射表见服务端 SWITCH_MAP_DOC）；
/// 客户端永远 `copyWith` 后**整对象提交**（PUT 覆盖全部键，既有教训）。
library;

/// 位置与轨迹档位。
enum LocLevel {
  exact('exact', '精确轨迹'),
  street('street', '仅街区'),
  off('off', '关闭');

  const LocLevel(this.wire, this.label);
  final String wire;
  final String label;

  static LocLevel fromWire(Object? v) =>
      LocLevel.values.firstWhere((e) => e.wire == v, orElse: () => LocLevel.exact);
}

/// 手机使用档位。
enum UsageLevel {
  full('full', '时长+分布'),
  screenOnly('screen_only', '仅亮灭屏'),
  off('off', '关闭');

  const UsageLevel(this.wire, this.label);
  final String wire;
  final String label;

  static UsageLevel fromWire(Object? v) => UsageLevel.values
      .firstWhere((e) => e.wire == v, orElse: () => UsageLevel.full);
}

/// 软件记录档位。
enum AppLevel {
  stream('stream', '精确时间流'),
  top5('top5', '仅 Top5'),
  off('off', '关闭');

  const AppLevel(this.wire, this.label);
  final String wire;
  final String label;

  static AppLevel fromWire(Object? v) =>
      AppLevel.values.firstWhere((e) => e.wire == v, orElse: () => AppLevel.stream);
}

/// 网络档位。
enum NetLevel {
  ssid('ssid', '显示 SSID'),
  typeOnly('type_only', '仅网络类型'),
  off('off', '关闭');

  const NetLevel(this.wire, this.label);
  final String wire;
  final String label;

  static NetLevel fromWire(Object? v) =>
      NetLevel.values.firstWhere((e) => e.wire == v, orElse: () => NetLevel.ssid);
}

class PeerPolicy {
  const PeerPolicy({
    this.globalOff = false,
    this.pausedUntil,
    this.locLevel = LocLevel.exact,
    this.usageLevel = UsageLevel.full,
    this.appLevel = AppLevel.stream,
    this.netLevel = NetLevel.ssid,
    this.battery = true,
    this.batteryAlert = true,
    this.sensitivePkgs = const <String>[],
    this.foldShort = true,
  });

  /// 完全关闭报备（一停全停）。
  final bool globalOff;

  /// 定时暂停截止（unix 秒）；null = 未暂停。
  final double? pausedUntil;

  final LocLevel locLevel;
  final UsageLevel usageLevel;
  final AppLevel appLevel;
  final NetLevel netLevel;

  /// 电量与充电上报开关。
  final bool battery;

  /// 低电量（<20%）提醒开关。
  final bool batteryAlert;

  /// 敏感应用包名清单（端侧脱敏用，真实包名不出设备）。
  final List<String> sensitivePkgs;

  /// 折叠 <10 秒的短暂切换。
  final bool foldShort;

  /// 与服务端 `DEFAULT_POLICY` 同构的缺省（全新用户；老用户由服务端按现状生成）。
  static const PeerPolicy defaults = PeerPolicy();

  static PeerPolicy fromJson(Object? raw) {
    final j = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
    final until = (j['paused_until'] as num?)?.toDouble();
    final pkgs = (j['sensitive_pkgs'] as List?)
            ?.map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    bool pick(String k, bool def) => j[k] is bool ? j[k] as bool : def;
    return PeerPolicy(
      globalOff: pick('global_off', false),
      pausedUntil: (until != null && until > 0) ? until : null,
      locLevel: LocLevel.fromWire(j['location_level']),
      usageLevel: UsageLevel.fromWire(j['usage_level']),
      appLevel: AppLevel.fromWire(j['app_level']),
      netLevel: NetLevel.fromWire(j['network_level']),
      battery: pick('battery', true),
      batteryAlert: pick('battery_alert', true),
      sensitivePkgs: pkgs,
      foldShort: pick('fold_short', true),
    );
  }

  Map<String, Object?> toJson() => {
        'global_off': globalOff,
        'paused_until': pausedUntil,
        'location_level': locLevel.wire,
        'usage_level': usageLevel.wire,
        'app_level': appLevel.wire,
        'network_level': netLevel.wire,
        'battery': battery,
        'battery_alert': batteryAlert,
        'sensitive_pkgs': sensitivePkgs,
        'fold_short': foldShort,
      };

  PeerPolicy copyWith({
    bool? globalOff,
    Object? pausedUntil = _unset,
    LocLevel? locLevel,
    UsageLevel? usageLevel,
    AppLevel? appLevel,
    NetLevel? netLevel,
    bool? battery,
    bool? batteryAlert,
    List<String>? sensitivePkgs,
    bool? foldShort,
  }) =>
      PeerPolicy(
        globalOff: globalOff ?? this.globalOff,
        pausedUntil: identical(pausedUntil, _unset)
            ? this.pausedUntil
            : pausedUntil as double?,
        locLevel: locLevel ?? this.locLevel,
        usageLevel: usageLevel ?? this.usageLevel,
        appLevel: appLevel ?? this.appLevel,
        netLevel: netLevel ?? this.netLevel,
        battery: battery ?? this.battery,
        batteryAlert: batteryAlert ?? this.batteryAlert,
        sensitivePkgs: sensitivePkgs ?? this.sensitivePkgs,
        foldShort: foldShort ?? this.foldShort,
      );

  /// 现在是否处于「已停用」（完全关闭 / 暂停未到期）。
  bool haltedAt(DateTime now) {
    if (globalOff) return true;
    final until = pausedUntil;
    if (until == null) return false;
    return until > now.millisecondsSinceEpoch / 1000;
  }

  bool get isHalted => haltedAt(DateTime.now());

  /// 仅「暂停中」（不含完全关闭）——设置页两段文案分开用。
  bool get isPaused {
    final until = pausedUntil;
    return !globalOff && until != null && until > DateTime.now().millisecondsSinceEpoch / 1000;
  }

  /// 停用原因（'' = 未停用；与后端 reason 同口径）。
  String haltedReasonAt(DateTime now) {
    if (globalOff) return 'off';
    final until = pausedUntil;
    if (until != null && until > now.millisecondsSinceEpoch / 1000) return 'paused';
    return '';
  }

  String get haltedReason => haltedReasonAt(DateTime.now());

  /// 端侧是否需要启采集（状态 + 使用）。
  bool get collecting => !isHalted;

  @override
  bool operator ==(Object other) {
    if (other is! PeerPolicy) return false;
    if (other.globalOff != globalOff ||
        other.pausedUntil != pausedUntil ||
        other.locLevel != locLevel ||
        other.usageLevel != usageLevel ||
        other.appLevel != appLevel ||
        other.netLevel != netLevel ||
        other.battery != battery ||
        other.batteryAlert != batteryAlert ||
        other.foldShort != foldShort) {
      return false;
    }
    if (other.sensitivePkgs.length != sensitivePkgs.length) return false;
    for (var i = 0; i < sensitivePkgs.length; i++) {
      if (other.sensitivePkgs[i] != sensitivePkgs[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(globalOff, pausedUntil, locLevel, usageLevel,
      appLevel, netLevel, battery, batteryAlert, foldShort, sensitivePkgs.length);

  @override
  String toString() => 'PeerPolicy(off:$globalOff, until:$pausedUntil, '
      'loc:${locLevel.wire}, usage:${usageLevel.wire}, app:${appLevel.wire}, '
      'net:${netLevel.wire}, battery:$battery, alert:$batteryAlert, '
      'pkgs:${sensitivePkgs.length}, fold:$foldShort)';
}

const Object _unset = Object();

/// 「暂停 2 小时」的截止时刻（unix 秒）。
double pauseUntilHours(DateTime now, int hours) =>
    now.add(Duration(hours: hours)).millisecondsSinceEpoch / 1000;

/// 「暂停到明早 8 点」的截止时刻：若已过今天 8 点，则取明天 8 点。
double pauseUntilNextMorning(DateTime now, {int hour = 8}) {
  var t = DateTime(now.year, now.month, now.day, hour);
  if (!t.isAfter(now)) t = t.add(const Duration(days: 1));
  return t.millisecondsSinceEpoch / 1000;
}
