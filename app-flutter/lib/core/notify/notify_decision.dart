/// 2.4.5 甲组 · 通知判定核心（纯函数/纯类，无 Flutter/网络依赖，可单测钉死
/// 提示词判定矩阵四条用例）。
///
/// 设计（第 0 步定案）：SSE 载荷 `{refresh, unread, chat, other, rev}` 是纯变更
/// 信号（app/main.py:2056-2090），不含任何内容 → 服务 isolate 收到信号后自己走
/// 现行补拉路径（GET /api/records?kind=chat&limit=200，chat_repository.dart:25-29）
/// 与本地「已决定 id 集合」diff 出增量，本文件负责判定「弹不弹 / 弹什么」。
///
/// 判定矩阵（提示词第 2 项，三个条件全部满足才弹，缺一不弹）：
/// ① 事件由对方产生（本人事件永不弹）；
/// ② App 不在前台（前台时 SSE 已实时呈现）；
/// ③ 未通知过（按记录/通知 id 本地持久化去重）。
///
/// 🔴 seen 语义：`NotifiedStore` 记的是「已决定过（弹或不弹）的 id」——前台不弹的
/// 消息同样记入，否则回后台后这批消息会被当成「新的」再弹一遍。单测钉死此语义。
library;

import '../chat/chat_models.dart' show ChatRecord;
import '../../features/notify/notify_models.dart' show NoticeItem;

/// 合并阈值：重连补拉到的未通知消息超过 3 条合并为一条摘要通知（提示词原文）
const int kNotifyMergeThreshold = 3;

/// 文字摘要截断长度（一行量级，超出省略；提示词「约 30 字」）
const int kNotifyTextSnippetMax = 30;

/// 通知渠道 id（常驻通知渠道由 flutter_foreground_task 的 AndroidNotificationOptions
/// 独立配置为 love_ongoing；这两个是新消息高重要级 / 其他事件渠道）
const String kChannelMessages = 'love_messages';
const String kChannelEvents = 'love_events';

/// 一条待弹通知的完整描述（服务 isolate 判定产出 → 主 isolate 呈现）。
/// [key] 是去重键（`chat:<recordId>` / `notice:<noticeId>`）；[androidId] 是
/// 系统通知 id（同 key 同 id → 重复弹天然覆盖不重复）。
class NotifyItem {
  const NotifyItem({
    required this.key,
    required this.androidId,
    required this.channelId,
    required this.title,
    required this.body,
    required this.route,
    required this.clearChatOnTap,
    this.count = 1,
    this.recordId = '',
    this.event = '',
  });

  final String key;
  final int androidId;
  final String channelId;
  final String title;
  final String body;

  /// 点击落点路由（'' = 仅打开 App）。
  final String route;

  /// 点击时是否清除该会话已弹的聊天通知（进聊天页即清，别让通知栏留已读）。
  final bool clearChatOnTap;

  /// 合并通知的条数（>1 时由呈现层拼「有 N 条新消息」）
  final int count;

  /// 2.8.1：记录级通知的 record_id / event。系统通知点击要按 kind 直达，
  /// 冷启动时只能靠 payload 里这两个字段还原落点（kind 到场再取记录判定）。
  final String recordId;
  final String event;

  Map<String, dynamic> toJson() => {
        'key': key,
        'androidId': androidId,
        'channelId': channelId,
        'title': title,
        'body': body,
        'route': route,
        'clearChatOnTap': clearChatOnTap,
        'count': count,
        'recordId': recordId,
        'event': event,
      };

