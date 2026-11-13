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
import 'package:love_space/features/timeline/composer_sheet.dart';

Future<void> _pumpComposer(WidgetTester tester) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      // composer initState 会拉相册列表：给一个空配置 Dio（请求失败被
      // catch 吞掉，不影响 UI 渲染）
      dioProvider.overrideWith((ref) async => Dio()),
    ],
    child: const MaterialApp(
      home: Scaffold(
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
    // 通知出现在弹层顶部（ChatToastHost 在 Column 首位）、不被底部栏遮挡
    expect(find.text('草稿已保存'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await expectLater(find.byType(ComposerSheet),
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
