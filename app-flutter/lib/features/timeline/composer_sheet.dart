/// Composer 完整态（条目 4 · 段二 · A 段）：
/// 发布（标题/内容/日期/媒体，client_id 幂等）+ 保存草稿（kind:'draft'，成功
/// 明确 toast）+ 表单本地暂存（字段+media+client_id 持久化，关弹层不丢、杀进程
/// 重开恢复，未传完媒体提示重选）+ 录音 tile（record 插件）+ 相册分类 chips
/// （kind:'album'，「暂不分类」=空 album 字段）。
/// 媒体上传复用聊天链路（白名单/250MB 预检/顺序上传/限流策略）。
/// 发布成功清空暂存；保存草稿成功保留工作态（草稿已落服务端，内容不丢）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/api_client.dart';
import '../../core/chat/chat_media.dart';
import '../../core/chat/chat_models.dart' show ChatLocalFile;
import '../chat/chat_toast.dart' show ChatToastHost, ChatToastTone, chatToastProvider;
import '../chat/voice_recorder.dart';
import 'composer_store.dart';
import 'timeline_controller.dart';

/// 打开 composer 弹层（FAB 与页头「记录此刻」共用入口）
Future<void> showComposerSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => const ComposerSheet(),
  );
}

/// 一条待发媒体：先选本机文件 → 顺序上传拿 id → 发布进 body.media
class ComposerMedia {
  ComposerMedia({required this.localFile});
  final ChatLocalFile localFile;
  String? uploadedId;
  double progress = 0; // 0..1（上传中）
}

/// 相册分类项（kind:'album' 记录）
class AlbumChoice {
  const AlbumChoice({required this.id, required this.title});
  final String id;
  final String title;
}

class ComposerSheet extends ConsumerStatefulWidget {
  const ComposerSheet({super.key});

  @override
  ConsumerState<ComposerSheet> createState() => _ComposerSheetState();
}

class _ComposerSheetState extends ConsumerState<ComposerSheet> {
  final _title = TextEditingController();
  final _content = TextEditingController();
  DateTime _date = DateTime.now();
  final _media = <ComposerMedia>[];
  bool _submitting = false;
  bool _draftSaving = false;
  String? _error;

  // 相册分类
  String? _album; // 选中相册 id；null=暂不分类
  List<AlbumChoice> _albums = const [];
  bool _albumsLoading = false;

  // 本地暂存
  String? _postClientId;
  String? _draftClientId;
  bool _pendingMediaNotice = false; // 恢复出未传完媒体

  // 录音三键状态机（四态互斥：idle / recording / paused → 完成=进列表、
  // 取消=丢弃；录制中或暂停中关弹层一律自动取消）
  static const _recIdle = 0, _recRecording = 1, _recPaused = 2;
  final VoiceRecorder _rec = VoiceRecorder();
  int _recState = _recIdle;
  Duration _recElapsed = Duration.zero;
  int _recTicks = 0; // 累计录制秒数（暂停冻结，继续续走）
  Timer? _recTimer;

  @override
  void initState() {
    super.initState();
    _loadStore();
    Future.microtask(_fetchAlbums);
    // 监听字段变化，自动暂存
    _title.addListener(_onFieldChanged);
    _content.addListener(_onFieldChanged);
  }

  @override
  void dispose() {
    _title.removeListener(_onFieldChanged);
    _content.removeListener(_onFieldChanged);
    _title.dispose();
    _content.dispose();
    _recTimer?.cancel();
    _recTimer = null;
    // 录制中或暂停中关掉弹层：一律自动取消录音，不留脏文件（已验收行为）
    if (_recState != _recIdle) {
      _rec.cancel().catchError((_) {});
    }
    _rec.dispose();
    super.dispose();
  }

  void _onFieldChanged() => _persistStore();

  /// 结果类提示统一走顶部通知（复用聊天撤回提示同一套组件/位置/样式，
  /// 2200ms 自动收起；禁用底部 SnackBar——真机被底部栏遮盖）。
  void _toast(String msg, {ChatToastTone tone = ChatToastTone.info}) {
    ref.read(chatToastProvider.notifier).show(msg, tone: tone);
  }

