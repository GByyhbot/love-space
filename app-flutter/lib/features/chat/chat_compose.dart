/// 输入区（段二 · Step 6 原生规范）：
/// · Scaffold.resizeToAvoidBottomInset + MediaQuery.viewInsets 读键盘，不移植
///   Web 键盘逻辑（A/B 分流、原生桥、平滑全不要）；
/// · 底部同一槽位互斥切换：键盘 / ⊕面板 / 贴纸坞（InputSlotMachine，见 input_slots.dart）；
///   面板高度按内容估高、夹「无键盘视口」62%；面板先占位、键盘收起后显内容（防闪烁）；
/// · 面板意图：点输入框键盘临时压掉面板，键盘收起后自动回位；亲手收起/选走功能才清意图；
/// · 输入框自动长高（约 4 行封顶内滚）；有文字时语音位换发送钮（对齐 Web syncCompose）；
/// · 语音录制对齐微信/QQ：长按麦克风，松开发送 / 上滑左上取消 / 上滑右上转文字。
/// ⊕面板 16 格与贴纸坞文案逐字对照 Web（chat.js 266–286 / stickerPanel 系列）。
/// [dark]：底栏按视频 78 整体染黑（与系统浅色主题解耦；顶栏与气泡不受影响）。
library;

import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HapticFeedback, PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart' show Amplitude;

import '../../core/api/api_client.dart';
import '../../core/chat/chat_chrome.dart';
import '../../core/chat/chat_media.dart';
import '../../core/chat/keyboard_metrics.dart';
import '../../core/chat/chat_models.dart';
import '../../core/chat/chat_state.dart';
import '../auth/auth_state.dart';
import 'album_picker_sheet.dart';
import 'chat_toast.dart';
import 'input_slots.dart';
import 'media_bubble_widgets.dart';
import 'song_picker_sheet.dart';
import 'sticker_data.dart';
import 'voice_playback.dart';
import 'voice_recorder.dart';

class ChatCompose extends ConsumerStatefulWidget {
  const ChatCompose({
    super.key,
    this.replyNotifier,
    this.onOpenSearch,
    this.onOpenWallpaper,
    this.immersive = false,
    this.dark = false,
  });

  /// 引用态（页级持有：长按菜单「引用」设置，发送/取消后清空）
  final ValueNotifier<(String, String)?>? replyNotifier;

  /// ⊕「搜消息」→ 页面打开页内搜索栏（口径：只筛最近加载的消息）
  final VoidCallback? onOpenSearch;

  /// ⊕「聊天背景」→ 页面打开背景弹层
  final VoidCallback? onOpenWallpaper;

  /// 照片背景沉浸式：输入栏/引用栏走与顶栏同色系的半透明深色层压图上
  final bool immersive;

  /// 底栏按视频 78 染黑（聊天页专属深色外壳）
  final bool dark;

  @override
  ConsumerState<ChatCompose> createState() => _ChatComposeState();
}

