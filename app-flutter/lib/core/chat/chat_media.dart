/// 聊天媒体层（段二 · Step 5 两段式上传 + 媒体 URL）。
/// 契约（api-samples/04 + app/main.py 实读）：
/// · POST /api/media multipart 字段 file → {id, mime, name, status=pending}，
///   worker 异步转码 preview；422 魔数/损坏中文 detail 直通；
/// · GET /media/{mid}?preview=true 需 Cookie；status 未 ready 服务端回退原文件；
/// · GET /api/media/images?limit=300 → [{id,name,created}]（服务器媒体库，相册选择器）。
/// 本地预检（不发请求）：格式白名单 + 250MB 上限（MAX_UPLOAD_MB 默认 250）。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../api/api_client.dart';

/// 上传上限（服务端 MAX_UPLOAD_MB 默认 250；本地预检先行，超限不发请求）
const int maxUploadMb = 250;

/// 本地预检 / 链路校验失败的可读异常（message 直通 UI，不走 errorDetail 兜底文案）
class MediaValidationError implements Exception {
  const MediaValidationError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 上传大小上限（字节）
const int maxUploadBytes = maxUploadMb * 1024 * 1024;

/// 每条记录 body.media 上限（服务端白名单）
const int maxMediaPerRecord = 30;

/// 格式白名单（对齐方案 §阶段 4：图 jpg/png/webp/gif/heic、视频 mp4/mov/webm、
/// 音频 m4a/mp3/wav/aac/ogg/webm）；key=扩展名小写，value=声明 mime
const Map<String, String> uploadWhitelist = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp',
  'gif': 'image/gif',
  'heic': 'image/heic',
  'mp4': 'video/mp4',
  'mov': 'video/mov',
  'webm': 'video/webm',
  'm4a': 'audio/mp4',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'aac': 'audio/aac',
  'ogg': 'audio/ogg',
};

/// 本地预检：返回 null=通过；否则为中文错误文案（不发请求）
String? validateUploadFile(String filename, int sizeBytes) {
  final dot = filename.lastIndexOf('.');
  final ext = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
  if (!uploadWhitelist.containsKey(ext)) {
    return '暂不支持该格式，试试图片 / 视频 / 语音';
  }
  if (sizeBytes > maxUploadBytes) {
    return '文件超过 $maxUploadMb MB 上限，先压一压再发吧';
  }
  return null;
}

/// 扩展名 → 声明 mime（无白名单命中返回空串）
String mimeOfName(String filename) {
  final dot = filename.lastIndexOf('.');
  final ext = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
  return uploadWhitelist[ext] ?? '';
}

/// 上传单个媒体文件（multipart 字段 file；onSendProgress 进度回调 0..1）。
/// 返回服务端 {id, mime, name, status} 的 id；422/413 中文 detail 由调用方
/// errorDetail(e) 直通。
Future<String> uploadChatMedia(
  Dio dio,
  String filename,
  List<int> bytes, {
  void Function(double progress)? onProgress,
}) async {
  final form = FormData.fromMap({
    'file': MultipartFile.fromBytes(bytes, filename: filename),
  });
  final r = await dio.post('/api/media', data: form,
      onSendProgress: (sent, total) {
    if (onProgress != null && total > 0) onProgress(sent / total);
  });
  return ((r.data ?? const {}) as Map)['id'].toString();
}

/// 服务器媒体库图片列表项（GET /api/media/images）
class MediaLibraryItem {
  const MediaLibraryItem({
    required this.id,
    this.name = '',
    this.created = 0,
  });
  final String id;
  final String name;
  final double created;

  factory MediaLibraryItem.fromJson(Map<String, dynamic> j) => MediaLibraryItem(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        created: (j['created'] as num?)?.toDouble() ?? 0,
      );
}

