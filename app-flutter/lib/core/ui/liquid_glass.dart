/// Apple Liquid Glass（iOS 26 风格）轻量呈现基元（2.8.7 界面适配优化令）。
///
/// 性能护栏（Android 落地）：
/// · [LiquidGlassSurface] 是唯一允许使用 `BackdropFilter` 的新组件，且**仅限**
///   用于少量固定浮层（轨迹回放悬浮条、互动抽屉、悬浮操作胶囊）；
/// · [LiquidGlassCard] 用于滚动列表卡片，**禁用 `BackdropFilter`**，改用预烘焙
///   半透明底色 + 同心圆角 + 1px 高光描边 + 轻阴影，保证低端机滚动流畅。
library;

import 'dart:ui' show FontFeature, ImageFilter;

import 'package:flutter/material.dart';

import 'package:love_space/core/theme/motion.dart';
import 'package:love_space/core/theme/tokens.dart';
import 'apple_ui.dart';
import 'pressable_scale.dart';

/// 外层卡片默认圆角（对齐 Liquid Glass 大圆角 20，同心内嵌元素用 [kGlassInnerRadius]）。
const double kGlassRadius = AppRadius.large;

/// 嵌套元素圆角：`AppRadius.concentric(20, 8) = 12`（同心圆角：外圆角 = 内圆角 + 间距）。
const double kGlassInnerRadius = AppRadius.small;

/// 悬浮条 / 抽屉顶部特大圆角（28）。
const double kGlassSheetRadius = AppRadius.xl;

/// 等宽数字特性：防计时/百分比/分钟数跳动抖动。
const List<FontFeature> kTabularFigures = <FontFeature>[
  FontFeature.tabularFigures(),
];

/// 为数字文本附加等宽数字特性（[base] 为空时自动补默认样式）。
TextStyle tabularStyle(TextStyle? base) =>
    (base ?? const TextStyle()).copyWith(fontFeatures: kTabularFigures);

/// 滚动列表专用的预烘焙液态玻璃卡片（无 `BackdropFilter`）。
class LiquidGlassCard extends StatelessWidget {
  const LiquidGlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Spacing.cardPad),
    this.radius = kGlassRadius,
    this.tint,
    this.borderColor,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? tint;
  final Color? borderColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;

    final baseSurface = tint ??
        (dark
            ? cs.surfaceContainerHigh.withValues(alpha: 0.78)
            : cs.surface.withValues(alpha: 0.90));
    final rimColor = borderColor ??
        (dark
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.white.withValues(alpha: 0.72));
    final strokeFallback =
        cs.outlineVariant.withValues(alpha: dark ? 0.45 : 0.60);

    final box = Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: baseSurface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: Color.alphaBlend(rimColor, strokeFallback),
          width: 1,
        ),
        boxShadow: appleCardShadows(dark),
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(radius),
        child: onTap == null
            ? Padding(padding: padding, child: child)
            : InkWell(
                borderRadius: BorderRadius.circular(radius),
                onTap: onTap,
                child: Padding(padding: padding, child: child),
              ),
      ),
    );

    if (onTap == null) return box;
    return PressableScale(onTap: onTap, child: box);
  }
}

/// 固定浮层专用的真毛玻璃表面（含 `BackdropFilter` 模糊，严格限用于固定浮层）。
class LiquidGlassSurface extends StatelessWidget {
  const LiquidGlassSurface({
    super.key,
    required this.child,
    this.borderRadius,
    this.padding = EdgeInsets.zero,
    this.sigma = 16.0,
    this.tint,
  });

  final Widget child;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry padding;
  final double sigma;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final br = borderRadius ?? BorderRadius.circular(kGlassSheetRadius);
    final fill = tint ??
        (dark
            ? cs.surfaceContainerHigh.withValues(alpha: 0.74)
            : cs.surface.withValues(alpha: 0.84));
    final rim = dark
        ? Colors.white.withValues(alpha: 0.16)
        : Colors.white.withValues(alpha: 0.80);

    return Container(
      decoration: BoxDecoration(
        borderRadius: br,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.42 : 0.12),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: br,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: br,
              border: Border.all(
                color: Color.alphaBlend(
                  rim,
                  cs.outlineVariant.withValues(alpha: 0.45),
                ),
                width: 1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 分段项配置（供 [LiquidPillSegmented] 使用）。
class LiquidPillSegment<T> {
  const LiquidPillSegment({
    required this.value,
    required this.label,
    this.key,
  });

  final T value;
  final String label;
  final Key? key;
}

/// 同心胶囊分段控制器（外圆角 14，内间距 3，选中胶囊圆角 11）。
class LiquidPillSegmented<T> extends StatelessWidget {
  const LiquidPillSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.expand = false,
  });

  final List<LiquidPillSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;

    Widget buildItem(LiquidPillSegment<T> seg) {
      final isSelected = seg.value == selected;
      final item = GestureDetector(
        key: seg.key,
        behavior: HitTestBehavior.opaque,
        onTap: isSelected ? null : () => onChanged(seg.value),
        child: AnimatedContainer(
          duration: Motion.fast,
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: isSelected
                ? (dark ? cs.primaryContainer : cs.surface)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            boxShadow: isSelected
                ? <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: dark ? 0.25 : 0.08),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              seg.label,
              maxLines: 1,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected
                    ? (dark ? cs.onPrimaryContainer : cs.onSurface)
                    : cs.outline,
              ),
            ),
          ),
        ),
      );
      return expand ? Expanded(child: item) : item;
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: dark ? 0.55 : 0.72),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: dark ? 0.45 : 0.65),
        ),
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: [for (final s in segments) buildItem(s)],
      ),
    );
  }
}

