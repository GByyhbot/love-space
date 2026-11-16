/// 视觉对齐 Web · 试点段（2.3.1/VC231）：壳层 chrome 组件与语义色表。
///
/// 范围：悬浮底栏 Dock（方案 A 浮层重构，`bottomNavigationBar` 置 null）+
/// 顶栏 42×42 圆钮组 + WebBadge 角标 + chrome 语义色表。
/// 纪律：
/// · 玻璃 α 全部**显式取值**（不许从 `ColorScheme.fromSeed` 派生玻璃 α），
///   出处逐条标注 `static/style.css:行号`（web-visual-plan.md 盘点表 1.5/1.6）。
/// · `BackdropFilter`（毛玻璃）只允许出现在本文件（Dock 静态区）；顶栏为
///   半透明 80%（style.css:2108），App 端 AppBar 与 body 上下布局、其后无可
///   模糊内容，故未引入 blur（ui_polish_b_test ⑨ 护栏已同步改口径）。
/// · 动效只用 opacity/transform（AnimatedContainer/AnimatedScale，Motion 令牌
///   120/220ms）；水滴双弹簧（app.js:399-407）以「胶囊色/透明度 220ms + 内容
///   scale 120ms」双 tween 近似（盘点 W4 落定，不引新依赖、不调弹簧参数）。
/// · 不改 tokens.dart 既有常量语义；tab 结构 / IndexedStack / 手势 / 路由零变化。
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../core/theme/motion.dart';

/// chrome 语义色表（深浅两档显式取值，widget 测试逐值断言）。
///
/// 玻璃三件套（dockBg/dockLine/dockShadow）是**纯常量**，与主题色无关——
/// Web 在 `:root` / `:root.dark` 两处显式给出（style.css:2736-2737），
/// seed 派生不出玻璃 α，故不许走 fromSeed。
/// 主题相关槽位（navPillBg/topBtnBorder/topbarBg）走 ColorScheme 最近语义档，
/// 映射关系逐条注明。
class ChromeColors {
  const ChromeColors({required this.brightness, required this.scheme});

  factory ChromeColors.of(ThemeData theme) => ChromeColors(
        brightness: theme.brightness,
        scheme: theme.colorScheme,
      );

  final Brightness brightness;
  final ColorScheme scheme;

  bool get _light => brightness == Brightness.light;

  /// Dock 玻璃底：浅 `rgba(255,255,255,.9)` / 夜 `rgba(28,22,30,.78)`。
  /// 出处 style.css:2736。
  Color get dockBg => _light
      ? const Color(0xE6FFFFFF)
      : const Color(0xC71C161E); // 28,22,30 → 0x1C161E

  /// Dock 描边 1px：浅 `rgba(0,0,0,.06)` / 夜 `rgba(255,255,255,.09)`。
  /// 出处 style.css:2737。
  Color get dockLine =>
      _light ? const Color(0x0F000000) : const Color(0x17FFFFFF);

  /// Dock 阴影（`0 10px 28px` 的色源）：浅 `rgba(90,50,70,.28)` /
  /// 夜 `rgba(0,0,0,.55)`。出处 style.css:2737/:2741。
  Color get dockShadow => _light
      ? const Color.fromRGBO(90, 50, 70, 0.28)
      : const Color.fromRGBO(0, 0, 0, 0.55);

  /// nav 选中胶囊底（--soft）：浅取 M3 [ColorScheme.primaryContainer]
  /// （--soft 的最近语义档），夜 `rgba(255,255,255,.14)` 显式值。
  /// 出处 style.css:2699（浅=--soft）/:2746（夜覆盖）。
  Color get navPillBg => _light
      ? scheme.primaryContainer
      : const Color(0x24FFFFFF); // .14×255≈36=0x24

  /// 顶栏圆钮底（--raised）：浅 = surface（style.css:74/:279），
  /// 夜 `rgba(255,255,255,.06)` 显式值（style.css:1522）。
  Color get topBtnBg => _light
      ? scheme.surface
      : const Color(0x0FFFFFFF); // .06×255≈15=0x0F

  /// 顶栏圆钮描边（--line-strong 的最近语义档）。出处 style.css:280。
  Color get topBtnBorder => scheme.outlineVariant;

  /// 顶栏圆钮阴影（--btn-lift `0 1px 2px`）：浅 `rgba(69,56,63,.07)` /
  /// 夜 `rgba(0,0,0,.4)`。出处 style.css:140/:1519。
  Color get topBtnShadow => _light
      ? const Color.fromRGBO(69, 56, 63, 0.07)
      : const Color.fromRGBO(0, 0, 0, 0.40);

