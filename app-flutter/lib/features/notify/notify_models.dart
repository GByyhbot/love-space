/// 「数据管理与通知渠道」章 · 段 A（2.2.5 / VC225）：
/// `/channels`（通知渠道）与 `/notices`（通知中心）共享的只读模型、中文映射表
/// 与纯函数。
///
/// 契约锚点（全部为服务端 / Web 原文，客户端不造数据）：
/// · CHANNEL_KINDS 10 种 `app/main.py:2502`，中文名 `static/app.js:1493`；
/// · EVENTS 12 事件 `main.py:2503-2504`，中文名 `app.js:1494`（含 `period`）；
/// · config 字段表逐字对齐 `app.js:2436` configs，required 口径对齐
///   `app.js:2438` update()（`bark.url`、`webhook.token` 非必填；`port` 默认 465）；
/// · `GET /api/channels` 逐行 `pop('config')`（`main.py:2524`）→ [ChannelItem]
///   **不含任何 config / 凭据字段**，列表页绝不回填明文；
/// · 发送记录状态文案对齐 `app.js:1498`。
library;

import 'dart:convert';

/// 渠道类型中文名（`app.js:1493` channelNames；键顺序即表单下拉顺序）。
const Map<String, String> channelNames = <String, String>{
  'smtp': '邮件',
  'bark': 'Bark',
  'serverchan': 'Server酱',
  'pushplus': 'PushPlus',
  'wecom': '企业微信机器人',
  'webhook': '自定义 Webhook',
  'telegram': 'Telegram',
  'dingtalk': '钉钉机器人',
  'feishu': '飞书机器人',
  'ntfy': 'ntfy',
};

/// 订阅事件中文名（`app.js:1494` eventNames 的对象键顺序，也就是
/// `app.js:2437` `Object.keys(eventNames)` 的提交顺序；`period` 在
/// anniversary 之后，本表按原文顺序照录，共 12 项）。
const Map<String, String> eventNames = <String, String>{
  'chat': '聊天消息',
  'comment': '点赞与评论',
  'note': '留言',
  'activity': '新动态与互动',
  'anniversary': '纪念日',
  'period': '生理期提醒',
  'wish': '愿望到期',
  'surprise': '惊喜公开',
  'habit': '共同打卡',
  'backup': '备份失败',
  'storage': '空间不足',
  'system': '系统消息',
};

/// 发送记录状态文案（`app.js:1498`）。
const Map<String, String> deliveryStatusNames = <String, String>{
  'sent': '已发送',
  'pending': '待发送',
  'sending': '发送中',
  'failed': '失败',
  'merged': '已合并',
  'skipped': '已跳过',
};

/// 表单字段输入类型（对齐 `app.js:2436` configs 第三项：text / number /
/// password / email / url）。
enum ChannelFieldType { text, number, password, email, url }

/// 渠道配置项定义（逐字对齐 `app.js:2436` configs 表 `[key, label, type]`）。
///
/// [key] 只是 `POST /api/channels` 请求体 `config` 的键名（不是凭据值本身）。
/// [required] 对齐 `app.js:2438` update()：仅 `bark.url` / `webhook.token`
/// 非必填；其余字段必填，缺失时由服务端 `validate_config` 返回中文原文。
class ChannelConfigField {
  const ChannelConfigField({
    required this.key,
    required this.label,
    required this.type,
    this.required = true,
    this.initialValue = '',
  });

  final String key;
  final String label;
  final ChannelFieldType type;
  final bool required;
  final String initialValue;
}

