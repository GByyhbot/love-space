/// 底部选择单（2.4.1 修复包第 15 项通则 B 共享组件）：凡「点开选一个」的
/// 原生下拉/弹出菜单，一律改用本组件——底部 sheet（抓手 + 标题 + 关闭
/// 圆钮）、行式布局、选中行淡紫底 + 右勾、点选即关。
/// 日期/时间选择器沿用已中文化的系统选择器，不在此列。
library;

import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import 'apple_ui.dart';

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
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final cs = theme.colorScheme;
      final dark = theme.brightness == Brightness.dark;
      return AppleSheetContainer(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        title: title,
        onClose: () => Navigator.pop(ctx),
        maxHeightFactor: 0.65,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          children: [
            for (final opt in options)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Material(
                  color: opt.value == selected
                      ? cs.primaryContainer.withValues(alpha: dark ? 0.58 : 0.72)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadius.small),
                  child: InkWell(
                    key: Key('selection-${opt.value}'),
                    borderRadius: BorderRadius.circular(AppRadius.small),
                    onTap: () => Navigator.pop(ctx, opt.value),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      decoration: opt.value == selected
                          ? BoxDecoration(
                              borderRadius:
                                  BorderRadius.circular(AppRadius.small),
                              border: Border.all(
                                color: cs.primary.withValues(alpha: 0.28),
                                width: 0.8,
                              ),
                            )
                          : null,
                      child: Row(
                        children: [
                          if (opt.leading != null) ...[
                            opt.leading!,
                            const SizedBox(width: Spacing.md),
                          ],
                          Expanded(
                            child: Text(
                              opt.label,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontWeight: opt.value == selected
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: opt.value == selected
                                    ? (dark
                                        ? cs.onPrimaryContainer
                                        : cs.onSurface)
                                    : cs.onSurface,
                              ),
                            ),
                          ),
                          if (opt.value == selected)
                            Icon(Icons.check_rounded, color: cs.primary)
                          else if (opt.trailing != null)
                            opt.trailing!,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
