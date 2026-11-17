/// 聊天背景设置页（2.4.0 设置拆分段）：聊天背景功能本体进设置内独立页，
/// 与聊天页右上角「聊天背景」面板共用同一 [WallpaperSheet] 组件与同一
/// 数据源（authProvider.spaceRaw 的 chat_bg* 四键）——任一处修改另一处
/// 即时一致，禁止复制第二套实现。保存反馈走顶部 toast，失败保留页面内容。
library;

import 'package:flutter/material.dart';

import '../chat/wallpaper_sheet.dart';

class ChatWallpaperPage extends StatelessWidget {
  const ChatWallpaperPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('聊天背景')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: WallpaperSheet(embedded: true),
            ),
          ],
        ),
      ),
    );
  }
}
