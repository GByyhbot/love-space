// 2.4.1 C 组断言（⑫–⑯ + 通则 A/B）：
// ⑮账本记一笔底部 sheet（分类选择单回显）；⑯传照片专属 sheet（未选禁用
// +「上传 N 项」文案 + 关闭圆钮）；通则 A 护栏（录入表单一律 showFormSheet
// 底部 sheet）；通则 B 护栏（原生下拉全仓清零）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/features/timeline/photo_upload_sheet.dart';
import 'package:love_space/features/together/ledger_page.dart';

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

  /// 只保留代码行（注释里的历史字面量不算数，与 B 组 codeOnly 同手法）。
  String codeOnly(String s2) => s2
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  // ── ⑮ 账本记一笔 ────────────────────────────────────────────────
  testWidgets('🔴 第 15 项：记一笔改底部 sheet，分类走底部选择单点选回显',
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
        initialLocation: '/ledger',
        routes: [
          GoRoute(path: '/ledger', builder: (_, _) => const LedgerPage()),
        ],
      )),
    ));
    await tester.pumpAndSettle();
    // 打开记一笔 sheet
    await tester.tap(find.byTooltip('记一笔'));
    await tester.pumpAndSettle();
    // 底部 sheet 外壳在位（标题 + 关闭圆钮）
    expect(find.text('记一笔'), findsWidgets);
    expect(find.byTooltip('关闭'), findsWidgets);
    // 分类选择框 → 底部选择单
    await tester.tap(find.byKey(const Key('ledger-category-field')));
    await tester.pumpAndSettle();
    expect(find.text('分类'), findsWidgets);
    // 点选「旅行」→ 选择单关闭、选择框回显
    await tester.tap(find.byKey(const Key('selection-旅行')));
    await tester.pumpAndSettle();
    final catField =
        tester.widget<InkWell>(find.byKey(const Key('ledger-category-field')));
    expect(catField, isNotNull);
    // 回显文本「旅行」出现在 sheet 里（选择框值位）
    expect(find.text('旅行'), findsWidgets);
  });

  test('🔴 第 15 项护栏：账本表单无原生下拉、提交仍走 ledger 原数据口径', () {
    final src =
        codeOnly(File('lib/features/together/ledger_page.dart')
            .readAsStringSync());
    expect(src.contains('DropdownButtonFormField'), isFalse,
        reason: '账本分类原生下拉已改底部选择单');
    expect(src.contains('showSelectionSheet<String>'), isTrue);
    expect(src.contains('showFormSheet'), isFalse,
        reason: '账本表单自带 composer 同款外壳（抓手+圆钮+玻璃栏），不经共用骨架');
    expect(src.contains('GlassActionBar('), isTrue);
    expect(src.contains("'amount'"), isTrue);
    expect(src.contains("'category'"), isTrue);
    expect(src.contains("'date'"), isTrue);
    expect(src.contains("'content'"), isTrue,
        reason: '提交 changes 四键口径不变');
    expect(src.contains('ledgerSummary'), isTrue,
        reason: '汇总算法与统计不动');
  });

  // ── ⑯ 传照片专属 sheet ──────────────────────────────────────────
  testWidgets('🔴 第 16 项：未选媒体时「上传 0 项」禁用（双钮形态）',
      (tester) async {
    tester.view.physicalSize = const Size(393, 859);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = _FakeAdapter((o, i) {
        if (o.uri.path == '/api/records') {
          // 相册抓取（kind=album）：返回一个相册让选择框在位
          return _json([
            {'id': 'a1', 'kind': 'album', 'body': {'title': '旅行画册'}},
          ]);
        }
        return _json(<Object>[]);
      });
    final container = ProviderContainer(overrides: [
      api.dioProvider.overrideWith((ref) async => dio),
      api.baseProvider.overrideWith((ref) async => 'https://test.local'),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: const PhotoUploadSheet()),
      ),
    ));
    await tester.pumpAndSettle();
    // 外壳 + 虚线添加格 + 相册选择框在位
    expect(find.text('传照片'), findsOneWidget);
    expect(find.byKey(const Key('photo-add-tile')), findsOneWidget);
    expect(find.byKey(const Key('photo-album-field')), findsOneWidget);
    // 「上传 0 项」保存钮禁用（onPressed null）
    final saveBtn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '上传 0 项'));
    expect(saveBtn.onPressed, isNull, reason: '未选媒体禁用上传钮');
  });

  test('🔴 第 16 项护栏：抽屉「传照片」改开专属 sheet，composer 自动选图入口退役', () {
    final shell =
        codeOnly(File('lib/features/shell/shell_page.dart')
            .readAsStringSync());
    expect(shell.contains('showPhotoUploadSheet(context)'), isTrue);
    expect(shell.contains('autoPickMedia: true'), isFalse,
        reason: '传照片不再借 composer autoPickMedia 通道');
    final photo =
        codeOnly(File('lib/features/timeline/photo_upload_sheet.dart')
            .readAsStringSync());
    expect(photo.contains("'kind': 'post'"), isTrue);
    expect(photo.contains("'media'"), isTrue);
    expect(photo.contains("'album'"), isTrue,
        reason: 'POST body 只含 media+album（正文空）');
    expect(photo.contains('uploadChatMedia'), isTrue,
        reason: '两段式上传走 composer 同一管线');
    expect(photo.contains('newChatClientId'), isTrue,
        reason: 'client_id 幂等');
    expect(photo.contains('已上传到相册'), isTrue);
    expect(photo.contains('上传中…'), isTrue,
        reason: '上传中文字提示（非 busy spinner）');
  });

  // ── 通则 A：录入类弹窗/表单一律底部 sheet ────────────────────────
  test('🔴 通则 A：各录入表单改 showFormSheet 底部 sheet（源码护栏）', () {
    for (final f in [
      'lib/features/together/tool_pages.dart', // mood / note / wish
      'lib/features/together/question_habit_pages.dart', // question / answer / habit
      'lib/features/together/anniversary_page.dart',
      'lib/features/together/quest_page.dart',
      'lib/features/together/music_page.dart', // upload / edit meta
      'lib/features/album/album_page.dart', // create / rename
    ]) {
      final src = codeOnly(File(f).readAsStringSync());
      expect(src.contains('showFormSheet'), isTrue,
          reason: '$f 录入表单套同一外壳（showFormSheet）');
    }
    // period_form 自带 sheet 外壳（经周期章双呈现机制不经共用骨架）：
    // 抓手+圆钮+玻璃栏 + 调用点 showModalBottomSheet
    final periodForm =
        codeOnly(File('lib/features/period/period_form.dart')
            .readAsStringSync());
    expect(periodForm.contains('GlassActionBar('), isTrue,
        reason: 'period_form 表单套同一玻璃栏外壳');
    expect(periodForm.contains('Icons.close_rounded'), isTrue);
    final periodPage =
        codeOnly(File('lib/features/period/period_page.dart')
            .readAsStringSync());
    expect(periodPage.contains('showModalBottomSheet<bool>('), isTrue);
  });

  // ── 通则 B：原生下拉全仓清零 ──────────────────────────────────────
  test('🔴 通则 B：全仓无原生下拉 / SimpleDialog 选单（源码护栏）', () {
    final libDir = Directory('lib');
    final offenders = <String>[];
    for (final f in libDir.listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final src = codeOnly(f.readAsStringSync());
      if (src.contains('DropdownButtonFormField') ||
          src.contains('DropdownButton<') ||
          src.contains('SimpleDialog(')) {
        offenders.add(f.path);
      }
    }
    expect(offenders, isEmpty,
        reason: '点开选一个的原生下拉一律改 showSelectionSheet（通则 B）');
  });
}
