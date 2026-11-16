/// 设计令牌（「UI/布局优化」章段 B 2.2.9/VC229）：间距 + 圆角单一来源。
/// 收敛纪律：只改取值来源不改行为、不改 widget 树形态；
/// 旧值分布 → 新令牌对照表见 docs/ui-polish-plan.md 段 B 落地备注。
library;

/// 间距令牌。
abstract final class Spacing {
  /// 卡内统一 padding：收敛自 `EdgeInsets.all(14)`×10 与卡内 `all(16)`×22，
  /// 取主流值 16（G2）。
  static const double cardPad = 16;

  /// 内容页滚动底部留白统一值（G1）：滚动主体（ListView / SingleChildScrollView）
  /// padding 底部一律用此值，统一避让口径（底栏 / 悬浮操作 + 视觉呼吸），
  /// 规则见 docs/ui-polish-plan.md 段 B 落地备注。
  static const double pageBottom = 88;

  /// 标准纵向间隙：`SizedBox(height: 8)` 主流档（×72）。
  static const double gap = 8;

  /// 紧凑纵向间隙：`SizedBox(height: 6)` 半档（×58）。
  /// 是否归并进 [gap] 待主人裁定（half-step 定档，见段 B 小结「待裁定」）；
  /// 裁定归并时删除本常量并全局替换引用即可。
  static const double gapTight = 6;
}

/// 圆角令牌：收敛 10/12/14/16 四档混用（G3）→ 10/12/16 三档。
abstract final class AppRadius {
  /// 小件：缩略图、色块、内嵌元素（原 circular(10) 档 ×28）。
  static const double sm = 10;

  /// 标准卡：与 cardTheme 一致（Card+InkWell 12 事实标准，2.1 基线）。
  static const double card = 12;

  /// 大容器：sheet 顶部、dialog、大卡（原 14 归档至此档，16 档 ×6）。
  static const double lg = 16;
}
