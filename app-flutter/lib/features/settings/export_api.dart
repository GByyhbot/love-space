/// 数据导出三件（「数据管理与通知渠道」章 · 段 B · 2.2.6 / VC226）。
///
/// 三个端点契约（`docs/data-notification-plan.md` §3.5，逐条附行号）：
/// · `GET /api/export`（`main.py:2582`）→ zip，服务端名「我们的回忆.zip」，
///   限流 `rate_limit('export',10,300)`，含 period 且**明文**，恒生成。
/// · `GET /api/export/markdown`（`main.py:2592`）→ zip，
///   服务端名「恋爱空间-第二大脑-{YYYYMMDD}.zip」，**与 JSON 导出共用同一
///   限流桶**（同 action='export'），含 period 明文，恒生成。
/// · `GET /api/export/ics`（`main.py:2604`）→ 文本 `text/calendar`，名
///   「love-space-{YYYYMMDD}.ics」+ `filename*=UTF-8''我们的纪念日-{...}.ics`，
///   **无限流**；只含 anniversary/wish/quest、无 period；无内容 404
///   「还没有可导出的纪念日或计划」（`main.py:2667-2668`）。
///
/// 承接方式（D3 定案）：复用现有落盘范式（`album_viewer_page.dart:265-285`），
/// `dio.get(responseType: bytes)` → `downloads/` → 顶部通知报文件名；
/// **不引新依赖**（share_plus / open_file / permission_handler / dio.download 全不用）。
///
/// 🔴 7-C 错误通道：`validateAppStatus`（`api_client.dart:279`）会把 4xx 作为
/// 「成功 Response」放行，本模块必须**显式判 4xx**（2xx 才落盘）；bytes 错误体
/// 是 JSON bytes（`List<int>`），共享 `responseDetail()` 只认 Map/List，故先
/// `utf8.decode` → `jsonDecode` 再喂 `responseDetail`（助手在本文件内，
/// **共享代码不动**）。服务端 `detail` 原文透传（429/404 同样），不吞、不改写。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/api/api_client.dart' as api;

// ── 入口文案（逐字对齐 Web `app.js:1482` 数据管理卡） ──────────────────

/// Web `<a href="/api/export" download>` 的条目文案（逐字）。
const String exportRecordsLabel = '导出我有权查看的记录与原文件';

/// Web `<a href="/api/export/markdown" download>` 的条目文案（逐字）。
const String exportMarkdownLabel = '导出 Markdown 知识库（第二大脑）';

/// Web `<a href="/api/export/ics" download>` 的条目文案（逐字）。
const String exportIcsLabel = '导出日历 .ics（纪念日与计划）';

/// Web 数据管理卡 small-note（逐字；段 C 的存储摘要条与 admin 完整备份
/// 按定案不在本段，文案里「完整备份由服务器管理员管理」属说明而非入口）。
const String exportCardNote =
    '第二大脑是纯 Markdown 文件夹，可拖进 Obsidian / Logseq，也可直接给 AI 当'
    '长期记忆；只含你自己可见的内容，个人心愿只导出标题。私密日记按账号隔离，'
    '完整备份由服务器管理员管理。日历文件导进手机自带日历后，纪念日就能用系统'
    '提醒，比站内推送更稳。';

/// `/settings` 数据导出卡标题（主人指令原话「数据导出」）。
const String exportCardTitle = '数据导出';

// ── 端点规格 ──────────────────────────────────────────────────────────

/// 三个导出端点。
enum ExportKind { records, markdown, ics }

/// 端点规格（路径 / 回退名口径）。
class ExportSpec {
  const ExportSpec({
    required this.kind,
    required this.path,
    required this.sharedRateLimit,
  });

  final ExportKind kind;

  /// 相对 baseUrl 的请求路径。
  final String path;

  /// 是否与其它导出共用 `rate_limit('export',10,300)` 桶
  /// （records/markdown 共用、ics 无限流——连撞 429 的风险面）。
  final bool sharedRateLimit;
}

const Map<ExportKind, ExportSpec> exportSpecs = <ExportKind, ExportSpec>{
  ExportKind.records: ExportSpec(
    kind: ExportKind.records,
    path: '/api/export',
    sharedRateLimit: true,
  ),
  ExportKind.markdown: ExportSpec(
    kind: ExportKind.markdown,
    path: '/api/export/markdown',
    sharedRateLimit: true,
  ),
  ExportKind.ics: ExportSpec(
    kind: ExportKind.ics,
    path: '/api/export/ics',
    sharedRateLimit: false,
  ),
};

