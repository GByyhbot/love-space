/// 时光页状态与控制器（条目 4 · 段一骨架 + 段二 B 互动）。
/// 状态挂 keepAlive Notifier：切 tab（shell IndexedStack 常驻）与短时离开
/// 不丢列表/筛选；首屏骨架只在首次拉取时出现（对齐 Web timelineSkeleton）。
/// SSE other 且时光 tab 激活 → resetOnSseOther（对齐 Web refresh）。
/// 段二 B：点赞/评论/删评论只替换本卡（_patchRecord），不整列表重建、
/// 不跳位；失败回滚到点前状态并走顶部通知；SSE 重拉按 cid 去重合并，
/// 本端即时插入与服务端回显恒为一条。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/chat/chat_repository.dart' show newChatClientId;
import '../../core/timeline/timeline_data.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;

class TimelineState {
  const TimelineState({
    this.posts = const [],
    this.loading = false,
    this.hasMore = true,
    this.skeleton = false,
    this.filter = const TimelineFilter(),
    this.error,
  });
  final List<api.Record> posts;
  final bool loading;
  final bool hasMore;
  final bool skeleton; // 首屏骨架（仅首次拉取）
  final TimelineFilter filter;
  final String? error;

  TimelineState copyWith({
    List<api.Record>? posts,
    bool? loading,
    bool? hasMore,
    bool? skeleton,
    TimelineFilter? filter,
    String? error,
  }) =>
      TimelineState(
        posts: posts ?? this.posts,
        loading: loading ?? this.loading,
        hasMore: hasMore ?? this.hasMore,
        skeleton: skeleton ?? this.skeleton,
        filter: filter ?? this.filter,
        error: error,
      );
}

class TimelineController extends Notifier<TimelineState> {
  bool _disposed = false;
  bool _loaded = false;
  bool _skeletonSeen = false;
  String? _boundUserId;
  (double, String)? _cursor;

  /// reset 请求代次：快速连续改筛选时旧请求仍在途，只有最新一代允许写 state。
  int _reqSeq = 0;

  /// composer 发布幂等：首次生成后随会话保留（失败重试复用，成功清空——
  /// 持久化暂存归段二）
  String? _activePostClientId;

  /// 草稿保存幂等：与发布独立，成功清空（改内容再存走新 id 新建草稿，
  /// 避免同 client_id 返回旧草稿不更新）
  String? _activeDraftClientId;

  /// 段二 B：本端即时插入的评论（cid → 评论对象，含 record_id），
  /// SSE reset 重拉时按 cid 去重补回（服务端快照可能早于本端提交）。
  final Map<String, Map<String, dynamic>> _localComments = {};

  /// 段二 B：乐观点赞在途的卡（rid → 期望 likes），POST 完成即清。
  /// 防止 SSE 重拉在途把乐观态短暂冲回。
  final Map<String, List<String>> _optimisticLikes = {};

  @override
  TimelineState build() {
    ref.onDispose(() => _disposed = true);
    return const TimelineState();
  }

  /// 进入页面初始化：换号重置；首次进页拉首屏
  Future<void> bootstrap(String myId) async {
    if (_boundUserId != myId) {
      _boundUserId = myId;
      _loaded = false;
      _cursor = null;
      _activePostClientId = null;
      if (!_disposed) state = const TimelineState();
    }
    if (!_loaded) await load(reset: true);
  }