/// 状态灯语义档。
enum LivePillTone { active, idle, warn }

/// 在线 / 休眠 / 停用胶囊状态灯（默认单行省略，[ellipsis]=false 时完整展示不截断）。
class LiveStatusPill extends StatelessWidget {
  const LiveStatusPill({
    super.key,
    required this.label,
    this.tone = LivePillTone.active,
    this.ellipsis = true,
  });

  final String label;
  final LivePillTone tone;
  final bool ellipsis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final (bg, fg, dot) = switch (tone) {
      LivePillTone.active => (
          cs.primaryContainer.withValues(alpha: 0.78),
          cs.onPrimaryContainer,
          cs.primary,
        ),
      LivePillTone.idle => (
          cs.surfaceContainerHighest.withValues(alpha: 0.72),
          cs.outline,
          cs.outline,
        ),
      LivePillTone.warn => (
          cs.errorContainer.withValues(alpha: 0.78),
          cs.error,
          cs.error,
        ),
    };
    final textWidget = Text(
      label,
      maxLines: ellipsis ? 1 : 2,
      softWrap: !ellipsis,
      overflow: ellipsis ? TextOverflow.ellipsis : TextOverflow.visible,
      style: theme.textTheme.labelSmall?.copyWith(
        color: fg,
        fontWeight: FontWeight.w600,
      ),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Flexible(child: textWidget),
        ],
      ),
    );
  }
}

/// 44×44 电量圆环指示器（等宽数字防抖，<=20% 切换警示色）。
class BatteryRing extends StatelessWidget {
  const BatteryRing({
    super.key,
    required this.battery,
    this.charging,
  });

  final int battery;
  final bool? charging;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final clamped = battery.clamp(0, 100);
    final low = clamped <= 20 && charging != true;
    final fill = low ? cs.error : cs.primary;
    final track = cs.outlineVariant.withValues(alpha: 0.45);
    final subLabel = charging == true
        ? '充电中'
        : (clamped <= 20 ? '低电量' : (charging == false ? '未充电' : null));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 44,
          height: 44,
          child: CustomPaint(
            painter: _BatteryRingPainter(
              fraction: clamped / 100.0,
              track: track,
              fill: fill,
            ),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    '$clamped%',
                    maxLines: 1,
                    style: tabularStyle(
                      theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: low ? cs.error : cs.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (subLabel != null) ...[
          const SizedBox(height: 3),
          Text(
            subLabel,
            maxLines: 1,
            style: theme.textTheme.labelSmall?.copyWith(
              color: low ? cs.error : cs.outline,
              fontSize: 10,
            ),
          ),
        ],
      ],
    );
  }
}

class _BatteryRingPainter extends CustomPainter {
  const _BatteryRingPainter({
    required this.fraction,
    required this.track,
    required this.fill,
  });

  final double fraction;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 4.0;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - stroke) / 2;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    if (fraction > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -1.5707963267948966,
        6.283185307179586 * fraction,
        false,
        Paint()
          ..color = fill
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_BatteryRingPainter old) =>
      old.fraction != fraction || old.track != track || old.fill != fill;
}

/// 统一卡片区头（苹果风格分组小标题 + 可选右侧动作文案）。
class GlassSectionHeader extends StatelessWidget {
  const GlassSectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding = const EdgeInsets.symmetric(horizontal: Spacing.xs),
  });

  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: cs.outline,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 列表顶/底微渐隐遮罩（纯 Gradient，无 BackdropFilter，配合悬浮玻璃栏使用）。
class GlassEdgeFade extends StatelessWidget {
  const GlassEdgeFade({
    super.key,
    this.top = false,
    this.height = 24,
  });

  final bool top;
  final double height;

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.surface;
    return IgnorePointer(
      child: Container(
        height: height,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: top ? Alignment.topCenter : Alignment.bottomCenter,
            end: top ? Alignment.bottomCenter : Alignment.topCenter,
            colors: [bg.withValues(alpha: 0.85), bg.withValues(alpha: 0)],
          ),
        ),
      ),
    );
  }
}
