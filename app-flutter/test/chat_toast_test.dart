/* 复验修复单测：
   ① 长按录音手势意图（松开发送 / 左上取消 / 右上转文字）；
   ② 顶部提示层取代底部 SnackBar：自动收起、录音态常驻、不占底部；
   ③ 聊天背景层在 body 被键盘压缩后仍保持完整视口高度与顶部位置。 */
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/features/chat/chat_toast.dart';
import 'package:love_space/features/chat/chat_wallpaper_frame.dart';

void main() {
  group('① 长按录音手势意图（纯函数）', () {
    const origin = Offset(500, 1200);

    test('直接松开 / 只往上滑一点 / 正上方 → 发送', () {
      expect(recordIntentFor(finger: origin, origin: origin),
          RecordIntent.send);
      expect(
          recordIntentFor(
              finger: const Offset(500, 1160), origin: origin),
          RecordIntent.send);
      expect(
          recordIntentFor(
              finger: const Offset(500, 1000), origin: origin),
          RecordIntent.send);
    });

    test('滑到左上 → 取消；滑到右上 → 转文字', () {
      expect(
          recordIntentFor(
              finger: const Offset(300, 1000), origin: origin),
          RecordIntent.cancel);
      expect(
          recordIntentFor(
              finger: const Offset(620, 1000), origin: origin),
          RecordIntent.toText);
    });

    test('没有明显上滑时不误判左右象限', () {
      expect(
          recordIntentFor(
              finger: const Offset(100, 1180), origin: origin),
          RecordIntent.send);
      expect(
          recordIntentFor(
              finger: const Offset(620, 1180), origin: origin),
          RecordIntent.send);
    });

    test('阈值可配置；边界值落在对应象限', () {
      expect(
          recordIntentFor(
              finger: const Offset(450, 1136),
              origin: origin,
              threshold: 64),
          RecordIntent.send);
      expect(
          recordIntentFor(
              finger: const Offset(436, 1136),
              origin: origin,
              threshold: 64),
          RecordIntent.cancel);
    });
  });

  Widget toastTree() => MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            const Positioned(
                top: 0, left: 0, right: 0, child: ChatToastHost()),
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

    testWidgets('录音态显示意图高亮且不被普通提示挤掉', (tester) async {
      await tester.pumpWidget(ProviderScope(child: toastTree()));
      await tester.tap(find.text('toast'));
      await tester.pump();
      await tester.tap(find.text('record'));
      await tester.pump();
      expect(find.text('正在录音'), findsOneWidget);
      expect(find.text('松开取消录音'), findsOneWidget);
      expect(find.text('左上取消'), findsOneWidget);
      expect(find.text('右上转文字'), findsOneWidget);
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
