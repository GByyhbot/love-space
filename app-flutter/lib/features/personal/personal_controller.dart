/// 「个人角落」段 7-A / 7-B / 7-C 数据层（Riverpod Notifier）。
///
/// · 🔴 7-C 个人心愿走**专属端点 + 独立 kind 串 + 独立 state**：
///   [personalWishKinds] = 'personal_wish'，[PersonalController.loadWishes]
///   显式 `GET /api/records?kind=personal_wish&limit=1000`，**不带 author、
///   不按 author 过滤**（personal_wish 不在 PRIVATE，双方都能看到锁态标题）；
///   独立 [PersonalState.wishes] / `_wishSeq`，换号一并清空重拉。
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

/// 🔴 7-C 独立 kind 串：**绝不复用 [personalKinds]**。
/// personalKinds = diary,draft,surprise（PRIVATE 三类）；服务端对「不带 kind」
/// 隐式排除这三类（main.py:1156），且 [PersonalController.load] 会带 author
/// 参数并二次按 author 过滤。personal_wish 不在 db.PRIVATE（db.py:343）、
/// 也不在 ENCRYPTED，db.visible 不拦（db.py:377）、serialize 也不对非作者抛
/// 404（serializers.py:18-19）→ **双方都要拉到彼此的锁态标题**。
/// 复用 personalKinds 会同时踩两个坑：①按 author 把对方心愿过滤掉；
/// ②服务端不带 kind 的隐式排除让 personal_wish 漏出 kind 串。
const personalWishKinds = 'personal_wish';

/// 🔴 7-C 隐私红线（serializers.py:23-36 实读）：
/// 列表 GET 的 personal_wish body 是 serialize **重建**出来的，不是 stored 原文：
/// · 作者态：`{title, locked:false, content, sealed}`（sealed 是凭密码解密用的
///   密文副本，Web personalWishCard 不呈现；且 :35-36 对作者是无条件追加，
///   即便 open_sealed 失败退化成锁定态也照样下发）；
/// · 对方已解锁：`{title, locked:false, content}`；
/// · 对方未解锁：`{title, locked:true}`（content 不下发）。
/// parseTogetherRecords 会把 body 整包带进客户端，这里在**数据层**就收敛为
/// Web 呈现范围内的三键 {title, locked, content?}：sealed / password_hash /
/// owner_sealed / readers_sealed 等一律丢弃——不渲染、不缓存、不进日志/通知/搜索。
/// 渲染层同样只取三键（personal_page.dart 的 _WishTile 有同款注释）。
Map<String, dynamic> sanitizeWishBody(Map<String, dynamic> body) {
  final locked = body['locked'] != false;
  return <String, dynamic>{
    'title': (body['title'] ?? '').toString(),
    'locked': locked,
    if (!locked) 'content': (body['content'] ?? '').toString(),
  };
}

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
    this.wishes = const [],
    this.loading = false,
    this.trashLoading = false,
    this.wishLoading = false,
    this.error,
  });

  /// 已按 author 过滤、且只含 diary/draft/surprise 三类
  final List<TogetherRecord> records;
  /// 回收站（trash=true 拉取，含私密三类；已按 author 过滤）
  final List<TogetherRecord> trash;
  /// 🔴 7-C 独立列表：personal_wish，**不按 author 过滤**（双方锁态标题都要显示）。
  /// body 已由 [sanitizeWishBody] 收敛为 {title, locked, content?} 三键，
  /// 绝不缓存 sealed / password_hash 等超出 Web 呈现范围的字段。
  final List<TogetherRecord> wishes;
  final bool loading;
  final bool trashLoading;
  final bool wishLoading;
  final String? error;

  PersonalState copyWith({
    List<TogetherRecord>? records,
    List<TogetherRecord>? trash,
    List<TogetherRecord>? wishes,
    bool? loading,
    bool? trashLoading,
    bool? wishLoading,
    String? error,
  }) =>
      PersonalState(
        records: records ?? this.records,
        trash: trash ?? this.trash,
        wishes: wishes ?? this.wishes,
        loading: loading ?? this.loading,
        trashLoading: trashLoading ?? this.trashLoading,
        wishLoading: wishLoading ?? this.wishLoading,
        error: error,
      );
}

