/// 认证状态（方案 v2 阶段 2 账号页的基础；脚手架先落地登录 + 会话校验）。
library;

import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/config.dart';

enum AuthPhase { checking, out, authed }

class MeData {
  const MeData({required this.userName, required this.spaceName, this.unread = 0, this.chatUnread = 0});
  final String userName;
  final String spaceName;
  final int unread;
  final int chatUnread;
}

class AuthNotifier extends Notifier<AuthPhase> {
  MeData? me;

  @override
  AuthPhase build() {
    ref.onDispose(() => onUnauthorized = null);
    onUnauthorized = () {
      if (state != AuthPhase.out) state = AuthPhase.out;
    };
    Future.microtask(_bootstrap);
    return AuthPhase.checking;
  }

  Future<void> _bootstrap() async {
    final sw = Stopwatch()..start();
    // stage 记录卡住的环节（探测线路 / me 请求），超时或异常时打日志供定位
    String stage = '线路选择（快路径/并行探测）';
    try {
      final steps = Future(() async {
        final dio = await ref.read(dioProvider.future);
        stage = 'GET /api/me';
        final r = await dio.get('/api/me');
        stage = '解析 me 响应';
        if (r.statusCode != 200) return false;
        final j = r.data as Map<String, dynamic>;
        final user = (j['user'] ?? {}) as Map<String, dynamic>;
        final space = (j['space'] ?? {}) as Map<String, dynamic>;
        me = MeData(
          userName: (user['name'] ?? '').toString(),
          spaceName: (space['name'] ?? '').toString(),
          unread: (j['unread'] as num?)?.toInt() ?? 0,
          chatUnread: (j['chat_unread'] as num?)?.toInt() ?? 0,
        );
        return true;
      });
      final ok = await steps.timeout(AppConfig.bootstrapDeadline);
      if (ok) {
        state = AuthPhase.authed;
      } else {
        debugPrint('[bootstrap] ${sw.elapsed} 未登录（me 非 200）');
        state = AuthPhase.out;
      }
    } on TimeoutException {
      debugPrint('[bootstrap] ${sw.elapsed} 超时兜底：卡在 [$stage] → 降级登录页可重试');
      state = AuthPhase.out;
    } catch (e) {
      debugPrint('[bootstrap] ${sw.elapsed} 失败：[$stage] $e → 登录页');
      state = AuthPhase.out;
    }
  }

  /// 网络兜底重试（登录页「重试连接」入口）：不必重输密码，
  /// 重新走一遍 bootstrap（上次线路快路径 → 全量探测 → me 验活）。
  Future<void> retryBootstrap() async {
    if (state == AuthPhase.checking) return;
    state = AuthPhase.checking;
    await Future.microtask(_bootstrap);
  }

  /// 登录：成功返回 null，失败返回服务端中文文案。
  /// 成功后：从 jar 取回会话 token → secure_storage 存正本 + 全线路播种
  /// （换线免登录的前提，见 api_client.seedSessionToAllRoutes）。
  Future<String?> login(String username, String password) async {
    try {
      final dio = await ref.read(dioProvider.future);
      await dio.post('/api/login', data: {'username': username, 'password': password});
      final jar = await ref.read(cookieJarProvider.future);
      final base = await ref.read(baseProvider.future);
      final cookies = await jar.loadForRequest(Uri.parse('$base/'));
      for (final c in cookies) {
        if (c.name == AppConfig.sessionCookieName && c.value.isNotEmpty) {
          await storeSessionToken(c.value);
          await seedSessionToAllRoutes(jar, c.value);
          break;
        }
      }
      await _bootstrap();
      return state == AuthPhase.authed ? null : '登录失败，请重试';
    } on DioException catch (e) {
      final data = e.response?.data;
      if (data is Map && data['detail'] != null) return data['detail'].toString();
      return errorDetail(e);
    } catch (e) {
      return errorDetail(e);
    }
  }

  Future<void> logout() async {
    try {
      final dio = await ref.read(dioProvider.future);
      await dio.post('/api/logout');
    } catch (_) {}
    me = null;
    state = AuthPhase.out;
    // 客户端侧不留痕：清全部线路 jar 记录 + secure_storage 正本
    try {
      final jar = await ref.read(cookieJarProvider.future);
      await clearSessionEverywhere(jar);
    } catch (_) {}
  }

  /// 401 全局回调入口（api_client.onUnauthorized 由 build 里注册）。
  /// 会话已失效：token 正本一并清掉，避免下次启动拿死 token 播种。
  void forceOut() {
    me = null;
    state = AuthPhase.out;
    clearSessionToken();
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthPhase>(AuthNotifier.new);