  /// 拉取（reset=true 首屏/筛选变更/发布后重置；否则游标追加）
  Future<void> load({required bool reset}) async {
    if (_disposed) return;
    // 上翻（reset=false）仍需防重入；首屏/筛选变更（reset=true）**允许并发**：
    // 旧请求在途时若直接 return，第二次筛选会被静默丢弃，页面停在上一次
    // 筛选结果（QA4 防抖竞态用例抓到的真实缺陷）。改由 _reqSeq 让旧响应失效。
    if (!reset && (state.loading || !state.hasMore)) return;
    final seq = ++_reqSeq;
    final filter = state.filter; // 捕获本次筛选，避免 await 期间被下一次改掉
    state = state.copyWith(loading: true, error: null,
        skeleton: reset && !_skeletonSeen);
    try {
      final dio = await ref.read(api.dioProvider.future);
      final cursor = reset ? null : _cursor;
      final r = await dio.get('/api/records',
          queryParameters: buildTimelineQuery(filter, cursor: cursor));
      // 已被更新的筛选覆盖：旧响应不得写 posts / cursor / loading
      if (_disposed || seq != _reqSeq) return;
      final fetched = parsePostRecords(r.data);
      final hasMore = fetched.length > timelinePageSize;
      final page = fetched.take(timelinePageSize).toList();
      if (reset) {
        // SSE other 重拉 / 发布后重拉：以服务端为底，按 cid 去重合并
        // 本端即时插入的评论（服务端快照可能早于本端 POST），并保留
        // 在途的乐观点赞态，避免刷出重复卡或点赞闪烁。
        final merged = <api.Record>[];
        for (final rec in page) {
          final locals = _localComments.values
              .where((c) => c['record_id']?.toString() == rec.id)
              .toList();
          final comments = locals.isEmpty
              ? rec.comments
              : mergeCommentsByCid(rec.comments, locals);
          final likes = _optimisticLikes[rec.id] ?? rec.likes;
          // 服务端已回显该评论 → 本地兜底记录功成身退（防无限留存）
          final serverCids = {
            for (final c in rec.comments) c['id']?.toString()
          };
          _localComments.removeWhere((cid, _) => serverCids.contains(cid));
          merged.add(identical(comments, rec.comments) &&
                  identical(likes, rec.likes)
              ? rec
              : _rebuildRecord(rec, likes: likes, comments: comments));
        }
        if (!_disposed) {
          state = state.copyWith(posts: merged, hasMore: hasMore);
        }
      } else {
        final (_, merged) =
            appendTimelinePage(state.posts, page, (rec) => rec.id);
        if (!_disposed) state = state.copyWith(posts: merged, hasMore: hasMore);
      }
      final last = page.isNotEmpty ? page.last : null;
      _cursor = last != null ? (last.created, last.id) : null;
      _skeletonSeen = true;
      if (!_disposed) state = state.copyWith(loading: false, skeleton: false);
    } catch (e) {
      _skeletonSeen = true;
      // 旧请求的失败也不得把 error 盖到最新一次筛选的界面上
      if (!_disposed && seq == _reqSeq) {
        state = state.copyWith(loading: false, skeleton: false,
            error: api.errorDetail(e));
      }
    }
    _loaded = true;
  }

  /// 筛选变更：reset 重拉
  Future<void> setFilter(TimelineFilter filter) async {
    if (!_disposed) state = state.copyWith(filter: filter);
    await load(reset: true);
  }

  Future<void> clearFilters() => setFilter(const TimelineFilter());

  /// 发布后重置回首屏（对齐 Web refresh）
  Future<void> resetAfterPublish() async {
    _loaded = true;
    await load(reset: true);
  }

  /// SSE other（时光 tab 激活时由页面调用）：reset 重拉
  Future<void> resetOnSseOther() async {
    if (_loaded) await load(reset: true);
  }

  // ── 段二 B · 互动（本卡原地更新 / 失败回滚 / SSE 去重）────────────

  /// 用同一 id 重建一条 Record（仅覆盖 likes/comments，其余字段原样保留）
  api.Record _rebuildRecord(api.Record old,
          {List<String>? likes, List<Map<String, dynamic>>? comments}) =>
      api.Record(
        id: old.id,
        kind: old.kind,
        author: old.author,
        body: old.body,
        created: old.created,
        clientId: old.clientId,
        likes: likes ?? old.likes,
        comments: comments ?? old.comments,
        media: old.media,
      );

  /// 只替换列表中对应 rid 的那一张卡：其余元素对象引用不变、顺序不变、
  /// 游标与 hasMore 不变 → ListView 视口位置不动、不闪烁（B3）。
  void _patchRecord(String rid,
      {List<String>? likes, List<Map<String, dynamic>>? comments}) {
    if (_disposed) return;
    final idx = state.posts.indexWhere((r) => r.id == rid);
    if (idx < 0) return;
    final next = List<api.Record>.of(state.posts);
    next[idx] = _rebuildRecord(next[idx], likes: likes, comments: comments);
    state = state.copyWith(posts: next);
  }

  void _toast(String msg, ChatToastTone tone) =>
      ref.read(chatToastProvider.notifier).show(msg, tone: tone);

