/// 生理期数据层（条目 8 · 段 8-A）：全部走**通用 `/api/records`** 读写。
///
/// 🔴 拉取方式与理由（主人第 3 条要求，最终小结亦须写明）：
/// 选 `GET /api/records?kind=period&limit=1000`，走 `main.py:1165` /
/// `:1169-1171` 的 **`only_period` 短路**（`kinds==['period']` 且
/// `period.pending_count()==0` 时直接 `return period.rows_for(...)`，不查主库）——
/// 分库记录全量返回、路径最短、不依赖合并分支。
/// · **绝不带 `media_type`、绝不把 period 放进 `exclude`**：`main.py:1166-1167`
///   `merge_period` 在 `media_type` 非空或 `exclude` 含 period 时**整体置 False**，
///   分库记录完全不返回；虽然 `only_period` 短路在前，但合并路径踩坑根因就在此，
///   显式单 kind 连合并分支都不进，最稳。
/// · **不加 `author`**：D6 现行口径「双方可看可记可改可删，不自创作者门槛」——
///   `period.visible :128-130` 只看 deleted、`serialize :133-140` 无门槛；
///   带 author 会把对方记的日记录过滤掉（验收点②）。
/// · **不带 `trash`**：本页只显示未删记录；已删记录由个人角落回收站
///   （`PersonalController.loadTrash`，`trashKinds` 含 period）呈现与恢复。
///
/// 两种记录形状（`period.js:32-34` / `:66`，**绝不虚构 `end` 键**）：
/// · 经期区间型：有 `start`、无 `date` → `start/length/cycle/content`，参与推算；
/// · 日记录型：有 `date`、无 `start` → `date/content`，不参与推算；
///   `period.js:66` 存日记录会强制删 `start`，本层 form 也永不给日记录带 start。
///
/// 错误通道（复用 7-C 返修）：`api.validateAppStatus` 让 4xx 作为成功
/// [Response] 返回而不抛异常，故**全部写方法**经 [_write] 显式调
/// `api.writeResponseError` 判 4xx，服务端 `data['detail']` 原文透传；
/// 失败不发成功通知、不 pop、输入保留、不自动重试（页面表单负责双呈现）。
///
/// 编辑**回填铁律**：`main.py:925` `clean_body` 的 `previous` 形参全文无引用、
/// PUT 只保存客户端传来的全量 body → 一律 `mergeRecordBody(原 body, 改动键)`。
///
/// 恢复：**不新写入口/端点**，接已有通用 restore ——
/// `personal_controller.dart:584-602` 的 `restore(rid)`
/// → `POST /api/records/{rid}/restore` → `main.py:1443-1451`
/// → `restore_period_record :1270-1275`（作者不符 404「记录不存在」，
/// 由 7-C 返修后的 `_writeResponse` 原文透传，不静默、不发成功通知）。
/// 本页只做软删，恢复按钮在个人角落 · 回收站（已有），页面仅作文字说明。
library;

import 'package:dio/dio.dart' show Dio, Response;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/together/together_data.dart';
import 'period_actions.dart';
import 'period_engine.dart';

/// 显式单 kind（走 `only_period` 短路；见文件头「拉取方式与理由」）。
const String periodKind = 'period';

/// `GET /api/records` 上限 1000（`main.py:1148` `limit=min(max(limit,0),1000)`）。
const int periodFetchLimit = 1000;

/// period 记录的两种形状（外加畸形兜底）。
enum PeriodShape {
  /// 经期区间行：有 `start`，参与推算。
  episode,

  /// 日记录行：有 `date` 无 `start`，不参与推算。
  day,

  /// 两个键都没有（畸形行）：不参与推算，不在表单里编辑。
  unknown,
}

/// 形状识别，逐字对齐 `period.js:34`（`!start && date`）与 `:112`（`start`）。
PeriodShape periodShapeOf(Map<String, dynamic> body) {
  final start = (body['start'] ?? '').toString();
  final date = (body['date'] ?? '').toString();
  if (start.isNotEmpty) return PeriodShape.episode;
  if (date.isNotEmpty) return PeriodShape.day;
  return PeriodShape.unknown;
}

/// 是否经期区间行。
bool isPeriodEpisode(TogetherRecord r) =>
    periodShapeOf(r.body) == PeriodShape.episode;

/// 是否日记录行。
bool isPeriodDay(TogetherRecord r) => periodShapeOf(r.body) == PeriodShape.day;

/// 列表排序：按「经期 start / 日记录 date」倒序，同日按原顺序稳定。
/// 与 `sortByCreatedDesc` 同款稳定排序，避免同刻乱跳。
List<TogetherRecord> sortPeriodRecords(List<TogetherRecord> src) {
  String key(TogetherRecord r) {
    final start = (r.body['start'] ?? '').toString();
    return start.isNotEmpty ? start : (r.body['date'] ?? '').toString();
  }

  final indexed = <int, TogetherRecord>{
    for (var i = 0; i < src.length; i++) i: src[i],
  };
  final order = indexed.keys.toList()
    ..sort((a, b) {
      final c = key(indexed[b]!).compareTo(key(indexed[a]!));
      return c != 0 ? c : a.compareTo(b);
    });
  return [for (final i in order) indexed[i]!];
}

