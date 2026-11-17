/* 条目 7 段 7-C 自测夹具（2.2.0/VC220 真机阻断级返修 · 个人心愿）。
   7-C 初版 2.1.9/VC219 覆盖验收点 ①–⑫（本次同步回归，一条不改坏）；
   🔴 2.2.0 返修新增 ⑬：按**真实响应形状**复验 unlock 失败分支 + 双条件门控
   + client_id 幂等 + 连带写路径。

   【夹具形状的关键修正（本次返修根因之一，证据先行）】
   旧夹具 _setup 用 Dio 默认 validateStatus(200<=s<300) → 403/429/422 在
   测试里抛 DioException，恰好被 api.errorDetail 接住拿到 detail 原文，于是
   ②c/③/④「假通过」，从未覆盖真机 api.validateAppStatus (s<500) 下
   「4xx 作为成功 Response 返回、不抛 DioException」的形状。本次 _setup
   改为与生产 buildDio **共用** api.validateAppStatus；_adapterFor 直接返回
   statusCode=403 / 429 的 ResponseBody，响应体逐字为
     {"detail":"密码不正确，请向心愿本人确认"}
     {"detail":"尝试过于频繁，请 15 分钟后再试"}
   成功形状逐字为 {"content":"..."}，重拉列表该条 locked=false。

   原覆盖验收点 ①–⑫：
   ① 三态渲染（作者免密 / 已解锁 / 待解锁；待解锁 content 不渲染、sealed 不渲染）
   ② 双机全程（我建 → 对象端锁态 → 错密码 403 原文 → 对密码解锁 → 重拉后
      content 出现 → 退出重进仍免密）
   ③ 第二条心愿复用同密码 → 422 原文「双呈现」（表单内联 + 顶部通知）
   ④ 429 限速原文 + 双呈现
   ⑤ 换号不串（wishes 与解锁态只属新账号；logout invalidate 覆盖 wishes）
   ⑥ 请求中按钮禁用、不连点叠加（只发 1 次 unlock）、不自动重试
   ⑦ 密码不落本地（无持久化 / 无日志 / 无缓存；数据层 sanitize 丢掉越界字段）
   ⑧ 返回路径按钮 + 系统手势 handlePopRoute()
   ⑨ 删除走通用 DELETE + 标准文案 privateDeleteText + 重拉 wishes/trash
   ⑩ Web 无编辑 / 无彻底删除（App 不自创）
   ⑪ 4→5 tab、无 7-D 死卡
   ⑫ 请求 kind 串 personal_wish 显式断言（不带 author、limit=1000）

   ── 夹具形状来源（真实样本 + 序列化推导，双处注明）──────────────────
   客户端实际收到的是 **serialize 重建后的 body**，不是 stored 原文。依据
   `app/serializers.py:23-36` 逐行实读：
     · 作者本人（owner_sealed）→ {title, locked:false, content, sealed}
       （sealed 是凭密码解密用的密文副本，Web personalWishCard 不呈现；
         :35-36 对作者无条件追加，open_sealed 失败退化锁定态时也照样下发）
     · 对象已解锁（readers_sealed[uid]）→ {title, locked:false, content}
     · 对象未解锁 → {title, locked:true}（**content 不下发**）
     · password_hash / owner_sealed / readers_sealed / unlocked_by 等 stored
       字段随 result['body'] 整体替换，客户端拿不到。
   真实存量（2026-11-14 SSH 只读直查 NAS 容器 love-space:/data/love.db，
   经 .workbuddy/deploy.py connect()/run()，临时脚本用完即删；**未写库、
   未造数据、未打印任何密文**）：personal_wish 实测 2 行
     · id=b2c7d2a1f5b344dfabbf50c8d96c1fb3 / author=c7e5070e0f0a467dbc2e13d677ca8612
       / created=1791195587.7337775 / title=「最想完成的事」
     · id=9ce5acfad9e04baaa8d5bdb50bb70a0f / author=b7572733c5d540f0bf2379bb06f35206
       / created=1793635924.9610257 / title=「回🏡了」
     · 两条 stored body keys 实测均为 [owner_sealed, password_hash, sealed, title]，
       都还没有 readers_sealed（对方未解锁）；两条分属不同 author，正好印证
       「双方心愿都要显示、客户端绝不能按 author 过滤」。
   本文件的 _authorWish / _lockedWish 逐字取上述两条真实 id/author/created/
   title，按三态序列化形状构造；_unlockedWish 是第二条真实行在「对象已解锁」
   分支（serializers.py:29-32 readers.get(user_id)）下的等价形状，id 加后缀
   以区分三态，属于等价推导而非凭空造。作者态额外注入 sealed 密文 / 畸形
   password_hash / owner_sealed、锁定态额外注入畸形 content，专门验证客户端
   「渲染层只取三键、locked 态不呈现 content、越界字段不缓存」的隐私红线。
   同样是「真实存量 + 序列化等价形状」双处注明（本文件头 +
   docs/personal-corner-plan.md），与 7-A diary / 7-B surprise 的处理一致。
   🔴 stored 原文**没有明文 content 键**（正文只以密文 `sealed` / `owner_sealed`
   存在，main.py:1327-1328），本文件**不构造 stored 夹具、绝不伪造 content**；
   `_lockedWish` 里那一个 `content` 是**畸形注入的防御测试样本**，专测客户端
   对 locked 态绝不呈现 content、数据层无条件丢弃越界键，**不代表 API 形状**
   （服务端 serialize 恒不下发 `locked:true + content`）。
   QA 增量点逐条落地：① `author=TA` 的锁态记录仍渲染 + `loadWishes` 请求
   无 author 键 + state 里两账号都在；② `sealed` 净化无条件（含作者退化
   锁定态 `locked:true + sealed` 用例）；③ 客户端先拦 Field 越界
   （title>100 / content>20000 / password>128）避免英文数组型 422，解锁页
   只拦空不套 ≥6；⑤ 删除沿用 `confirmPrivateDelete()` + `privateDeleteText`，
   不新造弹层、不按 Web 逐字改文案。

   测试坑规避（沿用 7-A/7-B 踩过的经验）：
   · `flutter test` 前 unset 八个代理变量（含 ALL_PROXY/all_proxy/NO_PROXY）；
   · 纯 test() 里不调 bootstrap()，且用 personalCurrentUserProvider.overrideWith
     固定 uid，避免 authProvider 依赖重建把 _disposed 置 true 导致写操作 no-op；
   · testWidgets 的 FakeAsync 区里对无 widget 树容器直接 await 控制器请求会挂起
     → 控制器用例拆成纯 test() 真实 async 区，widget 用例只做交互/渲染断言；
   · dio 默认参数不用非 const 顶层变量（本文件无默认参数）；
   · 标题与正文同文时 find.textContaining 会命中多个 → 用 find.text 精确或
     findsWidgets / evaluate().length；
   · toast 的 2.2s Timer 收尾统一 _flush() 里 pump(3s) 冲洗；
   · ListView 页尾元素先 scrollUntilVisible，并把测试视口调大。 */
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import 'package:love_space/core/together/together_data.dart';
import 'package:love_space/features/chat/chat_toast.dart'
    show ChatToastHost, ChatToastTone, chatToastProvider;
import 'package:love_space/features/personal/personal_controller.dart';
import 'package:love_space/features/personal/personal_page.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final FutureOr<ResponseBody> Function(RequestOptions options, int callIndex)
      handler;
  final List<RequestOptions> requests = [];
  int calls = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return await handler(options, calls++);
  }
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
    jsonEncode(data), status,
    headers: {Headers.contentTypeHeader: const ['application/json']});

Map<String, Object> _meFixture({String uid = 'u1'}) => {
      'user': {'id': uid, 'name': uid == 'u1' ? '我' : 'TA', 'username': uid},
      'users': [
        {'id': 'u1', 'name': '我', 'username': 'u1'},
        {'id': 'u2', 'name': 'TA', 'username': 'u2'},
      ],
      'space': {}, 'unread': 0, 'chat_unread': 0,
    };

/// serialize_many 顶层形状（body 为 **序列化重建后** 的三态形状）
Map<String, Object?> _wishRec({
  required String id,
  required String author,
  required Map<String, Object?> body,
  double created = 1791195587.7337775,
}) =>
    {
      'id': id,
      'kind': 'personal_wish',
      'author': author,
      'body': body,
      'created': created,
      'updated': created,
      'published': null,
      'deleted': null,
      'client_id': 'cid-$id',
      'media': <Object>[],
      'likes': <Object>[],
      'comments': <Object>[],
    };

