/// 「个人角落」段 7-A / 7-B 数据层（Riverpod Notifier）。
///
/// · 🔴 显式 kind 拉取：`GET /api/records?kind=diary,draft,surprise`（顶层常量
///   [personalKinds]，一次拉三类、客户端按 r.kind 分流各 tab）。
///   服务端不带 kind 时隐式排除 diary/draft/surprise（main.py:1156），
///   **禁止不带 kind**；防「新增 tab 漏扩 kinds 串」事故重演。
/// · 回收站：`GET /api/records?trash=true&kind=<Web 全 kind 串>`（[trashKinds]
///   = app.js:468 `Object.keys(kindLabel).join(',')`，含私密三类）。服务端
///   trash 分支强制 `author=自己 AND deleted IS NOT NULL`（main.py:1150-1152），
///   客户端仍二次按 author 过滤，绝不混入他人条目。
/// · 跨账号隐私由服务端保证（db.visible 对 PRIVATE 只放作者，db.py:377；
///   serialize 对非作者私密记录 404）；**揭示前 surprise 绝不写进共享缓存**
///   （timeline/together 控制器），到点由 worker.py:225-235 把 kind 改成 post，
///   客户端只按服务端结果在时光页呈现，不自行缓存泄露路径。
/// · 写方法 POST/PUT/DELETE 由 dioProvider 自动带 `X-Love-Space: 1`；
///   PUT 全量 body，一律 mergeRecordBody 回填铁律（以原 body 为底只盖改动键）。
///   🔴 根因实读：main.py:925 `clean_body(..., previous=None)` 的 previous
///   参数在函数体内完全未使用 → 服务端 PUT **不 merge**。
/// · 发布草稿：PUT 改 kind（main.py:1400 仅 draft→post/diary/surprise），
///   surprise 需 body.publish_at 为未来时间戳（main.py:1127，否则 422）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/chat/chat_repository.dart' show newChatClientId;
import '../../core/together/together_data.dart';
import '../auth/auth_state.dart';
import '../timeline/timeline_controller.dart' show timelineControllerProvider;

/// 7-A/7-B 拉取的 kind 集（**显式**，新增 tab 必须同步扩这里 + 更新
/// personal_a_test / personal_b_test 的 kind 串断言）。分多次各带单 kind 也可，
/// 但绝不允许不带 kind；7-B 增补 surprise，回收站另走 [trashKinds]。
const personalKinds = 'diary,draft,surprise';

/// 回收站 kind 串：逐字对齐 Web `app.js:468` 的
/// `Object.keys(kindLabel).join(',')`（kindLabel 见 app.js:92），
/// **含 diary/draft/surprise 三类私密**（主人 2026-11-14 12:10「甲·对齐 Web」定案）。
/// 服务端 trash 分支强制 author=自己，客户端仍二次过滤。
const trashKinds = 'post,diary,draft,surprise,anniversary,wish,personal_wish,'
    'mood,note,question,habit,chat,album,quest,ledger,period,music';

/// 当前登录用户 id（服务端 author 过滤 + 客户端二次过滤用）。
/// 通过 watch(authProvider) 让 bootstrap 写入 me 后自动重算。
final personalCurrentUserProvider = Provider<String>((ref) {
  ref.watch(authProvider);
  return ref.watch(authProvider.notifier).me?.user.id ?? '';
});

class PersonalState {
  const PersonalState({
    this.records = const [],
    this.trash = const [],
    this.loading = false,
    this.trashLoading = false,
    this.error,
  });

  /// 已按 author 过滤、且只含 diary/draft/surprise 三类
  final List<TogetherRecord> records;
  /// 回收站（trash=true 拉取，含私密三类；已按 author 过滤）
  final List<TogetherRecord> trash;
  final bool loading;
  final bool trashLoading;
  final String? error;

  PersonalState copyWith({
    List<TogetherRecord>? records,
    List<TogetherRecord>? trash,
    bool? loading,
    bool? trashLoading,
    String? error,
  }) =>
      PersonalState(
        records: records ?? this.records,
        trash: trash ?? this.trash,
        loading: loading ?? this.loading,
        trashLoading: trashLoading ?? this.trashLoading,
        error: error,
      );
}

class PersonalController extends Notifier<PersonalState> {
  bool _disposed = false;
  bool _loaded = false;
  int _reqSeq = 0;
  int _trashSeq = 0; // 独立序号：load 与 loadTrash 可安全地先后/并发，互不误杀

  /// 🔴 P0-1 换号隐私串号根修：绑定拉取这份私密数据的用户 id。
  /// 正确对照 timeline_controller.dart:84-92 的同款 `_boundUserId` 换号重置。
  String? _boundUserId;

