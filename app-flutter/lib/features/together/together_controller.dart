/// 「我们」页状态与控制器（条目 6 · 段 A）。
/// · 一次全量 GET /api/records?kind=mood,note,wish,anniversary&limit=1000
///   （Web refreshData 同款，app.js:270；各工具页/ hub 共用同一份 state，
///   写后整列表 reload 保持一致）；
/// · 写操作：POST/PUT/DELETE /api/records；PUT 回填铁律（mergeRecordBody，
///   服务端 clean_body 不合并旧 body）；
/// · 结果提示由页面层走 chatToastProvider（全局 ChatToastHost 顶部通知）；
/// · 请求代次防竞态（时光/相册同款）；SSE other 且 tab 激活 → reset 重拉。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/together/together_data.dart';

/// 段 A/C 拉取的 kind 集（纪念日只读——管理页 B 段建；问答/打卡段 C）
const togetherKinds = 'mood,note,wish,anniversary,question,habit';

class TogetherState {
  const TogetherState({
    this.records = const [],
    this.loading = false,
    this.skeleton = false,
    this.error,
  });
  final List<TogetherRecord> records;
  final bool loading;
  final bool skeleton; // 首屏骨架（仅首次拉取）
  final String? error;

  TogetherState copyWith({
    List<TogetherRecord>? records,
    bool? loading,
    bool? skeleton,
    String? error,
  }) =>
      TogetherState(
        records: records ?? this.records,
        loading: loading ?? this.loading,
        skeleton: skeleton ?? this.skeleton,
        error: error,
      );
}

class TogetherController extends Notifier<TogetherState> {
  bool _disposed = false;
  bool _loaded = false;
  bool _skeletonSeen = false;
  int _reqSeq = 0;

  @override
  TogetherState build() {
    ref.onDispose(() => _disposed = true);
    return const TogetherState();
  }

  Future<void> bootstrap() async {
    if (!_loaded) await load();
  }

  /// 全量拉取（写后/SSE 重拉同一路径）
  Future<void> load() async {
    if (_disposed) return;
    final seq = ++_reqSeq;
    state = state.copyWith(loading: true, error: null, skeleton: !_skeletonSeen);
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.get('/api/records', queryParameters: {
        'kind': togetherKinds,
        'limit': 1000,
      });
      if (_disposed || seq != _reqSeq) return; // 旧响应失效
      state = state.copyWith(records: parseTogetherRecords(r.data));
      _skeletonSeen = true;
      state = state.copyWith(loading: false, skeleton: false);
    } catch (e) {
      _skeletonSeen = true;
      if (!_disposed && seq == _reqSeq) {
        state = state.copyWith(loading: false, skeleton: false,
            error: api.errorDetail(e));
      }
    }
    _loaded = true;
  }

  /// SSE other（tab 激活时由页面调用）：reset 重拉
  Future<void> resetOnSseOther() async {
    if (_loaded) await load();
  }

  /// 按 kind 过滤（created 倒序）
  List<TogetherRecord> recordsOf(String kind) =>
      sortByCreatedDesc(state.records.where((r) => r.kind == kind).toList());

  /// 心情手记（date 倒序）
  List<TogetherRecord> moods() =>
      sortMoodsByDateDesc(recordsOf('mood'));

  /// 新增：POST /api/records {kind, body, client_id}（client_id 幂等）。
  /// 成功后整列表 reload。返回 null=成功。
  Future<String?> add(String kind, Map<String, dynamic> body) async {
    if (_disposed) return null;
    try {
      final dio = await ref.read(api.dioProvider.future);
      await dio.post('/api/records', data: {
        'kind': kind,
        'body': body,
        'client_id': DateTime.now().microsecondsSinceEpoch.toString(),
      });
      await load();
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// 编辑：PUT /api/records/{rid} {kind, body: mergeRecordBody(original, changes)}
  /// 回填铁律：原始 body（页面打开编辑时持有的那份）逐键复制 + 只盖 changes。
  /// 成功后整列表 reload。返回 null=成功。
  Future<String?> edit(String rid, String kind, Map<String, dynamic> original,
      Map<String, dynamic> changes) async {
    if (_disposed) return null;
    try {
      final dio = await ref.read(api.dioProvider.future);
      await dio.put('/api/records/$rid', data: {
        'kind': kind,
        'body': mergeRecordBody(original, changes),
      });
      await load();
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// wish done 勾选（app.js:2536 toggle-wish 同口径：PUT 全量 body 只翻转 done）。
  /// 返回 null=成功。
  Future<String?> toggleWishDone(TogetherRecord record) async {
    final done = record.body['done'] == true;
    return edit(record.id, 'wish', record.body, {'done': !done});
  }

  /// 删除（服务端软删，回收站 30 天）。仅本人（非本人服务端 403 → 错误文案）。
  /// 成功后整列表 reload。返回 null=成功。
  Future<String?> delete(String rid) async {
    if (_disposed) return null;
    try {
      final dio = await ref.read(api.dioProvider.future);
      await dio.delete('/api/records/$rid');
      await load();
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  // ── 段 C · 子资源操作（不走记录 PUT，口径与编辑分开）──────────────

  /// 问答回答：POST /api/records/{rid}/answer {content 1..5000}。
  /// 服务端 answers PK(record_id,author) + ON CONFLICT DO UPDATE ——
  /// 每人一条答案、重复提交=覆盖自己的（可修改）。内容可见性由服务端
  /// 序列化控制（双方都答了才互相可见）。返回 null=成功。
  Future<String?> answer(String rid, String content) async {
    if (_disposed) return null;
    try {
      final dio = await ref.read(api.dioProvider.future);
      await dio.post('/api/records/$rid/answer', data: {'content': content});
      await load(); // 重拉拿最新 answers/answer_count（揭晓态以服务端为准）
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// 打卡：POST /api/records/{rid}/check（无 body）。
  /// 服务端 checks PK(record_id,author,day) + INSERT OR IGNORE ——
  /// 同一天重复打卡幂等（不产生脏数据）；day 用服务端 space 时区。
  /// 返回 null=成功。
  Future<String?> checkHabit(String rid) async {
    if (_disposed) return null;
    try {
      final dio = await ref.read(api.dioProvider.future);
      await dio.post('/api/records/$rid/check');
      await load(); // 重拉拿最新 checks（打卡状态以后端为准，不回弹）
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }
}

final togetherControllerProvider =
    NotifierProvider<TogetherController, TogetherState>(TogetherController.new);
