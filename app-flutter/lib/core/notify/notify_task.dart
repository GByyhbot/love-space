/// 2.4.5 甲组 · 前台服务 TaskHandler（服务 isolate）。
///
/// 选型 flutter_foreground_task 11.0.3（提示词第 1 项）：
/// · 维护活跃（2026 年持续发版）、TaskHandler isolate 模型与既有 Riverpod
///   架构零耦合、autoRunOnBoot 自带 BOOT_COMPLETED receiver（无需自写
///   Android receiver）、常驻通知通道自带（LOW/无声/ongoing，与消息渠道分离）。
/// · type=specialUse（manifest 声明，取舍依据见 AndroidManifest.xml 注释）。
///
/// 服务生命周期：登录成功后由 notify_service.dart 拉起、退出登录停止；BOOT/
/// MY_PACKAGE_REPLACED 由系统拉起时 onStart 读不到会话正本 → stopService
/// （未登录不空跑，提示词第 1 项 1）。
///
/// 🔴 双信号机制（第 0 步定案，后端零改动）：SSE 载荷是纯变更信号——
/// · chat=true → 拉现行补拉路径 GET /api/records?kind=chat&limit=200（与前台
///   reconcile 同一路径）→ 与 NotifiedStore diff → 判定矩阵弹；
/// · unread 计数增加 → GET /api/notices → diff → 按第 0 步建议表弹。
/// 🔴 不动 SSE 既有前台消费逻辑：本文件的 SSE 行解析是独立轻实现（契约对齐
/// sse_client.dart 头注：retry 行/`: ` 注释帧/data: 行），不改 sse_client.dart。
///
/// 线路：走主 isolate 通过插件数据通道写入的当前生效线路（baseProvider 同源）；
/// 主 isolate 线路变化时发 {type:'route'} 让服务重连到新线路（跟随重连，提示词
/// 第 1 项 2）。凭据：会话令牌正本经同一通道注入（secure_storage 主本，提示词
/// 第 0 步 3——用户无需在服务里再登录）。
///
/// 退避（提示词第 1 项 2）：首次 3s、逐次 ×2、封顶 30s；另有 10s 周期轻探测
/// /api/status，探测成功即取消退避立即重连（网络恢复不等退避计时）。
///
/// 前后台判定（提示词第 1 项 3）：主 isolate 经插件数据通道上报生命周期；
/// 状态未知（启动后未收到上报）或上报过期（>90s）时按后台处理——宁可弹、
/// 靠去重防重复，不许漏弹。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../chat/chat_models.dart';
import '../config.dart';
import '../../features/notify/notify_models.dart' show NoticeItem;
import 'notified_store.dart';
import 'notify_decision.dart';

/// 服务 isolate 配置键（notify_service.dart 侧 FlutterForegroundTask.saveData
/// 写入，TaskHandler 内 getData 读出）
const kTaskKeyBase = 'notify_base';
const kTaskKeyToken = 'notify_token';
const kTaskKeyMyId = 'notify_myid';
const kTaskKeyPartner = 'notify_partner';

/// 退避参数（写进摘要：首次 3s、逐次翻倍、上限封顶 30s；探测周期 10s）
const Duration kReconnectBase = Duration(seconds: 3);
const Duration kReconnectCap = Duration(seconds: 30);
const Duration kProbeInterval = Duration(seconds: 10);
const Duration kForegroundStale = Duration(seconds: 90);

/// 数据通道协议（主 isolate ↔ 服务 isolate；只能发原始类型/Map/List）
/// 主 → 服务：{type:'foreground', value:bool} / {type:'route', base:String}
///           / {type:'session', token:String}（relogin 播种后刷新）
/// 服务 → 主：{type:'notify', items:[NotifyItem.toJson()]}（主 isolate 呈现）
///           / {type:'log', text:String}（诊断日志，主 isolate debugPrint）

@pragma('vm:entry-point')
void startNotifyTask() {
  FlutterForegroundTask.setTaskHandler(NotifyTaskHandler());
}

class NotifyTaskHandler extends TaskHandler {
  NotifyTaskHandler();

  // ── 会话配置（onStart/onReceiveData 刷新）─────────────────────────────
  String _base = '';
  String _token = '';
  String _myId = '';
  String _partnerName = '对方';

  // ── 运行态 ──────────────────────────────────────────────────────────
  NotifiedStore? _store;
  Dio? _dio;
  StreamSubscription<List<int>>? _sseSub;
  Timer? _backoffTimer;
  Timer? _probeTimer;
  int _attempt = 0;
  bool _running = false;
  bool _destroyed = false;
  bool _foreground = false; // 未知/过期按后台（宁可弹）
  DateTime _foregroundAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastUnread = -1; // 首轮只建基线（对齐服务端 ready 语义）
  DateTime _lastEventAt = DateTime.now();

