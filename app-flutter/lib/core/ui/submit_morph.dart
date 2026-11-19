/// 2.4.10 第 02 项「提交按钮三连变」（Submit Morph）统一组件：
/// 点击后 文字淡出 → 按钮宽度收缩成圆（约 300ms ease-in-out）→
/// 圆内旋转加载环 → 成功后变绿画出对勾 → 约 1 秒后恢复原状。
///
/// 🔴 状态必须由真实请求驱动：[SubmitMorphController.submit] 接收
/// `Future<bool> Function()`——加载环转到 Future 完成为止；返回
/// true = 成功（对勾 + 1s 后恢复）；返回 false 或抛异常 = 失败
/// （不出现对勾，直接恢复原状，错误提示由调用方走既有通道）。
///
/// 收缩时长 300ms / 成功驻留 1s 均为命名常量（附录 B 纪律）。
/// 「按压→进行中→让位→落点确认」四段：按压段走默认水波纹，
/// 进行中=旋转环，落点确认=对勾（失败=回到原状）。
library;

import 'package:flutter/material.dart';

/// 按钮收缩成圆时长（提示词钦定约 300ms）。
const Duration kMorphCollapseDuration = Duration(milliseconds: 300);

/// 成功对勾后的驻留时长（提示词钦定约 1 秒）。
const Duration kMorphSuccessHoldDuration = Duration(seconds: 1);

/// 收缩后的圆径。
const double kMorphCircleSize = 44;

/// 对勾专属 Key（测试定位用，避开 MaterialApp 内部 CustomPaint）。
const Key morphCheckKey = ValueKey('morph-check');

/// 成功态填充色（提示词钦定「变绿」；语义色恒绿，浅深同值）。
const Color kMorphSuccessColor = Color(0xFF34A853);

/// 三连变状态机：idle → loading → (success 驻留 → idle | idle)。
/// FilledButton 直连（[SubmitMorphButton]）与 GlassActionBar 内嵌
/// （settings_widgets）共用同一状态机。
class SubmitMorphController extends ChangeNotifier {
  SubmitMorphPhase _phase = SubmitMorphPhase.idle;
  SubmitMorphPhase get phase => _phase;
  bool get busy => _phase != SubmitMorphPhase.idle;

  /// 提交编排：进入 loading → 等 [action] → success 驻留 1s 后回
  /// idle（成功）或直接回 idle（失败）。返回是否成功。
  /// busy 期间重复调用被忽略（防连点）。
  Future<bool> submit(Future<bool> Function() action) async {
    if (busy) return false;
    _phase = SubmitMorphPhase.loading;
    notifyListeners();
    bool ok;
    try {
      ok = await action();
    } catch (_) {
      ok = false;
    }
    if (ok) {
      _phase = SubmitMorphPhase.success;
      notifyListeners();
      await Future<void>.delayed(kMorphSuccessHoldDuration);
    }
    _phase = SubmitMorphPhase.idle;
    notifyListeners();
    return ok;
  }

  /// 外部强制复位（页面销毁时防 setState after dispose 用）。
  void reset() {
    if (_phase == SubmitMorphPhase.idle) return;
    _phase = SubmitMorphPhase.idle;
    notifyListeners();
  }
}

enum SubmitMorphPhase { idle, loading, success }

/// 三连变渲染体：phase=idle 时不渲染（宿主渲染原按钮）；loading/
/// success 时宽度从 [measuredWidth] 300ms 收缩为 [kMorphCircleSize]
/// 圆，圆内 spinner 或对勾。
class MorphArea extends StatelessWidget {
  const MorphArea({
    super.key,
    required this.phase,
    required this.measuredWidth,
    this.height = kMorphCircleSize,
  });

  final SubmitMorphPhase phase;
  final double? measuredWidth;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final start = measuredWidth ?? 160;
    final loading = phase == SubmitMorphPhase.loading;
    return TweenAnimationBuilder<double>(
      // 🔴 key 稳定（不含 phase）：loading→success 只换色不重放收缩。
      key: const ValueKey('morph-area'),
      tween: Tween(begin: start, end: kMorphCircleSize),
      duration: kMorphCollapseDuration,
      curve: Curves.easeInOut,
      builder: (context, w, child) => SizedBox(
        width: w,
        height: height,
        child: child,
      ),
      child: AnimatedContainer(
        duration: Duration.zero,
        width: kMorphCircleSize,
        height: kMorphCircleSize,
        decoration: BoxDecoration(
          color: loading ? cs.primary : kMorphSuccessColor,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: loading
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  valueColor: AlwaysStoppedAnimation(
                      cs.primary.computeLuminance() > 0.5
                          ? Colors.black87
                          : Colors.white),
                ),
              )
            : const _MorphCheck(),
      ),
    );
  }
}

/// 对勾描画（PathMetric 描边动画，400ms ease-out）。
class _MorphCheck extends StatelessWidget {
  const _MorphCheck();

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      builder: (context, t, _) => CustomPaint(
        key: morphCheckKey,
        size: const Size(20, 20),
        painter: _CheckPainter(t),
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  const _CheckPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * 0.18, size.height * 0.54)
      ..lineTo(size.width * 0.42, size.height * 0.76)
      ..lineTo(size.width * 0.84, size.height * 0.28);
    final metric = path.computeMetrics().first;
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(metric.extractPath(0, metric.length * t), paint);
  }

  @override
  bool shouldRepaint(_CheckPainter oldDelegate) => oldDelegate.t != t;
}

/// 独立形态的三连变按钮（FilledButton 直连）：适合散装提交按钮。
/// [onSubmit] 返回 true=成功（对勾+恢复）；false/异常=失败（恢复，
/// 提示由调用方走既有通道）。[expand]=true 满宽（Row stretch 场景），
/// 收缩圆在自身槽位居中；[onSuccess] 成功落点回调（关弹层等）。
class SubmitMorphButton extends StatefulWidget {
  const SubmitMorphButton({
    super.key,
    required this.label,
    required this.onSubmit,
    this.expand = false,
    this.onSuccess,
  });

  final String label;
  final Future<bool> Function() onSubmit;
  final bool expand;
  final VoidCallback? onSuccess;

  @override
  State<SubmitMorphButton> createState() => _SubmitMorphButtonState();
}

class _SubmitMorphButtonState extends State<SubmitMorphButton> {
  final SubmitMorphController _c = SubmitMorphController();
  final GlobalKey _key = GlobalKey();
  double? _measured;
  SubmitMorphPhase _phase = SubmitMorphPhase.idle;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    _c.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final was = _phase;
    _phase = _c.phase;
    setState(() {});
    if (was == SubmitMorphPhase.success &&
        _c.phase == SubmitMorphPhase.idle) {
      widget.onSuccess?.call();
    }
  }

  Future<void> _tap() async {
    if (_c.busy) return;
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    _measured = box?.size.width;
    await _c.submit(widget.onSubmit);
  }

  @override
  Widget build(BuildContext context) {
    final morphing = _c.phase != SubmitMorphPhase.idle;
    if (morphing) {
      final area = MorphArea(
        phase: _c.phase,
        measuredWidth: _measured,
      );
      // expand（满宽槽位）时圆居中；非 expand 场景（Row 里散装钮）
      // 直接给自定宽的 MorphArea——不可用 Align（Row 无界约束会炸 Infinity）。
      return widget.expand ? Center(child: area) : area;
    }
    final button = FilledButton(
      onPressed: _tap,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      child: Text(widget.label, key: _key),
    );
    return widget.expand
        ? SizedBox(width: double.infinity, child: button)
        : button;
  }
}
