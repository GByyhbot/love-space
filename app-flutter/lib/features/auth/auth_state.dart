/// 认证状态（方案 v2 阶段 2 账号页的基础；脚手架先落地登录 + 会话校验）。
library;

import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/chat/chat_media.dart' show mediaCookieHeadersProvider;
import '../../core/chat/chat_state.dart' show chatUnreadProvider;
import '../../core/config.dart';

enum AuthPhase { checking, out, authed }

class SpaceUser {
  const SpaceUser({required this.id, required this.name, required this.username, this.avatar = '', this.admin = false});
  final String id;
  final String name;
  final String username;
  final String avatar;
  final bool admin;

  factory SpaceUser.fromJson(Map<String, dynamic> j) => SpaceUser(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        username: (j['username'] ?? '').toString(),
        avatar: (j['avatar'] ?? '').toString(),
        admin: j['admin'] == 1 || j['admin'] == true,
      );
}

class MeData {
  const MeData({
    required this.user,
    required this.users,
    required this.spaceName,
    required this.spaceRaw,
    required this.spaceSince,
    this.unread = 0,
    this.chatUnread = 0,
    this.paired = false,
  });
  final SpaceUser user;
  final List<SpaceUser> users;
  final String spaceName;
  /// space 完整原始对象：PUT /api/space 是全量覆盖语义，必须原样带回
  final Map<String, dynamic> spaceRaw;
  final String spaceSince;
  final int unread;
  final int chatUnread;
  /// 空间是否已绑定两人（users.length==2；未绑定时账号页显示邀请入口）
  final bool paired;

  SpaceUser? byId(String id) {
    for (final u in users) {
      if (u.id == id) return u;
    }
    return null;
  }
}

/// 认证页三态（对齐 Web renderAuth：未初始化 → setup；带邀请 token → join；其余 login）
enum AuthMode { login, setup, join }

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
        final user = SpaceUser.fromJson((j['user'] ?? {}) as Map<String, dynamic>);
        final users = ((j['users'] ?? []) as List)
            .whereType<Map>()
            .map((u) => SpaceUser.fromJson(u.cast<String, dynamic>()))
            .toList();
        final space = (j['space'] ?? {}) as Map<String, dynamic>;
        me = MeData(
          user: user,
          users: users,
          spaceName: (space['name'] ?? '').toString(),
          spaceRaw: space,
          spaceSince: (space['since'] ?? '').toString(),
          unread: (j['unread'] as num?)?.toInt() ?? 0,
          chatUnread: (j['chat_unread'] as num?)?.toInt() ?? 0,
          paired: users.length >= 2,
        );
        // 聊天未读角标播种（/api/me 的 chat_unread 字段名已在 app/main.py 实读确认）：
        // 角标挂独立 Notifier（chat_state），变化不必打断 authed 态
        ref.read(chatUnreadProvider.notifier).set(me!.chatUnread);
        // Cookie 媒体请求头换线兜底（低危备忘 E2）：bootstrap 每次确定线路后
        // 重建媒体头缓存，mediaCookieHeadersProvider 注释与实现从此一致
        ref.invalidate(mediaCookieHeadersProvider);
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

  /// 已登录态下重新拉取 me（space/profile 变更后刷新全局状态）
  Future<void> reload() async {
    await _bootstrap();
  }

  /// 从响应体提取服务端中文文案（validateStatus<500 时 4xx 走正常响应）
  String? _detailOf(Object? data) {
    if (data is Map && data['detail'] != null) return data['detail'].toString();
    if (data is List && data.isNotEmpty) {
      final first = data.first;
      if (first is Map && first['msg'] != null) return first['msg'].toString();
    }
    return null;
  }

  /// 三态认证提交（对齐 Web renderAuth → POST /api/{mode}）：
  /// login：username/password；setup/join：再加 name（与邀请 token）。
  /// 成功后与登录同款：token 存正本 + 全线路播种（join/setup 产生的会话同样有效）。
  Future<String?> submitAuth(
    AuthMode mode, {
    required String username,
    required String password,
    String? name,
    String? token,
  }) async {
    try {
      final dio = await ref.read(dioProvider.future);
      final data = <String, dynamic>{'username': username, 'password': password};
      if (name != null && name.isNotEmpty) data['name'] = name;
      if (token != null && token.isNotEmpty) data['token'] = token;
      final path = switch (mode) {
        AuthMode.login => '/api/login',
        AuthMode.setup => '/api/setup',
        AuthMode.join => '/api/join',
      };
      final r = await dio.post(path, data: data);
      if ((r.statusCode ?? 500) >= 400) {
        return _detailOf(r.data) ?? '提交失败，请重试';
      }
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

  /// 账号资料保存（PUT /api/profile）：昵称必填；头像传媒体 id（空串=不修改）；
  /// 改密码时 old/new 成对传。服务端改密后会话立即失效（login_required=true）→ 回登录页。
  /// 返回 null=成功；'RELOGIN'=改密成功需重新登录；其余为错误文案。
  Future<String?> updateProfile({
    required String name,
    String? avatarId,
    String? oldPassword,
    String? newPassword,
  }) async {
    try {
      final dio = await ref.read(dioProvider.future);
      final data = <String, dynamic>{'name': name, 'avatar': avatarId ?? ''};
      if ((oldPassword ?? '').isNotEmpty) data['old_password'] = oldPassword;
      if ((newPassword ?? '').isNotEmpty) data['new_password'] = newPassword;
      final r = await dio.put('/api/profile', data: data);
      if ((r.statusCode ?? 500) >= 400) {
        return _detailOf(r.data) ?? '保存失败，请重试';
      }
      if (r.data is Map && r.data['login_required'] == true) {
        forceOut();
        return 'RELOGIN';
      }
      await Future.microtask(_bootstrap);
      return null;
    } on DioException catch (e) {
      final respData = e.response?.data;
      if (respData is Map && respData['detail'] != null) {
        return respData['detail'].toString();
      }
      return errorDetail(e);
    } catch (e) {
      return errorDetail(e);
    }
  }

  /// 生成邀请（POST /api/invite）：返回 (token, null)；已绑定等业务错误返回 (null, 文案)。
  Future<(String?, String?)> createInvite() async {
    try {
      final dio = await ref.read(dioProvider.future);
      final r = await dio.post('/api/invite');
      if ((r.statusCode ?? 500) >= 400) {
        return (null, _detailOf(r.data) ?? '生成邀请失败');
      }
      return ((r.data as Map)['token'].toString(), null);
    } on DioException catch (e) {
      final respData = e.response?.data;
      if (respData is Map && respData['detail'] != null) {
        return (null, respData['detail'].toString());
      }
      return (null, errorDetail(e));
    } catch (e) {
      return (null, errorDetail(e));
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
