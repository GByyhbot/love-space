/// 2.3.6 发布抽屉（主人构想、效果图已拍板）：Dock 上滑 / 点把手唤出，
/// 底部升起 sheet——顶 radius 26、chrome 语义色（dockBg/dockLine 同族）、
/// 顶部内把手；标题「记录此刻」+ 副题；类型快捷格 3 列 × 2 行。
///
/// 🔴 目标映射以现行入口实读为唯一事实（composer 弹层唯一 kind=post + 媒体
/// 入口；mood 需 emoji 选择器、surprise 需 publish_at、ledger 结构独立——
/// composer 表单不兼容）：
/// · 发动态/传照片 → composer 弹层原链（传照片自动触发图/视频选择）；
/// · 记心情/写日记/留惊喜/记一笔 → 各自既有入口页（数据流/请求零变化）。
/// 抽屉只在壳层出现（五个 tab 均可唤出），二级页不出现（由调用方位置保证）。
/// 关闭：下滑（sheet 默认 drag handle）+ 点遮罩 + 系统返回，与现行 sheet 一致。
library;

import 'package:flutter/material.dart';

import '../../core/theme/motion.dart';
import '../../core/theme/tokens.dart';
import '../../core/ui/apple_ui.dart';
import 'web_chrome.dart';

/// 六个类型快捷项（名称/图标/emoji/图标徽章色系语义对齐）。
enum ComposerDrawerAction {
  post('发动态', '📝', Icons.edit_note_rounded, AppleIconTone.rose),
  photo('传照片', '📷', Icons.photo_camera_rounded, AppleIconTone.sky),
  mood('记心情', '🌤', Icons.wb_sunny_rounded, AppleIconTone.amber),
  diary('写日记', '📖', Icons.menu_book_rounded, AppleIconTone.purple),
  surprise('留惊喜', '🎁', Icons.card_giftcard_rounded, AppleIconTone.pink),
  ledger('记一笔', '💰', Icons.account_balance_wallet_rounded, AppleIconTone.emerald);

  const ComposerDrawerAction(this.label, this.emoji, this.icon, this.tone);
  final String label;
  final String emoji;
  final IconData icon;
  final AppleIconTone tone;
}

/// 唤出发布抽屉。[onPick] 在选中类型并关闭抽屉后回调（外层执行跳转）。
Future<void> showComposerDrawerSheet(
  BuildContext context, {
  required ValueChanged<ComposerDrawerAction> onPick,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: false,
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    builder: (_) => ComposerDrawerSheet(onPick: onPick),
  );
}

class ComposerDrawerSheet extends StatelessWidget {
  const ComposerDrawerSheet({super.key, required this.onPick});

  final ValueChanged<ComposerDrawerAction> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final colors = ChromeColors.of(theme);
    final actions = ComposerDrawerAction.values;
    // 3 列 × 2 行：前 3 一行、后 3 一行。
    final rows = <List<ComposerDrawerAction>>[
      actions.sublist(0, 3),
      actions.sublist(3),
    ];
    return Container(
      decoration: BoxDecoration(
        color: dark ? cs.surfaceContainerHigh : cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
        border: Border(
          top: BorderSide(
            color: dark
                ? Colors.white.withValues(alpha: 0.14)
                : cs.outlineVariant.withValues(alpha: 0.55),
            width: 0.8,
          ),
        ),
        boxShadow: appleCardShadows(dark, elevated: true),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 顶部唯一抓手（抽屉打开期间 Dock 自身横条隐藏，画面仅此一条）
              Center(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).pop(),
                  child: SizedBox(
                    width: 48,
                    height: 24,
                    child: Center(
                      child: Container(
                        key: const Key('composer-drawer-handle'),
                        width: ChromeMetrics.dockHandleWidth,
                        height: ChromeMetrics.dockHandleHeight,
                        decoration: BoxDecoration(
                          color: colors.dockHandle,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              // 标题 + 副题 + 右侧关闭圆钮
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('记录此刻',
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text('选一种方式，把它留下来。',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  AppleSheetCloseButton(
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // 3 列 × 2 行类型格
              for (final row in rows) ...[
                Row(
                  children: [
                    for (final a in row)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: _actionCard(context, a, cs, dark),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionCard(
    BuildContext context,
    ComposerDrawerAction a,
    ColorScheme cs,
    bool dark,
  ) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('drawer-item-${a.name}'),
        borderRadius: BorderRadius.circular(AppRadius.medium),
        onTap: () {
          Navigator.of(context).pop(); // 先关抽屉（与现行 sheet 行为一致）
          onPick(a);
        },
        child: AnimatedContainer(
          duration: Motion.fast,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
          decoration: BoxDecoration(
            color: dark
                ? cs.surfaceContainerHighest.withValues(alpha: 0.55)
                : cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(AppRadius.medium),
            border: Border.all(
              color: dark
                  ? Colors.white.withValues(alpha: 0.10)
                  : cs.outline.withValues(alpha: 0.22),
              width: 0.8,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppleIconBadge(icon: a.icon, tone: a.tone, size: 38),
              const SizedBox(height: 8),
              Text(a.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w600,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}