class PersonalController extends Notifier<PersonalState> {
  bool _disposed = false;
  bool _loaded = false;
  int _reqSeq = 0;
  int _trashSeq = 0; // 独立序号：load 与 loadTrash 可安全地先后/并发，互不误杀
  int _wishSeq = 0; // 7-C 独立序号：wishes 与 records/trash 互不误杀

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
      _wishSeq++; // 7-C：wishes 一并作废，换号不串
      // 微任务里改 state/重拉：避免在 provider 通知/ widget build 期间改 provider
      Future.microtask(() async {
        if (_disposed) return;
        state = const PersonalState();
        await load();
        if (_disposed) return;
        await loadTrash();
        if (_disposed) return;
        await loadWishes();
      });
    });
    if (userChanged) {
      // 依赖重建路径：旧 listener 可能已被 Riverpod 移除，这里兜底重拉
      _reqSeq++;
      _trashSeq++;
      _wishSeq++;
      Future.microtask(() async {
        if (_disposed) return;
        await load();
        if (_disposed) return;
        await loadTrash();
        if (_disposed) return;
        await loadWishes();
      });
    }
    return const PersonalState();
  }

  /// 进入页面初始化：换号重置（状态清空 + 重拉）；首次进页拉首屏
  /// （records / trash / wishes 三路各自独立， wishes 也一并覆盖）。
  Future<void> bootstrap() async {
    final uid = ref.read(personalCurrentUserProvider);
    if (_boundUserId != uid) {
      _boundUserId = uid;
      _loaded = false;
      _reqSeq++;
      _trashSeq++;
      _wishSeq++;
      if (!_disposed) state = const PersonalState();
    }
    if (!_loaded) {
      await load();
      if (_disposed) return;
      await loadTrash();
      if (_disposed) return;
      await loadWishes();
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
  /// 🔧 7-C 支撑修正：响应序号检查改用**自己的 `_trashSeq`**（原先误用
  /// `_reqSeq`）。7-C 起 [loadWishes] 会独立自增 `_wishSeq`，两者不再与
  /// `_reqSeq` 同步递增，若继续按 `_reqSeq` 比对，删除心愿后的 loadTrash
  /// 会被误判为「旧响应」而静默不更新回收站；改回独立序号与 7-B 注释的
  /// 「load 与 loadTrash 互不误杀」设计一致。
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
      if (_disposed || seq != _trashSeq) return;
      final all = uid.isEmpty
          ? <TogetherRecord>[]
          : parseTogetherRecords(r.data)
              .where((x) => x.author == uid)
              .toList();
      state = state.copyWith(trash: all, trashLoading: false);
    } catch (e) {
      if (!_disposed && seq == _trashSeq) {
        state = state.copyWith(
            trashLoading: false, error: api.errorDetail(e));
      }
    }
  }

  /// 🔴 7-C 独立拉取个人心愿列表：
  /// `GET /api/records?kind=personal_wish&limit=1000`（**显式 kind，且绝不带
  /// author**——personal_wish 不在 db.PRIVATE（db.py:343），db.visible 不拦、
  /// serialize 也不对非作者抛 404，双方都要看到彼此的锁态标题；带 author 会
  /// 把对方心愿过滤掉，这正是不能复用 [personalKinds] / [load] 的根因）。
  /// · uid 为空（登录态未落定/已登出）→ **fail-closed 不渲染任何内容**；
  ///   但 personal_wish 与 PRIVATE 不同，**不套「仅本人可见」过滤**。
  /// · 服务端 serialize 重建 body（三态）→ [sanitizeWishBody] 收敛三键，
  ///   超出 Web 呈现范围的字段（作者额外下发的 sealed 密文等）一律不缓存。
  /// · 独立 [_wishSeq]：与 load / loadTrash 互不误杀。
  Future<void> loadWishes() async {
    if (_disposed) return;
    final seq = ++_wishSeq;
    state = state.copyWith(wishLoading: true, error: null);
    try {
      final uid = await _currentUserId();
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.get('/api/records', queryParameters: {
        'kind': personalWishKinds,
        'limit': 1000,
      });
      if (_disposed || seq != _wishSeq) return; // 旧响应失效（换号/连点）
      final all = uid.isEmpty
          ? <TogetherRecord>[]
          : parseTogetherRecords(r.data)
              .where((x) => x.kind == personalWishKinds)
              .map((x) => TogetherRecord(
                    id: x.id,
                    kind: x.kind,
                    body: sanitizeWishBody(x.body),
                    author: x.author,
                    created: x.created,
                    answers: x.answers,
                    answerCount: x.answerCount,
                    checks: x.checks,
                    media: x.media,
                    likeCount: x.likeCount,
                    commentCount: x.commentCount,
                    deleted: x.deleted,
                  ))
              .toList();
      state = state.copyWith(wishes: all, wishLoading: false);
    } catch (e) {
      if (!_disposed && seq == _wishSeq) {
        state = state.copyWith(wishLoading: false, error: api.errorDetail(e));
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

  /// 🔴 7-C 个人心愿（created 倒序）：**不按 author 过滤**——双方都要看到
  /// 彼此的锁态标题（服务端 serialize 按「作者 / 已解锁 / 未解锁」重建 body）。
  /// uid 为空（登录态未落定/已登出）→ fail-closed 返回空列表，不渲染任何内容。
  List<TogetherRecord> wishes() {
    final uid = ref.read(personalCurrentUserProvider);
    if (uid.isEmpty) return const <TogetherRecord>[];
    return sortByCreatedDesc(state.wishes
        .where((r) => r.kind == personalWishKinds)
        .toList());
  }

  /// 新建个人心愿：`POST /api/personal-wishes`（main.py:1306-1332）。
  /// · 客户端先拦空 **+ 拦 Field 越界**（title 1..100 / content 1..20000 /
  ///   password 6..128，对齐 Web minlength=6 与 PersonalWishInput 的 Field
  ///   约束），不合法不发请求。🔴 QA 增量：Pydantic `Field(min/max)` 越界时
  ///   detail 是**英文数组**（main.py:914-918），`api.errorDetail` 会把数组
  ///   toString 成一坨英文结构化文本；只有先拦住越界，服务端回的都是手动抛的
  ///   中文原文（422 空字段 / 422 撞密码 / 409），才能原样透传给 UI。
  /// · 撞密码是**空间级**约束（服务端遍历所有 personal_wish 的 password_hash，
  ///   含对方的心愿）→ 422 原文由 [api.errorDetail] 透传给 UI 双呈现，绝不吞。
  /// · client_id 用 [newChatClientId]（幂等；撞其他 kind 由服务端回 409）。
  /// 🔴 密码只在本次请求体里过一遍：不落本地存储、不进 state、不进日志/缓存；
  /// 加解密全在服务端，客户端不实现任何加密。成功后重拉 wishes。
  /// 返回 null=成功。
  Future<String?> addPersonalWish(
      String title, String content, String password) async {
    if (_disposed) return null;
    final t = title.trim();
    final c = content.trim();
    if (t.isEmpty || c.isEmpty || password.trim().isEmpty) {
      return '请填写心愿名称、具体内容和独立密码';
    }
    // 🔴 挡住 Pydantic Field 校验型 422（detail 是英文数组，无法原样呈现）：
    // 先拦越界，保证发给服务端的请求只会得到手动抛的中文错误。
    if (t.length > 100) return '心愿名称最多 100 字';
    if (c.length > 20000) return '具体心愿内容最多 20000 字';
    if (password.length < 6) return '密码至少 6 位（建议纯数字）';
    if (password.length > 128) return '密码最多 128 位';
    try {
      final dio = await ref.read(api.dioProvider.future);
      await dio.post('/api/personal-wishes', data: {
        'title': t,
        'content': c,
        'password': password,
        'client_id': newChatClientId(),
      });
      await loadWishes();
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// 解锁：`POST /api/personal-wishes/{rid}/unlock`（main.py:1335-1365）。
  /// · 作者本人 / 已解锁者由列表直接下发 content（**免密直达**），本方法只供
  ///   对方首次输密码调用；成功后服务端写 readers_sealed（永久可见）。
  /// · 客户端**重拉列表确认状态**，不自己记解锁态、不本地缓存 content。
  /// · 错密码 403「密码不正确，请向心愿本人确认」/ 超频 429
  ///   「尝试过于频繁，请 15 分钟后再试」原文由 [api.errorDetail] 透传，
  ///   不吞、**不自动重试**（限流配额按 每条心愿·每人 计，main.py:1351）。
  /// 🔴 密码只在请求体里过一遍，不落本地、不进日志/缓存。返回 null=成功。
  /// 解锁页**只拦空**：后端 `PersonalWishUnlockInput.password` 是
  /// `min_length=1`（main.py:921-922），**不是 6**，绝不套创建页的 ≥6 校验，
  /// 否则会拦掉合法短密码、制造客户端与服务端不一致。
  Future<String?> unlockPersonalWish(String rid, String password) async {
    if (_disposed) return null;
    if (password.isEmpty) return '请输入心愿密码';
    try {
      final dio = await ref.read(api.dioProvider.future);
      await dio.post('/api/personal-wishes/$rid/unlock', data: {
        'password': password,
      });
      await loadWishes();
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// 删除个人心愿（仅作者）：走**通用** `DELETE /api/records/{rid}`
  /// （main.py:1424；Web app.js:2523 `del('/records/'+id)`）。Web 无编辑入口
  /// （clean_body 对 personal_wish 明确 422「个人心愿请使用专属加密接口保存」），
  /// App 不自创编辑 / 彻底删除。成功后重拉 wishes + trash。
  /// 返回 null=成功。
  Future<String?> deleteWish(String rid) async {
    if (_disposed) return null;
    try {
      final dio = await ref.read(api.dioProvider.future);
      await dio.delete('/api/records/$rid');
      state = state.copyWith(
          wishes: state.wishes.where((r) => r.id != rid).toList());
      await loadWishes();
      if (_disposed) return null;
      await loadTrash();
      return null;
    } catch (e) {
      return api.errorDetail(e);
    }
  }

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