  // ── 本地暂存 ───────────────────────────────────────────────

  Future<void> _loadStore() async {
    final store = await readComposerStore();
    if (store == null || store.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _title.text = store.title;
      _content.text = store.content;
      if (store.date.isNotEmpty) {
        _date = DateTime.tryParse(store.date) ?? DateTime.now();
      }
      _album = store.album;
      _postClientId = store.postClientId;
      _draftClientId = store.draftClientId;
      for (final m in store.media) {
        _media.add(ComposerMedia(
            localFile: ChatLocalFile(path: m.path, name: m.name))
          ..uploadedId = m.uploadedId);
      }
      // 未传完媒体（无 uploadedId）：提示重选
      _pendingMediaNotice = store.media.any((m) => m.uploadedId == null);
    });
  }

  void _persistStore() {
    final store = ComposerStore(
      title: _title.text,
      content: _content.text,
      date: _fmtDate(_date),
      album: _album,
      postClientId: _postClientId,
      draftClientId: _draftClientId,
      media: _media
          .map((m) => StoredMedia(
              path: m.localFile.path,
              name: m.localFile.name,
              uploadedId: m.uploadedId))
          .toList(),
    );
    writeComposerStore(store);
  }

  // ── 相册分类 ───────────────────────────────────────────────

  Future<void> _fetchAlbums() async {
    try {
      final dio = await ref.read(dioProvider.future);
      final r = await dio.get('/api/records',
          queryParameters: {'kind': 'album', 'limit': 200});
      if (!mounted) return;
      final list = <AlbumChoice>[];
      if (r.data is List) {
        for (final e in r.data) {
          if (e is Map) {
            final body = (e['body'] ?? {}) as Map;
            final id = (e['id'] ?? '').toString();
            final title = (body['title'] ?? '').toString();
            if (id.isNotEmpty) list.add(AlbumChoice(id: id, title: title));
          }
        }
      }
      setState(() { _albums = list; _albumsLoading = false; });
    } catch (_) {
      if (mounted) setState(() { _albumsLoading = false; });
    }
  }

  void _selectAlbum(String? id) {
    setState(() => _album = id);
    _persistStore();
  }

  // ── 日期 ───────────────────────────────────────────────────

  Future<void> _pickDate() async {
    final d = await showDatePicker(
        context: context,
        initialDate: _date,
        firstDate: DateTime(2000),
        lastDate: DateTime.now().add(const Duration(days: 365)));
    if (d != null) {
      setState(() => _date = d);
      _persistStore();
    }
  }

  // ── 媒体选择 ───────────────────────────────────────────────

  Future<void> _pickImageVideo() async {
    final picked = await ImagePicker().pickMultiImage();
    if (picked.isEmpty) {
      final v = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (v != null) await _addMedia([v]);
      return;
    }
    await _addMedia(picked);
  }

  Future<void> _pickFromLibrary() async {
    try {
      final dio = await ref.read(dioProvider.future);
      final list = await fetchMediaLibrary(dio, limit: 60);
      if (!mounted) return;
      final picked = await showModalBottomSheet<String>(
        context: context,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (ctx) => SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.5,
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
            itemCount: list.length,
            itemBuilder: (ctx, i) => InkWell(
                onTap: () => Navigator.pop(ctx, list[i].id),
                child: Center(child: Text(list[i].name,
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(ctx).textTheme.labelSmall))),
          ),
        ),
      );
      if (picked != null && picked.isNotEmpty) {
        setState(() => _media.add(ComposerMedia(
            localFile: ChatLocalFile(path: '', name: 'media:$picked'))
          ..uploadedId = picked));
        _persistStore();
      }
    } catch (e) {
      _toast(errorDetail(e), tone: ChatToastTone.error);
    }
  }

  Future<void> _addMedia(List<XFile> files) async {
    for (final x in files) {
      final bytes = await File(x.path).length();
      final err = validateUploadFile(x.name, bytes);
      if (err != null) {
        _toast('${x.name}：$err', tone: ChatToastTone.warning);
        continue;
      }
      setState(() =>
          _media.add(ComposerMedia(localFile: ChatLocalFile(path: x.path, name: x.name))));
    }
    if (_media.length > maxMediaPerRecord) {
      _toast('一条记录最多 $maxMediaPerRecord 个附件，多出的已忽略',
          tone: ChatToastTone.warning);
      setState(() {
        while (_media.length > maxMediaPerRecord) {
          _media.removeLast();
        }
      });
    }
    _persistStore();
  }

  void _moveUp(int i) {
    if (i <= 0) return;
    setState(() {
      final m = _media.removeAt(i);
      _media.insert(i - 1, m);
    });
    _persistStore();
  }

  void _remove(int i) {
    setState(() => _media.removeAt(i));
    _persistStore();
  }

  // ── 录音 tile ───────────────────────────────────────────────

  // ── 录音三键（状态机四态互斥：idle / recording / paused →
  //    完成=停止进列表，取消=丢弃）──────────────────────────────

  void _startTick() {
    _recTimer?.cancel();
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _recTicks += 1;
      setState(() => _recElapsed = Duration(seconds: _recTicks));
    });
  }

  /// 冻结计时（暂停时调用；继续后 _startTick 续走，_recTicks 不清零）
  void _stopTick() {
    _recTimer?.cancel();
    _recTimer = null;
  }

  Future<void> _startRecord() async {
    // record 5.x：hasPermission() 首次调用即在 Android 触发系统授权弹窗，
    // 无独立 requestPermission API；返回 false 视为已拒绝
    if (!await _rec.hasPermission()) {
      _toast('没有录音权限，请到系统设置里给 App 开启麦克风权限',
          tone: ChatToastTone.warning);
      return;
    }
    try {
      await _rec.start();
      _recTicks = 0;
      if (mounted) {
        setState(() { _recState = _recRecording; _recElapsed = Duration.zero; });
      }
      _startTick();
    } catch (e) {
      _stopTick();
      _toast(errorDetail(e), tone: ChatToastTone.error);
    }
  }

  /// 暂停 / 继续（record 插件自带 pause/resume，不自造）：
  /// 暂停时计时冻结、界面明示「已暂停」；继续后接着录、计时续走。
  Future<void> _togglePause() async {
    if (_recState == _recRecording) {
      await _rec.pause();
      _stopTick();
      if (mounted) setState(() => _recState = _recPaused);
    } else if (_recState == _recPaused) {
      await _rec.resume();
      if (mounted) setState(() => _recState = _recRecording);
      _startTick();
    }
  }

  /// 完成：停止录音并把这条录音加入媒体列表（等同已验收的「停止进列表」）
  Future<void> _finishRecord() async {
    _stopTick();
    final f = await _rec.stop();
    _recTicks = 0;
    if (mounted) {
      setState(() { _recState = _recIdle; _recElapsed = Duration.zero; });
    }
    await _rec.recycle();
    if (f != null) {
      if (!mounted) return;
      setState(() => _media.add(ComposerMedia(
          localFile: ChatLocalFile(path: f.path, name: f.name))));
      _persistStore();
      _toast('录音已添加', tone: ChatToastTone.success);
    }
  }

  /// 取消：丢弃录音、不留脏文件（现有行为不变）
  Future<void> _cancelRecord() async {
    _stopTick();
    await _rec.cancel();
    await _rec.recycle();
    _recTicks = 0;
    if (mounted) {
      setState(() { _recState = _recIdle; _recElapsed = Duration.zero; });
    }
  }

  // ── 上传本机文件 → ids ─────────────────────────────────────

  Future<List<String>> _uploadLocals() async {
    final ids = <String>[];
    for (final m in _media) {
      if (m.uploadedId != null) {
        ids.add(m.uploadedId!);
        continue;
      }
      final bytes = await File(m.localFile.path).readAsBytes();
      final dio = await ref.read(dioProvider.future);
      final id = await uploadChatMedia(dio, m.localFile.name, bytes,
          onProgress: (p) {
        if (!mounted) return;
        setState(() => m.progress = p);
      });
      m.uploadedId = id;
      ids.add(id);
      if (mounted) setState(() {});
    }
    return ids;
  }

  // ── 发布 ───────────────────────────────────────────────────

  Future<void> _submit() async {
    if (_submitting) return;
    final content = _content.text.trim();
    final title = _title.text.trim();
    if (content.isEmpty && _media.isEmpty) {
      setState(() => _error = '写点什么，或加一张照片吧');
      return;
    }
    setState(() { _submitting = true; _error = null; });
    try {
      final ids = await _uploadLocals();
      final err = await ref.read(timelineControllerProvider.notifier).publish(
            content: content,
            date: _fmtDate(_date),
            mediaIds: ids,
            title: title.isEmpty ? null : title,
            album: _album,
            clientId: _postClientId,
          );
      if (err != null) {
        setState(() { _error = err; _submitting = false; });
        _toast(err, tone: ChatToastTone.error);
        return;
      }
      await clearComposerStore();
      await ref.read(timelineControllerProvider.notifier).resetAfterPublish();
      // 发布成功走顶部通知（先发再关弹层：弹层内 host 即将卸载，
      // 时光页顶部宿主接棒显示同一 provider 的通知）
      _toast('这一刻，已经好好收藏', tone: ChatToastTone.success);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      final msg = e is MediaValidationError ? e.message : errorDetail(e);
      setState(() {
        _error = msg;
        _submitting = false;
      });
      _toast(msg, tone: ChatToastTone.error);
    }
  }

  // ── 保存草稿 ───────────────────────────────────────────────

  Future<void> _saveDraft() async {
    if (_draftSaving) return;
    // 草稿允许空内容（仅存结构），但至少给一个可辨识的占位，避免空草稿
    final content = _content.text.trim();
    setState(() { _draftSaving = true; _error = null; });
    try {
      final ids = await _uploadLocals();
      final err = await ref.read(timelineControllerProvider.notifier).saveDraft(
            content: content.isEmpty ? '（草稿）' : content,
            date: _fmtDate(_date),
            mediaIds: ids,
            title: _title.text.trim().isEmpty ? null : _title.text.trim(),
            album: _album,
            clientId: _draftClientId,
          );
      if (err != null) {
        setState(() { _error = err; _draftSaving = false; });
        _toast(err, tone: ChatToastTone.error);
        return;
      }
      // 成功：顶部通知明确提示，绝不让用户以为按钮没反应
      setState(() { _draftSaving = false; });
      _toast('草稿已保存', tone: ChatToastTone.success);
    } catch (e) {
      final msg = e is MediaValidationError ? e.message : errorDetail(e);
      setState(() {
        _error = msg;
        _draftSaving = false;
      });
      _toast(msg, tone: ChatToastTone.error);
    }
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
          left: 16, right: 16, top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 12),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // 顶部通知宿主（复用聊天撤回提示同一套组件/位置/样式；空态 0 高不占位）
          const ChatToastHost(),
          Row(children: [
            Expanded(child: Text('记录此刻', style: theme.textTheme.titleMedium)),
            IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded)),
          ]),
          if (_pendingMediaNotice)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('有未上传完成的媒体，请重新选择或移除',
                    style: theme.textTheme.bodySmall),
              ),
            ),
          TextField(
            controller: _title,
            maxLength: 200,
            decoration: const InputDecoration(
                labelText: '标题（可选）', counterText: '', isDense: true),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _content,
            maxLines: 4,
            minLines: 2,
            maxLength: 20000,
            decoration: const InputDecoration(
                labelText: '这一刻想说的话', counterText: '', alignLabelWithHint: true),
          ),
          const SizedBox(height: 8),
          // 日期 + 媒体入口
          Row(children: [
            Icon(Icons.event_rounded, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text('发生日期', style: theme.textTheme.bodyMedium),
            const SizedBox(width: 10),
            TextButton(
              onPressed: _pickDate,
              child: Text(_fmtDate(_date)),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _pickImageVideo,
              icon: const Icon(Icons.image_rounded, size: 18),
              label: const Text('图/视频'),
            ),
            TextButton.icon(
              onPressed: _pickFromLibrary,
              icon: const Icon(Icons.audiotrack_rounded, size: 18),
              label: const Text('音频'),
            ),
          ]),
          // 录音 tile（三键：录制中=暂停/完成/取消，暂停中=继续/完成/取消）
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              Icon(Icons.mic_rounded, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('录音', style: theme.textTheme.bodyMedium),
              const Spacer(),
              if (_recState == _recIdle)
                TextButton.icon(
                  onPressed: _startRecord,
                  icon: const Icon(Icons.mic_rounded, size: 18),
                  label: const Text('开始录音'),
                ),
              if (_recState == _recRecording) ...[
                Text(_fmtDuration(_recElapsed),
                    style: theme.textTheme.bodyMedium),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: _togglePause,
                  icon: const Icon(Icons.pause_rounded, size: 18),
                  label: const Text('暂停'),
                ),
              ],
              if (_recState == _recPaused) ...[
                Text('已暂停 ${_fmtDuration(_recElapsed)}',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.primary)),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: _togglePause,
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('继续'),
                ),
              ],
              if (_recState != _recIdle) ...[
                TextButton.icon(
                  onPressed: _finishRecord,
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('完成'),
                ),
                IconButton(
                  tooltip: '取消',
                  visualDensity: VisualDensity.compact,
                  onPressed: _cancelRecord,
                  icon: const Icon(Icons.cancel_rounded, size: 18),
                ),
              ],
            ]),
          ),
          // 相册分类 chips
          if (_albums.isNotEmpty || _albumsLoading)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('相册分类', style: theme.textTheme.bodyMedium),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  _albumChip(theme, '暂不分类', _album == null, () => _selectAlbum(null)),
                  for (final a in _albums)
                    _albumChip(theme, a.title, _album == a.id, () => _selectAlbum(a.id)),
                ]),
                if (_albumsLoading)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text('加载相册中…', style: TextStyle(color: Colors.grey)),
                  ),
              ]),
            ),
          if (_media.isNotEmpty)
            ..._buildMediaList(theme),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ),
          const SizedBox(height: 10),
          Row(children: [
            // 保存草稿（次按钮）
            OutlinedButton(
              onPressed: _draftSaving ? null : _saveDraft,
              child: _draftSaving
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('存草稿'),
            ),
            const Spacer(),
            // 发布（主按钮）
            FilledButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('发布'),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _albumChip(ThemeData theme, String label, bool selected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant),
        ),
        child: Text(label,
            style: theme.textTheme.labelSmall?.copyWith(
                color: selected
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.outline)),
      ),
    );
  }

  String _fmtDuration(Duration d) =>
    '${d.inMinutes.toString().padLeft(2, '0')}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  List<Widget> _buildMediaList(ThemeData theme) {
    return [
      const SizedBox(height: 8),
      for (var i = 0; i < _media.length; i++)
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            Icon(Icons.attach_file_rounded, size: 16, color: theme.colorScheme.outline),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min, children: [
                Text(_media[i].localFile.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall),
                if (_media[i].uploadedId == null && _media[i].progress > 0)
                  LinearProgressIndicator(value: _media[i].progress, minHeight: 3),
                if (_media[i].uploadedId != null)
                  Text('已就绪',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.primary)),
              ]),
            ),
            IconButton(
              tooltip: '前移',
              visualDensity: VisualDensity.compact,
              onPressed: i == 0 ? null : () => _moveUp(i),
              icon: const Icon(Icons.arrow_upward_rounded, size: 18),
            ),
            IconButton(
              tooltip: '移除',
              visualDensity: VisualDensity.compact,
              onPressed: () => _remove(i),
              icon: Icon(Icons.close_rounded, size: 18, color: theme.colorScheme.error),
            ),
          ]),
        ),
    ];
  }
}
