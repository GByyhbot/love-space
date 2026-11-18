/// 在线更新服务（2.4.3 提交三 · 第 4 项 App 侧 + 第 5 项加速代理）。
///
/// 数据源（B2 定案仓库 PUBLIC）：App 直连 GitHub API，无凭据——
/// GET https://api.github.com/repos/GByyhbot/love-space/releases，
/// 超时/错误口径与现有网络层一致（Dio + 全局状态码策略）。
///
/// 版本比对：只认标签以 app-v 开头的正式版（prerelease 跳过、老 v* Release
/// 如 v1.7.4 一律忽略）；取版本号最大的一条与本机 versionName 数值段逐段
/// 比较（复用 settings_state.newerVer），严格大于才提示。
///
/// 检查时机：①冷启动节流（距上次检查不足 6 小时跳过，时间戳存
/// shared_preferences，失败也记时避免重试轰炸）；②设置页手动检查不受
/// 节流、必须有明确反馈。iOS 不显示入口、不检查（Platform 判断收口）。
///
/// 下载（第 5 项）：通道顺序=直连 GitHub → 内置代理候选逐个试；失败判定
/// =连接超时 10s / 开始后连续 15s 无数据进展 / HTTP 非 200；换通道重下
/// （分片不跨通道续传）；全部通道失败才算失败。代理只加速不信任——
/// 校验值永远只取 GitHub 元数据（.sha256 资产直连获取，禁止走代理）。
///
/// 验签与安装：下载完成先算本地 SHA-256 与 .sha256 对账，不一致立即删
/// 文件禁止进入安装步；一致调起系统安装器（open_filex，FileProvider）。
/// 任何环节失败 App 照常可用；自动检查全程静默；下载可取消（删半成品）。
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/api_client.dart' show dioProvider;
import '../settings/settings_state.dart' show newerVer;
import 'update_sheet.dart';

/// ── 常量（第 5 项内置候选清单，来源=本段实测，见交付摘要）──────────
const String kGithubRepo = 'GByyhbot/love-space';
const String kReleaseApi =
    'https://api.github.com/repos/$kGithubRepo/releases';
const String kApkAssetName = 'app-arm64-v8a-release.apk';
const String kShaAssetSuffix = '.sha256';

/// 代理候选（域名级内置写死；只服务于 APK 文件下载加速，禁止代理业务
/// API/媒体/SSE 等任何其他流量）。实测记录见 2.4.3 交付摘要第 5 项。
const List<String> kProxyPrefixes = [
  'https://gh-proxy.com/',
  'https://ghproxy.net/',
  'https://hub.gitmirror.com/',
];

/// 自动检查节流窗口（6 小时）。
const Duration kAutoCheckInterval = Duration(hours: 6);
const String kPrefLastCheck = 'update_last_check_ms';

/// 下载失败判定参数（第 5 项第 3 点；实现时微调值，摘要注明最终值）。
const Duration kConnectTimeout = Duration(seconds: 10);
const Duration kStallWindow = Duration(seconds: 15);

/// 「以后再说」：本次冷启动不再弹（session 级；下次冷启动仍可提示）。
final Set<String> sessionDeferredVersions = <String>{};

/// ── 模型 ─────────────────────────────────────────────────────────────

class GithubAsset {
  const GithubAsset({required this.name, required this.url});
  final String name;
  final String url;

  factory GithubAsset.fromJson(Map<String, dynamic> j) => GithubAsset(
        name: (j['name'] ?? '').toString(),
        url: (j['browser_download_url'] ?? '').toString(),
      );
}

class GithubRelease {
  const GithubRelease({
    required this.tagName,
    required this.name,
    required this.body,
    required this.prerelease,
    required this.assets,
  });

  final String tagName;
  final String name;
  final String body;
  final bool prerelease;
  final List<GithubAsset> assets;

  /// app-v2.4.3 → 2.4.3（非 app-v 前缀返回空串，比对时被忽略）。
  String get appVersion => tagName.startsWith('app-v')
      ? tagName.substring('app-v'.length)
      : '';

  GithubAsset? get apkAsset {
    for (final a in assets) {
      if (a.name == kApkAssetName) return a;
    }
    return null;
  }

