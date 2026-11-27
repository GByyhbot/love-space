/// Apple iOS 26 / Liquid Glass 设计基元（主要页面真改版式令 · 框架层）。
///
/// 提供全 App 统一使用的四大视觉底座：
/// 1. [AppleIconBadge] / [AppleIconTone]：圆角方形色底 + 白色圆润矢量图标，
///    用于设置项、功能入口、卡片头标（替代所有装饰性 emoji）。
/// 2. [AppleGroupedSection] / [AppleGroupedRow]：Apple 分组列表容器，
///    组内统一大圆角底 + 细分割线（带左侧图标缩进）+ 双层柔和阴影。
/// 3. [ApplePageBackground] / [appleCardShadows]：微 tinted 纵深背景 + 双层浮起阴影，
///    让白色/高亮卡片在浅色与深色模式下都明显「浮」于底面之上。
/// 4. [AppleGlassAppBar] / [ShellChromeScope]：真毛玻璃固定顶栏（含大标题滚收过渡）
///    与内容顶距作用域，让页面滚过顶栏和底栏时呈现真实的磨砂模糊透出。
///
/// 性能护栏：`BackdropFilter` 仅存在于固定壳层 [AppleGlassAppBar]，
/// 滚动列表组件 [AppleGroupedSection] 零 `BackdropFilter`。
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'package:love_space/core/theme/motion.dart';
import 'package:love_space/core/theme/tokens.dart';

/// 双层柔和卡片阴影（近处清晰托底 + 远处环境浮起感）。
List<BoxShadow> appleCardShadows(bool dark, {bool elevated = false}) {
  if (dark) {
    return <BoxShadow>[
      BoxShadow(
        color: Colors.black.withValues(alpha: elevated ? 0.36 : 0.26),
        blurRadius: elevated ? 6 : 3,
        offset: const Offset(0, 1),
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: elevated ? 0.46 : 0.34),
        blurRadius: elevated ? 28 : 20,
        spreadRadius: -4,
        offset: Offset(0, elevated ? 10 : 7),
      ),
    ];
  }
  return <BoxShadow>[
    BoxShadow(
      color: Colors.black.withValues(alpha: elevated ? 0.06 : 0.04),
      blurRadius: elevated ? 6 : 3,
      offset: const Offset(0, 1),
    ),
    BoxShadow(
      color: Colors.black.withValues(alpha: elevated ? 0.11 : 0.075),
      blurRadius: elevated ? 26 : 18,
      spreadRadius: -4,
      offset: Offset(0, elevated ? 10 : 7),
    ),
  ];
}

/// 微 tinted 纵深页底色（随当前 ThemeData / ColorScheme 派生，浅深自适应）。
Color appleCanvasColor(ThemeData theme) {
  final cs = theme.colorScheme;
  final dark = theme.brightness == Brightness.dark;
  if (dark) {
    return Color.alphaBlend(
      cs.primary.withValues(alpha: 0.03),
      cs.surface,
    );
  }
  return Color.alphaBlend(
    cs.primary.withValues(alpha: 0.035),
    cs.surfaceContainerLow,
  );
}

/// 纵深页底容器：柔和顶部主题色微晕 + 干净底面，让前景卡片明显浮起。
class ApplePageBackground extends StatelessWidget {
  const ApplePageBackground({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final base = appleCanvasColor(theme);
    final topWash = Color.alphaBlend(
      cs.primary.withValues(alpha: dark ? 0.08 : 0.065),
      base,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const <double>[0.0, 0.28, 1.0],
          colors: <Color>[topWash, base, base],
        ),
      ),
      child: child,
    );
  }
}

/// 图标语义色系（Apple HIG 系统色族，浅深模式高对比度、低刺眼）。
enum AppleIconTone {
  rose,
  coral,
  amber,
  emerald,
  teal,
  sky,
  blue,
  indigo,
  purple,
  pink,
  slate,
}

