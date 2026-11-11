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
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/api_client.dart';
import '../../core/chat/chat_media.dart';
import '../../core/chat/chat_models.dart';
import '../../core/chat/chat_state.dart';
import '../auth/auth_state.dart';
import 'album_picker_sheet.dart';
import 'input_slots.dart';
import 'media_bubble_widgets.dart';
import 'sticker_data.dart';
import 'voice_recorder.dart';

class ChatCompose extends ConsumerStatefulWidget {
  const ChatCompose({super.key});

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
  String _stickerTab = 'cute';

  @override
  void initState() {
    super.initState();
    _input.addListener(() {
      final has = _input.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
    _focus.addListener(_onFocusChanged);
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
    if (_lastInsets > 0 && insets == 0 && _slots.intent != null) {
      _slots.handle(InputSlotEvent.keyboardClosed);
    }
    _lastInsets = insets;
  }

  @override
  void dispose() {
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
    try {
      await ref.read(chatControllerProvider.notifier).send(text);
    } catch (e) {
      _snack(errorDetail(e));
    }
  }

  /// 本地预检后发送本机文件（白名单 + 250MB；非法文件剔除并提示，不发请求）
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

  /// 点 emoji 只插入文本不弹键盘（对齐 Web insertStickerText）
  void _insertEmoji(String em) {
    final value = _input.value;
    final sel = _input.selection;
    final valid = sel.isValid && sel.baseOffset >= 0;
    final start = valid ? sel.start : value.text.length;
    final end = valid && sel.extentOffset >= sel.start ? sel.end : start;
    final newText = value.text.replaceRange(start, end, em);
    _input.value = TextEditingValue(
      text: newText,
      selection:
          TextSelection.collapsed(offset: start + em.characters.length),
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
      case 'chat-locate':
      case 'chat-song':
      case 'chat-search':
      case 'chat-bg':
        _snack('条目 3 · 段三开放');
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
    final maxPanelH = MediaQuery.of(context).size.height * 0.62;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      // 同槽位互斥面板（先占位、键盘收起后显内容——防闪烁走常规 resize 路径）
      if (_slots.slot == InputSlot.fn)
        _FnPanel(height: min(368.0, maxPanelH), onAction: _onFnAction),
      if (_slots.slot == InputSlot.sticker)
        _StickerDock(
          height: min(348.0, maxPanelH),
          tab: _stickerTab,
          onTab: (t) => setState(() => _stickerTab = t),
          onEmoji: _insertEmoji,
          onPickFunction: _pickFunction,
          onAddSticker: _addMySticker,
        ),
      Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
              top: BorderSide(color: theme.colorScheme.outlineVariant)),
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
                decoration: InputDecoration(
                  hintText: '发消息',
                  isDense: true,
                  filled: true,
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
              icon: const Icon(Icons.emoji_emotions_rounded),
            ),
            IconButton(
              tooltip: '更多',
              onPressed: _toggleFn,
              icon: Icon(_slots.slot == InputSlot.fn
                  ? Icons.close_rounded
                  : Icons.add_circle_outline_rounded),
            ),
          ]),
        ),
      ),
    ]);
  }
}

// ── ⊕功能面板（16 格对齐 Web fnPanel）────────────────────────────────

class _FnPanel extends StatelessWidget {
  const _FnPanel({required this.height, required this.onAction});
  final double height;
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
      color: theme.colorScheme.surfaceContainerLow,
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
    required this.tab,
    required this.onTab,
    required this.onEmoji,
    required this.onPickFunction,
    required this.onAddSticker,
  });
  final double height;
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
      color: theme.colorScheme.surfaceContainerLow,
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