/// 超出 Web 呈现范围的字段值（专测「不渲染 / 不缓存」）
const String _cipher = 'SEALED_CIPHERTEXT_SHOULD_NOT_RENDER';
const String _ownerCipher = 'OWNER_SEALED_SHOULD_NOT_RENDER';
const String _lockedCipher = 'LOCKED_SEALED_SHOULD_NOT_RENDER';
const String _hashValue = 'PASSWORD_HASH_SHOULD_NOT_RENDER';
const String _hostileContent = '不该被渲染的锁定态密文内容';

/// ① 作者免密态（NAS 真实行 1）：{title, locked:false, content, sealed}
/// 额外注入 password_hash / owner_sealed 畸形字段，验证渲染层只取三键。
final Map<String, Object?> _authorWish = _wishRec(
  id: 'b2c7d2a1f5b344dfabbf50c8d96c1fb3',
  author: 'u1',
  created: 1791195587.7337775,
  body: {
    'title': '最想完成的事',
    'locked': false,
    'content': '想和你一起去看一次海',
    'sealed': {'ciphertext': _cipher},
    'password_hash': _hashValue,
    'owner_sealed': {'ciphertext': _ownerCipher},
  },
);

/// ③ 对方待解锁态（NAS 真实行 2）：{title, locked:true}（content 不下发）。
/// 故意塞入畸形 content + sealed，验证 locked 态绝不呈现 content、
/// 数据层 sanitizeWishBody 把越界键全部丢弃。
/// 🔴 注意：服务端 serialize **恒不下发** `locked:true + content`，这里的
/// content 是**畸形注入的防御测试样本，不是 API 形状**（QA 明确要求 stored
/// 夹具不得伪造 content 键；本文件全部夹具都是 serialize 重建后的 API 形状）。
final Map<String, Object?> _lockedWish = _wishRec(
  id: '9ce5acfad9e04baaa8d5bdb50bb70a0f',
  author: 'u2',
  created: 1793635924.9610257,
  body: {
    'title': '回🏡了',
    'locked': true,
    'content': _hostileContent,
    'sealed': {'ciphertext': _lockedCipher},
  },
);

/// ② 对方已解锁态（真实行 2 的 readers_sealed 分支等价形状）：
/// {title, locked:false, content}，无 sealed。
final Map<String, Object?> _unlockedWish = _wishRec(
  id: '9ce5acfad9e04baaa8d5bdb50bb70a0f-unlocked-equivalent',
  author: 'u2',
  created: 1793635924.9610257,
  body: {
    'title': '一起布置未来的家',
    'locked': false,
    'content': '一起把家布置成想要的样子',
  },
);

final List<Object?> _defaultWishes = [
  _authorWish,
  _lockedWish,
  _unlockedWish,
];

/// 可变后端状态：模拟服务端按当前 uid 重新 serialize 的三态 + 专属端点。
/// 🔴 2.2.0 返修：unlock 200 会**真实**写 readers_sealed（重拉 locked:false），
/// 失败 403/429 完全不写（重拉 locked:true），与 main.py:1350-1365 一致。
class _Store {
  _Store({List<Object?>? wishes})
      : wishes = List<Object?>.from(wishes ?? _defaultWishes);

  List<Object?> wishes;
  String uid = 'u1';
  int createStatus = 200;
  String? createDetail;
  int unlockStatus = 200;
  String? unlockDetail;
  /// 200 响应体是否含 content（门控条件①；false 专测「2xx 但无 content」）
  bool unlockReturnsContent = true;
  /// 200 后是否模拟服务端写 readers_sealed（重拉列表该条 locked:false）；
  /// false 专测门控条件②「200 但重拉后仍 locked=true」（服务端异常/竞态）。
  bool unlockWritesReaders = true;
  Completer<ResponseBody>? unlockGate;
  void Function(Map<String, Object?> body)? onCreateSuccess;
  int createCalls = 0;
  int unlockCalls = 0;
  final List<Map<String, Object?>> createBodies = [];
  final List<Map<String, Object?>> unlockBodies = [];

  // 连带核查：其余写路径的 4xx 模拟（默认 200 全放行，不改变既有断言）
  int recordsPostStatus = 200;
  String? recordsPostDetail;
  int putStatus = 200;
  String? putDetail;
  int deleteStatus = 200;
  String? deleteDetail;
  int restoreStatus = 200;
  String? restoreDetail;
}

/// 模拟服务端 main.py:1355-1364 解锁成功后写 readers_sealed：
/// 重拉列表时该 rid 的 serialize 形状变为 {title, locked:false, content}。
/// 该 rid 原本不在列表（纯控制器用例）→ 追加一条已解锁记录，
/// 保证「服务端确认成功 → 重拉 locked:false」的双条件闭环可测。
void _markWishUnlocked(_Store s, String rid) {
  for (var i = 0; i < s.wishes.length; i++) {
    final w = s.wishes[i];
    if (w is Map && w['id'] == rid) {
      final updated = Map<String, Object?>.from(w);
      updated['body'] = <String, Object?>{
        'title': (w['body'] as Map)['title'] ?? '',
        'locked': false,
        'content': '想和你一起去看一次海',
      };
      s.wishes[i] = updated;
      return;
    }
  }
  s.wishes.add(_wishRec(
    id: rid,
    author: 'u2',
    body: <String, Object?>{
      'title': '已解锁心愿',
      'locked': false,
      'content': '想和你一起去看一次海',
    },
  ));
}

_FakeAdapter _adapterFor(_Store s) => _FakeAdapter((o, i) async {
      if (o.uri.path == '/api/me') return _json(_meFixture(uid: s.uid));
      if (o.method == 'GET' && o.uri.path == '/api/records') {
        final trash = o.queryParameters['trash'];
        if (trash == true || trash == 'true') return _json(<Object>[]);
        if (o.queryParameters['kind'] == personalWishKinds) {
          return _json(s.wishes);
        }
        // personalKinds / trashKinds 主列表：本夹具不关心，返回空
        return _json(<Object>[]);
      }
      if (o.method == 'POST' && o.uri.path == '/api/personal-wishes') {
        s.createCalls++;
        final body = Map<String, Object?>.from(o.data as Map);
        s.createBodies.add(body);
        if (s.createStatus >= 400) {
          return _json({'detail': s.createDetail}, s.createStatus);
        }
        s.onCreateSuccess?.call(body);
        return _json(<String, Object>{});
      }
      final path = o.uri.path;
      if (o.method == 'POST' &&
          path.startsWith('/api/personal-wishes/') &&
          path.endsWith('/unlock')) {
        s.unlockCalls++;
        s.unlockBodies.add(Map<String, Object?>.from(o.data as Map));
        final gate = s.unlockGate;
        if (gate != null) return await gate.future;
        // 🔴 真实形状：403/429 是「成功返回但 statusCode 为 4xx」的 Response，
        // 逐字响应体 {"detail":"..."}；夹具 Dio 用 api.validateAppStatus(s<500)
        // 放行、不抛 DioException，与真机取证完全一致。
        if (s.unlockStatus >= 400) {
          return _json({'detail': s.unlockDetail}, s.unlockStatus);
        }
        if (s.unlockWritesReaders) {
          final rid = path.split('/')[3]; // /api/personal-wishes/{rid}/unlock
          _markWishUnlocked(s, rid);
        }
        // 200 成功形状逐字 {"content":"..."}；关掉开关专测门控条件①
        return _json(s.unlockReturnsContent
            ? <String, Object>{'content': '想和你一起去看一次海'}
            : <String, Object>{});
      }
      if (o.method == 'POST' && path == '/api/records') {
        if (s.recordsPostStatus >= 400) {
          return _json({'detail': s.recordsPostDetail}, s.recordsPostStatus);
        }
        return _json(<String, Object>{});
      }
      if (o.method == 'PUT' && path.startsWith('/api/records/')) {
        if (s.putStatus >= 400) {
          return _json({'detail': s.putDetail}, s.putStatus);
        }
        return _json(<String, Object>{});
      }
      if (o.method == 'DELETE' && path.startsWith('/api/records/')) {
        if (s.deleteStatus >= 400) {
          return _json({'detail': s.deleteDetail}, s.deleteStatus);
        }
        return _json(<String, Object>{});
      }
      if (o.method == 'POST' && path.endsWith('/restore')) {
        if (s.restoreStatus >= 400) {
          return _json({'detail': s.restoreDetail}, s.restoreStatus);
        }
        return _json(<String, Object>{});
      }
      return _json(<String, Object>{});
    });