  /// 顶栏半透明底：Web 原生端 `color-mix(var(--bg) 80%, transparent)`，
  /// App 端映射为 surface @80%（α 显式）。出处 style.css:2108。
  Color get topbarBg => scheme.surface.withValues(alpha: 0.80);

  /// 中央 + 钮阴影色：`rgba(0,0,0,.24)`（深浅同值）。出处 style.css:2749。
  Color get fabShadow => const Color.fromRGBO(0, 0, 0, 0.24);

  /// 角标 surface 外圈色（`0 0 0 2px var(--surface)`）。出处 style.css:287。
  Color get badgeRing => scheme.surface;
}

/// Web 语义色（「跟主题无关、跟明暗一起换」，style.css:37-45 浅 / :1512 夜）。
/// 试点段只用到绿/琥珀/紫（fertile）三族，随用随补。
abstract final class WebSemanticColors {
  static Color green(Brightness b) => b == Brightness.light
      ? const Color(0xFF4B6B3F)
      : const Color(0xFF8FB27C);

  /// --green-soft（style.css:39/:1512）
  static Color greenSoft(Brightness b) => b == Brightness.light
      ? const Color(0xFFEAF1E4)
      : const Color(0xFF2B3428);

  /// --amber（style.css:40/:1512）
  static Color amber(Brightness b) => b == Brightness.light
      ? const Color(0xFF8A5A22)
      : const Color(0xFFD2A472);

  /// --amber-soft（style.css:41/:1512）
  static Color amberSoft(Brightness b) => b == Brightness.light
      ? const Color(0xFFF7EEDF)
      : const Color(0xFF3A3026);

  /// --fertile 排卵窗紫（style.css:61/:1513）
  static Color fertile(Brightness b) => b == Brightness.light
      ? const Color(0xFF7B63A0)
      : const Color(0xFFB49BD6);

  /// 卡片顶部内高光（--hairline：浅 rgba(255,255,255,.72)，夜 .05）。
  /// 出处 style.css:1937/:2017。
  static Color cardHairline(Brightness b) => b == Brightness.light
      ? const Color.fromRGBO(255, 255, 255, 0.72)
      : const Color.fromRGBO(255, 255, 255, 0.05);
}

/// chrome 尺寸刻度（数值出处逐条标注，勿凭感觉改）。
abstract final class ChromeMetrics {
  /// Dock 距屏幕左右下各 10px。出处 style.css:2738。
  static const double dockInset = 10;

  /// Dock 内边距 6px。出处 style.css:2738。
  static const double dockPadding = 6;

  /// Dock 圆角 24。出处 style.css:2739。
  static const double dockRadius = 24;

  /// Dock 玻璃 blur 18 + saturate 1.25。出处 style.css:2740。
  static const double dockBlurSigma = 18;
  static const double dockSaturation = 1.25;

  /// Dock 阴影 `0 10px 28px`。出处 style.css:2741。
  static const double dockShadowOffsetY = 10;
  static const double dockShadowBlur = 28;

  /// nav 项 min-height 46 / 圆角 14 / 图标 20 / 文字 11（fs-xs）。
  /// 出处 style.css:2743-2744/:2701。
  static const double navItemHeight = 46;
  static const double navItemRadius = 14;
  static const double navIconSize = 20;
  static const double navLabelSize = 11;

  /// 中央 + 钮 46×46、图标 22、阴影 `0 4px 14px`。
  /// 出处 style.css:2747-2749。
  static const double fabSize = 46;
  static const double fabIconSize = 22;
  static const double fabShadowOffsetY = 4;
  static const double fabShadowBlur = 14;

  /// 顶栏圆钮 42×42、图标 19、钮组间距 9（手机档）。出处 style.css:279/:284/:1399。
  static const double topBtnSize = 42;
  static const double topBtnIconSize = 19;
  static const double topBtnGap = 9;

  /// 头像钮 44×44。出处 style.css:431。
  static const double avatarBtnSize = 44;

  /// 未读角标 min-width 17。出处 style.css:286。
  static const double badgeMinWidth = 17;

  /// 滚动主体底部让位 104（Web `.main` 手机档 padding-bottom）。
  /// 出处 style.css:2750。
  static const double contentBottom = 104;

  /// 页头：副题与标题间距 5、页头与首卡间距 16。出处 style.css:343/:342。
  static const double headingSubGap = 5;
  static const double headingMargin = 16;
}

/// Web `--serif` 字体族（style.css:153：Georgia,"Songti SC","Microsoft YaHei",serif）。
/// Flutter 端直引族名、缺失时系统默认回退，不引新字体依赖包（盘点表口径）。
const String webSerifFamily = 'Georgia';
const List<String> webSerifFallback = <String>['Songti SC', 'Microsoft YaHei'];

