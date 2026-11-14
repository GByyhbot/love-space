/// 主框架（脚手架阶段 1）：底部导航四 Tab + 中央发布占位 + 首页最小内容。
/// SSE 已在认证后启动；首页显示连接状态与 /api/me 摘要，作为端到端打通的证明。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_state.dart';
import '../../core/chat/chat_state.dart';
import '../../core/sse/sse_client.dart';
import '../album/album_page.dart';
import '../home/home_page.dart';
import '../personal/personal_page.dart';
import '../timeline/composer_sheet.dart';
import '../timeline/timeline_page.dart';
import '../together/together_page.dart';

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
      appBar: AppBar(
        title: Text(const ['首页', '时光', '相册', '我们', '个人角落'][_tab]),
        actions: [
          // 私聊入口（对齐 Web 顶栏「私聊」图标，带未读角标；>99 显示 99+）。
          // 🔴 阶段 2 通则：二级页一律 push 打开（保留主页在路由栈），
          // 返回按钮与系统手势都能回上一页。
          IconButton(
            tooltip: '私聊',
            onPressed: () => context.push('/messages'),
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text(unread > 99 ? '99+' : '$unread'),
              child: const Icon(Icons.chat_bubble_outline_rounded),
            ),
          ),
          // 头像入口 → 账号资料页（对齐 Web 账号菜单：资料/邀请/退出都在那里）。
          // 🔴 阶段 2 通则：二级页一律 push 打开（保留主页在路由栈），
          // 系统返回手势/返回键回上一页；只有主页根部按返回才退出 App。
          IconButton(
            tooltip: '账号资料',
            onPressed: () => context.push('/profile'),
            icon: CircleAvatar(
              radius: 14,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text((me?.user.name.isEmpty ?? true)
                      ? '?' : me!.user.name.characters.first,
                  style: TextStyle(fontSize: 13, color: theme.colorScheme.onPrimaryContainer)),
            ),
          ),
        ],
      ),
      body: IndexedStack(index: _tab, children: pages),
      floatingActionButton: FloatingActionButton(
        tooltip: '记录此刻',
        onPressed: () => showComposerSheet(context),
        child: const Icon(Icons.favorite),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        notchMargin: 6,
        // 🔴 P1-2：M3 BottomAppBar 默认左右各 16 padding（bottom_app_bar.dart
        // :221-222），五个 tab 在 W<411 时会 RenderFlex overflow（QA 实测
        // 320→44px / 360→24 / 393→7.5 / 400→4.0）。清零后可用宽 = W，
        // 每侧 Expanded=(W−52)/2，右侧 3×44=132 ≤ (320−52)/2=134，六档全过。
        padding: EdgeInsets.zero,
        child: SizedBox(
          height: 52,
          // 五个 tab 分列中央 52px FAB 缺口两侧：两侧 Expanded 等宽 →
          // 缺口恒在屏幕正中，不挤压 notch；单项宽 44 让右侧 3 项在 W=320
          // 也放得下（3×44=132 ≤ (320−52)/2=134）。
          child: Row(children: [
            Expanded(
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                _navItem(0, Icons.home_rounded, '首页'),
                _navItem(1, Icons.history_rounded, '时光'),
              ]),
            ),
            const SizedBox(width: 52),
            Expanded(
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                _navItem(2, Icons.photo_library_rounded, '相册'),
                _navItem(3, Icons.favorite_rounded, '我们'),
                _navItem(4, Icons.lock_outline_rounded, '角落'),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
  /// 单个导航项（[index] 0..4；onGoTab 由首页快捷入口传入，含 4=角落）
  Widget _navItem(int index, IconData icon, String label) => _NavItem(
        icon: icon,
        label: label,
        index: index,
        current: _tab,
        onTap: () => setState(() => _tab = index),
      );
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.icon, required this.label, required this.index, required this.current, required this.onTap});
  final IconData icon;
  final String label;
  final int index;
  final int current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final active = index == current;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 44,
        height: 52,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 22, color: active ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outline),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(
            fontSize: 11,
            color: active ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outline,
          )),
        ]),
      ),
    );
  }
}
