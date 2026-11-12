// 语音遮罩三态 golden 截图（对照微信三张全屏截图逐项比对）：
// 渲染 393×873（@1x），加载真实中文字体（微软雅黑注册为默认 Roboto 族），
// 分别注入 send / cancel / toText 三态，与 test/goldens/ 下三张 PNG 对齐。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/features/chat/chat_toast.dart';

Future<void> _loadChineseFont() async {
  final bytes =
      File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync();
  final byteData = ByteData.view(Uint8List.fromList(bytes).buffer);
  final loader = FontLoader('Roboto')..addFont(Future.value(byteData));
  await loader.load();
}

Widget _tree(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Stack(children: [const VoiceRecordOverlay()]),
        ),
      ),
    );

void _pumpState(ProviderContainer container, RecordIntent intent) {
  container.read(chatRecordProvider.notifier).start();
  if (intent != RecordIntent.send) {
    container.read(chatRecordProvider.notifier).intent(intent);
  }
}

void main() {
  testWidgets('语音遮罩三态 golden（send/cancel/toText）', (tester) async {
    await _loadChineseFont();
    tester.view.physicalSize = const Size(393, 873);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(_tree(container));
    await tester.pump();

    // ── 态 1：发送（默认绿 + 波形 + 扇面；圆环在发送弧中央）──
    _pumpState(container, RecordIntent.send);
    container.read(recordFingerProvider.notifier).state =
        const Offset(196.5, 873 - 25);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byType(VoiceRecordOverlay),
        matchesGoldenFile('goldens/voice_send.png'));

    // ── 态 2：取消（红 82dp 左移 19% + 左胶囊白 + 浮标；圆环在左胶囊内）──
    container.read(chatRecordProvider.notifier).intent(RecordIntent.cancel);
    container.read(recordFingerProvider.notifier).state =
        const Offset(75, 873 - 127);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byType(VoiceRecordOverlay),
        matchesGoldenFile('goldens/voice_cancel.png'));

    // ── 态 3：转文字（89% 文字卡 + 右胶囊白 + 浮标；圆环在右胶囊内）──
    container.read(chatRecordProvider.notifier).intent(RecordIntent.toText);
    container.read(recordFingerProvider.notifier).state =
        const Offset(322, 873 - 127);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byType(VoiceRecordOverlay),
        matchesGoldenFile('goldens/voice_totext.png'));
  });
}
