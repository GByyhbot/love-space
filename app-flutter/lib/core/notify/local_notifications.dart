/// 2.4.5 甲组 · 本地通知呈现层（主 isolate）。
///
/// 职责单一：初始化插件 / 申请 Android 13+ 通知权限 / 按 NotifyItem 弹通知 /
/// 点击路由回调。判定与去重全在 notify_decision.dart + notify_task.dart（服务
/// isolate），这里只负责「怎么弹」与「点了去哪」。
///
/// 渠道（提示词：新消息用独立高重要级渠道，按事件大类分组，不做复杂聚合）：
/// · love_messages：HIGH，默认铃声+震动（用户可在系统设置里改）；
/// · love_events：DEFAULT，其余通知类事件（点赞响铃是骚扰，降一级）；
/// · love_ongoing：常驻通知渠道，由 flutter_foreground_task 的
///   AndroidNotificationOptions 独立配置（LOW/无声），与本文件严格分开。
///
/// id 策略：notifyAndroidId(key) —— 同 key 恒同 id：同一记录重复判定只会
/// 覆盖不叠加；「点开清除」按记录 id 精确 cancel（见 notify_service.dart）。
library;

import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notify_decision.dart';

/// 全局插件实例（通知响应监听在主 isolate 注册一次）
final FlutterLocalNotificationsPlugin plugin = FlutterLocalNotificationsPlugin();

/// 点击回调（由 notify_service.dart 注册；payload 是 NotifyItem.toJson 的 JSON）
void Function(NotifyItem item)? onNotifyItemTap;

/// 冷启动（通知点击拉起 App）时待处理的 payload（由 notify_service 消费）
NotifyItem? pendingLaunchItem;

/// 当前已弹的聊天通知 id 集合（进聊天页即清——提示词「点开聊天页后该会话
/// 已弹出的系统通知应被清除」）
final Set<int> activeChatNotificationIds = <int>{};

/// 清除全部聊天通知（进聊天页 / 点击聊天通知时调用）
Future<void> clearChatNotifications() async {
  for (final id in List<int>.from(activeChatNotificationIds)) {
    await cancelById(id);
  }
  activeChatNotificationIds.clear();
}

bool _initialized = false;

Future<void> ensureInitialized() async {
  if (_initialized) return;
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await plugin.initialize(
    settings: const InitializationSettings(android: androidInit),
    onDidReceiveNotificationResponse: (resp) {
      final raw = resp.payload;
      if (raw == null || raw.isEmpty) return;
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        onNotifyItemTap?.call(NotifyItem.fromJson(j));
      } catch (_) {}
    },
  );
  _initialized = true;
}

/// Android 13+ 通知权限申请（返回是否已授权）。
/// 23.x API：requestNotificationsPermission 返回 bool。
Future<bool> requestNotificationPermission() async {
  await ensureInitialized();
  final android =
      plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  if (android == null) return false; // 非 Android 平台（iOS 本段不碰）
  return await android.requestNotificationsPermission() ?? false;
}

/// 查询当前通知权限状态（设置页「权限状态」行用；Android 13+）
Future<bool> areNotificationsEnabled() async {
  await ensureInitialized();
  final android =
      plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  if (android == null) return false;
  return await android.areNotificationsEnabled() ?? false;
}

/// 弹一条通知（渠道按 item.channelId 自动创建；失败静默——通知层绝不崩主链）
Future<void> showNotifyItem(NotifyItem item) async {
  try {
    await ensureInitialized();
    final high = item.channelId == kChannelMessages;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        item.channelId,
        high ? '新消息' : '空间提醒',
        channelDescription: high
            ? '对方发来的聊天消息通知（默认铃声+震动，可在系统设置里修改）'
            : '留言、动态、纪念日等空间提醒通知',
        importance: high ? Importance.high : Importance.defaultImportance,
        priority: high ? Priority.high : Priority.defaultPriority,
        playSound: high,
        enableVibration: high,
        onlyAlertOnce: false,
      ),
    );
    await plugin.show(
      id: item.androidId,
      title: item.title,
      body: item.body,
      notificationDetails: details,
      payload: jsonEncode(item.toJson()),
    );
    if (item.channelId == kChannelMessages) {
      activeChatNotificationIds.add(item.androidId);
    }
  } catch (_) {
    // 通知失败不崩（无权限/渠道异常等），下次事件自然重试
  }
}

/// 按 id 清除（进聊天页清该会话已弹通知：notify_service 维护当前已弹集合）
Future<void> cancelById(int androidId) async {
  try {
    await plugin.cancel(id: androidId);
  } catch (_) {}
}

/// 清除全部聊天通知（id 与 key 对齐：重新按 key 集算 id 再 cancel）
Future<void> cancelByKeys(Iterable<String> keys) async {
  for (final k in keys) {
    await cancelById(notifyAndroidId(k));
  }
}