/// 服务器媒体库（相册选择器数据源；只列图片，对齐 Web chatAlbumPick）
Future<List<MediaLibraryItem>> fetchMediaLibrary(Dio dio,
    {int limit = 300}) async {
  final r =
      await dio.get('/api/media/images', queryParameters: {'limit': limit});
  if (r.data is! List) return const [];
  return (r.data as List)
      .whereType<Map>()
      .map((e) => MediaLibraryItem.fromJson(e.cast<String, dynamic>()))
      .toList();
}

/// 媒体 URL 拼装（base 来自线路选择，禁止硬抄域名）
String mediaUrl(String base, String mid, {bool preview = true, bool poster = false}) {
  final params = <String>[];
  if (preview) params.add('preview=true');
  if (poster) params.add('poster=true');
  return '$base/media/$mid${params.isEmpty ? '' : '?${params.join('&')}'}';
}

/// 音乐试听/封面转发 URL（对齐 Web artSrcOf：`/api/music/stream?u=<encodeURIComponent>`）；
/// `/api/*` 需登录 Cookie，调用方带 mediaCookieHeadersProvider 的头
String musicStreamUrl(String base, String src) =>
    '$base/api/music/stream?u=${Uri.encodeQueryComponent(src)}';

/// 气泡皮肤图 URL（公开静态语义同 /static，无需 Cookie——Web 同款直挂 `<img>`）
String bubbleSkinUrl(String base, String packName) =>
    '$base/api/bubbles/$packName';

/// 共享 Cookie 头 Provider：cached_network_image 的 httpHeaders /
/// video_player 的 httpHeaders / just_audio 的 headers 全走这里。
/// 换线兜底：auth bootstrap 每次确定线路后 invalidate 重建（见 auth_state）。
final mediaCookieHeadersProvider = FutureProvider<Map<String, String>>((ref) async {
  final jar = await ref.watch(cookieJarProvider.future);
  final base = await ref.watch(baseProvider.future);
  final cookies = await jar.loadForRequest(Uri.parse('$base/'));
  final pairs = cookies
      .where((c) => c.name.isNotEmpty && c.value.isNotEmpty)
      .map((c) => '${c.name}=${c.value}')
      .join('; ');
  return {'Cookie': pairs};
});

/// base URL Provider（媒体 URL 拼装用）
final chatBaseProvider = FutureProvider<String>((ref) => ref.watch(baseProvider.future));

/// 音频「下载优先」缓存（歌单试听 / 聊天选歌卡 / 聊天歌曲卡共用）：
/// Dio **全量 GET（无 Range）** → 文档目录/song_cache/{cacheKey}.m4a → 本地路径。
/// 🔴 背景：中转线（iepose）对原生播放器的 Range 流式请求有已知缺陷（语音
/// 曾栽过），setUrl 直拉远程流在该线不可靠——一律先下载后播本地文件。
/// 命中缓存直接返回（在线 30s 试听片段约几百 KB，重复试听零下载）。
Future<String> downloadAudioToCache(
  Dio dio, {
  required String cacheKey,
  required String urlPath,
  Map<String, String> query = const {},
}) async {
  // 插件缺失/挂起兜底（测试环境 FakeAsync 下通道 Future 永不完成，必须
  // timeout 再回退；真机正常毫秒级返回）
  final docs = await getApplicationDocumentsDirectory()
      .timeout(const Duration(seconds: 3))
      .catchError((_) => Future<Directory>.value(Directory.systemTemp));
  final dir = Directory('${docs.path}${Platform.pathSeparator}song_cache');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final safeKey = cacheKey.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  final file = File('${dir.path}${Platform.pathSeparator}$safeKey.m4a');
  if (file.existsSync()) return file.path; // 命中缓存
  final r = await dio.get(urlPath, queryParameters: query,
      options: Options(responseType: ResponseType.bytes));
  final code = r.statusCode ?? 0;
  if (code < 200 || code >= 300) {
    throw Exception('HTTP $code');
  }
  final bytes = (r.data as List?)?.cast<int>() ?? const <int>[];
  if (bytes.isEmpty) throw Exception('空响应体');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
