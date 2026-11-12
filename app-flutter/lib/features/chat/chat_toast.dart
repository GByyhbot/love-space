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

/// 由手指当前位置与长按起点推导意图（微信/QQ 同款，水平优先）：
/// · 向左滑超阈值（不要求先上滑——屏幕下方左右滑动即生效）→ 取消；
/// · 向右滑超阈值 → 转文字；
/// · 其余（原地按住 / 轻微抖动 / 只上滑）→ 发送。
/// [currentIntent] 迟滞防抖：已在某区时退出该区用更小的退出阈值
///（enter=threshold / exit=threshold-[hysteresis]），边界来回滑动不闪烁。
RecordIntent recordIntentFor({
  required Offset finger,
  required Offset origin,
  double threshold = recordSlideThreshold,
  RecordIntent? currentIntent,
  double hysteresis = 16.0,
}) {
  final dx = finger.dx - origin.dx;
  final enter = threshold;
  final exit = threshold - hysteresis;
  final cur = currentIntent ?? RecordIntent.send;
  switch (cur) {
    case RecordIntent.cancel:
      if (dx >= enter) return RecordIntent.toText;
      if (dx > -exit) return RecordIntent.send;
      return RecordIntent.cancel;
    case RecordIntent.toText:
      if (dx <= -enter) return RecordIntent.cancel;
      if (dx < exit) return RecordIntent.send;
      return RecordIntent.toText;
    case RecordIntent.send:
      if (dx <= -enter) return RecordIntent.cancel;
      if (dx >= enter) return RecordIntent.toText;
      return RecordIntent.send;
  }
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

/// 归一化录音音量（0..1；由 chat_compose 订阅 record 的
/// onAmplitudeChanged dBFS 映射写入），气泡真波形数据源。
final chatVolumeProvider = StateProvider<double>((_) => 0);

class ChatRecordState {
  const ChatRecordState({
    required this.intent,
    required this.startedAt,
    this.ending,
  });
  final RecordIntent intent;
  final DateTime startedAt;

  /// 松手后的收尾方式（overlay 播完收尾动画后置空整个状态）：
  /// send=气泡下沉淡出 / cancel=气泡向取消胶囊缩小消失。
  final RecordEnding? ending;

  /// 录音秒数（60s 上限倒计时用）
  int get elapsedSeconds =>
      DateTime.now().difference(startedAt).inSeconds.clamp(0, 60);
}

enum RecordEnding { send, cancel }

class ChatRecordController extends Notifier<ChatRecordState?> {
  Timer? _endingTimer;

  @override
  ChatRecordState? build() {
    ref.onDispose(() => _endingTimer?.cancel());
    return null;
  }

  void start() => state =
      ChatRecordState(intent: RecordIntent.send, startedAt: DateTime.now());

  void intent(RecordIntent next) {
    final cur = state;
    if (cur == null || cur.ending != null || cur.intent == next) return;
    state = ChatRecordState(
        intent: next, startedAt: cur.startedAt, ending: cur.ending);
  }

  /// 松手收尾：进入 ending 态播 320ms 收尾动画后清空（不许硬切）。
  /// [ending] 为 null 表示直接清除（异常路径兜底）。
  void stop({RecordEnding? ending}) {
    _endingTimer?.cancel();
    final cur = state;
    if (cur == null) return;
    if (ending == null) {
      state = null;
      return;
    }
    state = ChatRecordState(
        intent: cur.intent, startedAt: cur.startedAt, ending: ending);
    _endingTimer = Timer(const Duration(milliseconds: 320), () {
      state = null;
    });
  }
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
/// 微信式语音输入全屏遮罩（按微信原版规格重做，用户定版 8 条）：
/// · 压暗背景 150ms 淡入；扇面 220ms easeOutBack 上升带轻回弹；
///   气泡 320ms easeOutBack 弹入（0.8→1）——时长收进 120/220/320 三档；
/// · 气泡钉死屏幕水平居中、距遮罩顶 40%，全程不跟手指；
///   宽度随实时音量在 0.44~0.52 屏宽间弹性呼吸（120ms 弹簧过渡）；
/// · 三态同高同位：默认主题绿；取消态仅变红 #FA5151 并缩到 0.85；
///   转文字态原地展开为提示卡（当前无 ASR 能力，见交付小结缺口报告）；
/// · 扇面深灰渐变 + 浅色同心弧带；胶囊进入时纯白填充+深字+1.06 放大；
/// · 松手收尾 320ms：发送=气泡下沉淡出 / 取消=向取消胶囊方向缩小消失。
/// 纯视觉：`IgnorePointer` 不拦截手势——指针 move/up 由原 GestureDetector 接收。
class VoiceRecordOverlay extends ConsumerWidget {
  const VoiceRecordOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rec = ref.watch(chatRecordProvider);
    if (rec == null) return const SizedBox.shrink();
    final intent = rec.intent;
    final cancel = intent == RecordIntent.cancel;
    final toText = intent == RecordIntent.toText;
    final ending = rec.ending;
    return IgnorePointer(
      // LayoutBuilder 取遮罩自身（= body）高度定位：MediaQuery.sizeOf 是
      // 全屏高，Positioned.top 相对 body Stack（AppBar 之下），混用会偏一个
      // AppBar（真机 91 录屏实证）。
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth;
        final h = box.maxHeight;
        return Stack(children: [
          // 压暗背景（150ms 淡入，铺满 body 全域）
          Positioned.fill(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              builder: (_, t, _) =>
                  ColoredBox(color: Colors.black.withValues(alpha: 0.6 * t)),
            ),
          ),
          // 气泡：钉死水平居中、距顶 40%，全程不跟手指
          Positioned(
            left: 0,
            right: 0,
            top: h * 0.40,
            child: Center(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.8, end: 1),
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutBack,
                builder: (_, appear, child) => Transform.scale(
                  scale: appear,
                  child: Opacity(opacity: appear.clamp(0, 1), child: child),
                ),
                child: _RecordBubble(
                    intent: intent,
                    ending: ending,
                    startedAt: rec.startedAt),
              ),
            ),
          ),
          // 底部扇面（220ms easeOutBack 上升带轻回弹）
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 1, end: 0),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutBack,
              builder: (_, t, child) => Transform.translate(
                offset: Offset(0, t * 80),
                child: child,
              ),
              child: _FanPanel(
                  width: w,
                  cancel: cancel,
                  toText: toText,
                  send: !cancel && !toText),
            ),
          ),
        ]);
      }),
    );
  }
}

