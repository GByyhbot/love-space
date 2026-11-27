/// 统一空态（「UI/布局优化」章段 C 2.3.0/VC230）。
/// 对齐 2.1 三段式基线：图标 size 44 + colorScheme.outline、titleMedium 主句、
/// bodySmall + colorScheme.outline 副句；页内空态统一纵向留白 48
/// （收编 quest 32 / ledger 24 两种散值，G8 留白归档）。
/// 文案由调用方各自传入，本组件不改任何页面文案。
library;

import 'package:flutter/material.dart';
import '../../core/theme/tokens.dart';
import '../../core/theme/typography.dart';

class AppEmptyView extends StatelessWidget {
  const AppEmptyView({
    super.key,
    required this.icon,
    required this.title,
    required this.hint,
    this.padding = const EdgeInsets.symmetric(vertical: 48),
  });

  final IconData icon;
  final String title;
  final String hint;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Column(children: [
        Icon(icon, size: 44, color: theme.colorScheme.outline),
        const SizedBox(height: Spacing.md),
        Text(title, textAlign: TextAlign.center, style: AppType.title(theme)),
        const SizedBox(height: Spacing.gap),
        Text(hint,
            textAlign: TextAlign.center, style: AppType.caption(theme)),
      ]),
    );
  }
}
