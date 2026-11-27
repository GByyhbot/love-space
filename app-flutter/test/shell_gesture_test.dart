/* 2.3.4 起防回归常驻断言（针对 2.3.2 回退教训），2.3.6 适配 Dock 改版：
   🔴 真机事故：2.3.2 装机后首页主体 tap/滚动全部无反应（根因定性见 2.3.5
   小结：主人最终裁定元凶为「最近的小美好」动态卡区，已摘除）。

   本文件固化不变量：壳层浮层（WebDock + BackdropFilter）在位时——
   ① Dock 自身手势可用（五 tab 切换、把手/上滑开抽屉、抽屉点项到达目标）；
   ② 首页主体手势可用（hero tap 弹层、命中路径无浮层截获）；
   ③ 2.3.5 形态护栏（动态卡区保持摘除、today 双格与每日一句在位）。
   本段及以后每段（视觉/UI 改动）都必须带着本文件跑；任何改动若引入
   「覆盖主体的透明拦截层」或破坏 Dock 手势边界，此处断言立即失败。 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart' show HitTestResult;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import 'package:love_space/core/sse/sse_client.dart'
    show SseClient, SseEvent, SsePhase, SseState, sseEventsProvider, sseProvider;
import 'package:love_space/features/chat/chat_toast.dart'
    show ChatToastController, ChatToastMessage, ChatToastTone, chatToastProvider;
import 'package:love_space/features/shell/shell_page.dart';

// ── 夹具（与 web_visual_d_test 同族口径）─────────────────────────────

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final ResponseBody Function(RequestOptions options, int callIndex) handler;
  int calls = 0;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return handler(options, calls++);
  }
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
    jsonEncode(data), status,
    headers: {Headers.contentTypeHeader: const ['application/json']});

Map<String, Object> _me() => {
      'user': {'id': 'u1', 'name': '我', 'username': 'u1'},
      'users': [
        {'id': 'u1', 'name': '我', 'username': 'u1'},
        {'id': 'u2', 'name': 'TA', 'username': 'u2'},
      ],
      'space': {'name': '小空间', 'since': '2024-01-01'},
      'unread': 0,
      'chat_unread': 0,
    };

Future<ProviderContainer> _container(_Adapter adapter) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  final container = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
    mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
    api.cookieJarProvider.overrideWith((ref) async {
      throw StateError('test: no cookie jar');
    }),
    sseProvider.overrideWith(_FakeSse.new),
    sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    chatToastProvider.overrideWith(_NoTimerToastController.new),
  ]);
  addTearDown(container.dispose);
  return container;
}

class _FakeSse extends SseClient {
  @override
  SseState build() => const SseState(phase: SsePhase.idle);
  @override
  void start() {}
}

class _NoTimerToastController extends ChatToastController {
  @override
  void show(String text, {ChatToastTone tone = ChatToastTone.info}) {
    state = ChatToastMessage(id: 1, text: text, tone: tone);
  }
}

Future<void> _pumpShell(WidgetTester tester, ProviderContainer container,
    {Size size = const Size(393, 800)}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: ShellPage()),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
  await tester.pump();
}

/// GoRouter 版 pump：抽屉六格路由映射断言需要真实路由（stub 目标页）。
Future<void> _pumpShellRouter(
    WidgetTester tester, ProviderContainer container) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(393, 800);
  addTearDown(tester.view.reset);
  final router = GoRouter(initialLocation: '/', routes: [
    GoRoute(path: '/', builder: (_, _) => const ShellPage()),
    GoRoute(
        path: '/together/mood',
        builder: (_, _) => const Scaffold(body: Text('MOOD_PAGE'))),
    GoRoute(
        path: '/personal/diary-form',
        builder: (_, _) => const Scaffold(body: Text('DIARY_FORM'))),
    GoRoute(
        path: '/personal/surprise-form',
        builder: (_, _) => const Scaffold(body: Text('SURPRISE_FORM'))),
    GoRoute(
        path: '/together/ledger',
        builder: (_, _) => const Scaffold(body: Text('LEDGER_PAGE'))),
    // 2.4.3 双卡二级页 stub（手势护栏用）
    GoRoute(
        path: '/on-this-day',
        builder: (_, _) => Scaffold(
            appBar: AppBar(title: const Text('OTD')),
            body: const Text('ON_THIS_DAY_PAGE'))),
    GoRoute(
        path: '/yearbook',
        builder: (_, _) => Scaffold(
            appBar: AppBar(title: const Text('YB')),
            body: const Text('YEARBOOK_PAGE'))),
  ]);
  addTearDown(router.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
  await tester.pump();
}

/// 打开抽屉（点把手）并等待 sheet 动画稳定。
Future<void> _openDrawer(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('shell-dock-handle')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 走完 timeline 防抖等 pending timer（480ms），避免收尾 timersPending。
Future<void> _drainTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  // ── ① Dock 自身手势（nav / 把手 / 上滑抽屉）─────────────────────────
  group('Dock 手势（nav 五 tab / 把手 / 上滑开抽屉）', () {
    testWidgets('五 tab 逐个 tap 切换（IndexedStack index 跟随）',
        (tester) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        return _json(<Object>[]);
      });
      final container = await _container(adapter);
      await _pumpShell(tester, container);
      expect(find.byType(BackdropFilter), findsNWidgets(2),
          reason: '前置：壳层固定真玻璃（顶栏 + Dock）共两处在位');
      for (final (i, label) in [
        (1, '时光'),
        (2, '相册'),
        (3, '我们'),
        (4, '角落'),
        (0, '首页'),
      ]) {
        await tester.tap(find.text(label));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(
            tester
                .widget<IndexedStack>(find.byType(IndexedStack).first)
                .index,
            i,
            reason: '五 tab 逐个可点切换（$label → index=$i）');
      }
      await _drainTimers(tester);
    });

    testWidgets('点把手 → 发布抽屉出现（六格在位）', (tester) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        return _json(<Object>[]);
      });
      final container = await _container(adapter);
      await _pumpShell(tester, container);
      await _openDrawer(tester);
      expect(find.text('记录此刻'), findsOneWidget,
          reason: '抽屉标题在位');
      for (final label in ['发动态', '传照片', '记心情', '写日记', '留惊喜', '记一笔']) {
        expect(find.text(label), findsOneWidget,
            reason: '类型快捷格 3×2：$label 在位');
      }
      await _drainTimers(tester);
    });

    testWidgets('抽屉点「发动态」→ 关抽屉 + composer「记录此刻」到达',
        (tester) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        return _json(<Object>[]);
      });
      final container = await _container(adapter);
      await _pumpShell(tester, container);
      await _openDrawer(tester);
      await tester.tap(find.byKey(const Key('drawer-item-post')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('发动态'), findsNothing,
          reason: '抽屉先关闭');
      expect(find.text('记录此刻'), findsOneWidget,
          reason: 'composer 与原 + 钮流程同一代码路径到达');
      await _drainTimers(tester);
    });

    testWidgets('Dock 上滑（快滑越阈值）→ 抽屉出现', (tester) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        return _json(<Object>[]);
      });
      final container = await _container(adapter);
      await _pumpShell(tester, container);
      await tester.fling(find.byKey(const Key('shell-dock')),
          const Offset(0, -220), 1200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('记录此刻'), findsOneWidget,
          reason: '🔴 Dock 上滑开抽屉（手势挂 Dock 容器自身，上滑越阈值触发）');
      await _drainTimers(tester);
    });

    testWidgets('六格映射：心情/日记/惊喜/账本 → 各自既有入口页',
        (tester) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        return _json(<Object>[]);
      });
      final container = await _container(adapter);
      // 现弹层唯一 kind=post（表单无 emoji/publish_at/金额字段），故四格
      // 跳各自既有入口页——以现弹层为唯一事实（数据流/请求零变化）。
      final cases = <(String, String)>[
        ('drawer-item-mood', 'MOOD_PAGE'),
        ('drawer-item-diary', 'DIARY_FORM'),
        ('drawer-item-surprise', 'SURPRISE_FORM'),
        ('drawer-item-ledger', 'LEDGER_PAGE'),
      ];
      for (final (itemKey, stub) in cases) {
        await _pumpShellRouter(tester, container);
        await _openDrawer(tester);
        await tester.tap(find.byKey(Key(itemKey)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text(stub), findsOneWidget,
            reason: '$itemKey → $stub（既有入口页到达）');
        await _drainTimers(tester);
      }
    });
  });

  // ── ② 首页主体手势（本防回归核心）────────────────────────────────
  group('首页主体手势（浮层在位时不得被吞）', () {
    testWidgets('2.3.5 形态护栏：动态卡区已摘除（主人裁定吞手势）', (tester) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        return _json(<Object>[]); // 空列表（records 解析须为 List，否则进错误态）
      });
      final container = await _container(adapter);
      await _pumpShell(tester, container);
      expect(find.byKey(const Key('home-recent-card')), findsNothing,
          reason: '🔴 「最近的小美好」动态卡区保持摘除（主人 2.3.5 裁定）');
      // today 双格与每日一句仍在位
      expect(find.text('今天的心情'), findsOneWidget);
      expect(find.text('最近纪念日'), findsOneWidget);
      expect(find.text('今天的一句'), findsOneWidget);
      await _drainTimers(tester);
    });

    testWidgets('2.3.7 心情格一行式：无名字、头像与胶囊同行、两胶囊左缘对齐同尺寸',
        (tester) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        return _json(<Object>[]);
      });
      final container = await _container(adapter);
      await _pumpShell(tester, container);

      // 名字文本已从心情格摘除（_MoodRow 不再渲染 user.name）。
      expect(find.text('TA'), findsNothing,
          reason: '🔴 心情格不再显示对方名字文本（2.3.7 一行式）');
      // 头像与胶囊都在位（头像在范围内、显示照片本体路径）。
      final av1 = find.byKey(const Key('mood-avatar-u1'));
      final av2 = find.byKey(const Key('mood-avatar-u2'));
      final pill1 = find.byKey(const Key('mood-pill-u1'));
      final pill2 = find.byKey(const Key('mood-pill-u2'));
      expect(av1, findsOneWidget);
      expect(av2, findsOneWidget);
      expect(pill1, findsOneWidget);
      expect(pill2, findsOneWidget);

      // 每行：头像与胶囊同一行（垂直中心对齐）。
      final rAv1 = tester.getRect(av1);
      final rPill1 = tester.getRect(pill1);
      final rAv2 = tester.getRect(av2);
      final rPill2 = tester.getRect(pill2);
      expect((rAv1.top + rAv1.bottom) / 2,
          closeTo((rPill1.top + rPill1.bottom) / 2, 2.0),
          reason: '🔴 u1 头像与胶囊同一行（非「头像+名字/胶囊」两行式）');
      expect((rAv2.top + rAv2.bottom) / 2,
          closeTo((rPill2.top + rPill2.bottom) / 2, 2.0),
          reason: '🔴 u2 头像与胶囊同一行');

      // 两行胶囊左缘对齐、同尺寸（同 Expanded + 同 padding）。
      expect(rPill1.left, closeTo(rPill2.left, 1.0),
          reason: '🔴 两行胶囊左缘对齐');
      expect(rPill1.width, closeTo(rPill2.width, 1.0),
          reason: '🔴 两行胶囊等宽');
      expect(rPill1.height, closeTo(rPill2.height, 1.0),
          reason: '🔴 两行胶囊等高');
      await _drainTimers(tester);
    });

    testWidgets('2.4.0 齿轮入口：五 tab 顶栏齿轮在位，点击落设置主页，返回原 tab',
        (tester) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        return _json(<Object>[]);
      });
      final container = await _container(adapter);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(393, 800);
      addTearDown(tester.view.reset);
      final router = GoRouter(initialLocation: '/', routes: [
        GoRoute(path: '/', builder: (_, _) => const ShellPage()),
        GoRoute(
            path: '/settings',
            builder: (_, _) => Scaffold(
                appBar: AppBar(title: const Text('SETTINGS_HOME')),
                body: const Center(child: Text('settings-body')))),
      ]);
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();

      // 切到第 3 个 tab（相册），制造「非首页 tab」状态。
      await tester.tap(find.text('相册'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      int? stackIndex() =>
          tester.widget<IndexedStack>(find.byType(IndexedStack).first).index;
      expect(stackIndex(), 2, reason: '前置：相册 tab 已选中');

      // 齿轮在位且点击落设置主页（WebTopIconButton 顶栏本体，非 overlay）。
      final gear = find.byKey(const Key('shell-settings'));
      expect(gear, findsOneWidget, reason: '🔴 五 tab 顶栏齿轮入口在位');
      await tester.tap(gear);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('SETTINGS_HOME'), findsOneWidget,
          reason: '🔴 齿轮点击落设置主页');

      // 返回回到原 tab（IndexedStack 保留）：pop 后相册 tab 仍选中。
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('SETTINGS_HOME'), findsNothing);
      expect(stackIndex(), 2, reason: '🔴 返回后仍在切走前的 tab（相册=2）');
      await _drainTimers(tester);
    });

    testWidgets('hero 卡 tap → 弹「空间信息」编辑层', (tester) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        if (o.uri.path == '/api/records') {
          final kind = o.uri.queryParameters['kind'] ?? '';
          return _json(kind.contains(',') ? <Object>[] : <Object>[]);
        }
        return _json(<String, Object>{});
      });
      final container = await _container(adapter);
      await _pumpShell(tester, container);
      // hero 在视口上部（y≈120-350，远离 Dock 区）：点主体内容必须生效——
      // 若任何改动引入覆盖主体的透明拦截层，此处 tap 落不到 InkWell 即失败。
      await tester.tap(find.byKey(const Key('home-hero')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('空间信息'), findsOneWidget,
          reason: '🔴 首页主体 tap 必须生效（浮层不得吞主体手势）');
      await _drainTimers(tester);
    });

    // ── 2.4.3 双卡手势护栏：新卡区可点可拖、Dock 与顶栏不受影响 ──────────
    group('2.4.3 双卡手势（历史卡/年报卡可点可拖）', () {
      // 双卡 mock：on-this-day 给一组往年记录（卡渲染）、yearbook 给全零
      // （恒渲染），其余路径照旧空对象（失败静默口径下 provider 不炸）。
      _Adapter cardsAdapter() => _Adapter((o, i) {
            if (o.uri.path == '/api/me') return _json(_me());
            if (o.uri.path == '/api/records') return _json(<Object>[]);
            if (o.uri.path == '/api/on-this-day') {
              return _json(<Object>[
                {
                  'year': 2025,
                  'is_today': false,
                  'items': [
                    {
                      'id': 'r1', 'kind': 'post', 'author': 'u1',
                      'body': {'content': '去年今天', 'date': '2025-05-01'},
                      'created': 1730000000, 'likes': <String>[],
                      'comments': <Object>[], 'media': <Object>[],
                    },
                  ],
                },
              ]);
            }
            if (o.uri.path == '/api/yearbook') {
              return _json(<String, Object>{
                'year': 2026, 'is_current': true, 'total': 0,
                'photos': 0, 'mood_days': 0, 'wishes_done': 0,
                'moods': 0, 'anniversaries': 0, 'active_days': 0,
                'streak': 0, 'interactions': 0, 'by_kind': <String, Object>{},
                'mood_top': <Object>[], 'words': <Object>[],
              });
            }
            return _json(<String, Object>{});
          });


      testWidgets('双卡可点：历史卡 tap → /on-this-day；返回后年报卡 tap → /yearbook',
          (tester) async {
        final container = await _container(cardsAdapter());
        await _pumpShellRouter(tester, container);
        // 双卡在每日一句下方，视口外：滚到可见（这也是「可拖动」的路径）
        await tester.scrollUntilVisible(
          find.byKey(const Key('home-card-otd')),
          200,
          scrollable: find.descendant(
              of: find.byType(ShellPage),
              matching: find.byType(Scrollable)).first,
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(find.byKey(const Key('home-card-otd')));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('ON_THIS_DAY_PAGE'), findsOneWidget,
            reason: '🔴 历史卡 tap 必须生效（新卡不得吞手势/被浮层截获）');

        // 系统返回 → 回首页且首页可继续交互（再滚到年报卡可点）
        await tester.pageBack();
        await tester.pump(const Duration(seconds: 1));
        await tester.scrollUntilVisible(
          find.byKey(const Key('home-card-yearbook')),
          200,
          scrollable: find.descendant(
              of: find.byType(ShellPage),
              matching: find.byType(Scrollable)).first,
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(find.byKey(const Key('home-card-yearbook')));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('YEARBOOK_PAGE'), findsOneWidget,
            reason: '🔴 返回后年报卡 tap 继续生效（首页未锁死）');
        await _drainTimers(tester);
      });

      testWidgets('双卡区可纵向拖动滚动 + Dock 不受影响', (tester) async {
        final container = await _container(cardsAdapter());
        await _pumpShellRouter(tester, container);
        final scrollable = find
            .descendant(
                of: find.byType(ShellPage),
                matching: find.byType(Scrollable))
            .first;
        final before = tester.state<ScrollableState>(scrollable).position.pixels;
        // 从卡区起手向上拖：新卡不得拦截纵向手势
        await tester.scrollUntilVisible(
          find.byKey(const Key('home-card-yearbook')),
          200,
          scrollable: scrollable,
        );
        await tester.pump(const Duration(milliseconds: 200));
        final after = tester.state<ScrollableState>(scrollable).position.pixels;
        expect(after, greaterThan(before),
            reason: '🔴 双卡区纵向拖动必须能滚动首页（2.3.5 事故回归护栏）');
        // Dock 不受影响：五 tab 切换仍可用（切到时光 tab）
        await tester.tap(find.byKey(const Key('shell-nav-1')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const Key('home-card-yearbook')), findsNothing,
            reason: 'Dock 切 tab 正常（首页卡随 IndexedStack 隐藏）');
        await _drainTimers(tester);
      });
    });

    testWidgets('主体区命中路径不被浮层截获（BackdropFilter 不得出现）', (tester) async {      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        if (o.uri.path == '/api/records') return _json(<Object>[]);
        return _json(<String, Object>{});
      });
      final container = await _container(adapter);
      await _pumpShell(tester, container);
      // 机制映射：真机「首页主体点不动滑不动」的直接机制 = 透明浮层覆盖主体，
      // 其命中路径必经浮层的 RenderBackdropFilter。对主体区做底层命中测试。
      await _drainTimers(tester);
      final result = HitTestResult();
      tester.binding.renderViews.first.hitTest(
          result, position: const Offset(196, 400));
      final names = result.path
          .map((e) => e.target.runtimeType.toString())
          .toList(growable: false);
      expect(names.contains('RenderBackdropFilter'), isFalse,
          reason: '🔴 主体区命中路径不得出现 Dock 玻璃浮层（真机吞手势机制）');
      expect(names.contains('RenderIndexedStack'), isTrue,
          reason: '命中必须到达主体 IndexedStack（页面层）');
    });
  });
}
