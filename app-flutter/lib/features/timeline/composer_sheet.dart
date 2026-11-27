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

import 'package:dio/dio.dart' show Dio;
import 'package:flutter/material.dart';
import 'composer_song_sheet.dart' show showComposerSongSheet;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/api_client.dart';
import '../../core/chat/chat_media.dart';
import '../../core/chat/chat_models.dart' show ChatLocalFile, ChatMedia;
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../chat/media_bubble_widgets.dart' show MediaImageView, VideoCardView;
import '../chat/voice_playback.dart' show voicePlaybackProvider;
import 'image_viewer.dart' show ImageViewerPage;
import '../chat/voice_recorder.dart';
import 'composer_store.dart';
import 'timeline_controller.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/tokens.dart';
import '../../core/ui/apple_ui.dart';
import '../../core/ui/selection_sheet.dart';
import '../settings/settings_widgets.dart'
    show GlassActionBar, filledFieldDecoration;

/// 打开 composer 弹层（页头「记录此刻」/ FAB / 聊天「记入时光」/ 编辑共用）。
/// · [editRecord] 非空 = 编辑态（C2）：预填原记录，PUT 全量 body（原始 body
///   为底只覆盖改动字段），不走暂存、不显示存草稿。
/// · [initialContent] / [initialMediaIds] = 聊天「记入时光」预填（C4）：
///   post 态，与时光页发布共用暂存/client_id 幂等一套逻辑。
/// · [initialAlbum] = 相册页上传预填（段 C）：非空时预填该相册分类并跳过
///   本地暂存恢复（干净起点，避免把上一次草稿混进当前相册）。
/// · [editKind] = 编辑态强制 PUT 的 kind（条目 7 草稿箱「继续编辑」传
///   'draft'：timelineController.editRecord 默认按时光列表里的卡取 kind，
///   草稿不在该列表会被误判成 post；这里显式覆盖，不另造编辑器）。
Future<void> showComposerSheet(
  BuildContext context, {
  Record? editRecord,
  String? editKind,
  String? initialContent,
  List<String>? initialMediaIds,
  String? initialAlbum,

  /// 2.3.6（发布抽屉「传照片」）：打开弹层后自动触发图/视频选择一次——
  /// 即现弹层「图/视频」入口的既有行为，仅省一次手点；null/false 零变化。
  bool autoPickMedia = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl))),
    builder: (_) => ComposerSheet(
      editRecord: editRecord,
      editKind: editKind,
      initialContent: initialContent,
      initialMediaIds: initialMediaIds,
      initialAlbum: initialAlbum,
      autoPickMedia: autoPickMedia,
    ),
  );
}

/// 一条待发媒体：先选本机文件 → 顺序上传拿 id → 发布进 body.media
class ComposerMedia {
  ComposerMedia({required this.localFile, this.mime = ''});
  final ChatLocalFile localFile;

  /// 2.8.4：媒体 MIME。编辑态从 `record.media` 元数据带入，决定预览形态
  /// （图片缩略图 / 视频封面 / 音频试听）；新建时为空，由扩展名兜底。
  final String mime;
  String? uploadedId;
  double progress = 0; // 0..1（上传中）
}

/// 选图/视频共用入口（2.4.1 第 16 项抽共用：行为等价 composer 原实现——
/// 先多选图，未选到再退回选一个视频；不弹任何提示）。
Future<List<XFile>> pickImageVideoFiles() async {
  final picked = await ImagePicker().pickMultiImage();
  if (picked.isNotEmpty) return picked;
  final v = await ImagePicker().pickVideo(source: ImageSource.gallery);
  return v == null ? const <XFile>[] : <XFile>[v];
}

/// 相册分类抓取共用入口（2.4.1 第 16 项抽共用：请求与解析逐行等价
/// composer 原实现——GET /api/records?kind=album&limit=200，失败静默空表）。
Future<List<AlbumChoice>> fetchAlbumList(Future<Dio> Function() getDio) async {
  try {
    final dio = await getDio();
    final r = await dio.get('/api/records',
        queryParameters: {'kind': 'album', 'limit': 200});
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
    return list;
  } catch (_) {
    return const <AlbumChoice>[];
  }
}

/// 相册分类项（kind:'album' 记录）
class AlbumChoice {
  const AlbumChoice({required this.id, required this.title});
  final String id;
  final String title;
}

