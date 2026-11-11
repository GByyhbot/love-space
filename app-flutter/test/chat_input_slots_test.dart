/* 输入区同槽位互斥状态机单测（段二 · Step 6 核心逻辑）：
   键盘 / ⊕面板 / 贴纸坞三选一互斥；面板意图（键盘压掉→收起回位）；
   亲手收起面板/选走功能才清意图。 */
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/features/chat/input_slots.dart';

void main() {
  test('初始无槽位；打开面板未开过键盘时无意图', () {
    final m = InputSlotMachine();
    expect(m.slot, InputSlot.none);
    m.handle(InputSlotEvent.toggleFn);
    expect(m.slot, InputSlot.fn);
    expect(m.intent, isNull);
  });

  test('面板开合切换：再点一次收起并清意图', () {
    final m = InputSlotMachine()..handle(InputSlotEvent.toggleFn);
    m.handle(InputSlotEvent.toggleFn);
    expect(m.slot, InputSlot.none);
    expect(m.intent, isNull);
    m.handle(InputSlotEvent.toggleSticker);
    m.handle(InputSlotEvent.toggleSticker);
    expect(m.slot, InputSlot.none);
    expect(m.intent, isNull);
  });

  test('面板意图：点输入框键盘压掉面板 → 键盘收起后自动回位', () {
    final m = InputSlotMachine()..handle(InputSlotEvent.toggleSticker);
    m.handle(InputSlotEvent.keyboardFocus); // 键盘临时压掉贴纸坞
    expect(m.slot, InputSlot.none);
    expect(m.intent, InputSlot.sticker);
    m.handle(InputSlotEvent.keyboardClosed); // 键盘收起 → 面板回位
    expect(m.slot, InputSlot.sticker);
    expect(m.intent, isNull);
  });

  test('选走功能：面板收起 + 意图清空（键盘收起不再回位）', () {
    final m = InputSlotMachine()..handle(InputSlotEvent.toggleFn);
    m.handle(InputSlotEvent.keyboardFocus);
    expect(m.intent, InputSlot.fn);
    m.handle(InputSlotEvent.pickFunction); // 相册/拍摄/语音选走
    expect(m.slot, InputSlot.none);
    expect(m.intent, isNull);
    m.handle(InputSlotEvent.keyboardClosed);
    expect(m.slot, InputSlot.none); // 不回位
  });

  test('亲手收起面板：意图一并清空', () {
    final m = InputSlotMachine()..handle(InputSlotEvent.toggleFn);
    m.handle(InputSlotEvent.keyboardFocus);
    expect(m.intent, InputSlot.fn);
    // 键盘收起回位后，用户再点 ⊕ 收起面板
    m.handle(InputSlotEvent.keyboardClosed);
    m.handle(InputSlotEvent.toggleFn);
    expect(m.slot, InputSlot.none);
    expect(m.intent, isNull);
  });

  test('无面板时点输入框 / 无意图时键盘收起：状态不变', () {
    final m = InputSlotMachine();
    m.handle(InputSlotEvent.keyboardFocus);
    expect(m.slot, InputSlot.none);
    expect(m.intent, isNull);
    m.handle(InputSlotEvent.keyboardClosed);
    expect(m.slot, InputSlot.none);
  });

  test('fn ↔ sticker 同槽位互换（⊕面板里点「表情」直接切坞）', () {
    final m = InputSlotMachine()..handle(InputSlotEvent.toggleFn);
    m.handle(InputSlotEvent.toggleSticker);
    expect(m.slot, InputSlot.sticker);
    m.handle(InputSlotEvent.toggleFn);
    expect(m.slot, InputSlot.fn);
  });

  test('意图始终只记一个面板：连续意图不叠加', () {
    final m = InputSlotMachine()..handle(InputSlotEvent.toggleSticker);
    m.handle(InputSlotEvent.keyboardFocus);
    m.handle(InputSlotEvent.keyboardClosed); // 回到贴纸坞
    m.handle(InputSlotEvent.keyboardFocus); // 再压掉
    expect(m.intent, InputSlot.sticker);
    m.handle(InputSlotEvent.keyboardClosed);
    expect(m.slot, InputSlot.sticker);
  });
}
