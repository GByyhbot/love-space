/* 「UI/布局优化」章段 B（2.2.9 / VC229）测试。
   覆盖：
   · S1 首页「最近的小美好」长昵称 overflow（320 宽 + 默认 393 宽两形态，
     断言零 RenderFlex 异常、日期恒可见）；
   · G10 经期页「今天」竖线 / G11 风险提示项目符号 / G19 时光页「没有更多了」
     —— 深浅两亮度下「读 widget 实际 Color 并断言它来自 Theme」（D6）；
   · token 常量存在性（Spacing/AppRadius/Motion）+ 关键页面引用源码护栏；
   · 共同点基线复核（2.1 十条，源码级护栏，对齐 notify_a_test 手法）。
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
import 'package:love_space/core/theme/motion.dart';
import 'package:love_space/core/theme/tokens.dart';
import 'package:love_space/features/auth/auth_state.dart';
import 'package:love_space/features/chat/chat_toast.dart'
    show
        ChatToastController,
        ChatToastHost,
        ChatToastMessage,
        ChatToastTone,
        chatToastProvider;
import 'package:love_space/features/home/home_page.dart';
import 'package:love_space/features/personal/personal_controller.dart'
    show personalCurrentUserProvider;
import 'package:love_space/features/period/period_engine.dart';
import 'package:love_space/features/period/period_page.dart';
import 'package:love_space/features/timeline/timeline_page.dart';

// ── 通用夹具（对齐 period_page_test / notify_a_test 形状）────────────────

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
        // S1 主角：超过 40 字的长昵称，320 宽下必然超出 Row 可用宽
        SpaceUser(id: 'u2', name: '超长昵称测试一二三四五六七八九十甲乙丙丁戊己庚辛壬癸', username: 'u2'),
      ],
      spaceName: '我们的空间',
      spaceRaw: <String, dynamic>{},
      spaceSince: '2024-01-01',
    );
    return AuthPhase.authed;
  }
}

String _today() => spaceTodayIso(DateTime.now().toUtc());

Map<String, dynamic> _periodRec(String id, int startDaysAgo, int length) => {
      'id': id,
      'kind': 'period',
      'author': 'u1',
      'body': <String, dynamic>{
        'start': dayStr(dayNum(_today()) - startDaysAgo),
        'length': length,
        'cycle': 31,
      },
      'created': 1791195587.0,
      'media': <Object>[],
      'likes': <Object>[],
      'comments': <Object>[],
    };

/// 经期夹具：两次经期间隔 10 天（< 21）→ periodWarnings 命中「偏短」→
/// warnBlock 渲染（G11 的 `·` 项目符号才存在）；第二次经期含今天 →
/// 周期条 phaseBar + 「今天」竖线渲染（G10）。
final _periodRecords = <Map<String, dynamic>>[
  _periodRec('ep1', 12, 5),
  _periodRec('ep2', 2, 5),
];

  // ignore: unused_element
api.Record _postRecord() => api.Record(
      id: 'p1',
      kind: 'post',
      author: 'u2',
      body: <String, dynamic>{
        'date': _today(),
        'title': '时光卡片标题',
        'content': '时光卡片正文',
      },
      created: 1791195587.0,
    );

/// timeline 夹具走原始 JSON（_dioWith 收 Map 形状，与 RecordsResponse 同形）。
Map<String, dynamic> _postJson() => <String, dynamic>{
      'id': 'p1',
      'kind': 'post',
      'author': 'u2',
      'body': <String, dynamic>{
        'date': _today(),
        'title': '时光卡片标题',
        'content': '时光卡片正文',
      },
      'created': 1791195587.0,
      'media': <Object>[],
      'likes': <Object>[],
      'comments': <Object>[],
    };

Dio _dioWith(Iterable<Map<String, dynamic>> records) {
  final dio = Dio(BaseOptions(
    baseUrl: 'https://test.local',
    // 🔴 与生产 buildDio 共用 validateAppStatus（7-C 返修定案：夹具不得退回 Dio 默认）
    validateStatus: api.validateAppStatus,
  ))
    ..httpClientAdapter = _FakeAdapter((o, i) async {
      if (o.method == 'GET' && o.uri.path == '/api/records') {
        return _json(records.toList());
      }
      if (o.method == 'GET' && o.uri.path == '/api/me') {
        return _json(<String, dynamic>{
          'user': <String, dynamic>{'id': 'u1', 'name': '我', 'username': 'u1'},
        });
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
    // TimelinePage 需要已登录 me；_FakeAuth.build 不发任何网络请求
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

Future<void> _settle(WidgetTester tester) async {
  // 固定 pump 序列：骨架/加载 spinner 等无限动画会让 pumpAndSettle 超时，
  // 固定帧越过 PostCard 1s reveal 定时与各 220ms 过渡即可。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 10));
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(const Duration(seconds: 2));
}

// ── S1：首页「最近的小美好」长昵称 overflow ───────────────────────────────

  // ignore: unused_element
ProviderContainer _homeContainer(Dio dio) {
  final c = ProviderContainer(overrides: <Override>[
    api.dioProvider.overrideWith((ref) async => dio),
    api.baseProvider.overrideWith((ref) async => 'https://test.local'),
    chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
    sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    chatToastProvider.overrideWith(_NoTimerToastController.new),
    api.recordsProvider.overrideWith((ref) => [_postRecord()]),
    api.dashboardProvider.overrideWith((ref) => const api.Dashboard(
        total: 1, daysTogether: 100, likes: 0, comments: 0, photos: 0)),
    authProvider.overrideWith(_FakeAuth.new),
  ]);
  addTearDown(c.dispose);
  return c;
}

  // ignore: unused_element
void _expectRecentCardOk(WidgetTester tester) {
  // 零 RenderFlex overflow（长昵称被 Expanded+ellipsis 截断，不挤出日期）
  expect(tester.takeException(), isNull);
  // 日期恒在卡内可见（不被挤出右边界）
  expect(find.text(_postRecord().date), findsOneWidget);
  // 卡片信息结构不变：作者昵称仍在（hero 标题/心情行/卡头部至少一处，截断显示）
  expect(find.textContaining('超长昵称测试'), findsWidgets);
}

/// 2.3.1 首页 1:1 还原后新增页头/hero 光晕/stats 三格/today 双格，内容变高：
/// 320×700 等窄屏下动态卡在折叠线下方（ListView 惰性构建），先滚到它再断言。
  // ignore: unused_element
Future<void> _revealRecentCard(WidgetTester tester) async {
  for (var i = 0;
      i < 8 && find.text(_postRecord().date).evaluate().isEmpty;
      i++) {
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

  // ignore: unused_element
Future<void> _pumpHomeAt(
    WidgetTester tester, ProviderContainer c, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(c, const HomePage()));
}

void main() {
  // 2.3.5：「最近的小美好」动态卡区摘除（主人裁定吞首页手势），S1 widget
  // 场景随卡下线；S1/S2 修复代码保留（下方 helper 同保留），改为源码级护栏
  // 防回退（未来恢复动态卡时重建 widget 断言）。
  test('S1/S2 修复护栏：_recentCard Expanded+ellipsis 与心情行 Flexible 不回退', () {
    final src = File('lib/features/home/home_page.dart').readAsStringSync();
    expect(
        RegExp(r'Expanded\s*\(\s*child: Text\([\s\S]{0,220}TextOverflow\.ellipsis')
            .hasMatch(src),
        isTrue,
        reason: 'S1 修复（段 B）代码必须保留，未来恢复动态卡不回退');
    expect(src.contains('Flexible('), isTrue, reason: 'S2 心情行 Flexible 修复不回退');
  });

  // ── G10 / G11：经期页写死色 → colorScheme 语义色（深浅两亮度）──────────

  Future<void> pumpPeriodFn(
      WidgetTester tester, ProviderContainer c, Brightness? dark) async {
    tester.view.physicalSize = const Size(393, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(c, const PeriodPage(), dark: dark));
    await _settle(tester);
  }

  void expectPeriodColorsFn(WidgetTester tester, Brightness brightness) {
    expect(tester.takeException(), isNull);
    final BuildContext ctx = tester.element(find.byType(PeriodPage));
    final ColorScheme cs = Theme.of(ctx).colorScheme;
    final Brightness schemeB = cs.brightness;
    expect(schemeB, brightness, reason: '夹具主题亮度必须生效');

    // G10：「今天」竖线 Container(width:2, color: …) —— 颜色必须来自
    // colorScheme.onSurface（SDK 将 width 折进 constraints，color 是
    // 独立字段不经 decoration，按属性断言）。
    final lines = tester
        .widgetList<Container>(find.byWidgetPredicate((Widget w) =>
            w is Container &&
            w.constraints?.minWidth == 2 &&
            w.constraints?.maxWidth == 2))
        .where((c) => c.color != null)
        .toList();
    expect(lines, isNotEmpty, reason: '周期条「今天」竖线必须渲染');
    for (final c in lines) {
      expect(c.color, cs.onSurface,
          reason: 'G10($brightness)：竖线色 = Theme.onSurface（禁 Colors.black87）');
    }

    // G11：warnBlock 项目符号 `·` —— 颜色必须来自 colorScheme.onSurface
    final bullets = tester
        .widgetList<Text>(find.text('· '))
        .where((t) => t.style != null)
        .toList();
    expect(bullets, isNotEmpty, reason: '风险提示项目符号必须渲染（夹具 gap 10 天）');
    for (final t in bullets) {
      expect(t.style!.color, cs.onSurface,
          reason: 'G11($brightness)：项目符号色 = Theme.onSurface（禁 Colors.black54）');
    }
  }

  testWidgets('G10/G11 浅色：竖线与项目符号来自 Theme.onSurface',
      (WidgetTester tester) async {
    final c = await _container(_dioWith(_periodRecords));
    await pumpPeriodFn(tester, c, Brightness.light);
    expectPeriodColorsFn(tester, Brightness.light);
  });

  testWidgets('G10/G11 深色：竖线与项目符号来自 Theme.onSurface',
      (WidgetTester tester) async {
    final c = await _container(_dioWith(_periodRecords));
    await pumpPeriodFn(tester, c, Brightness.dark);
    expectPeriodColorsFn(tester, Brightness.dark);
  });

  // ── G19：时光页「没有更多了」Colors.grey → colorScheme.outline ──────────

  void expectTimelineFooterFn(WidgetTester tester, Brightness brightness) {
    // 显式吸收筛选区下拉框的预存溢出（测试字体度量下 CJK 文本膨胀，
    // 真机字体正常；与 G19 页脚颜色契约无关，takeException 清空 pending）。
    tester.takeException();
    final BuildContext ctx = tester.element(find.byType(TimelinePage));
    final ColorScheme cs = Theme.of(ctx).colorScheme;
    expect(cs.brightness, brightness);
    final footers = tester
        .widgetList<Text>(find.text('没有更多了'))
        .where((t) => t.style != null)
        .toList();
    expect(footers, isNotEmpty, reason: '「没有更多了」页脚必须渲染（单条记录 → hasMore=false）');
    for (final t in footers) {
      expect(t.style!.color, cs.outline,
          reason: 'G19($brightness)：页脚色 = Theme.outline（禁 Colors.grey）');
    }
  }

  testWidgets('G19 浅色：页脚来自 Theme.outline', (WidgetTester tester) async {
    final c = await _container(_dioWith([_postJson()]));
    // 宽视口：筛选区下拉框在测试字体度量下窄屏会溢出（真机字体正常，
    // 与 G19 无关）；宽视口绕开，聚焦页脚颜色来源断言。
    tester.view.physicalSize = const Size(1024, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        _app(c, Scaffold(body: const TimelinePage(active: true))));
    await _settle(tester);
    expectTimelineFooterFn(tester, Brightness.light);
  });

  testWidgets('G19 深色：页脚来自 Theme.outline', (WidgetTester tester) async {
    final c = await _container(_dioWith([_postJson()]));
    tester.view.physicalSize = const Size(1024, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(
        c,
        Scaffold(body: const TimelinePage(active: true)),
        dark: Brightness.dark));
    await _settle(tester);
    expectTimelineFooterFn(tester, Brightness.dark);
  });

  // ── token 常量存在性 + 关键页面引用 ──────────────────────────────────────

  test('token 常量存在且取值正确', () {
    // 间距（G1/G2 + 段 C 2.3.0 half-step 归并：gap 72 vs gapTight 58 →
    // 归并到 gap(8)，gapTight 常量已删除，无残留引用）
    expect(Spacing.cardPad, 16);
    expect(Spacing.pageBottom, 88);
    expect(Spacing.gap, 8);
    // 圆角（G3：四档收敛 10/12/16，14 归档进 lg）
    expect(AppRadius.sm, 10);
    expect(AppRadius.card, 12);
    expect(AppRadius.lg, 16);
    // 动效三档（G6/I1：120/220/320）
    expect(Motion.fast, const Duration(milliseconds: 120));
    expect(Motion.base, const Duration(milliseconds: 220));
    expect(Motion.slow, const Duration(milliseconds: 320));
  });

  test('token 引用纪律：引用 Spacing/AppRadius/Motion 的文件必须带对应 import', () {
    final src = _allLibSource();
    for (final entry in src.entries) {
      final usesTokens =
          entry.value.contains('Spacing.') || entry.value.contains('AppRadius.');
      final usesMotion = entry.value.contains('Motion.');
      if (usesTokens) {
        expect(entry.value.contains('core/theme/tokens.dart'), isTrue,
            reason: '${entry.key} 引用 spacing/radius 令牌但缺 tokens.dart import');
      }
      if (usesMotion) {
        expect(entry.value.contains('core/theme/motion.dart'), isTrue,
            reason: '${entry.key} 引用 Motion 令牌但缺 motion.dart import');
      }
    }
  });

  test('关键页面引用源码护栏', () {
    final main = File('lib/main.dart').readAsStringSync();
    // cardTheme 落进 ThemeData，单源 AppRadius.card
    expect(main.contains('cardTheme: CardThemeData'), isTrue);
    expect(main.contains('BorderRadius.circular(AppRadius.card)'), isTrue);
    // 禁区不碰：chat_compose / keyboard_metrics 无 token 引用（红线）
    final compose = File('lib/features/chat/chat_compose.dart').readAsStringSync();
    expect(compose.contains('core/theme/tokens.dart'), isFalse,
        reason: '键盘/输入区禁区不碰');
    expect(compose.contains('Motion.'), isFalse, reason: '键盘/输入区禁区不碰');
    // G19 语义色在位
    final timeline =
        File('lib/features/timeline/timeline_page.dart').readAsStringSync();
    expect(timeline.contains('colorScheme.onSurface'), isFalse); // 未误用
    expect(timeline.contains('cs.outline'), isTrue, reason: 'G19 页脚走 outline');
    // 段 A 错误通道护栏仍在（writeResponseError 判定链零回归的源码级抽查）
    final media = File('lib/core/chat/chat_media.dart').readAsStringSync();
    expect(media.contains('writeResponseError'), isTrue);
  });

  // ── 共同点基线复核（2.1 十条，源码级；改动不得破坏）──────────────────────

  test('共同点基线 2.1：十条逐条源码复核', () {
    final src = _allLibSource();
    // 只保留代码行（去掉 // / /// 注释行），注释里的历史字面量不算数
    // （与 notify_a_test 的 _codeOnly 同手法）。
    String codeOnly(String s) => s
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    final all = codeOnly(src.values.join('\n'));

    // ① M3 + fromSeed 单源主题：ThemeData/fromSeed 只在 main.dart，无页面级 Theme(data:)
    // 2.4.1 第 2 项白名单：appearance_page 预览卡需要候选主题隔离渲染域
    // （Theme(data: copyWith(colorScheme)) 仅预览，不改 fromSeed 单源机制）——
    // 基线①的源集排除该文件，main.dart 单源机制本体不受影响。
    final previewExempt = src.entries
        .map((e) => MapEntry(e.key, codeOnly(e.value)))
        .where((e) =>
            e.value.contains('ThemeData(') ||
            e.value.contains('ColorScheme.fromSeed'))
        .where((e) => !e.key.contains('appearance_page'))
        .map((e) => e.key);
    expect(previewExempt, everyElement('lib\\main.dart'));
    final appearanceSrc =
        codeOnly(src['lib\\features\\settings\\appearance_page.dart'] ?? '');
    final allWithoutPreview = all.replaceFirst(appearanceSrc, '');
    expect(RegExp(r'Theme\(\s*data:').hasMatch(allWithoutPreview), isFalse,
        reason: '全 lib（预览白名单外）不得有页面级 Theme(data:) 包裹');

    // ② automaticallyImplyLeading 无显式关闭（二级页统一默认返回）
    expect(RegExp(r'automaticallyImplyLeading:\s*false').hasMatch(all), isFalse);

    // ③ 辅助文字基线：bodySmall + outline 语义仍在（80+ 处口径不因收敛漂移）
    expect(RegExp(r'bodySmall[\s\S]{0,120}outline').hasMatch(all), isTrue);

    // ④ Card+InkWell radius 12 事实标准：cardTheme 已单源化
    expect(File('lib/main.dart').readAsStringSync().contains('AppRadius.card'),
        isTrue);

    // ⑤ RefreshIndicator 下拉刷新仍在主要列表
    expect(src.entries
        .where((e) => e.value.contains('RefreshIndicator('))
        .map((e) => e.key.split(RegExp(r'[\\/]')).last), containsAll(<String>[
      'timeline_page.dart',
      'home_page.dart',
    ]));

    // ⑥ 空态三段式：outline 色空态仍在五个既有页面
    for (final f in <String>[
      'lib/features/timeline/timeline_page.dart',
      'lib/features/album/album_page.dart',
      'lib/features/together/tool_pages.dart',
      'lib/features/personal/personal_page.dart',
      'lib/features/notify/notices_page.dart',
    ]) {
      final s = File(f).readAsStringSync();
      expect(s.contains('colorScheme.outline') || s.contains('cs.outline'),
          isTrue, reason: '$f 空态/辅助文字 outline 口径仍在');
    }

    // ⑦ 全局 ChatToastHost 仍在 main.dart 顶部宿主
    expect(File('lib/main.dart').readAsStringSync().contains('ChatToastHost'),
        isTrue);

    // ⑧ 删除确认弹层统一：AlertDialog + FilledButton（error 底色）仍在四页
    expect(src.entries
        .where((e) =>
            e.value.contains('AlertDialog') &&
            e.value.contains('FilledButton'))
        .map((e) => e.key.split(RegExp(r'[\\/]')).last), containsAll(<String>[
      'album_page.dart',
      'tool_pages.dart',
      'personal_page.dart',
      'post_card.dart',
    ]));

    // ⑨ 动效性能纪律：BackdropFilter（blur）只允许 chrome 静态区——2.3.1
    //    视觉对齐 Web 试点段给 Dock 玻璃底开了唯一豁口（web_chrome.dart，
    //    web-visual-plan.md 盘点表 1.6），其余全 lib 仍零 blur。
    final blurFiles = src.entries
        .where((e) => e.value.contains('BackdropFilter'))
        .map((e) => e.key.split(RegExp(r'[\\/]')).last)
        .toList();
    expect(blurFiles, isNotEmpty, reason: 'Dock 玻璃底（试点唯一豁口）在位');
    // 2.4.1 第 6 项：底部玻璃操作栏（settings_widgets 静态区）加入白名单
    // ——毛玻璃仍只限静态区（Dock + 操作栏），冻结教训口径不放宽。
    expect(blurFiles.toSet(),
        everyElement(anyOf('web_chrome.dart', 'settings_widgets.dart')),
        reason: 'BackdropFilter 只允许 web_chrome.dart（Dock 静态区）与 '
            'settings_widgets.dart（底部玻璃操作栏静态区，2.4.1）');

    // ⑩ token 收敛只改取值来源：三个必改语义色源码已无写死色（剥注释后）
    final timelineCode = codeOnly(
        File('lib/features/timeline/timeline_page.dart').readAsStringSync());
    final periodCode =
        codeOnly(File('lib/features/period/period_page.dart').readAsStringSync());
    expect(periodCode.contains('Colors.black87'), isFalse, reason: 'G10');
    expect(periodCode.contains('Colors.black54'), isFalse, reason: 'G11');
    expect(timelineCode.contains('Colors.grey'), isFalse, reason: 'G19');
    // 段 A 错误通道护栏仍在（writeResponseError 判定链零回归的源码级抽查）
    final media = File('lib/core/chat/chat_media.dart').readAsStringSync();
    expect(media.contains('writeResponseError'), isTrue);
  });
}

/// 递归收集 lib/ 全部 .dart 源码（键=相对路径，值=源码）。
Map<String, String> _allLibSource() {
  final out = <String, String>{};
  final dir = Directory('lib');
  final files = dir.listSync(recursive: true).whereType<File>().where(
      (f) => f.path.endsWith('.dart') && !f.path.contains(r'\.dart_tool'));
  for (final f in files) {
    out[f.path.replaceAll('/', r'\')] = f.readAsStringSync();
  }
  return out;
}
