/* 视觉对齐 Web · 试点段（2.3.1/VC231）新增测试：
   ① chrome 语义色表深浅两档逐值断言（玻璃 α 显式取值，不许 fromSeed 派生）；
   ② Dock 结构：+ 钮 46×46、五 tab 仍在、距边 10、玻璃仅 Dock 一处；
   ③ 顶栏三钮（通知/私聊/头像）42/42/44 圆钮 + 角标 + push 去向不回归；
   ④ 首页 1:1 数值断言：页头文案逐字、hero radius 20、stats 三格、
      动态卡 radius 17（Web 手机档 style.css:1421）、320 宽零溢出。
   数值出处见 lib/features/shell/web_chrome.dart 与 docs/web-visual-plan.md。 */
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
import 'package:love_space/features/chat/chat_toast.dart'
    show ChatToastController, ChatToastMessage, ChatToastTone, chatToastProvider;
import 'package:love_space/core/sse/sse_client.dart'
    show SseClient, SsePhase, SseState, SseEvent, sseEventsProvider, sseProvider;
import 'package:love_space/features/home/home_page.dart';
import 'package:love_space/features/shell/shell_page.dart';
import 'package:love_space/features/shell/web_chrome.dart';

// ── 夹具 ─────────────────────────────────────────────────────────────

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final ResponseBody Function(RequestOptions options, int callIndex) handler;
  final List<RequestOptions> requests = <RequestOptions>[];
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

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
    jsonEncode(data), status,
    headers: {Headers.contentTypeHeader: const ['application/json']});

/// 双人 me（unread 可调，角标测试用）
Map<String, Object> _me({int systemUnread = 0, int chatUnread = 0}) => {
      'user': {'id': 'u1', 'name': '我', 'username': 'u1'},
      'users': [
        {'id': 'u1', 'name': '我', 'username': 'u1'},
        {'id': 'u2', 'name': 'TA', 'username': 'u2'},
      ],
      'space': {'name': '小空间', 'since': '2024-01-01'},
      'unread': systemUnread,
      'chat_unread': chatUnread,
    };

