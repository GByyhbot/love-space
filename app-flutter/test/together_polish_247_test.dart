/* 2.4.7 甲组（我们专区美化）护栏测试：
   ① 共同年历 393 宽：标题行单行不溢出 + 「记了 N 天」胶囊 + 图例四项在卡内；
      今天=主题色实心圆（token 断言）+ 选中=primary 描边圆
   ② ToolTile 作者行头像结构：有头像走 AvatarMedia（统一鉴权缓存路径）、
      无头像走字母 CircleAvatar 兜底
   ③ 主操作悬浮钮底色==primary（token 断言）：ToolScaffold（MoodPage）与
      自建 scaffold（HabitPage）同源 toolFab
   ④ 愿望 meta 胶囊 chips 393 宽不溢出（文案逐字保留）
   ⑤ 源码护栏：触碰文件内不得新增写死 Color(0x…) 字面量 */
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import 'package:love_space/features/chat/chat_toast.dart' show ChatToastHost;
import 'package:love_space/features/together/calendar_page.dart';
import 'package:love_space/features/auth/auth_state.dart';
import 'package:love_space/features/together/question_habit_pages.dart';
import 'package:love_space/features/together/tool_pages.dart';

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

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
    jsonEncode(data), status,
    headers: {Headers.contentTypeHeader: const ['application/json']});

Map<String, Object> _toolRecord(String id, String kind,
        {Map<String, Object> body = const {}, String author = 'u1'}) =>
    {
      'id': id, 'kind': kind, 'author': author,
      'body': body,
      'created': 1000.0, 'updated': 1000.0, 'client_id': '',
      'media': const <Object>[], 'likes': const <Object>[],
      'comments': const <Object>[],
    };

/// 认证供体：/api/me 返回合法 me（ToolTile 作者行头像/人名解析依赖）。
/// 🔴 avatar 留空走字母兜底：AvatarMedia 的 retainLatest 在测试环境会触碰
/// secure storage/缓存库（无插件），真渲染留给真机验收 + 源码断言。
Map<String, Object> _meFixture() => {
      'user': {'id': 'u1', 'name': '我', 'username': 'u1'},
      'users': [
        {'id': 'u1', 'name': '我', 'username': 'u1'},
        {'id': 'u2', 'name': 'TA', 'username': 'u2'},
      ],
      'space': {},
      'unread': 0,
      'chat_unread': 0,
    };

_FakeAdapter _withMe(ResponseBody Function(RequestOptions, int) inner) =>
    _FakeAdapter((options, i) {
      if (options.uri.path == '/api/me') return _json(_meFixture());
      return inner(options, i);
    });

ProviderContainer _widgetSetup(_FakeAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  return ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
    mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
  ]);
}

/// 预热 authProvider（拉 /api/me）：ToolTile watch 的是 notifier 不随 me
/// 到达重建，me 必须在 tiles 构建前就位。
/// 🔴 不能在 pumpWidget 前 await reload()——_bootstrap 里 `Future(() …)`
/// 是零时长 Timer，FakeAsync 不 pump 永不触发（曾致测试整体挂死）；
/// 这里用 pump 驱动直到 authed。
Future<void> _warmAuth(WidgetTester tester, ProviderContainer container) async {
  container.read(authProvider.notifier).reload();
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (container.read(authProvider) == AuthPhase.authed) return;
  }
  fail('authProvider 未在 1s 内就绪');
}

/// 页面 pump 外壳与 together_b/c 同构：ChatToastHost 顶部浮层。
Future<void> _pumpPage(WidgetTester tester, ProviderContainer container,
    Widget page) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      builder: (context, child) => Stack(children: [
        child ?? const SizedBox.shrink(),
        const Positioned(
            top: 0, left: 0, right: 0,
            child: IgnorePointer(child: SafeArea(child: ChatToastHost()))),
      ]),
      home: page,
    ),
  ));
  await tester.pumpAndSettle();
}

