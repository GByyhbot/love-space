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

/// 挂在聊天页 body 顶部；录音态优先，其次普通提示。
class ChatToastHost extends ConsumerWidget {
  const ChatToastHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rec = ref.watch(chatRecordProvider);
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
      child: rec != null
          ? _RecordBanner(key: const ValueKey('record'), state: rec)
          : toast != null
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

/// 录音状态卡：波形 + 主文案 + 左上取消 / 右上转文字 两个高亮区。
class _RecordBanner extends StatefulWidget {
  const _RecordBanner({super.key, required this.state});
  final ChatRecordState state;

  @override
  State<_RecordBanner> createState() => _RecordBannerState();
}

class _RecordBannerState extends State<_RecordBanner>
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
    final scheme = Theme.of(context).colorScheme;
    final intent = widget.state.intent;
    final (title, accent) = switch (intent) {
      RecordIntent.cancel => ('松开取消录音', scheme.error),
      RecordIntent.toText => ('松开转为文字', scheme.primary),
      RecordIntent.send => ('松开发送 · 上滑取消或转文字', scheme.primary),
    };
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: scheme.inverseSurface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
              blurRadius: 20,
              offset: const Offset(0, 6),
              color: Colors.black.withValues(alpha: 0.24)),
        ],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          _Wave(animation: _c, color: accent),
          const SizedBox(width: 12),
          Expanded(
            child: Text('正在录音',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: scheme.onInverseSurface,
                    fontWeight: FontWeight.w600)),
          ),
        ]),
        const SizedBox(height: 8),
        Text(title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onInverseSurface.withValues(alpha: 0.85))),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
              child: _Zone(
                  label: '左上取消',
                  icon: Icons.close_rounded,
                  selected: intent == RecordIntent.cancel,
                  color: scheme.error)),
          const SizedBox(width: 10),
          Expanded(
              child: _Zone(
                  label: '右上转文字',
                  icon: Icons.text_fields_rounded,
                  selected: intent == RecordIntent.toText,
                  color: scheme.primary)),
        ]),
      ]),
    );
  }
}

class _Wave extends AnimatedWidget {
  const _Wave({required Animation<double> animation, required this.color})
      : super(listenable: animation);
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = (listenable as Animation<double>).value;
    return SizedBox(
      width: 34,
      height: 22,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < 4; i++)
            Container(
              width: 4,
              height: 6 + (1 - (t - i * 0.18).abs().clamp(0.0, 1.0)) * 15,
              decoration: BoxDecoration(
                  color: color, borderRadius: BorderRadius.circular(2)),
            ),
        ],
      ),
    );
  }
}

class _Zone extends StatelessWidget {
  const _Zone(
      {required this.label,
      required this.icon,
      required this.selected,
      required this.color});
  final String label;
  final IconData icon;
  final bool selected;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: selected
            ? color.withValues(alpha: 0.22)
            : scheme.onInverseSurface.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: selected
                ? color.withValues(alpha: 0.75)
                : Colors.transparent,
            width: 1.2),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 15, color: selected ? color : scheme.onInverseSurface),
        const SizedBox(width: 6),
        Text(label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: selected ? color : scheme.onInverseSurface,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400)),
      ]),
    );
  }
}
