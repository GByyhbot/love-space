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

/// 上滑判定阈值（历史保留；现行判定按胶囊行横带 x 比例，见 recordIntentFor）
const double recordSlideThreshold = 64.0;

/// 录音手势中手指的全局坐标（真圆环跟随用；松手/取消时置空）
final recordFingerProvider = StateProvider<Offset?>((_) => null);

/// 胶囊行判定带（微信实测规格）：手指 x < 屏宽 44% 进取消区、> 56% 进
/// 转文字区、中间为发送区；边界 [hysteresis]（18dp）迟滞防闪烁：
/// 已在某区时退出该区需反向越过「区边界 + 迟滞带宽」。
RecordIntent recordIntentFor({
  required double x,
  required double screenWidth,
  RecordIntent? currentIntent,
  double hysteresis = 18.0,
}) {
  final cur = currentIntent ?? RecordIntent.send;
  final cancelEdge = screenWidth * 0.44;
  final textEdge = screenWidth * 0.56;
  switch (cur) {
    case RecordIntent.cancel:
      if (x >= textEdge) return RecordIntent.toText;
      if (x >= cancelEdge + hysteresis) return RecordIntent.send;
      return RecordIntent.cancel;
    case RecordIntent.toText:
      if (x < cancelEdge) return RecordIntent.cancel;
      if (x < textEdge - hysteresis) return RecordIntent.send;
      return RecordIntent.toText;
    case RecordIntent.send:
      if (x < cancelEdge) return RecordIntent.cancel;
      if (x > textEdge) return RecordIntent.toText;
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
///   宽度随实时音量在 44% 屏宽基线~272dp 间弹性呼吸（220ms 弹簧过渡）；
/// · 三态同高同位：默认主题绿；取消态仅变红 #FA5151 并缩到 0.85；
///   转文字态原地展开为提示卡（当前无 ASR 能力，见交付小结缺口报告）；
/// · 扇面深灰渐变 + 浅色同心弧带；胶囊进入时纯白填充+深字+1.06 放大；
/// · 松手收尾 320ms：发送=气泡下沉淡出 / 取消=向取消胶囊方向缩小消失。
/// 纯视觉：`IgnorePointer` 不拦截手势——指针 move/up 由原 GestureDetector 接收。
/// 微信式语音输入全屏遮罩（微信全屏截图实测规格 393×873 逐项落实）：
/// · 气泡中心钉在屏高 58.5%（三态不变），AnimatedAlign 三态水平锚定
///   （默认 x=0 / 取消 x=-0.62 即 19% / 转文字 x=0），320ms easeOutBack 同步弹簧；
/// · 三态尺寸：默认基线 44% 屏宽~272dp 随音量弹性（高 76 圆角 20 尾 10dp）/
///   取消 82dp 红
///   #FA5151 / 转文字 89% 屏宽×104 文字卡（光标 + 右下小波形）；
/// · 底部家具 180dp：浅色穹顶弧（弧顶中央距底 96dp、两端 48dp）+ 两个
///   stadium 胶囊（47% 屏宽×64，中心线距底 127，左 -8° 右 +8°，激活只变色）+
///   浮标（激活胶囊上方 12dp，13sp，跟随倾斜，120ms 淡入）+ 底部标识
///   （中心距底 50dp，15sp）+ 手指圆环（44dp 2dp 白 60% 描边跟随手指）；
/// · 动画：遮罩 150ms 淡入 / 扇面 220ms easeOutBack 上升 / 气泡 320ms
///   easeOutBack 弹入 / 颜色 120ms / 收尾 320ms 两段式；
/// 纯视觉：`IgnorePointer` 不拦截手势——指针 move/up 由原 GestureDetector 接收。
class VoiceRecordOverlay extends ConsumerWidget {
  const VoiceRecordOverlay({super.key, this.topInset = 0});

  /// 状态栏 + AppBar 高度：屏高百分比锚点换算到 body 坐标用
  final double topInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rec = ref.watch(chatRecordProvider);
    if (rec == null) return const SizedBox.shrink();
    final intent = rec.intent;
    final cancel = intent == RecordIntent.cancel;
    final toText = intent == RecordIntent.toText;
    return IgnorePointer(
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth;
        final h = box.maxHeight;
        // 气泡中心 = 屏高 58.5%，换算到 body 坐标（body 顶 = 状态栏+AppBar 下）
        final screenH = MediaQuery.sizeOf(context).height;
        final centerY = (screenH * 0.585 - topInset).clamp(h * 0.2, h * 0.9);
        final alignY = (centerY / h) * 2 - 1;
        // 三态水平锚点：默认居中 / 取消中心 x=19% / 转文字居中
        final alignX = cancel ? 0.19 * 2 - 1 : 0.0;
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
          // 气泡：三态中心锚定（y 恒 58.5% 屏高），位置/尺寸同步弹簧
          Align(
            alignment: Alignment(alignX, alignY),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.8, end: 1),
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutBack,
              builder: (_, appear, child) => Transform.scale(
                scale: appear,
                child: Opacity(opacity: appear.clamp(0, 1), child: child),
              ),
              child: _RecordBubble(
                  width: w,
                  intent: intent,
                  ending: rec.ending,
                  startedAt: rec.startedAt),
            ),
          ),
          // 底部家具（180dp，220ms easeOutBack 上升带轻回弹）
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
          // 手指触点圆环（跟随手指，限定在家具范围）
          _FingerRing(topInset: topInset, bodyHeight: h),
        ]);
      }),
    );
  }
}