/// 全量导出比普通请求重得多：基座 `buildDio` 的 `receiveTimeout` 只有 20s
/// （`api_client.dart:285`），大空间必超时 —— 导出请求逐请求放宽到 10 分钟。
const Duration exportReceiveTimeout = Duration(minutes: 10);

/// 客户端回退名的日期戳：服务端 ics 用空间时区（`main.py:2671`）、markdown
/// 用服务器本地时区，客户端拿不到时区配置，按定案统一用 UTC+8（空间时区
/// 默认 `Asia/Shanghai`）生成同格式 stamp。
String exportStampUtc8(DateTime now) {
  final t = now.toUtc().add(const Duration(hours: 8));
  final m = t.month.toString().padLeft(2, '0');
  final d = t.day.toString().padLeft(2, '0');
  return '${t.year}$m$d';
}

/// 解析不到 `Content-Disposition` 头时的客户端回退名（与 Web 侧同一格式）。
String exportFallbackName(ExportKind kind, DateTime now) {
  switch (kind) {
    case ExportKind.records:
      // `main.py:2588` FileResponse filename='我们的回忆.zip'（无日期戳）
      return '我们的回忆.zip';
    case ExportKind.markdown:
      // `main.py:2597` f'恋爱空间-第二大脑-{stamp}.zip'
      return '恋爱空间-第二大脑-${exportStampUtc8(now)}.zip';
    case ExportKind.ics:
      // `main.py:2672` f'love-space-{stamp_name}.ics'
      return 'love-space-${exportStampUtc8(now)}.ics';
  }
}

// ── Content-Disposition 文件名解析（含 RFC 5987 filename*） ────────────

/// `filename*=UTF-8''xxx`（charset 可大小写；服务端 Starlette 用小写
/// `utf-8''`，`main.py:2673` 用大写 `UTF-8''`）。
final RegExp _filenameStarRegex = RegExp(
  r"filename\*\s*=\s*([^']*)''([^;]+)",
  caseSensitive: false,
);

/// `filename="xxx"` 或 `filename=xxx;`。
final RegExp _filenamePlainRegex = RegExp(
  r'filename\s*=\s*(?:"([^"]+)"|([^";]+))',
  caseSensitive: false,
);

/// 从 `Content-Disposition` 头解析文件名；`filename*`（RFC 5987）优先于
/// `filename`（UTF-8 权威名）；解析失败 / 落空返回 null（走回退名）。
String? parseContentDispositionFilename(String? header) {
  if (header == null || header.trim().isEmpty) return null;
  final star = _filenameStarRegex.firstMatch(header);
  if (star != null) {
    final raw = (star.group(2) ?? '').trim();
    if (raw.isNotEmpty) {
      try {
        // %XX 百分号转义（UTF-8），Uri.decodeComponent 即等价 RFC 5987 解码
        final decoded = Uri.decodeComponent(raw);
        if (decoded.isNotEmpty) return decoded;
      } catch (_) {
        // 🔴 非法转义抛 ArgumentError（非 FormatException）——解码失败一律
        // 退回 filename= 普通字段，不能崩
      }
    }
  }
  final plain = _filenamePlainRegex.firstMatch(header);
  if (plain != null) {
    final raw = (plain.group(1) ?? plain.group(2) ?? '').trim();
    if (raw.isNotEmpty) return raw;
  }
  return null;
}

/// 落盘安全兜底：去掉路径分隔符与控制字符（Android 私有目录无需再严格，
/// 但解析自响应头的外部输入必须防路径穿越）。
String? sanitizeFilename(String? name) {
  if (name == null) return null;
  final cleaned = name
      .replaceAll(RegExp(r'[\\/:\x00-\x1f]'), '_')
      .trim();
  return cleaned.isEmpty ? null : cleaned;
}

// ── bytes 错误体 → detail 原文（共享 responseDetail 不动，助手本文件内） ──

