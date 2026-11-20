/// 生理期写操作计划（条目 8 · 段 8-B · 纯 Dart，可单测）。
///
/// 把 `static/period.js` 的写语义抽成「计划对象」，由
/// [PeriodController.executePlan] 统一执行（7-C 错误通道 + `refresh()`）。
/// 全部**不出现 `end` 键**：结束靠改 `length` 或删整条（`period.js` 全文无 end）。
///
/// 逐字移植：
/// · `periodStart :77-93`（gap 1–3 接回上一段 / 否则新建 `max(3,d.length)`）；
/// · `periodEnd :94-101`（首日 DELETE / 中途改 length / 不在经期提示）；
/// · `periodMore :102-109`（`want=max(len,n-s+2)`，幂等只提示不写）；
/// · `periodSaveDay :59-70`（整份 body 覆盖 / 清空 ''/null/空数组键 /
///   强制删 `start` / 有行 PUT 无行 POST+client_id / refresh）；
/// · `periodForm :809-833`（`{start,length,cycle,flow?,symptoms,content}`，
///   有记录 PUT 不带 client_id / 无记录 POST 带 client_id）；
/// · `app.js:2507-2510` `period-del-episode`（整次全部碎片逐个 DELETE）。
///
/// 结果提示文案全部按 Web 逐字（`:85/:92/:96/:98/:99/:104/:106/:108`）。
/// 期望值由 Node vm 实跑 Web 原函数产出（`period_b_expected.json` 的
/// `actions` / `dayLogs`），Dart 侧 `plan*` 逐项断言 method/path/body/message 全等。
library;

import 'period_engine.dart';
import 'period_meta.dart';

/// 写方法种类（对齐 Web `post/put/del`）。
enum PeriodWriteKind { post, put, delete }

/// 一次写操作的完整描述。
class PeriodWritePlan {
  const PeriodWritePlan({
    required this.message,
    this.kind,
    this.path,
    this.body,
    this.clientId,
    this.refresh = true,
  });

  /// Web `toast()` 文案；无写操作时（幂等 / 不在经期）也用它提示。
  final String message;

  /// null = 只提示、不写（`:96`/`:104`/`:106`）。
  final PeriodWriteKind? kind;
  final String? path;
  final Map<String, dynamic>? body;

  /// 仅 POST 携带（Web `uuid()`；App 由表单 State initState 生成一次复用）。
  final String? clientId;

  /// 是否 `refresh()`（无写操作时 Web 直接 `return toast(...)`，不刷新）。
  final bool refresh;

  bool get hasWrite => kind != null;
}

/// `periodStart :77-93`。
PeriodWritePlan planStart(PeriodData d, String day,
    {required String clientId}) {
  final n = dayNum(day);
  final lastEp = d.lastEp;
  if (lastEp != null) {
    final gap = n - lastEp.end;
    if (gap >= 1 && gap <= 3) {
      // `:84` 接回上一段：改 lastEp.rec（最后一条碎片）的 length。
      final r = lastEp.rec;
      final body = <String, dynamic>{
        ...r.body,
        'length': n - dayNum(r.start) + 1,
      };
      return PeriodWritePlan(
        kind: PeriodWriteKind.put,
        path: '/records/${r.id}',
        body: body,
        message: '已经把这次经期接到今天',
      );
    }
  }
  // `:90` 默认天数 `Math.max(3, d.length)`；**没有 end 键**。
  final body = <String, dynamic>{
    'start': day,
    'length': d.length < 3 ? 3 : d.length,
    'cycle': d.cycle,
  };
  return PeriodWritePlan(
    kind: PeriodWriteKind.post,
    path: '/records',
    body: body,
    clientId: clientId,
    message: '已记下这次经期',
  );
}

/// `periodEnd :94-101`。
PeriodWritePlan planEnd(PeriodData d, String day) {
  final n = dayNum(day);
  final hit = periodEpisodeOf(d, n);
  if (hit == null) {
    return const PeriodWritePlan(
      message: '这天本来就不在经期里',
      refresh: false,
    );
  }
  final ep = hit.owner;
  final s = dayNum(ep.start);
  if (s == n) {
    // `:98` 首日 → 直接删掉这条记录（DELETE）。
    return PeriodWritePlan(
      kind: PeriodWriteKind.delete,
      path: '/records/${ep.id}',
      message: '已撤掉这次经期',
    );
  }
  // `:99` 中途 → 把这段截到昨天（length = n - s）。
  final body = <String, dynamic>{...ep.body, 'length': n - s};
  return PeriodWritePlan(
    kind: PeriodWriteKind.put,
    path: '/records/${ep.id}',
    body: body,
    message: '这次经期到昨天为止',
  );
}

