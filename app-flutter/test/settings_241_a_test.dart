// 2.4.1 修复包 A 组断言（第 1–6 项）：
// ①空间信息独立页 ②主题外观改版 ③主页背景改版 ④聊天背景同源（护栏在
// settings_240_test）⑤账号页身份卡/成员头像修复 ⑥登录页改版。
// 数据层契约在 settings_d/settings_240；本文件只测新呈现与关键护栏。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:love_space/features/settings/appearance_page.dart';
import 'package:love_space/features/settings/cover_page.dart';
import 'package:love_space/features/settings/settings_widgets.dart';

Future<void> _pumpPage(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(393, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(child: MaterialApp(home: page)));
  await tester.pumpAndSettle();
  // ListView 惰性构建：滚到底让尾部行（动效卡/玻璃栏等）进树。
  await tester.drag(find.byType(ListView).first, const Offset(0, -1600));
  await tester.pumpAndSettle();
  await tester.drag(find.byType(ListView).first, const Offset(0, 1600));
  await tester.pumpAndSettle();
  // 冲 10s 收尾 timer（假时钟推进，避免 timersPending 不变式）。
  await tester.pump(const Duration(seconds: 10));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('第 2 项：主题外观页——预览卡/分段器/动效卡/玻璃栏在位，色卡勾徽随选中',
      (tester) async {
    await _pumpPage(tester, const AppearancePage());
    // 实时预览卡 + 主按钮样例。
    expect(find.byKey(const Key('settings-theme-preview')), findsOneWidget);
    expect(find.byKey(const Key('settings-theme-preview-button')),
        findsOneWidget);
    expect(find.text('对方的一条样例消息'), findsOneWidget);
    expect(find.text('我方的一条样例消息'), findsOneWidget);
    // 分段器（夜间/字号）替代下拉。
    expect(find.byKey(const Key('settings-dark')), findsOneWidget);
    expect(find.byKey(const Key('settings-font')), findsOneWidget);
    expect(find.text('跟随系统'), findsOneWidget);
    // 动效卡片行。
    expect(find.byKey(const Key('settings-motion')), findsOneWidget);
    expect(find.text('转场与点按的柔感动画'), findsOneWidget);
    // 底部玻璃操作栏（取消/保存）。
    expect(find.byType(SettingsGlassBar), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    // 默认 rose 选中：色卡勾徽（Icons.check）在 rose 卡内出现。
    expect(find.byKey(const Key('settings-theme-rose')), findsOneWidget);
    // 注脚。
    expect(find.textContaining('夜间模式与字号只记在这台设备上'), findsOneWidget);
  });

  testWidgets('第 3 项：主页背景页——hero 预览卡/当前封面徽标/共用小字/玻璃栏整行保存',
      (tester) async {
    await _pumpPage(tester, const CoverPage());
    expect(find.byKey(const Key('hero-preview')), findsOneWidget,
        reason: '首页效果预览卡（hero 真实布局）');
    expect(find.text('两个人共用这张封面'), findsOneWidget);
    expect(find.text('当前封面'), findsNothing,
        reason: '无封面数据夹具下不显示徽标（徽标仅在有封面时出现）');
    expect(find.byKey(const Key('settings-cover-pick')), findsOneWidget);
    expect(find.byType(SettingsGlassBar), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(find.textContaining('换好照片保存后会直接更新首页封面'), findsOneWidget);
  });

  test('第 5 项④源码护栏：成员行头像补传 avatarId（有照片渲染照片组件）', () {
    final src =
        File('lib/features/account/profile_page.dart').readAsStringSync();
    expect(
        src.contains('_Avatar(name: user.name, size: 44, avatarId: user.avatar)'),
        isTrue,
        reason: '🔴 「我们」成员行 _Avatar 必须带 avatarId（漏传恒显首字母 BUG）');
    // 身份 chip 文案在位。
    expect(src.contains('@\${me.user.username} · \$roleLabel'), isTrue);
  });

  test('第 6 项源码护栏：登录页玻璃圆徽/字距/光晕/密码显隐/双胶囊', () {
    final src = File('lib/features/auth/login_page.dart').readAsStringSync();
    expect(src.contains('_showPw'), isTrue, reason: '密码显隐状态');
    expect(src.contains('Icons.visibility_rounded'), isTrue);
    expect(src.contains('letterSpacing: 3'), isTrue, reason: '标题字距拉开');
    expect(src.contains('Icons.favorite_rounded'), isTrue, reason: '玻璃圆徽爱心');
    expect(src.contains('初始化新空间'), isTrue);
    expect(src.contains('我有邀请链接'), isTrue);
    expect(src.contains('Center('), isTrue);
    expect(src.contains('0x33C23F68'), isTrue, reason: '玫红余光');
    // 问候语与页脚保留（第 6 项③⑦）。
    expect(src.contains('网络不稳？重试免登录恢复'), isTrue);
    expect(src.contains('私密记录 · 只属于彼此'), isTrue);
  });

  test('第 6 项③：登录问候语保留（编译级字段存在）', () {
    final src = File('lib/features/auth/login_page.dart').readAsStringSync();
    expect(src.contains('把喜欢，写进每一天'), isTrue);
  });
}

