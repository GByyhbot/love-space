/// 聊天数据模型（对齐服务端 records kind='chat' 的实际返回形态）。
/// 字段依据 api-samples/03-records.md + app/main.py 实读：
/// · body: content / media[](媒体 id) / sticker / reply_to{id,text} / pinned /
///         recalled（服务端撤回时写入并清空 content）/ location{lat,lng} / song{...}
/// · record 顶层 media[]：{id,name,mime,size,status,preview}（preview 可为 null）
/// 段一渲染边界：媒体/贴纸/歌曲/位置/引用只渲染中性占位，绝不能崩（完整渲染在段二/三）。
library;

/// 附件（record.media[] 元素；与 /api/media 返回形态一致）
class ChatMedia {
  const ChatMedia({
    this.id = '',
    this.name = '',
    this.mime = '',
    this.size = 0,
    this.status = '',
    this.preview = '',
  });
  final String id;
  final String name;
  final String mime;
  final int size;

  /// 服务端 worker 异步转码状态：pending / processing / ready / original
  final String status;
  final String preview;

  factory ChatMedia.fromJson(Map<String, dynamic> j) => ChatMedia(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        // mime 归一小写：服务端理论下发小写，但历史数据/上游兼容层不可信
        // （低危备忘 E3：全部判定处统一 lowercase 后比较）
        mime: (j['mime'] ?? '').toString().toLowerCase(),
        size: (j['size'] as num?)?.toInt() ?? 0,
        status: (j['status'] ?? '').toString(),
        preview: (j['preview'] ?? '').toString(),
      );

  /// 自定义表情两形态（段二判定复用；mime 已在 fromJson 归一小写）
  bool get isCustomStickerMedia =>
      mime == 'image/webp' || mime == 'video/webm';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mime': mime,
        'size': size,
        'status': status,
        'preview': preview.isEmpty ? null : preview,
      };

  /// 段一占位文案：按 mime 分流（图片/视频/语音/未知附件）
  String get placeholderLabel {
    if (mime.startsWith('image/')) return '[图片]';
    if (mime.startsWith('video/')) return '[视频]';
    if (mime.startsWith('audio/')) return '[语音]';
    return '[附件]';
  }
}

/// 位置消息（body.location = {lat, lng}）
class ChatLocation {
  const ChatLocation({required this.lat, required this.lng});
  final double lat;
  final double lng;

  @override
  bool operator ==(Object other) =>
      other is ChatLocation && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);
}

/// 分享的歌（body.song = {title,artist,mid,src,art,dur}）
class ChatSong {
  const ChatSong({
    this.title = '',
    this.artist = '',
    this.mid = '',
    this.src = '',
    this.art = '',
    this.dur = 0,
  });
  final String title;
  final String artist;
  final String mid;
  final String src;
  final String art;
  final double dur;

