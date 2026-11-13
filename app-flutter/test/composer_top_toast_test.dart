/// 顶部通知对比自查 golden（段二 A 返修 1）：
/// composer 顶部「草稿已保存」与聊天页撤回提示走同一套 ChatToastHost /
/// chatToastProvider（同一组件、同位置——宿主顶部、同样式 _ToastPill）。
/// 生成：flutter test --update-goldens test/composer_top_toast_test.dart
/// 产物：test/goldens/composer_top_toast.png + chat_recall_toast.png（对比图）
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:love_space/core/api/api_client.dart' show dioProvider;
import 'package:love_space/features/chat/chat_toast.dart';
import 'package:love_space/features/chat/chat_toast.dart';
import 'package:love_space/features/timeline/composer_sheet.dart';

Future<void> _pumpComposer(WidgetTester tester) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      // composer initState 会拉相册列表：给一个空配置 Dio（请求失败被
      // catch 吞掉，不影响 UI 渲染）
      dioProvider.overrideWith((ref) async => Dio()),
    ],
    // 段 B 起宿主由 App 根部全局承载（App 内只挂一处），测试按真实架构
    // 在 MaterialApp.builder 里挂同一个 ChatToastHost，覆盖所有页面/弹层。
    child: MaterialApp(
      builder: (context, child) => Stack(children: [
        child ?? const SizedBox.shrink(),
        const Positioned(
            top: 0, left: 0, right: 0,
            child: IgnorePointer(child: SafeArea(child: ChatToastHost()))),
      ]),
      home: const Scaffold(
        body: SafeArea(child: ComposerSheet()),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('composer 顶部通知「草稿已保存」（返修 1 主场景）',
      (tester) async {
    await _pumpComposer(tester);
    final ctx = tester.element(find.byType(ComposerSheet));
    ProviderScope.containerOf(ctx)
        .read(chatToastProvider.notifier)
        .show('草稿已保存', tone: ChatToastTone.success);
    await tester.pumpAndSettle();
    // 通知出现在页面顶部（全局宿主）、不被底部栏遮挡
    expect(find.text('草稿已保存'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    // 取整页截图（含顶部宿主），与聊天撤回提示 golden 做同组件对比
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/composer_top_toast.png'));
  });

  testWidgets('聊天撤回提示（对照组：同一 ChatToastHost 组件）', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            // 与聊天页 messages_page 相同的挂法：body 顶部 Positioned
            Positioned(top: 0, left: 0, right: 0, child: ChatToastHost()),
          ]),
        ),
      ),
    ));
    final ctx = tester.element(find.byType(ChatToastHost));
    ProviderScope.containerOf(ctx)
        .read(chatToastProvider.notifier)
        .show('你撤回了一条消息', tone: ChatToastTone.info);
    await tester.pumpAndSettle();
    await expectLater(find.byType(ChatToastHost),
        matchesGoldenFile('goldens/chat_recall_toast.png'));
  });
}