  static NotifyItem fromJson(Map<String, dynamic> j) => NotifyItem(
        key: (j['key'] ?? '').toString(),
        androidId: (j['androidId'] as num?)?.toInt() ?? 0,
        channelId: (j['channelId'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        body: (j['body'] ?? '').toString(),
        route: (j['route'] ?? '').toString(),
        clearChatOnTap: j['clearChatOnTap'] == true,
        count: (j['count'] as num?)?.toInt() ?? 1,
        recordId: (j['recordId'] ?? '').toString(),
        event: (j['event'] ?? '').toString(),
      );
}

/// 聊天消息摘要映射表（提示词第 2 项「逐类以现行聊天消息类型为准对应」；
/// 字段口径对齐 chat_models.dart ChatBody / ChatMedia.placeholderLabel）：
/// 文字（截 30 字）→ 图片「[图片]」→ 语音「[语音]」→ 位置「[位置]」→
/// 贴纸/表情「[表情]」→ 视频「[视频]」→ 歌曲「[歌曲] …」→ 附件「[附件]」→
/// 引用「[引用]」→ 撤回「[消息已撤回]」。
String chatNotifySnippet(ChatRecord r) {
  final b = r.body;
  if (b.recalled) return '[消息已撤回]';
  final text = b.content.trim();
  if (text.isNotEmpty) {
    if (text.length <= kNotifyTextSnippetMax) return text;
    return '${text.substring(0, kNotifyTextSnippetMax)}…';
  }
  if (b.sticker != null) return '[表情]';
  if (b.location != null) return '[位置]';
  if (b.song != null && b.song!.title.isNotEmpty) return '[歌曲] ${b.song!.title}';
  for (final m in r.media) {
    if (m.id.isEmpty) continue;
    if (m.mime.startsWith('image/')) return '[图片]';
    if (m.mime.startsWith('video/')) return '[视频]';
    if (m.mime.startsWith('audio/')) return '[语音]';
  }
  if (b.mediaIds.isNotEmpty) return '[附件]';
  if (b.replyToId != null) return '[引用]';
  return '[消息]';
}

/// 系统通知 id：同 key 恒同 id（负 hash 修正为正），去重与「点开清除」都靠它
int notifyAndroidId(String key) {
  var h = key.hashCode & 0x7fffffff;
  if (h == 0) h = 1; // id 0 留给常驻通知，永不碰撞
  return h;
}

/// 判定结果：items=待弹通知；seenDelta=本次应记入「已决定」集合的全部 id
/// （含不弹的——前台不弹的消息也必须记 seen，否则回后台会重弹）。
class NotifyDecision {
  const NotifyDecision({required this.items, required this.seenDelta});
  final List<NotifyItem> items;
  final Set<String> seenDelta;
}

/// 聊天消息判定（判定矩阵 + 补拉防轰炸）。
///
/// [fresh] 是补拉窗口（GET 200 条）；与 [isNotified]（已决定谓词）筛出
/// 「本次新出现」的消息，再按矩阵过滤：
/// · 本人消息（author==myId）不弹但记 seen；
/// · 前台不弹但记 seen；
/// · 对方消息后台时 ≤3 条逐条弹（标题=对方名字，正文=摘要映射）；>3 条合并
///   「有 N 条新消息」（计数=对方产生的未通知消息数，不含本人消息）。
NotifyDecision decideChatNotifications({
  required List<ChatRecord> fresh,
  required String myId,
  required String partnerName,
  required bool foreground,
  required bool Function(String key) isNotified,
  int mergeThreshold = kNotifyMergeThreshold,
}) {
  final seen = <String>{};
  final freshUnseen = <ChatRecord>[];
  for (final r in fresh) {
    final key = 'chat:${r.id}';
    // 补拉窗口里可能同时含已决定过的旧记录：谓词命中的直接跳过（③ 已通知过）
    if (isNotified(key)) continue;
    seen.add(key);
    if (r.author == myId) continue; // ① 本人事件不弹
    freshUnseen.add(r);
  }
  // ② 前台不弹（SSE 前台链已实时呈现）
  if (foreground || freshUnseen.isEmpty) {
    return NotifyDecision(items: const [], seenDelta: seen);
  }
  final items = <NotifyItem>[];
  if (freshUnseen.length > mergeThreshold) {
    items.add(NotifyItem(
      key: 'chat:merge:${freshUnseen.last.id}',
      androidId: notifyAndroidId('chat:merge'),
      channelId: kChannelMessages,
      title: partnerName,
      body: '有 ${freshUnseen.length} 条新消息',
      route: '/messages',
      clearChatOnTap: true,
      count: freshUnseen.length,
    ));
  } else {
    for (final r in freshUnseen) {
      items.add(NotifyItem(
        key: 'chat:${r.id}',
        androidId: notifyAndroidId('chat:${r.id}'),
        channelId: kChannelMessages,
        title: partnerName,
        body: chatNotifySnippet(r),
        route: '/messages',
        clearChatOnTap: true,
      ));
    }
  }
  return NotifyDecision(items: items, seenDelta: seen);
}

/// ── 通知类事件（notices）───────────────────────────────────────────────

/// 通知中心事件落点映射（乙组第 4 项共用同一函数，保证「系统通知点击」与
/// 「软件内通知中心点击」落点一致，不会两套口径）：
/// · 有直达路由的功能提醒类：anniversary→纪念日页 / period→生理期页 /
///   wish→共同愿望页 / habit→共同打卡页；
/// · 记录类（activity/comment/note/surprise）：v1 无直达记录路由 → 打开 App
///   （''；乙组第 4 项在通知中心内做记录弹层后，此处可同步升级）；
/// · chat 不在此表（聊天走 SSE chat 信号，且通知中心首行过滤 chat）。
/// 本表同时是「映射表覆盖通知中心现行全部类型」护栏的清单源（乙组测试引用）。
const Map<String, String> kNoticeRoutes = <String, String>{
  'anniversary': '/together/anniversary',
  'period': '/period',
  'wish': '/together/wish',
  'habit': '/together/habit',
};

/// 事件 → 渠道分组（按事件大类分组即可，提示词原文）：新消息高渠道专指聊天
/// （铃声+震动是聊天语义）；其余通知类事件进 love_events（DEFAULT 渠道），
/// 避免点赞也响铃骚扰。
String noticeChannel(String event) => kChannelEvents;

/// v1 弹/不弹事件表（第 0 步建议表，yang 未另行批示按表执行）：
/// 弹：activity/comment/note/surprise/anniversary/period/wish/habit；
/// 不弹：system（首次事件前台可见）/storage（运维）/backup（admin 运维）/
/// chat（通知中心首行过滤 chat，聊天由专用链路处理）。
const Set<String> kNoticeNotifyEvents = <String>{
  'activity',
  'comment',
  'note',
  'surprise',
  'anniversary',
  'period',
  'wish',
  'habit',
};

/// notices 判定（信号=服务 isolate 观察到 SSE unread 计数增加 → GET /api/notices
/// 全量 200 条 → diff）。标题/正文只来自服务端 NoticeItem，
/// 客户端不造文案（对齐 notify_models.dart「内容全部来自服务端」铁律）。
NotifyDecision decideNoticeNotifications({
  required List<NoticeItem> notices,
  required bool foreground,
  required bool Function(String key) isNotified,
}) {
  final seen = <String>{};
  final freshUnseen = <NoticeItem>[];
  for (final n in notices) {
    final key = 'notice:${n.id}';
    if (isNotified(key)) continue;
    seen.add(key);
    if (!kNoticeNotifyEvents.contains(n.event)) continue; // ⑤ 建议表
    freshUnseen.add(n);
  }
  if (foreground || freshUnseen.isEmpty) {
    return NotifyDecision(items: const [], seenDelta: seen);
  }
  final items = <NotifyItem>[];
  for (final n in freshUnseen) {
    items.add(NotifyItem(
      key: 'notice:${n.id}',
      androidId: notifyAndroidId('notice:${n.id}'),
      channelId: noticeChannel(n.event),
      title: eventTitle(n.event),
      body: n.title,
      route: noticeRoute(n.event),
      clearChatOnTap: false,
      // 2.8.1：把 record_id + event 带进系统通知 payload——
      // 冷启动点通知时才可能还原落点（kind 到场再取记录）
      recordId: n.recordId,
      event: n.event,
    ));
  }
  return NotifyDecision(items: items, seenDelta: seen);
}

/// 事件中文名（notify_models.dart eventNames 单一事实源；未知原样回显）
String eventTitle(String event) {
  const names = <String, String>{
    'activity': '新动态',
    'comment': '点赞与评论',
    'note': '留言',
    'surprise': '惊喜公开',
    'anniversary': '纪念日',
    'period': '生理期提醒',
    'wish': '愿望到期',
    'habit': '共同打卡',
  };
  return names[event] ?? event;
}

/// 系统通知点击落点（与软件内通知中心共用 kNoticeRoutes；无直达 = 打开 App）
String noticeRoute(String event) => kNoticeRoutes[event] ?? '';

/// ── 软件内通知中心点击落点（2.4.5 乙组第 4 项）────────────────────────
///
/// 服务端通知生成点盘点（db.notice() 全部调用）：带 record_id 的事件=记录级
/// 可定位（activity/comment/note/surprise/wish 有 rid；anniversary 有两种——
/// 记录型 worker.py:239 带 rid、里程碑 worker.py:262 不带）；不带 rid 的=
/// 功能提醒（period）或运维（system/storage/backup）。
enum NoticeTargetKind {
  /// 打开「历史上的今天」同款纪录底部弹层（showRecordStorySheet，乙组选型：
  /// 现行可复用组件，直显该条内容，无需时光定位复杂联动）
  recordStory,

  /// push 到对应功能页（kNoticeRoutes）
  route,

  /// 兜底弹层（现行 AlertDialog 展示服务端 title + 已读标记——非死条目：
  /// 有内容呈现、有点击反馈、标记已读；无 rid 的记录类通知（如 main.py:2913
  /// 导入聊天记录提醒）也归此类）
  fallback,
}

class NoticeTarget {
  const NoticeTarget({required this.kind, this.route = ''});
  final NoticeTargetKind kind;
  final String route;
}

/// 单条通知的落点判定（逐类映射表，乙组测试逐类钉死；映射规则：
/// ① 有 recordId → 弹层直显该条（跨事件类型统一，弹层即内容本体）；
/// ② 无 recordId 但有直达路由（kNoticeRoutes）→ 功能页；
/// ③ 都没有 → 兜底弹层（title + 事件名 + 时间，标已读））。
/// 单条通知的落点判定（2.8.1 起按 kind 分流，不再是「有 rid 就弹层」）。
///
/// 点击时通知行只有 event + record_id，没有 kind——kind 由调用方先
/// `GET /api/records/{rid}` 取到记录后传入（[kind] 为空表示尚未取到）：
/// · event='chat' → 聊天页；
/// · event='peer'（报备/SOS）→ 报备详情页；
/// · 有 rid 且 kind='anniversary' → 纪念日列表页（记录本体是个日期，弹层没意义）；
/// · 有 rid 且 kind='period' → 生理期页（红线：内容不外显）；
/// · 有 rid 的其它 kind → 记录底部弹层（内容本体）；
/// · 无 rid 但命中 [kNoticeRoutes] → 对应功能页；
/// · 都没有（备份/存储等运维通知）→ 兜底弹层（title + 事件名 + 时间）。
NoticeTarget noticeTargetOf(String event, String recordId, [String kind = '']) {
  if (event == 'chat') {
    return const NoticeTarget(kind: NoticeTargetKind.route, route: '/messages');
  }
  if (event == 'peer') {
    return const NoticeTarget(
        kind: NoticeTargetKind.route, route: '/together/peer-report');
  }
  final rid = recordId.trim();
  if (rid.isNotEmpty) {
    final k = kind.trim();
    if (k == 'anniversary') {
      return const NoticeTarget(
          kind: NoticeTargetKind.route, route: '/together/anniversary');
    }
    if (k == 'period') {
      return const NoticeTarget(kind: NoticeTargetKind.route, route: '/period');
    }
    return const NoticeTarget(kind: NoticeTargetKind.recordStory);
  }
  final route = kNoticeRoutes[event];
  if (route != null && route.isNotEmpty) {
    return NoticeTarget(kind: NoticeTargetKind.route, route: route);
  }
  return const NoticeTarget(kind: NoticeTargetKind.fallback);
}
