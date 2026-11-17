/// 聊天气泡设置页（2.4.0 设置拆分段）：气泡皮肤功能本体进设置内独立页，
/// 与聊天页右上角「聊天气泡」面板共用同一 [BubbleSkinSheet] 组件与同一
/// 数据源（GET /api/bubbles + PUT /api/space 的 chat_bubble* 三键）——
/// 任一处修改另一处即时一致，禁止复制第二套实现。保存反馈走顶部 toast，
/// 失败保留页面内容。
library;

import 'package:flutter/material.dart';

import '../chat/bubble_skin_sheet.dart';

class ChatBubblePage extends StatelessWidget {
  const ChatBubblePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('聊天气泡')),
      body: SafeArea(
        // BubbleSkinSheet(embedded) 内部是 Column+Expanded（网格撑满），
        // 由 Scaffold body 有界高度直接承载，不再包滚动容器。
        child: BubbleSkinSheet(embedded: true),
      ),
    );
  }
}
