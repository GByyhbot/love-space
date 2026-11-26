/// 2.8.0 报备入口 P0 · API 层（`core/peer/` 内扩展，不新建网络栈）。
///
/// 契约依据 `app/report_routes.py` + `app/main.py` 实读（后端零改动）：
/// · `GET  /api/peer/report-presets` → `{presets:[{scene,label,emoji,summary,push}]}`
/// · `POST /api/peer/report`         → `{ok, created, event, peer_revision}`
///   · 同 `client_id` 重试 → `created=false`，不重复推送（幂等依据）
///   · 本人 events 共享关闭 → **422**，detail=「报备事件共享已关闭」
/// · `POST /api/peer/events/{id}/ack` → `{ok, event, peer_revision}`；自回应 400、不存在 404
/// · `GET  /api/peer/events?date=`   → `{date, mine:[...], peer:{closed_off, events:[...]}}`
/// · `GET  /api/peer/settings`       → **顶层四键** `{location,track,events,usage}`
///   （实读 `app/main.py:2008` 直返 `peer.load_settings()` 的 dict，无包裹层）
/// · `PUT  /api/peer/settings`       → 同结构；🔴 `peer.save_settings` 按
///   `bool(data.get(k, True))` **全覆盖**写四键，前端漏传即被重置回 true，
///   所以本文件所有写入口都提交完整四键（[PeerShareSettings.toJson]）。
///
/// 🔴 错误通道（7-C 口径）：`validateAppStatus` 把 4xx 当成功 Response 放行，
/// 因此每个写方法都必须显式 `writeResponseError` 判定，**不许只 catch
/// DioException**（那会把 403/422 当成功）。
///
/// 🔴 解析容缺：旧后端 / 自动事件没有 `source/scene/note/place_name/client_id/ack`
/// 列时按缺省补齐（source='auto'、ack=null），不允许因缺字段整表解析失败。
library;

import 'package:dio/dio.dart';

import '../api/api_client.dart';
import '../chat/chat_repository.dart' show newChatClientId;

/// client_id 生成：**盘线复用** chat 发消息同款（`chat_repository.newChatClientId`
/// = uuid v4，与 Web `uuid()` 同口径），不自创随机串。
String newReportClientId() => newChatClientId();

/// 报备事件共享被关闭（POST /api/peer/report 的 422 专项）。
///
/// 与通用 4xx 分开的理由：这个错要单独呈现「开启后才能发报备」的固定文案，
/// 且离线队列遇到它必须**出队丢弃**（重试一万次也还是 422）。
class ReportShareClosed implements Exception {
  const ReportShareClosed([this.detail = '报备事件共享已关闭']);
  final String detail;

  @override
  String toString() => detail;
}

/// 服务端给了 detail 的其它业务失败（4xx，非「关闭」语义）。
class PeerApiException implements Exception {
  const PeerApiException(this.detail);
  final String detail;

  @override
  String toString() => detail;
}

/// `GET /api/peer/report-presets` 单条（双人共享预设）。
class ReportPreset {
  const ReportPreset({
    required this.scene,
    required this.label,
    this.emoji = '💬',
    this.summary = '',
    this.push = true,
  });

  final String scene;
  final String label;
  final String emoji;

  /// 预设附带的摘要（发送时直接用作 `summary`）。
  final String summary;

  /// 预设附带的推送缺省（`push:false` = 静默预设，补备注时也不许变成强推送）。
  final bool push;

  static ReportPreset? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    final scene = (j['scene'] ?? '').toString().trim();
    final label = (j['label'] ?? '').toString().trim();
    if (scene.isEmpty || label.isEmpty) return null;
    final summary = (j['summary'] ?? '').toString().trim();
    return ReportPreset(
      scene: scene,
      label: label,
      emoji: (j['emoji'] ?? '💬').toString().trim().isEmpty
          ? '💬'
          : (j['emoji'] ?? '💬').toString().trim(),
      summary: summary.isEmpty ? label : summary,
      push: j['push'] is bool ? j['push'] as bool : true,
    );
  }

  Map<String, Object?> toJson() => {
        'scene': scene,
        'label': label,
        'emoji': emoji,
        'summary': summary,
        'push': push,
      };
}

