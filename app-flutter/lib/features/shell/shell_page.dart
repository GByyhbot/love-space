/// 主框架（脚手架阶段 1）：底部导航四 Tab + 中央发布占位 + 首页最小内容。
/// SSE 已在认证后启动；首页显示连接状态与 /api/me 摘要，作为端到端打通的证明。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart';
import '../../core/sse/sse_client.dart';

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
    final me = ref.watch(authProvider.notifier).me;
    final sse = ref.watch(sseProvider);
    final pages = [
      _HomeTab(me: me, sse: sse),
      const _PlaceholderTab(title: '时光', note: '阶段 2 · 条目 4 迁移'),
      const _PlaceholderTab(title: '相册', note: '阶段 2 · 条目 5 迁移'),
      const _PlaceholderTab(title: '我们', note: '阶段 2 · 条目 6 迁移'),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(const ['首页', '时光', '相册', '我们'][_tab]),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: '退出登录',
            onPressed: () => ref.read(authProvider.notifier).logout(),
          ),
        ],
      ),
      body: pages[_tab],
      floatingActionButton: FloatingActionButton(
        onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('发布（底部弹窗）在阶段 2 迁移')),
        ),
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

class _HomeTab extends StatelessWidget {
  const _HomeTab({required this.me, required this.sse});
  final MeData? me;
  final SseState sse;

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(me?.spaceName.isEmpty == false ? me!.spaceName : '我们的空间',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text('已登录：${me?.userName ?? '…'}',
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text('未读：通知 ${me?.unread ?? 0} · 私聊 ${me?.chatUnread ?? 0}',
                style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Icon(sse.phase == SsePhase.connected ? Icons.sensors_rounded : Icons.sensors_off_rounded,
                color: sse.phase == SsePhase.connected ? Colors.green : Theme.of(context).colorScheme.outline),
            const SizedBox(width: 10),
            Expanded(child: Text(
              sse.phase == SsePhase.connected
                  ? '实时通道已连接（SSE，增量事件驱动中）'
                  : '实时通道：${sse.phase.name}${sse.lastError == null ? '' : ' · ${sse.lastError}'}',
              style: Theme.of(context).textTheme.bodyMedium,
            )),
          ]),
        ),
      ),
      const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('首页其余内容（恋爱天数 / 今日心情 / 纪念日倒计时）在阶段 2 · 条目 2 迁移'),
        ),
      ),
    ]);
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
