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

import '../auth/auth_state.dart';
import '../../core/chat/chat_state.dart';
import '../../core/sse/sse_client.dart';
import '../album/album_page.dart';
import '../home/home_page.dart';
import '../notify/system_unread_provider.dart';
import '../personal/personal_page.dart';
import '../timeline/composer_sheet.dart';
import '../timeline/timeline_page.dart';
import '../together/together_page.dart';
import 'web_chrome.dart';

class ShellPage extends ConsumerStatefulWidget {
  const ShellPage({super.key});

  @override
  ConsumerState<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends ConsumerState<ShellPage> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // 认证后启动 SSE（脚手架打底；聊天页阶段直接复用 events 流）
    Future.microtask(() => ref.read(sseProvider.notifier).start());
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
    final unread = ref.watch(chatUnreadProvider);
    // 🔴 段 A：铃铛用「系统未读」/api/me 的 unread（main.py:723），私聊用
    // chatUnreadProvider 的 chat_unread；两个字段严格区分，别写反。
    final systemUnread = ref.watch(systemUnreadProvider);
    final me = ref.watch(authProvider.notifier).me;
    final theme = Theme.of(context);
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
      // 顶栏半透明 80%（Web 原生端 color-mix(--bg 80%)，style.css:2108；
      // AppBar 与 body 上下布局、其后无可模糊内容，不引入 blur——毛玻璃
      // 只 Dock 一个静态区）。
      appBar: AppBar(
        backgroundColor: ChromeColors.of(theme).topbarBg,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        title: Text(const ['首页', '时光', '相册', '我们', '个人角落'][_tab]),
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
          // 头像入口 → 账号资料页（对齐 Web 账号菜单：资料/邀请/退出都在那里）。
          // 🔴 阶段 2 通则：二级页一律 push 打开（保留主页在路由栈），
          // 系统返回手势/返回键回上一页；只有主页根部按返回才退出 App。
          WebAvatarButton(
            onPressed: () => context.push('/profile'),
            initial: (me?.user.name.isEmpty ?? true)
                ? '?'
                : me!.user.name.characters.first,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
          children: [
            Positioned.fill(child: IndexedStack(index: _tab, children: pages)),
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
                onTab: (tab) => setState(() => _tab = tab),
                onCompose: () => showComposerSheet(context),
              ),
            ),
          ],
        ),
    );
  }
}
