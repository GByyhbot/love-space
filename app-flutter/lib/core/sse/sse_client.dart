/// SSE 客户端（方案 v2 阶段 1 打底，聊天页直接复用）。
/// 契约（阶段 0 实测，见 api-samples/05）：
/// GET /api/events 为无限流——首行 `retry: 3000`，随后 `: ready` / `: heartbeat`
/// 注释（约 2s 一次），变化时推 `data: {...}`（rev + refresh/chat/other 标志）。
/// 铁律：无限流端点绝不能用普通 GET（心跳让读超时永不触发 → 永久挂起），
/// 必须流式读取；断线按 retry 起步指数退避封顶 30s；进后台断开、回前台重连补拉。
library;

import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../config.dart';

class SseEvent {
  const SseEvent({required this.raw, this.chat = false, this.other = false, this.refresh = false});
  final String raw;
  final bool chat;
  final bool other;
  final bool refresh;
}

enum SsePhase { idle, connecting, connected, stopped, unauthorized }

class SseState {
  const SseState({required this.phase, this.lastError});
  final SsePhase phase;
  final String? lastError;
}

class SseClient extends Notifier<SseState> {
  bool _running = false;
  bool _disposed = false;
  bool _foreground = true;
  int _attempt = 0;
  Timer? _backoff;
  AppLifecycleListener? _lifecycle;
  StreamSubscription<List<int>>? _streamSub;
  final _eventsController = StreamController<SseEvent>.broadcast();

  /// 上层订阅此流获取增量事件（chat/other），据此决定重拉范围
  Stream<SseEvent> get events => _eventsController.stream;

  @override
  SseState build() {
    ref.onDispose(_teardown);
    _lifecycle = AppLifecycleListener(onPause: _pause, onResume: _resume, onDetach: _teardown);
    Future.microtask(_connect); // 认证态就绪后再由调用方 start；这里先待命
    return const SseState(phase: SsePhase.idle);
  }

  void start() {
    if (_running) return;
    _running = true;
    _disposed = false;
    _foreground = true;
    _attempt = 0;
    _connect();
  }

  void stop() {
    _running = false;
    _backoff?.cancel();
    state = const SseState(phase: SsePhase.stopped);
  }

  Future<void> _connect() async {
    if (_disposed || !_running || !_foreground) return;
    state = const SseState(phase: SsePhase.connecting);
    final Dio sse;
    try {
      sse = await ref.read(dioProvider.future);
    } catch (e) {
      _scheduleRetry('dio 不可用: $e');
      return;
    }
    try {
      final rsp = await sse.get<ResponseBody>(
        AppConfig.ssePath,
        options: Options(responseType: ResponseType.stream, receiveTimeout: null),
      );
      if ((rsp.statusCode ?? 0) >= 300) {
        state = SseState(phase: SsePhase.stopped, lastError: 'HTTP ${rsp.statusCode}');
        return;
      }
      _attempt = 0;
      state = const SseState(phase: SsePhase.connected);
      String carry = '';
      StreamSubscription<List<int>>? sub;
      sub = rsp.data!.stream.listen((chunk) {
        if (_disposed || !_running || !_foreground) { sub?.cancel(); return; }
        carry += utf8.decode(chunk, allowMalformed: true);
        final parts = carry.split('\n');
        carry = parts.removeLast(); // 最后一行可能不完整，留回缓冲
        for (final raw in parts) {
          final line = raw.trim();
          if (line.isEmpty) continue;
          if (line.startsWith('retry:')) continue; // 已由常量约定
          if (line.startsWith(':')) continue;      // ready/heartbeat 注释
          if (line.startsWith('data:')) {
            final body = line.substring(5).trim();
            Map<String, dynamic>? j;
            try { j = jsonDecode(body) as Map<String, dynamic>; } catch (_) {}
            _eventsController.add(SseEvent(
              raw: body,
              chat: j?['chat'] == true,
              other: j?['other'] == true,
              refresh: j?['refresh'] == true,
            ));
          }
        }
      }, onDone: () {
        _scheduleRetry('stream ended');
      }, onError: (Object e) {
        _scheduleRetry(e.toString());
      });
      _streamSub = sub;
    } on DioException catch (e) {
      // 401 = 会话失效：不重连（全局 401 拦截已触发回登录）
      state = SseState(phase: SsePhase.stopped, lastError: '${e.response?.statusCode}');
      return;
    } catch (e) {
      _scheduleRetry(e.toString());
    }
  }

  void _scheduleRetry(String reason) {
    if (_disposed || !_running || !_foreground) return;
    _attempt += 1;
    final waitMs = (AppConfig.sseRetryBase.inMilliseconds * (1 << _attempt.clamp(0, 4)))
        .clamp(AppConfig.sseRetryBase.inMilliseconds, AppConfig.sseRetryCap.inMilliseconds);
    if (kDebugMode) debugPrint('[sse] $reason → 重连 #$_attempt in ${waitMs}ms');
    state = SseState(phase: SsePhase.idle, lastError: reason);
    _backoff = Timer(Duration(milliseconds: waitMs), _connect);
  }

  void _pause() {
    _foreground = false;
    _backoff?.cancel();
    state = const SseState(phase: SsePhase.stopped);
  }

  void _resume() {
    _foreground = true;
    _attempt = 0;
    if (_running) _connect();
  }

  void _teardown() {
    _disposed = true;
    _running = false;
    _backoff?.cancel();
    _streamSub?.cancel();
    _lifecycle?.dispose();
    _eventsController.close();
  }
}

final sseProvider = NotifierProvider<SseClient, SseState>(SseClient.new);

/// 上层订阅此流获取增量事件（chat/other），据此决定重拉范围
final sseEventsProvider = StreamProvider<SseEvent>((ref) {
  return ref.watch(sseProvider.notifier).events;
});
