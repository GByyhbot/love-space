/// 2.4.10 第 01 项「点赞爆粒子」（Like Burst）统一组件：
/// 点击点赞：爱心 1→0.8→1.2→1（带回弹）+ 由灰变红，周围炸开 8 个
/// 彩色小圆点向外飞散淡出；总时长约 600ms。取消点赞：只做颜色/缩放
/// 的简洁反向（1→0.85→1），不放粒子（数字滚动由宿主 LikeCountLabel 承担）。
///
/// 🔴 动画只跟随已确认状态呈现：触发时机 = 点击（乐观期即刻），
/// 服务端失败回滚时 liked 翻回，走「取消」同款简洁反向——与现行
/// 「成功通知在服务端确认后」纪律一致，不引入假成功状态。
/// 粒子挂在按钮局部 Stack（Icon 区）内，不铺卡片级覆盖层（冻结教训）。
/// 动画只动 transform/opacity；时长 600ms 为命名常量。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 点赞爆粒子总时长（提示词钦定约 600ms）。
const Duration kLikeBurstDuration = Duration(milliseconds: 600);

/// 爆点数量（提示词钦定 8 个）。
const int kLikeBurstCount = 8;

/// 点赞按钮爱心（含爆粒子动画）：[liked] 为真源（Record.likes），
/// [onTap] 由宿主接现行点赞切换（乐观翻转 → 服务端确认 → 失败回滚）。
class LikeBurstIcon extends StatefulWidget {
  const LikeBurstIcon({
    super.key,
    required this.liked,
    required this.onTap,
    this.size = 15,
    this.color,
    this.idleColor,
  });

  final bool liked;
  final VoidCallback onTap;
  final double size;
  final Color? color;
  final Color? idleColor;

  @override
  State<LikeBurstIcon> createState() => _LikeBurstIconState();
}

class _LikeBurstIconState extends State<LikeBurstIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: kLikeBurstDuration);
  bool _burst = false; // 本次动画是否爆粒子（点赞方向）

  void _tap() {
    setState(() => _burst = !widget.liked);
    _c.forward(from: 0);
    widget.onTap();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fill = widget.liked
        ? (widget.color ?? cs.primary)
        : (widget.idleColor ?? cs.outline);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: _tap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: SizedBox(
          width: widget.size + kLikeBurstCount,
          height: widget.size + 8,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              // 8 个彩色小圆点（仅点赞方向放粒子）
              if (_burst) ..._particles(cs),
              ScaleTransition(
                scale: _burst ? _burstScale : _cancelScale,
                child: Icon(
                  Icons.favorite_rounded,
                  size: widget.size,
                  color: fill,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 点赞序列：1→0.8（快）→1.2（回弹过冲）→1。
  Animation<double> get _burstScale => TweenSequence<double>([
        TweenSequenceItem(
            tween: Tween(begin: 1.0, end: 0.8)
                .chain(CurveTween(curve: Curves.easeOut)),
            weight: 25),
        TweenSequenceItem(
            tween: Tween(begin: 0.8, end: 1.2)
                .chain(CurveTween(curve: Curves.easeOutBack)),
            weight: 45),
        TweenSequenceItem(
            tween: Tween(begin: 1.2, end: 1.0)
                .chain(CurveTween(curve: Curves.easeOut)),
            weight: 30),
      ]).animate(_c);

  // 取消序列（简洁反向）：1→0.85→1，不放粒子。
  Animation<double> get _cancelScale => TweenSequence<double>([
        TweenSequenceItem(
            tween: Tween(begin: 1.0, end: 0.85)
                .chain(CurveTween(curve: Curves.easeOut)),
            weight: 40),
        TweenSequenceItem(
            tween: Tween(begin: 0.85, end: 1.0)
                .chain(CurveTween(curve: Curves.easeOutBack)),
            weight: 60),
      ]).animate(_c);

  List<Widget> _particles(ColorScheme cs) {
    final tints = [cs.primary, cs.secondary, cs.tertiary];
    return [
      for (var i = 0; i < kLikeBurstCount; i++)
        AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = _c.value;
            // 粒子在前 2/3 时段飞散淡出，随后完全消失。
            final p = (t / 0.66).clamp(0.0, 1.0);
            final angle =
                i * 2 * math.pi / kLikeBurstCount + math.pi / kLikeBurstCount;
            final dist = 6 + 16 * Curves.easeOut.transform(p);
            final opacity = p >= 1 ? 0.0 : (1 - p);
            final dot = _dotSize(p);
            return Opacity(
              opacity: opacity,
              child: Transform.translate(
                offset: Offset(dist * math.cos(angle) - dot / 2,
                    dist * math.sin(angle) - dot / 2),
                child: Container(
                  width: dot,
                  height: dot,
                  decoration: BoxDecoration(
                    color: tints[i % tints.length],
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          },
        ),
    ];
  }

  double _dotSize(double p) => 5 - 3 * p;
}

/// 点赞数标签（数字滚动 +1）：点赞方向新值从下方滚入（向上滚动），
/// 取消方向只淡切（提示词：取消不滚数）。其余文案/口径不变。
class LikeCountLabel extends StatelessWidget {
  const LikeCountLabel({
    super.key,
    required this.liked,
    required this.count,
    this.style,
  });

  final bool liked;
  final int count;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: liked
          ? (child, anim) => SlideTransition(
                position: anim.drive(
                    Tween(begin: const Offset(0, 0.9), end: Offset.zero)),
                child: child,
              )
          : (child, anim) => FadeTransition(opacity: anim, child: child),
      child: Text(
        count <= 0 ? '喜欢' : '$count',
        key: ValueKey('like-count-$count'),
        style: style,
      ),
    );
  }
}