/// serif 数字/名字样式（hero 天数 42、stats 22、倒计时 26 等共用字族）。
TextStyle webSerifStyle(
  double fontSize, {
  required Color color,
  FontWeight fontWeight = FontWeight.w500,
  double? height,
  double? letterSpacing,
}) =>
    TextStyle(
      fontFamily: webSerifFamily,
      fontFamilyFallback: webSerifFallback,
      fontSize: fontSize,
      height: height,
      letterSpacing: letterSpacing,
      color: color,
      fontWeight: fontWeight,
    );

/// 饱和度 color matrix（本 SDK dart:ui 无 `ColorFilter.saturate` 工厂，
/// 手写等价矩阵；amount=1 不变，>1 增饱和——Web `saturate(1.25)` 同口径）。
ColorFilter _saturateFilter(double amount) => ColorFilter.matrix(<double>[
      0.213 + 0.787 * amount, 0.715 - 0.715 * amount, 0.072 - 0.072 * amount, 0, 0,
      0.213 - 0.213 * amount, 0.715 + 0.285 * amount, 0.072 - 0.072 * amount, 0, 0,
      0.213 - 0.213 * amount, 0.715 - 0.715 * amount, 0.072 + 0.928 * amount, 0, 0,
      0, 0, 0, 1, 0,
    ]);

/// ── 悬浮底栏 Dock（方案 A 浮层）──────────────────────────────────
///
/// 形态对齐 Web sw296（style.css:2736-2749）：距边 10、radius 24、玻璃底
/// blur(18) saturate(1.25)、阴影 0 10px 28px；nav 项 min-height 46、radius 14、
/// 图标 20 上文字下、字 11；中央 + 钮 46×46 圆形 primary 底 **嵌行内居中**
/// （Web 实读 margin-top:0，不凸出、无凹口——盘点表 1.6 ⚠️ 口径）；选中态
/// soft 胶囊（radius 14）衬底，水滴动效以双 tween 近似（见文件头注释）。
///
/// 🔴 tab 结构红线：仍五 tab（首页/时光/相册/我们/角落），IndexedStack 与
/// 手势零变化；本组件只画 chrome，不持有任何页面。
class WebDock extends StatelessWidget {
  const WebDock({
    super.key,
    required this.currentIndex,
    required this.onTab,
    required this.onCompose,
  });

  final int currentIndex;
  final ValueChanged<int> onTab;
  final VoidCallback onCompose;