class ComposerSheet extends ConsumerStatefulWidget {
  const ComposerSheet({
    super.key,
    this.editRecord,
    this.editKind,
    this.initialContent,
    this.initialMediaIds,
    this.initialAlbum,
    this.autoPickMedia = false,
  });
  final Record? editRecord;

  /// 2.3.6（发布抽屉「传照片」）：首帧后自动触发一次图/视频选择。
  final bool autoPickMedia;

  /// 编辑态强制 PUT kind（草稿箱继续编辑 = 'draft'）
  final String? editKind;
  final String? initialContent;
  final List<String>? initialMediaIds;
  final String? initialAlbum;

  bool get isEdit => editRecord != null;
  bool get hasPrefill =>
      (initialContent != null && initialContent!.isNotEmpty) ||
      (initialMediaIds != null && initialMediaIds!.isNotEmpty);

  @override
  ConsumerState<ComposerSheet> createState() => _ComposerSheetState();
}

class _ComposerSheetState extends ConsumerState<ComposerSheet> {
  final _title = TextEditingController();
  final _content = TextEditingController();
  DateTime _date = DateTime.now();
  final _media = <ComposerMedia>[];
  /// 2.4.12：一条动态最多一首歌（body.song 形态），null=未选。
  Map<String, dynamic>? _song;
  bool _submitting = false;
  bool _draftSaving = false;
  String? _error;