/// 预设回落集（**仅**接口失败且无缓存时用于渲染，绝不落库冒充用户配置）。
/// 与后端 `peer.DEFAULT_REPORT_PRESETS` 逐字同源。
const List<ReportPreset> kDefaultReportPresets = [
  ReportPreset(
      scene: 'depart', label: '出门啦', emoji: '🚶', summary: '准备出门啦'),
  ReportPreset(
      scene: 'arrive_home',
      label: '到家了',
      emoji: '🏠',
      summary: '平安到家啦'),
  ReportPreset(
      scene: 'meal',
      label: '吃饭中',
      emoji: '🍚',
      summary: '正在干饭',
      push: false),
  ReportPreset(
      scene: 'busy',
      label: '忙碌中',
      emoji: '💻',
      summary: '在忙，晚点回你',
      push: false),
  ReportPreset(
      scene: 'sleep',
      label: '准备睡了',
      emoji: '🌙',
      summary: '准备睡觉啦，晚安'),
  ReportPreset(
      scene: 'miss', label: '想你了', emoji: '💗', summary: '突然好想你'),
];

/// 一条事件上的回应（`ack` 非空才存在——后端没有独立的「已读」字段）。
class PeerEventAck {
  const PeerEventAck({required this.by, required this.emoji, this.at});

  final String by;
  final String emoji;
  final double? at;

  static PeerEventAck? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    final emoji = (j['emoji'] ?? '').toString();
    if (emoji.isEmpty) return null;
    return PeerEventAck(
      by: (j['by'] ?? '').toString(),
      emoji: emoji,
      at: (j['at'] as num?)?.toDouble(),
    );
  }
}

/// 报备事件（`GET /api/peer/events` 的一行；容缺列按缺省补齐）。
class PeerEventItem {
  const PeerEventItem({
    required this.id,
    required this.user,
    required this.type,
    required this.ts,
    required this.summary,
    this.pushed = 0,
    this.source = 'auto',
    this.scene = '',
    this.note = '',
    this.placeName = '',
    this.clientId = '',
    this.ack,
    this.mine = false,
    this.payload = const <String, Object?>{},
  });

  final String id;
  final String user;
  final String type;
  final double ts;
  final String summary;
  final int pushed;

  /// `manual` = 主动报备；`auto` = 自动守护事件（旧后端无此列时按 auto）。
  final String source;
  final String scene;
  final String note;
  final String placeName;
  final String clientId;
  final PeerEventAck? ack;

  /// 该行是否属于「我」（后端 `mine=true` 或列表来源判定）。
  final bool mine;

  /// 状态事件的结构化载荷（2.8.7）；主动报备恒为空 map。
  final Map<String, Object?> payload;

  /// 事件流里**只给 manual_report 渲染报备卡与回应按钮**，自动事件维持简行。
  bool get isManualReport => type == 'manual_report';

  /// 设备状态事件（`state.*`）：简行渲染 + 文案由 payload 生成。
  bool get isStateEvent => type.startsWith('state.');

  static PeerEventItem fromJson(Object? raw, {bool mine = false}) {
    final j = raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{};
    return PeerEventItem(
      id: (j['id'] ?? '').toString(),
      user: (j['user'] ?? '').toString(),
      type: (j['type'] ?? '').toString(),
      ts: (j['ts'] as num?)?.toDouble() ?? 0,
      summary: (j['summary'] ?? '').toString(),
      pushed: (j['pushed'] as num?)?.toInt() ?? 0,
      source: (j['source'] ?? 'auto').toString(),
      scene: (j['scene'] ?? '').toString(),
      note: (j['note'] ?? '').toString(),
      placeName: (j['place_name'] ?? '').toString(),
      clientId: (j['client_id'] ?? '').toString(),
      ack: PeerEventAck.fromJson(j['ack']),
      mine: j['mine'] == true || mine,
      payload: j['payload'] is Map
          ? (j['payload'] as Map).cast<String, Object?>()
          : const <String, Object?>{},
    );
  }

