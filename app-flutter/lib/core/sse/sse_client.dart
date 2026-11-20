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
  const SseEvent({required this.raw, this.chat = false, this.other = false, this.refresh = false, this.typing = false});
  final String raw;
  final bool chat;
  final bool other;
  final bool refresh;

  /// 2.4.10 第 08 项：对方正在输入（内存态信号；旧后端无此字段=false，
  /// 胶囊永不出现自然降级）。
  final bool typing;
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
  Timer? _watchdog;
  DateTime _lastDataAt = DateTime.now();
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
    // 2.5.10：10s 周期死链探测——25s 无任何数据（心跳 5s 应恒有）即轻探
    // /api/status，成功则掐掉当前悬挂流重连（中转线缓冲 SSE 的兜底）。
    _watchdog ??= Timer.periodic(const Duration(seconds: 10), (_) => _probe());
    _connect();
  }

  /// 死链轻探测：流悬挂（缓冲型中转收不到任何块）时 5s 内探 /api/status，
  /// 探测成功说明服务器活着而流死了 → 掐流重连。
  Future<void> _probe() async {
    if (_disposed || !_running || !_foreground) return;
    if (DateTime.now().difference(_lastDataAt) <
        const Duration(seconds: 25)) {
      return; // 流活着
    }
    _log('[sse] 25s 无数据，探测重连');
    _streamSub?.cancel();
    _streamSub = null;
    _attempt = 0;
    await _connect();
  }

  void _log(String text) {
    if (kDebugMode) debugPrint(text);
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
        // 🔴 2.5.10 真机诊断修复：null 是「继承 BaseOptions 6s」不是禁用——
        // 心跳 5s 贴着 6s 上限，中转线一缓冲就断，前台 SSE 频繁断连
        // （机主「角标经常迟到、必须下拉刷新」根因）。显式禁用；死链检测
        // 交给下方 _watchdog 轻探测。
        options: Options(
          responseType: ResponseType.stream,
          receiveTimeout: Duration.zero,
        ),
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
        _touch();
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
              typing: j?['typing'] == true,
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

  void _touch() => _lastDataAt = DateTime.now();

  void _resume() {
    _foreground = true;
    _attempt = 0;
    if (_running) _connect();
  }

  void _teardown() {
    _disposed = true;
    _running = false;
    _backoff?.cancel();
    _watchdog?.cancel();
    _watchdog = null;
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
