/* 复验修复单测：
   ① 长按录音手势意图（松开发送 / 左上取消 / 右上转文字）；
   ② 顶部提示层取代底部 SnackBar：自动收起；录音态改全屏遮罩、不占底部；
   ③ 聊天背景层在 body 被键盘压缩后仍保持完整视口高度与顶部位置。 */
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/features/chat/chat_toast.dart';
import 'package:love_space/features/chat/chat_wallpaper_frame.dart';

void main() {
  group('① 长按录音手势意图（2.7.0：判定带 30%/70% + 进入迟滞 12dp）', () {
    const w = 393.0; // 实测规格屏宽
    final cancelEdge = w * 0.30;   // 117.9（2.7.0：0.44 → 0.30，有意变更）
    final textEdge = w * 0.70;     // 275.1（2.7.0：0.56 → 0.70，有意变更）

    test('中间带（屏宽 40%）→ 发送', () {
      expect(recordIntentFor(x: w / 2, screenWidth: w), RecordIntent.send);
      // 发送区内紧贴边界（越界 1px 未过进入迟滞）→ 保持发送
      expect(recordIntentFor(x: cancelEdge - 1, screenWidth: w),
          RecordIntent.send, reason: '越界 1px 不翻转（进入迟滞）');
      expect(recordIntentFor(x: textEdge + 1, screenWidth: w),
          RecordIntent.send, reason: '越界 1px 不翻转（进入迟滞）');
    });

    test('x < 30%−12 → 取消；x > 70%+12 → 转文字（深区）', () {
      expect(recordIntentFor(x: 20, screenWidth: w), RecordIntent.cancel);
      expect(recordIntentFor(x: w - 20, screenWidth: w), RecordIntent.toText);
    });

    test('2.7.0 新增：进入迟滞 12dp——越界 11dp 不翻转、13dp 翻转', () {
      // send 态进入取消需 x < cancelEdge−12
      expect(recordIntentFor(x: cancelEdge - 11, screenWidth: w),
          RecordIntent.send, reason: '越界 11dp 不翻转');
      expect(recordIntentFor(x: cancelEdge - 13, screenWidth: w),
          RecordIntent.cancel, reason: '越界 13dp 翻转');
      // send 态进入转文字需 x > textEdge+12
      expect(recordIntentFor(x: textEdge + 11, screenWidth: w),
          RecordIntent.send, reason: '越界 11dp 不翻转');
      expect(recordIntentFor(x: textEdge + 13, screenWidth: w),
          RecordIntent.toText, reason: '越界 13dp 翻转');
    });

    test('退出回发送区的 18dp 迟滞保留（既有语义适配新边界）', () {
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
    });

    test('取消 ↔ 转文字直接跳转需越过目标区边界 ± 12dp', () {
      // 取消区：x 越过 textEdge+2（未过 +12）→ 保持取消
      expect(
          recordIntentFor(
              x: textEdge + 2,
              screenWidth: w,
              currentIntent: RecordIntent.cancel),
          RecordIntent.cancel, reason: '越过 2dp 不翻转（进入迟滞）');
      // 越过 textEdge+13 → 转文字
      expect(
          recordIntentFor(
              x: textEdge + 13,
              screenWidth: w,
              currentIntent: RecordIntent.cancel),
          RecordIntent.toText);
      // 转文字区：x 低于 cancelEdge-11（未过 −12 进取消门槛）→ 保持转文字
      // （未过门槛不翻转；回发送带只覆盖靠近发送区一侧，对称口径）
      expect(
          recordIntentFor(
              x: cancelEdge - 11,
              screenWidth: w,
              currentIntent: RecordIntent.toText),
          RecordIntent.toText, reason: '越过 11dp 不翻转');
      // 低于 cancelEdge-13 → 取消（进取消门槛优先于发送带判定）
      expect(
          recordIntentFor(
              x: cancelEdge - 13,
              screenWidth: w,
              currentIntent: RecordIntent.toText),
          RecordIntent.cancel);
    });

    test('2.7.0 动画口径：胶囊选中态 Motion.base（220ms）、气泡 easeOutCubic', () {
      final src = File('lib/features/chat/chat_toast.dart').readAsStringSync();
      // 气泡 AnimatedContainer：easeOutBack → easeOutCubic（时长 220 保持）
      expect(src.contains('curve: Curves.easeOutCubic'), isTrue,
          reason: '气泡 AnimatedContainer 曲线');
      // 胶囊选中态：Motion.fast → Motion.base（220ms）
      // 胶囊选中态（Motion.fast → Motion.base）：按位置断言（对齐缩进无关）
      expect(src.contains('duration: Motion.base,'), isTrue,
          reason: '胶囊选中态 220ms（Motion.base 220ms）');
      final capsuleI = src.indexOf('curve: Curves.easeOut,');
      final fastI = src.indexOf('duration: Motion.fast,\n      curve: Curves.easeOut,');
      expect(fastI, -1, reason: '胶囊选中态不再用 Motion.fast+easeOut 组合');
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
