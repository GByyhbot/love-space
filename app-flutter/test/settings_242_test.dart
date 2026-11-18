// 2.4.2 断言（4 项）：
// 第 1 项：chat-wallpaper 色卡网格等分拉满（与分段器/预览区同缘）+ 说明
// 文案去重（只留分区末尾注脚）；第 2 项：传照片 album_only 两路径 body
// 差异护栏（photo sheet 带标记 / composer 发动态绝不带 / App 时光无客户端
// 过滤）；第 3 项：角落页第五颗胶囊可滑出可点（末尾留白 40 + 渐隐
// IgnorePointer + 半露点击滚位）；第 4 项：五页标题行全引用 PageHeading
// （源码护栏）+ 393 宽标题左缘/距顶一致性（布局断言，修复对象首页与我们页）。
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
import 'package:love_space/features/auth/auth_state.dart'
    show authProvider, AuthNotifier, AuthPhase, MeData, SpaceUser;
import 'package:love_space/features/chat/chat_toast.dart' show ChatToastHost;
import 'package:love_space/features/home/home_page.dart';
import 'package:love_space/features/personal/personal_page.dart';
import 'package:love_space/features/settings/chat_wallpaper_page.dart';
import 'package:love_space/features/timeline/timeline_page.dart';
import 'package:love_space/features/together/together_page.dart';

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

Map<String, Object> _meFixture() => {
      'user': {
        'id': 'u1', 'name': '我', 'username': 'u1',
        'avatar': '',
      },
      'users': [
        {'id': 'u1', 'name': '我', 'username': 'u1', 'avatar': ''},
        {'id': 'u2', 'name': 'TA', 'username': 'u2', 'avatar': ''},
      ],
      'space': {},
      'unread': 0,
      'chat_unread': 0,
    };

class _FakeAuth extends AuthNotifier {
  @override
  AuthPhase build() {
    me = MeData(
      user: const SpaceUser(id: 'u1', name: '我', username: 'u1'),
      users: const [
        SpaceUser(id: 'u1', name: '我', username: 'u1'),
        SpaceUser(id: 'u2', name: 'TA', username: 'u2'),
      ],
      spaceName: '我们的空间',
      spaceRaw: <String, dynamic>{},
      spaceSince: '2024-01-01',
    );
    return AuthPhase.authed;
  }
}

ProviderContainer _setup(_FakeAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  return ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    // 直接注入已登录 me：真实 bootstrap 走线路探测/网络，widget 测试等不到
    authProvider.overrideWith(_FakeAuth.new),
    chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
    mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
  ]);
}

