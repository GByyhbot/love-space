/// 报备中心四页签一壳（主要页面真改版式令 · 对齐心邻 V3 原型）。
///
/// 一屏四页签：`今日 / 轨迹 / 手机 / 设置`，使用 [IndexedStack] 常驻状态：
/// · 顶栏：固定真毛玻璃 [AppleGlassAppBar]（返回键 + 当前页签标题 + 右侧副题）；
/// · 底栏：固定液态玻璃四页签导航栏（[LiquidGlassSurface]，与 V3 原型一致）；
/// · 悬浮 `+` 互动钮：今日 / 轨迹 / 手机三页可见（设置页隐藏，与 V3 原型一致），
///   点开「想 TA 一下」互动抽屉 [showPeerPokeSheet]。
///
/// 旧路由 `/together/peer-report`、`/together/peer-report/track`、
/// `/together/peer-report/phone`、`/settings/peer-share` 全部映射到本壳对应
/// [initialTab]（0..3），保证所有既有入口零失效。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/motion.dart';
import '../../core/theme/tokens.dart';
import '../../core/ui/apple_ui.dart';
import '../../core/ui/liquid_glass.dart';
import '../../core/ui/pressable_scale.dart';
import '../settings/peer_share_settings_page.dart';
import 'peer_phone_page.dart';
import 'peer_poke_sheet.dart';
import 'peer_report_page.dart';
import 'peer_track_page.dart';

class PeerHubPage extends ConsumerStatefulWidget {
  const PeerHubPage({super.key, this.initialTab = 0});

  /// 0 = 今日，1 = 轨迹，2 = 手机，3 = 设置。
  final int initialTab;

  @override
  ConsumerState<PeerHubPage> createState() => _PeerHubPageState();
}

class _PeerHubPageState extends ConsumerState<PeerHubPage> {
  late int _tab = widget.initialTab.clamp(0, 3);

  /// 懒建保活集合：仅首次切到的页签才创建实体树，建后由 IndexedStack 保活，
  /// 避免在今日/设置等非地图页签时提前创建轨迹页 AndroidView。
  late final Set<int> _activated = <int>{_tab};

  static const List<({String title, String sub, IconData icon, String label})>
      _tabs = [
    (
      title: '今日',
      sub: '实时状态 · 双方透明',
      icon: Icons.schedule_rounded,
      label: '今日',
    ),
    (
      title: '轨迹',
      sub: '实时路线 · 时间轴回放',
      icon: Icons.location_on_rounded,
      label: '轨迹',
    ),
    (
      title: '手机使用',
      sub: '24h 分布 · 软件时间流',
      icon: Icons.smartphone_rounded,
      label: '手机',
    ),
    (
      title: '报备设置',
      sub: '随时可关 · 双方透明',
      icon: Icons.verified_user_rounded,
      label: '设置',
    ),
  ];

  void _setTab(int index) {
    final next = index.clamp(0, 3);
    if (next == _tab) return;
    setState(() {
      _tab = next;
      _activated.add(next);
    });
  }

  Widget _buildTab(int index) {
    if (!_activated.contains(index)) {
      return const SizedBox.shrink();
    }
    return switch (index) {
      0 => PeerReportPage(
          embedded: true,
          onSwitchTab: _setTab,
        ),
      1 => PeerTrackPage(
          embedded: true,
          onSwitchTab: _setTab,
        ),
      2 => PeerPhonePage(
          embedded: true,
          onSwitchTab: _setTab,
        ),
      3 => const PeerShareSettingsPage(
          embedded: true,
        ),
      _ => const SizedBox.shrink(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight;
    final meta = _tabs[_tab];

    return Scaffold(
      backgroundColor: appleCanvasColor(theme),
      extendBodyBehindAppBar: true,
      appBar: AppleGlassAppBar(
        collapsedTitle: meta.title,
        collapseProgress: 1.0,
        leading: IconButton(
          key: const Key('peer-hub-back'),
          tooltip: '返回',
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              Navigator.of(context).maybePop();
            }
          },
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 18,
            color: cs.onSurface,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: Spacing.lg),
            child: Center(
              child: Text(
                meta.sub,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.outline,
                ),
              ),
            ),
          ),
        ],
      ),
      body: ApplePageBackground(
        child: Stack(
          children: [
            Positioned.fill(
              child: ShellChromeScope(
                topInset: topInset,
                child: IndexedStack(
                  index: _tab,
                  children: [
                    for (var i = 0; i < 4; i++) _buildTab(i),
                  ],
                ),
              ),
            ),
            // V3 悬浮 `+` 互动按钮（今日 / 轨迹 / 手机三页展示，设置页隐藏）
            if (_tab != 3)
              Positioned(
                right: 18,
                bottom: bottomPad + 92,
                child: PressableScale(
                  onTap: () => showPeerPokeSheet(context, ref),
                  child: Container(
                    key: const Key('peer-hub-fab'),
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: cs.primary,
                      boxShadow: [
                        BoxShadow(
                          color: cs.primary.withValues(alpha: dark ? 0.45 : 0.34),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Material(
                      type: MaterialType.transparency,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => showPeerPokeSheet(context, ref),
                        child: Icon(
                          Icons.add_rounded,
                          size: 26,
                          color: cs.onPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // V3 底部四页签液态玻璃导航栏
            Positioned(
              left: 12,
              right: 12,
              bottom: bottomPad + 10,
              child: LiquidGlassSurface(
                key: const Key('peer-hub-tabbar'),
                borderRadius: BorderRadius.circular(24),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Row(
                  children: [
                    for (var i = 0; i < _tabs.length; i++)
                      Expanded(
                        child: _HubTabItem(
                          key: Key('peer-hub-tab-$i'),
                          icon: _tabs[i].icon,
                          label: _tabs[i].label,
                          selected: _tab == i,
                          onTap: () => _setTab(i),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HubTabItem extends StatelessWidget {
  const _HubTabItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final fg = selected
        ? (dark ? cs.onPrimaryContainer : cs.primary)
        : (dark ? cs.outline : cs.onSurfaceVariant);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Curves.easeOutCubic,
        height: 48,
        decoration: BoxDecoration(
          color: selected
              ? (dark
                  ? cs.primaryContainer.withValues(alpha: 0.72)
                  : cs.primaryContainer.withValues(alpha: 0.78))
              : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          border: selected && !dark
              ? Border.all(
                  color: cs.primary.withValues(alpha: 0.24),
                  width: 0.7,
                )
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: fg),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
