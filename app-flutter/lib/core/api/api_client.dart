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
import 'package:path_provider/path_provider.dart';

import '../config.dart';

/// 会话失效全局回调（由认证层注册：置登录态 → 路由跳登录页）
void Function()? onUnauthorized;

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

/// 线路选择（内置主线路 → /api/routes 清单 → 可达性探测；空清单回退内置）
final baseProvider = FutureProvider<String>((ref) async {
  const builtin = AppConfig.builtinMainRoute;
  final probe = Dio(BaseOptions(
    baseUrl: builtin,
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 6),
    ))..httpClientAdapter = directAdapter();
  try {
    final r = await probe.get('/api/routes');
    if (r.data is List) {
      final fetched = (r.data as List)
          .map((e) => e is Map ? (e['url'] ?? e['origin'] ?? '').toString() : e.toString())
          .where((u) => u.isNotEmpty)
          .map((u) => u.endsWith('/') ? u.substring(0, u.length - 1) : u)
          .toList();
      // 阶段 0 实测：本地测试环境返回空列表 → 回退内置主线路
      final all = fetched.isEmpty ? [builtin] : fetched;
      for (final base in all) {
        if (await _reachable(base)) return base;
      }
    }
  } catch (_) {/* 探测失败保持内置主线路 */}
  return builtin;
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

/// 主 Dio 实例（登录态请求全部走它；SSE 用同一 CookieJar 自建流式实例）
final dioProvider = FutureProvider<Dio>((ref) async {
  final jar = await ref.watch(cookieJarProvider.future);
  final base = await ref.watch(baseProvider.future);
  return buildDio(base, jar);
});
