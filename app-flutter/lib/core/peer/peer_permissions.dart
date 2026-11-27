/// Proactive permission snapshot, diagnostics snapshot, OEM guidance, and
/// uniform network icon mapping for Peer Report modules.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:love_space/core/theme/app_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

const MethodChannel _peerNativeChannel = MethodChannel('peer_loc/native');

const String kPeerPermPromptLastAtKey = 'peer_perm_prompt_last_at_ms';
const Duration kPeerPermPromptCooldown = Duration(hours: 24);
const String kFirstInstallPermGuideDoneKey = 'first_install_perm_guide_done_v1';

/// Maps peer network string (`wifi` / `cell` / `none`) to the semantic Material icon.
IconData networkIconFor(String? net) {
  switch ((net ?? '').trim().toLowerCase()) {
    case 'wifi':
      return AppIcons.wifi;
    case 'cell':
    case 'cellular':
    case 'mobile':
      return AppIcons.cellular;
    case 'none':
    case 'offline':
      return AppIcons.offline;
    default:
      return AppIcons.networkOther;
  }
}

class PeerPermissionSnapshot {
  const PeerPermissionSnapshot({
    required this.fine,
    required this.background,
    required this.usage,
    required this.notification,
    required this.batteryIgnored,
    required this.manufacturer,
    required this.autoStartIntentSupported,
    required this.channelAvailable,
  });

  final bool fine;
  final bool background;
  final bool usage;
  final bool notification;
  final bool batteryIgnored;
  final String manufacturer;
  final bool autoStartIntentSupported;
  final bool channelAvailable;

  static const PeerPermissionSnapshot unavailable = PeerPermissionSnapshot(
    fine: false,
    background: false,
    usage: false,
    notification: false,
    batteryIgnored: false,
    manufacturer: '',
    autoStartIntentSupported: false,
    channelAvailable: false,
  );

  bool get hasMissingCritical =>
      channelAvailable && (!fine || !background || !usage);

  bool get allGranted =>
      fine && background && usage && notification && batteryIgnored;

  factory PeerPermissionSnapshot.fromMap(Map<Object?, Object?> m) {
    return PeerPermissionSnapshot(
      fine: m['fine'] == true,
      background: m['background'] == true,
      usage: m['usage'] == true,
      notification: m['notification'] == true,
      batteryIgnored: m['batteryIgnored'] == true,
      manufacturer: (m['manufacturer'] ?? '').toString().toLowerCase(),
      autoStartIntentSupported: m['autoStartIntentSupported'] == true,
      channelAvailable: true,
    );
  }
}

class PeerDiagnosticsSnapshot {
  const PeerDiagnosticsSnapshot({
    required this.locRunning,
    required this.locReceived,
    required this.locQueue,
    required this.locReported,
    required this.locDropped,
    required this.locStill,
    required this.heartbeatArmed,
    required this.heartbeatTicks,
    required this.locError,
    required this.lastReceivedAtMs,
    required this.lastFlushAtMs,
    required this.stateEnabled,
    required this.stateEmitted,
    required this.lastStateEmitAtMs,
    required this.unlockPending,
    required this.inScreenSession,
    required this.usageGranted,
    required this.usageEnabled,
    required this.usageEmitted,
    required this.usageCursorMs,
    required this.lastUsagePullAtMs,
    required this.lastUsageEmitAtMs,
    required this.lastUsageRawCount,
    required this.policySummary,
    required this.policyHalted,
    required this.permissions,
    required this.channelAvailable,
    this.debounceState = '',
    this.anchorLockCount = 0,
    this.droppedAccuracy = 0,
    this.droppedSpike = 0,
    this.droppedBounce = 0,
    this.droppedStationary = 0,
    this.backoffStep = 0,
    this.mapStatus = '',
    this.mapErrorCode = '',
    this.mapErrorMessage = '',
    this.mapErrorCallback = '',
    this.mapErrorAtMs,
  });

  final bool locRunning;
  final int locReceived;
  final int locQueue;
  final int locReported;
  final int locDropped;
  final bool locStill;
  final bool heartbeatArmed;
  final int heartbeatTicks;
  final String? locError;
  final int? lastReceivedAtMs;
  final int? lastFlushAtMs;
  final bool stateEnabled;
  final int stateEmitted;
  final int? lastStateEmitAtMs;
  final int unlockPending;
  final bool inScreenSession;
  final bool usageGranted;
  final bool usageEnabled;
  final int usageEmitted;
  final int? usageCursorMs;
  final int? lastUsagePullAtMs;
  final int? lastUsageEmitAtMs;
  final int lastUsageRawCount;
  final String policySummary;
  final bool policyHalted;
  final PeerPermissionSnapshot permissions;
  final bool channelAvailable;
  final String debounceState;
  final int anchorLockCount;
  final int droppedAccuracy;
  final int droppedSpike;
  final int droppedBounce;
  final int droppedStationary;
  final int backoffStep;
  final String mapStatus;
  final String mapErrorCode;
  final String mapErrorMessage;
  final String mapErrorCallback;
  final int? mapErrorAtMs;