/// 录音气泡（实测规格）：
/// · 三态中心由外层 AnimatedAlign 锚定；本组件只管尺寸/颜色/内容：
///   默认宽基线 44% 屏宽~272dp 随音量弹性（widthDpFor 纯函数）、高 76、
///   圆角 20、底部中央 10dp 尾巴；取消宽 82dp（近方形）红 #FA5151；
///   转文字 89% 屏宽×104 文字卡（左对齐文本 + 光标 + 右下小波形）；
/// · 真波形 24 根深色竖条（chatVolumeProvider 实时音量 + 60ms tick 平滑）；
/// · 60s 上限：最后 10 秒气泡内倒计时；
/// · 收尾 320ms：send 下沉淡出 / cancel 向取消胶囊方向缩小淡出。
class _RecordBubble extends ConsumerStatefulWidget {
  const _RecordBubble({
    required this.width,
    required this.intent,
    required this.ending,
    required this.startedAt,
  });
  final double width;
  final RecordIntent intent;
  final RecordEnding? ending;
  final DateTime startedAt;

  /// 宽度随音量弹性曲线（纯函数，可单测）：[volume] 0..1 → dp。
  /// 静音基线 = 44% 屏宽（≈172.9dp@393，落在 128~272 区间内），
  /// 随音量向 [max]（272dp）弹性增长；整体 clamp(128, 272)。
  static double widthDpFor(double volume,
          {required double screenW, double min = 128, double max = 272}) =>
      (screenW * 0.44 + volume.clamp(0, 1) * (max - screenW * 0.44))
          .clamp(min, max);

  @override
  ConsumerState<_RecordBubble> createState() => _RecordBubbleState();
}

class _RecordBubbleState extends ConsumerState<_RecordBubble> {
  static const _cancelColor = Color(0xFFFA5151);
  static const _bubbleColor = Color(0xFF95EC69);
  static const _waveColor = Color(0xFF2E9E52); // 深色波形压亮绿气泡

