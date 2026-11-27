/// 主框架（脚手架阶段 1）：底部导航五 Tab + 中央发布 + 首页等五页 IndexedStack。
/// SSE 已在认证后启动；首页显示连接状态与 /api/me 摘要，作为端到端打通的证明。
///
/// 2.3.1（视觉对齐 Web 试点段）：chrome 浮层重构（方案 A，web-visual-plan.md
/// 3.2① 定稿）——`bottomNavigationBar` 置 null，底栏改悬浮 Dock（距边 10、
/// radius 24、玻璃底 blur18 saturate1.25，见 web_chrome.dart，出处逐条标注）；
/// 顶栏三动作改 42×42 圆钮 + surface 外圈角标（style.css:278-287）。🔴 红线：
/// 五 tab 结构 / IndexedStack / 手势 / 路由 / provider 零变化，「角落」仍是
/// 第 5 tab；Dock 常驻 ShellPage Stack，push 覆盖自然遮住（盘点 3.2③）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../auth/auth_state.dart';
import '../../core/chat/chat_state.dart';
import '../../core/notify/notify_service.dart' show NotifyCoordinator, onAppResumedReload;
import '../../core/peer/peer_permissions.dart';
import '../../core/sse/sse_client.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/tokens.dart';
import '../../core/ui/apple_ui.dart';
import '../album/album_page.dart';
import '../home/home_page.dart';
import '../notify/system_unread_provider.dart';
import '../personal/personal_page.dart';
import '../settings/peer_permission_sheet.dart';
import '../timeline/composer_sheet.dart';
import '../timeline/photo_upload_sheet.dart';
import 'composer_drawer.dart';
import '../timeline/timeline_page.dart';
import '../together/together_page.dart';
import '../update/update_service.dart'
    show autoCheckSilently, purgeApkCache;
import 'web_chrome.dart';

class ShellPage extends ConsumerStatefulWidget {
  const ShellPage({super.key});

  @override
  ConsumerState<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends ConsumerState<ShellPage> {
  int _tab = 0;
  bool _drawerOpen = false;

  /// 各 Tab 的滚动收起进度（0.0 = 顶部展开，1.0 = 滚过页头后紧凑标题淡入顶栏）。
  final List<double> _collapseByTab = <double>[0, 0, 0, 0, 0];

  static const List<String> _tabTitles = <String>[
    '首页',
    '时光',
    '相册',
    '我们',
    '角落',
  ];

  bool _onTabScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    final next = ((notification.metrics.pixels - 16) / 36).clamp(0.0, 1.0);
    if ((next - _collapseByTab[_tab]).abs() > 0.04) {
      setState(() => _collapseByTab[_tab] = next);
    }
    return false;
  }

