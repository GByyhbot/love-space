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
      expect(find.byType(BackdropFilter), findsOneWidget,
          reason: '前置：壳层浮层（Dock 玻璃）在位');
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

    testWidgets('主体区命中路径不被浮层截获（BackdropFilter 不得出现）', (tester) async {
      final adapter = _Adapter((o, i) {
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
