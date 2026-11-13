/// love_space · Flutter 双平台客户端（方案 v2 · 阶段 1 脚手架）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/album/album_data.dart' show PhotoItem;
import 'features/account/profile_page.dart';
import 'features/album/album_viewer_page.dart';
import 'features/auth/auth_state.dart';
import 'features/auth/login_page.dart';
import 'features/chat/chat_toast.dart' show ChatToastHost;
import 'features/chat/messages_page.dart';
import 'features/shell/shell_page.dart';
import 'features/together/anniversary_page.dart';
import 'features/together/calendar_page.dart';
import 'features/together/ledger_page.dart';
import 'features/together/music_page.dart';
import 'features/together/question_habit_pages.dart';
import 'features/together/quest_page.dart';
import 'features/together/tool_pages.dart';

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
      // 「我们」工具页（条目 6 · 段 A/B）：hub 宫格 push 进入，二级页规范
      GoRoute(path: '/together/mood', builder: (_, _) => const MoodPage()),
      GoRoute(path: '/together/note', builder: (_, _) => const NotePage()),
      GoRoute(path: '/together/wish', builder: (_, _) => const WishPage()),
      GoRoute(
          path: '/together/anniversary',
          builder: (_, _) => const AnniversaryPage()),
      GoRoute(path: '/together/calendar', builder: (_, _) => const CalendarPage()),
      GoRoute(path: '/together/question', builder: (_, _) => const QuestionPage()),
      GoRoute(path: '/together/habit', builder: (_, _) => const HabitPage()),
      GoRoute(path: '/together/quest', builder: (_, _) => const QuestPage()),
      GoRoute(path: '/together/ledger', builder: (_, _) => const LedgerPage()),
      GoRoute(path: '/together/music', builder: (_, _) => const MusicPage()),
      // 相册查看器（条目 5 · 段 B 甲档）：Hero 共享元素转场 + 跨相册翻页 +
      // InteractiveViewer 缩放 + 下拉跟手关闭 + 计数/caption/预加载 + 下载顶部通知。
      // 二级页一律 context.push：保留主页在路由栈，返回按钮/系统手势回网格。
      GoRoute(
        path: '/album/viewer',
        builder: (_, state) {
          final extra = (state.extra as Map?) ?? const {};
          final photos = (extra['photos'] as List?)?.cast<PhotoItem>() ??
              const <PhotoItem>[];
          final index = (extra['index'] as int?) ?? 0;
          final albumId = (extra['albumId'] as String?) ?? '';
          return AlbumViewerPage(
            photos: photos,
            initialIndex: index,
            albumId: albumId,
          );
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
      // 全局唯一顶部通知宿主：builder 包在 Navigator 之上，覆盖所有页面、
      // 二级页、BottomSheet、Dialog（含全屏查看器）——结果类提示统一走
      // ChatToastHost，App 内不再有底部 SnackBar。IgnorePointer 不拦手势；
      // SafeArea 避开状态栏，通知始终在顶部不被任何栏/弹层遮挡。
      builder: (context, child) => Stack(children: [
        child ?? const SizedBox.shrink(),
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: SafeArea(child: ChatToastHost()),
          ),
        ),
      ]),
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