  /// B1 点赞 toggle：本地先翻转（服务端只回 {ok:true} 不回状态），
  /// POST 失败回滚到点前状态并给顶部通知，绝不静默失败。
  Future<void> toggleLike(String rid, String myId) async {
    if (_disposed) return;
    final idx = state.posts.indexWhere((r) => r.id == rid);
    if (idx < 0) return;
    final before = List<String>.of(state.posts[idx].likes); // 点前快照
    final optimistic = toggleLocalLikes(before, myId);
    _optimisticLikes[rid] = optimistic;
    _patchRecord(rid, likes: optimistic);
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.post('/api/records/$rid/like');
      if ((r.statusCode ?? 500) >= 400) {
        throw Exception('HTTP ${r.statusCode}');
      }
      _optimisticLikes.remove(rid); // 服务端已落库，后续重拉自然对齐
    } catch (e) {
      _optimisticLikes.remove(rid);
      _patchRecord(rid, likes: before); // 回滚到点前状态
      _toast('点赞失败，已恢复', ChatToastTone.error);
    }
  }

  /// B2 发表评论：POST 返回真实 cid → 本卡即时插入（卡片内联列表上屏）。
  /// 失败给顶部通知、不插入。返回是否成功（供 BottomSheet 收起用）。
  Future<bool> addComment(String rid, String content, String myId) async {
    final text = content.trim();
    if (text.isEmpty || text.length > 5000) {
      _toast('评论内容需在 1–5000 字之间', ChatToastTone.warning);
      return false;
    }
    if (_disposed) return false;
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.post('/api/records/$rid/comments',
          data: {'content': text});
      if ((r.statusCode ?? 500) >= 400) {
        throw Exception('HTTP ${r.statusCode}');
      }
      final cid = ((r.data as Map?) ?? const {})['id']?.toString() ?? '';
      if (cid.isEmpty) throw Exception('服务端未返回评论 id');
      final comment = <String, dynamic>{
        'id': cid,
        'record_id': rid,
        'author': myId,
        'content': text,
        'created': DateTime.now().millisecondsSinceEpoch / 1000.0,
      };
      _localComments[cid] = comment; // SSE 重拉去重合并的本地兜底
      final idx = state.posts.indexWhere((rec) => rec.id == rid);
      if (idx < 0) return false;
      _patchRecord(rid, comments: mergeCommentsByCid(
          state.posts[idx].comments, [comment]));
      return true;
    } catch (e) {
      _toast('评论发送失败：${api.errorDetail(e)}', ChatToastTone.error);
      return false;
    }
  }

  /// B2 删评论：仅本人（UI 已按 author 控制入口，服务端再校验一次）。
  /// 成功后本卡移除；失败回滚并给顶部通知。
  Future<void> deleteComment(String rid, String cid, String myId) async {
    if (_disposed) return;
    final idx = state.posts.indexWhere((r) => r.id == rid);
    if (idx < 0) return;
    final before = List<Map<String, dynamic>>.of(state.posts[idx].comments);
    final target = before.where((c) => c['id']?.toString() == cid).toList();
    if (target.isEmpty || !canDeleteComment(target.first, myId)) return;
    final optimistic = before
        .where((c) => c['id']?.toString() != cid)
        .toList();
    _localComments.remove(cid);
    _patchRecord(rid, comments: optimistic);
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.delete('/api/comments/$cid');
      if ((r.statusCode ?? 500) >= 400) {
        throw Exception('HTTP ${r.statusCode}');
      }
    } catch (e) {
      _patchRecord(rid, comments: before); // 回滚
      _toast('删除评论失败，已恢复：${api.errorDetail(e)}',
          ChatToastTone.error);
    }
  }

  // ── 段二 C · 编辑 / 删除（本卡原地更新 / 回填铁律）──────────────

  /// C2 编辑：PUT /api/records/{rid} {kind, body}。
  /// [changes] 只含用户实际改动的字段；服务端 clean_body 只留 permitted
  /// 字段，故 body 必须以本卡从服务器拉到的原始 body 为底逐键复制后覆盖，
  /// 客户端不建模的字段（含 permitted 集内未知字段）一律原样带回。
  /// 成功后用服务端返回的完整记录本卡原地替换（不整列表重建）。
  Future<String?> editRecord(String rid, Map<String, dynamic> changes,
      {Map<String, dynamic>? originalBody, String? kindOverride}) async {
    if (_disposed) return null;
    final idx = state.posts.indexWhere((r) => r.id == rid);
    if (idx < 0 && originalBody == null) return null;
    // 以「服务器拉到的原始 body」为底：优先用 composer 打开时持有的那份
    // （避免编辑期间 SSE 重拉把 state 里的 body 换掉），否则用当前卡的。
    final base = originalBody ?? state.posts[idx].body;
    final body = buildEditBody(base, changes); // 回填铁律
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.put('/api/records/$rid', data: {
        // 草稿箱「继续编辑」显式保持 kind=draft；其余沿用列表卡的 kind。
        'kind': kindOverride ??
            (idx >= 0 ? state.posts[idx].kind : 'post'),
        'body': body,
      });
      if ((r.statusCode ?? 500) >= 400) {
        final data = r.data;
        if (data is Map && data['detail'] != null) {
          return data['detail'].toString();
        }
        return '保存失败，请重试';
      }
      // 服务端返回 serialize 后的完整记录 → 只替换本卡（其余引用不变）
      if (r.data is Map) {
        final updated = api.Record.fromJson(
            (r.data as Map).cast<String, dynamic>());
        _patchWholeRecord(rid, updated);
      }
      return null; // 成功
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// 用服务端返回的完整 Record 本卡原地替换（保留 B 段本地乐观态）：
  /// likes 用服务端值（编辑不动点赞），comments 按 cid 去重合并本地即时插入。
  void _patchWholeRecord(String rid, api.Record updated) {
    if (_disposed) return;
    final idx = state.posts.indexWhere((r) => r.id == rid);
    if (idx < 0) return;
    final locals = _localComments.values
        .where((c) => c['record_id']?.toString() == rid)
        .toList();
    final merged = locals.isEmpty
        ? updated.comments
        : mergeCommentsByCid(updated.comments, locals);
    final next = List<api.Record>.of(state.posts);
    next[idx] = _rebuildRecord(updated, comments: merged);
    state = state.copyWith(posts: next);
    // 服务端已回显的本地评论兜底清除
    final serverCids = {for (final c in updated.comments) c['id']?.toString()};
    _localComments.removeWhere((cid, _) => serverCids.contains(cid));
  }

  /// C3 删除：确认弹层由 UI 承担 → DELETE /api/records/{rid}（软删，
  /// 进作者回收站 30 天可恢复；回收站 UI 归条目 7 本段不做）。
  /// 成功后本卡原地移除（沿用 B 段 _patchRecord 机制，不整列表重建）。
  Future<String?> deleteRecord(String rid) async {
    if (_disposed) return null;
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.delete('/api/records/$rid');
      if ((r.statusCode ?? 500) >= 400) {
        final data = r.data;
        if (data is Map && data['detail'] != null) {
          return data['detail'].toString();
        }
        return '删除失败，请重试';
      }
      // 本卡原地移除：其余元素引用不变、顺序不变、游标不变
      final next = state.posts.where((r) => r.id != rid).toList();
      state = state.copyWith(posts: next);
      return null; // 成功
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// 发布（composer 完整态）：POST /api/records {kind:'post', body, client_id}。
  /// client_id 幂等复用：失败保留同一 id 重试，成功清空。
  /// [album] 为相册 id（空/不传=不分类）；服务端校验相册存在。
  /// 返回 null=成功；否则为错误文案。
  Future<String?> publish({
    required String content,
    required String date,
    required List<String> mediaIds,
    String? title,
    String? album,
    String? clientId,
  }) async {
    final cid = clientId ?? _activePostClientId ?? newChatClientId();
    _activePostClientId = cid; // 会话态同步（失败重试复用）
    final body = <String, dynamic>{
      'content': content,
      'date': date,
      'media': mediaIds,
      if (title != null && title.isNotEmpty) 'title': title,
      if (album != null && album.isNotEmpty) 'album': album,
    };
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.post('/api/records', data: {
        'kind': 'post',
        'body': body,
        'client_id': cid,
      });
      if ((r.statusCode ?? 500) >= 400) {
        final data = r.data;
        if (data is Map && data['detail'] != null) return data['detail'].toString();
        return '发布失败，请重试';
      }
      _activePostClientId = null; // 成功清空（下次发布新 id）
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// 保存草稿（composer 完整态）：POST /api/records {kind:'draft', body, client_id}。
  /// draft 属 PRIVATE（published=null，非作者不可见），body 字段与 post 同构。
  /// client_id 幂等复用：失败保留同一 id 重试；成功清空（改内容再存走新 id 新建，
  /// 避免同 client_id 命中旧草稿不更新）。
  /// [album] 为相册 id（空/不传=不分类）。返回 null=成功；否则为错误文案。
  Future<String?> saveDraft({
    required String content,
    required String date,
    required List<String> mediaIds,
    String? title,
    String? album,
    String? clientId,
  }) async {
    final cid = clientId ?? _activeDraftClientId ?? newChatClientId();
    _activeDraftClientId = cid; // 会话态同步（失败重试复用）
    final body = <String, dynamic>{
      'content': content,
      'date': date,
      'media': mediaIds,
      if (title != null && title.isNotEmpty) 'title': title,
      if (album != null && album.isNotEmpty) 'album': album,
    };
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.post('/api/records', data: {
        'kind': 'draft',
        'body': body,
        'client_id': cid,
      });
      if ((r.statusCode ?? 500) >= 400) {
        final data = r.data;
        if (data is Map && data['detail'] != null) return data['detail'].toString();
        return '草稿保存失败，请重试';
      }
      _activeDraftClientId = null; // 成功清空（下次保存新 id）
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }
}

final timelineControllerProvider =
    NotifierProvider<TimelineController, TimelineState>(TimelineController.new);