class PeriodState {
  const PeriodState({
    this.records = const [],
    this.loading = false,
    this.error,
  });

  /// 全部未删的 period 记录（**不按 author 过滤**，双方共享同一条周期）。
  final List<TogetherRecord> records;
  final bool loading;
  final String? error;

  PeriodState copyWith({
    List<TogetherRecord>? records,
    bool? loading,
    String? error,
  }) =>
      PeriodState(
        records: records ?? this.records,
        loading: loading ?? this.loading,
        error: error,
      );
}

class PeriodController extends Notifier<PeriodState> {
  bool _disposed = false;
  bool _loaded = false;
  int _reqSeq = 0; // 请求代次防竞态（下拉刷新/写后重拉/SSE 重拉互不误杀）

  @override
  PeriodState build() {
    // Riverpod 依赖重建时旧 onDispose 先触发，必须在此复位，
    // 否则 _disposed 永久为 true、后续写方法静默 no-op（7-A 同款教训）。
    _disposed = false;
    _loaded = false;
    ref.onDispose(() => _disposed = true);
    return const PeriodState();
  }

  /// 进页首屏拉取。
  Future<void> bootstrap() async {
    if (!_loaded) await load();
  }

  /// 全量拉取（进页 / 下拉刷新 / 写后 / SSE other 重拉同一路径）。
  Future<void> load() async {
    if (_disposed) return;
    final seq = ++_reqSeq;
    state = state.copyWith(loading: true, error: null);
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.get('/api/records', queryParameters: {
        'kind': periodKind,
        'limit': periodFetchLimit,
        // 🔴 无 media_type、无 exclude、无 author、无 trash（见文件头）。
      });
      if (_disposed || seq != _reqSeq) return; // 旧响应失效
      final all = parseTogetherRecords(r.data)
          .where((x) => x.kind == periodKind)
          .toList();
      state = state.copyWith(records: all, loading: false);
    } catch (e) {
      if (!_disposed && seq == _reqSeq) {
        state = state.copyWith(loading: false, error: api.errorDetail(e));
      }
    }
    _loaded = true;
  }

  /// 🔴 7-C 返修统一写入口：显式判定被 `api.validateAppStatus` 放行的 4xx。
  /// 2xx → null（真成功）；4xx → 服务端 `data['detail']` 原文；
  /// 真正抛出的异常（5xx / 网络层）→ `api.errorDetail` 兜底。
  Future<String?> _write(
      Future<Response<dynamic>> Function(Dio dio) request) async {
    try {
      final dio = await ref.read(api.dioProvider.future);
      final resp = await request(dio);
      return api.writeResponseError(resp);
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// 新建经期区间记录：`POST /api/records {kind:'period', body, client_id}`。
  /// · 字段只做基础四项（B 段 9 字段/四动作/预警/月历不在本段）；
  /// · `client_id` 由**表单 State 的 initState 用 `api.newClientId()` 生成一次**
  ///   后传入，失败重试复用同值（7-C 教训，服务端 `find_by_client` 幂等
  ///   `main.py:1238-1240`），本方法绝不自行再生成；
  /// · 本地先拦 `clean_body` 的区间约束（`main.py:999-1010`：length 1–15、
  ///   cycle 15–60）与必填 start（`:1099-1100`），避免发给服务端英文数组型 422。
  /// 返回 null=成功。
  Future<String?> addEpisode({
    required String start,
    required int length,
    required int cycle,
    required String content,
    required String clientId,
  }) async {
    if (_disposed) return null;
    if (start.length != 10) return '请选择这次经期开始的日期';
    if (length < 1 || length > 15) return '经期需在 1–15 天之间';
    if (cycle < 15 || cycle > 60) return '周期需在 15–60 天之间';
    final body = <String, dynamic>{
      'start': start,
      'length': length,
      'cycle': cycle,
      if (content.trim().isNotEmpty) 'content': content.trim(),
      // 🔴 经期行不带 date；且**没有 end 键**（period.js 全文未见）。
    };
    final failure = await _write((dio) => dio.post('/api/records', data: {
          'kind': periodKind,
          'body': body,
          'client_id': clientId,
        }));
    if (failure != null) return failure;
    await load();
    return null;
  }

  /// 新建日记录：`POST /api/records {kind:'period', body:{date, content}, client_id}`。
  /// 🔴 日记录行**永不带 `start`**（`period.js:66` 强制删，否则会被当成一次经期）；
  /// `clean_body` 要求 start/date 二者必有其一（`main.py:1099-1100`）。
  /// 返回 null=成功。
  Future<String?> addDay({
    required String date,
    required String content,
    required String clientId,
  }) async {
    if (_disposed) return null;
    if (date.length != 10) return '请选择日期';
    final body = <String, dynamic>{
      'date': date,
      if (content.trim().isNotEmpty) 'content': content.trim(),
    };
    final failure = await _write((dio) => dio.post('/api/records', data: {
          'kind': periodKind,
          'body': body,
          'client_id': clientId,
        }));
    if (failure != null) return failure;
    await load();
    return null;
  }

  /// 编辑（两种形状通用）：`PUT /api/records/{rid} {kind:'period', body}`。
  /// 🔴 **回填铁律**：以服务端原始 body 为底 `mergeRecordBody` 逐键复制，
  /// 只盖表单改动键；`clean_body` 的 `previous` 未参与合并（`:925`），
  /// 只传改动字段会抹掉 `flow/symptoms/…` 等原有键。
  /// 表单只改各自形状的字段，不会把 `start`/`date` 互换（形状不变）。
  /// 返回 null=成功。
  Future<String?> edit(
      TogetherRecord record, Map<String, dynamic> changes) async {
    if (_disposed) return null;
    final failure = await _write((dio) => dio.put(
          '/api/records/${record.id}',
          data: {
            'kind': periodKind,
            'body': mergeRecordBody(record.body, changes),
          },
        ));
    if (failure != null) return failure;
    await load();
    return null;
  }

  /// 删除（软删）：`DELETE /api/records/{rid}` → `main.py:1424-1428`
  /// → `delete_period_record :1263-1267`（零作者校验，谁都能删）。
  /// 删除后进个人角落 · 回收站（`trashKinds` 含 period），回收站不自动删除、可随时恢复。
  /// 🔴 D6：本层**不加** `author == uid` 判断。返回 null=成功。
  Future<String?> delete(String rid) async {
    if (_disposed) return null;
    final failure =
        await _write((dio) => dio.delete('/api/records/$rid'));
    if (failure != null) return failure;
    state = state.copyWith(
        records: state.records.where((r) => r.id != rid).toList());
    await load();
    return null;
  }

  // ── 段 8-B：统一写执行器（四动作 / 日记录 / 经期表单 / 删整次） ──────

  /// 引擎入参形状（`{id, author, body}`）。页面与弹层共用同一份快照，
  /// 保证 `periodData` / `planSaveDay` 看到的数据完全同源。
  List<PeriodRow> get periodRows => <PeriodRow>[
        for (final r in state.records)
          PeriodRow(id: r.id, author: r.author, body: r.body),
      ];

  /// 执行 [PeriodWritePlan]（由 `period_actions.dart` 的纯函数产出）。
  ///
  /// 🔴 7-C 返修纪律：所有写都经 [_write] 显式调 `api.writeResponseError`
  /// 判 4xx（服务端 `detail` 原文透传）；失败返回错误串（页面发 error tone、
  /// **不发成功通知、不 pop、输入保留、不自动重试**）。
  /// [plan.refresh] 为 true 时按 Web `await refresh()` 重拉全量。
  Future<String?> executePlan(PeriodWritePlan plan) async {
    if (_disposed) return null;
    if (!plan.hasWrite) return null; // 只提示不写（幂等 / 不在经期）
    final kind = plan.kind!;
    // 🔴 路径映射：Web 的 `post/put/del('/records…')`（period.js:67/:68/:84/
    // :98/:107/:827/:828）由 app.js 的 api() 统一加 `/api` 前缀；App 的 Dio
    // baseUrl 不含该前缀（8-A 通用读写一律 `/api/records`），故在此补一层。
    // 计划对象保留 Web 原路径以便与夹具逐项对拍，实际请求走 `/api/...`。
    final path = '/api${plan.path!}';
    final failure = await _write((dio) {
      switch (kind) {
        case PeriodWriteKind.post:
          return dio.post(path, data: <String, dynamic>{
            'kind': periodKind,
            'body': plan.body,
            'client_id': plan.clientId,
          });
        case PeriodWriteKind.put:
          return dio.put(path, data: <String, dynamic>{
            'kind': periodKind,
            'body': plan.body,
            // 🔴 PUT 不带 client_id（periodForm :827 / periodSaveDay :67）。
          });
        case PeriodWriteKind.delete:
          return dio.delete(path);
      }
    });
    if (failure != null) return failure;
    if (plan.refresh) await load();
    return null;
  }

  /// `app.js:2507-2510` `period-del-episode`：该次月经的全部碎片逐个 DELETE，
  /// 全部成功后才 `refresh()`；中途失败立即返回原文、不发成功通知。
  Future<String?> deleteEpisode(List<String> ids) async {
    if (_disposed) return null;
    for (final rid in ids) {
      final failure =
          await _write((dio) => dio.delete('/api/records/$rid'));
      if (failure != null) return failure;
    }
    if (ids.isNotEmpty) await load();
    return null;
  }
}

final periodControllerProvider =
    NotifierProvider<PeriodController, PeriodState>(PeriodController.new);
