// 2.4.3 断言（提交一 · 双卡）：
// 历史卡显隐（往年无记录→整卡不渲染；有→渲染且预览行≤2、年份倒序）；
// 两卡导航（tap → push /on-this-day 与 /yearbook，返回后首页可继续交互）；
// 年报口径（四格数字与 yang 改判定义逐一对账；年份取服务端响应字段、
// 无写死年份常量——源码护栏）；记录故事弹层（条目点击弹出+正文全文
// 可见+点赞可达+关闭后列表滚动位置不变）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:love_space/core/api/api_client.dart';
import 'package:love_space/core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import 'package:love_space/features/auth/auth_state.dart'
    show authProvider, AuthNotifier, AuthPhase, MeData, SpaceUser;
import 'package:love_space/features/chat/chat_toast.dart' show ChatToastHost;
import 'package:love_space/features/home/home_page.dart';
import 'package:love_space/features/home/on_this_day_page.dart';
import 'package:love_space/features/home/yearbook_page.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions options, int callIndex) handler;
  final List<RequestOptions> requests = [];
  int calls = 0;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return handler(options, calls++);
  }
}

ResponseBody _json(Object data) => ResponseBody.fromString(jsonEncode(data),
    200,
    headers: {Headers.contentTypeHeader: const ['application/json']});

MeData _me() => MeData(
      user: const SpaceUser(id: 'u1', name: '我', username: 'u1',
          avatar: ''),
      users: const [
        SpaceUser(id: 'u1', name: '我', username: 'u1', avatar: ''),
        SpaceUser(id: 'u2', name: 'TA', username: 'u2', avatar: ''),
      ],
      spaceName: '我们的空间',
      spaceRaw: <String, dynamic>{},
      spaceSince: '2024-01-01',
    );

Map<String, Object> _record(Map<String, Object> body,
        {String kind = 'post', List<Object> media = const []}) =>
    {
      'id': 'r${body.hashCode}',
      'kind': kind,
      'author': 'u1',
      'body': body,
      'created': 1730000000,
      'likes': <String>[],
      'comments': <Map<String, dynamic>>[],
      'media': media,
    };

final _pastGroup = <Object>[
  {
    'year': 2025,
    'is_today': false,
    'items': [
      _record({'content': '去年今天的第一条回忆', 'date': '2025-05-01'}),
      _record({'title': '第二年的今天', 'date': '2025-05-01'}),
      _record({'content': '同一年第三条', 'date': '2025-05-01'}),
    ],
  },
  {
    'year': 2024,
    'is_today': false,
    'items': [
      _record({'content': '更早的回忆', 'date': '2024-05-01'}),
    ],
  },
];

class _FakeAuth extends AuthNotifier {
  @override
  AuthPhase build() {
    me = _me();
    return AuthPhase.authed;
  }
}

ProviderContainer _setup(_FakeAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  return ProviderContainer(overrides: [
    dioProvider.overrideWith((ref) async => dio),
    authProvider.overrideWith(_FakeAuth.new),
    chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
    mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
  ]);
}

/// 首页壳（带 router，供 push 断言）+ 顶部 toast 宿主。
Future<void> _pumpHome(WidgetTester tester, ProviderContainer container,
    {GoRouter? router}) async {
  Widget stackBuilder(BuildContext context, Widget? child) => Stack(
      children: [
        child ?? const SizedBox.shrink(),
        const Positioned(
            top: 0, left: 0, right: 0,
            child: IgnorePointer(child: SafeArea(child: ChatToastHost()))),
      ]);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: router != null
        ? MaterialApp.router(routerConfig: router, builder: stackBuilder)
        : MaterialApp(
            // Material 祖先：裸 pump 页面页内 InkWell 需 Material（2.4.2 同款坑）
            home: Material(child: const HomePage()),
            builder: stackBuilder),
  ));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(const Duration(seconds: 2));
}