  @override
  void initState() {
    // 2.5.9 条目二时机①：回前台必刷回调注入（NotifyCoordinator 生命周期上报处调用）
    onAppResumedReload = () => ref.read(authProvider.notifier).reload();
    super.initState();
    // 认证后启动 SSE（脚手架打底；聊天页阶段直接复用 events 流）
    Future.microtask(() => ref.read(sseProvider.notifier).start());
    // 2.4.5 甲组：进入主框架（已登录态）→ 服务配置注入 + 拉起前台服务 +
    // 生命周期/线路跟随上报 + 消费服务判定结果。登出时 dispose → leaveShell。
    Future.microtask(() async {
      try {
        await NotifyCoordinator.instance.enterShell(ref);
      } catch (_) {
        // 通知装配失败绝不影响主链（无权限/插件异常等）
      }
    });
    // 2.4.3 提交三：冷启动自动检查更新（可观测链：6h 节流+静默+不冒泡）。
    // 必须异步且隔离（不进首页构建路径）；先清历史安装包再检查。
    Future.microtask(() async {
      try {
        await purgeApkCache();
        final info = await PackageInfo.fromPlatform();
        if (!mounted) return;
        await autoCheckSilently(ref, context, info.version);
      } catch (_) {
        // 自动检查异常绝不影响启动/首页
      }
    });
    // 首次安装主动弹出权限引导（使用共用权限清单弹层，仅首次触发一次）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkFirstInstallPermissions();
    });
  }

  Future<void> _checkFirstInstallPermissions() async {
    try {
      final snap = await peerPermissionStatus();
      if (!mounted) return;
      if (!await shouldShowFirstInstallPermissionGuide(snap) || !mounted) {
        return;
      }
      await markFirstInstallPermissionGuideDone();
      if (!mounted) return;
      await showPeerPermissionGuideSheet(
        context,
        initialSnapshot: snap,
        isFirstInstall: true,
      );
    } catch (_) {
      // 权限引导异常绝不影响主链
    }
  }

  Future<void> _openComposerDrawer() async {
    if (_drawerOpen) return;
    setState(() => _drawerOpen = true);
    try {
      await showComposerDrawerSheet(
        context,
        onPick: (action) {
          switch (action) {
            case ComposerDrawerAction.post:
              showComposerSheet(context);
            case ComposerDrawerAction.photo:
              showPhotoUploadSheet(context);
            case ComposerDrawerAction.mood:
              context.push('/together/mood');
            case ComposerDrawerAction.diary:
              context.push('/personal/diary-form');
            case ComposerDrawerAction.surprise:
              context.push('/personal/surprise-form');
            case ComposerDrawerAction.ledger:
              context.push('/together/ledger');
          }
        },
      );
    } finally {
      if (mounted) setState(() => _drawerOpen = false);
    }
  }

  @override
  void dispose() {
    // 2.4.5 甲组：退出主框架（登出/会话失效被 redirect 走）→ 停服务（未登录不空跑）
    NotifyCoordinator.instance.leaveShell();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // SSE chat 事件（聊天页未打开时）→ 重拉 me 更新未读角标（Web syncBadge 同口径）；
    // 页面已打开时由聊天页自己对账 + 清未读，不需要动角标
    ref.listen(sseEventsProvider, (prev, next) {
      if (next.value?.chat == true && !ref.read(chatPageActiveProvider)) {
        ref.read(authProvider.notifier).reload();
      }
    });
    // 2.5.9 条目二时机②：SSE 每次（重）连接成功 → 补一次 reload，
    // 堵断线期间漏掉的事件（回前台 resume 由 NotifyCoordinator 上报 + reload）
    ref.listen(sseProvider, (prev, next) {
      if (next.phase == SsePhase.connected &&
          prev?.phase != SsePhase.connected) {
        ref.read(authProvider.notifier).reload();
      }
    });
    // 2.5.9 条目二时机③：退出聊天页 → reload 一次（页内新消息已在页内呈现，
    // 角标回到服务端真实值）
    ref.listen(chatPageActiveProvider, (prev, next) {
      if (prev == true && next == false) {
        ref.read(authProvider.notifier).reload();
      }
    });
    final unread = ref.watch(chatUnreadProvider);
    // 🔴 段 A：铃铛用「系统未读」/api/me 的 unread（main.py:723），私聊用
    // chatUnreadProvider 的 chat_unread；两个字段严格区分，别写反。
    final systemUnread = ref.watch(systemUnreadProvider);
    final me = ref.watch(authProvider.notifier).me;
    final theme = Theme.of(context);
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight;
    // IndexedStack 常驻五个 tab：时光列表/筛选状态切页不丢（时光页状态
    // 挂 keepAlive controller，双保险）；条目 7 段 7-A 新增「角落」第 5 页。
    final pages = [
      HomePage(onGoTab: (tab) => setState(() => _tab = tab)),
      TimelinePage(active: _tab == 1),
      AlbumPage(active: _tab == 2),
      // 条目 6 段 B：hub 宫格（纪念日展示卡直达管理页 /together/anniversary）
      TogetherPage(active: _tab == 3),
      // 条目 7 段 7-A：个人角落（页内 diary / draft 两 tab；发布 post 由控制器
      // 显式触发时光重拉，无需 active 门控，故不传 active 死参数）
      const PersonalPage(),
    ];
    return Scaffold(
      backgroundColor: appleCanvasColor(theme),
      // 真玻璃壳层：正文滚入毛玻璃顶栏背后，顶栏紧凑标题随滚动平滑淡入。
      extendBodyBehindAppBar: true,
      appBar: AppleGlassAppBar(
        collapsedTitle: _tabTitles[_tab],
        collapseProgress: _collapseByTab[_tab],
        actions: [
          // 「数据管理与通知渠道」章 段 A：通知中心铃铛（对齐 Web 顶栏
          // 「通知」图标 `app.js:325`）。角标用 me.unread（系统未读总数，
          // main.py:723），>99 显示 99+；与下方私聊的 chat_unread 严格
          // 区分。context.push('/notices')，返回按钮 / 系统手势可回。
          WebTopIconButton(
            key: const Key('shell-notices'),
            tooltip: '通知',
            onPressed: () => context.push('/notices'),
            icon: Icons.notifications_none_rounded,
            badge: systemUnread > 0
                ? WebBadge(unreadBadgeLabel(systemUnread))
                : null,
          ),
          // 钮组间距 9（Web 手机档 topbar-right gap，style.css:1399）
          const SizedBox(width: ChromeMetrics.topBtnGap),
          // 私聊入口（对齐 Web 顶栏「私聊」图标，带未读角标；>99 显示 99+）。
          // 🔴 阶段 2 通则：二级页一律 push 打开（保留主页在路由栈），
          // 返回按钮与系统手势都能回上一页。
          WebTopIconButton(
            tooltip: '私聊',
            onPressed: () => context.push('/messages'),
            icon: Icons.chat_bubble_outline_rounded,
            badge: unread > 0 ? WebBadge(unread > 99 ? '99+' : '$unread') : null,
          ),
          const SizedBox(width: ChromeMetrics.topBtnGap),
          // 2.4.0 设置拆分段：齿轮入口（五 tab 顶栏通用，头像左侧）。
          // 🔴 齿轮是顶栏组件本体的一部分（WebTopIconButton 同款 42px
          // 圆形玻璃钮），禁止任何悬浮 overlay（首页冻结教训）；
          // push /settings（设置主页），返回回到原 tab（IndexedStack 保留）。
          WebTopIconButton(
            key: const Key('shell-settings'),
            tooltip: '设置',
            onPressed: () => context.push('/settings'),
            icon: AppIcons.settings,
          ),
          const SizedBox(width: ChromeMetrics.topBtnGap),
          // 头像入口 → 账号资料页（对齐 Web 账号菜单：资料/邀请/退出都在那里）。
          // 🔴 阶段 2 通则：二级页一律 push 打开（保留主页在路由栈），
          // 系统返回手势/返回键回上一页；只有主页根部按返回才退出 App。
          WebAvatarButton(
            onPressed: () => context.push('/profile'),
            initial: (me?.user.name.isEmpty ?? true)
                ? '?'
                : me!.user.name.characters.first,
            // 2.3.7：照片头像（media id 来自 users.avatar）
            avatarId: me?.user.avatar ?? '',
          ),
          const SizedBox(width: Spacing.xs),
        ],
      ),
      body: ApplePageBackground(
        child: Stack(
          children: [
            Positioned.fill(
              child: ShellChromeScope(
                topInset: topInset,
                child: NotificationListener<ScrollNotification>(
                  onNotification: _onTabScroll,
                  child: IndexedStack(index: _tab, children: pages),
                ),
              ),
            ),
            // 悬浮 Dock（方案 A 浮层，web-visual-plan.md 3.2①）：距左右下各
            // 10px + 底部安全区透传（Web inset:auto 10px calc(10px+safe)，
            // style.css:2738）；bottomNavigationBar 已置 null，Scaffold body
            // 保留 MediaQuery 底部安全区，Dock 自己消费。
            Positioned(
              left: ChromeMetrics.dockInset,
              right: ChromeMetrics.dockInset,
              bottom:
                  ChromeMetrics.dockInset + MediaQuery.of(context).padding.bottom,
              child: WebDock(
                key: const Key('shell-dock'),
                currentIndex: _tab,
                hideHandle: _drawerOpen,
                onTab: (tab) => setState(() => _tab = tab),
                onOpenDrawer: _openComposerDrawer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
