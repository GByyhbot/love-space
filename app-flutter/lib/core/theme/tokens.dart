/// 间距、圆角与触控令牌（全 App 统一 Design Foundation）。
///
/// 间距阶梯：4 / 8 / 12 / 16 / 20 / 24 / 32；
/// 圆角阶梯：12（小）/ 16（中）/ 20（大）/ 28（特大），嵌套严格遵守
/// 「外圆角 = 内圆角 + 内边距」（`concentric`）。
///
/// 兼容保留既定基准键：`cardPad`=16、`pageBottom`=88、`gap`=8、
/// `sm`=10、`card`=12、`lg`=16，确保全仓零回归。
library;

/// 间距令牌（阶梯：4 / 8 / 12 / 16 / 20 / 24 / 32 + 底栏避让 88）。
abstract final class Spacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;

  /// 页面水平通用边距（对齐 16 阶梯）。
  static const double pagePad = lg;

  /// 卡内统一 padding（16）。
  static const double cardPad = lg;

  /// 内容页滚动底部留白统一值（避让悬浮 Dock + 视觉呼吸）。
  static const double pageBottom = 88;

  /// 标准纵向间隙（8）。
  static const double gap = sm;
}

/// 圆角令牌（Liquid Glass 阶梯：12 / 16 / 20 / 28，兼容保留 sm=10 / card=12 / lg=16）。
abstract final class AppRadius {
  /// 小件（既有基线 10，chip / 徽章等小件用）。
  static const double sm = 10;

  /// 标准卡（既定 cardTheme 单源 12，同时对应 Liquid Glass 小圆角档）。
  static const double card = 12;

  /// Liquid Glass 阶梯：小 12 / 中 16 / 大 20 / 特大 28。
  static const double small = 12;
  static const double medium = 16;
  static const double large = 20;
  static const double xl = 28;

  /// 大容器（既有基线 16，与 medium 同档）。
  static const double lg = 16;

  /// 胶囊整圆。
  static const double pill = 999;

  /// 同心圆角计算：`max(4, outer - inset)`（外圆角 = 内圆角 + 间距）。
  static double concentric(double outer, double inset) {
    final v = outer - inset;
    return v > 4 ? v : 4;
  }
}

/// 触控最小目标尺寸（苹果 HIG / Material ≥44dp 口径）。
abstract final class AppTouch {
  static const double minTarget = 44;
}
