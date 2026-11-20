/// 2.5.9 消息通知完善护栏。
/// 锁死：① 铃铛新口径 max(0, unread−chat_unread)（字段防写反）；
/// ② 通知中心 chat 过滤（既有）；③ 三个对账时机接线（回前台/SSE 重连/退聊天页）；
/// ④ 断点#1 Cookie 注入（服务 isolate 补拉带会话）；⑤ 断点#2 重连即对账；
/// ⑥ 裁定⑥诊断行渲染链（status 通道 + provider + 设置页行）；⑦ 全部已读按事件。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/notify/notify_decision.dart';

void main() {
  final root = Directory.current.path;
  String src(String rel) => File('$root/$rel').readAsStringSync();

  group('条目三：铃铛口径 max(0, unread−chat_unread)', () {
    int badge(int unread, int chatUnread) => (unread - chatUnread).clamp(0, 1 << 30);

    test('正常：铃铛=非私聊未读', () {
      expect(badge(5, 2), 3);
      expect(badge(10, 0), 10);
      expect(badge(0, 0), 0);
    });

    test('钳 0：私聊数不可能多于总数，但脏值也不出负', () {
      expect(badge(2, 5), 0);
      expect(badge(0, 3), 0);
    });

    test('字段防写反：unread 走减数、chatUnread 走被减数（源码级）', () {
      final auth = src('lib/features/auth/auth_state.dart');
      // 锚定播种行两字段顺序：unread 在前（被减数）、chatUnread 在后（减数）
      expect(
          auth.contains('(me!.unread - me!.chatUnread)'), isTrue,
          reason: '播种公式必须是 unread − chatUnread（写反=私聊独占铃铛）');
      expect(auth.contains('state = me!.unread;'), isFalse,
          reason: '旧口径（铃铛=全部 unread）必须移除');
    });
  });

  test('条目三：通知中心列表过滤 chat（既有，不许被本段改动破坏）', () {
    final page = src('lib/features/notify/notices_page.dart');
    expect(page.contains("n.event != 'chat'"), isTrue);
  });

  test('条目三：全部已读只清非 chat 事件（按 event 逐个调用既有接口）', () {
    final api = src('lib/features/notify/notify_api.dart');
    expect(api.contains("markNoticesRead({String? recordId, String? event})"),
        isTrue, reason: '后端既有 ?event= 参数（main.py:1961）');
    final page = src('lib/features/notify/notices_page.dart');
    expect(page.contains("n.event != 'chat'"), isTrue,
        reason: '事件集合排除 chat——私聊未读只能进聊天页清');
    expect(page.contains('svc.markNoticesRead(event: e)'), isTrue);
    expect(page.contains('svc.markNoticesRead()'), isFalse,
        reason: '不许再走空参数全清（会把私聊也清了）');
  });

  group('第 0 步断点修复', () {
    test('断点#1：服务 isolate 补拉请求必须带会话 Cookie', () {
      final task = src('lib/core/notify/notify_task.dart');
      expect(task.contains("headers: {'Cookie': '${r'${AppConfig.sessionCookieName}=$_token'}'}"),
          isTrue, reason: '_dioFor BaseOptions 注入 Cookie（401 静默吞根因）');
    });

    test('断点#2：SSE 连接成功即对账（服务端首轮不推 data，断线变化靠主动补拉）', () {
      final task = src('lib/core/notify/notify_task.dart');
      expect(task.contains('_reconcileAfterConnect()'), isTrue,
          reason: '连接成功即补拉（裁定⑤断线补弹）');
      expect(task.contains('Future<void> _reconcileAfterConnect()'), isTrue);
      expect(task.contains('_handleChatSignal(reason:'), isTrue);
      expect(task.contains('_handleUnreadSignal(reason:'), isTrue);
    });

    test('4xx 不再静默：补拉/拉取失败进诊断与日志', () {
      final task = src('lib/core/notify/notify_task.dart');
      expect(task.contains("补拉失败 HTTP"), isTrue);
      expect(task.contains("通知拉取失败 HTTP"), isTrue);
    });
  });

  group('裁定⑥：诊断行渲染链', () {
    test('服务 isolate 推 status 快照（变化时+statusQuery 时）', () {
      final task = src('lib/core/notify/notify_task.dart');
      expect(task.contains("'type': 'status'"), isTrue);
      expect(task.contains("case 'statusQuery'"), isTrue);
      expect(task.contains("'decision': _lastDecision"), isTrue);
    });

    test('主 isolate 消费 status → provider → 设置页行', () {
      final service = src('lib/core/notify/notify_service.dart');
      expect(service.contains("case 'status'"), isTrue);
      expect(service.contains('notifyStatusProvider'), isTrue);
      final main = src('lib/main.dart');
      expect(main.contains('NotifyCoordinator.notifyStatusContainer = container'),
          isTrue, reason: 'static 回调写 provider 需 container 注入');
      final settings = src('lib/features/settings/settings_home_page.dart');
      expect(settings.contains('通知服务状态'), isTrue);
    });
  });

  group('条目二：三个对账时机接线', () {
    test('时机①回前台必刷（NotifyCoordinator onResume 回调）', () {
      final service = src('lib/core/notify/notify_service.dart');
      expect(service.contains('onAppResumedReload?.call()'), isTrue);
      final shell = src('lib/features/shell/shell_page.dart');
      expect(shell.contains('onAppResumedReload ='), isTrue,
          reason: 'shell 注入 reload 实现');
    });

    test('时机②SSE 重连成功对账 + 时机③退聊天页对账', () {
      final shell = src('lib/features/shell/shell_page.dart');
      expect(shell.contains('SsePhase.connected'), isTrue,
          reason: 'SSE 重连成功 → reload');
      expect(shell.contains('prev == true && next == false'), isTrue,
          reason: 'chatPageActive true→false（退出聊天页）→ reload');
    });
  });

  test('判定矩阵回归：2.4.5 语义不被本段破坏（纯函数直测）', () {
    // seen 语义：前台不弹也记 seen（防回后台重弹）
    final r1 = const NotifyDecision(items: [], seenDelta: {'chat:a'});
    expect(r1.seenDelta, contains('chat:a'));
    // 阈值常量与渠道 id 不变
    expect(kNotifyMergeThreshold, 3);
    expect(kChannelMessages, 'love_messages');
    // chat 不在事件弹表（通知中心/事件通知两链路都排除 chat）
    expect(kNoticeNotifyEvents.contains('chat'), isFalse);
  });
}
