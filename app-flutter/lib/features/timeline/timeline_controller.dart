/// 时光页状态与控制器（条目 4 · 段一）。
/// 状态挂 keepAlive Notifier：切 tab（shell IndexedStack 常驻）与短时离开
/// 不丢列表/筛选；首屏骨架只在首次拉取时出现（对齐 Web timelineSkeleton）。
/// SSE other 且时光 tab 激活 → resetOnSseOther（对齐 Web refresh）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/chat/chat_repository.dart' show newChatClientId;
import '../../core/timeline/timeline_data.dart';

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

  /// composer 发布幂等：首次生成后随会话保留（失败重试复用，成功清空——
  /// 持久化暂存归段二）
  String? _activePostClientId;

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
    if (state.loading || _disposed) return;
    if (!reset && !state.hasMore) return;
    state = state.copyWith(loading: true, error: null,
        skeleton: reset && !_skeletonSeen);
    try {
      final dio = await ref.read(api.dioProvider.future);
      final cursor = reset ? null : _cursor;
      final r = await dio.get('/api/records',
          queryParameters: buildTimelineQuery(state.filter, cursor: cursor));
      final fetched = parsePostRecords(r.data);
      final hasMore = fetched.length > timelinePageSize;
      final page = fetched.take(timelinePageSize).toList();
      if (reset) {
        if (!_disposed) state = state.copyWith(posts: page, hasMore: hasMore);
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
      if (!_disposed) {
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

  /// 发布（composer 基础态）：POST /api/records {kind:'post', body, client_id}。
  /// client_id 幂等复用：失败保留同一 id 重试，成功清空。
  /// 返回 null=成功；否则为错误文案。
  Future<String?> publish({
    required String content,
    required String date,
    required List<String> mediaIds,
    String? title,
  }) async {
    final clientId = _activePostClientId ??= newChatClientId();
    final body = <String, dynamic>{
      'content': content,
      'date': date,
      'media': mediaIds,
      if (title != null && title.isNotEmpty) 'title': title,
    };
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.post('/api/records', data: {
        'kind': 'post',
        'body': body,
        'client_id': clientId,
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
}

final timelineControllerProvider =
    NotifierProvider<TimelineController, TimelineState>(TimelineController.new);
