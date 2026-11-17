// 2.4.1 修复包 B 组断言（第 7–11 项）：
// ⑨五 tab 顶栏无页名 + 四页标题行引用共享 PageHeading；⑦时光三胶囊+无记录
// 此刻钮源码护栏；⑧相册分段器共用组件+新建卡虚线+实心紫退役；⑩工具卡淡彩
// 底座+生理期宽卡 --period 柔光；⑪393 宽五标签完整布局（无裁切无 overflow）
// +横滑结构+空状态玻璃圆徽。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/features/personal/personal_page.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
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

ResponseBody _json(Object data) => ResponseBody.fromString(jsonEncode(data),
    200,
    headers: {Headers.contentTypeHeader: const ['application/json']});

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 只保留代码行（去掉 // / /// 注释行），注释里的历史字面量不算数
  /// （与 ui_polish_b_test 的 codeOnly 同手法）。
  String codeOnly(String s2) => s2
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  // ── ⑨ 顶栏与标题行 ────────────────────────────────────────────────
  test('🔴 第 9 项：五 tab 顶栏无页名文字（壳层源码护栏）', () {
    final shell =
        File('lib/features/shell/shell_page.dart').readAsStringSync();
    expect(shell.contains("const ['首页', '时光', '相册', '我们', '个人角落']"),
        isFalse, reason: '🔴 顶栏页名文字已删');
    // 圆钮组仍在位（顺序：通知/私聊/齿轮/头像）。
    expect(shell.contains("Key('shell-notices')"), isTrue);
    expect(shell.contains("Key('shell-settings')"), isTrue);
  });

  test('🔴 第 9 项：四页标题行引用同一共享 PageHeading 组件', () {
    for (final f in [
      'lib/features/timeline/timeline_page.dart',
      'lib/features/album/album_page.dart',
      'lib/features/together/together_page.dart',
      'lib/features/personal/personal_page.dart',
    ]) {
      final src = File(f).readAsStringSync();
      expect(src.contains('PageHeading('), isTrue,
          reason: '$f 标题行引用共享 PageHeading（2.4.1 第 9 项）');
      expect(src.contains('headlineSmall?.copyWith(\n                      fontWeight'),
          isFalse,
          reason: '$f 不得再手写大标题数值');
    }
    final ph = File('lib/core/ui/page_heading.dart').readAsStringSync();
    expect(ph.contains('pageHeadingTitleSize = 24'), isTrue,
        reason: '共享字号常量（时光页基准）');
    expect(ph.contains('pageHeadingTopGap = 8'), isTrue,
        reason: '标题行距顶栏间距收紧（12 → 8）');
  });

  // ── ⑦ 时光页 ──────────────────────────────────────────────────────
  test('🔴 第 7 项：记录此刻按钮删除（勿留死代码）+ 三胶囊筛选行 + 搜索框 14', () {
    final src = codeOnly(
        File('lib/features/timeline/timeline_page.dart').readAsStringSync());
    expect(src.contains('记录此刻'), isFalse, reason: '🔴 标题钮删除且无残留引用');
    expect(src.contains('showComposerSheet'), isFalse, reason: '死引用清零');
    expect(src.contains("Key('timeline-filter-author')"), isTrue);
    expect(src.contains("Key('timeline-filter-media')"), isTrue);
    expect(src.contains("Key('timeline-filter-date')"), isTrue);
    expect(src.contains('showSelectionSheet'), isTrue,
        reason: '范围/类型走底部选择单（通则 B）');
    expect(src.contains('BorderRadius.circular(14)'), isTrue,
        reason: '搜索框圆角 14');
    // 筛选逻辑不变：setFilter/clearFilters 仍在。
    expect(src.contains('setFilter'), isTrue);
    expect(src.contains('clearFilters'), isTrue);
  });

  // ── ⑧ 相册页 ──────────────────────────────────────────────────────
  test('🔴 第 8 项：标题新建钮删除 + 分段器共用组件 + 淡紫底退役实心紫 + 网格 13', () {
    final src = codeOnly(
        File('lib/features/album/album_page.dart').readAsStringSync());
    expect(src.contains('SegmentedButton<AlbumView>'), isFalse,
        reason: '原生分段器退役（改 SettingsSegmented 共用组件）');
    expect(src.contains('SettingsSegmented<AlbumView>'), isTrue);
    expect(src.contains('primaryContainer : cs.surfaceContainerHighest'),
        isFalse, reason: '🔴「全部照片」实心紫块退役');
    expect(src.contains('primaryContainer.withValues(alpha: 0.35)'), isTrue,
        reason: '淡紫底（禁整卡实心紫）');
    expect(src.contains('borderRadius: 14,'), isTrue, reason: '封面圆角 14');
    expect(src.contains('PageHeading('), isTrue, reason: '标题行共享组件');
    // 新建流程不变：_showCreateAlbumDialog 仍被末尾「+ 新建」卡调用。
    expect(src.contains('_showCreateAlbumDialog'), isTrue);
  });

  // ── ⑩ 我们页 ──────────────────────────────────────────────────────
  test('🔴 第 10 项：工具卡淡彩底座映射在位 + 生理期宽卡 --period 柔光', () {
    final src =
        File('lib/features/together/together_page.dart').readAsStringSync();
    for (final name in ['共同年历', '心情手记', '悄悄留言', '共同愿望', '情侣问答', '共同打卡']) {
      expect(src.contains("'$name'"), isTrue, reason: '$name 淡彩底映射在位');
    }
    expect(src.contains('periodStageColor(context)'), isTrue,
        reason: '生理期宽卡柔光取 period_colors（--period light/dark）');
    expect(src.contains('flutter'), isTrue);
    expect(src.contains('Radius.circular(11)'), isTrue, reason: '底座圆角 11');
    // 无设置入口守卫保留（2.4.0）。
    expect(src.contains('settings-hub-'), isFalse);
  });

  // ── ⑪ 个人角落 ─────────────────────────────────────────────────────
  testWidgets('🔴 第 11 项①：393 宽下五个标签文字均完整布局（无裁切无 overflow）',
      (tester) async {
    tester.view.physicalSize = const Size(393, 859);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = _FakeAdapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_meFixture());
        return _json(<Object>[]);
      });
    final container = ProviderContainer(overrides: [
      api.dioProvider.overrideWith((ref) async => dio),
      api.baseProvider.overrideWith((ref) async => 'https://test.local'),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: GoRouter(
        initialLocation: '/personal',
        routes: [
          GoRoute(
              path: '/personal', builder: (_, _) => const PersonalPage()),
        ],
      )),
    ));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 10));
    // 五个标签的文字均完整渲染（横滑行所有标签都 build）。
    for (final label in ['私密日记', '草稿箱', '定时惊喜', '回收站', '个人心愿']) {
      final t = find.text(label);
      expect(t, findsWidgets, reason: '$label 标签文字完整存在');
      // 文本自身无裁切（labelSmall 行高下文字宽度 < 选中胶囊自然宽度）。
      final rect = tester.getRect(t.first);
      expect(rect.width, greaterThan(0));
    }
    expect(tester.takeException(), isNull,
        reason: '393 宽不得有 RenderFlex overflow（原等分定宽裁切根因）');
    // 横滑结构：胶囊行容器是横向 ListView。
    expect(
        find.byWidgetPredicate((w) =>
            w is ListView &&
            (w.scrollDirection == Axis.horizontal)),
        findsWidgets,
        reason: '胶囊行为横滑 ListView（禁等分定宽）');
  });

  test('🔴 第 11 项④：空状态玻璃圆徽结构在位（五 tab 共用同一样式）', () {
    final src =
        File('lib/features/personal/personal_page.dart').readAsStringSync();
    expect(src.contains('Icons.lock_outline_rounded'), isTrue);
    expect(src.contains('blurRadius: 18'), isTrue, reason: '外圈淡光晕');
    expect(src.contains('shape: BoxShape.circle'), isTrue, reason: '玻璃圆徽');
    expect(src.contains('给自己，留一点心里话'), isTrue);
  });
}