  static const PeerDiagnosticsSnapshot unavailable = PeerDiagnosticsSnapshot(
    locRunning: false,
    locReceived: 0,
    locQueue: 0,
    locReported: 0,
    locDropped: 0,
    locStill: false,
    heartbeatArmed: false,
    heartbeatTicks: 0,
    locError: null,
    lastReceivedAtMs: null,
    lastFlushAtMs: null,
    stateEnabled: false,
    stateEmitted: 0,
    lastStateEmitAtMs: null,
    unlockPending: 0,
    inScreenSession: false,
    usageGranted: false,
    usageEnabled: false,
    usageEmitted: 0,
    usageCursorMs: null,
    lastUsagePullAtMs: null,
    lastUsageEmitAtMs: null,
    lastUsageRawCount: 0,
    policySummary: '',
    policyHalted: false,
    permissions: PeerPermissionSnapshot.unavailable,
    channelAvailable: false,
  );

  static int _asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);

  static int? _asPosInt(Object? v) {
    final i = _asInt(v);
    return i > 0 ? i : null;
  }

  factory PeerDiagnosticsSnapshot.fromMap(Map<Object?, Object?> m) {
    final loc = (m['location'] as Map?)?.cast<Object?, Object?>() ?? const {};
    final st = (m['state'] as Map?)?.cast<Object?, Object?>() ?? const {};
    final us = (m['usage'] as Map?)?.cast<Object?, Object?>() ?? const {};
    final pm = (m['permissions'] as Map?)?.cast<Object?, Object?>();
    final mp = (m['map'] as Map?)?.cast<Object?, Object?>() ?? const {};
    final errRaw = loc['error']?.toString();
    return PeerDiagnosticsSnapshot(
      locRunning: loc['running'] == true,
      locReceived: _asInt(loc['received']),
      locQueue: _asInt(loc['queue']),
      locReported: _asInt(loc['reported']),
      locDropped: _asInt(loc['dropped']),
      locStill: loc['still'] == true,
      heartbeatArmed: loc['heartbeatArmed'] == true,
      heartbeatTicks: _asInt(loc['heartbeatTicks']),
      locError: (errRaw == null || errRaw.isEmpty) ? null : errRaw,
      lastReceivedAtMs: _asPosInt(loc['lastReceivedAt']),
      lastFlushAtMs: _asPosInt(m['lastFlushAt']),
      stateEnabled: st['enabled'] == true,
      stateEmitted: _asInt(st['emitted']),
      lastStateEmitAtMs: _asPosInt(m['lastStateEmitAt']),
      unlockPending: _asInt(st['unlockPending']),
      inScreenSession: st['inScreenSession'] == true,
      usageGranted: us['granted'] == true,
      usageEnabled: us['enabled'] == true,
      usageEmitted: _asInt(us['emitted']),
      usageCursorMs: _asPosInt(us['cursor']),
      lastUsagePullAtMs: _asPosInt(m['lastUsagePullAt']),
      lastUsageEmitAtMs: _asPosInt(m['lastUsageEmitAt']),
      lastUsageRawCount: _asInt(m['lastUsageRawCount']),
      policySummary: (m['policySummary'] ?? '').toString(),
      policyHalted: m['policyHalted'] == true,
      permissions: pm == null
          ? PeerPermissionSnapshot.unavailable
          : PeerPermissionSnapshot.fromMap(pm),
      channelAvailable: true,
      debounceState: (loc['debounceState'] ?? '').toString(),
      anchorLockCount: _asInt(loc['anchorLockCount']),
      droppedAccuracy: _asInt(loc['droppedAccuracy']),
      droppedSpike: _asInt(loc['droppedSpike']),
      droppedBounce: _asInt(loc['droppedBounce']),
      droppedStationary: _asInt(loc['droppedStationary']),
      backoffStep: _asInt(loc['backoffStep']),
      mapStatus: (mp['status'] ?? '').toString(),
      mapErrorCode: (mp['errorCode'] ?? '').toString(),
      mapErrorMessage: (mp['errorMessage'] ?? '').toString(),
      mapErrorCallback: (mp['callback'] ?? '').toString(),
      mapErrorAtMs: _asPosInt(mp['errorAt']),
    );
  }
}

