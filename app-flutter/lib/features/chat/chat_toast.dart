/// 聊天页顶部提示层（复验修复）：替代底部 SnackBar，不遮挡输入区按钮。
///
/// 真机问题：`ScaffoldMessenger.showSnackBar` 从屏幕底部弹出，「正在录音」
/// 「已撤回」等提示会把输入栏与麦克风按钮整条盖住，录音时无法再次点击结束。
/// 本层统一挂在 body 顶部（AppBar 下方），滑入淡入、2.2s 自动收起；
/// 录音期间显示常驻状态卡，带手势意图高亮（松开发送 / 左上取消 / 右上转文字）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ── 录音手势意图（纯函数，可单测）──────────────────────────────────────

/// 长按录音松手后的动作
enum RecordIntent {
  /// 直接松开 → 发送语音
  send,

  /// 滑到左上角 → 取消
  cancel,

  /// 滑到右上角 → 转文字
  toText,
}

/// 上滑判定阈值（逻辑像素；相对长按起点）
const double recordSlideThreshold = 64.0;

/// 由手指当前位置与长按起点推导意图（微信/QQ 同款，用户定版水平优先）：
/// · 向左滑超阈值（**不要求先上滑**——屏幕下方左右滑动即生效）→ 取消；
/// · 向右滑超阈值 → 转文字；
/// · 其余（原地按住 / 轻微抖动 / 只上滑）→ 发送。
RecordIntent recordIntentFor({
  required Offset finger,
  required Offset origin,
  double threshold = recordSlideThreshold,
}) {
  final dx = finger.dx - origin.dx;
  if (dx <= -threshold) return RecordIntent.cancel;
  if (dx >= threshold) return RecordIntent.toText;
  return RecordIntent.send;
}

// ── 普通提示 ──────────────────────────────────────────────────────────

enum ChatToastTone { info, success, warning, error }

class ChatToastMessage {
  const ChatToastMessage({
    required this.id,
    required this.text,
    required this.tone,
  });
  final int id;
  final String text;
  final ChatToastTone tone;
}

/// 页面级提示控制器：同一时刻只留最新一条，定时器内不访问已释放的 notifier。
class ChatToastController extends Notifier<ChatToastMessage?> {
  Timer? _timer;
  bool _alive = true;
  int _seq = 0;

  @override
  ChatToastMessage? build() {
    _alive = true;
    ref.onDispose(() {
      _alive = false;
      _timer?.cancel();
    });
    return null;
  }

  void show(String text, {ChatToastTone tone = ChatToastTone.info}) {
    _timer?.cancel();
    state = ChatToastMessage(id: ++_seq, text: text, tone: tone);
    _timer = Timer(const Duration(milliseconds: 2200), () {
      if (_alive) state = null;
    });
  }

  void hide() {
    _timer?.cancel();
    if (_alive) state = null;
  }
}

final chatToastProvider =
    NotifierProvider<ChatToastController, ChatToastMessage?>(
        ChatToastController.new);

// ── 录音状态 ──────────────────────────────────────────────────────────

class ChatRecordState {
  const ChatRecordState({required this.intent, required this.startedAt});
  final RecordIntent intent;
  final DateTime startedAt;
}

class ChatRecordController extends Notifier<ChatRecordState?> {
  @override
  ChatRecordState? build() => null;

  void start() => state =
      ChatRecordState(intent: RecordIntent.send, startedAt: DateTime.now());

  void intent(RecordIntent next) {
    final cur = state;
    if (cur == null || cur.intent == next) return;
    state = ChatRecordState(intent: next, startedAt: cur.startedAt);
  }

  void stop() => state = null;
}

final chatRecordProvider =
    NotifierProvider<ChatRecordController, ChatRecordState?>(
        ChatRecordController.new);

// ── 顶部提示宿主 ──────────────────────────────────────────────────────

/// 挂在聊天页 body 顶部，只承载普通提示（已撤回 / 已复制 / 错误等）。
/// 录音态由单独的 [VoiceRecordOverlay] 全屏呈现，不再挤在顶部卡里
///（旧顶部卡会随输入栏被键盘推动，且语义上录音是全屏交互，不该在顶栏）。
class ChatToastHost extends ConsumerWidget {
  const ChatToastHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final toast = ref.watch(chatToastProvider);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => SlideTransition(
        position: Tween<Offset>(
                begin: const Offset(0, -0.35), end: Offset.zero)
            .animate(animation),
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: toast != null
          ? _ToastPill(key: ValueKey('toast-${toast.id}'), message: toast)
          : const SizedBox.shrink(key: ValueKey('empty')),
    );
  }
}