Future<ProviderContainer> _setup(_FakeAdapter adapter,
    {String uid = 'u1', StateProvider<String>? uidProvider}) async {
  // 🔴 2.2.0 返修：夹具 Dio 必须与生产 buildDio **共用同一个 validateStatus**。
  // 旧夹具用 Dio 默认 <300，4xx 抛 DioException 恰好被 errorDetail 接住，
  // 掩盖了真机「4xx 作为成功 Response 返回、不抛异常」的形状（假通过根因）。
  final dio = Dio(BaseOptions(
    baseUrl: 'https://test.local',
    validateStatus: api.validateAppStatus,
  ))..httpClientAdapter = adapter;
  final container = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
    mediaCookieHeadersProvider
        .overrideWith((ref) async => <String, String>{}),
    // 🔴 纯 test() 里固定 uid：否则 personalCurrentUserProvider 依赖
    // authProvider 变化会让 Notifier 重建，旧 onDispose 把 _disposed 置
    // true，写操作静默 no-op（7-A 返修踩过的坑）。换号用例改用可变的
    // uidProvider，让 build() 的 _boundUserId 机制真正被触发。
    personalCurrentUserProvider.overrideWith(
        (ref) => uidProvider != null ? ref.watch(uidProvider) : uid),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// 用 GoRouter 承载个人角落（含 7-C 两条 push 路由），并复刻 main.dart 的
/// 顶部通知宿主，供「双呈现」断言同时检查表单内联与顶部通知。
Widget _app(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/personal',
          routes: [
            GoRoute(
                path: '/personal',
                builder: (_, _) => const PersonalPage()),
            GoRoute(
              path: '/personal/diary-form',
              builder: (_, state) {
                final extra = (state.extra as Map?) ?? const {};
                return DiaryFormPage(
                    record: extra['record'] as TogetherRecord?);
              },
            ),
            GoRoute(
              path: '/personal/publish',
              builder: (_, state) {
                final extra = (state.extra as Map?) ?? const {};
                return DraftPublishPage(
                    draft: extra['draft']! as TogetherRecord);
              },
            ),
            GoRoute(
              path: '/personal/surprise-form',
              builder: (_, state) {
                final extra = (state.extra as Map?) ?? const {};
                return SurpriseFormPage(
                    record: extra['record'] as TogetherRecord?);
              },
            ),
            GoRoute(
              path: '/personal/wish-form',
              builder: (_, _) => const PersonalWishFormPage(),
            ),
            GoRoute(
              path: '/personal/wish-unlock',
              builder: (_, state) {
                final extra = (state.extra as Map?) ?? const {};
                return PersonalWishUnlockPage(
                  rid: (extra['rid'] ?? '').toString(),
                  title: (extra['title'] ?? '').toString(),
                );
              },
            ),
          ],
        ),
        builder: (context, child) => Stack(children: [
          child ?? const SizedBox.shrink(),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
                child: SafeArea(child: ChatToastHost())),
          ),
        ]),
      ),
    );

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  // 大视口：让 5 个 tab 与列表页尾元素都落在可点击范围（仍配 scrollUntilVisible）
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(_app(container));
  await tester.pumpAndSettle();
}

