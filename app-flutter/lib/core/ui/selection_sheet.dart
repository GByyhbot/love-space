/// 底部选择单（2.4.1 修复包第 15 项通则 B 共享组件）：凡「点开选一个」的
/// 原生下拉/弹出菜单，一律改用本组件——底部 sheet（抓手 + 标题 + 关闭
/// 圆钮）、行式布局、选中行淡紫底 + 右勾、点选即关。
/// 日期/时间选择器沿用已中文化的系统选择器，不在此列。
library;

import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

/// 单个选项。[leading] 可选（封面缩略图/彩色字徽等自定义头部）。
class SelectionOption<T> {
  const SelectionOption({
    required this.value,
    required this.label,
    this.leading,
    this.trailing,
  });

  final T value;
  final String label;
  final Widget? leading;

  /// 选中行右侧的自定义尾缀（默认勾）。
  final Widget? trailing;
}

/// 打开底部选择单并返回选中值（点遮罩/关闭钮取消返回 null）。
Future<T?> showSelectionSheet<T>({
  required BuildContext context,
  required String title,
  required List<SelectionOption<T>> options,
  required T selected,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg))),
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 外壳（同 composer sheet）：抓手 + 标题 + 关闭圆钮。
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 38,
                        height: 4.5,
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: Theme.of(ctx)
                              .colorScheme
                              .outlineVariant
                              .withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      Text(title, style: Theme.of(ctx).textTheme.titleMedium),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close_rounded),
                ),
              ]),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: [
                  for (final opt in options)
                    ListTile(
                      key: Key('selection-${opt.value}'),
                      leading: opt.leading,
                      title: Text(opt.label),
                      // 选中行淡紫底 + 右勾；点选即关。
                      tileColor: opt.value == selected
                          ? Theme.of(ctx)
                              .colorScheme
                              .primaryContainer
                              .withValues(alpha: 0.45)
                          : null,
                      trailing: opt.value == selected
                          ? Icon(Icons.check_rounded,
                              color: Theme.of(ctx).colorScheme.primary)
                          : opt.trailing,
                      onTap: () => Navigator.pop(ctx, opt.value),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
