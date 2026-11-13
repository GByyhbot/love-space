/// Composer 表单本地暂存（条目 4 · 段二 · A3）。
/// 等价 Web localStorage：字段 + media + client_id 持久化，关弹层不丢、
/// 杀进程重开恢复；未传完媒体（uploadedId 为空）恢复时提示重选。
/// 落盘为应用文档目录下 JSON 单文件，随账号不区分（同一设备单账号场景）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 暂存文件名（应用文档目录）
const String composerStoreFilename = 'composer_draft.json';

/// 一条暂存媒体（本地文件 + 已上传 id）
class StoredMedia {
  const StoredMedia({
    required this.path,
    required this.name,
    this.uploadedId,
  });
  final String path;
  final String name;
  final String? uploadedId;

  Map<String, dynamic> toJson() => {
        'path': path,
        'name': name,
        if (uploadedId != null) 'uploadedId': uploadedId,
      };

  factory StoredMedia.fromJson(Map<String, dynamic> j) => StoredMedia(
        path: (j['path'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        uploadedId: j['uploadedId']?.toString(),
      );
}

/// composer 本地暂存结构
class ComposerStore {
  const ComposerStore({
    this.title = '',
    this.content = '',
    this.date = '',
    this.album,
    this.postClientId,
    this.draftClientId,
    this.media = const [],
  });

  final String title;
  final String content;
  final String date; // yyyy-MM-dd
  final String? album; // 相册 id；null/空=暂不分类
  final String? postClientId;
  final String? draftClientId;
  final List<StoredMedia> media;

  bool get isEmpty =>
      title.isEmpty && content.isEmpty && media.isEmpty && album == null;

  Map<String, dynamic> toJson() => {
        'title': title,
        'content': content,
        'date': date,
        if (album != null && album!.isNotEmpty) 'album': album,
        if (postClientId != null) 'postClientId': postClientId,
        if (draftClientId != null) 'draftClientId': draftClientId,
        'media': media.map((e) => e.toJson()).toList(),
      };

  factory ComposerStore.fromJson(Map<String, dynamic> j) => ComposerStore(
        title: (j['title'] ?? '').toString(),
        content: (j['content'] ?? '').toString(),
        date: (j['date'] ?? '').toString(),
        album: j['album']?.toString(),
        postClientId: j['postClientId']?.toString(),
        draftClientId: j['draftClientId']?.toString(),
        media: ((j['media'] ?? const []) as List)
            .whereType<Map>()
            .map((e) => StoredMedia.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );
}

/// 读取暂存；无文件或解析失败返回 null（不抛异常）
Future<ComposerStore?> readComposerStore() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}${Platform.pathSeparator}$composerStoreFilename');
    if (!await f.exists()) return null;
    final raw = await f.readAsString();
    final j = jsonDecode(raw);
    if (j is Map) return ComposerStore.fromJson(j.cast<String, dynamic>());
    return null;
  } catch (_) {
    return null;
  }
}

/// 写入暂存；失败不抛（下次再写）
Future<void> writeComposerStore(ComposerStore store) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}${Platform.pathSeparator}$composerStoreFilename');
    await f.writeAsString(jsonEncode(store.toJson()));
  } catch (_) {
    // 暂存落盘失败不阻断表单；下次变更再试
  }
}

/// 清空暂存（发布成功后调用）
Future<void> clearComposerStore() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}${Platform.pathSeparator}$composerStoreFilename');
    if (await f.exists()) await f.delete();
  } catch (_) {
    // 忽略
  }
}
