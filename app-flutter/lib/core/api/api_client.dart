/// 共享网络基础设施：CookieJar（唯一实例）→ Dio（拦截器定版）→ 线路选择。
/// auth_probe 实验结论直接落地（方案 v2 阶段 0 → 阶段 1）：
/// · 写请求统一注入 X-Love-Space: 1（缺头 403）
/// · PersistCookieJar 落盘 → App 重启免登录
/// · 401 → 清会话回登录（全局回调由认证层注册）
/// · Dio 显式 DIRECT 代理（开发机 HTTP_PROXY 环境变量坑，真机默认即直连）
library;

import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../config.dart';

/// 会话失效全局回调（由认证层注册：置登录态 → 路由跳登录页）
void Function()? onUnauthorized;

/// 会话 token 的加密落盘（secure_storage）：CookieJar 的 per-host 文件在真机上
/// 观测到偶发丢失（2026-11-11 小米 15：5 次恢复成功、1 次 me 401），这里存一份
/// 正本，冷启动/换线时据此自愈播种——参照旧壳 MainActivity 的 seedCookie 做法。
const _secureStorage = FlutterSecureStorage();
const _sessionTokenKey = 'love_session_token';

Future<void> storeSessionToken(String token) =>
    _secureStorage.write(key: _sessionTokenKey, value: token);

Future<void> clearSessionToken() =>
    _secureStorage.delete(key: _sessionTokenKey);

Future<String?> readSessionToken() =>
    _secureStorage.read(key: _sessionTokenKey);

/// 把会话 token 播种到全部线路域名（参照旧壳 shareSessionToAll/seedCookie）。
/// 五条线路同一后端、同一 sessions 表，token 跨域通用；明文内网线路不带
/// Secure（cookie 带了 Secure 就不会随 http 请求发送，切过去等于没登录）。
Future<void> seedSessionToAllRoutes(PersistCookieJar jar, String token) async {
  for (final base in AppConfig.effectiveRoutes) {
    final uri = Uri.parse('$base/');
    final cookie = Cookie(AppConfig.sessionCookieName, token)
      ..path = '/'
      ..maxAge = AppConfig.sessionTtlDays * 86400
      ..httpOnly = true
      ..secure = uri.scheme == 'https';
    await jar.saveFromResponse(uri, [cookie]);
  }
}

/// 冷启动/换线自愈：确保 jar 里有会话 cookie。
/// ① 当前线路已有 → 直接返回；② 从其它线路的 jar 记录里找回（换线场景）；
/// ③ 从 secure_storage 正本恢复（jar 文件偶发丢失场景）。找回后全线路重播。
Future<void> ensureSessionCookie(PersistCookieJar jar, String base) async {
  final uri = Uri.parse('$base/');
  final existing = await jar.loadForRequest(uri);
  if (existing.any((c) => c.name == AppConfig.sessionCookieName)) return;

  String? token;
  for (final other in AppConfig.effectiveRoutes) {
    if (other == base) continue;
    final found = await jar.loadForRequest(Uri.parse('$other/'));
    for (final c in found) {
      if (c.name == AppConfig.sessionCookieName && c.value.isNotEmpty) {
        token = c.value;
        break;
      }
    }
    if (token != null) break;
  }
  token ??= await readSessionToken();
  if (token == null || token.isEmpty) return;
  await seedSessionToAllRoutes(jar, token);
}

/// 登出：清全部线路的 jar 记录 + secure_storage 正本（服务端 /api/logout 删
/// sessions 行并 delete_cookie，这里负责客户端侧不留痕）。
Future<void> clearSessionEverywhere(PersistCookieJar jar) async {
  for (final base in AppConfig.effectiveRoutes) {
    await jar.delete(Uri.parse('$base/'), true);
  }
  await clearSessionToken();
}

/// 带直连代理覆写的适配器（见 auth-plan.md：Dart 默认 findProxyFromEnvironment
/// 会读 HTTP_PROXY 环境变量且不识别 NO_PROXY='*'，开发机必须显式 DIRECT）
IOHttpClientAdapter directAdapter() {
  final adapter = IOHttpClientAdapter();
  adapter.createHttpClient = () {
    final h = HttpClient();
    h.findProxy = (uri) => 'DIRECT';
    return h;
  };
  return adapter;
}

Future<PersistCookieJar> createCookieJar() async {
  final dir = await getApplicationDocumentsDirectory();
  final store = '${dir.path}${Platform.pathSeparator}.cookies';
  return PersistCookieJar(ignoreExpires: true, storage: FileStorage(store));
}

Dio buildDio(String baseUrl, PersistCookieJar jar, {bool authHeader = true}) {
  final dio = Dio(BaseOptions(
    baseUrl: baseUrl,
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
    // 401 也走响应分支，由拦截器统一处理会话失效
    validateStatus: (s) => s != null && s < 500,
  ));
  dio.httpClientAdapter = directAdapter();
  dio.interceptors.add(CookieManager(jar));
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) {
      if (authHeader &&
          ['POST', 'PUT', 'PATCH', 'DELETE'].contains(options.method.toUpperCase())) {
        options.headers['X-Love-Space'] = '1';
      }
      handler.next(options);
    },
    onError: (e, handler) {
      if (e.response?.statusCode == 401) onUnauthorized?.call();
      handler.next(e);
    },
  ));
  return dio;
}

/// 提取服务端中文错误文案（detail 直通 UI）
String errorDetail(Object? e) {
  if (e is DioException) {
    final data = e.response?.data;
    if (data is Map && data['detail'] != null) return data['detail'].toString();
    if (data is List && data.isNotEmpty) {
      final first = data.first;
      if (first is Map && first['msg'] != null) return first['msg'].toString();
    }
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout) {
      return '网络连接不上，稍后再试';
    }
  }
  return '出了点小问题，稍后再试';
}

/// CookieJar（App 全局唯一实例；ApiClient 与 SSE 共用）
final cookieJarProvider = FutureProvider<PersistCookieJar>((_) => createCookieJar());

/// 线路选择（按主人定版优先级逐条探测可达性，首选 4019 逐级回退）。
/// 不再读 /api/routes（其返回顺序与产品优先级无关；空清单回退逻辑一并作废）。
final baseProvider = FutureProvider<String>((ref) async {
  final routes = AppConfig.effectiveRoutes;
  for (final base in routes) {
    if (await _reachable(base)) return base;
  }
  // 全部不可达：回退首选线路，让业务请求自然失败并触发「网络连接不上」文案
  return routes.first;
});

Future<bool> _reachable(String base) async {
  try {
    final d = Dio(BaseOptions(
      baseUrl: base,
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      ))..httpClientAdapter = directAdapter();
    final r = await d.get('/api/status');
    return r.statusCode == 200;
  } catch (_) {
    return false;
  }
}

/// 主 Dio 实例（登录态请求全部走它；SSE 用同一 CookieJar 自建流式实例）。
/// 构建前先做会话自愈播种：换线/cookie 文件偶发丢失都能从这里兜回来。
final dioProvider = FutureProvider<Dio>((ref) async {
  final jar = await ref.watch(cookieJarProvider.future);
  final base = await ref.watch(baseProvider.future);
  await ensureSessionCookie(jar, base);
  return buildDio(base, jar);
});