/// 10 种渠道的 config 字段表（键顺序 / 标签 / 类型逐项对齐 `app.js:2436`）。
const Map<String, List<ChannelConfigField>> channelConfigs =
    <String, List<ChannelConfigField>>{
  'smtp': <ChannelConfigField>[
    ChannelConfigField(
        key: 'host', label: 'SMTP 主机', type: ChannelFieldType.text),
    ChannelConfigField(
        key: 'port',
        label: '端口：465 或 587',
        type: ChannelFieldType.number,
        initialValue: '465'),
    ChannelConfigField(
        key: 'username', label: '登录用户名', type: ChannelFieldType.text),
    ChannelConfigField(
        key: 'password', label: '邮箱授权码', type: ChannelFieldType.password),
    ChannelConfigField(
        key: 'from', label: '发件邮箱', type: ChannelFieldType.email),
    ChannelConfigField(
        key: 'to', label: '收件邮箱', type: ChannelFieldType.email),
  ],
  'bark': <ChannelConfigField>[
    ChannelConfigField(
        key: 'key', label: '设备 Key', type: ChannelFieldType.password),
    ChannelConfigField(
        key: 'url',
        label: '服务地址（默认 https://api.day.app）',
        type: ChannelFieldType.url,
        required: false),
  ],
  'serverchan': <ChannelConfigField>[
    ChannelConfigField(
        key: 'key', label: 'SendKey', type: ChannelFieldType.password),
  ],
  'pushplus': <ChannelConfigField>[
    ChannelConfigField(
        key: 'token', label: 'Token', type: ChannelFieldType.password),
  ],
  'wecom': <ChannelConfigField>[
    ChannelConfigField(
        key: 'url',
        label: '企业微信机器人 Webhook 地址',
        type: ChannelFieldType.url),
  ],
  'webhook': <ChannelConfigField>[
    ChannelConfigField(
        key: 'url', label: 'HTTPS Webhook 地址', type: ChannelFieldType.url),
    ChannelConfigField(
        key: 'token',
        label: 'Bearer Token（可选）',
        type: ChannelFieldType.password,
        required: false),
  ],
  'telegram': <ChannelConfigField>[
    ChannelConfigField(
        key: 'token',
        label: 'Bot Token（数字:字母）',
        type: ChannelFieldType.password),
    ChannelConfigField(
        key: 'chat_id',
        label: 'Chat ID（群组为负数）',
        type: ChannelFieldType.text),
  ],
  'dingtalk': <ChannelConfigField>[
    ChannelConfigField(
        key: 'token', label: 'access_token', type: ChannelFieldType.password),
    ChannelConfigField(
        key: 'secret',
        label: '加签 secret（SEC 开头）',
        type: ChannelFieldType.password),
  ],
  'feishu': <ChannelConfigField>[
    ChannelConfigField(
        key: 'token', label: 'Webhook token', type: ChannelFieldType.password),
    ChannelConfigField(
        key: 'secret',
        label: '签名校验 secret',
        type: ChannelFieldType.password),
  ],
  'ntfy': <ChannelConfigField>[
    ChannelConfigField(
        key: 'host',
        label: '服务地址（如 https://ntfy.sh）',
        type: ChannelFieldType.url),
    ChannelConfigField(
        key: 'topic', label: 'Topic 名称', type: ChannelFieldType.text),
  ],
};

/// 通用字符串列表解析：服务端 `GET /api/channels` 已 `json.loads` 为 List
/// （`main.py:2525`）；兼容个别夹具把 events 作为 JSON 字符串回传的形状。
List<String> parseStringList(Object? raw) {
  if (raw is List) {
    return raw.map((Object? e) => e.toString()).toList();
  }
  if (raw is String && raw.isNotEmpty) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((Object? e) => e.toString()).toList();
      }
    } catch (_) {
      return const <String>[];
    }
  }
  return const <String>[];
}

/// `GET /api/channels` 单行（`main.py:2518-2527`）。
///
/// 🔴 服务端逐行 `item.pop('config')` 不回传配置：本类**没有 config 字段**，
/// 客户端也永不保存 / 回填 / 展示任何凭据。
class ChannelItem {
  const ChannelItem({
    required this.id,
    required this.kind,
    required this.name,
    required this.events,
    required this.enabled,
    required this.quietStart,
    required this.quietEnd,
    required this.interval,
  });

  final String id;
  final String kind;
  final String name;
  final List<String> events;
  final bool enabled;
  final int quietStart;
  final int quietEnd;
  final int interval;