  PeerEventItem withAck(PeerEventAck? value) => PeerEventItem(
        id: id,
        user: user,
        type: type,
        ts: ts,
        payload: payload,
        summary: summary,
        pushed: pushed,
        source: source,
        scene: scene,
        note: note,
        placeName: placeName,
        clientId: clientId,
        ack: value,
        mine: mine,
      );
}

/// 当日合并事件流：mine 与 peer.events 合并为单一时间序（ts 降序）。
class PeerEventsDay {
  const PeerEventsDay({
    required this.date,
    required this.events,
    required this.peerClosedOff,
  });

  final String date;
  final List<PeerEventItem> events;

  /// 对方 events 共享关闭——对等口径：明示，不当故障、不伪造空列表语义。
  final bool peerClosedOff;

  List<PeerEventItem> get peerEvents =>
      events.where((e) => !e.mine).toList(growable: false);

  List<PeerEventItem> get mineEvents =>
      events.where((e) => e.mine).toList(growable: false);

  /// 对方最近一条**主动报备**（首页胶囊条那行小字的数据源）。
  PeerEventItem? get latestPeerManualReport {
    for (final e in events) {
      if (!e.mine && e.isManualReport) return e;
    }
    return null;
  }
}

/// 发送结果：`created=false` 表示同 client_id 已存在（幂等命中，不是失败）。
class ReportSendResult {
  const ReportSendResult({required this.created, required this.event});
  final bool created;
  final PeerEventItem event;
}

/// 拉预设；失败抛 dio 异常或 [PeerApiException]，由调用方决定回落。
Future<List<ReportPreset>> fetchReportPresets(Dio dio) async {
  final r = await dio.get('/api/peer/report-presets');
  final err = writeResponseError(r);
  if (err != null) throw PeerApiException(err);
  final raw = r.data;
  if (raw is! Map) throw const PeerApiException(genericErrorText);
  final list = (raw['presets'] as List?) ?? const [];
  final parsed = list
      .map(ReportPreset.fromJson)
      .whereType<ReportPreset>()
      .toList(growable: false);
  // 服务端返回空集视为异常形态：回落默认集（不落库）
  return parsed.isEmpty ? kDefaultReportPresets : parsed;
}

/// 发一条报备。
///
/// [push] 传 null 表示「用后端按 scene 推的缺省」；UI 层两种入口都显式传值
/// （单击=预设 push，长按补备注=仍用预设 push，避免静默预设误触发强推送）。
///
/// 🔴 422 且 detail 含「关闭」→ 抛 [ReportShareClosed]（专用分支）；
/// 其它 4xx → [PeerApiException]（detail 原文直通 UI）。
Future<ReportSendResult> sendReport(
  Dio dio, {
  required String scene,
  required String clientId,
  String summary = '',
  String note = '',
  String placeName = '',
  bool? push,
  double? ts,
  String kind = '',
  Map<String, Object?>? payload,
}) async {
  final r = await dio.post('/api/peer/report', data: {
    'scene': scene,
    'summary': summary,
    'note': note,
    'place_name': placeName,
    'push': ?push,
    'client_id': clientId,
    'ts': ?ts,
    // 2.8.7：状态事件走同一条通道（kind 非空即状态分支，后端据此写 state.*）
    if (kind.isNotEmpty) 'kind': kind,
    'payload': ?payload,
  });
  final status = r.statusCode ?? 0;
  final err = writeResponseError(r);
  if (err != null) {
    if (status == 422 && err.contains('关闭')) throw ReportShareClosed(err);
    throw PeerApiException(err);
  }
  final raw = r.data;
  if (raw is! Map) throw const PeerApiException(genericErrorText);
  final j = raw.cast<String, dynamic>();
  return ReportSendResult(
    created: j['created'] == true,
    event: PeerEventItem.fromJson(j['event'], mine: true),
  );
}

