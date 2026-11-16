/// 动效时长三档令牌（「UI/布局优化」章段 B 2.2.9/VC229）。
/// 来源：页面优化计划附录 B P1.5 动效三档 120/220/320ms（G6/I1），
/// 对齐 Web `--dur-1/2/3`（style.css:2627）。
/// 映射原则：≤160→[fast]、>160 且 ≤280→[base]、>280→[slow]；
/// 功能定时器（防抖/退避/toast 计时）与 repeat 循环动画不套三档，
/// 白名单逐条见 docs/ui-polish-plan.md 段 B 落地备注。
library;

abstract final class Motion {
  /// 微反馈档（120ms）：按压回弹、小件淡入淡出。
  static const Duration fast = Duration(milliseconds: 120);

  /// 标准过渡档（220ms）：卡片展开、淡入、位移过渡。
  static const Duration base = Duration(milliseconds: 220);

  /// 大型转场档（320ms）：滚动对齐、面板收展。
  static const Duration slow = Duration(milliseconds: 320);
}
