/// 认证状态（方案 v2 阶段 2 账号页的基础；脚手架先落地登录 + 会话校验）。
library;

import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';

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
    try {
      final dio = await ref.read(dioProvider.future);
      final r = await dio.get('/api/me');
      if (r.statusCode == 200) {
        final j = r.data as Map<String, dynamic>;
        final user = (j['user'] ?? {}) as Map<String, dynamic>;
        final space = (j['space'] ?? {}) as Map<String, dynamic>;
        me = MeData(
          userName: (user['name'] ?? '').toString(),
          spaceName: (space['name'] ?? '').toString(),
          unread: (j['unread'] as num?)?.toInt() ?? 0,
          chatUnread: (j['chat_unread'] as num?)?.toInt() ?? 0,
        );
        state = AuthPhase.authed;
      } else {
        state = AuthPhase.out;
      }
    } catch (_) {
      // 网络不可达也先给登录页（页面带错误文案，可重试）
      state = AuthPhase.out;
    }
  }

  /// 登录：成功返回 null，失败返回服务端中文文案
  Future<String?> login(String username, String password) async {
    try {
      final dio = await ref.read(dioProvider.future);
      await dio.post('/api/login', data: {'username': username, 'password': password});
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
  }

  /// 401 全局回调入口（api_client.onUnauthorized 由 build 里注册）
  void forceOut() {
    me = null;
    state = AuthPhase.out;
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthPhase>(AuthNotifier.new);
