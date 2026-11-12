/// 输入区同槽位互斥状态机（Step 6 核心，纯 Dart 可单测，无 Flutter 依赖）。
/// 规范（chat-plan Step 6 + Web fnIntent 语义）：
/// · 键盘 / ⊕面板 / 贴纸坞三选一，同槽位互斥；
/// · 「面板意图」（等价 Web fnIntent）：点输入框时键盘临时压掉面板，键盘收起后
///   面板自动回位；用户亲手收起面板（再点一次开关）或选走功能才清意图；
/// · 打开面板时收起键盘（unfocus）。
library;

/// 底部槽位：无 / ⊕功能面板 / 贴纸坞
enum InputSlot { none, fn, sticker }

enum InputSlotEvent {
  /// 点 ⊕（开合切换）
  toggleFn,

  /// 点表情（开合切换）
  toggleSticker,

  /// 输入框获得焦点（键盘将弹出）
  keyboardFocus,

  /// 键盘收起（viewInsets.bottom 归零）
  keyboardClosed,

  /// 从面板选走一个功能（相册/拍摄/语音/贴纸发送等）→ 面板收起且意图清空
  pickFunction,
}

class InputSlotMachine {
  InputSlot _slot = InputSlot.none;
  InputSlot? _intent;

  InputSlot get slot => _slot;

  /// 面板意图（键盘压掉面板期间记住，键盘收起后自动回位）
  InputSlot? get intent => _intent;

  /// 槽位是否占位（布局口径，与 [slot] 的「谁在显示」口径不同）。
  ///
  /// 面板被键盘临时压住时 [slot] 已变 none、但 [intent] 记住了面板：
  /// 此刻槽位**仍须按等高公式占位**，否则 slotHeight 会瞬间归零 →
  /// 输入栏下沉一帧，键盘再把它顶回来，收起时又做一次面板展开
  /// ——真机「每次切换都执行一次展开动作」的根因。
  bool get slotOccupied => _slot != InputSlot.none || _intent != null;

  /// 互切过渡期要渲染的面板：slot 被键盘压成 none 时沿用 intent，
  /// 保证槽位内容不闪空白、不重建。
  InputSlot get visibleSlot =>
      _slot != InputSlot.none ? _slot : (_intent ?? InputSlot.none);

  /// 处理事件（纯状态迁移，可穷举单测）
  void handle(InputSlotEvent event) {
    switch (event) {
      case InputSlotEvent.toggleFn:
        if (_slot == InputSlot.fn) {
          // 亲手收起面板 → 意图一并清空
          _slot = InputSlot.none;
          _intent = null;
        } else {
          _slot = InputSlot.fn;
          _intent = null;
        }
      case InputSlotEvent.toggleSticker:
        if (_slot == InputSlot.sticker) {
          _slot = InputSlot.none;
          _intent = null;
        } else {
          _slot = InputSlot.sticker;
          _intent = null;
        }
      case InputSlotEvent.keyboardFocus:
        // 键盘临时压掉面板：记住意图，等键盘收起自动回位
        if (_slot != InputSlot.none) {
          _intent = _slot;
          _slot = InputSlot.none;
        }
      case InputSlotEvent.keyboardClosed:
        // 键盘收起后面板自动回位（意图未被亲手清掉时）
        if (_intent != null) {
          _slot = _intent!;
          _intent = null;
        }
      case InputSlotEvent.pickFunction:
        // 选走功能：面板收起 + 意图清空（Web fnCloseNow 同语义）
        _slot = InputSlot.none;
        _intent = null;
    }
  }
}