/// `periodMore :102-109`（幂等）。
PeriodWritePlan planMore(PeriodData d, String day) {
  final n = dayNum(day);
  final hit = periodEpisodeOf(d, n);
  if (hit == null) {
    return const PeriodWritePlan(message: '这天不在经期里', refresh: false);
  }
  final ep = hit.owner;
  final s = dayNum(ep.start);
  final len = jsNumberOr(ep.body['length'], 5);
  final want = _max(len, n - s + 2);
  if (want == len) {
    return PeriodWritePlan(
      message: '这次经期已经排到第 $len 天了',
      refresh: false,
    );
  }
  final body = <String, dynamic>{...ep.body, 'length': want};
  return PeriodWritePlan(
    kind: PeriodWriteKind.put,
    path: '/records/${ep.id}',
    body: body,
    message: '这次经期又多算一天',
  );
}

int _max(int a, int b) => a > b ? a : b;

/// `periodSaveDay :59-70` 的 body 语义（纯函数，便于逐项对拍）。
Map<String, dynamic> periodSaveDayBody({
  required List<PeriodRow> records,
  required String day,
  required Map<String, dynamic> patch,
}) {
  final row = periodDayRowOf(records, day);
  // `:61` 整份 body 覆盖（原始 body 为底 + date + patch）。
  final body = <String, dynamic>{
    if (row != null) ...row.body,
    'date': day,
    ...patch,
  };
  // `:62-65` 清掉 '' / null / 空数组键。
  body.removeWhere((k, v) =>
      v == '' || v == null || (v is List && v.isEmpty));
  // `:66` 强制删 start（日记录永不带 start，否则被当成一次经期）。
  // Web 是 `if(body.start)delete body.start`；空串/null 已在上一步删掉，
  // 此处用同一份 JS truthy 口径，避免 0/false 这类畸形值被误删。
  if (jsTruthy(body['start'])) body.remove('start');
  return body;
}

/// `periodSaveDay :59-70` 完整计划（有行 PUT / 无行 POST + client_id）。
PeriodWritePlan planSaveDay({
  required List<PeriodRow> records,
  required String day,
  required Map<String, dynamic> patch,
  required String clientId,
}) {
  final row = periodDayRowOf(records, day);
  final body = periodSaveDayBody(records: records, day: day, patch: patch);
  if (row != null) {
    return PeriodWritePlan(
      kind: PeriodWriteKind.put,
      path: '/records/${row.id}',
      body: body,
      message: '',
    );
  }
  return PeriodWritePlan(
    kind: PeriodWriteKind.post,
    path: '/records',
    body: body,
    clientId: clientId,
    message: '',
  );
}

/// `periodForm :818-829` 的提交 body（逐字 `:824-826`）。
///
/// [flowText] 为下拉值（'' = 不记）；[lengthText]/[cycleText] 为输入框原文；
/// [defaultCycle] 取引擎 `d.cycle`（`:824` `Number(f.get('cycle')||d.cycle)`）。
Map<String, dynamic> periodFormBody({
  required String start,
  required String lengthText,
  required String cycleText,
  required String flowText,
  required List<String> symptoms,
  required String content,
  required int defaultCycle,
}) {
  return <String, dynamic>{
    'start': start,
    'length': _formNumber(lengthText, 5),
    'cycle': _formNumber(cycleText, defaultCycle),
    if (flowText.isNotEmpty) 'flow': int.tryParse(flowText) ?? 0,
    'symptoms': List<String>.from(symptoms),
    'content': content,
    // 🔴 无 date、无 end、无 client_id（client_id 是记录顶层字段）。
  };
}

/// `Number(f.get('x')||fallback)`（空串 → fallback）。
int _formNumber(String raw, int fallback) {
  if (raw.isEmpty) return fallback;
  final n = num.tryParse(raw);
  return n == null || n.isNaN ? fallback : n.toInt();
}

/// `periodForm :827-828`：有记录 PUT（**不带 client_id**）/ 无记录 POST（带）。
PeriodWritePlan planSaveEpisodeForm({
  required String? recordId,
  required Map<String, dynamic> body,
  required String clientId,
}) {
  if (recordId != null) {
    return PeriodWritePlan(
      kind: PeriodWriteKind.put,
      path: '/records/$recordId',
      body: body,
      message: '已记下这次',
    );
  }
  return PeriodWritePlan(
    kind: PeriodWriteKind.post,
    path: '/records',
    body: body,
    clientId: clientId,
    message: '已记下这次',
  );
}

/// `app.js:2507-2510` 删整次：对该 episode 的**全部碎片** id 逐个 DELETE。
/// 回收站不会自动删除、可随时恢复，恢复接已有通用 `PersonalController.restore`。
List<String> deleteEpisodeIds(PeriodEpisode ep) =>
    ep.frags.map((r) => r.id).toList();