/// 一键回应某条对方报备（禁止回应自己：后端 400；不存在：404）。
Future<PeerEventItem> ackReport(
  Dio dio,
  String eventId,
  String emoji,
) async {
  final r = await dio.post('/api/peer/events/$eventId/ack', data: {'emoji': emoji});
  final err = writeResponseError(r);
  if (err != null) throw PeerApiException(err);
  final raw = r.data;
  if (raw is! Map) throw const PeerApiException(genericErrorText);
  return PeerEventItem.fromJson((raw)['event']);
}

/// 本人四项共享开关（`GET/PUT /api/peer/settings` 的顶层四键）。
///
/// 🔴 不可变 + `toJson()` **恒输出全部 4 键**：后端 `save_settings` 逐键
/// `bool(data.get(k, True))` 覆盖写，漏传键 = 静默重置为 `true`（把对方
/// 刚关掉的共享又打开）。所有变更一律 `copyWith` 后整对象提交。
/// `GET /api/peer/state-daily` 归一结果。
class PeerStateDaily {
  const PeerStateDaily({
    required this.date,
    required this.mineScreenSec,
    required this.mineUnlocks,
    required this.peerClosedOff,
    required this.peerScreenSec,
    required this.peerUnlocks,
  });

  final String date;
  final int mineScreenSec;
  final int mineUnlocks;
  final bool peerClosedOff;
  final int peerScreenSec;
  final int peerUnlocks;

  /// 对方关闭共享时两列都是 0，但那是「看不到」而不是「没发生」——
  /// 渲染层必须先判 [peerClosedOff]，不许直接显示 0。
  bool get peerHasData => !peerClosedOff && (peerScreenSec > 0 || peerUnlocks > 0);

  static PeerStateDaily fromJson(Map<String, dynamic> j) {
    final mine = (j['mine'] as Map?)?.cast<String, dynamic>() ?? const {};
    final peer = (j['peer'] as Map?)?.cast<String, dynamic>() ?? const {};
    return PeerStateDaily(
      date: (j['date'] ?? '').toString(),
      mineScreenSec: (mine['screen_sec'] as num?)?.toInt() ?? 0,
      mineUnlocks: (mine['unlocks'] as num?)?.toInt() ?? 0,
      peerClosedOff: peer['closed_off'] == true,
      peerScreenSec: (peer['screen_sec'] as num?)?.toInt() ?? 0,
      peerUnlocks: (peer['unlocks'] as num?)?.toInt() ?? 0,
    );
  }
}

class PeerShareSettings {
  const PeerShareSettings({
    this.location = true,
    this.track = true,
    this.events = true,
    this.usage = true,
  });

  /// 实时位置共享。
  final bool location;

  /// 历史轨迹共享（轨迹 15 天滚动清理）。
  final bool track;

  /// 报备与事件共享（关闭后 `POST /api/peer/report` 返回 422）。
  final bool events;

  /// 设备使用报告共享（后续版本接入）。
  final bool usage;

  /// 全开（仅作 `copyWith` 基线与测试用，**不得**用作加载失败时的兜底渲染）。
  static const PeerShareSettings allOn = PeerShareSettings();

  /// 解析容缺：缺键/非 bool 一律按 `true`——与 `app/peer.py` 口径逐字一致。
  static PeerShareSettings fromJson(Object? raw) {
    final j = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
    bool pick(String k) => j[k] is bool ? j[k] as bool : true;
    return PeerShareSettings(
      location: pick('location'),
      track: pick('track'),
      events: pick('events'),
      usage: pick('usage'),
    );
  }

  PeerShareSettings copyWith({
    bool? location,
    bool? track,
    bool? events,
    bool? usage,
  }) =>
      PeerShareSettings(
        location: location ?? this.location,
        track: track ?? this.track,
        events: events ?? this.events,
        usage: usage ?? this.usage,
      );