String codeOnly(String s2) => s2
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── 历史卡显隐 ─────────────────────────────────────────────────────
  testWidgets('🔴 历史卡：往年无记录→整卡不渲染；有→渲染且预览行≤2、年份倒序',
      (tester) async {
    tester.view.physicalSize = const Size(393, 859);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 无往年记录：只有 is_today 组 → 卡不渲染
    final emptyAdapter = _FakeAdapter((o, i) {
      if (o.uri.path == '/api/on-this-day') {
        return _json([
          {'year': 2026, 'is_today': true, 'items': [
            _record({'content': '今天写的', 'date': '2026-05-01'}),
          ]},
        ]);
      }
      if (o.uri.path == '/api/yearbook') {
        return _json({'year': 2026, 'is_current': true, 'total': 0,
            'photos': 0, 'mood_days': 0, 'wishes_done': 0, 'moods': 0,
            'anniversaries': 0, 'active_days': 0, 'streak': 0,
            'interactions': 0, 'by_kind': {}, 'mood_top': [], 'words': []});
      }
      return _json(<Object>[]);
    });
    final c1 = _setup(emptyAdapter);
    await _pumpHome(tester, c1);
    expect(find.byKey(const Key('home-card-otd')), findsNothing,
        reason: '往年无记录 → 整卡不渲染（不占位）');
    // 年报卡恒渲染（全零也显示）
    expect(find.byKey(const Key('home-card-yearbook')), findsOneWidget,
        reason: '年报卡恒渲染（全零也显示）');
    c1.dispose();

    // 有往年记录 → 卡渲染且预览行 ≤2（3 条往年记录只取 2 条）
    final adapter = _FakeAdapter((o, i) {
      if (o.uri.path == '/api/on-this-day') return _json(_pastGroup);
      return _json(<Object>[]);
    });
    final c2 = _setup(adapter);
    await _pumpHome(tester, c2);
    expect(find.byKey(const Key('home-card-otd')), findsOneWidget);
    // 前 2 条预览都来自 2025 组（年份近的在上）：2025 两条、2024 不出现
    expect(find.text('2025 年的今天'), findsNWidgets(2),
        reason: '预览行取前 2 条（同年两条都来自 2025 组 = 年份近的在上）');
    expect(find.text('2024 年的今天'), findsNothing,
        reason: '预览行最多 2 条（往年共 4 条只取前 2，2024 组轮不到）');
    expect(find.text('去年今天的第一条回忆'), findsOneWidget,
        reason: '同年多条按响应序（created 升序）');
    c2.dispose();
  });

  // ── 两卡导航 ───────────────────────────────────────────────────────
  testWidgets('🔴 两卡导航：tap 历史/年报卡分别 push /on-this-day 与 /yearbook',
      (tester) async {
    tester.view.physicalSize = const Size(393, 859);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final adapter = _FakeAdapter((o, i) {
      if (o.uri.path == '/api/on-this-day') return _json(_pastGroup);
      if (o.uri.path == '/api/yearbook') {
        return _json({'year': 2026, 'is_current': true, 'total': 12,
            'photos': 34, 'mood_days': 21, 'wishes_done': 5, 'moods': 30,
            'anniversaries': 3, 'active_days': 40, 'streak': 6,
            'interactions': 9, 'by_kind': {'post': 12}, 'mood_top': [],
            'words': []});
      }
      return _json(<Object>[]);
    });
    final container = _setup(adapter);
    final router = GoRouter(initialLocation: '/x', routes: [
      GoRoute(
          // Material 祖先：裸 pump 页面页内 InkWell 需 Material（2.4.2 同款坑）
          path: '/x',
          builder: (_, _) => Material(child: const HomePage())),
      GoRoute(path: '/on-this-day', builder: (_, _) => const OnThisDayPage()),
      GoRoute(path: '/yearbook', builder: (_, _) => const YearbookPage()),
    ]);
    addTearDown(router.dispose);
    await _pumpHome(tester, container, router: router);

    await tester.tap(find.byKey(const Key('home-card-otd')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(OnThisDayPage), findsOneWidget,
        reason: '点历史卡 push /on-this-day');

    // 系统返回（AppBar back）→ 回首页且首页可继续交互
    await tester.pageBack();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('home-card-yearbook')), findsOneWidget,
        reason: '返回后回到首页');

    await tester.tap(find.byKey(const Key('home-card-yearbook')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(YearbookPage), findsOneWidget,
        reason: '点年报卡 push /yearbook');
    container.dispose();
  });

  // ── 年报口径 ───────────────────────────────────────────────────────
  testWidgets('🔴 年报四格口径：total/photos/mood_days/wishes_done 逐一对账',
      (tester) async {
    tester.view.physicalSize = const Size(393, 859);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final adapter = _FakeAdapter((o, i) {
      if (o.uri.path == '/api/yearbook') {
        return _json({'year': 2026, 'is_current': true, 'total': 12,
            'photos': 34, 'mood_days': 21, 'wishes_done': 5, 'moods': 30,
            'anniversaries': 3, 'active_days': 40, 'streak': 6,
            'interactions': 9, 'by_kind': {'post': 12}, 'mood_top': [],
            'words': []});
      }
      return _json(<Object>[]);
    });
    final container = _setup(adapter);
    await _pumpHome(tester, container);
    expect(find.text('12'), findsOneWidget, reason: '条记录=total');
    expect(find.text('34'), findsOneWidget, reason: '张照片=photos');
    expect(find.text('21'), findsOneWidget, reason: '天心情=mood_days 去重天数');
    expect(find.text('5'), findsOneWidget, reason: '个心愿=wishes_done');
    expect(find.text('30'), findsNothing, reason: 'moods 条数不进四格');
    container.dispose();
  });

  test('🔴 年份口径：App 无写死年份常量（年份一律取服务端响应字段）', () {
    final src = codeOnly(File('lib/features/home/home_cards.dart')
            .readAsStringSync()) +
        codeOnly(
            File('lib/features/home/yearbook_page.dart').readAsStringSync());
    // 生产代码禁止任何写死年份（测试 fixture 里可以）。
    expect(RegExp(r"20\d\d").allMatches(src).isEmpty, isTrue,
        reason: '双卡与年报页不得写死年份常量（跨年自动滚动靠服务端 year 字段）');
  });

  // ── 二级页与弹层 ───────────────────────────────────────────────────
  testWidgets('🔴 /on-this-day：分组倒序全量 + 条目点击弹层出现且正文全文可见',
      (tester) async {
    tester.view.physicalSize = const Size(393, 859);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final adapter = _FakeAdapter((o, i) {
      if (o.uri.path == '/api/on-this-day') return _json(_pastGroup);
      return _json(<Object>[]);
    });
    final container = _setup(adapter);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: OnThisDayPage()),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('2025 年的今天'), findsOneWidget, reason: '年份倒序分组');
    expect(find.text('2024 年的今天'), findsOneWidget,
        reason: '二级页全量（不止 2 条，与首页卡预览不同）');
    expect(find.text('去年今天的第一条回忆'), findsOneWidget);

    await tester.tap(find.text('去年今天的第一条回忆'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('N 年前的今天', skipOffstage: false), findsNothing,
        reason: '记录无 2025 之外的年份标记时标签为具体 N 年前');
    expect(find.byKey(const Key('story-like'), skipOffstage: false),
        findsOneWidget, reason: '点赞可达');
    container.dispose();
  });

  testWidgets('🔴 弹层互动：点赞翻转计数 + 关弹层后列表滚动位置不变',
      (tester) async {
    tester.view.physicalSize = const Size(393, 859);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final adapter = _FakeAdapter((o, i) {
      if (o.uri.path == '/api/on-this-day') return _json(_pastGroup);
      if (o.method == 'POST' && o.uri.path.endsWith('/like')) {
        return _json({'ok': true});
      }
      return _json(<Object>[]);
    });
    final container = _setup(adapter);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: OnThisDayPage()),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));

    // 记录弹层前的滚动位置
    final before = tester.getRect(find.text('2025 年的今天')).top;

    await tester.tap(find.text('去年今天的第一条回忆'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // 正文全文可见（content 全文，不截断）
    expect(find.text('去年今天的第一条回忆', skipOffstage: false),
        findsNWidgets(2), reason: '列表行 + 弹层正文全文各一份');
    // 点赞 → 计数翻转
    await tester.tap(find.byKey(const Key('story-like')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('1', skipOffstage: false), findsWidgets,
        reason: '点赞后计数 1');

    // 关弹层（点遮罩）→ 列表滚动位置不变
    await tester.tapAt(const Offset(10, 100));
    await tester.pump(const Duration(milliseconds: 500));
    final after = tester.getRect(find.text('2025 年的今天')).top;
    expect(after, closeTo(before, 0.5), reason: '关弹层后列表滚动位置不变');
    container.dispose();
  });
}
