/* 复验修复单测：
   ① 长按录音手势意图（松开发送 / 左上取消 / 右上转文字）；
   ② 顶部提示层取代底部 SnackBar：自动收起；录音态改全屏遮罩、不占底部；
   ③ 聊天背景层在 body 被键盘压缩后仍保持完整视口高度与顶部位置。 */
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/features/chat/chat_toast.dart';
import 'package:love_space/features/chat/chat_wallpaper_frame.dart';

void main() {
  group('① 长按录音手势意图（纯函数：胶囊行横带 x 判定）', () {
    const w = 393.0; // 实测规格屏宽
    final cancelEdge = w * 0.44;   // 172.9
    final textEdge = w * 0.56;     // 220.1

    test('中间带 → 发送（默认态中心与 ±边缘内）', () {
      expect(recordIntentFor(x: w / 2, screenWidth: w), RecordIntent.send);
      expect(recordIntentFor(x: cancelEdge + 1, screenWidth: w),
          RecordIntent.send);
      expect(recordIntentFor(x: textEdge - 1, screenWidth: w),
          RecordIntent.send);
    });

    test('x < 44% → 取消；x > 56% → 转文字', () {
      expect(recordIntentFor(x: cancelEdge - 1, screenWidth: w),
          RecordIntent.cancel);
      expect(recordIntentFor(x: 20, screenWidth: w), RecordIntent.cancel);
      expect(recordIntentFor(x: textEdge + 1, screenWidth: w),
          RecordIntent.toText);
      expect(recordIntentFor(x: w - 20, screenWidth: w), RecordIntent.toText);
    });

    test('迟滞防抖 18dp：边界来回滑动不闪烁', () {
      // 已在取消区：x 回到 cancelEdge+10（< cancelEdge+18）→ 保持取消
      expect(
          recordIntentFor(
              x: cancelEdge + 10,
              screenWidth: w,
              currentIntent: RecordIntent.cancel),
          RecordIntent.cancel);
      // x >= cancelEdge+18 → 退回发送
      expect(
          recordIntentFor(
              x: cancelEdge + 19,
              screenWidth: w,
              currentIntent: RecordIntent.cancel),
          RecordIntent.send);
      // 已在转文字区：x = textEdge-10（> textEdge-18）→ 保持转文字
      expect(
          recordIntentFor(
              x: textEdge - 10,
              screenWidth: w,
              currentIntent: RecordIntent.toText),
          RecordIntent.toText);
      // x <= textEdge-18 → 退回发送
      expect(
          recordIntentFor(
              x: textEdge - 19,
              screenWidth: w,
              currentIntent: RecordIntent.toText),
          RecordIntent.send);
      // 取消区直接滑过中缝到转文字区 → 转文字
      expect(
          recordIntentFor(
              x: textEdge + 2,
              screenWidth: w,
              currentIntent: RecordIntent.cancel),
          RecordIntent.toText);
    });
  });

  Widget toastTree() => MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            const Positioned(
                top: 0, left: 0, right: 0, child: ChatToastHost()),
            const VoiceRecordOverlay(),
            Consumer(builder: (_, ref, _) => Column(children: [
                  TextButton(
                    onPressed: () => ref
                        .read(chatToastProvider.notifier)
                        .show('已撤回', tone: ChatToastTone.success),
                    child: const Text('toast')),
                  TextButton(
                    onPressed: () {
                      final n = ref.read(chatRecordProvider.notifier);
                      n.start();
                      n.intent(RecordIntent.cancel);
                    },
                    child: const Text('record')),
                ])),
          ]),
        ),
      );

  group('② 顶部提示层', () {
    testWidgets('提示出现在顶部、2.2s 后自动收起', (tester) async {
      await tester.pumpWidget(ProviderScope(child: toastTree()));
      await tester.tap(find.text('toast'));
      await tester.pump();
      expect(find.text('已撤回'), findsOneWidget);
      final rect = tester.getRect(find.text('已撤回'));
      expect(rect.top, lessThan(200), reason: '提示挂在页面顶部，不在底部');
      await tester.pump(const Duration(milliseconds: 2300));
      // AnimatedSwitcher 退场 220ms，旧 child 还在树里，再推进一帧
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('已撤回'), findsNothing);
    });

    testWidgets('录音态全屏遮罩显示三区且不被普通提示挤掉', (tester) async {
      await tester.pumpWidget(ProviderScope(child: toastTree()));
      await tester.tap(find.text('toast'));
      await tester.pump();
      // 普通提示出现在顶部
      expect(find.text('已撤回'), findsOneWidget);
      await tester.tap(find.text('record'));
      await tester.pump();
      // 录音态：全屏遮罩显示扇面三区（record 按钮设 intent=cancel →
      // 左胶囊白底高亮放大、中央大弧弱化为「语音」、气泡变红缩小）
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('滑到这里 转文字'), findsOneWidget);
      expect(find.text('语音'), findsOneWidget);
      // 普通提示仍与遮罩并存（遮罩与顶部提示层是两条独立通道）
      expect(find.text('已撤回'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    test('ChatToastController：同一时刻只留最新、hide 立刻清空', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(chatToastProvider), isNull);
      final n = c.read(chatToastProvider.notifier);
      n.show('第一条');
      expect(c.read(chatToastProvider)?.text, '第一条');
      n.show('第二条');
      expect(c.read(chatToastProvider)?.text, '第二条');
      n.hide();
      expect(c.read(chatToastProvider), isNull);
    });

    test('ChatRecordController：意图只在变化时更新，stop 清空', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(chatRecordProvider.notifier);
      n.start();
      final t0 = c.read(chatRecordProvider)!.startedAt;
      expect(c.read(chatRecordProvider)!.intent, RecordIntent.send);
      n.intent(RecordIntent.toText);
      expect(c.read(chatRecordProvider)!.intent, RecordIntent.toText);
      expect(c.read(chatRecordProvider)!.startedAt, t0,
          reason: '滑动改意图不应重置录音起点');
      n.stop();
      expect(c.read(chatRecordProvider), isNull);
    });
  });

  group('③ 背景层固定全屏高（键盘压缩 body 不上移）', () {
    testWidgets('body 高度变化后背景仍贴顶、高度恒为完整视口高',
        (tester) async {
      const viewport = 800.0;
      Widget tree(double bodyHeight) => MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: bodyHeight,
                child: Stack(children: [
                  ChatWallpaperFrame(
                    viewportHeight: viewport,
                    child: Container(key: const Key('bg')),
                  ),
                ]),
              ),
            ),
          );

      await tester.pumpWidget(tree(800));
      expect(tester.getSize(find.byKey(const Key('bg'))).height, viewport);
      await tester.pumpWidget(tree(500)); // 键盘弹出压掉 300
      final bg = tester.getRect(find.byKey(const Key('bg')));
      expect(bg.height, viewport, reason: '背景不随 body 压缩重新裁剪');
      expect(bg.top, 0, reason: '背景始终贴顶，不往上偏移');
    });
  });
}