  @override
  Widget build(BuildContext context) {
    final volume = ref.watch(chatVolumeProvider);
    final cancel = widget.intent == RecordIntent.cancel;
    final toText = widget.intent == RecordIntent.toText;
    final ending = widget.ending;
    final secsLeft = 60 -
        DateTime.now().difference(widget.startedAt).inSeconds.clamp(0, 60);
    final width = toText
        ? widget.width * 0.89
        : cancel
            ? widget.width * 0.21 // 82dp@393
            : _RecordBubble.widthDpFor(volume, screenW: widget.width);
    final height = toText ? 104.0 : 76.0;
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
      child: Stack(clipBehavior: Clip.none, children: [
        // 宽度随音量弹簧过渡（220ms easeOutBack，带轻回弹的隐式弹簧；
        // 时长取定版三档 120/220/320 中的 220 档）
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutBack,
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: cancel ? _cancelColor : _bubbleColor,
            borderRadius: BorderRadius.circular(20),
            boxShadow: const [
              BoxShadow(
                  blurRadius: 22, offset: Offset(0, 8), color: Colors.black38)
            ],
          ),
          child: toText
              // 转文字文字卡：左对齐文本 + 光标 + 右下小波形
              //（无 ASR 能力：文本位显示明确提示，缺口见交付小结）
              ? Stack(children: [
                  Positioned(
                    left: 16,
                    top: 0,
                    bottom: 0,
                    child: Row(children: [
                      Container(
                          width: 2.5,
                          height: 30,
                          decoration: BoxDecoration(
                              color: const Color(0xFF2E9E52),
                              borderRadius: BorderRadius.circular(1.5))),
                      const SizedBox(width: 10),
                      const Text('语音识别暂未开放',
                          style: TextStyle(
                              color: Color(0xFF1E4620),
                              fontSize: 15,
                              fontWeight: FontWeight.w600)),
                    ]),
                  ),
                  Positioned(
                    right: 12,
                    bottom: 8,
                    child: _RealWave(
                        color: _waveColor,
                        bars: 12,
                        barHeight: 16,
                        barWidth: 2.5),
                  ),
                ])
              : Center(
                  child: !cancel && secsLeft <= 10
                      ? Text('还可以说 $secsLeft 秒',
                          style: const TextStyle(
                              color: Color(0xFF1E4620),
                              fontSize: 15,
                              fontWeight: FontWeight.w800))
                      : _RealWave(
                          color: _waveColor,
                          bars: cancel ? 12 : 24,
                          barHeight: cancel ? 24 : 36,
                          barWidth: 2.5)),
        ),
        // 底部中央 10dp 小尾巴（转文字态偏右 68% 跟随手势方向）
        Positioned(
          left: toText ? width * 0.68 - 10 : (width - 20) / 2,
          bottom: -10,
          child: CustomPaint(
            size: const Size(20, 10),
            painter: _TailPainter(
                color: cancel ? _cancelColor : _bubbleColor),
          ),
        ),
      ]),
    );
  }
}

/// 真波形：[bars] 根竖条。高度由录音实时音量（chatVolumeProvider，dBFS 映射）
/// 逐帧推移形成历史波形 + 帧间平滑（新样本向目标 lerp 0.35），静音回落基线。
/// 每 60ms tick 一帧。
class _RealWave extends ConsumerStatefulWidget {
  const _RealWave(
      {required this.color,
      this.bars = 24,
      this.barHeight = 36,
      this.barWidth = 2.5});
  final Color color;
  final int bars;
  final double barHeight;
  final double barWidth;

  @override
  ConsumerState<_RealWave> createState() => _RealWaveState();
}

class _RealWaveState extends ConsumerState<_RealWave> {
  late final Timer _ticker;
  late final List<double> _display;