IconData _toneIcon(ChatToastTone tone) => switch (tone) {
      ChatToastTone.info => Icons.info_rounded,
      ChatToastTone.success => Icons.check_circle_rounded,
      ChatToastTone.warning => Icons.error_outline_rounded,
      ChatToastTone.error => Icons.cancel_rounded,
    };

Color _toneAccent(ChatToastTone tone, ColorScheme scheme) => switch (tone) {
      ChatToastTone.info => scheme.primary,
      ChatToastTone.success => const Color(0xFF4CAF82),
      ChatToastTone.warning => const Color(0xFFE8A33D),
      ChatToastTone.error => scheme.error,
    };

class _ToastPill extends StatelessWidget {
  const _ToastPill({super.key, required this.message});
  final ChatToastMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = _toneAccent(message.tone, scheme);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: scheme.inverseSurface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
              blurRadius: 18,
              offset: const Offset(0, 6),
              color: Colors.black.withValues(alpha: 0.22)),
        ],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(_toneIcon(message.tone), size: 18, color: accent),
        const SizedBox(width: 10),
        Flexible(
          child: Text(message.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onInverseSurface,
                  fontWeight: FontWeight.w500,
                  height: 1.35)),
        ),
      ]),
    );
  }
}

/// 微信式语音输入全屏遮罩（对齐视频 85）：
/// · 压暗背景，聊天界面被半透明黑遮罩盖住（录音是全屏交互）；
/// · 中央绿色波形气泡 + 向下尾巴（取消态缩小变红靠左，上方「松手 取消」）；
/// · 底部弧形三区：左弧「取消」/ 右弧「滑到这里 转文字」（深灰白字），
///   最底凸弧「松开 发送」（浅白黑字），当前意图对应区白底高亮；
/// · 手指白点落在当前意图区的中央（发送→大弧中央 / 取消→左弧 / 转文字→右弧）。
/// 纯视觉：`IgnorePointer` 不拦截手势——长按录音的起点在输入框旁的麦克风，
/// 指针 move/up 仍由那个 GestureDetector 接收，遮罩只负责呈现。
class VoiceRecordOverlay extends ConsumerWidget {
  const VoiceRecordOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rec = ref.watch(chatRecordProvider);
    if (rec == null) return const SizedBox.shrink();
    final intent = rec.intent;
    final size = MediaQuery.sizeOf(context);
    final cancel = intent == RecordIntent.cancel;
    final toText = intent == RecordIntent.toText;
    final bubbleTop = size.height * (cancel ? 0.52 : 0.46);
    return IgnorePointer(
      child: Stack(children: [
        // 压暗背景
        ColoredBox(
            color: Colors.black.withValues(alpha: 0.6),
            child: SizedBox(width: size.width, height: size.height)),
        // 中央气泡（取消态靠左缩小）
        Positioned(
          left: 0,
          right: 0,
          top: bubbleTop,
          child: cancel
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                      padding: const EdgeInsets.only(left: 24),
                      child: _RecordBubble(
                          intent: intent, startedAt: rec.startedAt)))
              : Center(
                  child: _RecordBubble(
                      intent: intent, startedAt: rec.startedAt)),
        ),
        // 底部弧形三区
        Positioned(
          left: 0,
          right: 0,
          bottom: MediaQuery.paddingOf(context).bottom,
          child: _ArcZones(
              width: size.width,
              cancel: cancel,
              toText: toText,
              send: !cancel && !toText),
        ),
      ]),
    );
  }
}

/// 录音气泡（对齐微信逐帧取证 f03/f08/f11）：
/// · 发送态：绿色胶囊高 88，宽度随录音时长渐长（0.30 + 0.035/秒，封顶 0.72）；
/// · 取消态：缩小为 100×100 红色方块（靠左），尾巴居中；
/// · 转文字态：近全宽（左右 12 边距）高 108 绿色扁条——左侧绿色光标竖线、
///   波形缩到右下角一小簇（松手后进入文字编辑态的视觉暗示）；
/// · 提示文字（「松手 取消」/「松手 编辑文字」）在气泡**下方**斜排，
///   取消态靠左、转文字态靠右；
/// · 尾巴：发送/取消态居中，转文字态偏右 68%（跟随手势方向）。
/// 时长驱动：Timer.periodic 每秒重建（气泡是纯视觉组件，重建无副作用）。
class _RecordBubble extends StatefulWidget {
  const _RecordBubble({required this.intent, required this.startedAt});
  final RecordIntent intent;
  final DateTime startedAt;

