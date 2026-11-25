/// 2.8.4 缺陷二护栏：时光/相册列表滚到底，最后一条不能被悬浮 Dock 盖住。
///
/// 报障：两页列表拉到最底，最后一条看不见也点不着。
/// 根因：时光页 ListView 完全没有底部 padding；相册页三处滚动体只给了 16。
/// Dock 是悬浮层（距边 10、6+14+2+46+6 ≈ 74 高），内容会滚到它下面。
///
/// 🔴 方法说明（如实申报）：本机缺少 Windows 金图能力（flutter 资源包下载
/// 卡死），做不了像素级「最后一条位于 Dock 上沿之上」的截图断言。这里用
/// 两层确定性断言兜住回归：
///   ① 常量关系：Spacing.pageBottom 必须 ≥ Dock 实测总高 + 常规页边距；
///   ② 结构护栏：四个滚动归属处必须引用该常量（时光 1 处、相册 3 处），
///      不得再出现「16」这种欠距写法。
/// 像素级验收留给真机与 CI 全量跑。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/theme/tokens.dart';
import 'package:love_space/features/shell/web_chrome.dart' show ChromeMetrics;

void main() {
  test('底距常量 ≥ Dock 实测总高 + 常规页边距', () {
    // Dock 结构：padding(6) + 抓手行(14) + 2 + 导航项(46) + padding(6)
    final dockHeight = ChromeMetrics.dockPadding * 2 +
        ChromeMetrics.dockHandleRow +
        2 +
        ChromeMetrics.navItemHeight;
    expect(dockHeight, closeTo(74, 1), reason: 'Dock 实测高度口径');
    expect(Spacing.pageBottom, greaterThanOrEqualTo(dockHeight + 12),
        reason: '内容底距必须让最后一条完整露在 Dock 上沿之上');
  });

  test('时光页滚动体带 pageBottom 底距', () {
    final src = File('lib/features/timeline/timeline_page.dart').readAsStringSync();
    expect(src.contains('Spacing.pageBottom'), isTrue,
        reason: '2.8.4：时光 ListView 必须留出 Dock 让位底距');
  });

  test('相册页三处滚动体都带 pageBottom 底距', () {
    final src = File('lib/features/album/album_page.dart').readAsStringSync();
    final hits = 'Spacing.pageBottom'.allMatches(src).length;
    expect(hits, 3,
        reason: '网格 / 分组列表 / 骨架三处滚动体都要让位，缺一处就会在某个视图下被盖住');
    expect(src.contains('16, 4, 16, 16'), isFalse,
        reason: '旧欠距写法不许回潮');
  });
}