  @override
  PersonalState build() {
    final uid = ref.watch(personalCurrentUserProvider);
    final previousUid = _boundUserId;
    final userChanged = previousUid != null && previousUid != uid;
    // 🔴 Riverpod：build 内 watch 的依赖变化时本 Notifier 会重新 build，
    // 旧的 onDispose 回调先触发。必须在这里复位，否则 _disposed 永久为 true，
    // 后续所有写方法（编辑/发布/删除）静默 no-op。
    _disposed = false;
    _loaded = false;
    _boundUserId = uid;
    ref.onDispose(() => _disposed = true);
    // ① watch：uid 变化即触发本 Notifier 依赖更新（state 归零）；
    //    listen：显式清态 + 重拉，覆盖「页面未重建、bootstrap 不再执行」的换号路径。
    ref.listen(personalCurrentUserProvider, (prev, next) {
      if (prev == next) return;
      _boundUserId = next;
      _loaded = false;
      _reqSeq++; // 在途的旧账号请求响应一律作废
      _trashSeq++;
      // 微任务里改 state/重拉：避免在 provider 通知/ widget build 期间改 provider
      Future.microtask(() async {
        if (_disposed) return;
        state = const PersonalState();
        await load();
        if (_disposed) return;
        await loadTrash();
      });
    });
    if (userChanged) {
      // 依赖重建路径：旧 listener 可能已被 Riverpod 移除，这里兜底重拉
      _reqSeq++;
      _trashSeq++;
      Future.microtask(() async {
        if (_disposed) return;
        await load();
        if (_disposed) return;
        await loadTrash();
      });
    }
    return const PersonalState();
  }

  /// 进入页面初始化：换号重置（状态清空 + 重拉）；首次进页拉首屏。
  Future<void> bootstrap() async {
    final uid = ref.read(personalCurrentUserProvider);
    if (_boundUserId != uid) {
      _boundUserId = uid;
      _loaded = false;
      _reqSeq++;
      _trashSeq++;
      if (!_disposed) state = const PersonalState();
    }
    if (!_loaded) {
      await load();
      if (_disposed) return;
      await loadTrash();
    }
  }