  // C2 编辑回填铁律：服务器拉到的原始 body，只作为 put 的底逐键复制。
  // _editInitial 是预填时的字段快照，用于判定「用户实际改动了哪些字段」。
  Map<String, dynamic> _originalBody = const {};
  Map<String, dynamic> _editInitial = const {};

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
    if (widget.isEdit) {
      _initFromEditRecord(widget.editRecord!);
    } else if (widget.hasPrefill) {
      // 聊天「记入时光」预填：跳过暂存恢复（避免把上一次草稿混进来），
      // 但之后仍走同一套自动暂存 + client_id 幂等发布逻辑
      _content.text = widget.initialContent ?? '';
      for (final id in widget.initialMediaIds ?? const <String>[]) {
        _media.add(ComposerMedia(
            localFile: ChatLocalFile(path: '', name: '附件'))
          ..uploadedId = id);
      }
    } else if (widget.initialAlbum != null && widget.initialAlbum!.isNotEmpty) {
      // 相册页上传预填（段 C）：预填相册分类，跳过暂存恢复（干净起点，
      // 避免把上一次草稿混进当前相册），之后仍走自动暂存 + 幂等发布。
      _album = widget.initialAlbum;
    } else {
      _loadStore();
    }
    Future.microtask(_fetchAlbums);
    // 监听字段变化，自动暂存（编辑态不写暂存，避免污染草稿文件）
    _title.addListener(_onFieldChanged);
    _content.addListener(_onFieldChanged);
    // 2.3.6（发布抽屉「传照片」）：首帧稳定后自动触发一次图/视频选择——
    // 即「图/视频」入口的既有行为，仅省一次手点。
    if (widget.autoPickMedia) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pickImageVideo();
      });
    }
  }

  /// C2 编辑预填：从服务器拉到的原始 body 逐键回填（保留未知字段作为提交底），
  /// 媒体 id 直接作为已上传项，album 原样回填，「暂不分类」=空。
  void _initFromEditRecord(Record r) {
    _originalBody = Map<String, dynamic>.from(r.body);
    _title.text = (r.body['title'] ?? '').toString();
    _content.text = (r.body['content'] ?? '').toString();
    final dateStr = (r.body['date'] ?? '').toString();
    _date = DateTime.tryParse(dateStr) ?? DateTime.now();
    _album = (r.body['album'] ?? '').toString().isEmpty
        ? null
        : r.body['album'].toString();
    final rawSong = r.body['song'];
    if (rawSong is Map) _song = Map<String, dynamic>.from(rawSong);
    final mids = (r.body['media'] as List?) ?? const [];
    // 2.8.4 缺陷一：body.media 只有 id，原来把 id 塞进 name 当「文件名」显示，
    // 于是编辑态只能看到 `media:fa719…` 这种 token 芯片、也点不开预览。
    // 记录 JSON 的 `media` 字段本来就带 {id,mime,name}（serialize_many 组装），
    // 拿它还原成与新建态同形态的附件项即可，不需要额外请求、后端零改。
    final meta = <String, Map<String, dynamic>>{
      for (final m in r.media)
        if ((m['id'] ?? '').toString().isNotEmpty)
          (m['id'] ?? '').toString(): m,
    };
    for (final mid in mids) {
      final id = mid.toString();
      if (id.isEmpty) continue;
      final m = meta[id];
      final nm = (m?['name'] ?? '').toString();
      _media.add(ComposerMedia(
          localFile: ChatLocalFile(path: '', name: nm.isEmpty ? '附件' : nm),
          mime: (m?['mime'] ?? '').toString())
        ..uploadedId = id);
    }
    // 预填快照：只记录客户端建模的五个字段，作为「是否改动」的基准；
    // 原始 body 里的其它键（未知字段）一律不进快照、提交时也不碰。
    _editInitial = {
      'title': _title.text,
      'content': _content.text,
      'date': _fmtDate(_date),
      'media': (r.body['media'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          <String>[],
      'album': _album ?? '',
    };
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
    if (widget.isEdit) return; // C2 编辑不走暂存（草稿文件属新建/记入时光）
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
      final list = await fetchAlbumList(() => ref.read(dioProvider.future));
      if (!mounted) return;
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
    final picked = await pickImageVideoFiles();
    if (picked.isEmpty) return;
    await _addMedia(picked);
  }

  /// 2.4.12：选歌（库音乐/在线两页签），选中写草稿态 _song。
  Future<void> _pickSong() async {
    final picked = await showComposerSongSheet(context);
    if (picked != null && mounted) setState(() => _song = picked);
  }

  Future<void> _pickFromLibrary() async {
    try {
      final dio = await ref.read(dioProvider.future);
      final list = await fetchMediaLibrary(dio, limit: 60);
      if (!mounted) return;
      final picked = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: false,
        backgroundColor: Colors.transparent,
        builder: (ctx) => AppleSheetContainer(
          title: '从媒体库选',
          onClose: () => Navigator.pop(ctx),
          maxHeightFactor: 0.55,
          child: GridView.builder(
            padding: const EdgeInsets.only(bottom: 8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3, mainAxisSpacing: 6, crossAxisSpacing: 6),
            itemCount: list.length,
            itemBuilder: (ctx, i) {
              final cs = Theme.of(ctx).colorScheme;
              return Material(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(AppRadius.small),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.small),
                  onTap: () => Navigator.pop(ctx, list[i].id),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Center(
                      child: Text(
                        list[i].name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(ctx).textTheme.labelSmall,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      if (picked != null && picked.isNotEmpty) {
        setState(() => _media.add(ComposerMedia(
            localFile: ChatLocalFile(path: '', name: '附件'))
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
    // 无独立 requestPermission API；返回 false 视为已拒绝。
    // （时光线入口为按钮点击路径，弹窗合规——既有交互形态不动，2.7.0 ①-5）
    if (!await _rec.hasPermission()) {
      _toast('没有录音权限，请到系统设置里给 App 开启麦克风权限',
          tone: ChatToastTone.warning);
      return;
    }
    try {
      // 2.7.0 第①项①-5：启动 3 秒超时兜底（授权后重建由 VoiceRecorder.start
      // 内部自动处理，与本文件无关）；超时走既有 catch 收尾。
      await _rec.start().timeout(const Duration(seconds: 3));
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

  // ── 发布（2.4.10：改返 Future<bool> 供三连变真实请求驱动；
  // 成功/失败 toast 与关弹层由本函数内部承担，morph 只看返回值）──

  Future<bool> _submit() async {
    if (_submitting) return false;
    final content = _content.text.trim();
    final title = _title.text.trim();
    if (content.isEmpty && _media.isEmpty) {
      setState(() => _error = '写点什么，或加一张照片吧');
      return false;
    }
    setState(() { _submitting = true; _error = null; });
    try {
      final ids = await _uploadLocals();
      if (widget.isEdit) {
        return await _submitEdit(title, content, ids);
      }
      final err = await ref.read(timelineControllerProvider.notifier).publish(
            content: content,
            date: _fmtDate(_date),
            mediaIds: ids,
            title: title.isEmpty ? null : title,
            album: _album,
            clientId: _postClientId,
            song: _song,
          );
      if (err != null) {
        setState(() { _error = err; _submitting = false; });
        _toast(err, tone: ChatToastTone.error);
        return false;
      }
      await clearComposerStore();
      await ref.read(timelineControllerProvider.notifier).resetAfterPublish();
      // 发布成功走顶部通知（弹层由 onMorphSuccess 在对勾驻留后关，
      // toast host 接棒链路不变）
      _toast('这一刻，已经好好收藏', tone: ChatToastTone.success);
      return true;
    } catch (e) {
      final msg = e is MediaValidationError ? e.message : errorDetail(e);
      setState(() {
        _error = msg;
        _submitting = false;
      });
      _toast(msg, tone: ChatToastTone.error);
      return false;
    }
  }

  /// C2 编辑提交：只把「用户实际改动」的字段放进 changes，交给控制器
  /// 以服务器原始 body 为底合并后 PUT；客户端不认识/不建模的字段（含
  /// permitted 集内未知字段）一律不碰，由原始 body 原样带回。
  Future<bool> _submitEdit(String title, String content, List<String> ids) async {
    final changes = <String, dynamic>{};
    // 只覆盖「用户实际改动」的字段：与预填快照逐一比对，未改动的不进
    // changes，由控制器用原始 body 逐键复制时原样带回（含未知字段）。
    if (_title.text.trim() != _editInitial['title']) {
      changes['title'] = title;
    }
    if (content != _editInitial['content']) changes['content'] = content;
    final dateStr = _fmtDate(_date);
    if (dateStr != _editInitial['date']) changes['date'] = dateStr;
    final initialMedia =
        (_editInitial['media'] as List?)?.cast<String>() ?? <String>[];
    if (!_sameList(initialMedia, ids)) changes['media'] = ids;
    final newAlbum = _album ?? '';
    if (newAlbum != _editInitial['album']) changes['album'] = newAlbum;
    // 2.4.12 回填铁律 song 维度：不编辑音乐时 song 不进 changes，
    // 由 originalBody 原样带回；换歌/移除才写 changes['song']（null=移除需显式空 Map 标记）
    final initialSong = _originalBody['song'];
    final songChanged = _song != null
        ? _song.toString() != (initialSong?.toString() ?? '')
        : initialSong != null;
    if (songChanged) changes['song'] = _song;

    final err = await ref.read(timelineControllerProvider.notifier).editRecord(
        widget.editRecord!.id, changes,
        originalBody: _originalBody, kindOverride: widget.editKind);
    if (err != null) {
      setState(() { _error = err; _submitting = false; });
      _toast(err, tone: ChatToastTone.error);
      return false;
    }
    _toast('已保存修改', tone: ChatToastTone.success);
    return true;
  }

  bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
          // 顶部通知由 App 根部全局 ChatToastHost 承载（覆盖弹层）
          // 2.4.1 第 12 项①外壳：顶部小抓手（Dock 抽屉同款 38×4.5）+
          // 关闭钮收进圆钮（半透圆底）。
          Column(children: [
            Center(
              child: Container(
                width: 38,
                height: 4.5,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            Row(children: [
              Expanded(child: Text(
                  widget.isEdit ? '编辑这一刻' : '记录此刻',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700))),
              AppleSheetCloseButton(
                onPressed: () => Navigator.of(context).pop(),
              ),
            ]),
          ]),
          if (_pendingMediaNotice)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Text('有未上传完成的媒体，请重新选择或移除',
                    style: theme.textTheme.bodySmall),
              ),
            ),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('标题（可选）', style: theme.textTheme.labelSmall),
            const SizedBox(height: 6),
            TextField(
              controller: _title,
              maxLength: 200,
              decoration: filledFieldDecoration(counterText: ''),
            ),
          ]),
          const SizedBox(height: Spacing.gap),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('这一刻想说的话', style: theme.textTheme.labelSmall),
            const SizedBox(height: 6),
            TextField(
              controller: _content,
              maxLines: 6,
              minLines: 4,
              maxLength: 20000,
              style: const TextStyle(height: 1.5),
              decoration: filledFieldDecoration(alignLabelWithHint: true),
            ),
          ]),
          const SizedBox(height: Spacing.gap),
          // 日期 + 媒体入口。2.3.4（推广段一重做，QA 备案缺陷②）：
          // 原单行 Row（图标+文字+日期钮+Spacer+图/视频+音频）在 393 宽右溢出
          // 约 90px、320 更甚——改 Wrap：日期组 mainAxisSize.min 固定一行，
          // 媒体入口空间不足自动换行；发布字段/回调链零变化。
          // 2.4.1 第 12 项③：发生日期改整行选择框（标签 + 值 + 右箭头）。
          InkWell(
            key: const Key('composer-date-field'),
            borderRadius: BorderRadius.circular(12),
            onTap: _pickDate,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                Text('发生日期', style: theme.textTheme.labelSmall),
                const Spacer(),
                Text(_fmtDate(_date), style: theme.textTheme.bodyMedium),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right_rounded,
                    size: 18, color: theme.colorScheme.outline),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          // 2.4.1 第 12 项④：媒体入口 tile（图标上文字下、淡紫底 + 紫描边）；
          // 2.4.12 加「音乐」第四入口——Wrap 防 393 宽挤压（历史溢出教训）。
          Wrap(spacing: 8, runSpacing: 8, children: [
            SizedBox(
              width: (MediaQuery.sizeOf(context).width - 32 - 24) / 4,
              child: _mediaTile(theme, Icons.image_rounded, '图/视频',
                  onTap: _pickImageVideo),
            ),
            SizedBox(
              width: (MediaQuery.sizeOf(context).width - 32 - 24) / 4,
              child: _mediaTile(theme, Icons.audiotrack_rounded, '音频',
                  onTap: _pickFromLibrary),
            ),
            SizedBox(
              width: (MediaQuery.sizeOf(context).width - 32 - 24) / 4,
              child: _mediaTile(theme, Icons.mic_rounded, '录音',
                  onTap: _recState == _recIdle ? _startRecord : null),
            ),
            SizedBox(
              width: (MediaQuery.sizeOf(context).width - 32 - 24) / 4,
              child: _mediaTile(theme, Icons.music_note_rounded,
                  _song == null ? '音乐' : '已选歌', onTap: _pickSong),
            ),
          ]),
          if (_song != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                Icon(Icons.music_note_rounded, size: 16,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Expanded(child: Text(
                    '${_song!['title'] ?? ''} · ${_song!['artist'] ?? ''}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall)),
                IconButton(
                    tooltip: '移除歌曲', iconSize: 18,
                    onPressed: () => setState(() => _song = null),
                    icon: const Icon(Icons.close_rounded)),
              ]),
            ),
          // 录音状态行（录制中=暂停/完成/取消，暂停中=继续/完成/取消；
          // 入口已由上方「录音」tile 承担——2.4.1 第 12 项④只换容器）。
          if (_recState != _recIdle)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              Icon(Icons.mic_rounded, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('录音', style: theme.textTheme.bodyMedium),
              const Spacer(),
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
          // 2.4.1 第 12 项⑤：相册分类改选择框 + 底部选择单（每行相册
          // 选中打勾，第一行「暂不分类」）。
          if (_albums.isNotEmpty || _albumsLoading)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                InkWell(
                  key: const Key('composer-album-field'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: _albumsLoading
                      ? null
                      : () async {
                          final picked = await showSelectionSheet<String>(
                            context: context,
                            title: '相册分类',
                            selected: _album ?? '',
                            options: [
                              const SelectionOption(
                                  value: '', label: '暂不分类'),
                              for (final a in _albums)
                                SelectionOption(
                                    value: a.id, label: a.title),
                            ],
                          );
                          if (picked != null) _selectAlbum(picked);
                        },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(children: [
                      Text('相册', style: theme.textTheme.labelSmall),
                      const Spacer(),
                      Flexible(
                        child: Text(_albumLabel(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium),
                      ),
                      const SizedBox(width: 6),
                      Icon(AppIcons.chevronRight,
                          size: 18, color: theme.colorScheme.outline),
                    ]),
                  ),
                ),
                if (_albumsLoading)
                  Padding(
                    padding: const EdgeInsets.only(top: Spacing.xs),
                    child: Text('加载相册中…',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.outline)),
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
          // 2.4.1 第 12 项⑥：底部动作移入玻璃操作栏（存草稿 1/3 描边、
          // 发布/保存修改 2/3 实心；编辑态整行）；键盘电梯沿用外层
          // Padding(viewInsets) 电梯，只换皮不换骨。
          GlassActionBar(
            safeAreaBottom: false,
            cancelLabel: widget.isEdit ? null : '存草稿',
            onCancel: _draftSaving ? null : _saveDraft,
            saveLabel: widget.isEdit ? '保存修改' : '发布',
            // 2.4.10：发布/保存走三连变（对勾驻留 1s 后由
            // onMorphSuccess 关弹层）；busy 只服务存草稿。
            onSave: () {},
            morphOnSave: _submit,
            onMorphSuccess: () => Navigator.of(context).pop(),
            busy: _draftSaving,
          ),
        ]),
      ),
    );
  }

  String _albumLabel() {
    if (_albumsLoading) return '加载中…';
    if (_album == null) return '暂不分类';
    for (final a in _albums) {
      if (a.id == _album) return a.title;
    }
    return '暂不分类';
  }

  /// 媒体入口 tile（图标上文字下、淡紫底 + 紫描边）。
  Widget _mediaTile(ThemeData theme, IconData icon, String label,
      {required VoidCallback? onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.45)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(height: 4),
            Text(label,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.primary)),
          ],
        ),
      ),
    );
  }

  String _fmtDuration(Duration d) =>
    '${d.inMinutes.toString().padLeft(2, '0')}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  List<Widget> _buildMediaList(ThemeData theme) {
    return [
      const SizedBox(height: Spacing.gap),
      for (var i = 0; i < _media.length; i++)
        Container(
          key: ValueKey('composer-media-$i'),
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Row(children: [
            // 2.8.4 缺陷一：预览区与新建态同形态（图片缩略图 / 视频封面 /
            // 音频可试听），不再只给一个「token 芯片」
            _mediaThumb(_media[i], theme),
            const SizedBox(width: 10),
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

  /// 附件预览块（56×56）。已有媒体按 MIME 分三态：图片→缩略图+全屏查看、
  /// 视频→封面+播放页、音频→试听按钮；本地新选且是图片时直接读文件预览。
  Widget _mediaThumb(ComposerMedia m, ThemeData theme) {
    const size = 56.0;
    final id = (m.uploadedId ?? '').trim();
    final mime = m.mime.isNotEmpty ? m.mime : _mimeFromName(m.localFile.name);

    Widget box(Widget child) => ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: SizedBox(width: size, height: size, child: child),
        );

    if (id.isNotEmpty) {
      if (mime.startsWith('video/')) {
        return box(VideoCardView(mid: id, size: size));
      }
      if (mime.startsWith('audio/')) {
        return box(_ComposerAudioTile(mid: id));
      }
      // 图片；MIME 缺失时也按图片试（错了有占位兜底），至少比 token 强
      // 用 GestureDetector 而非 InkWell：缩略图只有 56×56，涟漪意义不大，
      // 且 InkWell 会拉 shaders/ink_sparkle（无资源环境下测试必炸）
      return box(GestureDetector(
        key: ValueKey('composer-media-open-$id'),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => ImageViewerPage(
            images: <ChatMedia>[
              ChatMedia(id: id, name: m.localFile.name, mime: mime),
            ],
          ),
        )),
        child: MediaImageView(mid: id, size: size),
      ));
    }

    // 本地新选（还没上传）：图片读文件，其余给类型图标
    if (m.localFile.path.isNotEmpty && mime.startsWith('image/')) {
      return box(Image.file(File(m.localFile.path),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _thumbPlaceholder(theme, Icons.image_outlined)));
    }
    return box(_thumbPlaceholder(
        theme, mime.startsWith('video/') ? Icons.videocam_outlined : Icons.attach_file_rounded));
  }

  Widget _thumbPlaceholder(ThemeData theme, IconData icon) => Container(
        color: theme.colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(icon, size: 20, color: theme.colorScheme.outline),
      );

  /// 只有本地文件名可用时按扩展名猜 MIME（新建态场景兜底）。
  String _mimeFromName(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.jpg') || n.endsWith('.jpeg') || n.endsWith('.png') ||
        n.endsWith('.gif') || n.endsWith('.webp') || n.endsWith('.heic')) {
      return 'image/*';
    }
    if (n.endsWith('.mp4') || n.endsWith('.mov') || n.endsWith('.m4v') ||
        n.endsWith('.webm')) {
      return 'video/*';
    }
    if (n.endsWith('.m4a') || n.endsWith('.mp3') || n.endsWith('.aac') ||
        n.endsWith('.wav') || n.endsWith('.ogg')) {
      return 'audio/*';
    }
    return '';
  }
}

/// 编辑态音频附件的试听块：点击走全局语音播放器（与聊天气泡同一套控制器，
/// 互斥播放由控制器保证）。
class _ComposerAudioTile extends ConsumerWidget {
  const _ComposerAudioTile({required this.mid});
  final String mid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(voicePlaybackProvider);
    final playing = st.playing && st.playingMid == mid;
    return InkWell(
      key: ValueKey('composer-media-audio-$mid'),
      onTap: () => ref.read(voicePlaybackProvider.notifier).toggle(mid),
      child: Container(
        color: Theme.of(context).colorScheme.primaryContainer,
        alignment: Alignment.center,
        child: Icon(
          playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
          size: 26,
          color: Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}
