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

import '../../core/ui/apple_ui.dart';
import '../../core/ui/submit_morph.dart';

/// 表单底部 sheet 骨架（2.4.1 通则 A 共用外壳）：全仓录入类弹窗/表单
/// 一律套同一外壳——抓手 + 标题 + 关闭圆钮 + 内容（键盘升高）+
/// GlassActionBar（取消 1/3 描边 + 保存 2/3 实心；cancelLabel null =
/// 整行保存）。返回 true=保存关闭 / false=取消 / null=点遮罩关闭。
/// [onSave] 校验通过后调用 [closeOk] 关闭（不关即留在 sheet 继续编辑）。
/// 2.4.10 第 02 项：[asyncSave] 传入时保存按钮走「提交三连变」——
/// 请求中弹层保持打开（按钮收缩圆+旋转环），返回 true 才关弹层；
/// false/异常 = 留在弹层，错误提示由调用方走既有通道（改掉旧
/// 「先关后请求」时序，主人已裁定）。
Future<bool?> showFormSheet(
  BuildContext context, {
  required String title,
  required String saveLabel,
  String? cancelLabel,
  required Widget Function(StateSetter setState) builder,
  required void Function(void Function() closeOk, StateSetter setState) onSave,
  Future<bool> Function()? asyncSave,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    builder: (sheetCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheetState) => AppleSheetContainer(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        title: title,
        onClose: () => Navigator.of(sheetCtx).pop(false),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(child: builder(setSheetState)),
            ),
            const SizedBox(height: 10),
            GlassActionBar(
              safeAreaBottom: false,
              cancelLabel: cancelLabel,
              onCancel: () => Navigator.of(sheetCtx).pop(false),
              saveLabel: saveLabel,
              onSave: () =>
                  onSave(() => Navigator.of(sheetCtx).pop(true), setSheetState),
              morphOnSave: asyncSave,
              onMorphSuccess: () => Navigator.of(sheetCtx).pop(true),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 圆角填充输入装饰（第 5 项②口径，12/13/14/15 各表单复用）：
/// 圆角 12、淡底、标签在框上方（调用方用 Column[Text(label), 6, TextField]）。
InputDecoration filledFieldDecoration(
        {String? hint, Widget? suffixIcon, String? counterText,
        bool alignLabelWithHint = false, String? prefixText,
        TextStyle? prefixStyle}) =>
    InputDecoration(
      hintText: hint,
      suffixIcon: suffixIcon,
      counterText: counterText,
      alignLabelWithHint: alignLabelWithHint,
      prefixText: prefixText,
      prefixStyle: prefixStyle,
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
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Container(
      // 容器淡底 + 圆角 14（简报第 3 项口径）
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: dark
            ? cs.surfaceContainerHighest.withValues(alpha: 0.55)
            : cs.surfaceContainerHighest.withValues(alpha: 0.90),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: dark
              ? cs.outlineVariant.withValues(alpha: 0.45)
              : cs.outline.withValues(alpha: 0.26),
        ),
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
                    // 选中段实心主色深字；未选段透明底清晰文字。
                    color: selected == value
                        ? cs.primary
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                          color: selected == value
                              ? cs.onPrimary
                              : (dark ? cs.outline : cs.onSurfaceVariant),
                          fontWeight:
                              selected == value ? FontWeight.w600 : FontWeight.w500,
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
/// 玻璃操作栏核心样式（2.4.1 第 6 项共享；composer sheet 与页面级
/// SettingsGlassBar 共用同一视觉，禁第二套）：取消 1/3 描边 + 保存 2/3
/// 实心主色（[cancelLabel] null = 整行保存）+ 毛玻璃底（静态区豁口）。
class GlassActionBar extends StatelessWidget {
  const GlassActionBar({
    super.key,
    this.cancelLabel,
    this.onCancel,
    required this.saveLabel,
    required this.onSave,
    this.saveEnabled = true,
    this.busy = false,
    this.safeAreaBottom = true,
    this.morphOnSave,
    this.onMorphSuccess,
  });

  final String? cancelLabel;
  final VoidCallback? onCancel;
  final String saveLabel;
  final VoidCallback onSave;
  final bool saveEnabled;
  final bool busy;
  final bool safeAreaBottom;

  /// 2.4.10 第 02 项：传入时保存按钮走「提交三连变」（真实请求驱动）。
  final Future<bool> Function()? morphOnSave;

  /// 三连变成功落点回调（B 类弹层：关 sheet；页面级：导航/刷新等）。
  final VoidCallback? onMorphSuccess;

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
      child: safeAreaBottom
          ? SafeArea(top: false, child: _buttons(cs))
          : _buttons(cs),
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

  Widget _buttons(ColorScheme cs) {
    final useMorph = morphOnSave != null;
    return Padding(
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
            child: useMorph
                ? _MorphSaveButton(
                    label: saveLabel,
                    enabled: saveEnabled && !busy,
                    onSubmit: morphOnSave!,
                    onSuccess: onMorphSuccess,
                  )
                : FilledButton(
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
    );
  }
}

/// 三连变保存钮（GlassActionBar 内嵌形态）：状态机见
/// submit_morph.dart；收缩圆在自身 Expanded 槽位居中。
class _MorphSaveButton extends StatefulWidget {
  const _MorphSaveButton({
    required this.label,
    required this.enabled,
    required this.onSubmit,
    this.onSuccess,
  });

  final String label;
  final bool enabled;
  final Future<bool> Function() onSubmit;
  final VoidCallback? onSuccess;

  @override
  State<_MorphSaveButton> createState() => _MorphSaveButtonState();
}

class _MorphSaveButtonState extends State<_MorphSaveButton> {
  final SubmitMorphController _c = SubmitMorphController();
  final GlobalKey _key = GlobalKey();
  double? _measured;
  SubmitMorphPhase _phase = SubmitMorphPhase.idle;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    _c.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final was = _phase;
    _phase = _c.phase;
    setState(() {});
    if (was == SubmitMorphPhase.success &&
        _c.phase == SubmitMorphPhase.idle) {
      widget.onSuccess?.call();
    }
  }

  Future<void> _tap() async {
    if (_c.busy || !widget.enabled) return;
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    _measured = box?.size.width;
    await _c.submit(widget.onSubmit);
  }

  @override
  Widget build(BuildContext context) {
    if (_c.phase != SubmitMorphPhase.idle) {
      return Center(
        child: MorphArea(phase: _c.phase, measuredWidth: _measured),
      );
    }
    return FilledButton(
      onPressed: widget.enabled ? _tap : null,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      child: Text(widget.label, key: _key),
    );
  }
}

class SettingsGlassBar extends StatelessWidget {
  const SettingsGlassBar({
    super.key,
    this.cancelLabel,
    this.onCancel,
    required this.saveLabel,
    required this.onSave,
    this.saveEnabled = true,
    this.busy = false,
    this.morphOnSave,
    this.onMorphSuccess,
  });

  final String? cancelLabel;
  final VoidCallback? onCancel;
  final String saveLabel;
  final VoidCallback onSave;
  final bool saveEnabled;
  final bool busy;
  final Future<bool> Function()? morphOnSave;
  final VoidCallback? onMorphSuccess;

  /// 页面内容底部需预留的高度（栏体 + 底部安全区由页面自行叠加）。
  static const double barReserveHeight = 88;

  @override
  Widget build(BuildContext context) {
    return GlassActionBar(
      cancelLabel: cancelLabel,
      onCancel: onCancel,
      saveLabel: saveLabel,
      onSave: onSave,
      saveEnabled: saveEnabled,
      busy: busy,
      morphOnSave: morphOnSave,
      onMorphSuccess: onMorphSuccess,
    );
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