/// toast 的 2.2s Timer 收尾冲洗
Future<void> _flush(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

Future<void> _openWishTab(WidgetTester tester) async {
  await tester.tap(find.text('个人心愿'));
  await tester.pumpAndSettle();
}

Future<void> _tapUnlockEntry(WidgetTester tester) async {
  final btn = find.text('输入密码查看').first;
  await tester.scrollUntilVisible(btn, 200,
          scrollable: find.byType(Scrollable).last);
  await tester.pumpAndSettle();
  await tester.tap(btn);
  await tester.pumpAndSettle();
}

void main() {
  // ── ① 三态渲染 + 隐私红线 ───────────────────────────────────────
  group('① 三态渲染（作者免密/已解锁/待解锁，content/sealed 不越界）', () {
    testWidgets('三种卡片视觉可辨；锁定态不渲染 content；sealed 等不渲染',
        (tester) async {
      final store = _Store();
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      await _pump(tester, container);
      await _openWishTab(tester);

      // 页头 / hint 逐字对齐 Web personalWishPage（app.js:1302）
      expect(find.text(personalWishSubtitle), findsOneWidget);
      expect(find.text(personalTabs[4].hint), findsOneWidget);
      expect(find.text('许下心愿'), findsOneWidget);

      // 三态：作者免密 1 张 + 对方 2 张（已解锁 / 待解锁）
      expect(find.text('你的个人心愿'), findsOneWidget);
      expect(find.text('TA的个人心愿'), findsNWidgets(2));
      expect(find.text('已解锁 · 内容只有你们两人能看见'), findsNWidgets(2));
      expect(find.text('具体内容已加密保存'), findsOneWidget);

      // 作者免密直达 / 对方已解锁：content 直接显示
      expect(find.text('想和你一起去看一次海'), findsOneWidget);
      expect(find.text('一起把家布置成想要的样子'), findsOneWidget);
      // 🔴 QA 最高风险项直接证据：author=u2（TA）的锁态心愿仍渲染，
      // 客户端绝不能按 author 把对方心愿过滤掉（否则静默空列表最难查）
      expect(find.text('回🏡了'), findsOneWidget,
          reason: '对方心愿的锁态标题必须显示（服务端 serialize 不 404）');
      expect(find.text('最想完成的事'), findsOneWidget);
      expect(find.text('一起布置未来的家'), findsOneWidget);
      // 待解锁：占位文案 + 入口按钮，且畸形注入的 content 绝不渲染
      expect(find.text('TA 留了一份心愿给你，输入一次密码后就能一直读到内容。'),
          findsOneWidget);
      expect(find.text('输入密码查看'), findsOneWidget);
      expect(find.text(_hostileContent), findsNothing,
          reason: '未解锁 content 不得出现在客户端任何地方');

      // 🔴 超出 Web 呈现范围的字段（作者额外下发的 sealed 密文 + 畸形 stored
      // 字段）一律不渲染、不缓存
      expect(find.text(_cipher), findsNothing);
      expect(find.text(_ownerCipher), findsNothing);
      expect(find.text(_hashValue), findsNothing);
      final bodies = container
          .read(personalControllerProvider)
          .wishes
          .map((r) => r.body)
          .toList();
      for (final b in bodies) {
        expect(b.keys.toSet(),
            everyElement(isIn(<String>{'title', 'locked', 'content'})),
            reason: '数据层 sanitizeWishBody 只留三键');
      }
      expect(jsonEncode(bodies).contains(_cipher), isFalse);
      expect(jsonEncode(bodies).contains(_ownerCipher), isFalse);
      expect(jsonEncode(bodies).contains(_lockedCipher), isFalse,
          reason: '作者退化锁定态也带 sealed，必须无条件净化');
      expect(jsonEncode(bodies).contains(_hashValue), isFalse);
      expect(jsonEncode(bodies).contains(_hostileContent), isFalse);
      final lockedBody =
          bodies.firstWhere((b) => b['locked'] == true);
      expect(lockedBody.containsKey('content'), isFalse);

      // 作者免密：作者卡片没有解锁入口，也不发任何 unlock 请求
      expect(store.unlockCalls, 0);
      expect(adapter.requests.where((r) => r.uri.path.endsWith('/unlock')),
          isEmpty);
      await _flush(tester);
    });

    test('sanitizeWishBody 纯函数：三键收敛、locked 丢 content、越界键全丢', () {
      final open = sanitizeWishBody({
        'title': 't',
        'locked': false,
        'content': 'c',
        'sealed': {'x': _cipher},
        'password_hash': _hashValue,
        'owner_sealed': {'x': _ownerCipher},
        'readers_sealed': {'u2': 'R'},
      });
      expect(open.keys.toSet(), {'title', 'locked', 'content'});
      expect(open['title'], 't');
      expect(open['locked'], false);
      expect(open['content'], 'c');
      expect(jsonEncode(open).contains(_cipher), isFalse);

      final locked = sanitizeWishBody({
        'title': 't2',
        'locked': true,
        'content': _hostileContent,
        'sealed': {'x': 'X'},
      });
      expect(locked.keys.toSet(), {'title', 'locked'});
      expect(locked['locked'], true);
      expect(jsonEncode(locked).contains(_hostileContent), isFalse);

      // 缺失 locked 时按锁定态处理（fail-closed）
      expect(sanitizeWishBody({'title': 'x'})['locked'], true);
    });

    test('作者退化锁定态（locked:true + sealed）仍无条件净化，净化不挂 open 分支',
        () {
      // serializers.py:33-34 open_sealed 抛异常 → 退化成 locked:true；
      // 但 :35-36 的 `if author:` **无条件**追加 sealed。QA 最高风险项：
      // 「只取三键」绝不能挂在 locked==false 分支上，必须在数据解析边界
      // 无条件过滤，否则退化态的密文会进缓存。
      final degraded = sanitizeWishBody({
        'title': '退化态',
        'locked': true,
        'content': _hostileContent,
        'sealed': {'ciphertext': _cipher},
        'owner_sealed': {'ciphertext': _ownerCipher},
        'password_hash': _hashValue,
        'readers_sealed': {'u2': 'READER_CIPHER'},
      });
      expect(degraded.keys.toSet(), {'title', 'locked'},
          reason: 'locked 态连 content 也不留');
      expect(degraded['locked'], true);
      expect(jsonEncode(degraded).contains(_cipher), isFalse);
      expect(jsonEncode(degraded).contains(_ownerCipher), isFalse);
      expect(jsonEncode(degraded).contains(_hashValue), isFalse);
      expect(jsonEncode(degraded).contains('READER_CIPHER'), isFalse);
      expect(jsonEncode(degraded).contains(_hostileContent), isFalse);
    });
  });

  // ── ② 双机全程 ─────────────────────────────────────────────────
  group('② 双机全程（我建 → 对象锁态 → 403 → 解锁 → 重拉 → 重进免密）', () {
    // 纯 test() 真实 async 区：FakeAsync 里对无 widget 树容器 await 控制器
    // 请求会挂起（历史坑），故用纯 test 且不调 bootstrap()。
    test('全程闭环：服务端记 readers，客户端重拉确认而非自记解锁态', () async {
      final store = _Store(wishes: <Object?>[]);
      store.onCreateSuccess = (body) {
        // 服务端创建成功后按作者态 serialize（content 明文 + sealed 密文）
        store.wishes = [
          _wishRec(
            id: 'w-new',
            author: 'u1',
            body: {
              'title': body['title'],
              'locked': false,
              'content': body['content'],
              'sealed': {'ciphertext': 'CIPHER'},
            },
          ),
        ];
      };
      final adapter = _adapterFor(store);

      // a) 我（u1）创建
      final a = await _setup(adapter, uid: 'u1');
      final e1 = await a
          .read(personalControllerProvider.notifier)
          .addPersonalWish('最想完成的事', '想和你一起去看一次海', '123456');
      expect(e1, isNull);
      expect(store.createCalls, 1);
      expect(store.createBodies.single['title'], '最想完成的事');
      expect(store.createBodies.single['content'], '想和你一起去看一次海');
      expect(store.createBodies.single['password'], '123456');
      expect(store.createBodies.single['client_id'], isNotEmpty);
      expect(
          adapter.requests,
          anyElement(predicate<RequestOptions>((r) =>
              r.method == 'POST' && r.uri.path == '/api/personal-wishes')));
      expect(a.read(personalControllerProvider).wishes.single.body['locked'],
          false);

      // b) 对象端（u2）：服务端按非作者 serialize → locked:true，content 不下发
      store.uid = 'u2';
      store.wishes = [
        _wishRec(
          id: 'w-new',
          author: 'u1',
          body: {'title': '最想完成的事', 'locked': true},
        ),
      ];
      final b = await _setup(adapter, uid: 'u2');
      final ctrlB = b.read(personalControllerProvider.notifier);
      await ctrlB.loadWishes();
      final lockedState = b.read(personalControllerProvider).wishes;
      expect(lockedState.single.body['locked'], true);
      expect(lockedState.single.body.containsKey('content'), isFalse);
      expect(jsonEncode(lockedState.map((r) => r.body).toList())
          .contains('想和你一起去看一次海'), isFalse,
          reason: '对方未解锁时 content 不下发，客户端也不缓存');

      // c) 错密码 → 403 原文原样回传
      store.unlockStatus = 403;
      store.unlockDetail = '密码不正确，请向心愿本人确认';
      final e2 = await ctrlB.unlockPersonalWish('w-new', '000000');
      expect(e2, '密码不正确，请向心愿本人确认');
      expect(store.unlockCalls, 1);
      expect(store.unlockBodies.single['password'], '000000');
      expect(
          adapter.requests,
          anyElement(predicate<RequestOptions>((r) =>
              r.method == 'POST' &&
              r.uri.path == '/api/personal-wishes/w-new/unlock')));

      // d) 对密码 → 服务端写 readers_sealed；客户端重拉确认状态
      store.unlockStatus = 200;
      store.unlockDetail = null;
      store.wishes = [
        _wishRec(
          id: 'w-new',
          author: 'u1',
          body: {
            'title': '最想完成的事',
            'locked': false,
            'content': '想和你一起去看一次海',
          },
        ),
      ];
      final e3 = await ctrlB.unlockPersonalWish('w-new', '123456');
      expect(e3, isNull);
      final unlocked = b.read(personalControllerProvider).wishes;
      expect(unlocked.single.body['locked'], false);
      expect(unlocked.single.body['content'], '想和你一起去看一次海');
      final wishGets = adapter.requests
          .where((r) =>
              r.method == 'GET' &&
              r.uri.path == '/api/records' &&
              r.queryParameters['kind'] == personalWishKinds)
          .length;
      expect(wishGets, greaterThanOrEqualTo(2),
          reason: '解锁成功后必须重拉列表确认状态，不自记解锁态');

      // e) 退出重进：新建容器（新会话）仍免密，不发任何 unlock 请求
      final callsBefore = store.unlockCalls;
      final c = await _setup(adapter, uid: 'u2');
      await c.read(personalControllerProvider.notifier).loadWishes();
      final again = c.read(personalControllerProvider).wishes;
      expect(again.single.body['locked'], false);
      expect(again.single.body['content'], '想和你一起去看一次海');
      expect(store.unlockCalls, callsBefore,
          reason: '退出重进仍免密，客户端不凭本地缓存也不重复解锁');
    });
  });

  // ── ③ 撞密码 422 双呈现 ─────────────────────────────────────────
  group('③ 第二条心愿复用同密码 → 422 原文双呈现', () {
    test('控制器：422 原文一字不差回传（api.errorDetail 取 detail）', () async {
      final store = _Store();
      store.createStatus = 422;
      store.createDetail = '这个密码已经用于另一条个人心愿，请为每条心愿设置不同密码';
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      final err = await container
          .read(personalControllerProvider.notifier)
          .addPersonalWish('另一份心愿', '另一份内容', '123456');
      expect(err, '这个密码已经用于另一条个人心愿，请为每条心愿设置不同密码');
      expect(store.createCalls, 1);
    });

    testWidgets('表单内联 + 顶部通知同句呈现，tone=error，绝不吞',
        (tester) async {
      final store = _Store();
      store.createStatus = 422;
      store.createDetail = '这个密码已经用于另一条个人心愿，请为每条心愿设置不同密码';
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      await _pump(tester, container);
      await _openWishTab(tester);
      await tester.tap(find.text('许下心愿'));
      await tester.pumpAndSettle();
      expect(find.text('许下一份个人心愿'), findsOneWidget);
      expect(find.text('心愿名称（对方可见）'), findsOneWidget);
      expect(find.text('具体心愿内容（需要密码才能查看）'), findsOneWidget);
      expect(find.text('这条心愿的独立密码'), findsOneWidget);
      expect(find.text('加密保存'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(0), '另一份心愿');
      await tester.enterText(find.byType(TextField).at(1), '另一份内容');
      await tester.enterText(find.byType(TextField).at(2), '123456');
      await tester.tap(find.text('加密保存'));
      await tester.pumpAndSettle();

      expect(store.createCalls, 1);
      expect(find.text(store.createDetail!).evaluate().length,
          greaterThanOrEqualTo(2),
          reason: '表单内联 + 顶部通知双呈现');
      expect(container.read(chatToastProvider)?.text, store.createDetail);
      expect(container.read(chatToastProvider)?.tone, ChatToastTone.error);
      await _flush(tester);
    });

    test('客户端先拦空 + 拦 Field 越界：所有 Pydantic 数组型 422 都不发请求',
        () async {
      final store = _Store();
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      final ctrl = container.read(personalControllerProvider.notifier);

      expect(await ctrl.addPersonalWish('', '内容', '123456'),
          '请填写心愿名称、具体内容和独立密码');
      expect(await ctrl.addPersonalWish('标题', '', '123456'),
          '请填写心愿名称、具体内容和独立密码');
      expect(await ctrl.addPersonalWish('标题', '内容', '   '),
          '请填写心愿名称、具体内容和独立密码');
      expect(await ctrl.addPersonalWish('标题', '内容', '12345'),
          '密码至少 6 位（建议纯数字）');
      // 🔴 QA 增量：main.py:914-918 的 Pydantic Field(min/max) 越界时 detail
      // 是英文数组，api.errorDetail 会 toString 成一坨英文结构化文本。客户端
      // 必须在发请求前挡住 title>100 / content>20000 / password>128，保证
      // 服务端只回手动抛的中文原文，才能原样透传给 UI 双呈现。
      expect(await ctrl.addPersonalWish('x' * 101, '内容', '123456'),
          '心愿名称最多 100 字');
      expect(await ctrl.addPersonalWish('标题', 'x' * 20001, '123456'),
          '具体心愿内容最多 20000 字');
      expect(await ctrl.addPersonalWish('标题', '内容', 'x' * 129),
          '密码最多 128 位');
      expect(store.createCalls, 0, reason: '不合法输入一律不发请求');
      expect(adapter.requests.where((r) => r.method == 'POST'), isEmpty,
          reason: '绝不制造 Field 校验型 422（英文数组 detail）');
    });
  });

  // ── ④ 429 限速原文 ──────────────────────────────────────────────
  group('④ 429 限速原文（security.py:193-206, limit=20/window=900）', () {
    test('控制器：429「尝试过于频繁，请 15 分钟后再试」原文回传', () async {
      final store = _Store();
      store.unlockStatus = 429;
      store.unlockDetail = '尝试过于频繁，请 15 分钟后再试';
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      final err = await container
          .read(personalControllerProvider.notifier)
          .unlockPersonalWish('w1', '000000');
      expect(err, '尝试过于频繁，请 15 分钟后再试');
      expect(store.unlockCalls, 1, reason: '不自动重试');
      // QA 实读：首错即计数、前 20 次错密码都是 403，第 21 次才转 429；
      // rate_limit key = 'personal-wish-unlock:{rid}:{uid}' + client_ip，
      // 每条心愿每人独立配额。客户端不模拟计数，只如实呈现服务端码与原文。
    });

    test('解锁页只拦空、不套创建页 ≥6（UnlockInput min_length=1）', () async {
      final store = _Store();
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      final ctrl = container.read(personalControllerProvider.notifier);
      expect(await ctrl.unlockPersonalWish('w1', ''), '请输入心愿密码');
      expect(store.unlockCalls, 0, reason: '空密码不发请求');
      // 5 位短密码对解锁合法（main.py:921-922 min_length=1，不是 6），
      // 绝不套创建页校验，否则会拦掉合法短密码。
      expect(await ctrl.unlockPersonalWish('w1', '12345'), isNull);
      expect(store.unlockCalls, 1);
      expect(store.unlockBodies.single['password'], '12345');
    });

    testWidgets('429 原文表单内联 + 顶部通知双呈现', (tester) async {
      final store = _Store();
      store.unlockStatus = 429;
      store.unlockDetail = '尝试过于频繁，请 15 分钟后再试';
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      await _pump(tester, container);
      await _openWishTab(tester);
      await _tapUnlockEntry(tester);
      expect(find.text('打开这份个人心愿'), findsOneWidget);
      expect(find.text('「回🏡了」的内容已加密，请输入心愿本人交给你的密码。'),
          findsOneWidget);
      expect(find.text('心愿密码'), findsOneWidget);
      expect(find.text('解锁心愿'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '000000');
      await tester.tap(find.text('解锁心愿'));
      await tester.pumpAndSettle();
      expect(store.unlockCalls, 1);
      expect(find.text(store.unlockDetail!).evaluate().length,
          greaterThanOrEqualTo(2));
      expect(container.read(chatToastProvider)?.text, store.unlockDetail);
      expect(container.read(chatToastProvider)?.tone, ChatToastTone.error);
      await _flush(tester);
    });
  });

  // ── ⑤ 换号不串 ──────────────────────────────────────────────────
  group('⑤ 换号不串（wishes 与解锁态只属新账号）', () {
    test('uid 变化触发 _boundUserId：旧账号解锁明文不残留', () async {
      final uidProvider = StateProvider<String>((ref) => 'u1');
      final store = _Store(wishes: [_authorWish]);
      final adapter = _adapterFor(store);
      final c = await _setup(adapter, uidProvider: uidProvider);
      await c.read(personalControllerProvider.notifier).loadWishes();
      expect(c.read(personalControllerProvider).wishes.single.body['locked'],
          false);
      expect(
          c.read(personalControllerProvider).wishes.single.body['content'],
          '想和你一起去看一次海');

      // 换号：服务端按新 uid 重新 serialize → 对方未解锁 locked:true
      store.uid = 'u2';
      store.wishes = [
        _wishRec(
          id: 'b2c7d2a1f5b344dfabbf50c8d96c1fb3',
          author: 'u1',
          body: {'title': '最想完成的事', 'locked': true},
        ),
      ];
      c.read(uidProvider.notifier).state = 'u2';
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // 🔴 关键：换号瞬间 state 里绝不能残留旧账号的解锁明文。
      // 实读行为：personalCurrentUserProvider 变化 → Riverpod 用新实例 rebuild
      // Notifier，build() 直接返回 const PersonalState()（wishes 归零，
      // fail-closed）；重拉由页面重进的 bootstrap()/loadWishes() 完成。
      final noLeak = c.read(personalControllerProvider).wishes;
      expect(
          jsonEncode(noLeak.map((r) => r.body).toList())
              .contains('想和你一起去看一次海'),
          isFalse,
          reason: '解锁态与明文只属旧账号，绝不串到新账号');

      // 页面重进：按新账号重拉，拿到服务端对新 uid 的锁态序列化形状
      await c.read(personalControllerProvider.notifier).loadWishes();
      final after = c.read(personalControllerProvider).wishes;
      expect(after, isNotEmpty, reason: '重进后重拉，不是旧账号缓存');
      expect(after.length, 1);
      expect(after.single.body['locked'], true);
      expect(after.single.body.containsKey('content'), isFalse);
      expect(
          jsonEncode(after.map((r) => r.body).toList())
              .contains('想和你一起去看一次海'),
          isFalse);
      final wishGets = adapter.requests
          .where((r) =>
              r.method == 'GET' &&
              r.uri.path == '/api/records' &&
              r.queryParameters['kind'] == personalWishKinds)
          .length;
      expect(wishGets, greaterThanOrEqualTo(2), reason: '换号后重拉 wishes');
    });

    test('uid 为空时 wishes fail-closed（不渲染任何内容）', () async {
      final store = _Store();
      store.uid = ''; // /api/me 也返回空 user.id，杜绝兜底放行
      final adapter = _adapterFor(store);
      final c = await _setup(adapter, uid: '');
      final ctrl = c.read(personalControllerProvider.notifier);
      await ctrl.loadWishes();
      expect(c.read(personalControllerProvider).wishes, isEmpty);
      expect(ctrl.wishes(), isEmpty,
          reason: 'personal_wish 与 PRIVATE 不同，但登录态未落定仍不渲染');
    });

    test('logout() 的 invalidate 覆盖 wishes：作废后三路 state 全清', () async {
      final store = _Store();
      final adapter = _adapterFor(store);
      final c = await _setup(adapter);
      final ctrl = c.read(personalControllerProvider.notifier);
      await ctrl.load();
      await ctrl.loadTrash();
      await ctrl.loadWishes();
      expect(c.read(personalControllerProvider).wishes, isNotEmpty);
      // auth_state.dart logout() 走 ref.container.invalidate(personalControllerProvider)
      c.invalidate(personalControllerProvider);
      final fresh = c.read(personalControllerProvider);
      expect(fresh.wishes, isEmpty);
      expect(fresh.records, isEmpty);
      expect(fresh.trash, isEmpty);
    });
  });

  // ── ⑥ 请求中按钮禁用 / 不连点叠加 / 不自动重试 ────────────────────
  group('⑥ 请求中按钮禁用 + 不连点叠加（只发 1 次 unlock）', () {
    testWidgets('gate 挂起请求：按钮 disabled、连点无效、403 后不重试',
        (tester) async {
      final store = _Store();
      final gate = Completer<ResponseBody>();
      store.unlockGate = gate;
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      await _pump(tester, container);
      await _openWishTab(tester);
      await _tapUnlockEntry(tester);
      await tester.enterText(find.byType(TextField).first, '000000');
      await tester.tap(find.text('解锁心愿'));
      await tester.pumpAndSettle();

      expect(store.unlockCalls, 1);
      final btn = find.byType(FilledButton);
      expect(tester.widget<FilledButton>(btn).onPressed, isNull,
          reason: '请求中按钮禁用');
      expect(find.text('解锁中…'), findsOneWidget);

      // 连点第二下：禁用按钮不再回调
      await tester.tap(btn);
      await tester.pumpAndSettle();
      expect(store.unlockCalls, 1, reason: '不连点叠加请求');

      // 以 403 收尾：客户端不自动重试
      gate.complete(_json({'detail': '密码不正确，请向心愿本人确认'}, 403));
      await tester.pumpAndSettle();
      expect(store.unlockCalls, 1, reason: '错密码不自动重试');
      expect(find.text('密码不正确，请向心愿本人确认').evaluate().length,
          greaterThanOrEqualTo(2));
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNotNull, reason: '结束后按钮恢复可用');
      await _flush(tester);
    });
  });

  // ── ⑦ 密码不落本地 ──────────────────────────────────────────────
  group('⑦ 密码只在请求里过一遍（无持久化 / 无日志 / 无缓存）', () {
    test('创建+解锁密码只出现在两个 POST 体；state/GET/日志一律不含', () async {
      final store = _Store(wishes: <Object?>[]);
      final adapter = _adapterFor(store);
      final c = await _setup(adapter);
      final logs = <String>[];
      await runZoned(() async {
        final ctrl = c.read(personalControllerProvider.notifier);
        expect(
            await ctrl.addPersonalWish('心愿A', '内容A', 'PW_CREATE_654321'),
            isNull);
        expect(await ctrl.unlockPersonalWish('w-x', 'PW_UNLOCK_654321'),
            isNull);
      },
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => logs.add(line),
          ));

      final dump = logs.join('\n');
      expect(dump.contains('PW_CREATE_654321'), isFalse,
          reason: '密码不进日志');
      expect(dump.contains('PW_UNLOCK_654321'), isFalse);

      final posts = adapter.requests
          .where((r) => r.method == 'POST')
          .toList();
      expect(posts.length, 2);
      expect((posts[0].data as Map)['password'], 'PW_CREATE_654321');
      expect((posts[1].data as Map)['password'], 'PW_UNLOCK_654321');
      for (final r in adapter.requests.where((r) => r.method != 'POST')) {
        expect(r.uri.toString().contains('PW_CREATE_654321'), isFalse);
        expect(r.uri.toString().contains('PW_UNLOCK_654321'), isFalse);
        expect(r.queryParameters.toString().contains('PW_CREATE_654321'),
            isFalse);
        expect(r.queryParameters.toString().contains('PW_UNLOCK_654321'),
            isFalse);
      }
      final st = c.read(personalControllerProvider);
      final stateDump = jsonEncode([
        ...st.wishes.map((r) => r.body),
        ...st.records.map((r) => r.body),
        ...st.trash.map((r) => r.body),
      ]);
      expect(stateDump.contains('PW_CREATE_654321'), isFalse,
          reason: '不落任何本地缓存/state');
      expect(stateDump.contains('PW_UNLOCK_654321'), isFalse);
    });
  });

  // ── ⑧ 返回路径 ──────────────────────────────────────────────────
  group('⑧ 返回路径（按钮 + 系统手势 handlePopRoute）', () {
    testWidgets('创建页 / 解锁页两条 push 路由都可返回上一页', (tester) async {
      final store = _Store();
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      await _pump(tester, container);
      await _openWishTab(tester);

      // 创建页：系统手势
      await tester.tap(find.text('许下心愿'));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('我的小角落'), findsOneWidget);
      expect(find.text('心愿名称（对方可见）'), findsNothing);

      // 创建页：AppBar 返回按钮
      await tester.tap(find.text('许下心愿'));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('我的小角落'), findsOneWidget);

      // 解锁页：系统手势
      await _tapUnlockEntry(tester);
      expect(find.text('打开这份个人心愿'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('我的小角落'), findsOneWidget);

      // 解锁页：AppBar 返回按钮
      await _tapUnlockEntry(tester);
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('我的小角落'), findsOneWidget);
      await _flush(tester);
    });
  });

  // ── ⑨ 删除 ──────────────────────────────────────────────────────
  group('⑨ 删除：通用 DELETE + 标准文案 + 重拉 wishes/trash', () {
    testWidgets('仅作者卡片有删除；确认弹层标准文案；DELETE /api/records/{rid}',
        (tester) async {
      final store = _Store();
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      await _pump(tester, container);
      await _openWishTab(tester);

      final del = find.byTooltip('删除心愿');
      expect(del, findsOneWidget, reason: '仅作者卡片有删除菜单');
      await tester.scrollUntilVisible(del, 200,
          scrollable: find.byType(Scrollable).last);
      await tester.pumpAndSettle();
      await tester.tap(del);
      await tester.pumpAndSettle();
      expect(find.text(privateDeleteText), findsOneWidget);
      expect(find.text('删除后会进入回收站，30 天内可以恢复。'), findsOneWidget);
      expect(find.textContaining('不进回收站'), findsNothing);
      expect(find.textContaining('不可恢复'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(
          adapter.requests,
          anyElement(predicate<RequestOptions>((r) =>
              r.method == 'DELETE' &&
              r.uri.path ==
                  '/api/records/b2c7d2a1f5b344dfabbf50c8d96c1fb3')),
          reason: 'Web app.js:2523 走通用 del("/records/"+id)');
      final wishGets = adapter.requests
          .where((r) =>
              r.method == 'GET' &&
              r.uri.path == '/api/records' &&
              r.queryParameters['kind'] == personalWishKinds)
          .length;
      expect(wishGets, greaterThanOrEqualTo(2), reason: '成功后重拉 wishes');
      expect(
          adapter.requests,
          anyElement(predicate<RequestOptions>((r) =>
              r.method == 'GET' &&
              r.uri.path == '/api/records' &&
              (r.queryParameters['trash'] == true ||
                  r.queryParameters['trash'] == 'true'))),
          reason: '成功后重拉 trash');
      await _flush(tester);
    });

    test('deleteWish 控制器：DELETE 后返回 null（无错误）', () async {
      final store = _Store();
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      final err = await container
          .read(personalControllerProvider.notifier)
          .deleteWish('w1');
      expect(err, isNull);
      expect(
          adapter.requests,
          anyElement(predicate<RequestOptions>((r) =>
              r.method == 'DELETE' && r.uri.path == '/api/records/w1')));
    });
  });

  // ── ⑩ Web 无编辑 / 无彻底删除 ────────────────────────────────────
  group('⑩ Web 无编辑 / 无彻底删除（App 不自创）', () {
    testWidgets('心愿卡片无编辑入口、无彻底删除、不发 PUT', (tester) async {
      final store = _Store();
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      await _pump(tester, container);
      await _openWishTab(tester);
      expect(find.byTooltip('编辑心愿'), findsNothing);
      expect(find.text('编辑心愿'), findsNothing);
      expect(find.textContaining('彻底删除'), findsNothing);
      expect(adapter.requests.where((r) => r.method == 'PUT'), isEmpty,
          reason: 'clean_body 对 personal_wish 明确 422，禁止 PUT 改');
      expect(find.byTooltip('删除心愿'), findsOneWidget);
      await _flush(tester);
    });
  });

  // ── ⑪ 4→5 tab / 无死卡 ──────────────────────────────────────────
  group('⑪ 4→5 tab、无 7-D 死卡', () {
    testWidgets('personalTabs 恰 5 项，IndexedStack 恰 5 页，无多余空卡',
        (tester) async {
      final store = _Store();
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      await _pump(tester, container);

      expect(personalTabs.length, 5);
      expect(personalTabs.map((t) => t.id).toList(),
          ['diary', 'draft', 'surprise', 'trash', 'personal_wish']);
      expect(
          personalTabs.every((t) => t.label.isNotEmpty && t.hint.isNotEmpty),
          isTrue, reason: '每项都有去向，无死卡');
      expect(find.text('个人心愿'), findsOneWidget); // tab 标签
      expect(
          tester
              .widget<IndexedStack>(find.byType(IndexedStack).first)
              .children
              .length,
          5,
          reason: '可扩展表与 IndexedStack 常驻页一一对应');
      await _openWishTab(tester);
      expect(find.text(personalTabs[4].hint), findsOneWidget);
      expect(find.text('许下心愿'), findsOneWidget);
      await _flush(tester);
    });
  });

  // ── ⑫ 显式 kind 串 ──────────────────────────────────────────────
  group('⑫ 请求 kind 串 personal_wish 显式断言', () {
    testWidgets('GET /api/records?kind=personal_wish&limit=1000，绝不带 author',
        (tester) async {
      final store = _Store();
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      await _pump(tester, container);

      final wishGets = adapter.requests
          .where((r) =>
              r.method == 'GET' &&
              r.uri.path == '/api/records' &&
              r.queryParameters['kind'] == personalWishKinds)
          .toList();
      expect(wishGets, isNotEmpty);
      for (final r in wishGets) {
        expect(r.queryParameters['limit'], 1000);
        expect(r.queryParameters.containsKey('author'), isFalse,
            reason: '带 author 会按作者过滤掉对方心愿（双方都要显示锁态标题）');
        expect(r.queryParameters['trash'], isNot(true));
      }
      expect(personalWishKinds, 'personal_wish');
      expect(personalKinds, 'diary,draft,surprise');
      expect(personalKinds.split(',').contains('personal_wish'), isFalse,
          reason: '绝不复用 personalKinds（PRIVATE 三类）');
      await _flush(tester);
    });

    test('loadWishes 不按 author 过滤：作者与对方心愿都在 state、请求无 author 键',
        () async {
      final store = _Store(); // u1 作者态 + u2 锁态 + u2 已解锁
      final adapter = _adapterFor(store);
      final c = await _setup(adapter);
      await c.read(personalControllerProvider.notifier).loadWishes();
      final list = c.read(personalControllerProvider).wishes;
      expect(list.length, 3);
      expect(list.map((r) => r.author).toSet(),
          containsAll(<String>['u1', 'u2']));
      expect(list.where((r) => r.author == 'u2').length, 2,
          reason: '对方的两条心愿（锁态 + 已解锁）都必须保留');
      final wishGets = adapter.requests.where((r) =>
          r.method == 'GET' &&
          r.uri.path == '/api/records' &&
          r.queryParameters['kind'] == personalWishKinds);
      expect(wishGets, isNotEmpty);
      for (final r in wishGets) {
        expect(r.queryParameters.containsKey('author'), isFalse,
            reason: 'main.py:1175-1177 的 author=? 会在 SQL 层排除对方心愿');
      }
      // 与 7-B load() 对照：主列表带 author + 二次按 author 过滤，
      // wishes 绝不能复用（personal_wish 不在 db.PRIVATE，db.visible 双方 True）
      expect(personalKinds, 'diary,draft,surprise');
    });
  });

  // ── ⑬ 2.2.0 真机阻断级返修：真实 4xx Response 形状 + 双条件门控 ──
  group('⑬ 真实 4xx Response 形状（validateStatus: s<500 放行，不抛异常）', () {
    // 逐字引用主理人真实 HTTP 取证（隔离 DATA_DIR + 真实 uvicorn + httpx）：
    const wrongPwDetail = '密码不正确，请向心愿本人确认';
    const rateLimitDetail = '尝试过于频繁，请 15 分钟后再试';
    const okMsg = '已解锁，内容现在直接显示在心愿卡片里';
    const lockedRid = '9ce5acfad9e04baaa8d5bdb50bb70a0f';

    test('夹具自检：403/429 在 s<500 下确为「成功返回的 Response」，不抛异常',
        () async {
      // 若 403/429 抛 DioException，await 会直接抛出使用例失败 →
      // 直接证明夹具与真机形状一致（7-C 旧夹具的 <300 形状会在这里露馅）。
      final adapter = _FakeAdapter((o, i) async => _json(
          {'detail': i == 0 ? wrongPwDetail : rateLimitDetail},
          i == 0 ? 403 : 429));
      final dio = Dio(BaseOptions(
        baseUrl: 'https://test.local',
        validateStatus: api.validateAppStatus,
      ))..httpClientAdapter = adapter;
      final r403 = await dio.post('/api/personal-wishes/w1/unlock',
          data: {'password': 'wrong-999'});
      expect(r403.statusCode, 403);
      expect((r403.data as Map)['detail'], wrongPwDetail);
      expect(api.writeResponseError(r403), wrongPwDetail,
          reason: 'writeResponseError 从成功返回的 4xx 里取服务端原文');
      final r429 = await dio.post('/api/personal-wishes/w1/unlock',
          data: {'password': 'wrong-999'});
      expect(r429.statusCode, 429);
      expect((r429.data as Map)['detail'], rateLimitDetail);
      expect(api.writeResponseError(r429), rateLimitDetail);
      // 对照：4xx 不是 DioException，errorDetail 只能给兜底文案 →
      // 这正是不能用 errorDetail 处理放行 4xx 的原因。
      expect(api.errorDetail('anything'), api.genericErrorText);
    });

    testWidgets(
        '① 错密码 403 → 不发成功通知、顶部+内联为服务端原文、密码框保留、卡片仍 locked',
        (tester) async {
      final store = _Store();
      store.unlockStatus = 403;
      store.unlockDetail = wrongPwDetail;
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      await _pump(tester, container);
      await _openWishTab(tester);
      await _tapUnlockEntry(tester);
      await tester.enterText(find.byType(TextField).first, 'wrong-999');
      await tester.tap(find.text('解锁心愿'));
      await tester.pumpAndSettle();

      expect(store.unlockCalls, 1, reason: '403 不自动重试');
      expect(
          adapter.requests
              .where((r) => r.uri.path.endsWith('/unlock'))
              .length,
          1);
      // 服务端原文逐字：表单内联 + 顶部通知双呈现
      expect(find.text(wrongPwDetail).evaluate().length,
          greaterThanOrEqualTo(2));
      expect(container.read(chatToastProvider)?.text, wrongPwDetail);
      expect(container.read(chatToastProvider)?.tone, ChatToastTone.error);
      // 真机现象的反面：绝不发成功通知
      expect(find.text(okMsg), findsNothing);
      expect(container.read(chatToastProvider)?.tone,
          isNot(ChatToastTone.success));
      // 密码框保留可重输、不 pop、按钮恢复可用
      expect(find.text('打开这份个人心愿'), findsOneWidget,
          reason: '失败不 pop');
      final tf = tester.widget<TextField>(find.byType(TextField).first);
      expect(tf.controller?.text, 'wrong-999', reason: '密码框保留可重输');
      expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNotNull,
          reason: '按钮恢复可用，不禁用');
      // 卡片保持锁定态：失败不重拉、不自记解锁态、不缓存 content
      final wish = container
          .read(personalControllerProvider)
          .wishes
          .firstWhere((w) => w.id == lockedRid);
      expect(wish.body['locked'], true);
      expect(wish.body.containsKey('content'), isFalse);
      await _flush(tester);
    });

    testWidgets('② 429 限速 → 同上且不自动重试、请求恰好 1 次', (tester) async {
      final store = _Store();
      store.unlockStatus = 429;
      store.unlockDetail = rateLimitDetail;
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      await _pump(tester, container);
      await _openWishTab(tester);
      await _tapUnlockEntry(tester);
      await tester.enterText(find.byType(TextField).first, 'wrong-999');
      await tester.tap(find.text('解锁心愿'));
      await tester.pumpAndSettle();

      expect(store.unlockCalls, 1);
      expect(
          adapter.requests
              .where((r) => r.uri.path.endsWith('/unlock'))
              .length,
          1,
          reason: '429 配额敏感，请求恰好 1 次，绝不自动重试');
      expect(find.text(rateLimitDetail).evaluate().length,
          greaterThanOrEqualTo(2));
      expect(container.read(chatToastProvider)?.text, rateLimitDetail);
      expect(container.read(chatToastProvider)?.tone, ChatToastTone.error);
      expect(find.text(okMsg), findsNothing);
      expect(find.text('打开这份个人心愿'), findsOneWidget);
      final tf = tester.widget<TextField>(find.byType(TextField).first);
      expect(tf.controller?.text, 'wrong-999', reason: '密码框保留');
      final wish = container
          .read(personalControllerProvider)
          .wishes
          .firstWhere((w) => w.id == lockedRid);
      expect(wish.body['locked'], true);
      await _flush(tester);
    });

    testWidgets(
        '③ 正确密码 200 {"content":"..."} + 重拉 locked=false → 才发成功通知',
        (tester) async {
      final store = _Store(); // 200 + 服务端写 readers_sealed
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      await _pump(tester, container);
      await _openWishTab(tester);
      await _tapUnlockEntry(tester);
      await tester.enterText(find.byType(TextField).first, '123456');
      await tester.tap(find.text('解锁心愿'));
      await tester.pumpAndSettle();

      expect(store.unlockCalls, 1);
      expect(container.read(chatToastProvider)?.text, okMsg);
      expect(container.read(chatToastProvider)?.tone, ChatToastTone.success);
      expect(find.text(okMsg), findsOneWidget);
      expect(find.text('打开这份个人心愿'), findsNothing,
          reason: '成功后 pop 回列表');
      final wish = container
          .read(personalControllerProvider)
          .wishes
          .firstWhere((w) => w.id == lockedRid);
      expect(wish.body['locked'], false);
      // 客户端不自记解锁态：成功后必须重拉列表确认
      final wishGets = adapter.requests
          .where((r) =>
              r.method == 'GET' &&
              r.uri.path == '/api/records' &&
              r.queryParameters['kind'] == personalWishKinds)
          .length;
      expect(wishGets, greaterThanOrEqualTo(2));
      await _flush(tester);
    });

    testWidgets('④ 200 但重拉后仍 locked=true → 不发成功通知、走失败分支',
        (tester) async {
      final store = _Store();
      store.unlockWritesReaders = false; // 服务端异常：没写 readers_sealed
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      await _pump(tester, container);
      await _openWishTab(tester);
      await _tapUnlockEntry(tester);
      await tester.enterText(find.byType(TextField).first, '123456');
      await tester.tap(find.text('解锁心愿'));
      await tester.pumpAndSettle();

      expect(store.unlockCalls, 1);
      expect(find.text(okMsg), findsNothing, reason: '双条件门控拦住成功通知');
      expect(container.read(chatToastProvider)?.tone, ChatToastTone.error);
      expect(container.read(chatToastProvider)?.text,
          unlockNotEffectiveText);
      expect(find.text(unlockNotEffectiveText).evaluate().length,
          greaterThanOrEqualTo(2), reason: '顶部+内联双呈现');
      expect(find.text('打开这份个人心愿'), findsOneWidget,
          reason: '门控不通过不 pop');
      final tf = tester.widget<TextField>(find.byType(TextField).first);
      expect(tf.controller?.text, '123456', reason: '密码框保留可重输');
      final wish = container
          .read(personalControllerProvider)
          .wishes
          .firstWhere((w) => w.id == lockedRid);
      expect(wish.body['locked'], true, reason: '卡片保持锁定态');
      await _flush(tester);
    });

    test('④b 200 但响应体无 content → 门控条件①不通过，不重拉、不发成功通知',
        () async {
      final store = _Store();
      store.unlockReturnsContent = false;
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      final err = await container
          .read(personalControllerProvider.notifier)
          .unlockPersonalWish('w1', '123456');
      expect(err, unlockNotEffectiveText);
      expect(store.unlockCalls, 1);
      final wishGets = adapter.requests
          .where((r) =>
              r.method == 'GET' &&
              r.uri.path == '/api/records' &&
              r.queryParameters['kind'] == personalWishKinds)
          .length;
      expect(wishGets, 0, reason: '条件①不通过不重拉列表');
    });

    testWidgets('⑤ client_id 表单内失败重试复用同值（Web app.js:1801 对齐）',
        (tester) async {
      final store = _Store();
      store.createStatus = 422;
      store.createDetail = '这个密码已经用于另一条个人心愿，请为每条心愿设置不同密码';
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      await _pump(tester, container);
      await _openWishTab(tester);
      await tester.tap(find.text('许下心愿'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '心愿甲');
      await tester.enterText(find.byType(TextField).at(1), '内容甲');
      await tester.enterText(find.byType(TextField).at(2), '123456');
      await tester.tap(find.text('加密保存'));
      await tester.pumpAndSettle();
      expect(store.createCalls, 1);
      expect(find.text('许下一份个人心愿'), findsOneWidget,
          reason: '422 失败不 pop，表单 State 存活');
      // 同一表单 State 内第二次提交：client_id 必须复用
      await tester.tap(find.text('加密保存'));
      await tester.pumpAndSettle();
      expect(store.createCalls, 2);
      expect(store.createBodies.length, 2);
      final first = store.createBodies[0]['client_id'];
      final second = store.createBodies[1]['client_id'];
      expect(first, isNotEmpty);
      expect(second, first,
          reason: '表单生命周期内失败重试复用同一个 client_id');
      expect(find.text('这份个人心愿已加密保存'), findsNothing,
          reason: '422 绝不弹成功通知');
      await _flush(tester);
    });

    test('⑥ 连带核查：personal 其余写路径 4xx 同样返回服务端原文（不当成功）',
        () async {
      final store = _Store();
      store.createStatus = 422;
      store.createDetail = '撞密码原文';
      store.unlockStatus = 403;
      store.unlockDetail = wrongPwDetail;
      store.recordsPostStatus = 422;
      store.recordsPostDetail = '请选择未来的公开时间';
      store.putStatus = 422;
      store.putDetail = '编辑被拒原文';
      store.deleteStatus = 403;
      store.deleteDetail = '删除被拒原文';
      store.restoreStatus = 404;
      store.restoreDetail = '恢复被拒原文';
      final adapter = _adapterFor(store);
      final container = await _setup(adapter);
      final ctrl = container.read(personalControllerProvider.notifier);
      final future = DateTime.now().add(const Duration(days: 1));
      final rec = TogetherRecord(
        id: 'r1',
        kind: 'diary',
        author: 'u1',
        body: <String, dynamic>{'content': '原文', 'date': '2026-01-01'},
      );
      final draft = TogetherRecord(
        id: 'd1',
        kind: 'draft',
        author: 'u1',
        body: <String, dynamic>{'content': '草稿'},
      );

      // 10 条写路径逐条验证：4xx 一律 detail 原文，绝不 return null=成功
      expect(await ctrl.addPersonalWish('标题', '内容', '123456'), '撞密码原文');
      expect(await ctrl.unlockPersonalWish('w1', '000000'), wrongPwDetail);
      expect(await ctrl.addSurprise('服务端会拒的惊喜', future),
          '请选择未来的公开时间');
      expect(await ctrl.addDiary('日记'), '请选择未来的公开时间');
      expect(await ctrl.editSurprise(rec, '改', future), '编辑被拒原文');
      expect(await ctrl.editDiary(rec, '改'), '编辑被拒原文');
      expect(await ctrl.publishDraft(draft, 'diary'), '编辑被拒原文');
      expect(await ctrl.delete('r1'), '删除被拒原文');
      expect(await ctrl.deleteWish('w1'), '删除被拒原文');
      expect(await ctrl.restore('r1'), '恢复被拒原文');
      // 失败路径不应触发任何成功后的重拉（列表 GET）
      final listGets = adapter.requests
          .where((r) => r.method == 'GET' && r.uri.path == '/api/records')
          .length;
      expect(listGets, 0, reason: '4xx 不当成功，不重拉列表、不改本地 state');
    });
  });
}