  /// 当前用户 id：优先读认证缓存；冷启动/测试竞态（me 尚未落定）时直接
  /// 拉一次 /api/me，保证 author 加固参数与客户端过滤不会漏。
  Future<String> _currentUserId() async {
    final cached = ref.read(personalCurrentUserProvider);
    if (cached.isNotEmpty) return cached;
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.get('/api/me');
      final j = r.data;
      if (j is Map) {
        final u = j['user'];
        if (u is Map) return (u['id'] ?? '').toString();
      }
    } catch (_) {
      // 取不到就退化为不带 author（服务端仍按登录态保证隐私）
    }
    return '';
  }

  /// 显式 kind 全量拉取（写后/SSE 重拉同一路径）。
  Future<void> load() async {
    if (_disposed) return;
    final seq = ++_reqSeq;
    state = state.copyWith(loading: true, error: null);
    try {
      final uid = await _currentUserId();
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.get('/api/records', queryParameters: {
        'kind': personalKinds,
        'limit': 1000,
        if (uid.isNotEmpty) 'author': uid,
      });
      if (_disposed || seq != _reqSeq) return; // 旧响应失效
      // 🔴 P2-4 / P0-1 ③：uid 为空 **fail-closed**，绝不放行全部记录
      // （服务端虽由 db.visible 兜住，客户端也必须按作者过滤，不依赖兜底）。
      final all = uid.isEmpty
          ? <TogetherRecord>[]
          : parseTogetherRecords(r.data)
              .where((x) => const ['diary', 'draft', 'surprise']
                  .contains(x.kind))
              .where((x) => x.author == uid)
              .toList();
      state = state.copyWith(records: all, loading: false);
    } catch (e) {
      if (!_disposed && seq == _reqSeq) {
        state = state.copyWith(loading: false, error: api.errorDetail(e));
      }
    }
    _loaded = true;
  }

  /// 回收站（段 7-B）：`GET /api/records?trash=true&kind=<Web 全 kind 串>`。
  /// 🔴 服务端 trash 分支已强制 `author=自己 AND deleted IS NOT NULL`
  /// （main.py:1150-1152），客户端仍带 author 加固 + 二次按 author 过滤
  /// （fail-closed），绝不混入他人条目；period 分库由服务端合并，客户端统一解析。
  Future<void> loadTrash() async {
    if (_disposed) return;
    final seq = ++_trashSeq;
    state = state.copyWith(trashLoading: true, error: null);
    try {
      final uid = await _currentUserId();
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.get('/api/records', queryParameters: {
        'trash': true,
        'kind': trashKinds,
        'limit': 1000,
        if (uid.isNotEmpty) 'author': uid,
      });
      if (_disposed || seq != _reqSeq) return;
      final all = uid.isEmpty
          ? <TogetherRecord>[]
          : parseTogetherRecords(r.data)
              .where((x) => x.author == uid)
              .toList();
      state = state.copyWith(trash: all, trashLoading: false);
    } catch (e) {
      if (!_disposed && seq == _reqSeq) {
        state = state.copyWith(
            trashLoading: false, error: api.errorDetail(e));
      }
    }
  }

  /// 🔴 P0-1 ③：渲染前按**当前** uid 二次过滤（缓存里的旧账号记录一律不渲染）。
  /// uid 为空（登录态未落定/已登出）→ **fail-closed 返回空列表**。
  List<TogetherRecord> _owned(String kind) {
    final uid = ref.read(personalCurrentUserProvider);
    if (uid.isEmpty) return const <TogetherRecord>[];
    return sortByCreatedDesc(state.records
        .where((r) => r.kind == kind && r.author == uid)
        .toList());
  }

  /// 私密日记（created 倒序）
  List<TogetherRecord> diaries() => _owned('diary');

  /// 草稿箱（created 倒序）
  List<TogetherRecord> drafts() => _owned('draft');

  /// 定时惊喜（created 倒序）。揭示后服务端 worker.py:225-235 会把记录
  /// 改成 kind=post，那时它自然不再出现在这里；客户端只按服务端结果呈现。
  List<TogetherRecord> surprises() => _owned('surprise');

  /// 新建定时惊喜：POST {kind:'surprise', body, client_id}。
  /// body.publish_at 为 epoch 秒数值（main.py:1127：now < t < now+50 年，
  /// 否则 422「请选择未来的公开时间」，原文由 api.errorDetail 透传给顶部通知）。
  /// 本地先校验，服务端 422 也照样把原文返回给 UI，绝不静默失败。
  /// 成功后整列表 reload。返回 null=成功。
  Future<String?> addSurprise(String content, DateTime publishAt) async {
    if (_disposed) return null;
    final text = content.trim();
    if (text.isEmpty) return '写点什么吧';
    final t = publishAt.millisecondsSinceEpoch / 1000;
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    if (t <= now || t >= now + 50 * 366 * 86400) {
      return '请选择未来的公开时间';
    }
    try {
      final dio = await ref.read(api.dioProvider.future);
      await dio.post('/api/records', data: {
        'kind': 'surprise',
        'body': {
          'content': text,
          'date': todayDateStr(),
          'media': <String>[],
          'publish_at': t,
        },
        'client_id': newChatClientId(),
      });
      await load();
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// 编辑定时惊喜（含改期）：PUT 全量 body（**回填铁律**，原始 body 逐键复制 +
  /// 只盖 content / publish_at）；kind 保持 surprise，否则服务端会 pop 掉
  /// publish_at（main.py:1132）。改期同样校验未来窗口。返回 null=成功。
  Future<String?> editSurprise(
      TogetherRecord record, String content, DateTime publishAt) async {
    if (_disposed) return null;
    final text = content.trim();
    if (text.isEmpty) return '写点什么吧';
    final t = publishAt.millisecondsSinceEpoch / 1000;
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    if (t <= now || t >= now + 50 * 366 * 86400) {
      return '请选择未来的公开时间';
    }
    try {
      final dio = await ref.read(api.dioProvider.future);
      await dio.put('/api/records/${record.id}', data: {
        'kind': 'surprise',
        'body': mergeRecordBody(record.body, {
          'content': text,
          'publish_at': t,
        }),
      });
      await load();
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// 回收站恢复（段 7-B）：POST /api/records/{rid}/restore（main.py:1443）。
  /// period 分库由服务端 `period.get(rid, include_deleted=True)` 分流，
  /// 客户端统一调用即可；成功后本地移除该条 + 重拉主列表与回收站。
  /// 返回 null=成功。
  Future<String?> restore(String rid, {String? kind}) async {
    if (_disposed) return null;
    try {
      final dio = await ref.read(api.dioProvider.future);
      await dio.post('/api/records/$rid/restore');
      state = state.copyWith(
          trash: state.trash.where((r) => r.id != rid).toList());
      await load();
      if (_disposed) return null;
      await loadTrash();
      // 恢复一条时光（post）后必须显式重拉时光列表（同 publishDraft 的 post
      // 分支：timeline 的 SSE 监听有 active 门控，IndexedStack 切回不触发 load）。
      if (kind == 'post') {
        await ref
            .read(timelineControllerProvider.notifier)
            .resetAfterPublish();
      }
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// 新建私密日记：POST {kind:'diary', body, client_id}。
  /// content 必填（main.py:1107 的必填集合是 {post,diary,surprise,note,chat}，
  /// **不含 draft**——草稿空内容服务端允许，本方法只管 diary，不给草稿加校验）；
  /// 日期取今天、media 空数组（Web composer 同形状）。
  /// 成功后整列表 reload。返回 null=成功。
  Future<String?> addDiary(String content) async {
    if (_disposed) return null;
    final text = content.trim();
    if (text.isEmpty) return '写点什么吧';
    try {
      final dio = await ref.read(api.dioProvider.future);
      await dio.post('/api/records', data: {
        'kind': 'diary',
        'body': {
          'content': text,
          'date': todayDateStr(),
          'media': <String>[],
        },
        'client_id': newChatClientId(),
      });
      await load();
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// 编辑私密日记：PUT 全量 body（**回填铁律**，原始 body 逐键复制 + 只盖 content）。
  /// 成功后整列表 reload。返回 null=成功。
  Future<String?> editDiary(TogetherRecord record, String content) async {
    if (_disposed) return null;
    final text = content.trim();
    if (text.isEmpty) return '写点什么吧';
    try {
      final dio = await ref.read(api.dioProvider.future);
      await dio.put('/api/records/${record.id}', data: {
        'kind': 'diary',
        'body': mergeRecordBody(record.body, {'content': text}),
      });
      await load();
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// 发布草稿：PUT 改 kind（post→时光 / diary→日记 / surprise→定时惊喜）。
  /// · body 必须 merge 原 body（回填铁律）；surprise 额外带未来 publish_at（秒）。
  /// · 成功后本地移除草稿；diary 目标移入日记列表（服务端下次 load 为准）。
  /// 返回 null=成功。
  Future<String?> publishDraft(
    TogetherRecord draft,
    String targetKind, {
    DateTime? publishAt,
  }) async {
    if (_disposed) return null;
    if (!const {'post', 'diary', 'surprise'}.contains(targetKind)) {
      return '不支持的发布类型';
    }
    if (targetKind == 'surprise' &&
        (publishAt == null || !publishAt.isAfter(DateTime.now()))) {
      return '请选择未来的公开时间';
    }
    final body = mergeRecordBody(draft.body, {
      if (targetKind == 'surprise')
        'publish_at': publishAt!.millisecondsSinceEpoch / 1000,
    }); // 回填铁律：main.py:925 PUT 服务端不 merge，原 body 必须逐键带回
    try {
      final dio = await ref.read(api.dioProvider.future);
      await dio.put('/api/records/${draft.id}', data: {
        'kind': targetKind,
        'body': body,
      });
      final next = state.records.where((r) => r.id != draft.id).toList();
      if (targetKind == 'diary') {
        next.add(TogetherRecord(
          id: draft.id,
          kind: 'diary',
          body: body,
          author: draft.author,
          created: draft.created,
          answers: draft.answers,
          answerCount: draft.answerCount,
          checks: draft.checks,
          media: draft.media,
          likeCount: draft.likeCount,
          commentCount: draft.commentCount,
        ));
      }
      state = state.copyWith(records: next);
      if (targetKind == 'post') {
        // 🔴 P1-3：draft→post 服务端已置 published=now()（main.py:1408），
        // 但时光 tab 的 SSE 监听有 widget.active 门控、IndexedStack 切回不触发
        // load → 必须显式重拉（与 composer_sheet.dart:527 同款）。
        // Web navigate() 到 timeline 也会显式 loadTimeline(true)（app.js:427）。
        await ref
            .read(timelineControllerProvider.notifier)
            .resetAfterPublish();
      }
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// 删除（DELETE 服务端软删，main.py:1424）。删除后进回收站（标准口径：
  /// 「删除后会进入回收站，30 天内可以恢复。」），成功后本地移除并重拉回收站。
  /// 返回 null=成功。
  Future<String?> delete(String rid) async {
    if (_disposed) return null;
    try {
      final dio = await ref.read(api.dioProvider.future);
      await dio.delete('/api/records/$rid');
      state = state.copyWith(
          records: state.records.where((r) => r.id != rid).toList());
      await loadTrash();
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }
}

final personalControllerProvider =
    NotifierProvider<PersonalController, PersonalState>(PersonalController.new);
