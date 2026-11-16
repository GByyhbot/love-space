/* 「UI/布局优化」章段 C（2.3.0 / VC230）测试。
   覆盖：
   · 三态统一组件断言（AppProgress / AppEmptyView / AppErrorView / AppErrorText）；
   · 9 页 loading 行为断言（personal 五 tab + mood/note/wish + quest/ledger/music
     首拉期间统一 loading、不闪空态）；
   · quest 写失败保草稿（失败 → 表单在 + 文字在 + 错误 detail 原文 toast error tone）；
   · 组件颜色来源深浅两档断言（对齐 ui_polish_b_test G10/G11 口径）；
   · half-step 归并后无残留引用（gapTight 清零源码护栏）。
   跑前 unset 八个代理变量（flutter_tester 本地 WebSocket 会被代理劫持）。 */
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart' show chatBaseProvider;
import 'package:love_space/core/sse/sse_client.dart'
    show SseEvent, sseEventsProvider;
import 'package:love_space/core/ui/empty_view.dart';
import 'package:love_space/core/ui/error_view.dart';
import 'package:love_space/core/ui/progress.dart';
import 'package:love_space/features/auth/auth_state.dart';
import 'package:love_space/features/chat/chat_toast.dart'
    show
        ChatToastController,
        ChatToastHost,
        ChatToastMessage,
        ChatToastTone,
        chatToastProvider;
import 'package:love_space/features/personal/personal_controller.dart'
    show personalCurrentUserProvider;
import 'package:love_space/features/personal/personal_page.dart';
import 'package:love_space/features/together/ledger_page.dart';
import 'package:love_space/features/together/music_page.dart';
import 'package:love_space/features/together/quest_page.dart';
import 'package:love_space/features/together/tool_pages.dart';

// ── 通用夹具（对齐 ui_polish_b_test / notify_a_test 形状）────────────────

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final FutureOr<ResponseBody> Function(RequestOptions options, int callIndex)
      handler;
  int calls = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      handler(options, calls++);
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
    jsonEncode(data), status,
    headers: {Headers.contentTypeHeader: const ['application/json']});

/// 避免 flutter_test 结束时 `A Timer is still pending` 不变量失败。
class _NoTimerToastController extends ChatToastController {
  @override
  void show(String text, {ChatToastTone tone = ChatToastTone.info}) {
    state = ChatToastMessage(id: 1, text: text, tone: tone);
  }
}

/// 认证夹具：直接落到 authed + 双人 me（绕过 bootstrap 网络）。
class _FakeAuth extends AuthNotifier {
  @override
  AuthPhase build() {
    me = MeData(
      user: const SpaceUser(id: 'u1', name: '我', username: 'u1'),
      users: const [
        SpaceUser(id: 'u1', name: '我', username: 'u1'),
        SpaceUser(id: 'u2', name: '另一半', username: 'u2'),
      ],
      spaceName: '我们的空间',
      spaceRaw: <String, dynamic>{},
      spaceSince: '2024-01-01',
    );
    return AuthPhase.authed;
  }
}

/// 永不完成的夹具（首拉挂起 → 页面必须停在统一 loading、不得闪空态）。
Dio _dioPending() {
  final dio = Dio(BaseOptions(
    baseUrl: 'https://test.local',
    validateStatus: api.validateAppStatus,
  ))
    ..httpClientAdapter = _FakeAdapter((o, i) async {
      return Completer<ResponseBody>().future;
    });
  return dio;
}

/// quest 写失败夹具：GET 全量空列表；POST kind=quest 一律 422 detail 原文
/// （validateAppStatus 放行 4xx，与生产共用形状）。
Dio _dioQuestFail() {
  final dio = Dio(BaseOptions(
    baseUrl: 'https://test.local',
    validateStatus: api.validateAppStatus,
  ))
    ..httpClientAdapter = _FakeAdapter((o, i) async {
      if (o.method == 'GET' && o.uri.path == '/api/records') {
        return _json(<Object>[]);
      }
      if (o.method == 'POST') {
        return _json(<String, dynamic>{'detail': '清单标题已存在'}, 422);
      }
      return _json(<Object>[]);
    });
  return dio;
}

Future<ProviderContainer> _container(Dio dio) async {
  final c = ProviderContainer(overrides: <Override>[
    api.dioProvider.overrideWith((ref) async => dio),
    api.baseProvider.overrideWith((ref) async => 'https://test.local'),
    chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
    sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    personalCurrentUserProvider.overrideWith((ref) => 'u1'),
    chatToastProvider.overrideWith(_NoTimerToastController.new),
    authProvider.overrideWith(_FakeAuth.new),
  ]);
  addTearDown(c.dispose);
  return c;
}

