/// 聊天背景设置页（2.4.1 修复包第 4 项改版）：仍与聊天页右上角面板共用
/// 同一 [WallpaperSheet] 组件与同一数据源（chat_bg* 键）——本页只是宿主
/// 骨架变化：平铺分区（无外层大卡）+ 底部玻璃操作栏经 GlobalKey 触发
/// 面板自身的 [WallpaperSheetState.saveNow]（同一保存实现，禁第二套链）。
/// 保存反馈走顶部 toast，失败保留页面内容（面板状态不清空）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/wallpaper_sheet.dart';
import 'settings_widgets.dart';

class ChatWallpaperPage extends ConsumerStatefulWidget {
  const ChatWallpaperPage({super.key});

  @override
  ConsumerState<ChatWallpaperPage> createState() => _ChatWallpaperPageState();
}

class _ChatWallpaperPageState extends ConsumerState<ChatWallpaperPage> {
  final GlobalKey<WallpaperSheetState> _panelKey =
      GlobalKey<WallpaperSheetState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('聊天背景')),
      body: Stack(
        children: [
          // 平铺分区：分段器 → 色卡网格 → 预览 → 遮罩滑杆 → 注脚
          // （无外层大卡、无卡内重复标题——AppBar 承担页名）。
          Positioned.fill(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                  16, 12, 16, SettingsGlassBar.barReserveHeight + 12),
              children: [
                Card(
                  margin: EdgeInsets.zero,
                  child: WallpaperSheet(
                    key: _panelKey,
                    embedded: true,
                  ),
                ),
                const SizedBox(height: 10),
                const SettingsFootnote(
                    '你们各看各的背景，互不打扰；但谁都能替对方换一张——上面选「TA 的手机」就行。'),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SettingsGlassBar(
              saveLabel: '保存',
              onSave: () => _panelKey.currentState?.saveNow(),
            ),
          ),
        ],
      ),
    );
  }
}
