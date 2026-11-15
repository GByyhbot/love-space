/// 「数据管理与通知渠道」章 · 段 C · 2.2.7 / VC227：完整备份与存储占用。
///
/// 契约（`docs/data-notification-plan.md` §3.6 / §3.7、D4/D5、第五节 C 行，
/// 后端 `main.py` 四端点逐条附行号）：
/// · `GET /api/storage` `:2693-2724` → 仅 admin；`total/media_by_kind/
///   media_by_month/db/backups/disk_free/disk_total/record_count/media_count`。
///   `db` 含 love.db + wal + **period.db + period.db-wal** `:2711-2715`；
///   `record_count` = 主库未删 + **period.count_active()** `:2718`。
///   🔴 客户端**只呈现服务端下发数字，不估算/不补算**（`backups_size` 只
///   glob `*.zip`、加密产物 `.zip.enc` 的已知缺口由服务端承担，见 U12）。
/// · `GET /api/backups` `:2727-2733` → 仅 admin；`[{name,size,created,encrypted}]`。
/// · `POST /api/backups` `:2676-2690` → 仅 admin；成功 `{'name':...}`；
///   未配 `BACKUP_PASSWORD` → **503 原文**「服务器未配置备份密码，已拒绝
///   生成明文备份；请联系管理员设置 BACKUP_PASSWORD」`:2684-2685`。
/// · `GET /api/backups/{name}` `:2736-2743` → 仅 admin；2xx = zip bytes。
///
/// 🔴 错误通道纪律（`api_client.dart:279` `validateAppStatus(s)=s<500`）：
/// 4xx 被当作「成功 Response」放行 → 每个请求**显式判 2xx**，4xx 用
/// `writeResponseError(r)` 取服务端 `detail` 原文；POST 的 503（>=500）会
/// 被 Dio 抛 `DioException(badResponse)` → `errorDetail(e)` 取
/// `e.response.data`（JSON Map）里的 detail 原文，不包装、不吞、不假成功。
///
/// 承接（D3/D4）：备份下载**复用段 B 落盘范式** `export_api.dart` 的
/// [saveBytesResponse] / [sanitizeFilename] / [exportReceiveTimeout] /
/// [SavedExport]，禁止另写一套；**不引新依赖**。
library;

import 'dart:io';

import 'package:dio/dio.dart';

import '../../core/api/api_client.dart' as api;
import 'export_api.dart';

// ── 逐字文案（对齐 Web `app.js:1500` `backupsPage()` / `:1482` 入口） ────

/// `/settings` 数据导出卡第 4 行 admin 入口文案（`app.js:1482` 逐字）。
const String backupsEntryLabel = '完整备份与存储占用';

/// 页面 AppBar 标题（App 二级页标题口径）。
const String backupsPageTitle = '完整备份与存储占用';

/// Web heading 主标题（`app.js:1500` 逐字）。
const String backupsHeading = '让回忆，有一个安心的家';

/// Web heading 副标题（`app.js:1500` 逐字）。
const String backupsSubtitle = '完整备份、迁移和恢复。';

/// 顶部动作按钮（`app.js:1500` heading 动作逐字）。
const String backupNowLabel = '立即备份';

/// 备份在途按钮文案（`_busy` 期间）。
const String backupBusyLabel = '备份中…';

/// 🔴 D5：恢复**只放说明，不放按钮、不做假入口**（后端无 HTTP 恢复端点）。
/// hint 逐字（`app.js:1500`）。
const String backupsHint =
    '每天自动备份，保留最近七份成功备份。完整备份包含双方数据与渠道密钥，'
    '仅供服务器管理员妥善保管。恢复操作通过服务器命令进行，并恢复到新的空目录。';

const String backupsEmptyTitle = '备份还未生成';
const String backupsEmptySubtitle = '可以现在创建第一份完整备份。';

/// 三类媒体中英映射（`app.js:1500` `kindBars` 逐字）。
const Map<String, String> mediaKindLabels = <String, String>{
  'image': '照片',
  'video': '视频',
  'audio': '语音',
};

