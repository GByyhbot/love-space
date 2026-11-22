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

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';

const _channel = MethodChannel('peer_loc/native');

const _prefsKey = 'peer_verify_on';

/// 验证开关（App 冷启动按此自动恢复采集）。
bool peerVerifyOn = false;

void peerLocLog(String msg) =>
    debugPrint('[peer-loc] ${DateTime.now().millisecondsSinceEpoch} $msg');

/// App 启动钩子（main.dart 初始化后调用一次）：开关开 → 自动恢复采集。
Future<void> peerLocatorAutoStart() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    peerVerifyOn = prefs.getBool(_prefsKey) ?? false;
    peerLocLog('auto-start check: on=$peerVerifyOn');
    if (!peerVerifyOn) return;
    final ok = await _ensurePermission();
    if (!ok) {
      peerLocLog('auto-start skipped: permission not granted');
      return; // 不反复弹窗：未授权保持开关但本次不启，下次 tap 再引导
    }
    await _startNative();
  } catch (e) {
    peerLocLog('auto-start error: $e');
  }
}

/// 开关切换（验证包临时开关行调用）。开启走权限引导，未授则保持关。
Future<bool> peerVerifyToggle(bool on) async {
  if (on) {
    final ok = await _ensurePermission();
    if (!ok) {
      peerLocLog('toggle-on aborted: permission');
      peerVerifyOn = false;
      await _persist(false);
      return false;
    }
    final started = await _startNative();
    peerVerifyOn = started;
    await _persist(started);
    return started;
  }
  peerVerifyOn = false;
  await _persist(false);
  try {
    await _channel.invokeMethod('stop');
  } catch (e) {
    peerLocLog('stop error: $e');
  }
  return false;
}

Future<bool> _persist(bool v) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_prefsKey, v);
  return v;
}

/// 权限引导（2.4.6 风格：一次引导不反复弹）。
/// always 未授时先 in-use → 系统「始终允许」选项（Android 10+ 单独页）。
Future<bool> _ensurePermission() async {
  var perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied) {
    perm = await Geolocator.requestPermission();
  }
  if (perm == LocationPermission.deniedForever) {
    peerLocLog('permission deniedForever -> openAppSettings 兜底');
    return false;
  }
  if (perm == LocationPermission.whileInUse) {
    // 「始终允许」单独引导（Android 10+ 需系统设置页单独授予）
    perm = await Geolocator.requestPermission();
    if (perm != LocationPermission.always) {
      peerLocLog('background location not granted (perm=$perm)');
      return false;
    }
  }
  return perm == LocationPermission.always || perm == LocationPermission.whileInUse;
}

Future<bool> _startNative() async {
  try {
    // 会话凭据：secure_storage 正本（api_client 同源）→ 原生 Cookie
    final token = await readSessionToken();
    if (token == null || token.isEmpty) {
      peerLocLog('start aborted: no session token');
      return false;
    }
    final base = await readLastRoute();
    if (base == null || base.isEmpty) {
      peerLocLog('start aborted: no base url');
      return false;
    }
    await _channel.invokeMethod(
        'start', {'cookie': 'love_session=$token', 'baseUrl': base});
    peerLocLog('native start ok (base=$base)');
    return true;
  } catch (e) {
    peerLocLog('start error: $e');
    return false;
  }
}

/// （保留）JSON 序列化占位：原生层 JSON 直接构建，Dart 侧无序列化职责。
String debugDump(Object o) => jsonEncode(o);
