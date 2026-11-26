/// 顶栏铃铛「系统未读」角标状态（段 A · 2.2.5 / VC225）。
///
/// 唯一数据源：`GET /api/me` 的 `unread` 字段（`app/main.py:723`，Web 顶栏铃铛
/// `static/app.js:325` 同款）。`auth_state.dart` 的 `_bootstrap` 每次拉到 me
/// 都会播种本 provider；通知中心写成功后 `reload()` 重拉 me → 角标更新，
/// **以服务端为准，不本地推算、不本地造未读**。
///
/// 🔴 与 `chatUnreadProvider`（`chat_unread`，私聊图标角标）严格区分：
/// 私聊用聊天未读、铃铛用未读总数，别把两个字段写反。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
// 3.x：StateProvider 移到 legacy 入口（官方保留兼容，行为不变）
import 'package:flutter_riverpod/legacy.dart';

/// 铃铛角标计数（服务端 `me.unread`）。
final systemUnreadProvider = StateProvider<int>((_) => 0);

/// >99 显示 `99+`（对齐 `app.js:325` 铃铛 / 私聊两个角标同款口径，
/// 以及 App 私聊角标 `shell_page.dart`）。
String unreadBadgeLabel(int count) => count > 99 ? '99+' : '$count';
