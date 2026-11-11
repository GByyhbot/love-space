/// love_space · Flutter 双平台客户端（方案 v2 · 阶段 1 脚手架）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/auth/auth_state.dart';
import 'features/auth/login_page.dart';
import 'features/shell/shell_page.dart';

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
      final onLogin = state.matchedLocation == '/login';
      if (phase == AuthPhase.checking) return onLogin ? null : '/splash';
      if (phase == AuthPhase.out) return onLogin ? null : '/login';
      return onLogin ? '/home' : null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const _SplashPage()),
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      GoRoute(path: '/home', builder: (_, _) => const ShellPage()),
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