Future<PeerPermissionSnapshot> peerPermissionStatus({bool bypassPlatform = false}) async {
  if (kIsWeb && !bypassPlatform) {
    return PeerPermissionSnapshot.unavailable;
  }
  try {
    final res = await _peerNativeChannel
        .invokeMethod<Map<Object?, Object?>>('permissions');
    if (res == null) return PeerPermissionSnapshot.unavailable;
    return PeerPermissionSnapshot.fromMap(res);
  } on MissingPluginException {
    return PeerPermissionSnapshot.unavailable;
  } on PlatformException {
    return PeerPermissionSnapshot.unavailable;
  }
}

Future<PeerDiagnosticsSnapshot> peerDiagnosticsStatus({bool bypassPlatform = false}) async {
  if (kIsWeb && !bypassPlatform) {
    return PeerDiagnosticsSnapshot.unavailable;
  }
  try {
    final res = await _peerNativeChannel
        .invokeMethod<Map<Object?, Object?>>('diagnostics');
    if (res == null) return PeerDiagnosticsSnapshot.unavailable;
    return PeerDiagnosticsSnapshot.fromMap(res);
  } on MissingPluginException {
    return PeerDiagnosticsSnapshot.unavailable;
  } on PlatformException {
    return PeerDiagnosticsSnapshot.unavailable;
  }
}

Future<bool> _invokeBool(String method, [Map<String, Object?>? args]) async {
  try {
    final res = await _peerNativeChannel.invokeMethod<Object?>(method, args);
    return res == true;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

Future<bool> peerRequestLocationPermission({bool background = false}) =>
    _invokeBool('requestLocationPermission', {'background': background});

Future<bool> peerRequestNotificationPermission() =>
    _invokeBool('requestNotificationPermission');

Future<bool> peerOpenAppSettings() => _invokeBool('openAppSettings');

Future<bool> peerOpenNotificationSettings() =>
    _invokeBool('openNotificationSettings');

Future<bool> peerOpenAutoStartSettings() =>
    _invokeBool('openAutoStartSettings');

Future<bool> peerRequestIgnoreBatterySetting() =>
    _invokeBool('requestIgnoreBattery');

String autoStartGuideForManufacturer(String manufacturer) {
  final m = manufacturer.trim().toLowerCase();
  if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) {
    return '小米 /澎湃 OS：设置 → 应用设置 → 应用管理 → 恋爱空间 → 开启「自启动」，并在「省电策略」中选「无限制」。';
  }
  if (m.contains('oppo') || m.contains('realme') || m.contains('oneplus')) {
    return 'OPPO / ColorOS：设置 → 应用 → 自启动管理中允许「恋爱空间」，并在耗电管理中允许完全后台行为。';
  }
  if (m.contains('vivo') || m.contains('iqoo')) {
    return 'vivo / iQOO：i 管家 → 应用管理 → 权限管理 → 自启动中开启「恋爱空间」，并将后台高耗电设为允许。';
  }
  if (m.contains('huawei') || m.contains('honor')) {
    return '华为 / 荣耀：手机管家 → 应用启动管理 → 找到「恋爱空间」，关闭自动管理并打开允许自启动、后台活动。';
  }
  return '请在系统设置 → 应用管理 → 恋爱空间 中允许自启动与后台运行，避免息屏后被系统清理。';
}

Future<bool> shouldShowProactivePermissionPrompt(
  PeerPermissionSnapshot snap, {
  DateTime? now,
}) async {
  if (!snap.hasMissingCritical) return false;
  final prefs = await SharedPreferences.getInstance();
  final lastMs = prefs.getInt(kPeerPermPromptLastAtKey);
  if (lastMs == null || lastMs <= 0) return true;
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  return (nowMs - lastMs) >= kPeerPermPromptCooldown.inMilliseconds;
}

Future<void> markProactivePermissionPromptShown({DateTime? now}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(
    kPeerPermPromptLastAtKey,
    (now ?? DateTime.now()).millisecondsSinceEpoch,
  );
}

/// 首次安装引导判定：原生通道可用、尚有未授权限，且本机尚未记录过首次引导完成标记。
Future<bool> shouldShowFirstInstallPermissionGuide(
  PeerPermissionSnapshot snap,
) async {
  if (!snap.channelAvailable || snap.allGranted) return false;
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(kFirstInstallPermGuideDoneKey) != true;
}

/// 记录首次安装权限引导已弹出，并同步刷新 24h 冷却时间戳，避免同日进报备页重复弹窗。
Future<void> markFirstInstallPermissionGuideDone({DateTime? now}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(kFirstInstallPermGuideDoneKey, true);
  await prefs.setInt(
    kPeerPermPromptLastAtKey,
    (now ?? DateTime.now()).millisecondsSinceEpoch,
  );
}
