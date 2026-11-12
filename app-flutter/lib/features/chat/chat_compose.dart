/// 输入区（段二 · Step 6 原生规范）：
/// · Scaffold.resizeToAvoidBottomInset + MediaQuery.viewInsets 读键盘，不移植
///   Web 键盘逻辑（A/B 分流、原生桥、平滑全不要）；
/// · 底部同一槽位互斥切换：键盘 / ⊕面板 / 贴纸坞（InputSlotMachine，见 input_slots.dart）；
///   面板高度按内容估高、夹「无键盘视口」62%；面板先占位、键盘收起后显内容（防闪烁）；
/// · 面板意图：点输入框键盘临时压掉面板，键盘收起后自动回位；亲手收起/选走功能才清意图；
/// · 输入框自动长高（约 4 行封顶内滚）；有文字时语音位换发送钮（对齐 Web syncCompose）；
/// · 语音录制对齐 Web chatVoiceToggle：点一下开始，再点一次结束并发送。
/// ⊕面板 16 格与贴纸坞文案逐字对照 Web（chat.js 266–286 / stickerPanel 系列）。
library;

import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/api_client.dart';
import '../../core/chat/chat_chrome.dart';
import '../../core/chat/chat_media.dart';
import '../../core/chat/keyboard_metrics.dart';
import '../../core/chat/chat_models.dart';
import '../../core/chat/chat_state.dart';
import '../auth/auth_state.dart';
import 'album_picker_sheet.dart';
import 'input_slots.dart';
import 'media_bubble_widgets.dart';
import 'song_picker_sheet.dart';
import 'sticker_data.dart';
import 'voice_recorder.dart';

class ChatCompose extends ConsumerStatefulWidget {
  const ChatCompose({
    super.key,
    this.replyNotifier,
    this.onOpenSearch,
    this.onOpenWallpaper,
    this.immersive = false,
  });

  /// 引用态（页级持有：长按菜单「引用」设置，发送/取消后清空）
  final ValueNotifier<(String, String)?>? replyNotifier;

  /// ⊕「搜消息」→ 页面打开页内搜索栏（口径：只筛最近加载的消息）
  final VoidCallback? onOpenSearch;

  /// ⊕「聊天背景」→ 页面打开背景弹层
  final VoidCallback? onOpenWallpaper;

  /// 照片背景沉浸式：输入栏/引用栏走与顶栏同色系的半透明深色层压图上
  final bool immersive;

  @override
  ConsumerState<ChatCompose> createState() => _ChatComposeState();
}