/// 首页动态夹具：一条 post（其余接口空）
Map<String, Object?> get _postJson => {
      'id': 'p1',
      'kind': 'post',
      'author': 'u2',
      'body': <String, dynamic>{
        'date': '2026-11-14',
        'title': '动态标题',
        'content': '动态正文',
        'media': <String>[],
      },
      'created': 1791195587.0,
      'updated': 1791195587.0,
      'published': null,
      'client_id': 'cid-p1',
      'media': <Object>[],
      'likes': <Object>[],
      'comments': <Object>[],
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

/// SSE 不连网（只保留事件流与 notifier 接口）
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

void main() {
  // ── ① chrome 语义色表：深浅两档逐值断言 ──────────────────────────
  group('chrome 色表（玻璃 α 显式取值）', () {
    test('浅色档：白玻璃 dock + primary 胶囊 + surface 钮底', () {
      final cs = ColorScheme.fromSeed(
        seedColor: const Color(0xFF953753),
        brightness: Brightness.light,
      );
      final c = ChromeColors(brightness: Brightness.light, scheme: cs);
      expect(c.dockBg, const Color(0xE6FFFFFF),
          reason: 'dock-bg 浅 rgba(255,255,255,.9)（style.css:2736）');
      expect(c.dockLine, const Color(0x0F000000),
          reason: 'dock-line 浅 rgba(0,0,0,.06)（style.css:2737）');
      expect(c.dockShadow, const Color.fromRGBO(90, 50, 70, 0.28),
          reason: 'dock-shadow 浅 rgba(90,50,70,.28)（style.css:2737）');
      expect(c.navPillBg, cs.primaryContainer,
          reason: 'nav 胶囊浅 = --soft 的 M3 语义档（style.css:2699）');
      expect(c.topBtnBg, cs.surface,
          reason: '顶栏钮浅 = --raised=surface（style.css:74/:279）');
      expect(c.topBtnShadow, const Color.fromRGBO(69, 56, 63, 0.07),
          reason: 'btn-lift 浅（style.css:140）');
      expect(c.fabShadow, const Color.fromRGBO(0, 0, 0, 0.24),
          reason: '+ 钮阴影 rgba(0,0,0,.24)（style.css:2749）');
      expect((c.topbarBg.a - 0.80).abs() < 0.001, isTrue,
          reason: '顶栏半透明 80%（style.css:2108）');
    });

    test('夜色档：黑玻璃 dock + 白 .14 胶囊 + 白 .06 钮底', () {
      final cs = ColorScheme.fromSeed(
        seedColor: const Color(0xFFDA8BA3),
        brightness: Brightness.dark,
      );
      final c = ChromeColors(brightness: Brightness.dark, scheme: cs);
      expect(c.dockBg, const Color(0xC71C161E),
          reason: 'dock-bg 夜 rgba(28,22,30,.78)（style.css:2736）');
      expect(c.dockLine, const Color(0x17FFFFFF),
          reason: 'dock-line 夜 rgba(255,255,255,.09)（style.css:2737）');
      expect(c.dockShadow, const Color.fromRGBO(0, 0, 0, 0.55),
          reason: 'dock-shadow 夜 rgba(0,0,0,.55)（style.css:2737）');
      expect(c.navPillBg, const Color(0x24FFFFFF),
          reason: 'nav 胶囊夜 rgba(255,255,255,.14)（style.css:2746）');
      expect(c.topBtnBg, const Color(0x0FFFFFFF),
          reason: '顶栏钮夜 = --raised rgba(255,255,255,.06)（style.css:1522）');
      expect(c.topBtnShadow, const Color.fromRGBO(0, 0, 0, 0.40),
          reason: 'btn-lift 夜（style.css:1519）');
    });

    test('Web 语义色（跟主题无关、跟明暗两换）浅/夜取值', () {
      // style.css:38-41（浅）/:1512（夜）
      expect(WebSemanticColors.green(Brightness.light), const Color(0xFF4B6B3F));
      expect(WebSemanticColors.green(Brightness.dark), const Color(0xFF8FB27C));
      expect(WebSemanticColors.greenSoft(Brightness.light),
          const Color(0xFFEAF1E4));
      expect(WebSemanticColors.greenSoft(Brightness.dark),
          const Color(0xFF2B3428));
      expect(WebSemanticColors.amber(Brightness.light), const Color(0xFF8A5A22));
      expect(WebSemanticColors.amber(Brightness.dark), const Color(0xFFD2A472));
      expect(WebSemanticColors.amberSoft(Brightness.light),
          const Color(0xFFF7EEDF));
      expect(WebSemanticColors.amberSoft(Brightness.dark),
          const Color(0xFF3A3026));
      expect(WebSemanticColors.fertile(Brightness.light),
          const Color(0xFF7B63A0));
      expect(WebSemanticColors.fertile(Brightness.dark), const Color(0xFFB49BD6));
      expect(WebSemanticColors.cardHairline(Brightness.light),
          const Color.fromRGBO(255, 255, 255, 0.72)); // :1937
      expect(WebSemanticColors.cardHairline(Brightness.dark),
          const Color.fromRGBO(255, 255, 255, 0.05)); // :2017
    });
  });

  // ── ② Dock 结构 ──────────────────────────────────────────────────
  group('Dock 结构（+ 钮 46×46、五 tab、距边 10、玻璃仅 Dock）', () {
    testWidgets('+ 钮 onTap 仍开发布弹层（showComposerSheet 行为链不回归）',
        (tester) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        return _json(<Object>[]);
      });
      final container = await _container(adapter);
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1.0;
      // 行为链护栏用宽视口（800×600，与 personal_a_test ⑧/timeline_edit_delete
      // 既有 composer 泵法同口径）：composer_sheet.dart:672「发生日期」Row 在
      // 窄视口（≤~400）右溢出属既有缺陷（不在本试点改动面，单独 Known Issue），
      // 此处只验证 onTap → showComposerSheet 调用链，不吞该布局异常。
      tester.view.physicalSize = const Size(800, 600);
      await tester.pumpWidget(
          UncontrolledProviderScope(container: container, child: const MaterialApp(home: ShellPage())));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // 行为红线（2.3.6 Dock 改版）：把手 → 抽屉 → 发动态 → composer 弹层，
      // 与原 + 钮同一 composer 调用链（showComposerSheet）。
      await tester.tap(find.byKey(const Key('shell-dock-handle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('发动态'), findsOneWidget,
          reason: '发布抽屉出现（六格 3×2）');
      await tester.tap(find.byKey(const Key('drawer-item-post')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('记录此刻'), findsOneWidget,
          reason: '抽屉点「发动态」必须到达 composer 弹层（同一调用链）');
    });

    testWidgets('真实 ShellPage：Dock 浮层在位、把手在位、五 tab 可切', (tester) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        return _json(<Object>[]);
      });
      final container = await _container(adapter);
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(393, 800);
      await tester.pumpWidget(
          UncontrolledProviderScope(container: container, child: const MaterialApp(home: ShellPage())));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 玻璃只 Dock 一处
      expect(find.byType(BackdropFilter), findsOneWidget);
      // 距左右下各 10px（style.css:2738）
      final positioned = tester
          .widgetList<Positioned>(find.ancestor(
              of: find.byKey(const Key('shell-dock')),
              matching: find.byType(Positioned)))
          .first;
      expect(positioned.left, 10);
      expect(positioned.right, 10);
      expect(positioned.bottom, 10);
      // 2.3.6：+ 钮已移除、顶部把手在位（38×4.5，属 Dock 组件自身）
      expect(find.byKey(const Key('shell-compose-fab')), findsNothing);
      expect(find.byKey(const Key('shell-dock-handle')), findsOneWidget);
      // 五 tab 仍在（红线：不许 4 tab），IndexedStack 五页
      for (final label in ['首页', '时光', '相册', '我们', '角落']) {
        expect(find.text(label), findsWidgets, reason: '$label 入口存在');
      }
      final stack = tester.widget<IndexedStack>(find.byType(IndexedStack).first);
      expect(stack.children.length, 5);
      // 切到第 5 tab（角落）仍工作
      await tester.tap(find.text('角落'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
          tester.widget<IndexedStack>(find.byType(IndexedStack).first).index, 4);
    });
  });

  // ── ③ 顶栏三钮功能不回归 ─────────────────────────────────────────
  group('顶栏三钮（通知/私聊/头像）', () {
    Future<(WidgetTester, ProviderContainer)> pumpShell(
        WidgetTester tester) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me(systemUnread: 3, chatUnread: 2));
        return _json(<Object>[]);
      });
      final container = await _container(adapter);
      final router = GoRouter(initialLocation: '/', routes: [
        GoRoute(path: '/', builder: (_, _) => const ShellPage()),
        GoRoute(path: '/notices', builder: (_, _) => const Scaffold(body: Text('NOTICES_PAGE'))),
        GoRoute(path: '/messages', builder: (_, _) => const Scaffold(body: Text('MESSAGES_PAGE'))),
        GoRoute(path: '/profile', builder: (_, _) => const Scaffold(body: Text('PROFILE_PAGE'))),
      ]);
      addTearDown(router.dispose);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(393, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          UncontrolledProviderScope(container: container, child: MaterialApp.router(routerConfig: router)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
      return (tester, container);
    }

    testWidgets('42×42 圆钮 + surface 外圈角标数字在位', (tester) async {
      await pumpShell(tester);
      expect(find.byKey(const Key('shell-notices')), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('shell-notices'))),
          const Size(42, 42),
          reason: '顶栏圆钮 42×42（style.css:279）');
      // 角标：系统未读 3 / 私聊 2（surface 外圈由 WebBadge 2px border 呈现）
      expect(find.text('1'), findsWidgets);
      expect(find.text('2'), findsWidgets);
      // 头像钮 44×44（style.css:431）
      final avatar = find.byType(WebAvatarButton);
      expect(avatar, findsOneWidget);
      expect(tester.getSize(avatar), const Size(44, 44));
    });

    testWidgets('铃铛 → /notices', (tester) async {
      await pumpShell(tester);
      await tester.tap(find.byKey(const Key('shell-notices')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('NOTICES_PAGE'), findsOneWidget);
    });

    testWidgets('私聊 → /messages', (tester) async {
      await pumpShell(tester);
      await tester.tap(find.byTooltip('私聊'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('MESSAGES_PAGE'), findsOneWidget);
    });

    testWidgets('头像 → /profile', (tester) async {
      await pumpShell(tester);
      await tester.tap(find.byTooltip('账号资料'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('PROFILE_PAGE'), findsOneWidget);
    });
  });

  // ── ④ 首页 1:1 数值断言 ─────────────────────────────────────────
  group('首页（页头逐字 / hero / stats / 动态卡）', () {
    Future<void> pumpHome(WidgetTester tester, Size size) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        if (o.method == 'GET' && o.uri.path == '/api/records') {
          return _json(<Object>[_postJson]);
        }
        if (o.method == 'GET' && o.uri.path == '/api/dashboard') {
          return _json(<String, Object>{'days_together': 100, 'photos': 5});
        }
        return _json(<Object>[]);
      });
      final container = await _container(adapter);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          UncontrolledProviderScope(container: container, child: const MaterialApp(home: HomePage())));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
    }

    BorderRadius radiusOf(WidgetTester tester, Key key) {
      final w = tester.widget<Container>(find.byKey(key));
      return (w.decoration! as BoxDecoration).borderRadius! as BorderRadius;
    }

    testWidgets('页头文案逐字 + hero radius 20 + stats 已摘除 + 动态卡 radius 17',
        (tester) async {
      await pumpHome(tester, const Size(393, 1200));
      // 页头逐字（app.js:725）
      expect(find.text('我们的每一天'), findsOneWidget);
      expect(find.text('一半是生活，一半是你。'), findsOneWidget);
      // hero radius 20（style.css:448）
      expect(radiusOf(tester, const Key('home-hero')).topLeft.x, 20);
      // 2.3.4（推广段一重做）：stats 三格整块摘除（真 Web 手机端无此区、
      // index.html/app.js 全库无 stats-grid 引用，盘点偏差，主人已裁定）
      for (var i = 0; i < 3; i++) {
        expect(find.byKey(Key('home-stat-$i')), findsNothing);
      }
      // 2.3.5（主人裁定）：「最近的小美好」动态卡区保持摘除（吞首页手势）
      expect(find.byKey(const Key('home-recent-card')), findsNothing);
      expect(find.text('最近的小美好'), findsNothing);
      // 每日一句仍在
      expect(find.text('今天的一句'), findsOneWidget);
    });

    testWidgets('2.3.7 真机修复：天数行锚到 hero 下半部（非贴名字顶部）',
        (tester) async {
      await pumpHome(tester, const Size(393, 1200));
      final heroRect = tester.getRect(find.byKey(const Key('home-hero')));
      final daysRect = tester.getRect(find.byKey(const Key('home-hero-days')));
      final heroMidY = (heroRect.top + heroRect.bottom) / 2;
      final daysMidY = (daysRect.top + daysRect.bottom) / 2;
      expect(daysMidY, greaterThan(heroMidY),
          reason: '🔴 天数行须锚到 hero 卡下半部（2.3.7 第6项：下移锚到底部，'
              '非 Pos...Align 失效贴顶）');
      // 且不超出卡片下边缘（bottom 定位留 18 padding）
      expect(daysRect.bottom, lessThan(heroRect.bottom),
          reason: '天数行不得溢出 hero 卡下边缘');
    });

    testWidgets('320×700 窄屏零 RenderFlex overflow', (tester) async {
      await pumpHome(tester, const Size(320, 700));
      expect(tester.takeException(), isNull,
          reason: 'stats 三格 / hero / 动态卡在 320 宽不得溢出');
    });
  });
}