// ── 数据模型（严格按服务端字段映射，不自补算） ─────────────────────────

/// `GET /api/storage` 响应。所有数字**逐字段照搬服务端**，不在客户端计算
/// total / db / record_count。
class StorageUsage {
  const StorageUsage({
    required this.total,
    required this.imageBytes,
    required this.videoBytes,
    required this.audioBytes,
    required this.db,
    required this.backups,
    required this.diskFree,
    required this.diskTotal,
    required this.recordCount,
    required this.mediaCount,
  });

  /// 服务端 `total`（已含 db/wal/period/backups，客户端不重算）。
  final num total;

  /// `media_by_kind.image`
  final num imageBytes;

  /// `media_by_kind.video`
  final num videoBytes;

  /// `media_by_kind.audio`
  final num audioBytes;

  /// 服务端 `db` = love.db + love.db-wal + period.db + period.db-wal。
  final num db;

  /// 服务端 `backups`（只 glob `*.zip`，加密 `.zip.enc` 的缺口由服务端承担）。
  final num backups;

  final num diskFree;
  final num diskTotal;

  /// 服务端 `record_count` = 主库未删 + period.count_active()。
  final int recordCount;

  final int mediaCount;

  /// 三类媒体之和（Web `Object.values(media_by_kind).reduce`）——只用于
  /// 媒体条宽比例，不参与存储数字呈现。
  num get mediaTotal => imageBytes + videoBytes + audioBytes;

