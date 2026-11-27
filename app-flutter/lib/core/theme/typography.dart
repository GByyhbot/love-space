/// 五档苹果口径字阶令牌（甲〇配色口径 B：只读全 App `ThemeData` / `ColorScheme`）。
///
/// 大标题紧字距、数字等宽、辅助文字通过降透明度或 `colorScheme.outline` 实现，
/// 绝不改色相、不硬编码颜色。
library;

import 'package:flutter/material.dart';

abstract final class AppType {
  static const List<FontFeature> tabularFeatures = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  /// 1. 大标题（页面主标题，紧字距 -0.4，w700）。
  static TextStyle largeTitle(ThemeData theme, {Color? color}) =>
      (theme.textTheme.headlineSmall ?? const TextStyle(fontSize: 24))
          .copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
        height: 1.2,
        color: color ?? theme.colorScheme.onSurface,
      );

  /// 2. 标题（卡片/分区标题，w700，微紧字距 -0.2）。
  static TextStyle title(ThemeData theme, {Color? color}) =>
      (theme.textTheme.titleSmall ?? const TextStyle(fontSize: 15)).copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        color: color ?? theme.colorScheme.onSurface,
      );

  /// 3. 正文（w400/w500，清晰行高）。
  static TextStyle body(ThemeData theme, {Color? color}) =>
      (theme.textTheme.bodyMedium ?? const TextStyle(fontSize: 14)).copyWith(
        color: color ?? theme.colorScheme.onSurface,
      );

  /// 4. 辅助文字（降透明度而非改色相，默认优先使用 `outline` / 72% `onSurfaceVariant`）。
  static TextStyle caption(ThemeData theme, {Color? color}) =>
      (theme.textTheme.bodySmall ?? const TextStyle(fontSize: 12)).copyWith(
        color: color ?? theme.colorScheme.outline,
      );

  /// 5. 等宽数字（计数/时间/百分比防横向抖动）。
  static TextStyle numeric(ThemeData theme,
          {TextStyle? base, Color? color}) =>
      (base ?? theme.textTheme.titleMedium ?? const TextStyle(fontSize: 16))
          .copyWith(
        fontFeatures: tabularFeatures,
        color: color,
      );
}
