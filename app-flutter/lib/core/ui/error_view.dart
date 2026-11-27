/// 统一错误态（「UI/布局优化」章段 C 2.3.0/VC230 · G14 收编）。
/// · [AppErrorView]：图标 + 错误文案（errorDetail/detail 原文口径）+ 重试按钮；
///   重试走调用方传入的既有回调（ref.invalidate 原 provider / 控制器 load），
///   组件不碰数据流、不自造数据。加载失败必须有可重试的错误呈现——
///   不是白屏、不是无限转圈、不是只报 toast。
/// · [AppErrorText]：行内错误口径（bodySmall + colorScheme.error），
///   收编裸 TextStyle；用于局部刷新失败等已有呈现位维持行内形态。
/// 纪律：颜色/字阶全走 colorScheme/TextTheme，不写死色/字号。
library;

import 'package:flutter/material.dart';
import '../../core/theme/tokens.dart';
import '../../core/theme/typography.dart';

class AppErrorView extends StatelessWidget {
  const AppErrorView({
    super.key,
    required this.detail,
    required this.onRetry,
  });

  /// 错误文案（detail 原文，调用方透传，组件不改写）。
  final String detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.error_outline_rounded,
              size: 44, color: theme.colorScheme.error),
          const SizedBox(height: Spacing.md),
          Text(detail,
              textAlign: TextAlign.center,
              style: AppType.caption(theme, color: theme.colorScheme.error)),
          const SizedBox(height: Spacing.gap),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('重试'),
          ),
        ]),
      ),
    );
  }
}

/// 行内错误文本（收编裸 TextStyle：统一 bodySmall + colorScheme.error）。
class AppErrorText extends StatelessWidget {
  const AppErrorText(this.text, {super.key, this.textAlign});

  final String text;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return Text(text,
        textAlign: textAlign,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.error));
  }
}