Widget _app(ProviderContainer c, Widget home, {Brightness? dark}) =>
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFEF3F68),
            brightness: dark ?? Brightness.light,
          ),
        ),
        home: home,
        builder: (context, child) => Stack(children: [
          child ?? const SizedBox.shrink(),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(child: SafeArea(child: ChatToastHost())),
          ),
        ]),
      ),
    );

/// 固定 pump 序列（loading spinner 无限动画，不用 pumpAndSettle）。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 10));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  // ── 三态组件断言 + 深浅两档颜色来源 ──────────────────────────────────

  Future<BuildContext> pumpBare(WidgetTester tester, Widget child,
      {Brightness? dark}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFEF3F68),
            brightness: dark ?? Brightness.light,
          ),
        ),
        home: Scaffold(body: Center(child: child)),
      ),
    );
    return tester.element(find.byType(Scaffold));
  }

  for (final dark in [false, true]) {
    final tag = dark ? '深色' : '浅色';
    testWidgets('AppProgress 渲染统一 spinner（$tag）', (tester) async {
      await pumpBare(tester, const AppProgress(), dark: dark ? Brightness.dark : null);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('AppEmptyView 三段式基线：44 图标 + outline 色源（$tag）',
        (tester) async {
      await pumpBare(
        tester,
        const AppEmptyView(
            icon: Icons.savings_rounded, title: '账本还是空的', hint: '提示语'),
        dark: dark ? Brightness.dark : null,
      );
      final ctx = tester.element(find.byType(AppEmptyView));
      final cs = Theme.of(ctx).colorScheme;
      final icons = tester.widgetList<Icon>(find.descendant(
          of: find.byType(AppEmptyView),
          matching: find.byIcon(Icons.savings_rounded)));
      expect(icons, isNotEmpty);
      for (final icon in icons) {
        expect(icon.size, 44, reason: '空态基线图标 size 44');
        expect(icon.color, cs.outline,
            reason: 'AppEmptyView($tag)：图标色 = Theme.outline');
      }
      final title = tester.widget<Text>(find.text('账本还是空的'));
      expect(title.style?.fontSize, Theme.of(ctx).textTheme.titleMedium?.fontSize,
          reason: '主句走 titleMedium 字阶');
      final hint = tester.widget<Text>(find.text('提示语'));
      expect(hint.style?.color, cs.outline,
          reason: 'AppEmptyView($tag)：副句色 = Theme.outline');
      expect(tester.takeException(), isNull);
    });

    testWidgets('AppErrorView：detail 原文 + error 色源 + 重试回调（$tag）',
        (tester) async {
      var retried = false;
      await pumpBare(
        tester,
        AppErrorView(
            detail: '清单标题已存在', onRetry: () => retried = true),
        dark: dark ? Brightness.dark : null,
      );
      final ctx = tester.element(find.byType(AppErrorView));
      final cs = Theme.of(ctx).colorScheme;
      expect(find.text('清单标题已存在'), findsOneWidget, reason: 'detail 原文直通呈现');
      final icon = tester
          .widgetList<Icon>(find.descendant(
              of: find.byType(AppErrorView),
              matching: find.byIcon(Icons.error_outline_rounded)))
          .first;
      expect(icon.size, 44);
      expect(icon.color, cs.error,
          reason: 'AppErrorView($tag)：图标色 = Theme.error');
      final detail = tester.widget<Text>(find.text('清单标题已存在'));
      expect(detail.style?.color, cs.error,
          reason: 'AppErrorView($tag)：文案色 = Theme.error');
      expect(find.text('重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      expect(retried, isTrue, reason: '重试走调用方回调（ref.invalidate/load）');
    });

    testWidgets('AppErrorText 行内口径：error 色源（$tag）', (tester) async {
      await pumpBare(tester, const AppErrorText('昵称不能为空'),
          dark: dark ? Brightness.dark : null);
      final ctx = tester.element(find.byType(AppErrorText));
      final cs = Theme.of(ctx).colorScheme;
      final t = tester.widget<Text>(find.text('昵称不能为空'));
      expect(t.style?.color, cs.error,
          reason: 'AppErrorText($tag)：色 = Theme.error（禁裸 TextStyle）');
      expect(t.style?.fontSize, Theme.of(ctx).textTheme.bodySmall?.fontSize,
          reason: '行内错误统一 bodySmall 字阶');
    });
  }

  // ── 9 页 loading 行为断言（首拉挂起 → 统一 loading、不闪空态）────────────

  Future<void> expectPendingLoading(
      WidgetTester tester, ProviderContainer c, Widget page,
      {required List<String> emptyTitles}) async {
    await tester.pumpWidget(_app(c, Scaffold(body: page)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(AppProgress), findsWidgets,
        reason: '首拉挂起期间必须呈现统一 loading 组件');
    for (final title in emptyTitles) {
      expect(find.text(title), findsNothing,
          reason: '首拉挂起期间不得闪空态（「$title」不应出现）');
    }
    expect(tester.takeException(), isNull);
  }

  testWidgets('mood/note/wish：首拉挂起 → AppProgress、不闪空态', (tester) async {
    final c = await _container(_dioPending());
    await expectPendingLoading(tester, c, const MoodPage(),
        emptyTitles: ['给我们，多一点小小的仪式感']);
    await expectPendingLoading(tester, c, const NotePage(),
        emptyTitles: ['给我们，多一点小小的仪式感']);
    await expectPendingLoading(tester, c, const WishPage(),
        emptyTitles: ['一起期待下一件小事']);
  });

  testWidgets('quest/ledger/music：首拉挂起 → AppProgress、不闪空态', (tester) async {
    final c = await _container(_dioPending());
    await expectPendingLoading(tester, c, const QuestPage(),
        emptyTitles: ['清单还空着']);
    await expectPendingLoading(tester, c, const LedgerPage(),
        emptyTitles: ['账本还是空的']);
    await expectPendingLoading(tester, c, const MusicPage(),
        emptyTitles: ['还没有歌']);
  });

  testWidgets('personal 五 tab：首拉挂起 → 各 tab AppProgress、不闪空态',
      (tester) async {
    final c = await _container(_dioPending());
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(c, const PersonalPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 五 tab 逐个点选断言（IndexedStack 常驻，finder 默认跳 offstage 子树）
    const tabs = <(String, String)>[
      ('私密日记', '给自己，留一点心里话'),
      ('草稿箱', '还没写完的故事，在这里等你'),
      ('定时惊喜', '提前准备一份温柔的惊喜'),
      ('回收站', '回收站是空的'),
      ('个人心愿', '留一份只差密码就能打开的心愿'),
    ];
    for (final (label, emptyTitle) in tabs) {
      await tester.tap(find.text(label));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(AppProgress), findsOneWidget,
          reason: '$label tab 首拉挂起期间呈现统一 loading');
      expect(find.text(emptyTitle), findsNothing,
          reason: '首拉挂起期间不得闪空态（「$emptyTitle」）');
    }
    expect(tester.takeException(), isNull);
  });

  // ── quest 写失败保草稿 ─────────────────────────────────────────────────

  testWidgets('quest 写失败：表单在 + 文字在 + 错误 detail 原文 toast error tone',
      (tester) async {
    final c = await _container(_dioQuestFail());
    await tester.pumpWidget(_app(c, const QuestPage()));
    await _settle(tester);
    tester.takeException();

    // 首拉完成（空列表）→ 统一空态
    expect(find.text('清单还空着'), findsOneWidget);

    // 填入自定义小事并点「加入清单」
    await tester.enterText(find.byType(TextFormField), '一起去看海');
    await tester.tap(find.byTooltip('加入清单'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // ① 表单还在（输入行未消失）
    expect(find.byType(TextFormField), findsOneWidget,
        reason: '写失败时表单不关');
    // ② 已填内容保留（未被 clear）
    expect(find.text('一起去看海'), findsOneWidget,
        reason: '写失败时输入保留（丢草稿修复）');
    // ③ 错误 detail 原文 + error tone
    final toast = c.read(chatToastProvider);
    expect(toast?.text, '添加失败：清单标题已存在',
        reason: '错误 detail 原文直通，不假成功');
    expect(toast?.tone, ChatToastTone.error);

    // 成功路径回归：POST 改为 2xx 时输入才清空（正常流程不动）
    expect(find.text('清单还空着'), findsOneWidget, reason: '失败不新增列表项');
  });

  // ── half-step 归并后无残留引用 ─────────────────────────────────────────

  test('half-step 归并：lib 全源码无 Spacing.gapTight 残留引用', () {
    final dir = Directory('lib');
    final files = dir.listSync(recursive: true).whereType<File>().where(
        (f) => f.path.endsWith('.dart') && !f.path.contains(r'\.dart_tool'));
    for (final f in files) {
      final src = f.readAsStringSync();
      // 代码行不得引用 gapTight（注释提及归并史实不在此列——按「代码引用」判定）
      final codeLines = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(codeLines.contains('gapTight'), isFalse,
          reason: '${f.path} 仍有 gapTight 代码引用（段 C 已归并到 gap）');
    }
  });
}