  factory ChannelItem.fromJson(Map<String, dynamic> j) => ChannelItem(
        id: (j['id'] ?? '').toString(),
        kind: (j['kind'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        events: parseStringList(j['events']),
        enabled: j['enabled'] == 1 || j['enabled'] == true,
        quietStart: (j['quiet_start'] as num?)?.toInt() ?? 22,
        quietEnd: (j['quiet_end'] as num?)?.toInt() ?? 8,
        interval: (j['interval'] as num?)?.toInt() ?? 300,
      );
}

/// `GET /api/notices` 单行（`main.py:1955-1958` / `db.py:97-99`）。
/// 内容全部来自服务端：客户端不拼文案、不造 event、不推断未读。
class NoticeItem {
  const NoticeItem({
    required this.id,
    required this.event,
    required this.title,
    required this.created,
    required this.seen,
    this.recordId = '',
  });

  final String id;
  final String event;
  final String title;
  final double created;
  final bool seen;
  final String recordId;

  factory NoticeItem.fromJson(Map<String, dynamic> j) => NoticeItem(
        id: (j['id'] ?? '').toString(),
        event: (j['event'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        created: (j['created'] as num?)?.toDouble() ?? 0,
        seen: j['seen'] == 1 || j['seen'] == true,
        recordId: (j['record_id'] ?? '').toString(),
      );
}

/// `GET /api/deliveries` 单行（`main.py:2567-2572`）。
class DeliveryItem {
  const DeliveryItem({
    required this.id,
    required this.status,
    required this.attempts,
    required this.title,
    required this.name,
    this.error = '',
    this.sentAt,
  });

  final String id;
  final String status;
  final int attempts;
  final String title;
  final String name;
  final String error;
  final double? sentAt;

  factory DeliveryItem.fromJson(Map<String, dynamic> j) => DeliveryItem(
        id: (j['id'] ?? '').toString(),
        status: (j['status'] ?? '').toString(),
        attempts: (j['attempts'] as num?)?.toInt() ?? 0,
        title: (j['title'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        error: (j['error'] ?? '').toString(),
        sentAt: (j['sent_at'] as num?)?.toDouble(),
      );

  bool get isFailed => status == 'failed';
}

/// 渠道类型中文名（未知类型原样回显，不臆造文案）。
String channelLabel(String kind) => channelNames[kind] ?? kind;

/// 事件中文名（未知事件原样回显，不臆造文案）。
String eventLabel(String id) => eventNames[id] ?? id;

/// 发送状态中文名（`app.js:1498`）。
String deliveryStatusLabel(String status) =>
    deliveryStatusNames[status] ?? status;

/// 已订阅事件中文名串（对齐 `app.js:1498` `c.events.map(...).join('、')`）。
String eventsLabel(List<String> events) =>
    events.isEmpty ? '未订阅事件' : events.map(eventLabel).join('、');

/// 免打扰时段文案（对齐 `app.js:1498`：起止相同＝全天接收）。
String quietLabel(int start, int end) =>
    start == end ? '全天接收' : '$start:00–$end:00 免打扰';

/// 服务端 created 是 epoch 秒（`db.py:44-45`；Web `app.js:89` 用 `*1000`）。
String noticeTimeLabel(double epochSeconds) {
  if (epochSeconds <= 0) return '';
  final DateTime dt =
      DateTime.fromMillisecondsSinceEpoch((epochSeconds * 1000).toInt());
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.month}月${dt.day}日 ${two(dt.hour)}:${two(dt.minute)}';
}

/// 构造 `POST /api/channels` 请求体（逐键对齐 `app.js:2437` 末尾）。
Map<String, dynamic> buildChannelPayload({
  required String kind,
  required String name,
  required Map<String, String> config,
  required List<String> events,
  required int quietStart,
  required int quietEnd,
  required int interval,
}) =>
    <String, dynamic>{
      'kind': kind,
      'name': name,
      'config': config,
      'events': events,
      'quiet_start': quietStart,
      'quiet_end': quietEnd,
      'interval': interval,
      'enabled': true,
    };

/// 从表单输入构造 config（对齐 `app.js:2437`：只收集非空字段）。
/// [values] 是表单输入框的一次性快照，函数返回后立即由调用方丢弃。
Map<String, String> buildChannelConfig(
    String kind, Map<String, String> values) {
  final List<ChannelConfigField> fields =
      channelConfigs[kind] ?? const <ChannelConfigField>[];
  final Map<String, String> config = <String, String>{};
  for (final ChannelConfigField f in fields) {
    final String v = (values[f.key] ?? '').trim();
    if (v.isNotEmpty) config[f.key] = v;
  }
  return config;
}

/// 新建表单 12 事件默认全选（`app.js:2437` 每个 checkbox 都带 `checked`）。
List<String> defaultSelectedEvents() => eventNames.keys.toList();