  static const List<(int, IconData, String)> _tabs = <(int, IconData, String)>[
    (0, Icons.home_rounded, '首页'),
    (1, Icons.history_rounded, '时光'),
    (2, Icons.photo_library_rounded, '相册'),
    (3, Icons.favorite_rounded, '我们'),
    (4, Icons.lock_outline_rounded, '角落'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = ChromeColors.of(theme);
    // 中央 + 钮屏幕居中：左右两个 Expanded 等宽（左 2 tab / 右 3 tab），
    // 与旧 BottomAppBar「缺口恒在屏幕正中」语义一致。
    Widget navGroup(List<(int, IconData, String)> group) => Expanded(
          child: Row(
            children: <Widget>[
              for (final tab in group) Expanded(child: _navItem(context, tab, colors)),
            ],
          ),
        );
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ChromeMetrics.dockRadius),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: colors.dockShadow,
            offset: Offset(0, ChromeMetrics.dockShadowOffsetY),
            blurRadius: ChromeMetrics.dockShadowBlur,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ChromeMetrics.dockRadius),
          // 毛玻璃只静态区纪律：BackdropFilter 全 lib 仅此一处（试点定案）。
          child: BackdropFilter(
            filter: ImageFilter.compose(
              outer: ImageFilter.blur(
                sigmaX: ChromeMetrics.dockBlurSigma,
                sigmaY: ChromeMetrics.dockBlurSigma,
              ),
              inner: _saturateFilter(ChromeMetrics.dockSaturation),
            ),
          child: Container(
            padding: const EdgeInsets.all(ChromeMetrics.dockPadding),
            decoration: BoxDecoration(
              color: colors.dockBg,
              borderRadius: BorderRadius.circular(ChromeMetrics.dockRadius),
              border: Border.all(color: colors.dockLine),
            ),
            child: Row(
              children: <Widget>[
                navGroup(_tabs.sublist(0, 2)),
                _composeButton(context, colors),
                navGroup(_tabs.sublist(2)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 单个 nav 项：46 高、radius 14、图标 20 + 11px 文字，选中 primary 字 +
  /// soft 胶囊衬底（胶囊色 220ms / 内容 scale 120ms 双 tween 近似水滴动效）。
  Widget _navItem(
    BuildContext context,
    (int, IconData, String) tab,
    ChromeColors colors,
  ) {
    final cs = Theme.of(context).colorScheme;
    final active = tab.$1 == currentIndex;
    final fg = active ? cs.primary : cs.outline;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('shell-nav-${tab.$1}'),
        borderRadius: BorderRadius.circular(ChromeMetrics.navItemRadius),
        onTap: () => onTab(tab.$1),
        child: AnimatedContainer(
          duration: Motion.base,
          curve: Curves.easeOut,
          height: ChromeMetrics.navItemHeight,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? colors.navPillBg : Colors.transparent,
            borderRadius: BorderRadius.circular(ChromeMetrics.navItemRadius),
          ),
          child: AnimatedScale(
            scale: active ? 1.0 : 0.94,
            duration: Motion.fast,
            curve: Curves.easeOut,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(tab.$2, size: ChromeMetrics.navIconSize, color: fg),
                const SizedBox(height: 2),
                Text(
                  tab.$3,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: ChromeMetrics.navLabelSize,
                    height: 1.1,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 中央 + 钮：46×46 圆形 primary 底、plus 图标 22 白、阴影 0 4px 14px .24；
  /// 嵌 Dock 行内居中（Web 实读口径，不凸出无凹口）。行为由外层注入。
  Widget _composeButton(BuildContext context, ChromeColors colors) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: ChromeMetrics.fabSize,
      child: Center(
        child: Container(
          key: const Key('shell-compose-fab'),
          width: ChromeMetrics.fabSize,
          height: ChromeMetrics.fabSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: cs.primary,
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: colors.fabShadow,
                offset: Offset(0, ChromeMetrics.fabShadowOffsetY),
                blurRadius: ChromeMetrics.fabShadowBlur,
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: Tooltip(
              message: '记录此刻',
              child: InkWell(
                onTap: onCompose,
                customBorder: const CircleBorder(),
                child: Center(
                  child: Icon(
                    Icons.add_rounded,
                    size: ChromeMetrics.fabIconSize,
                    color: cs.onPrimary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// ── 顶栏 42×42 圆形图标钮（style.css:278-284）────────────────────
///
/// 形态：pill 圆、--raised 底、1px --line-strong 描边、--btn-lift 阴影、
/// 图标 19。功能与去向由外层注入（通知 → /notices、私聊 → /messages），
/// 零新增入口；未读角标走 [WebBadge]（primary 底 + surface 2px 外圈）。
class WebTopIconButton extends StatelessWidget {
  const WebTopIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.badge,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = ChromeColors.of(theme);
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: ChromeMetrics.topBtnSize,
        height: ChromeMetrics.topBtnSize,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.topBtnBg,
                border: Border.all(color: colors.topBtnBorder),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: colors.topBtnShadow,
                    offset: const Offset(0, 1),
                    blurRadius: 2,
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onPressed,
                  customBorder: const CircleBorder(),
                  child: Center(
                    child: Icon(
                      icon,
                      size: ChromeMetrics.topBtnIconSize,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
            if (badge != null)
              Positioned(right: -3, top: -4, child: badge!),
          ],
        ),
      ),
    );
  }
}

/// 未读角标：min-width 17、padding 3px 4px、primary 底白字 10px w700、
/// `0 0 0 2px var(--surface)` 外圈（用 2px border 同效）。出处 style.css:285-287。
class WebBadge extends StatelessWidget {
  const WebBadge(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ring = ChromeColors.of(Theme.of(context)).badgeRing;
    return Container(
      constraints: const BoxConstraints(minWidth: ChromeMetrics.badgeMinWidth),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        color: cs.primary,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: ring, width: 2),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 10,
          height: 1,
          fontWeight: FontWeight.w700,
          color: cs.onPrimary,
        ),
      ),
    );
  }
}

/// 顶栏头像钮：44×44、padding 2、1px --line、surface 底（style.css:431），
/// 内圈头像沿用既有 primaryContainer 首字母口径。功能零变化（→ /profile）。
class WebAvatarButton extends StatelessWidget {
  const WebAvatarButton({
    super.key,
    required this.initial,
    required this.onPressed,
  });

  /// 首字母（空名兜底 '?'，与旧 CircleAvatar 口径一致）
  final String initial;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: '账号资料',
      child: SizedBox(
        width: ChromeMetrics.avatarBtnSize,
        height: ChromeMetrics.avatarBtnSize,
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: cs.surface,
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              customBorder: const CircleBorder(),
              child: Center(
                child: CircleAvatar(
                  radius: 17,
                  backgroundColor: cs.primaryContainer,
                  child: Text(
                    initial,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onPrimaryContainer,
                        ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
