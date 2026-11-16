/// 段 A 两个二级页共用的小型 UI 组件（内联错误区 / 说明卡 / 空态）。
///
/// 🔴 内联错误区是「服务端 detail 原文双呈现」的一半：另一半是顶部
/// `chatToastProvider(error tone)`。写失败时两者同时出现，输入保留、
/// 不发成功通知、不 pop、不自动重试。
library;

import 'package:flutter/material.dart';
import '../../core/theme/tokens.dart';

/// 服务端错误文案原文的内联错误区。
class NotifyErrorBanner extends StatelessWidget {
  const NotifyErrorBanner({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline_rounded, size: 18, color: cs.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              key: const Key('notify-inline-error'),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// 页面口径说明卡（WebPush 原生跳过 / 配置不回传 / 无编辑 / 订阅语义）。
class NotifyInfoCard extends StatelessWidget {
  const NotifyInfoCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.lines,
  });

  final String title;
  final String subtitle;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.cardPad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(subtitle,
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
            const SizedBox(height: 10),
            for (final String line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('· ', style: TextStyle(color: cs.outline)),
                    Expanded(
                      child: Text(
                        line,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.outline, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 空态卡（标题 + 说明，全部为静态文案，不来自本地推算）。
class NotifyEmptyCard extends StatelessWidget {
  const NotifyEmptyCard({
    super.key,
    required this.title,
    required this.detail,
  });

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: <Widget>[
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: Spacing.gapTight),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