extension AppleIconToneColor on AppleIconTone {
  Color resolve(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return switch (this) {
      AppleIconTone.rose => dark ? const Color(0xFFE56B84) : const Color(0xFFE04868),
      AppleIconTone.coral => dark ? const Color(0xFFEA7C64) : const Color(0xFFE66248),
      AppleIconTone.amber => dark ? const Color(0xFFE8A446) : const Color(0xFFEA9322),
      AppleIconTone.emerald => dark ? const Color(0xFF4BB879) : const Color(0xFF2EA962),
      AppleIconTone.teal => dark ? const Color(0xFF44B3B0) : const Color(0xFF229A97),
      AppleIconTone.sky => dark ? const Color(0xFF55A9EA) : const Color(0xFF2B8FE0),
      AppleIconTone.blue => dark ? const Color(0xFF5B8FF2) : const Color(0xFF3470E4),
      AppleIconTone.indigo => dark ? const Color(0xFF7C7AE8) : const Color(0xFF5B58D6),
      AppleIconTone.purple => dark ? const Color(0xFFA778E5) : const Color(0xFF8C54D0),
      AppleIconTone.pink => dark ? const Color(0xFFE472A8) : const Color(0xFFD95393),
      AppleIconTone.slate => dark ? const Color(0xFF7B8494) : const Color(0xFF646E7D),
    };
  }
}

/// Apple 风格圆角方形图标徽章（色底 + 柔渐变 + 白色圆润矢量图标）。
class AppleIconBadge extends StatelessWidget {
  const AppleIconBadge({
    super.key,
    required this.icon,
    this.tone = AppleIconTone.blue,
    this.color,
    this.size = 32,
    this.iconSize,
  });

  final IconData icon;
  final AppleIconTone tone;

  /// 可选覆盖色（例如直接使用 `Theme.of(context).colorScheme.primary`）。
  final Color? color;
  final double size;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final base = color ?? tone.resolve(brightness);
    final radius = size * 0.27;
    final resolvedIconSize = iconSize ?? size * 0.56;
    final lighter = Color.lerp(base, Colors.white, 0.16) ?? base;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[lighter, base],
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: base.withValues(alpha: brightness == Brightness.dark ? 0.30 : 0.24),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Icon(
        icon,
        size: resolvedIconSize,
        color: Colors.white,
      ),
    );
  }
}

/// Apple 分组列表容器：组标题 + 统一大圆角卡片 + 细分割线 + 双层浮起阴影。
///
/// 严格零 `BackdropFilter`（滚动列表安全）。
class AppleGroupedSection extends StatelessWidget {
  const AppleGroupedSection({
    super.key,
    this.title,
    this.footer,
    required this.children,
    this.dividerIndent = 60,
    this.margin = EdgeInsets.zero,
    this.radius = AppRadius.large,
  });

  final String? title;
  final String? footer;
  final List<Widget> children;
  final double dividerIndent;
  final EdgeInsetsGeometry margin;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final surface = dark ? cs.surfaceContainerHigh : cs.surface;
    final border = dark
        ? Colors.white.withValues(alpha: 0.08)
        : cs.outlineVariant.withValues(alpha: 0.45);
    final dividerColor = cs.outlineVariant.withValues(alpha: dark ? 0.35 : 0.45);

    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i != children.length - 1) {
        rows.add(
          Divider(
            height: 0.6,
            thickness: 0.6,
            indent: dividerIndent,
            endIndent: Spacing.lg,
            color: dividerColor,
          ),
        );
      }
    }

    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (title != null && title!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(
                left: Spacing.lg,
                right: Spacing.lg,
                bottom: Spacing.sm,
              ),
              child: Text(
                title!,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: cs.outline,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: border, width: 0.8),
              boxShadow: appleCardShadows(dark),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: rows,
                ),
              ),
            ),
          ),
          if (footer != null && footer!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(
                left: Spacing.lg,
                right: Spacing.lg,
                top: Spacing.xs + 2,
              ),
              child: Text(
                footer!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.outline,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Apple 分组列表标准行：左图标徽章 + 标题/副标题 + 右侧值/箭头。
class AppleGroupedRow extends StatelessWidget {
  const AppleGroupedRow({
    super.key,
    this.leading,
    this.icon,
    this.tone = AppleIconTone.blue,
    this.iconColor,
    required this.title,
    this.subtitle,
    this.trailingText,
    this.trailing,
    this.showChevron = true,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(
      horizontal: Spacing.lg,
      vertical: Spacing.md,
    ),
  });

  final Widget? leading;
  final IconData? icon;
  final AppleIconTone tone;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final String? trailingText;
  final Widget? trailing;
  final bool showChevron;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final leadingWidget = leading ??
        (icon != null
            ? AppleIconBadge(icon: icon!, tone: tone, color: iconColor)
            : null);

    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Padding(
        padding: padding,
        child: Row(
          children: <Widget>[
            if (leadingWidget != null) ...<Widget>[
              leadingWidget,
              const SizedBox(width: Spacing.md),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: cs.onSurface,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.outline,
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailingText != null && trailingText!.isNotEmpty) ...<Widget>[
              const SizedBox(width: Spacing.sm),
              Flexible(
                flex: 0,
                child: Text(
                  trailingText!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.outline,
                  ),
                ),
              ),
            ],
            if (trailing != null) ...<Widget>[
              const SizedBox(width: Spacing.sm),
              trailing!,
            ],
            if (showChevron && onTap != null) ...<Widget>[
              const SizedBox(width: Spacing.xs),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: cs.outline.withValues(alpha: 0.72),
              ),
            ],
          ],
        ),
      ),
    );

    if (onTap == null) return content;
    return InkWell(onTap: onTap, child: content);
  }
}