  /// 宽度随时长增长曲线（纯函数，可单测）：
  /// [secs] 秒 → 屏宽占比，基础 0.30、每秒 +0.035、封顶 0.72。
  static double widthFactorFor(int secs,
          {double base = 0.30, double growth = 0.035, double max = 0.72}) =>
      (base + secs * growth).clamp(base, max);

  @override
  State<_RecordBubble> createState() => _RecordBubbleState();
}

class _RecordBubbleState extends State<_RecordBubble> {
  Timer? _ticker;
  int _secs = 0;

  @override
  void initState() {
    super.initState();
    _secs = DateTime.now().difference(widget.startedAt).inSeconds.clamp(0, 60);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _secs++);
    });
  }

  @override
  void didUpdateWidget(covariant _RecordBubble old) {
    super.didUpdateWidget(old);
    if (old.startedAt != widget.startedAt) {
      _secs =
          DateTime.now().difference(widget.startedAt).inSeconds.clamp(0, 60);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final cancel = widget.intent == RecordIntent.cancel;
    final toText = widget.intent == RecordIntent.toText;
    final color = cancel ? const Color(0xFFFF6B5E) : const Color(0xFF95EC69);
    final width = cancel
        ? 100.0
        : toText
            ? size.width - 24
            : size.width * _RecordBubble.widthFactorFor(_secs);
    final height = cancel ? 100.0 : toText ? 108.0 : 88.0;
    final hint = cancel
        ? '松手 取消'
        : toText
            ? '松手 编辑文字'
            : null;
    // 尾巴水平位置：发送/取消态居中，转文字态偏右 68%（跟随手势方向）
    final tailLeft = toText ? width * 0.68 - 11 : (width - 22) / 2;
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment:
            toText ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Stack(clipBehavior: Clip.none, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              width: width,
              height: height,
              padding: EdgeInsets.symmetric(
                  horizontal: toText ? 14 : 20, vertical: toText ? 14 : 12),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [
                  BoxShadow(
                      blurRadius: 22,
                      offset: Offset(0, 8),
                      color: Colors.black38)
                ],
              ),
              child: toText
                  // 转文字态：左侧光标竖线 + 右下角一小簇波形（编辑态暗示）
                  ? Stack(children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                            width: 3,
                            height: 38,
                            decoration: BoxDecoration(
                                color: const Color(0xFF3EB575),
                                borderRadius: BorderRadius.circular(2))),
                      ),
                      Align(
                        alignment: Alignment.bottomRight,
                        child: _RecordWave(
                            color: Colors.black54,
                            bars: 12,
                            barWidth: 3,
                            maxHeight: 22,
                            uniform: true),
                      ),
                    ])
                  : Center(
                      child: _RecordWave(
                          color: Colors.black54,
                          bars: cancel ? 12 : 26,
                          barWidth: cancel ? 4 : 3,
                          maxHeight: 30,
                          uniform: true)),
            ),
            // 向下小尾巴（发送/取消态居中、转文字态偏右 68%）
            Positioned(
              left: tailLeft,
              bottom: -12,
              child: CustomPaint(
                size: const Size(22, 16),
                painter: _TailPainter(color: color),
              ),
            ),
          ]),
          if (hint != null) ...[
            const SizedBox(height: 18),
            Transform.rotate(
              angle: -0.15,
              child: Text(hint,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
            ),
          ],
        ]);
  }
}

/// 气泡尾巴：向下的对称小三角（贴气泡底边，水平位置随意图调整）。
class _TailPainter extends CustomPainter {
  const _TailPainter({required this.color});
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _TailPainter old) => old.color != color;
}
/// 波形（对齐微信 f03：一排细密均匀竖线）。[uniform]=true 等高静止排列，
/// false 保留轻微起伏动画；条数/粗细/峰高可调。
class _RecordWave extends StatefulWidget {
  const _RecordWave(
      {required this.color,
      this.bars = 26,
      this.barWidth = 3,
      this.maxHeight = 30,
      this.uniform = true});
  final Color color;
  final int bars;
  final double barWidth;
  final double maxHeight;
  final bool uniform;

  @override
  State<_RecordWave> createState() => _RecordWaveState();
}