/// 录音气泡（微信规格）：
/// · 颜色：默认主题绿 #95EC69，取消态 #FA5151 + 缩放 0.85（同高同位不移动）；
///   转文字态：原地变提示卡（无 ASR 能力——缺口见交付小结，不给假交互）；
/// · 高度 88 恒定；宽度 = 0.44 屏宽基础 + 实时音量呼吸（最多 +0.08 屏宽），
///   120ms 弹簧过渡，不做线性跳变；
/// · 真波形：24 根深绿竖条，高度由 chatVolumeProvider 实时音量映射，
///   帧间平滑插值（每 60ms tick），静音回落基线；
/// · 60s 上限：最后 10 秒在气泡内显示倒计时。
class _RecordBubble extends ConsumerStatefulWidget {
  const _RecordBubble({
    required this.intent,
    required this.ending,
    required this.startedAt,
  });
  final RecordIntent intent;
  final RecordEnding? ending;
  final DateTime startedAt;

  /// 宽度随音量弹性曲线（纯函数，可单测）：[volume] 0..1 → 屏宽占比，
  /// 基础 0.44、呼吸幅度 0.08、封顶 0.52。
  static double widthFactorFor(double volume,
          {double base = 0.44, double breath = 0.08, double max = 0.52}) =>
      (base + volume.clamp(0, 1) * breath).clamp(base, max);

