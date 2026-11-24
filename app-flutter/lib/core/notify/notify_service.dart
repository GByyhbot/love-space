/// 2.4.5 甲组 · 通知装配层（主 isolate）。
///
/// 职责：把前台服务、本地通知、判定结果三者接起来——
/// · 服务配置注入（线路/会话正本/我与对方，经插件数据通道 saveData，服务
///   isolate onStart 读同一份——用户无需在服务里再登录）；
/// · 登录成功后拉起服务、退出登录停止（shell_page enter/leave 钩子；未登录
///   不空跑）；
/// · 消费服务 isolate 的判定结果（{type:'notify'}）弹系统通知；
/// · 主 isolate 生命周期上报服务（前后台判定；未知/过期按后台——宁可弹）；
/// · 线路变化跟随（baseProvider → {type:'route'} → 服务重连新线路）；
/// · 通知点击路由（运行期点击 + 冷启动 launch 详情）。
///
/// 常驻通知（提示词第 1 项 4）：独立低重要级渠道 love_ongoing（LOW/无声/
/// 无角标），文案「恋爱空间 · 消息接收中」，点击打开 App；不放任何动态内容。
/// 与新消息渠道 love_messages（HIGH，铃声+震动）严格分开。
library;

import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart' as api;
import '../../features/auth/auth_state.dart' show MeData, authProvider;
import '../chat/chat_state.dart' show chatPageActiveProvider;
import 'local_notifications.dart';
import 'notify_decision.dart' show NotifyItem;
import 'notify_status.dart' show NotifyDiag, notifyStatusProvider;
import 'notify_task.dart';

/// 常驻通知渠道（flutter_foreground_task 专用，与消息渠道严格分开）
const String kOngoingChannelId = 'love_ongoing';

/// 通知点击路由回调（LoveApp build 注入：router.push）
void Function(String route)? notifyRouteHandler;

/// 2.8.1：记录级通知点击回调（LoveApp build 注入）。
///
/// 系统通知/冷启动的 payload 里只有 record_id + event，**没有 kind**；
/// 落点要靠 `GET /api/records/{rid}` 取到记录后按 kind 判定（anniversary
/// 进纪念日页、period 进生理期页、其余开记录弹层）。所以这条链路必须异步、
/// 而且不能依赖页面 context。
Future<void> Function(String recordId, String event)? notifyNoticeTapHandler;

/// 2.5.9 条目二：回前台必刷回调（shell_page 注入 authProvider.reload）——
/// 主 isolate onResume 时重拉 /api/me 对账两角标（服务端为准，不本地推算）。
void Function()? onAppResumedReload;

/// 通知装配器（shell_page enter/leave 钩子调用）
class NotifyCoordinator {
  NotifyCoordinator._();

  static final NotifyCoordinator instance = NotifyCoordinator._();

  AppLifecycleListener? _lifecycle;

