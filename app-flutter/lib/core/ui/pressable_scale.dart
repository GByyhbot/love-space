/// 2.4.10 附录 B ②：按压四段反馈——通用按压组件。
/// 按下即有微反馈（scale 0.97，快速档 120ms），手指未松持续保持
///（进行中/落点确认两段由宿主的 loading/结果反馈承担，与
/// SubmitMorph/HoldToConfirm 等既有组件拼成完整四段）。
/// 动画只动 transform；[motion]=false 时退化为直接 tap（总开关门控）。
library;

import 'package:flutter/material.dart';

class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    required this.onTap,
  });

  final Widget child;
  final VoidCallback? onTap;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.onTap == null ? null : (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: _down ? Curves.easeOut : Curves.easeOutBack,
        child: widget.child,
      ),
    );
  }
}