  @override
  void initState() {
    super.initState();
    _display = List.filled(widget.bars, 0.12);
    _ticker = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (!mounted) return;
      final cur = ref.read(chatVolumeProvider);
      final target = 0.12 + cur.clamp(0.0, 1.0) * 0.88;
      // 队列左移一格：最右是新样本（向目标 lerp 0.35 平滑），向左是历史
      for (var i = 0; i < widget.bars - 1; i++) {
        _display[i] = _display[i + 1];
      }
      _display[widget.bars - 1] =
          _display[widget.bars - 1] + (target - _display[widget.bars - 1]) * 0.35;
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
      width: widget.bars * 5.0,
      height: widget.barHeight,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < widget.bars; i++)
            Container(
              width: widget.barWidth,
              height: 6 + _display[i] * (widget.barHeight - 6),
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

/// 尾巴：向下的对称小三角（10dp，贴气泡底边中央）。
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

/// 底部家具（实测 180dp，三层由下往上）：
/// ① 浅色穹顶弧：实际曲线顶点中央距屏底 96dp、两端点距屏底 48dp
///    （两端不再落屏底，画布内 y=h-48 起、画布外不上溢容器）；
/// ② 两个 stadium 胶囊（宽 47% 屏宽、高 64、中心线距底 127、缝 20dp、
///    左 -8° 右 +8°）：默认深灰（18% 白叠加深色遮罩）浅灰白字 15sp，
///    激活纯白填充+深色字（只变色不放大）；
/// ③ 中央底部标识（中心距底 50dp，15sp）+ 浮标（激活胶囊上方 12dp，
///    13sp，倾斜跟随胶囊，120ms 淡入）。
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

  static const double furnitureH = 180;

  @override
  Widget build(BuildContext context) {
    final capsuleW = (width - 20) / 2; // 缝 20dp，两端贴屏缘
    return SizedBox(
      width: width,
      height: furnitureH,
      child: Stack(children: [
        // ① 穹顶弧（实际曲线顶点距屏底 96dp → 画布内 y=36；两端点距屏底
        //    48dp → 画布内 y=84；容器 132 高，画布无上溢）：
        //    发送态浅色（微信同款浅白穹顶），取消/转文字态变深灰
        //    （微信非发送态底部整体深色，「语音」白字才可读）
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 132,
          child: CustomPaint(
              size: Size(width, 132), painter: _DomePainter(active: send)),
        ),
        // ② 左胶囊「取消」（中心 x≈19%——左端贴屏缘）
        Positioned(
          left: 0,
          bottom: 95,
          width: capsuleW,
          height: 64,
          child: Transform.rotate(
            angle: -8 * 3.14159265 / 180,
            child: _FanTile(
                label: '取消', active: cancel, width: capsuleW, radius: 32),
          ),
        ),
        // ② 右胶囊「滑到这里 转文字」（右端贴屏缘）
        Positioned(
          right: 0,
          bottom: 95,
          width: capsuleW,
          height: 64,
          child: Transform.rotate(
            angle: 8 * 3.14159265 / 180,
            child: _FanTile(
                label: '滑到这里 转文字',
                active: toText,
                width: capsuleW,
                radius: 32),
          ),
        ),
        // 浮标：激活胶囊上方 12dp（中心 x≈19% / 82%），倾斜跟随胶囊
        Positioned(
          left: 0,
          right: 0,
          bottom: 162,
          child: Align(
            alignment: const Alignment(-0.62, 0),
            child: AnimatedOpacity(
              opacity: cancel ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: Transform.rotate(
                angle: -8 * 3.14159265 / 180,
                child: const Text('松手 取消',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 162,
          child: Align(
            alignment: const Alignment(0.64, 0),
            child: AnimatedOpacity(
              opacity: toText ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: Transform.rotate(
                angle: 8 * 3.14159265 / 180,
                child: const Text('松手 编辑文字',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ),
        // ③ 底部标识（文字中心距底 50dp）
        Positioned(
          left: 0,
          right: 0,
          bottom: 42,
          child: Center(
            child: Text(send ? '松开 发送' : '语音',
                style: TextStyle(
                    color: send ? Colors.black : Colors.white70,
                    fontSize: 15,
                    fontWeight: FontWeight.w800)),
          ),
        ),
      ]),
    );
  }
}

/// 穹顶弧：二次贝塞尔（画布坐标两端点 (0,h-48)/(w,h-48)——距屏底 48dp；
/// 实际曲线顶点 = 0.25P0+0.5P1+0.25P2 → 控制点 y=h-144 时顶点 y=h-96，
/// 即顶点距屏底 96dp）。发送态浅灰白（微信浅穹顶）；
/// 非发送态深灰微亮层（保证「语音」白字可读）。
class _DomePainter extends CustomPainter {
  const _DomePainter({required this.active});
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final p = Path()
      ..moveTo(0, h - 48)
      ..quadraticBezierTo(w * 0.5, h - 144, w, h - 48)
      ..close();
    canvas.drawPath(
        p,
        Paint()
          ..color = active
              ? const Color(0xFFE4E4E4).withValues(alpha: 0.96)
              : Colors.white.withValues(alpha: 0.10));
  }

  @override
  bool shouldRepaint(covariant _DomePainter old) => old.active != active;
}

/// 胶囊：stadium 全圆角；默认深灰（18% 白）浅灰白字 15sp；
/// 激活纯白填充+深色字（只变色不放大，120ms 交叉淡化）。
class _FanTile extends StatelessWidget {
  const _FanTile(
      {required this.label, required this.active, required this.width, required this.radius});
  final String label;
  final bool active;
  final double width;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active
            ? Colors.white.withValues(alpha: 0.98)
            : Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(radius),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
              color: active ? const Color(0xFF222222) : const Color(0xFFDDDDDD),
              fontSize: 15,
              fontWeight: FontWeight.w600)),
    );
  }
}

/// 手指触点圆环：44dp、2dp 白色 60% 描边，跟随手指（全局坐标 → body 局部），
/// 限定在家具范围（底部 180dp 区域）内移动。
class _FingerRing extends ConsumerWidget {
  const _FingerRing({required this.topInset, required this.bodyHeight});
  final double topInset;
  final double bodyHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pos = ref.watch(recordFingerProvider);
    if (pos == null) return const SizedBox.shrink();
    var localY = pos.dy - topInset;
    // 扇面范围：底部家具 180dp 区域（含上方 44dp 余量）
    localY = localY.clamp(bodyHeight - 224, bodyHeight - 44);
    return Positioned(
      left: pos.dx - 22,
      top: localY - 22,
      width: 44,
      height: 44,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.6), width: 2),
        ),
      ),
    );
  }
}