void _use393Viewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(393, 852);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  // ── ① 共同年历 ───────────────────────────────────────────────
  group('① 共同年历（甲组美化）', () {
    testWidgets('393 宽：标题行单行无溢出 + 记了 N 天胶囊 + 图例四项',
        (tester) async {
      _use393Viewport(tester);
      final now = DateTime.now();
      final adapter = _withMe((options, i) {
        return _json({
          'month': '${now.year}-${now.month.toString().padLeft(2, '0')}',
          'days': {
            '10': {
              'anniversaries': [
                {'id': 'a1', 'title': '领证纪念日'}
              ],
              'posts': [
                {'id': 'p1', 'title': '海边一天'}
              ],
              'moods': [
                {'author': 'u1', 'emoji': '☀️'}
              ],
              'checks': [
                {'author': 'u1'},
                {'author': 'u2'}
              ],
            },
          },
        });
      });
      final container = _widgetSetup(adapter);
      addTearDown(container.dispose);
      await _warmAuth(tester, container);
      await _pumpPage(tester, container, const CalendarPage());
      expect(tester.takeException(), isNull,
          reason: '393 宽整页渲染无 overflow/异常');

      // 标题单行：「2026 年 11 月」+「记了 1 天」胶囊
      expect(
          find.text('${now.year} 年 ${now.month} 月'), findsOneWidget);
      expect(find.text('记了 1 天'), findsOneWidget);

      // 图例四项（收进卡内，随数据一并渲染）
      for (final label in const ['纪念日', '动态', '心情', '打卡']) {
        expect(find.text(label), findsOneWidget, reason: '图例 $label');
      }
    });

    testWidgets('今天=主题色实心圆白字；选中日=primary 描边圆（token 断言）',
        (tester) async {
      _use393Viewport(tester);
      final now = DateTime.now();
      final adapter = _withMe((options, i) {
        return _json({
          'month': '${now.year}-${now.month.toString().padLeft(2, '0')}',
          'days': {},
        });
      });
      final container = _widgetSetup(adapter);
      addTearDown(container.dispose);
      await _warmAuth(tester, container);
      await _pumpPage(tester, container, const CalendarPage());

      final pageCtx = tester.element(find.byType(CalendarPage));
      final primary = Theme.of(pageCtx).colorScheme.primary;

      // 今天单元格：实心圆底色 == cs.primary（token 断言）
      final todayCircle = tester
          .widget<Container>(find.byKey(const Key('calendar-today-circle')));
      final todayDec = todayCircle.decoration as BoxDecoration;
      expect(todayDec.color, primary, reason: '今天=主题色实心圆');
      expect(todayDec.shape, BoxShape.circle);

      // 选中日：描边圆 Border.all(color: primary)
      await tester.tap(find.text('15'));
      await tester.pumpAndSettle();
      final selRing = tester
          .widget<Container>(find.byKey(const Key('calendar-selected-ring')));
      final selDec = selRing.decoration as BoxDecoration;
      final border = selDec.border as Border;
      expect(border.top.color, primary, reason: '选中=主题色描边');
      expect(tester.takeException(), isNull);
    });

    testWidgets('未选中提示卡：主题色浅底圆角卡 + 图标底座', (tester) async {
      final adapter = _withMe((options, i) {
        return _json({'month': '2026-01', 'days': {}});
      });
      final container = _widgetSetup(adapter);
      addTearDown(container.dispose);
      await _warmAuth(tester, container);
      await _pumpPage(tester, container, const CalendarPage());
      final pageCtx = tester.element(find.byType(CalendarPage));
      final cs = Theme.of(pageCtx).colorScheme;
      // 提示卡 Container：primary 浅底（0.08 alpha）+ 圆角 + Row(图标底座)
      final hintW = tester.widget<Container>(find.byWidgetPredicate((w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color != null &&
              (w.decoration as BoxDecoration).color!.a > 0 &&
              (w.decoration as BoxDecoration).borderRadius != null &&
              w.child is Row &&
              ((w.child as Row).children.first is Container)));
      final dec = hintW.decoration as BoxDecoration;
      expect(dec.color, cs.primary.withValues(alpha: 0.08),
          reason: '提示卡=主题色浅底');
      // 白底圆角方形图标底座（cs.surface）
      final iconBase = (hintW.child! as Row).children.first as Container;
      expect((iconBase.decoration as BoxDecoration).color, cs.surface,
          reason: '图标底座=表面白底圆角方形');
    });
  });

  // ── ② 作者行头像 + ③ 悬浮钮 token ────────────────────────────
  group('②③ ToolTile 头像行 + 悬浮钮 token', () {
    testWidgets('作者行头像结构 + MoodPage 悬浮钮底色==primary（token 断言）',
        (tester) async {
      final adapter = _withMe((options, i) {
        return _json([
          _toolRecord('m1', 'mood',
              body: {'emoji': '☀️', 'date': '2026-11-13', 'content': '晴'}),
        ]);
      });
      final container = _widgetSetup(adapter);
      addTearDown(container.dispose);
      await _warmAuth(tester, container);
      await _pumpPage(tester, container, const MoodPage());
      // 头像行结构断言：作者行含字母兜底头像（avatar 空 → CircleAvatar）
      expect(find.byType(CircleAvatar), findsWidgets,
          reason: '作者行含头像（无头像字母兜底）');
      expect(find.textContaining('我 · '), findsOneWidget, reason: '名字 · 日期保留');
      // 表情底座：彩色浅底圆角方形 46
      expect(find.text('☀️'), findsWidgets);
      // 悬浮钮 token：底色==primary
      final fab = tester.widget<FloatingActionButton>(
          find.widgetWithText(FloatingActionButton, '记心情'));
      final fabCtx = tester.element(find.widgetWithText(FloatingActionButton,
          '记心情'));
      expect(fab.backgroundColor, Theme.of(fabCtx).colorScheme.primary,
          reason: '悬浮钮=主题色实心（token 断言）');
    });

    testWidgets('无头像：字母 CircleAvatar 兜底 + 打卡页悬浮钮同 token',
        (tester) async {
      final adapter = _withMe((options, i) {
        return _json([
          _toolRecord('h1', 'habit',
              body: {'title': '早睡', 'content': ''}),
        ]);
      });
      final container = _widgetSetup(adapter);
      addTearDown(container.dispose);
      await _warmAuth(tester, container);
      await _pumpPage(tester, container, const HabitPage());
      expect(find.byType(CircleAvatar), findsWidgets,
          reason: '无头像走字母兜底');
      expect(find.textContaining('我 · '), findsOneWidget);
      final fab = tester.widget<FloatingActionButton>(
          find.widgetWithText(FloatingActionButton, '立个目标'));
      final fabCtx = tester.element(find.widgetWithText(FloatingActionButton,
          '立个目标'));
      expect(fab.backgroundColor, Theme.of(fabCtx).colorScheme.primary,
          reason: '打卡页悬浮钮=主题色实心（自建 scaffold 同源 toolFab）');
      // 打卡主操作按钮存在（tonal→solid 视觉切换，语义不变）
      expect(find.widgetWithText(FilledButton, '今天也一起坚持'), findsOneWidget);
    });
  });

  // ── ④ 愿望 meta 胶囊 ─────────────────────────────────────────
  group('④ 愿望 meta 胶囊 chips', () {
    testWidgets('393 宽：分类/约定/已完成 chips 不溢出（文案逐字保留）', (tester) async {
      _use393Viewport(tester);
      final adapter = _withMe((options, i) {
        return _json([
          _toolRecord('w1', 'wish', body: {
            'title': '去看海',
            'category': '旅行',
            'target': '2027-01-01',
            'done': true,
            'content': '',
          }),
        ]);
      });
      final container = _widgetSetup(adapter);
      addTearDown(container.dispose);
      await _warmAuth(tester, container);
      await _pumpPage(tester, container, const WishPage());
      expect(tester.takeException(), isNull, reason: '393 宽愿望 chips 无溢出');
      expect(find.text('旅行'), findsOneWidget);
      expect(find.textContaining('约定 2027-01-01'), findsOneWidget);
      expect(find.text('已完成'), findsOneWidget);
    });
  });

  // ── ⑤ 源码护栏：写死色零新增 ────────────────────────────────────
  group('⑤ 源码护栏（触碰文件写死色零新增）', () {
    test('甲组触碰文件不得出现 Color(0x…) 字面量', () {
      final files = [
        'lib/features/together/calendar_page.dart',
        'lib/features/together/tool_pages.dart',
        'lib/features/together/question_habit_pages.dart',
      ];
      final pattern = RegExp(r'Color\(0x');
      for (final f in files) {
        expect(pattern.hasMatch(File(f).readAsStringSync()), isFalse,
            reason: '$f 不得有写死色值字面量（走 colorScheme 令牌）');
      }
    });

    test('ToolTile 头像行走 AvatarMedia 统一路径（有头像分支源码断言）', () {
      final src = File('lib/features/together/tool_pages.dart').readAsStringSync();
      expect(src.contains('AvatarMedia('), isTrue,
          reason: '有头像走 AvatarMedia（统一鉴权缓存路径）');
      expect(src.contains('CircleAvatar'), isTrue,
          reason: '无头像字母兜底分支在位');
    });
  });
}
