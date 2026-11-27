/// love_space · Flutter 双平台客户端（方案 v2 · 阶段 1 脚手架）
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart' show AudioService, AudioServiceConfig;
import 'core/audio/song_audio_handler.dart' show SongAudioHandler;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/album/album_data.dart' show PhotoItem;
import 'core/theme/tokens.dart';
import 'core/together/together_data.dart' show TogetherRecord;
import 'features/account/profile_page.dart';
import 'features/settings/appearance_page.dart';
import 'features/settings/backups_page.dart';
import 'features/settings/chat_bubble_page.dart';
import 'features/settings/chat_wallpaper_page.dart';
import 'features/settings/cover_page.dart';
import 'features/settings/export_page.dart';
import 'features/settings/invite_page.dart';
import 'features/settings/links_page.dart';
import 'features/settings/notify_settings_page.dart';
import 'features/settings/settings_home_page.dart';
import 'features/settings/space_info_page.dart';
import 'features/settings/settings_state.dart';
import 'features/album/album_viewer_page.dart';
import 'features/auth/auth_state.dart';
import 'features/auth/login_page.dart';
import 'features/home/on_this_day_page.dart';
import 'features/home/yearbook_page.dart';
import 'features/chat/chat_toast.dart' show ChatToastHost, ChatToastTone, chatToastProvider;
import 'features/chat/messages_page.dart';
import 'features/notify/channels_page.dart';
import 'features/notify/notices_page.dart';
import 'features/personal/personal_page.dart';
import 'features/period/period_analysis_page.dart';
import 'features/period/period_page.dart';
import 'features/shell/shell_page.dart';
import 'features/together/anniversary_page.dart';
import 'features/together/calendar_page.dart';
import 'features/together/dashboard_page.dart';
import 'features/together/ledger_page.dart';
import 'features/together/music_page.dart';
import 'features/together/peer_hub_page.dart';
import 'features/together/peer_preview_page.dart';
import 'features/settings/peer_sensitive_page.dart';
import 'features/together/question_habit_pages.dart';
import 'features/together/quest_page.dart';
import 'features/together/tool_pages.dart';
import 'features/together/weekly_page.dart';
import 'core/audio/audio_init_status.dart' show AudioInitStatus, audioInitStatusProvider;
import 'core/audio/song_playback.dart' show songPlaybackProvider;
import 'core/notify/notify_service.dart'
    show NotifyCoordinator, notifyRouteHandler, notifyNoticeTapHandler;
// 2.8.1：系统通知/冷启动点击与通知中心共用同一套落点判定
import 'core/api/api_client.dart' as api;
import 'core/notify/notify_decision.dart' show NoticeTargetKind, noticeTargetOf;
import 'features/timeline/record_story_sheet.dart' show showRecordStorySheet;
import 'core/peer/peer_locator.dart';
import 'core/peer/peer_state_collector.dart';
import 'features/chat/voice_playback.dart' show voiceInterruptHook;