  @override
  ConsumerState<_RecordBubble> createState() => _RecordBubbleState();
}

class _RecordBubbleState extends ConsumerState<_RecordBubble> {
  static const _cancelColor = Color(0xFFFA5151);
  static const _bubbleColor = Color(0xFF95EC69);
  static const _waveColor = Color(0xFF2E9E52); // 深绿波形压亮绿气泡

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final volume = ref.watch(chatVolumeProvider);
    final cancel = widget.intent == RecordIntent.cancel;
    final toText = widget.intent == RecordIntent.toText;
    final ending = widget.ending;
    // 60s 上限：最后 10 秒气泡内倒计时
    final secsLeft = 60 -
        DateTime.now().difference(widget.startedAt).inSeconds.clamp(0, 60);
    return TweenAnimationBuilder<Offset>(
      tween: Tween(
          begin: Offset.zero,
          end: ending == RecordEnding.send
              ? const Offset(0, 0.35)
              : ending == RecordEnding.cancel
                  ? const Offset(-0.55, 0.45)
                  : Offset.zero),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeIn,
      builder: (_, off, child) => FractionalTranslation(
          translation: off,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 1, end: ending == null ? 1 : 0),
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeIn,
            builder: (_, op, inner) =>
                Opacity(opacity: op.clamp(0, 1), child: inner),
            child: child,
          )),
      child: AnimatedScale(
        scale: cancel ? 0.85 : 1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutBack,
          width: size.width * _RecordBubble.widthFactorFor(volume),
          height: 88,
          decoration: BoxDecoration(
            color: cancel ? _cancelColor : _bubbleColor,
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [
              BoxShadow(
                  blurRadius: 22, offset: Offset(0, 8), color: Colors.black38)
            ],
          ),
          child: toText
              // 转文字提示卡（无 ASR：明确告知，不做假交互）
              ? const Center(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.graphic_eq_rounded,
                            size: 26, color: Color(0xFF2E9E52)),
                        SizedBox(height: 6),
                        Text('语音识别暂未开放',
                            style: TextStyle(
                                color: Color(0xFF1E4620),
                                fontSize: 14,
                                fontWeight: FontWeight.w700)),
                      ]),
                )
              : Center(
                  child: secsLeft <= 10
                      ? Text('还可以说 $secsLeft 秒',
                          style: const TextStyle(
                              color: Color(0xFF1E4620),
                              fontSize: 15,
                              fontWeight: FontWeight.w800))
                      : const _RealWave(color: _waveColor)),
        ),
      ),
    );
  }
}

/// 真波形：24 根竖条。高度由录音实时音量（chatVolumeProvider，dBFS 映射）
/// 逐帧推移形成历史波形 + 帧间平滑（显示值向目标 lerp），静音回落基线。
/// 每 60ms tick 一帧。
class _RealWave extends ConsumerStatefulWidget {
  const _RealWave({required this.color});
  final Color color;

  @override
  ConsumerState<_RealWave> createState() => _RealWaveState();
}

class _RealWaveState extends ConsumerState<_RealWave> {
  static const int bars = 24;
  late final Timer _ticker;
  final List<double> _display = List.filled(bars, 0.12);

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (!mounted) return;
      final cur = ref.read(chatVolumeProvider);
      final target = 0.12 + cur.clamp(0.0, 1.0) * 0.88;
      // 队列左移一格：最右是新样本（显示值向目标 lerp 0.35 平滑），
      // 向左依次是历史波形
      for (var i = 0; i < bars - 1; i++) {
        _display[i] = _display[i + 1];
      }
      _display[bars - 1] = _display[bars - 1] + (target - _display[bars - 1]) * 0.35;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: bars * 5.0,
      height: 40,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < bars; i++)
            Container(
              width: 2.5,
              height: 6 + _display[i] * 34,
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
        ],
      ),
    );
  }
}