class _ChatComposeState extends ConsumerState<ChatCompose> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _slots = InputSlotMachine();
  final VoiceRecorder _recorder = VoiceRecorder();
  bool _recording = false;
  bool _hasText = false;
  double _lastInsets = 0;
  double _prevInsets = -1;
  String _stickerTab = 'cute';

  /// 本机键盘实测高度（落定后持久化；启动先读持久化值，无则用兜底，
  /// 首次键盘弹出自动纠正——主人定版：不写死、不估算）
  double? _kbHeight;

  @override
  void initState() {
    super.initState();
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final insets = MediaQuery.of(context).viewInsets.bottom;
    // 键盘收起（insets 归零）→ 意图面板自动回位
    if (_lastInsets > 0 && insets == 0) {
      if (_slots.intent != null) _slots.handle(InputSlotEvent.keyboardClosed);
    }
    // 键盘高度实测（复验 item 2）：连续两帧稳定且超门槛 → 记录并持久化
    if (insetsStable(_prevInsets, insets) && ((_kbHeight ?? 0) - insets).abs() > 1) {
      _kbHeight = insets;
      // ignore: unawaited_futures
      ref.read(keyboardMetricsStoreProvider).save(insets);
    }
    _prevInsets = insets;
    _lastInsets = insets;
  }

  /// 当前生效的键盘高度：本机实测（本次会话已弹过键盘）→ 持久化值 → 兜底。
  /// 面板/贴纸坞槽位一律等于该值（高度恒定推导见 keyboard_metrics.dart）
  double get _effectiveKeyboardHeight => _kbHeight ?? fallbackKeyboardHeight;

  @override
  void dispose() {
    widget.replyNotifier?.removeListener(_onReplyChanged);
    _input.dispose();
    _focus.dispose();
    _recorder.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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

  /// 语音（对齐 Web chatVoiceToggle：点一下开始，再点一次结束并发送）
  Future<void> _toggleVoice() async {
    if (_recording) {
      final f = await _recorder.stop();
      setState(() => _recording = false);
      if (f == null) {
        _snack('没有录到声音');
        return;
      }
      _snack('正在发送语音…');
      await _sendFiles([f]);
      return;
    }
    try {
      final ok = await _recorder.hasPermission();
      if (!ok) {
        _snack('需要麦克风权限，请到系统设置开启后重试');
        return;
      }
      await _recorder.start();
      setState(() => _recording = true);
      _snack('正在录音，再点一次麦克风结束并发送');
    } catch (_) {
      setState(() => _recording = false);
      _snack('录音失败');
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
      case 'voice': // 语音
        _pickFunction();
        _toggleVoice();
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
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final slotOpen = _slots.slot != InputSlot.none;
    // 槽位高度=键盘实测高度（等高推导，见 keyboard_metrics.dart）：
    // · 面板/坞开：slotHeight = (kbHeight - insets).clamp(0, kbHeight)
    //   → slotHeight + insets 恒等于 kbHeight，键盘↔面板两两切换时
    //   输入栏位置逐帧不动（总高度恒定）；
    // · 从零展开（insets==0）→ 槽位 0 → kbHeight 走抬升动画。
    final kbHeight = _effectiveKeyboardHeight;
    final slotHeight = slotHeightFor(
        slotOpen: slotOpen, insets: insets, kbHeight: kbHeight);
    // 动画时长：键盘过渡中（insets 变化时）零动画逐帧追踪公式（保证恒等式），
    // 零展开/收合才走 200ms 电梯动画
    final animDuration =
        (slotOpen && insets > 0) ? Duration.zero : const Duration(milliseconds: 200);
    final reply = widget.replyNotifier?.value;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      // 引用底栏（对齐 Web replyBar：「引用：xxx」+ 取消）
      if (reply != null)
        Container(
          width: double.infinity,
          color: chatChromeColor(theme, immersive: widget.immersive),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            Icon(Icons.reply_rounded,
                size: 16,
                color: widget.immersive
                    ? Colors.white70
                    : theme.colorScheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text('引用：${quoteSnippet(reply.$2)}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: widget.immersive ? Colors.white70 : null)),
            ),
            GestureDetector(
              onTap: () => widget.replyNotifier?.value = null,
              child: Text('取消',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.primary)),
            ),
          ]),
        ),
      // 输入栏（层级：消息列表 / 输入栏 / 底部槽位——输入栏恒在面板上方）。
      // 五处外壳同一函数取色：顶栏/状态栏/引用栏/输入栏/⊕面板/贴纸坞
      // 同一底色同一 α，杜绝「输入框透明、工具栏纯色」的混搭。
      Container(
        decoration: BoxDecoration(
          color: chatChromeColor(theme, immersive: widget.immersive),
          border: Border(
              top: BorderSide(
                  color: chatChromeBorder(theme, immersive: widget.immersive))),
        ),
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: SafeArea(
          top: false,
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
                style: TextStyle(
                    color: widget.immersive ? Colors.white : null),
                cursorColor: widget.immersive ? Colors.white70 : null,
                decoration: InputDecoration(
                  hintText: '发消息',
                  hintStyle: TextStyle(
                      color: widget.immersive ? Colors.white60 : null),
                  isDense: true,
                  filled: true,
                  fillColor: widget.immersive
                      ? Colors.white.withValues(alpha: 0.12)
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
            // 有文字时语音位换发送钮（对齐 Web form.has-text）
            if (!_hasText)
              IconButton(
                tooltip: _recording ? '结束并发送' : '发语音',
                onPressed: _toggleVoice,
                color: _recording ? theme.colorScheme.error : null,
                icon: Icon(_recording
                    ? Icons.stop_circle_rounded
                    : Icons.mic_rounded),
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
              color: widget.immersive ? Colors.white : null,
              icon: const Icon(Icons.emoji_emotions_rounded),
            ),
            IconButton(
              tooltip: '更多',
              onPressed: _toggleFn,
              color: widget.immersive ? Colors.white : null,
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
          child: _slots.slot == InputSlot.fn
              ? _FnPanel(
                  height: kbHeight,
                  immersive: widget.immersive,
                  onAction: _onFnAction)
              : _slots.slot == InputSlot.sticker
                  ? _StickerDock(
                      height: kbHeight,
                      immersive: widget.immersive,
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
      required this.onAction});
  final double height;
  final bool immersive;
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
    return Container(
      height: height,
      color: chatChromeColor(theme, immersive: immersive),
      child: GridView.count(
        crossAxisCount: 4,
        childAspectRatio: 1.15,
        padding: const EdgeInsets.all(10),
        children: [
          for (final (id, icon, label) in tiles)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => onAction(id),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 26, color: theme.colorScheme.primary),
                    const SizedBox(height: 6),
                    Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall),
                  ]),
            ),
        ],
      ),
    );
  }
}

// ── 贴纸坞（emoji 两组 + 3 内置包 + 我的）────────────────────────────

class _StickerDock extends ConsumerWidget {
  const _StickerDock({
    required this.height,
    required this.immersive,
    required this.tab,
    required this.onTab,
    required this.onEmoji,
    required this.onPickFunction,
    required this.onAddSticker,
  });
  final double height;
  final bool immersive;
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
    return Container(
      height: height,
      color: chatChromeColor(theme, immersive: immersive),
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
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline,
                      textStyle: theme.textTheme.labelLarge,
                    ),
                    child: Text(label),
                  ),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        Expanded(child: _body(context, ref)),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(_noteFor(tab),
              style:
                  theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
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