class _ChatComposeState extends ConsumerState<ChatCompose>
    with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _slots = InputSlotMachine();
  final VoiceRecorder _recorder = VoiceRecorder();
  bool _hasText = false;

  /// 长按录音起点（全局坐标）；为空表示当前不在录音手势中，
  /// 同时作为 _finishRecording 的幂等守卫。
  Offset? _recordOrigin;
  double _lastInsets = 0;
  double _prevInsets = -1;
  String _stickerTab = 'cute';

  /// 键盘是否正在参与本轮过渡（含 insets 归零的收尾帧）。
  /// 纯布局标志：帧后由 postFrameCallback 静默清除，不 setState，
  /// 避免「为清标志再触发一次布局刷新」。
  bool _keyboardTransition = false;

  /// 本机键盘实测高度（落定后持久化；启动先读持久化值，无则用兜底，
  /// 首次键盘弹出自动纠正——主人定版：不写死、不估算）
  double? _kbHeight;

  /// 读取**未被 Scaffold 消费**的原始窗口底部 insets，换算为逻辑像素。
  ///
  /// 🔴 根因（Flutter 源码 scaffold.dart:2921-2923 实读）：
  /// Scaffold 在 `resizeToAvoidBottomInset=true`（默认）时会给 body 子树
  /// 包一层 `MediaQuery.removeViewInsets(removeBottom: true)`，所以 body 内的
  /// `MediaQuery.of(context).viewInsets.bottom` **恒为 0**。旧实现读它会导致
  /// slotHeight 永远等于完整键盘高度，而 Scaffold 又单独压缩了一次 body，
  /// 键盘高度被计算两遍 → 输入栏被顶到屏幕顶部、工具栏与键盘同时完整显示
  ///（真机录屏 8.00s 实证）；键盘高度也永远测不到，过渡标记永不置位，
  /// 于是每次切换都跑 200ms 展开动画。
  /// `View.of(context)` 取自 widget 树根，不经过 Scaffold 的 MediaQuery 覆盖。
  double _windowKeyboardInsets(BuildContext context) {
    final view = View.of(context);
    return windowBottomInset(view.viewInsets.bottom, view.devicePixelRatio);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _input.addListener(() {
      final has = _input.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
    _focus.addListener(_onFocusChanged);
    widget.replyNotifier?.addListener(_onReplyChanged);
    Future.microtask(() async {
      final stored = await ref.read(keyboardMetricsStoreProvider).load();
      if (stored != null && mounted) setState(() => _kbHeight = stored);
    });
  }

  void _onReplyChanged() {
    if (mounted) setState(() {});
  }

  /// 面板意图：点输入框（获得焦点）→ 键盘临时压掉面板
  void _onFocusChanged() {
    if (_focus.hasFocus && _slots.slot != InputSlot.none) {
      setState(() => _slots.handle(InputSlotEvent.keyboardFocus));
    }
  }

  /// 窗口指标变化（键盘展开/收起的每一帧）由 WidgetsBinding 通知。
  /// 不能再用 didChangeDependencies：Scaffold 给 body 的 MediaQuery 已把
  /// viewInsets.bottom 清零，键盘变化未必会触发它。
  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!mounted) return;
    _syncKeyboardInsets(_windowKeyboardInsets(context));
  }

  /// 键盘 insets 状态同步（幂等：同一高度不重复 setState、不重复布局刷新）。
  void _syncKeyboardInsets(double insets) {
    if (insets == _lastInsets) return;
    // 过渡标记：insets>0 的每帧都算过渡；归零收尾帧仍算过渡
    //（这一帧 slotHeight 还要从 kbHeight-lastInsets 补到 kbHeight，
    //  若此刻切回 200ms 就会补做一次展开动画），帧后静默清除。
    if (insets > 0) {
      _keyboardTransition = true;
    } else if (_lastInsets > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _keyboardTransition = false;
      });
    }
    // 键盘收起（insets 归零）→ 意图面板自动回位。
    // 回位前后 slotOccupied / visibleSlot 都不变，故本次状态迁移不引起
    // 任何高度变化或动画（面板只是从 intent 移交回 slot）。
    if (_lastInsets > 0 && insets == 0) {
      if (_slots.intent != null) _slots.handle(InputSlotEvent.keyboardClosed);
    }
    // 键盘高度实测（复验 item 2）：连续两帧稳定且超门槛 → 记录并持久化
    if (insetsStable(_prevInsets, insets) &&
        ((_kbHeight ?? 0) - insets).abs() > 1) {
      _kbHeight = insets;
      // ignore: unawaited_futures
      ref.read(keyboardMetricsStoreProvider).save(insets);
    }
    _prevInsets = insets;
    _lastInsets = insets;
    if (mounted) setState(() {});
  }

  /// 当前生效的键盘高度：本机实测（本次会话已弹过键盘）→ 持久化值 → 兜底。
  /// 面板/贴纸坞槽位一律等于该值（高度恒定推导见 keyboard_metrics.dart）
  double get _effectiveKeyboardHeight => _kbHeight ?? fallbackKeyboardHeight;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.replyNotifier?.removeListener(_onReplyChanged);
    _ampSub?.cancel();
    _maxTimer?.cancel();
    _input.dispose();
    _focus.dispose();
    _recorder.dispose();
    super.dispose();
  }

  /// 统一走聊天页顶部提示层：底部 SnackBar 会盖住输入栏与麦克风按钮，
  /// 录音时「再点一次结束」根本点不到（真机录屏 11.00s 实证）。
  void _snack(String msg, {ChatToastTone tone = ChatToastTone.info}) {
    if (!mounted) return;
    ref.read(chatToastProvider.notifier).show(msg, tone: tone);
  }

  // ── 槽位切换 ───────────────────────────────────────────────────────

  void _toggleFn() {
    setState(() => _slots.handle(InputSlotEvent.toggleFn));
    if (_slots.slot != InputSlot.none) _focus.unfocus(); // 先记意图再收键盘
  }

  void _toggleSticker() {
    setState(() => _slots.handle(InputSlotEvent.toggleSticker));
    if (_slots.slot != InputSlot.none) _focus.unfocus();
  }

  /// 选走功能：面板收起 + 意图清空
  void _pickFunction() {
    setState(() => _slots.handle(InputSlotEvent.pickFunction));
  }

  // ── 发送入口 ───────────────────────────────────────────────────────

  Future<void> _sendText() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final reply = widget.replyNotifier?.value;
    widget.replyNotifier?.value = null;
    try {
      if (reply != null) {
        // 引用发送：body.reply_to={id, text 截 60 字}（quoteSnippet 在控制器内截断）
        await ref
            .read(chatControllerProvider.notifier)
            .sendTextReply(text, reply.$1, reply.$2);
      } else {
        await ref.read(chatControllerProvider.notifier).send(text);
      }
    } catch (e) {
      _snack(errorDetail(e));
    }
  }

  /// 定位发位置（对齐 Web chatLocate：权限中文指引 + 1e-5 精度 + 超时/拒签文案）
  Future<void> _locateAndSend() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      _snack('位置权限没给：到「设置 → 应用 → 恋爱空间 → 权限」里打开「位置」，再试一次');
      if (perm == LocationPermission.deniedForever) {
        await Geolocator.openAppSettings();
      }
      return;
    }
    _snack('正在获取位置…');
    try {
      final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 8)));
      // 精度 1e-5 取整（对齐 Web Math.round(x*1e5)/1e5）
      final lat = (pos.latitude * 1e5).round() / 1e5;
      final lng = (pos.longitude * 1e5).round() / 1e5;
      await ref.read(chatControllerProvider.notifier).sendLocation(lat, lng);
      _snack('位置已发送');
    } catch (_) {
      _snack('暂时定不到位置——室内、地下室或没开 GPS 都会这样，换个地方再试');
    }
  }

  /// 本地预检后发送本机文件（白名单 + 250MB；非法文件剔除并提示，不发请求）。
  /// 🔴 数量上限也在本地预检拦截：超 30 个一个请求都不发——否则全量上传
  /// 必撞服务端 30 次/300s 限流（QA 回归根因）。
  Future<void> _sendFiles(List<ChatLocalFile> files, {String caption = ''}) async {
    final ok = <ChatLocalFile>[];
    for (final f in files) {
      final file = File(f.path);
      if (!await file.exists()) continue;
      final err = validateUploadFile(f.name, await file.length());
      if (err != null) {
        _snack('${f.name}：$err');
        continue;
      }
      ok.add(f);
    }
    if (ok.isEmpty) return;
    if (ok.length > maxMediaPerRecord) {
      _snack('一条消息最多 $maxMediaPerRecord 个附件，先删几张再发');
      return;
    }
    try {
      await ref.read(chatControllerProvider.notifier).sendMedia(ok, caption: caption);
    } catch (e) {
      _snack(e is MediaValidationError ? e.message : errorDetail(e));
    }
  }

  Future<void> _pickFromGallery() async {
    final picked = await ImagePicker().pickMultiImage();
    if (picked.isEmpty) return;
    await _sendFiles(
        picked.map((x) => ChatLocalFile(path: x.path, name: x.name)).toList());
  }

  Future<void> _pickVideo() async {
    final x = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (x == null) return;
    await _sendFiles([ChatLocalFile(path: x.path, name: x.name)]);
  }

  Future<void> _pickCamera() async {
    final x = await ImagePicker().pickImage(
        source: ImageSource.camera, maxWidth: 2048, imageQuality: 90);
    if (x == null) return;
    await _sendFiles([ChatLocalFile(path: x.path, name: x.name)]);
  }

  // ── 长按录音（微信规格重做：真波形 / 迟滞判定 / 震动 / 60s 与 1s 通则）──

  /// 音量流订阅（真波形数据源）与 60s 上限定时器
  StreamSubscription<Amplitude>? _ampSub;
  Timer? _maxTimer;
  RecordIntent? _lastIntent;

  /// dBFS（约 -160..0）→ 归一化 0..1：-45dB 起听、-8dB 视为满格
  static double _dbToVolume(double db) =>
      ((db + 45) / 37).clamp(0.0, 1.0);

  void _startVolumeStream() {
    voiceDbg('compose _startVolumeStream enter');
    _ampSub?.cancel();
    _ampSub = _recorder
        .amplitudeStream(const Duration(milliseconds: 80))
        .listen((amp) {
      ref.read(chatVolumeProvider.notifier).state = _dbToVolume(amp.current);
    });
    voiceDbg('compose _startVolumeStream exit');
  }

  void _stopVolumeStream() {
    voiceDbg('compose _stopVolumeStream enter');
    _ampSub?.cancel();
    _ampSub = null;
    _maxTimer?.cancel();
    _maxTimer = null;
    _lastIntent = null;
    ref.read(chatVolumeProvider.notifier).state = 0;
    voiceDbg('compose _stopVolumeStream exit');
  }

  Future<void> _startRecording(Offset globalOrigin) async {
    voiceDbg('compose _startRecording enter');
    try {
      final ok = await _recorder.hasPermission();
      voiceDbg('compose _startRecording hasPermission', 'ok=$ok');
      if (!ok) {
        _snack('需要麦克风权限，请到系统设置开启后重试',
            tone: ChatToastTone.error);
        return;
      }
      await _recorder.start();
      // 开始录音前停掉在播语音（全局播放互斥：录音与试听不同时进行）
      // ignore: unawaited_futures
      ref.read(voicePlaybackProvider.notifier).stop();
      voiceDbg('compose _startRecording recorder-start-ok');
      _recordOrigin = globalOrigin;
      _lastIntent = RecordIntent.send;
      ref.read(recordFingerProvider.notifier).state = globalOrigin;
      ref.read(chatRecordProvider.notifier).start();
      _startVolumeStream();
      // 60s 上限：到时自动按发送收尾（微信同款）
      _maxTimer = Timer(const Duration(seconds: 60), () {
        if (mounted && _recordOrigin != null) _finishRecording();
      });
    } catch (e, s) {
      // [voice-dbg] 取证：真异常不再吞掉，全量落 logcat（只加日志不动控制流）
      voiceDbg('compose _startRecording catch',
          'type=${e.runtimeType} e=${e.toString()}');
      if (e is PlatformException) {
        voiceDbg('compose _startRecording platformException',
            'code=${e.code} message=${e.message} details=${e.details}');
      }
      // 栈截前 20 行（拼单行，防 logcat 按行截断/折叠）
      voiceDbg('compose _startRecording stack',
          'stack=${s.toString().split('\n').take(20).join(' | ')}');
      _recordOrigin = null;
      _stopVolumeStream();
      ref.read(chatRecordProvider.notifier).stop();
      // start 失败后录音器可能处于半初始化态，重建拿干净实例，避免影响下一次
      await _recorder.recycle();
      _snack('录音失败', tone: ChatToastTone.error);
    }
  }

  void _onRecordMove(Offset globalPosition) {
    if (_recordOrigin == null) return;
    // 手指圆环跟随（全局坐标，遮罩内换算）
    ref.read(recordFingerProvider.notifier).state = globalPosition;
    // 判定带：胶囊行横带 x 比例（44%/56%）+ 18dp 迟滞防闪烁
    final next = recordIntentFor(
        x: globalPosition.dx,
        screenWidth: MediaQuery.sizeOf(context).width,
        currentIntent: _lastIntent);
    if (next == _lastIntent) return;
    // 震动反馈：每次进出区域轻震，进入取消区加重
    HapticFeedback.selectionClick();
    if (next == RecordIntent.cancel) HapticFeedback.heavyImpact();
    _lastIntent = next;
    ref.read(chatRecordProvider.notifier).intent(next);
  }

  /// 松手收尾（幂等：手势取消与正常结束都可能回调，靠 _recordOrigin 去重）。
  /// 收尾分两段：先通知 overlay 播 320ms 收尾动画（stop(ending)），
  /// 再落盘/清理录音文件——动画与文件处理并行，互不阻塞。
  Future<void> _finishRecording() async {
    final origin = _recordOrigin;
    _recordOrigin = null;
    final state = ref.read(chatRecordProvider);
    voiceDbg('compose _finishRecording enter',
        'hasOrigin=${origin != null} hasState=${state != null}');
    if (origin == null || state == null) return;
    ref.read(recordFingerProvider.notifier).state = null;
    final intent = state.intent;
    final elapsed = DateTime.now().difference(state.startedAt);
    voiceDbg('compose _finishRecording intent',
        'intent=$intent elapsedMs=${elapsed.inMilliseconds}');
    _stopVolumeStream();
    switch (intent) {
      case RecordIntent.cancel:
        voiceDbg('compose _finish cancel pre stop(ending)');
        ref.read(chatRecordProvider.notifier).stop(ending: RecordEnding.cancel);
        voiceDbg('compose _finish cancel pre recorder.cancel');
        await _recorder.cancel();
        voiceDbg('compose _finish cancel pre recorder.recycle');
        await _recorder.recycle();
        voiceDbg('compose _finish cancel done');
        _snack('已取消录音');
      case RecordIntent.toText:
        // 🔴 后端零改动红线下无 ASR 接口（服务端与 Web 端都没有语音识别），
        // 不做假交互：按取消收尾并明确告知（遮罩气泡内也已即时提示）。
        voiceDbg('compose _finish toText pre stop(ending)');
        ref.read(chatRecordProvider.notifier).stop(ending: RecordEnding.cancel);
        voiceDbg('compose _finish toText pre recorder.cancel');
        await _recorder.cancel();
        voiceDbg('compose _finish toText pre recorder.recycle');
        await _recorder.recycle();
        voiceDbg('compose _finish toText done');
        _snack('语音识别暂未开放，本次录音未发送', tone: ChatToastTone.warning);
      case RecordIntent.send:
        // 通则：短于 1 秒提示「说话时间太短」不发送
        if (elapsed < const Duration(seconds: 1)) {
          voiceDbg('compose _finish send too-short pre stop(ending)');
          ref
              .read(chatRecordProvider.notifier)
              .stop(ending: RecordEnding.cancel);
          voiceDbg('compose _finish send too-short pre recorder.cancel');
          await _recorder.cancel();
          voiceDbg('compose _finish send too-short pre recorder.recycle');
          await _recorder.recycle();
          voiceDbg('compose _finish send too-short done');
          _snack('说话时间太短', tone: ChatToastTone.warning);
          return;
        }
        voiceDbg('compose _finish send pre stop(ending)');
        ref.read(chatRecordProvider.notifier).stop(ending: RecordEnding.send);
        voiceDbg('compose _finish send pre recorder.stop');
        final f = await _recorder.stop();
        voiceDbg('compose _finish send recorder.stop',
            'result=${f == null ? 'null' : f.path}');
        voiceDbg('compose _finish send pre recorder.recycle');
        await _recorder.recycle();
        if (f == null) {
          voiceDbg('compose _finish send stop-returned-null');
          _snack('没有录到声音', tone: ChatToastTone.warning);
          return;
        }
        voiceDbg('compose _finish send pre _sendFiles');
        await _sendFiles([f]);
        voiceDbg('compose _finish send _sendFiles done');
    }
  }

  /// 上传自定义表情到媒体库并加入「我的」（对齐 Web myStickers 语义）
  Future<void> _addMySticker() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x == null) return;
    try {
      final bytes = await x.readAsBytes();
      final dio = await ref.read(dioProvider.future);
      final mid = await uploadChatMedia(dio, x.name, bytes);
      final me = ref.read(authProvider.notifier).me;
      await ref
          .read(myStickersProvider.notifier)
          .add(me?.user.id ?? '', mid, x.name);
    } catch (e) {
      _snack(errorDetail(e));
    }
  }

  /// 点 emoji 只插入文本不弹键盘（对齐 Web insertStickerText）。
  /// 光标偏移按码元差计算：replaceRange 在码元层面操作，❤️/☀️/🌧️ 等多码元
  /// 单字素 emoji 若按字素数算 offset 会落进代理对中间、后续输入错位。
  void _insertEmoji(String em) {
    final value = _input.value;
    final sel = _input.selection;
    final valid = sel.isValid && sel.baseOffset >= 0;
    final start = valid ? sel.start : value.text.length;
    final end = valid && sel.extentOffset >= sel.start ? sel.end : start;
    final newText = value.text.replaceRange(start, end, em);
    _input.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
          offset: start + (newText.length - value.text.length)),
    );
  }

  // ── ⊕面板动作（对齐 Web fnPanel 16 格）────────────────────────────

  void _onFnAction(String id) {
    switch (id) {
      case 'media': // 相册 = 服务器媒体库选择器（对齐 Web chatAlbumPick）
        _pickFunction();
        showAlbumPicker(
          context,
          onSend: (mids, caption) async {
            try {
              await ref
                  .read(chatControllerProvider.notifier)
                  .sendMediaIds(mids, caption: caption);
            } catch (e) {
              _snack(errorDetail(e));
            }
          },
          onUpload: () => _showUploadChooser(),
        );
      case 'camera': // 拍摄（对齐 Web chat-shot：拍照）
        _pickFunction();
        _pickCamera();
      case 'voice': // 语音改为长按手势，面板入口只做引导
        _pickFunction();
        _snack('长按输入框旁的麦克风录音，松开发送；上滑可取消或转文字');
      case 'sticker-panel': // 表情 → 切到贴纸坞（同槽位互换）
        _toggleSticker();
      case 'chat-locate': // 位置（段三：定位+发送）
        _pickFunction();
        _locateAndSend();
      case 'chat-song': // 音乐（段三：在线搜歌；「从歌单选」不出现，歌单属条目 6）
        _pickFunction();
        showSongPicker(context);
      case 'chat-search': // 搜消息（段三：页内筛选已加载窗口）
        _pickFunction();
        widget.onOpenSearch?.call();
      case 'chat-bg': // 聊天背景（段三：背景弹层）
        _pickFunction();
        widget.onOpenWallpaper?.call();
      case 'tool-calendar':
      case 'tool-quest':
      case 'tool-wish':
      case 'tool-ledger':
        _snack('条目 6 迁移后开放');
      case 'tool-period':
        _snack('条目 8 迁移后开放');
      case 'dashboard':
      case 'weekly':
        _snack('条目 9 迁移后开放');
      case 'figure':
        _snack('情侣摆拍为 Web 专属页，不在 App 迁移范围');
    }
  }

  /// 相册「上传」：本机选择器（Web 是 file input 收图+视频；Flutter 分两路多选图/选视频）
  Future<void> _showUploadChooser() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('上传'),
        children: [
          SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'image'),
              child: const Text('图片（可多选）')),
          SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'video'),
              child: const Text('视频')),
        ],
      ),
    );
    if (choice == 'image') await _pickFromGallery();
    if (choice == 'video') await _pickVideo();
  }

  // ── UI ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 外壳前景是否走浅色：深色底（dark 或 immersive 压黑）一律白字白图标。
    final onDark = chromeIsDark(widget.dark, widget.immersive);
    // 必须读窗口原始 insets：Scaffold 已把 body 子树的 viewInsets.bottom 清零
    //（见 _windowKeyboardInsets 注释），用 MediaQuery 会让键盘高度被算两遍。
    final insets = _windowKeyboardInsets(context);
    // 布局口径用 slotOccupied，不用 slot：面板被键盘临时压住期间槽位仍占位，
    // slotHeight + insets ≡ kbHeight 在整段互切过渡里恒成立，输入栏位置与
    // 尺寸逐帧不变，位移只由系统键盘提供。
    final slotOccupied = _slots.slotOccupied;
    final visibleSlot = _slots.visibleSlot;
    // 槽位高度=键盘实测高度（等高推导，见 keyboard_metrics.dart）：
    // · 面板/坞占位：slotHeight = (kbHeight - insets).clamp(0, kbHeight)
    //   → 键盘↔面板两两切换时输入栏位置逐帧不动（总高度恒定）；
    // · 从零展开（insets==0 且无键盘参与）→ 槽位 0 → kbHeight 走抬升动画。
    final kbHeight = _effectiveKeyboardHeight;
    final slotHeight = slotHeightFor(
        slotOpen: slotOccupied, insets: insets, kbHeight: kbHeight);
    // 键盘参与的整段过渡（含 insets 归零收尾帧）零动画，杜绝末尾补一段展开；
    // 只有无键盘参与的从零展开 / 亲手收起才保留 200ms 电梯动效。
    final animDuration = slotAnimationDuration(
        slotOccupied: slotOccupied, keyboardActive: _keyboardTransition);
    final reply = widget.replyNotifier?.value;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      // 引用底栏（对齐 Web replyBar：「引用：xxx」+ 取消）
      if (reply != null)
        Container(
          width: double.infinity,
          color: chatChromeColor(theme,
              immersive: widget.immersive, dark: widget.dark),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            Icon(Icons.reply_rounded,
                size: 16, color: onDark ? Colors.white70 : theme.colorScheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text('引用：${quoteSnippet(reply.$2)}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: onDark ? Colors.white70 : null)),
            ),
            GestureDetector(
              onTap: () => widget.replyNotifier?.value = null,
              child: Text('取消',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.primary)),
            ),
          ]),
        ),
      // 输入栏：悬浮胶囊（用户定版：不贴屏幕底边，四周留边、整体大圆角）。
      // SafeArea 包在胶囊外——胶囊整体浮在系统导航条上方。
      // 深色外壳与面板同源取色；胶囊态不再要顶部分隔线。
      SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          decoration: BoxDecoration(
            color: chatChromeColor(theme,
                immersive: widget.immersive, dark: widget.dark),
            borderRadius: BorderRadius.circular(26),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _focus,
                minLines: 1,
                maxLines: 4, // 约 4 行封顶内部滚动（对齐 Web autoGrow）
                maxLength: 20000,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendText(),
                style: TextStyle(color: onDark ? Colors.white : null),
                cursorColor: onDark ? Colors.white70 : null,
                decoration: InputDecoration(
                  hintText: '发消息或按住说话…',
                  hintStyle:
                      TextStyle(color: onDark ? Colors.white60 : null),
                  isDense: true,
                  filled: true,
                  fillColor: onDark
                      ? Colors.white.withValues(alpha: 0.14)
                      : null,
                  counterText: '',
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 有文字时语音位换发送钮（对齐 Web form.has-text）。
            // 无文字时长按麦克风录音：松开发送 / 滑到左上取消 / 滑到右上转文字。
            // 不再有「再点一次结束」，底部提示也不会挡住这个按钮。
            if (!_hasText)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPressStart: (d) {
                  voiceDbg('compose gesture longPressStart',
                      'x=${d.globalPosition.dx} y=${d.globalPosition.dy}');
                  _startRecording(d.globalPosition);
                },
                onLongPressMoveUpdate: (d) => _onRecordMove(d.globalPosition),
                onLongPressEnd: (_) {
                  voiceDbg('compose gesture longPressEnd');
                  _finishRecording();
                },
                onLongPressCancel: () {
                  voiceDbg('compose gesture longPressCancel');
                  _finishRecording();
                },
                onTap: () => _snack('长按录音，松开发送；滑到左上取消、右上转文字'),
                child: Semantics(
                  button: true,
                  label: '长按录音',
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(Icons.mic_rounded,
                        color: onDark ? Colors.white : null),
                  ),
                ),
              )
            else
              IconButton.filled(
                tooltip: '发送',
                onPressed: _sendText,
                icon: const Icon(Icons.send_rounded, size: 20),
              ),
            IconButton(
              tooltip: '表情',
              onPressed: _toggleSticker,
              color: onDark ? Colors.white : null,
              icon: const Icon(Icons.emoji_emotions_rounded),
            ),
            IconButton(
              tooltip: '更多',
              onPressed: _toggleFn,
              color: onDark ? Colors.white : null,
              icon: Icon(_slots.slot == InputSlot.fn
                  ? Icons.close_rounded
                  : Icons.add_circle_outline_rounded),
            ),
          ]),
        ),
      ),
      // 底部槽位（键盘/⊕/坞互斥共用）：等高槽位——面板内容钉顶部、被槽位
      // 裁剪露出（内容超高内部滚动）；键盘过渡期零动画逐帧追踪等高公式
      AnimatedContainer(
        duration: animDuration,
        curve: Curves.easeOutCubic,
        height: slotHeight,
        clipBehavior: Clip.hardEdge,
        decoration: const BoxDecoration(),
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minHeight: 0,
          maxHeight: kbHeight,
          // 宽度沿用父约束（槽位宽度）：这里若给 maxWidth 无界，面板内容
          // 布局直接失败 → 槽位空白（段三真机缺陷 2 根因）
          child: visibleSlot == InputSlot.fn
              ? _FnPanel(
                  height: kbHeight,
                  immersive: widget.immersive,
                  dark: widget.dark,
                  onAction: _onFnAction)
              : visibleSlot == InputSlot.sticker
                  ? _StickerDock(
                      height: kbHeight,
                      immersive: widget.immersive,
                      dark: widget.dark,
                      tab: _stickerTab,
                      onTab: (t) => setState(() => _stickerTab = t),
                      onEmoji: _insertEmoji,
                      onPickFunction: _pickFunction,
                      onAddSticker: _addMySticker,
                    )
                  : const SizedBox(),
        ),
      ),
    ]);
  }
}