/// 壳层顶距作用域：让五主 Tab 在嵌入 [ShellPage]（`extendBodyBehindAppBar: true`）
/// 时自动预留顶栏高度，独立在 widget 测试里渲染时默认回退 0。
class ShellChromeScope extends InheritedWidget {
  const ShellChromeScope({
    super.key,
    required this.topInset,
    required super.child,
  });

  final double topInset;

  static double topInsetOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellChromeScope>()?.topInset ??
      0;

  @override
  bool updateShouldNotify(ShellChromeScope oldWidget) =>
      oldWidget.topInset != topInset;
}

/// 固定真毛玻璃顶栏（仅用于主壳层与聊天页固定顶栏）。
///
/// 随 [collapseProgress]（0.0 = 页顶大标题展开；1.0 = 滚下收起）平滑淡入
/// 紧凑顶栏标题，并加深底部细高光线。
class AppleGlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  const AppleGlassAppBar({
    super.key,
    this.collapsedTitle,
    this.collapseProgress = 0.0,
    this.leading,
    this.actions = const <Widget>[],
    this.toolbarHeight = kToolbarHeight,
    this.sigma = 20.0,
  });

  final String? collapsedTitle;
  final double collapseProgress;
  final Widget? leading;
  final List<Widget> actions;
  final double toolbarHeight;
  final double sigma;

  @override
  Size get preferredSize => Size.fromHeight(toolbarHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final t = collapseProgress.clamp(0.0, 1.0);
    final topPad = MediaQuery.paddingOf(context).top;

    // 滚下后玻璃不透明度略增，增强前景可读性。
    final bgAlpha = dark ? (0.58 + 0.18 * t) : (0.68 + 0.16 * t);
    final bgColor = (dark ? cs.surfaceContainerHigh : cs.surface)
        .withValues(alpha: bgAlpha);
    final rimColor = (dark ? Colors.white : cs.outlineVariant)
        .withValues(alpha: (dark ? 0.10 : 0.40) * (0.35 + 0.65 * t));

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: AnimatedContainer(
          duration: Motion.fast,
          height: topPad + toolbarHeight,
          padding: EdgeInsets.only(top: topPad),
          decoration: BoxDecoration(
            color: bgColor,
            border: Border(
              bottom: BorderSide(color: rimColor, width: 0.6),
            ),
          ),
          child: Row(
            children: <Widget>[
              if (leading != null)
                Padding(
                  padding: const EdgeInsets.only(left: Spacing.sm),
                  child: leading!,
                )
              else
                const SizedBox(width: Spacing.lg),
              Expanded(
                child: collapsedTitle == null
                    ? const SizedBox.shrink()
                    : AnimatedOpacity(
                        duration: Motion.fast,
                        opacity: t,
                        child: AnimatedSlide(
                          duration: Motion.fast,
                          curve: Curves.easeOutCubic,
                          offset: Offset(0, (1 - t) * 0.25),
                          child: Text(
                            collapsedTitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                              color: cs.onSurface,
                            ),
                          ),
                        ),
                      ),
              ),
              ...actions,
            ],
          ),
        ),
      ),
    );
  }
}
