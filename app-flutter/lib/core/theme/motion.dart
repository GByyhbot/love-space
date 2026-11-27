/// 动效时长与曲线令牌（全 App 统一弹簧曲线与 120 / 240 / 380 时长阶梯）。
///
/// 兼容保留既定 [fast]=120ms、[base]=220ms、[slow]=320ms 三档，新增
/// [medium]=240ms、[gentle]=380ms 与统一弹性/强调曲线，克制且无装饰性动画。
library;

import 'package:flutter/material.dart';

abstract final class Motion {
  /// 微反馈档（120ms）：按压回弹、小件淡入淡出。
  static const Duration fast = Duration(milliseconds: 120);

  /// 兼容既定标准过渡档（220ms）。
  static const Duration base = Duration(milliseconds: 220);

  /// Liquid Glass 标准过渡档（240ms）：卡片展开、切换滑块。
  static const Duration medium = Duration(milliseconds: 240);

  /// 兼容既定慢速过渡档（320ms）。
  static const Duration slow = Duration(milliseconds: 320);

  /// 柔和大型转场档（380ms）：抽屉弹层、页面级大元素过渡。
  static const Duration gentle = Duration(milliseconds: 380);

  /// 统一弹簧近似曲线（自然减速，无浮夸回弹）。
  static const Curve springCurve = Curves.easeOutCubic;

  /// 强调转场曲线（卡片展开、状态切页）。
  static const Curve emphasizedCurve = Curves.easeInOutCubicEmphasized;
}