// ── ⊕功能面板（16 格对齐 Web fnPanel）────────────────────────────────

class _FnPanel extends StatelessWidget {
  const _FnPanel(
      {required this.height,
      required this.immersive,
      required this.dark,
      required this.onAction});
  final double height;
  final bool immersive;
  final bool dark;
  final void Function(String id) onAction;

  static const List<(String, IconData, String)> tiles = [
    ('media', Icons.photo_rounded, '相册'),
    ('camera', Icons.photo_camera_rounded, '拍摄'),
    ('voice', Icons.mic_rounded, '语音'),
    ('sticker-panel', Icons.emoji_emotions_rounded, '表情'),
    ('chat-locate', Icons.location_on_rounded, '位置'),
    ('chat-song', Icons.music_note_rounded, '音乐'),
    ('chat-search', Icons.search_rounded, '搜消息'),
    ('chat-bg', Icons.wallpaper_rounded, '聊天背景'),
    ('tool-calendar', Icons.calendar_month_rounded, '共同年历'),
    ('tool-quest', Icons.checklist_rounded, '恋爱清单'),
    ('tool-wish', Icons.star_rounded, '共同愿望'),
    ('tool-ledger', Icons.menu_book_rounded, '共同账本'),
    ('tool-period', Icons.favorite_rounded, '生理期'),
    ('dashboard', Icons.grid_view_rounded, '数据看板'),
    ('weekly', Icons.schedule_rounded, '回忆周报'),
    ('figure', Icons.movie_rounded, '情侣摆拍'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onDark = chromeIsDark(dark, immersive);
    // 悬浮胶囊（用户定版：与输入框同宽同圆角，浮在底部；与输入栏同 margin）。
    // 固定 4×4 布局：Column+Row 均分，不用 GridView——网格天然可滚动，
    // 真机上内容不满一屏也能拖动（用户反馈的「上下滑动一点点」根因）。
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: chatChromeColor(theme, immersive: immersive, dark: dark),
            borderRadius: BorderRadius.circular(26),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Column(children: [
            for (var row = 0; row < 4; row++)
              Expanded(
                child: Row(children: [
                  for (var col = 0; col < 4; col++)
                    Expanded(
                      child: _FnCell(
                        tile: tiles[row * 4 + col],
                        onDark: onDark,
                        onTap: () => onAction(tiles[row * 4 + col].$1),
                      ),
                    ),
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}

/// ⊕面板单格（固定布局用；图标+文字居中）。
class _FnCell extends StatelessWidget {
  const _FnCell(
      {required this.tile, required this.onDark, required this.onTap});
  final (String, IconData, String) tile;
  final bool onDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(tile.$2,
                size: 24, color: onDark ? Colors.white : theme.colorScheme.primary),
            const SizedBox(height: 5),
            Text(tile.$3,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: onDark ? Colors.white70 : null)),
          ]),
    );
  }
}

// ── 贴纸坞（emoji 两组 + 3 内置包 + 我的）────────────────────────────

class _StickerDock extends ConsumerWidget {
  const _StickerDock({
    required this.height,
    required this.immersive,
    required this.dark,
    required this.tab,
    required this.onTab,
    required this.onEmoji,
    required this.onPickFunction,
    required this.onAddSticker,
  });
  final double height;
  final bool immersive;
  final bool dark;
  final String tab;
  final void Function(String tab) onTab;
  final void Function(String emoji) onEmoji;
  final VoidCallback onPickFunction;
  final VoidCallback onAddSticker;

  StickerPack? _packOf(String tab) {
    for (final p in stickerPacks) {
      if (p.id == tab) return p;
    }
    return null;
  }

  String _noteFor(String tab) {
    if (tab == 'spicy') return '这些只属于你们两个人的小秘密 🔒';
    if (tab == 'mine') return '只存于本机列表 · 图片保存在你们的空间里';
    if (_packOf(tab) != null) return '点一下，直接发给 TA';
    return '点一下，就能打进输入框';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final onDark = chromeIsDark(dark, immersive);
    return Container(
      height: height,
      color: chatChromeColor(theme, immersive: immersive, dark: dark),
      child: Column(children: [
        // tabs（对齐 Web renderStickerTabs 顺序与文案）
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final (id, label) in stickerTabs)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: TextButton(
                    onPressed: () => onTab(id),
                    style: TextButton.styleFrom(
                      foregroundColor: tab == id
                          ? (onDark ? Colors.white : theme.colorScheme.primary)
                          : (onDark
                              ? Colors.white60
                              : theme.colorScheme.outline),
                      textStyle: theme.textTheme.labelLarge,
                    ),
                    child: Text(label),
                  ),
                ),
            ],
          ),
        ),
        Divider(
            height: 1,
            color: onDark
                ? Colors.white24
                : theme.colorScheme.outlineVariant),
        Expanded(child: _body(context, ref)),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(_noteFor(tab),
              style:
                  theme.textTheme.bodySmall
                      ?.copyWith(color: onDark ? Colors.white60 : theme.colorScheme.outline)),
        ),
      ]),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref) {
    final pack = _packOf(tab);
    if (tab == 'mine') return _mineGrid(context, ref);
    if (pack != null) return _packGrid(context, ref, pack);
    return _emojiGrid(tab == 'spicy' ? spicyEmoji : cuteEmoji);
  }

  Widget _emojiGrid(List<String> list) {
    return GridView.count(
      crossAxisCount: 8,
      padding: const EdgeInsets.all(8),
      children: [
        for (final em in list)
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => onEmoji(em),
            child: Center(
                child: Text(em,
                    style: const TextStyle(fontSize: 26))),
          ),
      ],
    );
  }

  Widget _packGrid(BuildContext context, WidgetRef ref, StickerPack pack) {
    final base = ref.watch(chatBaseProvider).valueOrNull;
    if (base == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 5),
      padding: const EdgeInsets.all(8),
      itemCount: pack.count,
      itemBuilder: (context, i) {
        final path = '/static/stickers/${pack.dir}/$i.${pack.ext}';
        final url = '$base$path';
        return InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            onPickFunction(); // 发送即收起贴纸坞（对齐 Web dock.hidden=true）
            ref
                .read(chatControllerProvider.notifier)
                .sendSticker(path);
          },
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: pack.ext == 'webm'
                ? StickerVideoView(url: url)
                : CachedNetworkImage(
                    imageUrl: url,
                    fit: BoxFit.contain,
                    placeholder: (_, _) => const SizedBox(),
                    errorWidget: (_, _, _) => const SizedBox(),
                  ),
          ),
        );
      },
    );
  }

  Widget _mineGrid(BuildContext context, WidgetRef ref) {
    final stickers = ref.watch(myStickersProvider);
    final base = ref.watch(chatBaseProvider).valueOrNull;
    final me = ref.watch(authProvider.notifier).me;
    if (stickers.isEmpty) {
      // 空态逐字对齐 Web stickerTabHTML('mine')
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text('还没有专属表情包\n点下面收第一张，一点就能发给 TA',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.outline)),
          const SizedBox(height: 12),
          FilledButton.tonal(
              onPressed: onAddSticker, child: const Text('＋ 添加表情包')),
        ]),
      );
    }
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4),
      padding: const EdgeInsets.all(8),
      itemCount: stickers.length + 1,
      itemBuilder: (context, i) {
        // 末尾固定「＋ 添加表情包」格（对齐 Web sticker-add）
        if (i == stickers.length) {
          return InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onAddSticker,
            child: Center(
                child: Text('＋ 添加表情包',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelMedium)),
          );
        }
        final s = stickers[i];
        final url = base == null ? '' : mediaUrl(base, s.mid);
        return Stack(children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              onPickFunction();
              ref
                  .read(chatControllerProvider.notifier)
                  .sendCustomSticker(s.mid);
            },
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: url.isEmpty
                  ? const SizedBox()
                  : CachedNetworkImage(
                      imageUrl: url,
                      httpHeaders: ref
                          .watch(mediaCookieHeadersProvider)
                          .valueOrNull,
                      fit: BoxFit.contain,
                      placeholder: (_, _) => const SizedBox(),
                      errorWidget: (_, _, _) => const SizedBox(),
                    ),
            ),
          ),
          // 删除角标（对齐 Web sticker-del）
          Positioned(
            right: 0, top: 0,
            child: InkWell(
              onTap: () => ref
                  .read(myStickersProvider.notifier)
                  .remove(me?.user.id ?? '', s.mid),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.error,
                    shape: BoxShape.circle),
                child: const Icon(Icons.close, size: 11, color: Colors.white),
              ),
            ),
          ),
        ]);
      },
    );
  }
}