/// 2.4.5 甲组：通知/前台服务全局初始化先于首帧（Android only；失败不影响主链）。
/// 冷启动点击通知的 launch 详情只有在 initialize 完成后才可恢复。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await NotifyCoordinator.platformInit();
  } catch (_) {}
  // 2.4.14：audio_service 原生架构（旧桥接包已移除——其
  // 「接管全局 platform + 只许单 AudioPlayer」模型与本 App 多 player 不兼容）。
  // 歌曲专用 handler 持全 App 唯一歌曲 player，通知/锁屏广播为单一事实源；
  // 语音家族/选歌试听回归普通 just_audio，互不相干；失败不影响主链。
  // 3.x：默认开启「失败自动重试」（指数退避最多 10 次）。本项目错误提示与
  // 重试策略全在 UI/服务层显式做，provider 层再自动重试会推迟错误呈现、
  // 并放大后端压力 → 这里显式关掉，保持 2.x 语义（返回 null = 不重试）。
  final container = ProviderContainer(retry: (_, _) => null);
  // 2.4.15：init 成败与错误原文必须落盘可见（设置页「关于」区渲染），
  // 禁止裸 catch 吞错——2.4.14 真机「零媒体会话零报错」即吞错所致。
  try {
    final songHandler = await AudioService.init(
      builder: () => SongAudioHandler(),
      config: AudioServiceConfig(
        androidNotificationChannelId: 'cn.iepose.lovespace.audio',
        androidNotificationChannelName: '音乐播放',
        androidNotificationChannelDescription: '正在播放的歌曲与播放控制',
        androidNotificationOngoing: true,
        // 暂停时保留前台服务（裁定⑥并存口径 + 避免后台重启限制）
        androidStopForegroundOnPause: false,
        androidResumeOnClick: true,  // 点通知回 App
      ),
    );
    // 引擎接线（container 同源）：handler 注入 + 播语音停歌钩子
    container.read(songPlaybackProvider.notifier).attachHandler(songHandler);
    container.read(audioInitStatusProvider.notifier).state =
        const AudioInitStatus(ready: true);
  } catch (e) {
    // ignore: avoid_print
    print('AudioService.init failed: $e');
    container.read(audioInitStatusProvider.notifier).state =
        AudioInitStatus(error: e.toString());
  }
  voiceInterruptHook = () => container.read(songPlaybackProvider.notifier).stop();
  // 2.5.9 裁定⑥：static 回调（onTaskData）写 provider 用
  NotifyCoordinator.notifyStatusContainer = container;
  // 2.8.0 第 0 步：冷启动按持久化期望态自动恢复定位采集（开关显示与自启解耦依赖用户手拨）
  unawaited(peerLocatorAutoStart(resumeIfExpected: true));
  // 2.8.7 自动报备：装状态样本 handler + 按 events 开关同步原生采集态
  unawaited(peerStateCollectionAutoStart(
      dio: () => container.read(api.dioProvider.future)));
  runApp(UncontrolledProviderScope(container: container, child: const LoveApp()));
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
      // 段 C（2.2.7）：非 admin 直达 /backups → 回 /settings。
      // 选「直达也进不去」：不发任何 /api/storage 请求、不崩。保留既有
      // splash/authed 分支逻辑不动（splash 死锁教训），门控只在 authed 后判。
      if (location == '/backups' &&
          ref.read(authProvider.notifier).me?.user.admin != true) {
        return '/settings';
      }
      return onTransient ? '/home' : null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const _SplashPage()),
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      GoRoute(path: '/home', builder: (_, _) => const ShellPage()),
      // 2.4.3 双卡二级页：首页历史卡/年报卡 context.push 进入；
      // AppBar 自动返回按钮 + 系统手势都能回上一页。
      GoRoute(
          // 2.4.10 第 06 项（裁定 c）：首页「历史上的今天」入口卡 → 本页
          // 路由转场动画——打开 ease-out 0.72s（轻微上移+淡入）、收回
          // 0.68s ease-in；首页 widget 树与现有结构零改动（硬约束）。
          path: '/on-this-day',
          pageBuilder: (context, state) => CustomTransitionPage(
                key: state.pageKey,
                child: const OnThisDayPage(),
                transitionDuration: const Duration(milliseconds: 720),
                reverseTransitionDuration: const Duration(milliseconds: 680),
                transitionsBuilder: (context, anim, secondary, child) {
                  final inCurve = Curves.easeOut.transform(anim.value);
                  return FadeTransition(
                    opacity: anim.drive(Tween(begin: 0.0, end: 1.0)
                        .chain(CurveTween(curve: Curves.easeOut))),
                    child: SlideTransition(
                      position: anim.drive(Tween(
                          begin: const Offset(0, 0.04),
                          end: Offset.zero).chain(CurveTween(curve: Curves.easeOut))),
                      child: Transform.scale(scale: 0.96 + 0.04 * inCurve, child: child),
                    ),
                  );
                },
              )),
      GoRoute(path: '/yearbook', builder: (_, _) => const YearbookPage()),
      // 聊天（悄悄话）：二级页，Shell AppBar 私聊图标 push 进入（对齐 Web 顶栏入口）
      GoRoute(path: '/messages', builder: (_, _) => const MessagesPage()),
      GoRoute(path: '/profile', builder: (_, _) => const ProfilePage()),
      // 2.4.0 设置拆分段：全量长设置页退役，/settings 由设置主页接管
      // （分组索引 + 关于页脚）；六张内容独立页挂子路径，一律 push。
      GoRoute(path: '/settings', builder: (_, _) => const SettingsHomePage()),
      GoRoute(
          path: '/settings/theme', builder: (_, _) => const AppearancePage()),
      GoRoute(
          path: '/settings/cover', builder: (_, _) => const CoverPage()),
      GoRoute(
          path: '/settings/links', builder: (_, _) => const LinksPage()),
      // 2.4.5 乙组第 3 项：消息通知独立页（权限/服务状态/测试通知/小米放行引导）
      GoRoute(
          path: '/settings/notify',
          builder: (_, _) => const NotifySettingsPage()),
      // 2.8.0 P1 / 真改版式令：落入四页签报备中心「设置」页签（tab 3），兼容旧路由
      GoRoute(
          path: '/settings/peer-share',
          builder: (_, _) => const PeerHubPage(initialTab: 3)),
      GoRoute(
          path: '/settings/export', builder: (_, _) => const ExportPage()),
      GoRoute(
          path: '/settings/invite', builder: (_, _) => const InvitePage()),
      GoRoute(
          path: '/settings/space', builder: (_, _) => const SpaceInfoPage()),
      GoRoute(
          path: '/settings/chat-wallpaper',
          builder: (_, _) => const ChatWallpaperPage()),
      GoRoute(
          path: '/settings/chat-bubble',
          builder: (_, _) => const ChatBubblePage()),
      // 「数据管理与通知渠道」章 段 A：通知渠道 / 通知中心二级页。
      // 一律 context.push（主页在路由栈）；AppBar 自动返回按钮 +
      // 系统返回手势都能回上一页（widget 用例两条独立路径）。
      GoRoute(path: '/channels', builder: (_, _) => const ChannelsPage()),
      GoRoute(path: '/notices', builder: (_, _) => const NoticesPage()),
      // 「数据管理与通知渠道」章 段 C（2.2.7）：完整备份与存储占用
      // （仅 admin；非 admin 直达由上方 redirect 挡回 /settings）。
      // 一律 context.push 语义，AppBar 自动返回 + 系统手势可回。
      GoRoute(path: '/backups', builder: (_, _) => const BackupsPage()),
      // 条目 8 段 8-A（D1）：生理期独立二级页。hub 🌸 宽卡与聊天 ⊕ 面板
      // 两入口都 context.push('/period')；AppBar 自动返回 + 系统手势可回上一页。
      GoRoute(path: '/period', builder: (_, _) => const PeriodPage()),
      // 条目 8 段 C：生理数据分析独立二级页。主页 analysis-entry 卡
      // context.push('/period/analysis')；AppBar 自动返回 + 系统手势可回主页。
      GoRoute(
        path: '/period/analysis',
        builder: (_, _) => const PeriodAnalysisPage(),
      ),
      // 条目 7 段 7-A / 7-B / 7-C：个人角落五个二级页（一律 context.push，
      // 主页在栈；AppBar 自动返回按钮 + 系统手势都能回上一页）
      GoRoute(
        path: '/personal/diary-form',
        builder: (_, state) {
          final extra = (state.extra as Map?) ?? const {};
          return DiaryFormPage(record: extra['record'] as TogetherRecord?);
        },
      ),
      GoRoute(
        path: '/personal/publish',
        builder: (_, state) {
          final extra = (state.extra as Map?) ?? const {};
          return DraftPublishPage(draft: extra['draft']! as TogetherRecord);
        },
      ),
      GoRoute(
        path: '/personal/surprise-form',
        builder: (_, state) {
          final extra = (state.extra as Map?) ?? const {};
          return SurpriseFormPage(record: extra['record'] as TogetherRecord?);
        },
      ),
      // 7-C 个人心愿：创建表单 / 解锁页（push，不是 go/pushReplacement）
      GoRoute(
        path: '/personal/wish-form',
        builder: (_, _) => const PersonalWishFormPage(),
      ),
      GoRoute(
        path: '/personal/wish-unlock',
        builder: (_, state) {
          final extra = (state.extra as Map?) ?? const {};
          return PersonalWishUnlockPage(
            rid: (extra['rid'] ?? '').toString(),
            title: (extra['title'] ?? '').toString(),
          );
        },
      ),
      // 「我们」工具页（条目 6 · 段 A/B）：hub 宫格 push 进入，二级页规范
      GoRoute(path: '/together/mood', builder: (_, _) => const MoodPage()),
      GoRoute(path: '/together/note', builder: (_, _) => const NotePage()),
      GoRoute(path: '/together/wish', builder: (_, _) => const WishPage()),
      GoRoute(
        path: '/together/anniversary',
        builder: (_, _) => const AnniversaryPage(),
      ),
      GoRoute(
        path: '/together/calendar',
        builder: (_, _) => const CalendarPage(),
      ),
      GoRoute(
        path: '/together/question',
        builder: (_, _) => const QuestionPage(),
      ),
      GoRoute(path: '/together/habit', builder: (_, _) => const HabitPage()),
      GoRoute(path: '/together/quest', builder: (_, _) => const QuestPage()),
      GoRoute(path: '/together/ledger', builder: (_, _) => const LedgerPage()),
      GoRoute(path: '/together/music', builder: (_, _) => const MusicPage()),
      GoRoute(
        path: '/together/dashboard',
        builder: (_, _) => const DashboardPage(),
      ),
      GoRoute(path: '/together/weekly', builder: (_, _) => const WeeklyPage()),
      // 2.8.0 / 真改版式令：一屏四页签报备中心（今日/轨迹/手机/设置），
      // 全部既有路径映射到对应 initialTab，零断链。
      GoRoute(
        path: '/together/peer-report',
        builder: (_, _) => const PeerHubPage(initialTab: 0),
      ),
      GoRoute(
        path: '/together/peer-report/track',
        builder: (_, _) => const PeerHubPage(initialTab: 1),
      ),
      GoRoute(
        path: '/together/peer-report/phone',
        builder: (_, _) => const PeerHubPage(initialTab: 2),
      ),
      // 报备设置页的两个子页：对方视角预览 / 敏感软件多选
      GoRoute(
        path: '/settings/peer-share/preview',
        builder: (_, _) => const PeerPreviewPage(),
      ),
      GoRoute(
        path: '/settings/peer-share/sensitive',
        builder: (_, _) => const PeerSensitivePage(),
      ),
      // 相册查看器（条目 5 · 段 B 甲档）：Hero 共享元素转场 + 跨相册翻页 +
      // InteractiveViewer 缩放 + 下拉跟手关闭 + 计数/caption/预加载 + 下载顶部通知。
      // 二级页一律 context.push：保留主页在路由栈，返回按钮/系统手势回网格。
      GoRoute(
        path: '/album/viewer',
        builder: (_, state) {
          final extra = (state.extra as Map?) ?? const {};
          final photos =
              (extra['photos'] as List?)?.cast<PhotoItem>() ??
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

ThemeData buildAppTheme(
  Color seed,
  Brightness brightness, {
  bool motion = true,
}) {
  final cs = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
  );
  final dark = brightness == Brightness.dark;
  final sheetSurface = dark ? cs.surfaceContainerHigh : cs.surface;
  final sheetBorder = dark
      ? Colors.white.withValues(alpha: 0.12)
      : cs.outlineVariant.withValues(alpha: 0.55);
  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    // 圆角 token 化（段 B G3）：Card 落 12 事实标准（2.1 基线），单源主题。
    cardTheme: CardThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(
          Size(AppTouch.minTarget, AppTouch.minTarget),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontWeight: FontWeight.w600),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.small),
          ),
        ),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return cs.onSurface.withValues(alpha: dark ? 0.18 : 0.14);
          }
          return null;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return cs.onSurface.withValues(alpha: dark ? 0.45 : 0.48);
          }
          return null;
        }),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(
          Size(AppTouch.minTarget, AppTouch.minTarget),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontWeight: FontWeight.w600),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.small),
          ),
        ),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return dark
                ? cs.surfaceContainerHighest.withValues(alpha: 0.32)
                : cs.surfaceContainerHighest.withValues(alpha: 0.50);
          }
          return dark
              ? cs.surfaceContainerHigh.withValues(alpha: 0.55)
              : cs.surface.withValues(alpha: 0.94);
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return cs.onSurface.withValues(alpha: dark ? 0.42 : 0.46);
          }
          return cs.onSurface;
        }),
        side: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return BorderSide(
              color: cs.outline.withValues(alpha: dark ? 0.22 : 0.28),
              width: 1,
            );
          }
          return BorderSide(
            color: dark
                ? Colors.white.withValues(alpha: 0.22)
                : cs.outline.withValues(alpha: 0.52),
            width: 1,
          );
        }),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(
          Size(AppTouch.minTarget, AppTouch.minTarget),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontWeight: FontWeight.w600),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.small),
          ),
        ),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return cs.onSurface.withValues(alpha: dark ? 0.42 : 0.46);
          }
          return null;
        }),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: dark ? cs.surfaceContainerHigh : cs.surface,
      disabledColor: cs.surfaceContainerHighest.withValues(alpha: 0.55),
      selectedColor: cs.primaryContainer,
      labelStyle: TextStyle(color: cs.onSurface),
      secondaryLabelStyle: TextStyle(color: cs.onPrimaryContainer),
      side: BorderSide(
        color: dark
            ? Colors.white.withValues(alpha: 0.14)
            : cs.outline.withValues(alpha: 0.36),
        width: 0.8,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark
          ? cs.surfaceContainerHighest.withValues(alpha: 0.42)
          : cs.surfaceContainerHighest.withValues(alpha: 0.55),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.small),
        borderSide: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.small),
        borderSide: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.small),
        borderSide: BorderSide(color: cs.primary, width: 1.4),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      showDragHandle: false,
      backgroundColor: sheetSurface,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: Colors.black.withValues(alpha: dark ? 0.62 : 0.42),
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.xl),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: sheetSurface,
      surfaceTintColor: Colors.transparent,
      elevation: dark ? 6 : 3,
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: cs.onSurface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.large),
        side: BorderSide(color: sheetBorder, width: 0.8),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: sheetSurface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black.withValues(alpha: dark ? 0.28 : 0.08),
      elevation: dark ? 4 : 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.medium),
        side: BorderSide(color: sheetBorder, width: 0.8),
      ),
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: sheetSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.large),
      ),
    ),
    timePickerTheme: TimePickerThemeData(
      backgroundColor: sheetSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.large),
      ),
    ),
    dividerTheme: DividerThemeData(
      thickness: 1,
      space: 1,
      color: cs.outlineVariant.withValues(alpha: 0.45),
    ),
    // 动效开关（space.motion）：关掉时页面转场/水波纹都退化。
    splashFactory: motion ? null : NoSplash.splashFactory,
    pageTransitionsTheme: motion
        ? const PageTransitionsTheme()
        : const PageTransitionsTheme(
            builders: <TargetPlatform, PageTransitionsBuilder>{
              TargetPlatform.android: _NoMotionTransitionsBuilder(),
              TargetPlatform.iOS: _NoMotionTransitionsBuilder(),
            },
          ),
  );
}