  factory GithubRelease.fromJson(Map<String, dynamic> j) => GithubRelease(
        tagName: (j['tag_name'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        body: (j['body'] ?? '').toString(),
        prerelease: j['prerelease'] == true,
        assets: ((j['assets'] ?? []) as List)
            .whereType<Map>()
            .map((e) => GithubAsset.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );
}

/// 从 Release 列表挑最新可更新版：app-v 前缀 + 非 prerelease + 有 APK
/// 资产，取版本号最大者（newerVer 数值段比较）；无合规则返回 null。
GithubRelease? pickLatestAppRelease(List<GithubRelease> releases) {
  GithubRelease? best;
  for (final r in releases) {
    if (r.prerelease || !r.tagName.startsWith('app-v')) continue;
    if (r.appVersion.isEmpty || r.apkAsset == null) continue;
    if (best == null || newerVer(r.appVersion, best.appVersion)) {
      best = r;
    }
  }
  return best;
}

/// ── GitHub 客户端（直连，无凭据）────────────────────────────────────

Future<List<GithubRelease>> fetchReleases(Dio dio) async {
  final r = await dio.get<List<dynamic>>(
    kReleaseApi,
    queryParameters: {'per_page': 30},
    options: Options(
      // GitHub API 要求 UA；显式声明与直连来源，避免被中间层剥掉
      headers: {
        'User-Agent': 'LoveSpaceApp-update-check',
        'Accept': 'application/vnd.github+json',
      },
      // 用独立超时口径：检查轻量，10s 连接 + 15s 收发
      connectTimeout: kConnectTimeout,
      receiveTimeout: kStallWindow,
      sendTimeout: kStallWindow,
      // GitHub 是外部源，不落空间 cookie/拦截器影响
      extra: {'update-source': 'github'},
    ),
  );
  final list = r.data ?? const [];
  return list
      .whereType<Map>()
      .map((e) => GithubRelease.fromJson(e.cast<String, dynamic>()))
      .toList();
}

/// ── 本地状态 ─────────────────────────────────────────────────────────

Future<bool> _autoCheckDue() async {
  final prefs = await SharedPreferences.getInstance();
  final last = prefs.getInt(kPrefLastCheck) ?? 0;
  final due = DateTime.now().millisecondsSinceEpoch - last >=
      kAutoCheckInterval.inMilliseconds;
  // 失败也记时（调用方在拿到结果前就标记本轮已检查）
  await prefs.setInt(
      kPrefLastCheck, DateTime.now().millisecondsSinceEpoch);
  return due;
}

/// 下载文件落位：私有目录 downloads/（与相册原图下载同族），文件名带
/// 版本号防串版。
Future<File> apkTargetFile(String version) async {
  final dir = await getApplicationDocumentsDirectory();
  final dl = Directory('${dir.path}${Platform.pathSeparator}downloads');
  if (!dl.existsSync()) dl.createSync(recursive: true);
  return File(
      '${dl.path}${Platform.pathSeparator}lovespace-$version-arm64.apk');
}

/// 启动清理：删 downloads/ 下的历史安装包（半成品/已装旧版），不许在
/// 私有目录堆积历代 APK（第 4 项第 10 点）。冷启动自动检查前调用。
Future<void> purgeApkCache() async {
  try {
    if (!kIsWeb && Platform.isIOS) return;
    final dir = await getApplicationDocumentsDirectory();
    final dl = Directory('${dir.path}${Platform.pathSeparator}downloads');
    if (!dl.existsSync()) return;
    for (final f in dl.listSync()) {
      if (f is File && f.path.endsWith('.apk')) {
        try {
          f.deleteSync();
        } catch (_) {/* 单个失败不阻塞 */}
      }
    }
  } catch (_) {
    // 清理失败静默（App 照常可用）
  }
}

/// ── 下载引擎（通道切换 + 进度 + 取止）────────────────────────────────

class DownloadOutcome {
  const DownloadOutcome({required this.file, required this.channelUsed});
  final File file;
  final String channelUsed; // 直连 or 代理前缀（摘要/日志用）
}

/// 下载 APK：先直连 GitHub 资产 → 失败/过慢逐个切代理候选（换通道就
/// 重下，不跨通道续传）；进度回调（received/total）；[cancelToken] 取消
/// 会向上抛 DioException(cancel) 由调用方清理半成品。
Future<DownloadOutcome> downloadApk(
  Dio dio,
  GithubAsset asset,
  File target, {
  void Function(int received, int total)? onProgress,
  CancelToken? cancelToken,
}) async {
  final channels = <String>[asset.url];
  for (final p in kProxyPrefixes) {
    channels.add('$p${asset.url}');
  }
  Object? lastError;
  for (var i = 0; i < channels.length; i++) {
    final url = channels[i];
    try {
      final ok = await _downloadVia(dio, url, target,
          onProgress: onProgress, cancelToken: cancelToken);
      if (ok) {
        return DownloadOutcome(
            file: target,
            channelUsed:
                i == 0 ? '直连 GitHub' : '代理 ${kProxyPrefixes[i - 1]}');
      }
      lastError = 'HTTP 非 200';
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) rethrow; // 用户取消直接上抛
      lastError = e;
    } catch (e) {
      lastError = e;
    }
    if (target.existsSync()) target.deleteSync(); // 换通道重下
  }
  throw Exception('全部下载通道失败：$lastError');
}

/// 单通道下载；连接超时 10s、开始后连续 15s 无进展 → 经 CancelToken 中止
/// 本通道（stall 与用户取消用 local token 隔离：stall 算通道失败继续切换，
/// 用户取消向上抛）。直接写盘（dio.download），非 200 抛 badResponse 判败。
Future<bool> _downloadVia(
  Dio dio,
  String url,
  File target, {
  void Function(int received, int total)? onProgress,
  CancelToken? cancelToken,
}) async {
  var stalled = false;
  int lastReceived = -1;
  var lastProgressAt = DateTime.now();
  final localCancel = CancelToken();
  cancelToken?.whenCancel.then((_) {
    if (!localCancel.isCancelled) localCancel.cancel('user');
  });
  final timer = Timer.periodic(const Duration(seconds: 1), (_) {
    if (lastReceived >= 0 &&
        DateTime.now().difference(lastProgressAt) >= kStallWindow) {
      stalled = true;
      if (!localCancel.isCancelled) localCancel.cancel('stall');
    }
  });
  try {
    await dio.download(
      url,
      target.path,
      options: Options(
        headers: {'User-Agent': 'LoveSpaceApp-update-download'},
        connectTimeout: kConnectTimeout,
        sendTimeout: kStallWindow,
        extra: {'update-source': 'github'},
      ),
      cancelToken: localCancel,
      deleteOnError: true,
      onReceiveProgress: (received, total) {
        final now = DateTime.now();
        if (received != lastReceived) lastProgressAt = now;
        lastReceived = received;
        if (onProgress != null) onProgress(received, total);
      },
    );
    return target.existsSync() && target.lengthSync() > 0;
  } on DioException catch (e) {
    if (e.type == DioExceptionType.cancel && !stalled) rethrow; // 用户取消
    return false; // stall / 非 200 / 连接失败 → 切下一个通道
  } finally {
    timer.cancel();
  }
}

/// 校验值获取（硬性）：.sha256 资产只走 GitHub 直连（禁代理），拿不到
/// 视为验签失败（不许从下载通道取校验值）。
Future<String?> fetchSha256(Dio dio, GithubAsset apkAsset) async {
  try {
    final r = await dio.get<String>(
      '${apkAsset.url}$kShaAssetSuffix',
      options: Options(
        responseType: ResponseType.plain,
        headers: {'User-Agent': 'LoveSpaceApp-update-verify'},
        connectTimeout: kConnectTimeout,
        receiveTimeout: kStallWindow,
        sendTimeout: kStallWindow,
        extra: {'update-source': 'github'},
      ),
    );
    final text = (r.data ?? '').trim();
    if (text.isEmpty) return null;
    // 文件内容 = hex[64]（或 hex + 文件名两段），取第一段 hex
    final m = RegExp(r'[0-9a-fA-F]{64}').firstMatch(text);
    return m?.group(0)?.toLowerCase();
  } catch (_) {
    return null;
  }
}

/// ── 检查入口（自动节流 / 手动直查）──────────────────────────────────

enum CheckSource { auto, manual }

class CheckResult {
  const CheckResult({
    required this.status,
    this.release,
    this.errorText,
  });
  final String status; // 'up-to-date' | 'has-update' | 'error' | 'throttled'
  final GithubRelease? release;
  final String? errorText;
}

/// 检查更新（自动/手动共用取数与比对；节流只作用于 auto）。
/// iOS 不执行（调用方 UI 收口；此处再兜一道）。
Future<CheckResult> checkForUpdate(Dio dio, String localVersion,
    {required CheckSource source}) async {
  if (!kIsWeb && Platform.isIOS) {
    return const CheckResult(status: 'up-to-date');
  }
  if (source == CheckSource.auto && !await _autoCheckDue()) {
    return const CheckResult(status: 'throttled');
  }
  try {
    final releases = await fetchReleases(dio);
    final latest = pickLatestAppRelease(releases);
    if (latest == null) return const CheckResult(status: 'up-to-date');
    final has = localVersion.isNotEmpty && newerVer(latest.appVersion, localVersion);
    if (!has) return const CheckResult(status: 'up-to-date');
    return CheckResult(status: 'has-update', release: latest);
  } catch (e) {
    return CheckResult(
        status: 'error',
        errorText: '检查更新失败：请稍后再试（网络原因）');
  }
}

/// 自动检查（ShellPage 冷启动挂载点）：全程静默（失败连 toast 都不弹），
/// 有新版且未「以后再说」→ 弹更新 sheet。
Future<void> autoCheckSilently(WidgetRef ref, BuildContext context,
    String localVersion) async {
  try {
    if (!kIsWeb && Platform.isIOS) return;
    final dio = await ref.read(dioProvider.future);
    final result = await checkForUpdate(dio, localVersion,
        source: CheckSource.auto);
    if (result.status != 'has-update' || result.release == null) return;
    final ver = result.release!.appVersion;
    if (sessionDeferredVersions.contains(ver)) return;
    if (!context.mounted) return;
    await showUpdateSheet(context, ref: ref, release: result.release!);
  } catch (_) {
    // 自动检查异常绝不冒泡（不许影响启动/首页）
  }
}

/// 手动检查（设置页「检查更新」按钮）：不受节流、有明确反馈。
/// 返回给 UI 做反馈：'up-to-date'（toast 已是最新）/ 'error'（toast 原因）；
/// 'has-update' 已弹层，无需 toast。
Future<String> manualCheck(WidgetRef ref, BuildContext context,
    String localVersion) async {
  final dio = await ref.read(dioProvider.future);
  final result =
      await checkForUpdate(dio, localVersion, source: CheckSource.manual);
  if (result.status == 'has-update' && result.release != null) {
    if (context.mounted) {
      await showUpdateSheet(context, ref: ref, release: result.release!);
    }
  }
  return result.status;
}
