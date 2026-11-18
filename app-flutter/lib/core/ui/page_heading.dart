/// 页头标题行（2.4.1 修复包第 9 项）：五个 tab 页共用同一标题行组件与
/// 同一套共享常量——大标题同一字号（以时光页 headlineSmall(24)/600/
/// ls-0.3 为基准）、副标题同一字号同一颜色、大标题与副标题间距同一数值
/// （4）、标题行距顶栏间距五页同一数值且比现状收紧一档（12 → 8）。
/// 后续改一处全改，禁止各页手写数值。
library;

import 'package:flutter/material.dart';

/// 大标题字号（headlineSmall 24 为基准，主人裁定以时光页现字号为准）。
const double pageHeadingTitleSize = 24;

/// 大标题与副标题间距（五页同一数值）。
const double pageHeadingInnerGap = 4;

/// 标题行距顶栏间距（时光页原 12 收紧约 1/3 → 8，五页同一数值）。
const double pageHeadingTopGap = 8;

/// 共享大标题样式（五页引用同一处，禁止各页手写）。
TextStyle pageTitleStyle(ThemeData theme) =>
    theme.textTheme.headlineSmall!.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: -0.3,
    );

/// 共享副标题样式（同一字号、同一颜色）。
TextStyle pageSubtitleStyle(ThemeData theme) =>
    theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.outline,
    );

/// 标题行组件：五页（时光/相册/我们/个人角落/首页）统一引用。
/// [trailing] 可选（部分页保留右侧动作位）。
/// [embedded] = true：页面滚动容器自身供左右内边距与顶部间距（2.4.2 第 4
/// 项，供懒加载 ListView 里需要随页滚动的首页用）——组件只保留顶部
/// pageHeadingTopGap，不再叠加左右 16，避免双重内边距把标题挤成 32；
/// 常量仍同源，页面不得自写数值。默认 false（自带 16/8，直接放 Column）。
class PageHeading extends StatelessWidget {
  const PageHeading({
    super.key,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.embedded = false,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: embedded
          ? const EdgeInsets.only(top: pageHeadingTopGap)
          : const EdgeInsets.fromLTRB(16, pageHeadingTopGap, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: pageTitleStyle(theme)),
                SizedBox(height: pageHeadingInnerGap),
                Text(subtitle, style: pageSubtitleStyle(theme)),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
