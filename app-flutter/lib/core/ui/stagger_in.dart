/// 2.4.10 附录 B ①：列表/网格错峰入场（通用组件）。
/// 同批元素按序递增 delay（步进 40ms、封顶 600ms），只动
/// transform/opacity（透明度 + 轻微上移 12px）。规格：只做主要列表
/// 首屏，滚动加载的后续批次不做（2.4.10 附录 B 定案）；随机延迟禁用。
/// [enable]=false 时直接渲染 child（动效总开关门控）。
library;

import 'package:flutter/material.dart';

/// 错峰步进（附录 B 钦定 40–60ms，取 40）。
const Duration kStaggerStep = Duration(milliseconds: 40);

/// 错峰封顶。
const Duration kStaggerCap = Duration(milliseconds: 600);

class StaggerIn extends StatefulWidget {
  const StaggerIn({
    super.key,
    required this.index,
    required this.enable,
    required this.child,
  });

  final int index;
  final bool enable;
  final Widget child;

  @override
  State<StaggerIn> createState() => _StaggerInState();
}

class _StaggerInState extends State<StaggerIn>
    with SingleTickerProviderStateMixin {
  // 延迟用 Interval 曲线实现（控制器一次 forward 到底）——不用
  // Future.delayed（真定时器在测试树销毁时挂 pending，首测实证）。
  static const _anim = Duration(milliseconds: 260);
  late final AnimationController _c = AnimationController(
      vsync: this, duration: kStaggerCap + _anim);

  double get _delayFraction {
    final ms = (widget.index * kStaggerStep.inMilliseconds)
        .clamp(0, kStaggerCap.inMilliseconds);
    return (widget.enable ? ms : kStaggerCap.inMilliseconds) /
        (kStaggerCap.inMilliseconds + _anim.inMilliseconds);
  }

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enable) return widget.child;
    final start = _delayFraction;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.drive(CurveTween(curve: Interval(start, 1,
                curve: Curves.easeOut))).value;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 12 * (1 - t)),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}