  /// 🔴 恒 4 键（见类注释），顺序与后端 `SHARE_KEYS` 一致。
  Map<String, Object?> toJson() => {
        'location': location,
        'track': track,
        'events': events,
        'usage': usage,
      };

  @override
  bool operator ==(Object other) =>
      other is PeerShareSettings &&
      other.location == location &&
      other.track == track &&
      other.events == events &&
      other.usage == usage;

  @override
  int get hashCode => Object.hash(location, track, events, usage);

  @override
  String toString() =>
      'PeerShareSettings(location:$location, track:$track, '
      'events:$events, usage:$usage)';
}

/// 读本人四项共享开关（失败抛 [PeerApiException]，**不回落全开**——
/// 加载失败必须走错误态，不许拿默认全开冒充服务端真实配置）。
Future<PeerShareSettings> fetchPeerSettings(Dio dio) async {
  final r = await dio.get('/api/peer/settings');
  final err = writeResponseError(r);
  if (err != null) throw PeerApiException(err);
  final raw = r.data;
  if (raw is! Map) throw const PeerApiException(genericErrorText);
  return PeerShareSettings.fromJson(raw);
}

/// 写本人四项共享开关，返回后端落库后的最新状态。
///
/// 🔴 提交体恒为完整 4 键（[PeerShareSettings.toJson]），禁止只传变更键。
Future<PeerShareSettings> updatePeerSettings(
  Dio dio,
  PeerShareSettings settings,
) async {
  final r = await dio.put('/api/peer/settings', data: settings.toJson());
  final err = writeResponseError(r);
  if (err != null) throw PeerApiException(err);
  final raw = r.data;
  if (raw is! Map) throw const PeerApiException(genericErrorText);
  return PeerShareSettings.fromJson(raw);
}

/// 当日设备状态汇总（2.8.7）：亮屏时长 / 解锁次数。
///
/// 口径与 [fetchPeerEvents] 一致：服务端按空间时区切日；对方 events 关闭时
/// `closed_off=true` 且数值归 0（**不许拿 0 冒充「今天没亮屏」**）。
Future<PeerStateDaily> fetchStateDaily(Dio dio, {String date = ''}) async {
  final r = await dio.get('/api/peer/state-daily', queryParameters: {
    if (date.isNotEmpty) 'date': date,
  });
  final err = writeResponseError(r);
  if (err != null) throw PeerApiException(err);
  final raw = r.data;
  if (raw is! Map) throw const PeerApiException(genericErrorText);
  return PeerStateDaily.fromJson(raw.cast<String, dynamic>());
}

/// 当日事件流（默认服务端时区的「今天」；传 [date] 可指定 yyyy-MM-dd）。
Future<PeerEventsDay> fetchPeerEvents(Dio dio, {String date = ''}) async {
  final r = await dio.get('/api/peer/events', queryParameters: {
    if (date.isNotEmpty) 'date': date,
  });
  final err = writeResponseError(r);
  if (err != null) throw PeerApiException(err);
  final raw = r.data;
  if (raw is! Map) throw const PeerApiException(genericErrorText);
  final j = raw.cast<String, dynamic>();
  final mine = <PeerEventItem>[];
  for (final e in (j['mine'] as List?) ?? const []) {
    final item = PeerEventItem.fromJson(e, mine: true);
    if (item.id.isNotEmpty) mine.add(item);
  }
  final peerBlock =
      (j['peer'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
  final theirs = <PeerEventItem>[];
  for (final e in (peerBlock['events'] as List?) ?? const []) {
    final item = PeerEventItem.fromJson(e);
    if (item.id.isNotEmpty) theirs.add(item);
  }
  final merged = [...mine, ...theirs]..sort((a, b) => b.ts.compareTo(a.ts));
  return PeerEventsDay(
    date: (j['date'] ?? date).toString(),
    events: merged,
    peerClosedOff: peerBlock['closed_off'] == true,
  );
}
