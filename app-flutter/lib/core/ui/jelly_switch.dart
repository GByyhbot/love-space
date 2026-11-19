/// 2.4.10 第 03 项「果冻开关」（Jelly Toggle）统一组件：
/// 点击后圆点滑向另一端，途中横向拉长成胶囊形，到达终点回弹恢复
/// 圆形；底色由灰渐变到激活色。时长约 350ms，弹簧回弹曲线。
///
/// 激活色走主题 primary 令牌（演示稿绿色仅示意）；取值/保存逻辑
/// 零改动（受控组件，与现行 Switch 同签名）。
/// 动效门控：[motionEnabled]=false（外观页动效总开关关闭）时退化为
/// 直接切换（无动画），对齐 main.dart splash 退化纪律。
/// 动画只动 transform/opacity/对齐（Align 位移 + scale）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/settings_state.dart' show spaceAppearanceProvider;

/// 果冻开关总时长（提示词钦定约 350ms）。
const Duration kJellyDuration = Duration(milliseconds: 350);

/// 果冻开关：与 Flutter Switch 视觉等价（track 高 32 / 圆点 24，
/// Material 3 口径），动效按提示词形态实现。
class JellySwitch extends ConsumerStatefulWidget {
  const JellySwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  ConsumerState<JellySwitch> createState() => _JellySwitchState();
}

class _JellySwitchState extends ConsumerState<JellySwitch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: kJellyDuration);

  void _tap() {
    final onChanged = widget.onChanged;
    if (onChanged == null) return;
    final motion = ref.read(spaceAppearanceProvider).motion;
    if (!motion) {
      onChanged(!widget.value); // 动效关闭：直接切换（splash 纪律同源）
      return;
    }
    _c.forward(from: 0);
    onChanged(!widget.value);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final on = widget.value;
    final enabled = widget.onChanged != null;
    final motion = ref.watch(spaceAppearanceProvider).motion;
    final track = enabled
        ? (on ? cs.primary : cs.surfaceContainerHighest)
        : cs.surfaceContainerHighest.withValues(alpha: 0.4);
    final knobColor = enabled
        ? (on ? cs.onPrimary : cs.outline)
        : cs.outline.withValues(alpha: 0.4);
    return Semantics(
      toggled: on,
      child: GestureDetector(
        onTap: _tap,
        child: AnimatedContainer(
          duration: motion ? kJellyDuration : Duration.zero,
          curve: Curves.easeOut,
          width: 52,
          height: 32,
          decoration: BoxDecoration(
            color: track,
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.all(4),
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              // 果冻行程：位置 easeOutBack（端点过冲回弹），
              // 圆点中段横向拉长（scaleX 峰值 1.45）。
              final t = motion ? _c.value : 1.0;
              final stretch = math.sin(math.pi * (t * 2).clamp(0.0, 1.0));
              final sx = 1.0 + 0.45 * stretch;
              return Align(
                // 圆点从旧端滑向新端：on=true 时旧端 -1 → 新端 +1。
                alignment: Alignment(
                    on ? -1 + 2 * _travel(t) : 1 - 2 * _travel(t), 0),
                child: Transform.scale(
                  scaleX: sx,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                        color: knobColor, shape: BoxShape.circle),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  // 行程 0→1：easeOutBack 位移（终点过冲由 Align 钳制到 [1,-1] 边界，
  // 过冲表现为圆点轻触边缘回弹）。
  double _travel(double t) {
    const c1 = 0.7;
    const c3 = c1 + 1;
    final x = t - 1;
    final v = 1 + c3 * x * x * x + c1 * x * x;
    return v.clamp(0.0, 1.0);
  }
}