/// 底部扇面（微信规格）：
/// · 底层全宽贝塞尔扇面：深灰渐变 rgba(45,45,45,.95)→rgba(30,30,30,.98)，
///   严丝合缝盖住输入区；上缘两条浅色同心弧带做层次（rgba(255,255,255,.08)）；
/// · 中央凸弧浅灰白（发送态）+「松开 发送」黑字，非发送态显示「语音」；
/// · 左右胶囊：默认半透明白灰白字，进入时纯白填充+深字+1.06 放大（120ms）；
/// · 手指白点（空心圈）随意图平滑滑到对应区中央。
class _FanPanel extends StatelessWidget {
  const _FanPanel({
    required this.width,
    required this.cancel,
    required this.toText,
    required this.send,
  });
  final double width;
  final bool cancel;
  final bool toText;
  final bool send;

  static const double zoneH = 230;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: zoneH,
      child: Stack(children: [
        // 底层全宽扇面（深灰渐变贝塞尔弧顶）
        Positioned(
          left: -width * 0.3,
          right: -width * 0.3,
          bottom: 0,
          height: 190,
          child: CustomPaint(
            size: Size(width * 1.6, 190),
            painter: _FanPainter(),
          ),
        ),
        // 左弧「取消」
        Positioned(
          left: 0,
          bottom: 0,
          width: width * 0.46,
          height: 96,
          child: _FanTile(
              label: '取消', active: cancel, width: width * 0.46, arc: true),
        ),
        // 右弧「滑到这里 转文字」
        Positioned(
          right: 0,
          bottom: 0,
          width: width * 0.46,
          height: 96,
          child: _FanTile(
              label: '滑到这里 转文字',
              active: toText,
              width: width * 0.46,
              arc: true),
        ),
        // 中央凸弧浅灰白 + 大弧文字
        Positioned(
          left: -width * 0.3,
          right: -width * 0.3,
          bottom: 0,
          height: 84,
          child: CustomPaint(
            size: Size(width * 1.6, 84),
            painter: _ArcPainter(active: send),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 34,
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
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.92),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF8FA6B8), width: 2.5),
              boxShadow: const [
                BoxShadow(blurRadius: 4, color: Colors.black26)
              ],
            ),
          ),
        ),
      ]),
    );
  }
}

/// 全宽扇面：深灰渐变 + 浅色同心弧带（贝塞尔弧顶，溢出宽度由 Stack 裁剪）。
class _FanPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;
    // 弧形裁剪（与 _ArcPainter 同曲线族：控制点在容器上方）
    final clip = Path()
      ..moveTo(0, h)
      ..quadraticBezierTo(w * 0.5, -60, w, h)
      ..close();
    canvas.save();
    canvas.clipPath(clip);
    // 深灰渐变底
    canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFF2D2D2D).withValues(alpha: 0.95),
              const Color(0xFF1E1E1E).withValues(alpha: 0.98),
            ],
          ).createShader(rect));
    // 两条浅色同心弧带（层次）
    final band = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white.withValues(alpha: 0.08);
    for (final dy in [46.0, 92.0]) {
      final p = Path()
        ..moveTo(0, h - dy)
        ..quadraticBezierTo(w * 0.5, -60 - dy, w, h - dy);
      canvas.drawPath(p, band);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FanPainter old) => false;
}

/// 左/右胶囊：arc 模式为底部贴底半圆拱；active 纯白填充+深字+1.06 放大。
class _FanTile extends StatelessWidget {
  const _FanTile(
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
    return AnimatedScale(
      scale: active ? 1.06 : 1,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active
              ? Colors.white.withValues(alpha: 0.98)
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
                  color: active ? const Color(0xFF222222) : Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

/// 中央凸弧：二次贝塞尔弧顶。发送态浅灰白，其余态弱化半透明。
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
              ? const Color(0xFFE5E5E5).withValues(alpha: 0.97)
              : Colors.white.withValues(alpha: 0.16));
  }

  @override
  bool shouldRepaint(covariant _ArcPainter old) => old.active != active;
}