class LoveApp extends ConsumerWidget {
  const LoveApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    // 2.4.5 甲组：通知点击路由（回调由 local_notifications 层调用）
    notifyRouteHandler = (route) => router.push(route);
    // 2.8.1：记录级系统通知点击——payload 只有 record_id + event，
    // 先取记录判 kind，再走与通知中心完全相同的落点判定（两态一致）。
    // 冷启动时首帧可能还没挂载导航器，故取 context 前留一次短暂退避。
    notifyNoticeTapHandler = (recordId, event) async {
      final first = noticeTargetOf(event, recordId);
      if (first.kind == NoticeTargetKind.route) {
        if (first.route.isNotEmpty) router.push(first.route);
        return;
      }
      if (recordId.isEmpty) {
        // 备份/存储等运维通知没有 rid：进通知中心，别开空白页
        router.push('/notices');
        return;
      }
      api.Record? record;
      try {
        final dio = await ref.read(api.dioProvider.future);
        final r = await dio.get('/api/records/$recordId');
        if (r.statusCode == 200 && r.data is Map) {
          record = api.Record.fromJson((r.data as Map).cast<String, dynamic>());
        }
      } catch (_) {
        record = null;
      }
      BuildContext? ctx = router.routerDelegate.navigatorKey.currentContext;
      if (ctx == null) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
        ctx = router.routerDelegate.navigatorKey.currentContext;
      }
      if (record == null) {
        if (ctx != null && ctx.mounted) {
          ref
              .read(chatToastProvider.notifier)
              .show('这条记录已不存在', tone: ChatToastTone.warning);
        }
        return;
      }
      final second = noticeTargetOf(event, recordId, record.kind);
      if (second.kind == NoticeTargetKind.route) {
        router.push(second.route);
        return;
      }
      final me = ref.read(authProvider.notifier).me;
      final sheetCtx = ctx;
      if (sheetCtx != null && me != null && sheetCtx.mounted) {
        await showRecordStorySheet(sheetCtx, record: record, me: me);
      } else {
        router.push('/notices');
      }
    };
    // 🔴 段 D：ThemeData 真的吃到 space.theme / custom_color。
    // spaceAppearanceProvider / appearancePrefsProvider 任一变化都会让
    // MaterialApp 立刻重建（Riverpod 驱动），主题色 + 夜间模式正确叠加。
    final appearance = ref.watch(spaceAppearanceProvider);
    final lightSeed = themeSeedColor(
      appearance.effectiveTheme,
      appearance.effectiveCustomColor,
    );
    final darkSeed = themeSeedColor(
      appearance.effectiveTheme,
      appearance.effectiveCustomColor,
      dark: true,
    );
    final themeMode = ref.watch(appThemeModeProvider);
    final fontScale = ref.watch(appFontScaleProvider);
    final motion = appearance.effectiveMotion;

    return MaterialApp.router(
      title: '恋爱空间',
      theme: buildAppTheme(lightSeed, Brightness.light, motion: motion),
      darkTheme: buildAppTheme(darkSeed, Brightness.dark, motion: motion),
      themeMode: themeMode,
      routerConfig: router,
      // 2.3.7：日期选择器等 Material 组件中文（zh-CN 本地化）。
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN')],
      locale: const Locale('zh', 'CN'),
      // `applyFontScale() :124-127` 等价：--fs-scale 乘数（1 / 1.08 / 1.16）。
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(fontScale)),
        child: Builder(builder: (ctx) => _buildShell(ctx, child)),
      ),
    );
  }

  /// 全局唯一顶部通知宿主（见原 builder 注释）。
  static Widget _buildShell(BuildContext context, Widget? child) => Stack(
    children: [
      child ?? const SizedBox.shrink(),
      const Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: IgnorePointer(child: SafeArea(child: ChatToastHost())),
      ),
    ],
  );
}

/// `motion=false` 时无转场动画（对齐 Web `motion` 关掉轻柔动效）。
class _NoMotionTransitionsBuilder extends PageTransitionsBuilder {
  const _NoMotionTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

class _SplashPage extends StatelessWidget {
  const _SplashPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
