/// love_space · Flutter 双平台客户端（方案 v2 · 阶段 1 脚手架）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/chat/chat_models.dart' show ChatMedia;
import 'features/account/profile_page.dart';
import 'features/auth/auth_state.dart';
import 'features/auth/login_page.dart';
import 'features/chat/messages_page.dart';
import 'features/shell/shell_page.dart';
import 'features/timeline/image_viewer.dart';

void main() {
  runApp(const ProviderScope(child: LoveApp()));
}

/// 认证驱动的路由重定向：checking → splash；out → /login；authed → 主框架。
final routerProvider = Provider<GoRouter>((ref) {
  final notifier = ValueNotifier(0);
  ref.listen(authProvider, (_, _) => notifier.value++);
  return GoRouter(
    initialLocation: '/home',
    refreshListenable: notifier,
    redirect: (context, state) {
      final phase = ref.read(authProvider);
      final location = state.matchedLocation;
      final onLogin = location == '/login';
      // splash 是 checking 的临时落点：任何非 checking 阶段到达 splash 都必须离开，
      // 否则冷启动恢复成功（authed）会永远卡在转圈页（2026-11-11 真机事故根因）
      final onTransient = onLogin || location == '/splash';
      if (phase == AuthPhase.checking) return onLogin ? null : '/splash';
      if (phase == AuthPhase.out) return onLogin ? null : '/login';
      return onTransient ? '/home' : null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const _SplashPage()),
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      GoRoute(path: '/home', builder: (_, _) => const ShellPage()),
      // 聊天（悄悄话）：二级页，Shell AppBar 私聊图标 push 进入（对齐 Web 顶栏入口）
      GoRoute(path: '/messages', builder: (_, _) => const MessagesPage()),
      GoRoute(path: '/profile', builder: (_, _) => const ProfilePage()),
      // 相册查看器（条目 5 · 段 A 先用段一基础查看器；段 B 替换为
      // Hero 共享元素转场 + 跨相册翻页的进阶查看器，路由路径不变）。
      // 二级页一律 context.push：保留主页在路由栈，返回按钮/系统手势回网格。
      GoRoute(
        path: '/album/viewer',
        builder: (_, state) {
          final extra = (state.extra as Map?) ?? const {};
          final images = (extra['images'] as List?)?.cast<ChatMedia>() ??
              const <ChatMedia>[];
          final index = (extra['index'] as int?) ?? 0;
          return ImageViewerPage(images: images, initialIndex: index);
        },
      ),
    ],
  );
});

class LoveApp extends ConsumerWidget {
  const LoveApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: '恋爱空间',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF953753)),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF953753),
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      routerConfig: router,
    );
  }
}

class _SplashPage extends StatelessWidget {
  const _SplashPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
