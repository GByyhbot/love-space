/// 统一加载态（「UI/布局优化」章段 C 2.3.0/VC230 · D4 轻量口径）。
/// G16 三种 spinner 包装（裸 Center / Padding(32) / Padding(28)）收编为
/// 单一形态：竖直居中 + 统一留白 48；9 页首拉 loading（personal 五 tab +
/// mood/note/wish + quest/ledger/music）复用本组件防闪空态。
/// timeline/album 两页骨架屏维持现状（D4 定案）。
/// 纪律：颜色走默认主题（colorScheme.primary），不写死色/字号。
library;

import 'package:flutter/material.dart';

/// 统一 spinner 包装：Center + 纵向留白 48。
/// 全屏 loading 门（首页 records 首拉）与列表内嵌 loading（工具页首拉）
/// 共用同一形态。
class AppProgress extends StatelessWidget {
  const AppProgress({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
