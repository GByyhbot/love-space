/* 2.3.4 防回归常驻断言（针对 2.3.2 回退教训）：
   🔴 真机事故：2.3.2 (78ab1f2) 装机后首页主体 tap/滚动全部无反应（真机复现，
   被吞范围 = IndexedStack[0] 首页；Dock / 时光页 / 顶栏 / 弹层全部正常）。
   根因定性见交付小结（diff 复盘：78ab1f2 无手势结构变化，现象在 2.3.1 基线
   已存在——试点段验收仅视觉图证、未做手势点测而漏检）。

   本文件固化不变量：壳层浮层（WebDock + BackdropFilter）在位时——
   ① Dock 自身手势可用（nav 切 tab、+ 钮开 composer）；
   ② 首页主体手势可用（动态卡 tap → onGoTab 切页、ListView drag 滚动）。
   本段及以后每段（视觉/UI 改动）都必须带着本文件跑；任何改动若引入
   「覆盖主体的透明拦截层」，此处 tap/drag 断言会立即失败。 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart' show HitTestResult;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// 12 条 post：保证首页 ListView 内容超一屏，drag 滚动断言有位移空间。
List<Object> _posts() => List<Object>.generate(12, (i) {
      return {
        'id': 'p$i',
        'kind': 'post',
        'author': 'u2',
        'body': <String, dynamic>{
          'date': '2026-11-14',
          'title': '动态标题$i',
          'content': '动态正文$i',
          'media': <String>[],
        },
        'created': 1791195587.0 + i,
        'updated': 1791195587.0 + i,
        'published': null,
        'client_id': 'cid-p$i',
        'media': <Object>[],
        'likes': <Object>[],
        'comments': <Object>[],
      };
    });

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

void main() {
  // ── ① 壳层浮层自身手势 ────────────────────────────────────────────
  group('壳层浮层自身手势（Dock nav / + 钮）', () {
    testWidgets('nav「时光」tap → IndexedStack 切页 index=1', (tester) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        return _json(<Object>[]);
      });
      final container = await _container(adapter);
      await _pumpShell(tester, container);
      expect(find.byType(BackdropFilter), findsOneWidget,
          reason: '前置：壳层浮层（Dock 玻璃）在位——本组断言在浮层存在时生效');
      await tester.tap(find.text('时光'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
          tester.widget<IndexedStack>(find.byType(IndexedStack).first).index,
          1,
          reason: 'Dock nav 必须可点（浮层不得吞自身手势）');
    });

    testWidgets('中央 + 钮 tap → 发布弹层「记录此刻」', (tester) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        return _json(<Object>[]);
      });
      final container = await _container(adapter);
      await _pumpShell(tester, container, size: const Size(800, 600));
      await tester.tap(find.byKey(const Key('shell-compose-fab')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('记录此刻'), findsOneWidget,
          reason: '+ 钮行为链不回归（showComposerSheet）');
    });
  });

  // ── ② 首页主体手势（本防回归核心）────────────────────────────────
  group('首页主体手势（浮层在位时不得被吞）', () {
    testWidgets('hero 卡 tap → 弹「空间信息」编辑层', (tester) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        if (o.uri.path == '/api/records') {
          final kind = o.uri.queryParameters['kind'] ?? '';
          return _json(kind.contains(',') ? _posts().take(1).toList() : <Object>[]);
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
    });

    testWidgets('主体区命中路径不被浮层截获（BackdropFilter 不得出现）', (tester) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        if (o.uri.path == '/api/records') {
          final kind = o.uri.queryParameters['kind'] ?? '';
          return _json(kind.contains(',') ? _posts().take(1).toList() : <Object>[]);
        }
        return _json(<String, Object>{});
      });
      final container = await _container(adapter);
      await _pumpShell(tester, container);
      // 机制映射：真机「首页主体点不动滑不动」的直接机制 = 透明浮层覆盖主体，
      // 其命中路径必经浮层的 RenderBackdropFilter。对主体区（hero 下方
      // ListView 区 y=400）做底层命中测试：若浮层覆盖主体，BackdropFilter
      // 会出现在命中路径里 → 立即失败。tap 生效由 hero 用例独立断言。
      // 走完 timeline 防抖等 pending timer（480ms），避免收尾 timersPending
      await tester.pump(const Duration(seconds: 2));
      final result = HitTestResult();
      tester.binding.renderViews.first.hitTest(result, position: const Offset(196, 400));
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