/// bytes 响应的错误体是 JSON bytes（`List<int>`），共享 `responseDetail()`
/// （`api_client.dart:314-321`）只认 Map/List —— 先 `utf8.decode` →
/// `jsonDecode` 再喂它。形状照 `writeResponseError` 的取文案逻辑，但**不为
/// bytes 改共享本体**。拿不到原文返回 null（调用方兜底 genericErrorText）。
String? bytesResponseDetail(Object? data) {
  // 🔴 顺序敏感：Uint8List 也是 List（`is List` 命中），必须先认 JSON 解码
  // 形状（Map / List+Map），再认 bytes 形状（Uint8List extends List<int>）
  if (data is Map) return api.responseDetail(data);
  if (data is List && data.isNotEmpty && data.first is Map) {
    return api.responseDetail(data);
  }
  if (data is List<int>) {
    try {
      return api.responseDetail(jsonDecode(utf8.decode(data)));
    } catch (_) {
      return null;
    }
  }
  if (data is String && data.isNotEmpty) {
    // dio 个别路径会把 bytes 按文本解码兜住，同样先 jsonDecode
    try {
      return api.responseDetail(jsonDecode(data));
    } catch (_) {
      return null;
    }
  }
  return null;
}

// ── 下载 + 4xx 显式判 + 落盘 ──────────────────────────────────────────

/// 落盘结果：通知里报的文件名与实际落盘文件名**同源**（同一字符串）。
class SavedExport {
  const SavedExport({required this.path, required this.filename});

  /// 完整落盘路径。
  final String path;

  /// 文件名（toast 报 `downloads/<filename>`，与 [path] 末段一致）。
  final String filename;
}

/// 导出下载统一入口：
/// ① `GET bytes`（逐请求 `receiveTimeout: 10min` 覆盖基座 20s）；
/// ② 🔴 **显式判 4xx**（`validateAppStatus` 放行 4xx）：非 2xx 不落盘，
///    bytes 错误体解码后取服务端 `detail` **原文**（429/404 同样），不改写；
/// ③ 2xx：文件名 = `Content-Disposition` 解析（filename* 优先）→ 回退名，
///    落 `downloads/`（不存在则创建）；
/// ④ 网络层 / 5xx DioException → `errorDetail(e)` 原文。
///
/// [downloadsDir] 可注入（测试用临时目录）；null 时取
/// `getApplicationDocumentsDirectory()/downloads/`。[now] 注入当前时间
/// （回退名 stamp 用，测试可固定）。
///
/// 返回 `(saved, error)`：error 非 null 时 saved 必为 null，调用方只呈现
/// error 原文（error tone 顶部通知），**绝不假成功**。
Future<(SavedExport?, String?)> downloadExport(
  Dio dio,
  ExportKind kind, {
  Directory? downloadsDir,
  DateTime Function()? now,
}) async {
  final spec = exportSpecs[kind]!;
  try {
    final r = await dio.get<List<int>>(
      spec.path,
      options: Options(
        responseType: ResponseType.bytes,
        receiveTimeout: exportReceiveTimeout,
      ),
    );
    final status = r.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      // 🔴 4xx 被基座当作「成功 Response」放行，必须显式判；bytes 错误体
      // 解码后取 detail 原文（不落盘、不假成功）
      return (null, bytesResponseDetail(r.data) ?? api.genericErrorText);
    }
    final header = r.headers.value('content-disposition');
    final filename =
        sanitizeFilename(parseContentDispositionFilename(header)) ??
        exportFallbackName(kind, (now ?? DateTime.now)());
    final dir = downloadsDir ?? await defaultDownloadsDir();
    if (!await dir.exists()) await dir.create(recursive: true);
    final path = '${dir.path}${Platform.pathSeparator}$filename';
    await File(path).writeAsBytes(r.data ?? const <int>[]);
    return (SavedExport(path: path, filename: filename), null);
  } catch (e) {
    // 网络层 / 5xx DioException（`validateAppStatus` 放行之外才抛）与落盘
    // 异常：detail 原文，绝不崩出调用方
    return (null, api.errorDetail(e));
  }
}

/// 现有落盘范式同款目录（`album_viewer_page.dart:275-277`）：
/// `getApplicationDocumentsDirectory()/downloads/`。
Future<Directory> defaultDownloadsDir() async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory('${docs.path}${Platform.pathSeparator}downloads');
}
