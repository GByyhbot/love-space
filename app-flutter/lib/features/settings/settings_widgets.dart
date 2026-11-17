/// 2.4.1 修复包共享组件（第 6 项 + 第 3 项 + 注脚口径）：
/// · [SettingsGlassBar]：底部玻璃操作栏——固定页面底部、毛玻璃底、
///   取消占 1/3（描边）+ 保存占 2/3（实心主色）；单动作页传 null 取消
///   即整行保存。appearance/cover/chat-wallpaper/links/export/profile
///   各页复用同一组件，禁止各页各写一份。
/// · [SettingsSegmented]：圆角分段器——整行等分、容器淡底圆角 14、
///   选中段实心主色深字、未选段透明底弱化字（第 2 项夜间/字号与
///   第 8 项相册分段器共用）。
/// · [SettingsFootnote]：页脚注脚样式（小字、弱化色）。
/// 🔴 毛玻璃只用于静态区（定案 #3：冻结教训——Dock/操作栏均静态区）；
///    本组件是页面布局的组成部分（widget 本体），不是悬浮 overlay。
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';


/// 圆角填充输入装饰（第 5 项②口径，12/13/14/15 各表单复用）：
/// 圆角 12、淡底、标签在框上方（调用方用 Column[Text(label), 6, TextField]）。
InputDecoration filledFieldDecoration({String? hint, Widget? suffixIcon}) =>
    InputDecoration(
      hintText: hint,
      suffixIcon: suffixIcon,
      filled: true,
      isDense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.transparent),
      ),
    );

/// 页脚注脚（第 5 项：原页面说明文字降级；小字 + 弱化色）。
class SettingsFootnote extends StatelessWidget {
  const SettingsFootnote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context)
          .textTheme
          .labelSmall
          ?.copyWith(color: Theme.of(context).colorScheme.outline),
    );
  }
}

/// 圆角分段器（第 2 项夜间/字号、第 8 项相册分类共用同一组件）。
class SettingsSegmented<T> extends StatelessWidget {
  const SettingsSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  /// (值, 标签) 有序清单——顺序即渲染顺序。
  final List<(T, String)> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      // 容器淡底 + 圆角 14（简报第 3 项口径）
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (final (value, label) in segments)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(value),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    // 选中段实心主色深字；未选段透明底弱化字。
                    color: selected == value
                        ? cs.primary
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: selected == value
                              ? cs.onPrimary
                              : cs.outline,
                          fontWeight:
                              selected == value ? FontWeight.w600 : null,
                        ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 底部玻璃操作栏（第 6 项）：毛玻璃底固定页面底部；[onCancel] 传 null
/// 时保存整行（单动作页），否则取消 1/3 描边 + 保存 2/3 实心主色。
/// 页面内容底部需留出 [barReserveHeight] 等高内边距防遮挡。
class SettingsGlassBar extends StatelessWidget {
  const SettingsGlassBar({
    super.key,
    this.cancelLabel,
    this.onCancel,
    required this.saveLabel,
    required this.onSave,
    this.saveEnabled = true,
    this.busy = false,
  });

  final String? cancelLabel;
  final VoidCallback? onCancel;
  final String saveLabel;
  final VoidCallback onSave;
  final bool saveEnabled;
  final bool busy;

  /// 页面内容底部需预留的高度（栏体 + 底部安全区由页面自行叠加）。
  static const double barReserveHeight = 88;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bright = Theme.of(context).brightness;
    // 玻璃底：bg 80% 不透明等效（Web 顶栏 color-mix 口径，style.css:2108）。
    final glassColor = bright == Brightness.dark
        ? const Color(0xCC231B1D)
        : const Color(0xCCFAF8F9);
    Widget bar = Container(
      decoration: BoxDecoration(
        color: glassColor,
        border: Border(
          top: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              if (cancelLabel != null) ...[
                Expanded(
                  flex: 1,
                  child: OutlinedButton(
                    onPressed: busy ? null : onCancel,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: Text(cancelLabel!),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                flex: cancelLabel != null ? 2 : 1,
                child: FilledButton(
                  onPressed: saveEnabled && !busy ? onSave : null,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(saveLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // 毛玻璃（静态区允许，冻结教训 #3）。
    bar = ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: bar,
      ),
    );
    return bar;
  }
}

/// 页面骨架：内容 + 固定底部玻璃操作栏（Stack 组合，栏属页面本体）。
class SettingsGlassScaffold extends StatelessWidget {
  const SettingsGlassScaffold({
    super.key,
    required this.appBar,
    required this.children,
    required this.bar,
    this.listController,
  });

  final PreferredSizeWidget appBar;
  final List<Widget> children;
  final SettingsGlassBar bar;
  final ScrollController? listController;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBar,
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              controller: listController,
              padding: const EdgeInsets.fromLTRB(
                16, 12, 16, SettingsGlassBar.barReserveHeight + 12),
              children: children,
            ),
          ),
          Positioned(left: 0, right: 0, bottom: 0, child: bar),
        ],
      ),
    );
  }
}