class _RecordWaveState extends State<_RecordWave>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.bars * widget.barWidth * 1.8,
      height: widget.maxHeight,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < widget.bars; i++)
            AnimatedBuilder(
              animation: _c,
              builder: (_, _) {
                final t = _c.value;
                final h = widget.uniform
                    ? widget.maxHeight * (0.92 + 0.08 * (1 - (t * 2 - i * 0.16).abs().clamp(0.0, 1.0)))
                    : widget.maxHeight * 0.14 +
                        (1 - (t * 2 - i * 0.16).abs().clamp(0.0, 1.0)) *
                            widget.maxHeight * 0.86;
                return Container(
                  width: widget.barWidth,
                  height: h,
                  decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
/// 底部弧形三区（对齐微信 f03/f08/f11）：
/// · 左右两块半弧（底部贴屏幕底、顶部半圆拱，两边平分中央断开）；
/// · 中央凸弧（宽度溢出屏幕形成平缓弧顶）：发送态浅灰白「松开 发送」，
///   取消/转文字态弱化显示「语音」；
/// · 手指白点（空心圆圈样式）随意图平滑滑到对应区中央。
class _ArcZones extends StatelessWidget {
  const _ArcZones({
    required this.width,
    required this.cancel,
    required this.toText,
    required this.send,
  });
  final double width;
  final bool cancel;
  final bool toText;
  final bool send;

  static const double zoneH = 240;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: zoneH,
      child: Stack(children: [
        // 左弧「取消」（微信式半弧：底部贴底、顶部拱形，高 96；
        // 两边平分 0.46 宽、中央断开 8%）
        Positioned(
          left: 0,
          bottom: 0,
          width: width * 0.46,
          height: 96,
          child: _ArcTile(
              label: '取消',
              active: cancel,
              width: width * 0.46,
              arc: true),
        ),
        // 右弧「滑到这里 转文字」
        Positioned(
          right: 0,
          bottom: 0,
          width: width * 0.46,
          height: 96,
          child: _ArcTile(
              label: '滑到这里 转文字',
              active: toText,
              width: width * 0.46,
              arc: true),
        ),
        // 中央凸弧（宽度溢出屏幕 → 平缓弧顶；Stack 默认裁剪溢出）
        Positioned(
          left: -width * 0.3,
          right: -width * 0.3,
          bottom: 0,
          height: 110,
          child: CustomPaint(
            size: Size(width * 1.6, 110),
            painter: _ArcPainter(active: send),
          ),
        ),
        // 大弧文字（发送态「松开 发送」/ 取消态「语音」）
        Positioned(
          left: 0,
          right: 0,
          bottom: 42,
          child: Center(
            child: Text(send ? '松开 发送' : '语音',
                style: TextStyle(
                    color: send ? Colors.black : Colors.white70,
                    fontSize: 16,
                    fontWeight: FontWeight.w800)),
          ),
        ),
        // 手指白点（空心圈）：随意图平滑滑到对应区中央
        Align(
          alignment: send
              ? const Alignment(0, 0.72)
              : cancel
                  ? const Alignment(-0.54, 0.6)
                  : const Alignment(0.54, 0.6),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.9),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF8FA6B8), width: 2.5),
              boxShadow: const [
                BoxShadow(blurRadius: 10, color: Colors.black26)
              ],
            ),
          ),
        ),
      ]),
    );
  }
}
/// 左/右弧形块：[arc]=true 时为微信式半弧（底部贴屏幕底、顶部半圆拱形），
/// 文字沿弧面微倾；深灰白字，选中时白底黑字。
class _ArcTile extends StatelessWidget {
  const _ArcTile(
      {required this.label,
      required this.active,
      required this.width,
      this.arc = false});
  final String label;
  final bool active;
  final double width;
  final bool arc;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active
            ? Colors.white.withValues(alpha: 0.95)
            : Colors.white.withValues(alpha: 0.16),
        borderRadius: arc
            // 高 96 容器：顶部半径 48 = 高度一半 → 连续半圆拱顶
            ? const BorderRadius.vertical(top: Radius.circular(48))
            : BorderRadius.circular(52),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Transform.rotate(
        // 沿弧面微倾（逐帧取证：弧内文字逆时针 ~7°）
        angle: -0.12,
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: active ? Colors.black : Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600)),
      ),
    );
  }
}
class _ArcPainter extends CustomPainter {
  const _ArcPainter({required this.active});
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final p = Path()
      ..moveTo(0, h)
      ..quadraticBezierTo(w * 0.5, -70, w, h)
      ..close();
    canvas.drawPath(
        p,
        Paint()
          ..color = active
              ? Colors.white.withValues(alpha: 0.95)
              : Colors.white.withValues(alpha: 0.16));
  }

  @override
  bool shouldRepaint(covariant _ArcPainter old) => old.active != active;
}
