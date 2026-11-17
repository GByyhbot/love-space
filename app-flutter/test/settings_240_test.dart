// 2.4.0 设置搬家 + 入口拆分段防回归：四独立页内容隔离、聊天背景/气泡
// 同源护栏、顶栏齿轮入口源码护栏。数据层契约在 settings_d_test（不动）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/features/settings/appearance_page.dart';
import 'package:love_space/features/settings/cover_page.dart';
import 'package:love_space/features/settings/links_page.dart';

import 'package:dio/dio.dart';
import 'package:love_space/core/api/api_client.dart' as api;

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions options) handler;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return handler(options);
  }
}

Future<Widget> _wrap(WidgetTester tester, Widget child,
    {Future<ResponseBody> Function(RequestOptions)? onFetch}) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = _FakeAdapter(
        onFetch ?? (o) async => ResponseBody.fromString('[]', 200));
  final container = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
  ]);
  addTearDown(container.dispose);
  final w = UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: child)));
  await tester.pumpWidget(w);
  await tester.pumpAndSettle();
  return w;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('主题与外观页：本节内容在位 + 其他节标志文案隔离', (tester) async {
    await _wrap(tester, const AppearancePage());
    expect(find.text('主题配色　·　两个人共用'), findsOneWidget,
        reason: '本节标志文案在位');
    expect(find.text('启用轻柔动效'), findsOneWidget);
    // 隔离：其他节标志文案不得出现在本页。
    expect(find.text('首页封面照片'), findsNothing, reason: '主页背景节已拆走');
    expect(find.text('看看现在哪条线路最快，也可以手动切换。'), findsNothing,
        reason: '链路节已拆走');
    expect(find.text('邀请你，住进我的小世界'), findsNothing, reason: '邀请卡不在此页');
  });

  testWidgets('主页背景页：本节内容在位 + 其他节标志文案隔离', (tester) async {
    await _wrap(tester, const CoverPage());
    expect(find.text('首页封面照片'), findsOneWidget);
    expect(find.text('选择一张照片作为我们的空间封面'), findsOneWidget);
    expect(find.text('主题配色　·　两个人共用'), findsNothing, reason: '主题节已拆走');
    expect(find.text('看看现在哪条线路最快，也可以手动切换。'), findsNothing);
  });

  testWidgets('线路与连接页：本节内容在位 + 其他节标志文案隔离', (tester) async {
    await _wrap(
      tester,
      const LinksPage(),
      onFetch: (o) async => ResponseBody.fromString('[]', 200),
    );
    expect(find.text('看看现在哪条线路最快，也可以手动切换。'), findsOneWidget);
    // 检测按钮 key 在位（结果文案依赖 /api/routes 数据形状，不在此断言）。
    expect(find.byKey(const Key('settings-link-probe')), findsOneWidget);
    expect(find.text('主题配色　·　两个人共用'), findsNothing);
    expect(find.text('首页封面照片'), findsNothing);
  });

  test('🔴 同源护栏：聊天背景/气泡设置页与聊天页面板共用同一组件', () {
    final page = File('lib/features/settings/chat_wallpaper_page.dart')
        .readAsStringSync();
    expect(page.contains('WallpaperSheet(embedded: true)'), isTrue,
        reason: '设置页必须内嵌 WallpaperSheet 本体（与聊天页 sheet 同一实现）');
    expect(page.contains("chat_bg:"), isFalse, reason: '不得复制第二套读写实现');
    expect(page.contains("dio.put("), isFalse, reason: '不得直发 PUT');
    final bubblePage =
        File('lib/features/settings/chat_bubble_page.dart').readAsStringSync();
    expect(bubblePage.contains('BubbleSkinSheet(embedded: true)'), isTrue,
        reason: '设置页必须内嵌 BubbleSkinSheet 本体');
    expect(bubblePage.contains("chat_bubble:"), isFalse,
        reason: '不得复制第二套读写实现');
    expect(bubblePage.contains("dio.put("), isFalse, reason: '不得直发 PUT');
    // sheet 本体的 embedded 开关在位（同一组件两处消费的机制证明）。
    final wp = File('lib/features/chat/wallpaper_sheet.dart').readAsStringSync();
    expect(wp.contains('class WallpaperSheet'), isTrue);
    expect(wp.contains('this.embedded'), isTrue);
    final bp =
        File('lib/features/chat/bubble_skin_sheet.dart').readAsStringSync();
    expect(bp.contains('class BubbleSkinSheet'), isTrue);
    expect(bp.contains('this.embedded'), isTrue);
  });

  test('🔴 顶栏齿轮源码护栏：齿轮是顶栏组件本体（WebTopIconButton），无 overlay', () {
    final shell = File('lib/features/shell/shell_page.dart').readAsStringSync();
    expect(shell.contains("Key('shell-settings')"), isTrue,
        reason: '齿轮钮稳定 key 在位');
    expect(shell.contains("tooltip: '设置'"), isTrue);
    expect(shell.contains("context.push('/settings')"), isTrue);
    // 齿轮必须经由 WebTopIconButton（顶栏组件本体），禁止独立浮层 overlay。
    final gearIdx = shell.indexOf("Key('shell-settings')");
    final widgetIdx = shell.lastIndexOf('WebTopIconButton(', gearIdx);
    expect(widgetIdx, greaterThan(-1), reason: '齿轮用顶栏同款 WebTopIconButton');
    // 顶栏按钮区不得出现 Overlay/Positioned 包裹的独立齿轮浮层。
    expect(shell.contains('shell-settings-overlay'), isFalse);
  });

  test('🔴 退役护栏：全量设置页已删，无死路由死入口', () {
    expect(File('lib/features/settings/settings_page.dart').existsSync(),
        isFalse, reason: '全量长设置页退役（文件已删）');
    final together = File('lib/features/together/together_page.dart')
        .readAsStringSync();
    expect(together.contains('settings-hub-'), isFalse,
        reason: '「我们」页 8 张设置卡 key 零残留');
    expect(together.contains("push('/settings'"), isFalse,
        reason: '「我们」页不再导向设置');
    expect(together.contains('_settingsCard'), isFalse);
    final mainSrc = File('lib/main.dart').readAsStringSync();
    expect(mainSrc.contains('const SettingsHomePage()'), isTrue,
        reason: '/settings 由设置主页接管');
    expect(mainSrc.contains('SettingsPage()'), isFalse, reason: '旧页引用清零');
    // 六张内容独立页路由在位。
    for (final path in [
      '/settings/theme',
      '/settings/cover',
      '/settings/links',
      '/settings/export',
      '/settings/invite',
      '/settings/chat-wallpaper',
      '/settings/chat-bubble',
    ]) {
      expect(mainSrc.contains("path: '$path'"), isTrue,
          reason: '$path 独立页路由在位');
    }
  });
}
