/// 主框架（脚手架阶段 1）：底部导航四 Tab + 中央发布占位 + 首页最小内容。
/// SSE 已在认证后启动；首页显示连接状态与 /api/me 摘要，作为端到端打通的证明。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_state.dart';
import '../../core/chat/chat_state.dart';
import '../../core/sse/sse_client.dart';
import '../home/home_page.dart';
import '../timeline/composer_sheet.dart';
import '../timeline/timeline_page.dart';

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
    // IndexedStack 常驻四个 tab：时光列表/筛选状态切页不丢（时光页状态
    // 挂 keepAlive controller，双保险）
    final pages = [
      HomePage(onGoTab: (tab) => setState(() => _tab = tab)),
      TimelinePage(active: _tab == 1),
      const _PlaceholderTab(title: '相册', note: '阶段 2 · 条目 5 迁移'),
      const _PlaceholderTab(title: '我们', note: '阶段 2 · 条目 6 迁移'),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(const ['首页', '时光', '相册', '我们'][_tab]),
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
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _NavItem(icon: Icons.home_rounded, label: '首页', index: 0, current: _tab, onTap: () => setState(() => _tab = 0)),
            _NavItem(icon: Icons.history_rounded, label: '时光', index: 1, current: _tab, onTap: () => setState(() => _tab = 1)),
            const SizedBox(width: 52),
            _NavItem(icon: Icons.photo_library_rounded, label: '相册', index: 2, current: _tab, onTap: () => setState(() => _tab = 2)),
            _NavItem(icon: Icons.favorite_rounded, label: '我们', index: 3, current: _tab, onTap: () => setState(() => _tab = 3)),
          ],
        ),
      ),
    );
  }
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
        width: 72,
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


class _PlaceholderTab extends StatelessWidget {
  const _PlaceholderTab({required this.title, required this.note});
  final String title;
  final String note;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.construction_rounded, size: 44, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 10),
        Text('$title · $note', style: Theme.of(context).textTheme.bodyMedium),
      ]),
    );
  }
}