  /// 全局初始化（LoveApp 首帧前调用一次；仅 Android——iOS 不在本段）。
  static Future<void> platformInit() async {
    if (!Platform.isAndroid) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: kOngoingChannelId,
        channelName: '消息接收服务',
        channelDescription: '保持与恋爱空间服务器的连接以接收对方的消息提醒',
        // LOW + 无声 + 无角标：常驻通知不打扰（默认值即如此，显式写明）
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        playSound: false,
        enableVibration: false,
        showBadge: false,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        // 开机自启 + 覆盖安装后自启（插件自带 BOOT receiver；服务 onStart
        // 无会话配置时自停，未登录不空跑）
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
      ),
    );
    FlutterForegroundTask.initCommunicationPort();
    await ensureInitialized();
    onNotifyItemTap = (item) => instance.handleTap(item);
  }

  /// 进入主框架（shell_page initState；此时必为已登录态）。
  Future<void> enterShell(WidgetRef ref) async {
    // ① 服务配置注入（me 数据源：authProvider.notifier.me）
    final me = ref.read(authProvider.notifier).me;
    if (me != null) {
      await syncConfig(me);
    }
    // ② 权限（已授权则静默；未授权申请一次；拒绝也继续跑——FGS 通知不显示
    // 但连接保活，用户可在设置页再开）
    await requestNotificationPermission();
    // ③ 拉起服务（幂等：running 则 restart 刷新配置）
    if (Platform.isAndroid) {
      try {
        if (await FlutterForegroundTask.isRunningService) {
          await FlutterForegroundTask.restartService();
        } else {
          await FlutterForegroundTask.startService(
            serviceId: 256,
            notificationTitle: '恋爱空间',
            notificationText: '消息接收中',
            callback: startNotifyTask,
          );
        }
      } catch (e) {
        debugPrint('[notify] 服务拉起失败: $e');
      }
    }
    // ④ 生命周期上报（前后台判定；未收到上报时服务按后台——宁可弹）
    _lifecycle ??= AppLifecycleListener(
      onResume: () {
        sendToTask({'type': 'foreground', 'value': true});
        // 2.5.9 条目二时机①：回前台必刷——重拉 /api/me 两角标对账
        onAppResumedReload?.call();
      },
      onPause: () => sendToTask({'type': 'foreground', 'value': false}),
    );
    // ⑤ 线路跟随：baseProvider 变化 → 服务重连新线路
    ref.listen<AsyncValue<String>>(api.baseProvider, (prev, next) {
      final base = next.value;
      if (base != null && base != prev?.value) {
        sendToTask({'type': 'route', 'base': base});
      }
    });
    // ⑥ 进聊天页即清聊天通知（提示词：进页面即清，别让通知栏留一堆已读）
    ref.listen<bool>(chatPageActiveProvider, (prev, next) {
      if (next && prev != true) clearChatNotifications();
    });
    // ⑦ 冷启动通知点击（launch 详情只在 App 冷启动由通知拉起时有值）
    handleColdLaunch();
    // ⑧ 消费服务判定结果
    FlutterForegroundTask.addTaskDataCallback(onTaskData);
    // ⑨ 2.5.9 裁定⑥：查询一次服务状态快照（设置页「通知服务状态」行首帧
    //    即有值）；container 由 main 在创建时注入 notifyStatusContainer
  }

  /// 离开主框架（shell_page dispose：登出/会话失效）。停服务 + 停上报。
  Future<void> leaveShell() async {
    FlutterForegroundTask.removeTaskDataCallback(onTaskData);
    _lifecycle?.dispose();
    _lifecycle = null;
    if (Platform.isAndroid) {
      try {
        await FlutterForegroundTask.stopService();
      } catch (_) {}
    }
  }

  /// me 数据（myId/partnerName/会话正本/当前线路）写入服务数据通道。
  /// 线路与令牌分别取自 baseProvider 当前值与 secure_storage 正本——
  /// 与主 isolate 同源（提示词第 0 步 3：同一份线路配置、同一份凭据）。
  static Future<void> syncConfig(MeData me) async {
    if (!Platform.isAndroid) return;
    final partner = me.users.where((u) => u.id != me.user.id).toList();
    final partnerName = partner.isNotEmpty ? partner.first.name : '对方';
    String base = '';
    try {
      base = await api.readLastRoute() ?? '';
    } catch (_) {}
    String token = '';
    try {
      token = await api.readSessionToken() ?? '';
    } catch (_) {}
    await FlutterForegroundTask.saveData(key: kTaskKeyBase, value: base);
    await FlutterForegroundTask.saveData(key: kTaskKeyToken, value: token);
    await FlutterForegroundTask.saveData(key: kTaskKeyMyId, value: me.user.id);
    await FlutterForegroundTask.saveData(key: kTaskKeyPartner, value: partnerName);
  }

  static void sendToTask(Map<String, dynamic> msg) {
    if (!Platform.isAndroid) return;
    try {
      FlutterForegroundTask.sendDataToTask(msg);
    } catch (_) {}
  }

  /// 服务 isolate → 主 isolate 数据消费（static：插件回调要求）
  static void onTaskData(Object data) {
    if (data is! Map) return;
    final msg = Map<String, dynamic>.from(data);
    switch (msg['type']) {
      case 'notify':
        final items = ((msg['items'] ?? const []) as List)
            .whereType<Map>()
            .map((e) => NotifyItem.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        for (final item in items) {
          showNotifyItem(item);
        }
      case 'status':
        // 2.5.9 裁定⑥：服务诊断快照 → 设置页「通知服务状态」行
        notifyStatusContainer?.read(notifyStatusProvider.notifier).state =
            NotifyDiag.fromJson(msg);
      case 'log':
        if (kDebugMode) {
          debugPrint('[notify-task] ${msg['text']}');
        }
    }
  }

  /// 2.5.9：ProviderContainer 引用（onTaskData 是 static 回调，经此写 provider）
  static ProviderContainer? notifyStatusContainer;

  /// 通知点击（运行期 onDidReceiveNotificationResponse / 冷启动 launch）
  void handleTap(NotifyItem item) {
    if (item.clearChatOnTap) clearChatNotifications();
    // 2.8.1：记录级通知 / 报备类通知走 kind 感知路由——
    // 需要先取记录判 kind，交给注入的异步处理器（与通知中心同一套落点判定）。
    final rich = notifyNoticeTapHandler;
    if (rich != null && (item.recordId.isNotEmpty || item.event == 'peer')) {
      // 冷启动时 router 可能还没挂载：处理器内部自带一帧退避与降级
      unawaited(rich(item.recordId, item.event));
      return;
    }
    final handler = notifyRouteHandler;
    if (handler != null && item.route.isNotEmpty) {
      handler(item.route);
    }
    // route 为空 = 仅打开 App（App 已在运行则已在前台，无需动作）
  }

  /// 冷启动点击（App 由消息通知拉起时恢复 payload 并路由）
  Future<void> handleColdLaunch() async {
    try {
      final details = await plugin.getNotificationAppLaunchDetails();
      final resp = details?.notificationResponse;
      if (details?.didNotificationLaunchApp == true && resp?.payload != null) {
        final raw = resp!.payload!;
        try {
          final j = jsonDecode(raw) as Map<String, dynamic>;
          if (j.isNotEmpty) {
            handleTap(NotifyItem.fromJson(j));
          }
        } catch (_) {}
      }
    } catch (_) {}
  }
}