  factory ChatSong.fromJson(Map<String, dynamic> j) => ChatSong(
        title: (j['title'] ?? '').toString(),
        artist: (j['artist'] ?? '').toString(),
        mid: (j['mid'] ?? '').toString(),
        src: (j['src'] ?? '').toString(),
        art: (j['art'] ?? '').toString(),
        dur: (j['dur'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'artist': artist,
        'mid': mid,
        'src': src,
        'art': art,
        'dur': dur,
      };

  @override
  bool operator ==(Object other) =>
      other is ChatSong &&
      other.title == title &&
      other.artist == artist &&
      other.mid == mid &&
      other.src == src &&
      other.art == art &&
      other.dur == dur;

  @override
  int get hashCode => Object.hash(title, artist, mid, src, art, dur);
}

/// 聊天消息 body（服务端 clean_body 白名单内的字段，缺失一律容错为默认值）
class ChatBody {
  const ChatBody({
    this.content = '',
    this.title = '',
    this.mediaIds = const [],
    this.sticker,
    this.replyToId,
    this.replyToText,
    this.pinned = false,
    this.recalled = false,
    this.location,
    this.song,
  });
  final String content;

  /// kind=music 等的标题字段（聊天 body 里通常没有；通用解析容错）
  final String title;
  final List<String> mediaIds;
  final String? sticker;
  final String? replyToId;
  final String? replyToText;

  /// 置顶标记（段一忽略置顶栏渲染，但保留字段供对账更新）
  final bool pinned;

  /// 服务端撤回时写入 true 并清空 content（app/main.py recall_record）
  final bool recalled;
  final ChatLocation? location;
  final ChatSong? song;

  factory ChatBody.fromJson(Map<String, dynamic> j) {
    final reply = j['reply_to'];
    final loc = j['location'];
    final song = j['song'];
    return ChatBody(
      content: (j['content'] ?? '').toString(),
      title: (j['title'] ?? '').toString(),
      mediaIds: ((j['media'] ?? const []) as List).map((e) => e.toString()).toList(),
      sticker: j['sticker']?.toString(),
      replyToId: reply is Map ? (reply['id'] ?? '').toString() : null,
      replyToText: reply is Map ? (reply['text'] ?? '').toString() : null,
      pinned: j['pinned'] == true,
      recalled: j['recalled'] == true,
      location: loc is Map && loc['lat'] is num && loc['lng'] is num
          ? ChatLocation(lat: (loc['lat'] as num).toDouble(), lng: (loc['lng'] as num).toDouble())
          : null,
      song: song is Map ? ChatSong.fromJson(song.cast<String, dynamic>()) : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'content': content,
        if (title.isNotEmpty) 'title': title,
        'media': mediaIds,
        if (sticker != null) 'sticker': sticker,
        if (replyToId != null)
          'reply_to': {'id': replyToId, 'text': replyToText ?? ''},
        if (pinned) 'pinned': true,
        if (recalled) 'recalled': true,
        if (location != null)
          'location': {'lat': location!.lat, 'lng': location!.lng},
        if (song != null) 'song': song!.toJson(),
      };
}

/// kind='chat' 的记录（服务端统一 records 模型的聊天投影）
class ChatRecord {
  const ChatRecord({
    required this.id,
    required this.author,
    required this.created,
    required this.updated,
    required this.body,
    this.clientId = '',
    this.media = const [],
  });
  final String id;
  final String author;
  final double created;
  final double updated;
  final ChatBody body;
  final String clientId;
  final List<ChatMedia> media;

  factory ChatRecord.fromJson(Map<String, dynamic> j) => ChatRecord(
        id: (j['id'] ?? '').toString(),
        author: (j['author'] ?? '').toString(),
        created: (j['created'] as num?)?.toDouble() ?? 0,
        updated: (j['updated'] as num?)?.toDouble() ?? 0,
        body: ChatBody.fromJson(((j['body'] ?? const {}) as Map).cast<String, dynamic>()),
        clientId: (j['client_id'] ?? '').toString(),
        media: ((j['media'] ?? const []) as List)
            .whereType<Map>()
            .map((m) => ChatMedia.fromJson(m.cast<String, dynamic>()))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'author': author,
        'created': created,
        'updated': updated,
        'client_id': clientId,
        'body': body.toJson(),
        'media': media.map((m) => m.toJson()).toList(),
      };

  /// 渲染是否与 [o] 相同（对账合并时判断既有行是否需要原地更新）。
  /// 以 updated 时间戳 + 影响渲染的全部字段为准：撤回/置顶/引用变化都会推 updated。
  bool rendersSameAs(ChatRecord o) =>
      id == o.id &&
      author == o.author &&
      created == o.created &&
      updated == o.updated &&
      clientId == o.clientId &&
      body.recalled == o.body.recalled &&
      body.pinned == o.body.pinned &&
      body.content == o.body.content &&
      body.title == o.body.title &&
      body.sticker == o.body.sticker &&
      body.replyToId == o.body.replyToId &&
      body.replyToText == o.body.replyToText &&
      body.location == o.body.location &&
      body.song == o.body.song &&
      _listEq(body.mediaIds, o.body.mediaIds) &&
      _listEq(media.map((m) => m.id), o.media.map((m) => m.id)) &&
      _listEq(media.map((m) => m.status), o.media.map((m) => m.status));

  static bool _listEq(Iterable<String> a, Iterable<String> b) {
    if (a.length != b.length) return false;
    final bi = b.iterator;
    for (final x in a) {
      if (!bi.moveNext() || bi.current != x) return false;
    }
    return true;
  }

  /// 段一渲染行（纯文本 + 中性占位；不含撤回态——撤回行由页面单独渲染）。
  /// 媒体/贴纸/歌曲/位置/引用绝不抛异常：一律占位字符串。
  List<String> placeholderLines() {
    final b = body;
    final lines = <String>[];
    if (b.content.trim().isNotEmpty) lines.add(b.content);
    if (b.replyToId != null) {
      final text = (b.replyToText ?? '').trim();
      lines.add(text.isEmpty ? '[引用]' : '[引用] $text');
    }
    for (final m in media) {
      if (m.id.isNotEmpty) lines.add(m.placeholderLabel);
    }
    // body.media 引用了但顶层 media 缺项时按数量补占位（兜底，绝不丢行）
    if (b.mediaIds.length > media.where((m) => m.id.isNotEmpty).length) {
      lines.add('[附件]');
    }
    if (b.sticker != null) lines.add('[贴纸]');
    if (b.song != null && b.song!.title.isNotEmpty) lines.add('[歌曲] ${b.song!.title}');
    if (b.location != null) lines.add('[位置]');
    return lines;
  }
}

/// 待发媒体的本机文件引用（pending 队列里媒体先传后发：上传失败可重试重传）
class ChatLocalFile {
  const ChatLocalFile({required this.path, required this.name});
  final String path; // 本机绝对路径（重试时重新读取上传）
  final String name;

  Map<String, dynamic> toJson() => {'path': path, 'name': name};

  factory ChatLocalFile.fromJson(Map<String, dynamic> j) => ChatLocalFile(
        path: (j['path'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
      );
}

/// pending 发送阶段：upload=媒体上传中（气泡可见进度）/ send=记录 POST 中
enum ChatPendingPhase { upload, send }

/// 待发消息（pending 队列；等价 Web localStorage['pending-chat:<uid>']）
class ChatPending {
  const ChatPending({
    required this.clientId,
    required this.content,
    required this.createdAt,
    this.failed = false,
    this.mediaFiles = const [],
    this.phase = ChatPendingPhase.send,
    this.mediaIds = const [],
  });
  final String clientId;
  final String content;
  final double createdAt;
  final bool failed;

  /// 纯文本发送为空；媒体发送时为本机待传文件（重试重新上传）
  final List<ChatLocalFile> mediaFiles;
  final ChatPendingPhase phase;

  /// 已上传完成的媒体 id（phase=send 时存在；重试直接发记录零重传，低危备忘 E1）
  final List<String> mediaIds;
}

// ── 段二：气泡渲染视觉解析（纯函数，可单测）────────────────────────────

/// 单条聊天记录的渲染形态（段二媒体渲染取代段一占位的判定核心）
class ChatVisual {
  const ChatVisual({
    this.textLines = const [],
    this.imageMids = const [],
    this.videoMids = const [],
    this.voiceMids = const [],
    this.sticker,
    this.song,
    this.location,
    this.quote,
  });

  /// 文本行（含「[引用] …」占位行——引用跳转属段三）
  final List<String> textLines;

  /// 图片媒体（/media/{mid}?preview=true，带 Cookie）
  final List<String> imageMids;
  final List<String> videoMids;

  /// 语音媒体（voice chip，时长 + 点击整 chip 播放，对齐 Web voice-chip）
  final List<String> voiceMids;

  /// 非 null → 整条渲染为贴纸（无气泡；对齐 Web chat-sticker）
  final ChatStickerVisual? sticker;

  /// 非 null → 整条渲染为歌卡（段三；对齐 Web songCard 分支优先于贴纸）
  final ChatSong? song;

  /// 非 null → 整条渲染为位置卡片（段三）
  final ChatLocation? location;

  /// 引用块（段三升级：可点跳回原消息+高亮；id + 原文）
  final (String, String)? quote;

  bool get isEmpty =>
      textLines.isEmpty &&
      imageMids.isEmpty &&
      videoMids.isEmpty &&
      voiceMids.isEmpty &&
      sticker == null &&
      song == null &&
      location == null &&
      quote == null;
}

/// 贴纸视觉参数：内置包走公开静态路径（无需 Cookie），自定义表情走媒体 id（需 Cookie）
class ChatStickerVisual {
  const ChatStickerVisual({this.path, this.mid, required this.isVideo});
  final String? path; // /static/stickers/<包>/<序号>.<ext>
  final String? mid; // 自定义表情的媒体 id
  final bool isVideo; // .webm → 循环视频；否则静态图
}

/// 渲染判定（对齐 static/chat.js chatRows + mediaMarkup 的分流）：
/// · body.sticker → 贴纸（.webm 视频 / 其余静态图；公开静态无需 Cookie）；
/// · body.media 单张且 mime 为 image/webp 或 video/webm 且无文本 → 自定义表情贴纸；
/// · 其余 media 按 mime 分图片/视频/语音；文本（含引用占位）进 textLines。
ChatVisual chatVisualOf(ChatRecord r) {
  if (r.body.recalled) return const ChatVisual();
  final b = r.body;
  // 分支优先级对齐 Web chatRows：songCard → locCard → sticker → 文本+媒体
  final quote = b.replyToId != null ? (b.replyToId!, (b.replyToText ?? '')) : null;
  if (b.song != null && b.song!.title.isNotEmpty) {
    return ChatVisual(quote: quote, song: b.song);
  }
  if (b.location != null) {
    return ChatVisual(quote: quote, location: b.location);
  }
  if (b.sticker != null) {
    return ChatVisual(
      sticker: ChatStickerVisual(
          path: b.sticker, isVideo: b.sticker!.endsWith('.webm')),
    );
  }
  final visual = ChatVisual(
    textLines: [if (b.content.trim().isNotEmpty) b.content],
    imageMids: [],
    videoMids: [],
    voiceMids: [],
    quote: quote,
  );
  // 自定义表情：单媒体 webp/webm 且无文本 → 贴纸化渲染（对齐 Web sticker-send 发送形态）
  final isCustomSticker =
      b.content.trim().isEmpty && b.replyToId == null && b.mediaIds.length == 1 && r.media.length == 1;
  if (isCustomSticker) {
    final m = r.media.single;
    if (m.isCustomStickerMedia) {
      return ChatVisual(
        sticker: ChatStickerVisual(mid: m.id, isVideo: m.mime == 'video/webm'),
      );
    }
  }
  for (final m in r.media) {
    if (m.id.isEmpty) continue;
    if (m.mime.startsWith('image/')) {
      visual.imageMids.add(m.id);
    } else if (m.mime.startsWith('video/')) {
      visual.videoMids.add(m.id);
    } else if (m.mime.startsWith('audio/')) {
      visual.voiceMids.add(m.id);
    } else {
      visual.textLines.add(m.placeholderLabel);
    }
  }
  return visual;
}

// ── 段三：消息操作纯函数（可单测）────────────────────────────────────

/// 引用文本截断（对齐 Web：reply_to.text 存「当时那句话」slice(0,60)——
/// UTF-16 码元口径，与 JS slice 一致；中文等 BMP 字符计数相同）
String quoteSnippet(String text, {int max = 60}) {
  final t = text.trim();
  if (t.length <= max) return t.isEmpty ? '原消息' : t;
  return '${t.substring(0, max)}…';
}

/// 撤回资格：仅本人、2 分钟窗口内（服务端 app/main.py recall_record 同口径：
/// now() - created > 120 拒绝），已撤回的不再显示撤回项
bool canRecallChat(ChatRecord r, String myId, {DateTime Function()? now}) {
  if (r.author != myId || r.body.recalled) return false;
  final n = (now ?? DateTime.now)();
  final created = DateTime.fromMillisecondsSinceEpoch((r.created * 1000).round());
  return n.difference(created).inSeconds <= 120;
}

/// 置顶栏数据（对齐 Web messagesPage 的 pinned 口径：pinned 且未撤回，
/// created 降序取最新一条 + 总数）
({ChatRecord latest, int total})? pinnedBarInfo(List<ChatRecord> records) {
  final pinned = records
      .where((r) => r.body.pinned && !r.body.recalled)
      .toList()
    ..sort((a, b) => b.created.compareTo(a.created));
  if (pinned.isEmpty) return null;
  return (latest: pinned.first, total: pinned.length);
}

/// 置顶栏摘要（对齐 Web：content slice(0,42) 码元口径，空内容显「一条附件」）
String pinnedBarText(ChatRecord r) {
  final c = r.body.content.trim();
  if (c.isNotEmpty) {
    return c.length <= 42 ? c : '${c.substring(0, 42)}…';
  }
  return '一条附件';
}
