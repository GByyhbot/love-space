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

/// 由手指当前位置与长按起点推导意图（微信/QQ 同款象限语义）：
/// · 未明显上滑 / 正上方 → 发送；
/// · 左上（dx<0 且 dy<0 超阈值）→ 取消；
/// · 右上（dx>0 且 dy<0 超阈值）→ 转文字。
RecordIntent recordIntentFor({
  required Offset finger,
  required Offset origin,
  double threshold = recordSlideThreshold,
}) {
  final dx = finger.dx - origin.dx;
  final dy = finger.dy - origin.dy;
  if (dy > -threshold) return RecordIntent.send;
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

/// 微信式语音输入全屏遮罩（对齐视频 81）：
/// · 压暗背景，聊天界面被半透明黑遮罩盖住（录音是全屏交互，不该挤在顶部卡里）；
/// · 中上部绿色波形气泡（取消态转红）+ 向下小尾巴；
/// · 底部三区：左下「取消」/ 右下「滑到这里 · 转文字」/ 最底「松开 发送」，
///   按当前手势意图([RecordIntent])高亮对应区。
/// 纯视觉：`IgnorePointer` 不拦截手势——长按录音的起点在输入框旁的麦克风，
/// 指针 move/up 仍由那个 GestureDetector 接收，遮罩只负责呈现。
class VoiceRecordOverlay extends ConsumerWidget {
  const VoiceRecordOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rec = ref.watch(chatRecordProvider);
    if (rec == null) return const SizedBox.shrink();
    final intent = rec.intent;
    final top = MediaQuery.of(context).size.height * 0.2;
    return IgnorePointer(
      child: Stack(children: [
        // 压暗背景
        Container(color: Colors.black.withValues(alpha: 0.6)),
        // 中上部：绿色波形气泡（取消态转红）+ 向下尾巴
        Positioned(
          top: top,
          left: 0,
          right: 0,
          child: Center(child: _RecordBubble(intent: intent)),
        ),
        // 底部三区
        Positioned(
          left: 0,
          right: 0,
          bottom: MediaQuery.of(context).padding.bottom,
          child: _RecordZones(intent: intent),
        ),
      ]),
    );
  }
}

/// 录音气泡：微信绿（取消态转红）+ 动态波形 + 向下尾巴。
class _RecordBubble extends StatelessWidget {
  const _RecordBubble({required this.intent});
  final RecordIntent intent;

  @override
  Widget build(BuildContext context) {
    final cancel = intent == RecordIntent.cancel;
    final toText = intent == RecordIntent.toText;
    final color = cancel ? const Color(0xFFFF5B5B) : const Color(0xFF95EC69);
    final caption = cancel
        ? '松开取消'
        : toText
            ? '松开转文字'
            : '手指上滑，取消或转文字';
    return Stack(clipBehavior: Clip.none, children: [
      Container(
        margin: const EdgeInsets.only(bottom: 16, left: 28),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(blurRadius: 22, offset: Offset(0, 8), color: Colors.black38)
          ],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _RecordWave(color: Colors.black87),
          const SizedBox(height: 10),
          Text(caption,
              style: const TextStyle(
                  color: Colors.black87,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
        ]),
      ),
      // 向下小尾巴（气泡左下角）
      Positioned(
        left: 26,
        bottom: 0,
        child: CustomPaint(
          size: const Size(24, 18),
          painter: _TailPainter(color: color),
        ),
      ),
    ]);
  }
}

/// 气泡尾巴：向下的小三角（贴气泡左下角）。
class _TailPainter extends CustomPainter {
  const _TailPainter({required this.color});
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Path()
      ..moveTo(2, 0)
      ..lineTo(size.width, 0)
      ..lineTo(2, size.height)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _TailPainter old) => old.color != color;
}

/// 动态波形（黑色竖条，中间高两侧低、随时间起伏）。
class _RecordWave extends StatefulWidget {
  const _RecordWave({required this.color});
  final Color color;

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
      width: 132,
      height: 42,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < 11; i++)
            AnimatedBuilder(
              animation: _c,
              builder: (_, _) {
                final t = _c.value;
                final phase = (t * 2 - i * 0.16).abs().clamp(0.0, 1.0);
                final h = 7 + (1 - phase) * 30;
                return Container(
                  width: 4,
                  height: h,
                  decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// 底部三区（对齐视频 81：左取消 / 右转文字 / 底发送）。
class _RecordZones extends StatelessWidget {
  const _RecordZones({required this.intent});
  final RecordIntent intent;

  @override
  Widget build(BuildContext context) {
    final cancel = intent == RecordIntent.cancel;
    final toText = intent == RecordIntent.toText;
    final send = !cancel && !toText;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Row(children: [
          Expanded(
            child: _ZonePill(
              label: '取消',
              icon: Icons.close_rounded,
              active: cancel,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _ZonePill(
              label: '滑到这里 · 转文字',
              icon: Icons.text_fields_rounded,
              active: toText,
            ),
          ),
        ]),
      ),
      Container(
        margin: const EdgeInsets.only(bottom: 22, left: 24, right: 24),
        padding: const EdgeInsets.symmetric(vertical: 15),
        decoration: BoxDecoration(
          color: send ? Colors.white : Colors.white.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Center(
          child: Text('松开 发送',
              style: TextStyle(
                  color: send ? Colors.black : Colors.black54,
                  fontSize: 15,
                  fontWeight: FontWeight.w700)),
        ),
      ),
    ]);
  }
}

class _ZonePill extends StatelessWidget {
  const _ZonePill(
      {required this.label, required this.icon, required this.active});
  final String label;
  final IconData icon;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        color: active
            ? const Color(0xFF95EC69)
            : Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 16, color: active ? Colors.black : Colors.white70),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                color: active ? Colors.black : Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