  /// 插件要求实现：eventAction=nothing() 时不会被调度（每事件都由信号驱动）
  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _running = true;
    _destroyed = false;
    _store = await NotifiedStore.loadDefault();
    // 配置注入（主 isolate startService 前 saveData；BOOT 拉起时读不到）
    _base = (await FlutterForegroundTask.getData(key: kTaskKeyBase) ?? '') as String;
    _token = (await FlutterForegroundTask.getData(key: kTaskKeyToken) ?? '') as String;
    _myId = (await FlutterForegroundTask.getData(key: kTaskKeyMyId) ?? '') as String;
    _partnerName = (await FlutterForegroundTask.getData(key: kTaskKeyPartner) ?? '对方') as String;
    if (_base.isEmpty || _token.isEmpty || _myId.isEmpty) {
      // 未登录不空跑（提示词第 1 项 1）：BOOT/更新重启且无会话 → 自停
      _log('无会话配置，服务自停');
      try {
        await FlutterForegroundTask.stopService();
      } catch (_) {}
      return;
    }
    _probeTimer = Timer.periodic(kProbeInterval, (_) => _probe());
    _connect();
  }

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    final msg = Map<String, dynamic>.from(data);
    switch (msg['type']) {
      case 'foreground':
        _foreground = msg['value'] == true;
        _foregroundAt = DateTime.now();
      case 'route':
        final newBase = (msg['base'] ?? '').toString();
        if (newBase.isNotEmpty && newBase != _base) {
          _log('线路切换 → $newBase');
          _base = newBase;
          _dio = null; // 重建 dio（baseUrl 变了）
          _reconnectNow();
        }
      case 'session':
        final newToken = (msg['token'] ?? '').toString();
        if (newToken.isNotEmpty && newToken != _token) {
          _token = newToken;
          _reconnectNow();
        }
      case 'partner':
        final name = (msg['name'] ?? '').toString();
        if (name.isNotEmpty) _partnerName = name;
      case 'statusQuery':
        // 裁定⑥：主 isolate 查询时回推一次快照（设置页「通知服务状态」行）
        _setStatus(_lastDecision);
    }
  }

  // ── 诊断状态（裁定⑥）：紧凑快照，变化时 + statusQuery 时推主 isolate ──
  String _lastDecision = '尚无判定';
  String _lastError = '';

  void _setStatus(String decision, {String? error}) {
    _lastDecision = decision;
    if (error != null) _lastError = error;
    try {
      FlutterForegroundTask.sendDataToMain({
        'type': 'status',
        'running': _running,
        'connected': _sseSub != null,
        'lastEventAt': _lastEventAt.millisecondsSinceEpoch,
        'decision': _lastDecision,
        'error': _lastError,
      });
    } catch (_) {}
  }

  // ── SSE 连接 ─────────────────────────────────────────────────────────
  Dio _dioFor() {
    if (_dio != null) return _dio!;
    final d = Dio(BaseOptions(
      baseUrl: _base,
      connectTimeout: const Duration(seconds: 10),
      // 流式响应的 chunk 间隔超时＝死链检测：心跳 5s 一次，30s 没数据即断
      receiveTimeout: const Duration(seconds: 30),
      validateStatus: (s) => s != null && s < 500,
      // 🔴 2.5.9 断点#1 修复：会话 Cookie 注入 BaseOptions——此前只有 SSE
      // 请求手动带 Cookie，补拉 GET /api/records、GET /api/notices 全部 401
      // 且被 `statusCode>=400 return` 静默吞掉 → 后台通知永不弹、零报错
      // （真机「常驻通知在、服务活着、完全不弹」的根因）。
      headers: {'Cookie': '${AppConfig.sessionCookieName}=$_token'},
    ));
    final adapter = IOHttpClientAdapter();
    adapter.createHttpClient = () {
      final h = HttpClient();
      h.findProxy = (uri) => 'DIRECT'; // 开发机 HTTP_PROXY 坑，同 api_client.dart
      return h;
    };
    d.httpClientAdapter = adapter;
    _dio = d;
    return d;
  }

  Future<void> _connect() async {
    if (_destroyed || !_running) return;
    if (_backoffTimer != null) return; // 退避已排程，别双连
    try {
      final rsp = await _dioFor().get<ResponseBody>(
        '/api/events',
        options: Options(
          responseType: ResponseType.stream,
          // 🔴 2.5.10 真机诊断修复：Options.receiveTimeout=null 在 dio 里是
          // 「继承 BaseOptions」不是禁用——服务 isolate 继承 30s，当前线路对
          // SSE 流有缓冲时 30s 无 chunk 即被杀，死循环重连（机主 2.5.9 诊断行
          // 截图实锤）。显式 Duration.zero 禁用；死链检测交给 10s 周期
          // _probe（25s 无事件即探 /api/status，成功即重连）。
          receiveTimeout: Duration.zero,
          headers: {'Cookie': '${AppConfig.sessionCookieName}=$_token'},
        ),
      );
      if ((rsp.statusCode ?? 0) >= 300) {
        _setStatus('SSE HTTP ${rsp.statusCode}', error: 'SSE HTTP ${rsp.statusCode}');
        _log('SSE HTTP ${rsp.statusCode}');
        _scheduleRetry();
        return;
      }
      _attempt = 0;
      _lastEventAt = DateTime.now();
      _log('SSE 已连接');
      _setStatus('SSE 已连接');
      _sseSub = rsp.data!.stream.listen(_onChunk, onDone: () {
        _log('SSE 流结束');
        _scheduleRetry();
      }, onError: (Object e) {
        _log('SSE 错误 $e');
        _scheduleRetry();
      });
      // 🔴 2.5.9 断点#2 修复：服务端 SSE 首轮连接只建基线不发 data 帧
      // （main.py:2266-2272）——断线期间的 chat/notices 变化在重连后永不推送。
      // 连接成功即主动对账一次（seen 集合持久化防重弹），补上裁定⑤缺口。
      unawaited(_reconcileAfterConnect());
    } on DioException catch (e) {
      // 401 = 会话失效：不退避重连（等主 isolate 下发新会话）
      if (e.response?.statusCode == 401) {
        _setStatus('SSE 401，等待会话刷新', error: 'SSE 401（会话失效，等主 isolate 下发新会话）');
        _log('SSE 401，等待会话刷新');
        return;
      }
      _setStatus('SSE 连接失败', error: e.toString());
      _scheduleRetry();
    } catch (e) {
      _log('SSE 连接异常 $e');
      _scheduleRetry();
    }
  }

  String _carry = '';

  void _onChunk(List<int> chunk) {
    if (_destroyed || !_running) {
      _sseSub?.cancel();
      return;
    }
    _lastEventAt = DateTime.now();
    _carry += utf8.decode(chunk, allowMalformed: true);
    final parts = _carry.split('\n');
    _carry = parts.removeLast();
    for (final raw in parts) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith(':') || line.startsWith('retry:')) {
        continue; // ready/heartbeat 注释帧 + retry 行
      }
      if (line.startsWith('data:')) {
        _handleData(line.substring(5).trim());
      }
    }
  }

  /// 收到 data 帧：解析 {refresh, unread, chat, other, rev}
  Future<void> _handleData(String body) async {
    Map<String, dynamic> j;
    try {
      j = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    // 信号①：chat 变化 → 补拉增量 → 判定
    if (j['chat'] == true) {
      await _handleChatSignal();
    }
    // 信号②：unread 增加（新 notices）→ 拉通知增量 → 判定
    final unread = (j['unread'] as num?)?.toInt();
    if (unread != null && _lastUnread >= 0 && unread > _lastUnread) {
      await _handleUnreadSignal();
    }
    if (unread != null) _lastUnread = unread;
  }

  /// 重连/启动后主动对账（断点#2）：走与信号相同补拉路径，seen 集合防重。
  Future<void> _reconcileAfterConnect() async {
    await _handleChatSignal(reason: '重连对账');
    await _handleUnreadSignal(reason: '重连对账');
  }

  Future<void> _handleChatSignal({String reason = 'chat 信号'}) async {
    try {
      final r = await _dioFor().get('/api/records', queryParameters: {
        'kind': 'chat',
        'limit': 200,
      });
      if (_destroyed) return;
      if (r.statusCode != null && r.statusCode! >= 400) {
        // 🔴 2.5.9：不再静默吞 4xx（断点#1 的 401 曾在这里无痕消失）
        _setStatus('补拉失败 HTTP ${r.statusCode}', error: '补拉 /api/records HTTP ${r.statusCode}');
        _log('补拉失败 HTTP ${r.statusCode}');
        return;
      }
      _setStatus('$reason：拉到 ${((r.data ?? const []) as List).length} 条');
      final records = <ChatRecord>[];
      for (final e in ((r.data ?? const []) as List)) {
        if (e is Map) {
          records.add(ChatRecord.fromJson(e.cast<String, dynamic>()));
        }
      }
      final decision = decideChatNotifications(
        fresh: records,
        myId: _myId,
        partnerName: _partnerName,
        foreground: _isForeground(),
        isNotified: _store!.contains,
      );
      _store!.addAll(decision.seenDelta);
      if (decision.items.isNotEmpty || _store!.dirty) {
        await _store!.save();
      }
      if (decision.items.isNotEmpty) {
        _setStatus('已弹 ${decision.items.length} 条聊天通知');
        _sendItems(decision.items);
      } else {
        _setStatus('$reason：无待弹（${records.length} 条已决定/前台压下）');
      }
    } catch (e) {
      _setStatus('补拉异常', error: e.toString());
      _log('聊天补拉失败 $e');
    }
  }

  Future<void> _handleUnreadSignal({String reason = 'unread 信号'}) async {
    try {
      final r = await _dioFor().get('/api/notices');
      if (_destroyed) return;
      if (r.statusCode != null && r.statusCode! >= 400) {
        _setStatus('通知拉取失败 HTTP ${r.statusCode}', error: '拉取 /api/notices HTTP ${r.statusCode}');
        _log('通知拉取失败 HTTP ${r.statusCode}');
        return;
      }
      final notices = <NoticeItem>[];
      for (final e in ((r.data ?? const []) as List)) {
        if (e is Map) {
          notices.add(NoticeItem.fromJson(e.cast<String, dynamic>()));
        }
      }
      final decision = decideNoticeNotifications(
        notices: notices,
        foreground: _isForeground(),
        isNotified: _store!.contains,
      );
      _store!.addAll(decision.seenDelta);
      if (decision.items.isNotEmpty || _store!.dirty) {
        await _store!.save();
      }
      if (decision.items.isNotEmpty) {
        _setStatus('已弹 ${decision.items.length} 条事件通知');
        _sendItems(decision.items);
      } else {
        _setStatus('$reason：无待弹（notices 已决定/前台压下）');
      }
    } catch (e) {
      _setStatus('通知拉取异常', error: e.toString());
      _log('通知拉取失败 $e');
    }
  }

  /// 前后台判定：上报过期（>kForegroundStale 未刷新）按后台——宁可弹
  bool _isForeground() {
    if (!_foreground) return false;
    return DateTime.now().difference(_foregroundAt) <= kForegroundStale;
  }

  void _sendItems(List<NotifyItem> items) {
    try {
      FlutterForegroundTask.sendDataToMain({
        'type': 'notify',
        'items': items.map((e) => e.toJson()).toList(),
      });
    } catch (_) {
      // 主 isolate 不在（进程刚被杀 BOOT 拉起的窗口）：通知丢失。
      // 诚实边界：该窗口内错过通知，用户开 App 后由前台补拉呈现（摘要已注明）。
    }
  }

  void _log(String text) {
    try {
      FlutterForegroundTask.sendDataToMain({'type': 'log', 'text': text});
    } catch (_) {}
  }

  // ── 退避 + 探测 ──────────────────────────────────────────────────────
  void _scheduleRetry() {
    if (_destroyed || !_running || _backoffTimer != null) return;
    _sseSub = null;
    _attempt += 1;
    final waitMs = (kReconnectBase.inMilliseconds * (1 << (_attempt - 1).clamp(0, 4)))
        .clamp(kReconnectBase.inMilliseconds, kReconnectCap.inMilliseconds);
    _log('重连 #$_attempt in ${waitMs}ms');
    _backoffTimer = Timer(Duration(milliseconds: waitMs), () {
      _backoffTimer = null;
      _connect();
    });
  }

  /// 网络恢复立即重连：10s 周期探测 /api/status，成功且未连接 → 取消退避直连
  Future<void> _probe() async {
    if (_destroyed || !_running) return;
    // 流还活着（30s 内有数据）就不用探
    if (_sseSub != null &&
        DateTime.now().difference(_lastEventAt) < const Duration(seconds: 25)) {
      return;
    }
    try {
      final r = await _dioFor()
          .get('/api/status')
          .timeout(const Duration(seconds: 5));
      if (_destroyed) return;
      if ((r.statusCode ?? 0) == 200) {
        if (_backoffTimer != null || _sseSub == null) {
          _backoffTimer?.cancel();
          _backoffTimer = null;
          _attempt = 0;
          _log('探测成功，立即重连');
          _connect();
        }
      }
    } catch (_) {
      // 探测失败：等下一轮
    }
  }

  void _reconnectNow() {
    _sseSub?.cancel();
    _sseSub = null;
    _backoffTimer?.cancel();
    _backoffTimer = null;
    _attempt = 0;
    if (_running && !_destroyed) _connect();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _destroyed = true;
    _running = false;
    _sseSub?.cancel();
    _backoffTimer?.cancel();
    _probeTimer?.cancel();
    _dio?.close(force: true);
    _dio = null;
  }

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {
    // 常驻通知点击 → 打开 App（插件已配 launch intent），无附加动作
  }

  @override
  void onNotificationDismissed() {}
}
