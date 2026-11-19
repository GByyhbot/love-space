/// 2.4.10 第 04 项「长按确认」（Hold to Confirm）统一组件：
/// 圆形按钮，按住时外圈进度环顺时针走满（1.5s）；中途松手进度环
/// 倒退归零、不执行任何操作；走满后按钮左右轻震一下，变成对勾 +
/// 「已删除」，随后触发 [onConfirm]（由宿主关闭弹层/执行删除——
/// 原确认流程与软删/回收站逻辑零改动，本组件只换确认形态）。
///
/// 附录 B 纪律：进度环/对勾/位移只动 transform/opacity/描边进度；
/// 时长 1.5s 为命名常量。12 处删除确认统一接入（2.4.10 盘点定案）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 长按确认时长（提示词钦定 1.5 秒）。
const Duration kHoldConfirmDuration = Duration(milliseconds: 1500);

/// 走满后「已删除」驻留时长（可见对勾反馈再交还宿主）。
const Duration kHoldDoneDuration = Duration(milliseconds: 450);

/// 长按确认按钮：宿主把原确认弹层的「删除」FilledButton 换成本组件，
/// [onConfirm] 等价原 onPressed（pop(true) 等）。[icon] 默认删除图标。
class HoldToConfirmButton extends StatefulWidget {
  const HoldToConfirmButton({
    super.key,
    required this.onConfirm,
    this.label = '已删除',
    this.icon = Icons.delete_outline_rounded,
    this.size = 52,
    this.errorColor,
  });

  final VoidCallback onConfirm;
  final String label;
  final IconData icon;
  final double size;
  final Color? errorColor;

  @override
  State<HoldToConfirmButton> createState() => _HoldToConfirmButtonState();
}

class _HoldToConfirmButtonState extends State<HoldToConfirmButton>
    with TickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: kHoldConfirmDuration, value: 0);
  late final AnimationController _shakeC = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 240));
  bool _done = false;

  @override
  void initState() {
    super.initState();
    // 🔴 走满判定用 status listener（不许在 build 里 setState——
    // 乙批首测实证 build 期 setState 炸）；监听挂 initState（late final
    // 懒初始化 + 构造期 createTicker 会撞 unmounted，乙批首测实证）。
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed && !_done) {
        _done = true;
        if (mounted) setState(() {});
        _shakeThenConfirm();
      }
    });
  }


  void _onDown() {
    if (_done) return;
    _c.forward();
  }

  void _onUp() {
    if (_done) return;
    // 中途松手：进度环倒退归零，不执行任何操作。
    _c.reverse();
  }

  Future<void> _shakeThenConfirm() async {
    // 左右轻震一下（正弦双摆动）。
    unawaited(_shakeC.forward(from: 0));
    // 对勾 + 「已删除」驻留一拍再交还宿主（关弹层）。
    await Future<void>.delayed(kHoldDoneDuration);
    if (!mounted) return;
    widget.onConfirm();
  }

  @override
  void dispose() {
    _c.dispose();
    _shakeC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final danger = widget.errorColor ?? cs.error;
    final s = widget.size;
    Widget core = AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        final done = _done;
        return CustomPaint(
          painter: _HoldRingPainter(
            progress: done ? 1 : t,
            track: cs.surfaceContainerHighest.withValues(alpha: 0.6),
            arc: danger,
          ),
          child: Container(
            width: s,
            height: s,
            alignment: Alignment.center,
            child: done
                ? const Icon(Icons.check_rounded,
                    size: 24, color: Color(0xFF34A853))
                : Icon(widget.icon, size: 20, color: danger),
          ),
        );
      },
    );
    if (_done) {
      // 走满后左右轻震一下（对勾期间正弦位移）。
      core = AnimatedBuilder(
        animation: _shakeC,
        builder: (context, child) {
          final dx = _shakeC.isAnimating
              ? math.sin(_shakeC.value * 2 * math.pi) * 4
              : 0.0;
          return Transform.translate(offset: Offset(dx, 0), child: child);
        },
        child: core,
      );
    }
    return Semantics(
      button: true,
      child: GestureDetector(
        onLongPressStart: (_) => _onDown(),
        onLongPressEnd: (_) => _onUp(),
        onLongPressCancel: _onUp,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            core,
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _done
                  ? Text(widget.label,
                      key: const ValueKey('hold-done'),
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: danger))
                  : const SizedBox(width: 1, height: 0),
            ),
          ]),
        ),
      ),
    );
  }
}

/// 外圈进度环：底环细环 + 强调弧从 12 点方向顺时针（sweep=progress·2π），
/// 端点圆头（StrokeCap.round）。只画描边（transform/opacity 纪律）。
class _HoldRingPainter extends CustomPainter {
  const _HoldRingPainter({
    required this.progress,
    required this.track,
    required this.arc,
  });

  final double progress;
  final Color track;
  final Color arc;

  @override
  void paint(Canvas canvas, Size size) {
    final box = Offset.zero & size;
    final stroke = 3.0;
    final rect = box.deflate(stroke);
    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(rect, 0, 2 * math.pi, false, trackPaint);
    if (progress <= 0) return;
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = arc;
    canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * progress, false, arcPaint);
  }

  @override
  bool shouldRepaint(_HoldRingPainter old) =>
      old.progress != progress || old.arc != arc || old.track != track;
}
