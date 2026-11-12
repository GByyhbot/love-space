/// 聊天页「外壳」视觉与气泡尺寸契约（复验 item 2 / item 1 修复）。
///
/// 用户定版规则：顶栏、状态栏、输入栏、⊕面板、贴纸坞**五处同一底色同一透明度**，
/// 要么都纯色、要么都透明，不许「输入框透明 + 工具栏纯色」的混搭。
/// 上一版割裂根因：顶栏 `transparent/black54`、输入栏 α0.85、引用栏 α0.7、
/// ⊕面板与贴纸坞固定 α0.9 且完全不跟随 immersive —— 五处四套值。
///
/// 气泡最大宽度对齐 Web `static/style.css:645` `.chat-line{max-width:85%}`、
/// `:1455` `@media(max-width:640px){.chat-line{max-width:92%}}`。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

/// 五处外壳唯一透明度（immersive 与否**同一个 α**，不许一块实一块透）。
const double chatChromeAlpha = 0.72;

/// 五处外壳唯一底色：照片壁纸上压黑、普通背景用主题 surface，
/// 两者都套同一个 [chatChromeAlpha] → 同一底色 + 同一透明度。
Color chatChromeColor(ThemeData theme, {required bool immersive}) =>
    (immersive ? Colors.black : theme.colorScheme.surface)
        .withValues(alpha: chatChromeAlpha);

/// 外壳分隔线：与底色同明暗，避免浅色模式下一条突兀实线。
Color chatChromeBorder(ThemeData theme, {required bool immersive}) => immersive
    ? const Color(0x3DFFFFFF) // Colors.white24
    : theme.colorScheme.outlineVariant.withValues(alpha: 0.6);

/// 状态栏取色归一：底色与顶栏同源，图标亮度由**同一个底色**的亮度反推，
/// 杜绝「深色底配深色图标」；状态栏/导航栏底色也取同一色。
SystemUiOverlayStyle chatChromeOverlayStyle(ThemeData theme,
    {required bool immersive}) {
  final bg = chatChromeColor(theme, immersive: immersive);
  final onDark = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;
  return (onDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
      .copyWith(
    statusBarColor: bg,
    statusBarBrightness: onDark ? Brightness.dark : Brightness.light,
    statusBarIconBrightness: onDark ? Brightness.light : Brightness.dark,
    systemNavigationBarColor: bg,
    systemNavigationBarIconBrightness:
        onDark ? Brightness.light : Brightness.dark,
  );
}

/// Web `.chat-bubble{min-width:44px}`（style.css:657）。
const double bubbleMinWidth = 44.0;

/// 气泡最大宽度：短消息窄、长文本宽至上限（Web `.chat-bubble{max-width:100%}`
/// 叠在 `.chat-line` 的 85%/92% 上；行内还有头像 34 + gap 10）。
/// Flutter 行内另有 horizontal 12×2 + 头像 34 + 间距 6 = 64dp，取两侧较小值。
double bubbleMaxWidth(double viewportWidth) {
  final lineMax =
      viewportWidth <= 640 ? viewportWidth * 0.92 : viewportWidth * 0.85;
  final flutterAvail = viewportWidth - 64.0;
  final webAvail = lineMax - 44.0;
  return math.min(flutterAvail, webAvail).clamp(120.0, double.infinity).toDouble();
}

/// 气泡宽度框：Column 在 loose 约束下自身宽度 = 最大子宽（随内容扩展），
/// ConstrainedBox 夹到 Web `.chat-bubble min-width:44px` 与 `.chat-line`
/// 85%/92% 上限——短消息窄、长文本宽至上限。
/// 刻意不用 IntrinsicWidth：它给子树无界宽，歌卡/位置卡内的 Expanded 会炸。
/// 皮肤态/默认态共用本组件，宽度口径不因渲染分支漂移；公开供 widget 测试实证。
class ChatBubbleFrame extends StatelessWidget {
  const ChatBubbleFrame({super.key, required this.child});

  final Widget child;

  /// 纯函数：便于单测锁定宽度契约
  static BoxConstraints constraintsFor(double viewportWidth) => BoxConstraints(
        minWidth: bubbleMinWidth,
        maxWidth: bubbleMaxWidth(viewportWidth),
      );

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: constraintsFor(MediaQuery.sizeOf(context).width),
        child: child,
      );
}
