/// 聊天背景层定位框（复验修复：点输入框弹键盘时背景图不再上移）。
///
/// Scaffold 在 `resizeToAvoidBottomInset=true` 时会压缩 body 高度；背景若用
/// `Positioned.fill` 会跟着收缩，`BoxFit.cover` 重新裁剪 → 视觉上背景往上跑，
/// 键盘收起又落回来。本组件把背景钉在 Stack 顶部、高度恒为**完整视口高**，
/// 超出 body 的部分由 Stack 的硬裁剪处理，图片位置与裁剪始终不变。
library;

import 'package:flutter/material.dart';

class ChatWallpaperFrame extends StatelessWidget {
  const ChatWallpaperFrame({
    super.key,
    required this.viewportHeight,
    required this.child,
  });

  /// `MediaQuery.sizeOf(context).height`：完整视口高，不受 viewInsets 影响
  final double viewportHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) => Positioned(
        top: 0,
        left: 0,
        right: 0,
        height: viewportHeight,
        child: child,
      );
}