  factory StorageUsage.fromJson(Map<String, dynamic> j) {
    final kinds = (j['media_by_kind'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    num kind(String k) => (kinds[k] as num?) ?? 0;
    return StorageUsage(
      total: (j['total'] as num?) ?? 0,
      imageBytes: kind('image'),
      videoBytes: kind('video'),
      audioBytes: kind('audio'),
      db: (j['db'] as num?) ?? 0,
      backups: (j['backups'] as num?) ?? 0,
      diskFree: (j['disk_free'] as num?) ?? 0,
      diskTotal: (j['disk_total'] as num?) ?? 0,
      recordCount: (j['record_count'] as num?)?.toInt() ?? 0,
      mediaCount: (j['media_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// `GET /api/backups` 列表项。`created` 是 epoch 秒（`st_mtime`，可能是
/// 浮点），[timelineDateLabel] 直接吃 double。
class BackupItem {
  const BackupItem({
    required this.name,
    required this.size,
    required this.created,
    required this.encrypted,
  });

  final String name;
  final num size;
  final double created;
  final bool encrypted;

  factory BackupItem.fromJson(Map<String, dynamic> j) => BackupItem(
        name: (j['name'] ?? '').toString(),
        size: (j['size'] as num?) ?? 0,
        created: (j['created'] as num?)?.toDouble() ?? 0,
        encrypted: j['encrypted'] == true,
      );
}

// ── Web 同口径格式化（期望值由 Node vm 实跑 `app.js` 生成，见 fixtures） ──

/// 与 Web `fmt` 逐字同公式（`app.js:1500`）：
/// `b>=1073741824?(b/1073741824).toFixed(2)+' GB':(b/1048576).toFixed(1)+' MB'`
String formatStorageSize(num b) {
  if (b >= 1073741824) {
    return '${(b / 1073741824).toStringAsFixed(2)} GB';
  }
  return '${(b / 1048576).toStringAsFixed(1)} MB';
}

/// 与 Web `pct` 逐字同公式（`app.js:1500`）：
/// `s.disk_total?Math.round((1-s.disk_free/s.disk_total)*100):0`
int storageUsedPercent(num diskFree, num diskTotal) {
  if (diskTotal == 0) return 0;
  return ((1 - diskFree / diskTotal) * 100).round();
}

/// 备份列表项大小（Web `(b.size/1024/1024).toFixed(2)} MB`）。
String formatBackupSize(num size) =>
    '${(size / 1024 / 1024).toStringAsFixed(2)} MB';

/// 媒体条宽百分比（Web `total?Math.round(v/total*100):0`，total 三类之和）。
int mediaKindPercent(num value, num mediaTotal) =>
    mediaTotal != 0 ? (value / mediaTotal * 100).round() : 0;

/// meta 行逐字结构（Web `app.js:1500`）：
/// `数据库 ${fmt(db)} · 备份 ${fmt(backups)} · ${record_count} 条记录 · ${media_count} 个媒体文件`
String storageMetaLine(StorageUsage s) =>
    '数据库 ${formatStorageSize(s.db)} · 备份 ${formatStorageSize(s.backups)} · '
    '${s.recordCount} 条记录 · ${s.mediaCount} 个媒体文件';

// ── 四端点请求封装（全部经共享 dio，不引新依赖） ───────────────────────

/// `GET /api/storage`。返回 `(usage, error)`；error 非 null 时 usage 为 null。
/// 4xx（403「需要管理员账号」）走 `writeResponseError` 取 detail 原文；
/// 5xx / 网络层 DioException 走 `errorDetail`。
Future<(StorageUsage?, String?)> fetchStorage(Dio dio) async {
  try {
    final r = await dio.get('/api/storage');
    final err = api.writeResponseError(r);
    if (err != null) return (null, err);
    return (StorageUsage.fromJson((r.data as Map).cast<String, dynamic>()),
        null);
  } catch (e) {
    return (null, api.errorDetail(e));
  }
}

/// `GET /api/backups`。4xx（403「需要管理员账号」）原文透传。
Future<(List<BackupItem>?, String?)> fetchBackups(Dio dio) async {
  try {
    final r = await dio.get('/api/backups');
    final err = api.writeResponseError(r);
    if (err != null) return (null, err);
    final list = ((r.data ?? const <Object>[]) as List)
        .whereType<Map>()
        .map((e) => BackupItem.fromJson(e.cast<String, dynamic>()))
        .toList();
    return (list, null);
  } catch (e) {
    return (null, api.errorDetail(e));
  }
}

/// `POST /api/backups`。返回 `(name, error)`；成功解析 `{'name':...}`。
/// 🔴 503（未配 BACKUP_PASSWORD）与 500 会被 Dio 抛
/// `DioException(badResponse)`（>=500）→ `errorDetail(e)` 取
/// `e.response.data`（JSON Map）里的 detail **原文**，不包装成自创文案、
/// 不吞成 genericErrorText。403（4xx，放行成 Response）走
/// `writeResponseError` 原文。
Future<(String?, String?)> createBackup(Dio dio) async {
  try {
    final r = await dio.post('/api/backups');
    final err = api.writeResponseError(r);
    if (err != null) return (null, err);
    return ((r.data as Map?)?['name']?.toString(), null);
  } catch (e) {
    return (null, api.errorDetail(e));
  }
}

/// `GET /api/backups/{name}`（bytes 下载）。
/// 复用段 B [saveBytesResponse]：显式判 4xx（403「无权访问」/ 404
/// 「备份不存在」→ bytes 错误体解码取 detail 原文、不落盘）→ 文件名
/// `Content-Disposition` 优先、回退列表项服务端下发的 [name] → 落
/// `downloads/`。逐请求 `receiveTimeout: 10min` 覆盖基座 20s。
Future<(SavedExport?, String?)> downloadBackup(
  Dio dio,
  String name, {
  Directory? downloadsDir,
}) async {
  try {
    final r = await dio.get<List<int>>(
      '/api/backups/${Uri.encodeComponent(name)}',
      options: Options(
        responseType: ResponseType.bytes,
        receiveTimeout: exportReceiveTimeout,
      ),
    );
    return await saveBytesResponse(
      r,
      fallbackName: sanitizeFilename(name) ?? name,
      downloadsDir: downloadsDir,
    );
  } catch (e) {
    return (null, api.errorDetail(e));
  }
}