Future<void> pumpPage(WidgetTester tester, ProviderContainer container,
    {required Widget page}) async {
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
  // 等待 authProvider bootstrap（线路探测带真实时钟 deadline）
  await tester.pump(const Duration(seconds: 10));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String codeOnly(String s2) => s2
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  const footnote = '你们各看各的背景，互不打扰；但谁都能替对方换一张——上面选「TA 的手机」就行。';

  // ── 第 1 项：色卡网格 + 文案去重 ──────────────────────────────────
  test('🔴 第 1 项护栏：色卡改 4 列等分 GridView，去固定卡宽', () {
    final src =
        codeOnly(File('lib/features/chat/wallpaper_sheet.dart')
            .readAsStringSync());
    expect(src.contains('crossAxisCount: 4'), isTrue,
        reason: '色卡 4 列等分拉满');
    expect(src.contains('width: 86'), isFalse, reason: '去固定卡宽 86');
    expect(src.contains('WallpaperSheet'), isTrue);
  });

  test('🔴 第 1 项护栏：说明文案全文只留注脚一份', () {
    final sheet =
        codeOnly(File('lib/features/chat/wallpaper_sheet.dart')
            .readAsStringSync());
    expect(sheet.contains(footnote), isFalse,
        reason: '面板内文案已删（保留设置页注脚那份）');
    final page =
        codeOnly(File('lib/features/settings/chat_wallpaper_page.dart')
            .readAsStringSync());
    expect(page.contains(footnote), isTrue, reason: '分区末尾注脚保留');
  });

  testWidgets('🔴 第 1 项：393 宽设置页色卡网格与预览区左右同缘 + 文案仅一份',
      (tester) async {
    tester.view.physicalSize = const Size(393, 859);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final adapter = _FakeAdapter((o, i) {
      if (o.uri.path == '/api/me') return _json(_meFixture());
      return _json(<Object>[]);
    });
    final container = _setup(adapter);
    addTearDown(container.dispose);
    await pumpPage(
        tester, container,
        page: const Scaffold(body: ChatWallpaperPage()));
    // 渲染断点诊断：AppBar 标题在 / 预览区在（说明 me 已就绪走到色卡后）
    expect(find.text('聊天背景'), findsOneWidget);
    expect(find.text('背景遮罩'), findsOneWidget,
        reason: '面板渲染到了滑杆（me 已就绪、色卡 GridView 在其上方应已 build）');
    // 文案只出现一次（注脚）
    expect(find.text(footnote), findsOneWidget);
    // 色卡网格与预览区左右同缘同宽
    final grid = tester.getRect(find.byKey(const Key('wallpaper-swatches')));
    final preview = tester.getRect(find.byKey(const Key('wallpaper-preview')));
    expect(grid.left, closeTo(preview.left, 0.5),
        reason: '色卡网格左缘与预览区对齐');
    expect(grid.width, closeTo(preview.width, 0.5),
        reason: '色卡网格与预览区同宽（整行拉满）');
  });

  // ── 第 2 项：album_only 两路径 body 差异 ──────────────────────────
  test('🔴 第 2 项护栏：传照片 sheet 带标记、composer 发动态绝不带', () {
    final photo =
        codeOnly(File('lib/features/timeline/photo_upload_sheet.dart')
            .readAsStringSync());
    expect(photo.contains("'album_only': true"), isTrue,
        reason: '传照片创建的记录带 album_only=true');
    final composer =
        codeOnly(File('lib/features/timeline/composer_sheet.dart')
            .readAsStringSync());
    expect(composer.contains('album_only'), isFalse,
        reason: '正常发动态（哪怕纯图无字）绝不带标记');
    // App 时光页不写客户端过滤（服务端已过滤，防双份逻辑漂移）
    final timelineData =
        codeOnly(File('lib/core/timeline/timeline_data.dart')
            .readAsStringSync());
    expect(timelineData.contains('album_only'), isFalse);
    final timelinePage =
        codeOnly(File('lib/features/timeline/timeline_page.dart')
            .readAsStringSync());
    expect(timelinePage.contains('album_only'), isFalse);
  });

  // ── 第 3 项：胶囊第五颗可滑出可点 ──────────────────────────────────
  test('🔴 第 3 项护栏：末尾留白 40 + 渐隐 IgnorePointer + 半露点击滚位', () {
    final src =
        codeOnly(File('lib/features/personal/personal_page.dart')
            .readAsStringSync());
    expect(src.contains('fromLTRB(12, 0, 40, 0)'), isTrue,
        reason: '滚动行末尾留白 40（≥24dp + 渐隐层）');
    final fadeIdx = src.indexOf('Positioned(\n                right: 0,');
    final fadeBlock = src.substring(
        fadeIdx >= 0 ? fadeIdx : src.length,
        fadeIdx >= 0 ? fadeIdx + 400 : src.length);
    expect(fadeBlock.contains('IgnorePointer'), isTrue,
        reason: '渐隐层只做视觉，不吸收点击');
    expect(src.contains('_revealTab'), isTrue,
        reason: '半露点击自动滚到完全可见（先选中后滚位口径）');
  });

  testWidgets('🔴 第 3 项：393 宽滚到末尾「个人心愿」完整可见且点选成功',
      (tester) async {
    tester.view.physicalSize = const Size(393, 859);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final adapter = _FakeAdapter((o, i) {
      if (o.uri.path == '/api/me') return _json(_meFixture());
      return _json(<Object>[]);
    });
    final container = _setup(adapter);
    addTearDown(container.dispose);
    await pumpPage(tester, container, page: const PersonalPage());
    // 诊断锚点：第一颗胶囊在视口内必然 build
    expect(find.text('私密日记'), findsOneWidget);

    final wish = find.byKey(const Key('personal-tab-personal_wish'));
    expect(find.text('个人心愿'), findsOneWidget,
        reason: '五颗标签初始即全量 build（IndexedStack 常驻同口径）');
    // 拖标签行到末尾：scrollUntilVisible 定向滚横向胶囊行
    //（settings_241_b 教训：需显式指定 scrollable，避免页面纵向滚动接手）。
    // 胶囊行是页面上第一个 Scrollable（IndexedStack 内部的纵向滚动在后）
    final hList = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(wish, 100, scrollable: hList);
    await tester.pumpAndSettle();
    expect(wish, findsOneWidget, reason: '拖到末尾后第五颗已 build');
    // 末颗完全可见：右缘在渐隐层（30px）之内、左缘在视口内
    final rect = tester.getRect(wish);
    expect(rect.right, lessThanOrEqualTo(393 - 30 + 0.5),
        reason: '第五颗滚到末尾后完整滚出渐隐区');
    expect(rect.left, greaterThanOrEqualTo(0));
    // 点选成功（选中态切换）
    await tester.tap(wish);
    await tester.pumpAndSettle();
    final chip =
        tester.widget<ChoiceChip>(find.byKey(const Key('personal-tab-personal_wish')));
    expect(chip.selected, isTrue, reason: '第五颗可点选成功');
    // 拖标签行不滚页面：主标题仍停在顶部（页面纵向滚动位置未变）
    final heading = tester.getRect(find.text('我的小角落'));
    expect(heading.top, lessThanOrEqualTo(60), reason: '拖标签行滚的是标签行');
  });

  // ── 第 4 项：五页标题行统一 PageHeading ──────────────────────────
  test('🔴 第 4 项护栏：五页标题行全部引用共享 PageHeading（不再四页接线）', () {
    for (final f in [
      'lib/features/timeline/timeline_page.dart',
      'lib/features/album/album_page.dart',
      'lib/features/together/together_page.dart',
      'lib/features/personal/personal_page.dart',
      'lib/features/home/home_page.dart',
    ]) {
      final src = codeOnly(File(f).readAsStringSync());
      expect(src.contains('PageHeading('), isTrue,
          reason: '$f 标题行引用共享 PageHeading');
    }
    // 首页私有标题行实现已删
    final home =
        codeOnly(File('lib/features/home/home_page.dart').readAsStringSync());
    expect(home.contains('class _PageHeading'), isFalse,
        reason: '首页私有标题行删除');
    // 我们页容器 padding 归零（原 16+12 与 PageHeading 自带 16/8 叠加成
    // 左 32/顶 20 的根因）；首页容器 18→16 且顶部归零
    final together =
        codeOnly(File('lib/features/together/together_page.dart')
            .readAsStringSync());
    expect(together.contains('EdgeInsets.only(bottom: Spacing.pageBottom)'),
        isTrue, reason: '我们页容器 padding 归零');
    expect(home.contains('fromLTRB(\n              16, 0, 16,'),
        isTrue, reason: '首页容器左右 16、顶部归零');
  });

  testWidgets('🔴 第 4 项：393 宽三页标题左缘/距顶一致（首页/我们页 vs 时光参照）',
      (tester) async {
    tester.view.physicalSize = const Size(393, 859);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final adapter = _FakeAdapter((o, i) {
      if (o.uri.path == '/api/me') return _json(_meFixture());
      return _json(<Object>[]);
    });

    Future<Rect> headingRect(WidgetTester tester, Widget page, String text) async {
      final container = _setup(adapter);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => Stack(children: [
            child ?? const SizedBox.shrink(),
            const Positioned(
                top: 0, left: 0, right: 0,
                child: IgnorePointer(child: SafeArea(child: ChatToastHost()))),
          ]),
          // Material 祖先：页内 TextField/InkWell 在裸 pump 下无 Material
          // 会逐帧抛异常（时光页搜索框等 10 处），套一层不占布局的 Material。
          home: Material(child: page),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      final rect = tester.getRect(find.text(text));
      container.dispose();
      return rect;
    }

    final homeRect = await headingRect(tester, const HomePage(), '我们的每一天');
    final togetherRect =
        await headingRect(tester, const TogetherPage(active: true), '关于我们，还有好多好多');
    final timelineRect =
        await headingRect(tester, const TimelinePage(active: true), '时光慢慢，爱意满满');
    // 左缘一致（PageHeading 自带 16）
    expect(homeRect.left, closeTo(timelineRect.left, 0.5),
        reason: '首页标题左缘与时光页一致（原 18 vs 16）');
    expect(togetherRect.left, closeTo(timelineRect.left, 0.5),
        reason: '我们页标题左缘与时光页一致（原双重 32）');
    // 距顶一致（PageHeading 顶 8）
    expect(homeRect.top, closeTo(timelineRect.top, 0.5),
        reason: '首页标题距顶与时光页一致（原 18 vs 8）');
    expect(togetherRect.top, closeTo(timelineRect.top, 0.5),
        reason: '我们页标题距顶与时光页一致（原 20 vs 8）');
  });
}
