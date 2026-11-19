/// 「我们」页 hub（条目 6 · 段 A/B）：
/// heading + 🌸 生理期宽卡（条目 8 段 8-A 已落地，对齐 Web `app.js:1229`
/// tools-grid 首位硬编码宽卡）+ 纪念日只读展示卡（最近纪念日倒计时，
/// 段 B 起点击直达管理页——决策点①定案：管理页归首页入口 + 本卡双入口）
/// + 已落地工具卡（共同年历 / 心情手记 / 悄悄留言 / 共同愿望），
/// 后续段页面落地后逐段增补卡，🔴 不预放死卡。数据与工具页共用
/// togetherControllerProvider（一次全量）。
/// SSE other 且 tab 激活 → reset 重拉；顶部通知由全局 ChatToastHost 承载。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/sse/sse_client.dart';
import '../../core/ui/pressable_scale.dart' show PressableScale;
import '../../core/ui/page_heading.dart';
import '../../core/together/together_data.dart';
import '../period/period_colors.dart' show periodStageColor;
import '../shell/web_chrome.dart' show webSerifStyle;
import 'together_controller.dart';
import '../../core/theme/tokens.dart';

class TogetherPage extends ConsumerStatefulWidget {
  const TogetherPage({super.key, required this.active});
  final bool active; // 当前 tab 是否为「我们」（SSE other 只在激活时重拉）

  @override
  ConsumerState<TogetherPage> createState() => _TogetherPageState();
}

class _TogetherPageState extends ConsumerState<TogetherPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(togetherControllerProvider.notifier).bootstrap(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(togetherControllerProvider);
    ref.listen(sseEventsProvider, (prev, next) {
      final ev = next.value;
      if (widget.active && (ev?.other == true || ev?.refresh == true)) {
        ref.read(togetherControllerProvider.notifier).resetOnSseOther();
      }
    });

    final theme = Theme.of(context);
    final ann = nextAnniversary(st.records, todayDateStr());

    return SafeArea(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: RefreshIndicator(
          onRefresh: () => ref.read(togetherControllerProvider.notifier).load(),
          // hub 是固定短列表（工具卡 + 段 D 的 7 张设置卡），用
          // SingleChildScrollView + Column 一次构建全部卡片：ListView 的
          // 惰性回收会在长距离惯性滑动时把中段工具卡移出树，导致设置区加长后
          // 中段卡片闪烁 / 锚点丢失；一次构建更适合这种固定短列表。
          // RefreshIndicator 在内容不足一屏时仍需可滚动，故 AlwaysScrollable。
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            // 2.4.2 第 4 项：容器 padding 归零——标题行由共享 PageHeading
            // 自带 16/8（原容器 16+12 与其叠加成左 32/顶 20，是「我们页标题
            // 没有左对齐」的根因）；卡片内容用内层 Padding 保持原左缘。
            padding: const EdgeInsets.only(bottom: Spacing.pageBottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 2.4.1 第 9 项：标题行统一引用共享 PageHeading 组件。
                const PageHeading(
                  title: '关于我们，还有好多好多',
                  subtitle: '把喜欢落在实处，把日子过成纪念。',
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                // 条目 8 段 8-A（D1）：🌸 生理期宽卡置于 hub **顶部**，
                // 文案与位置逐字对齐 Web `app.js:1229` tools-grid 首位硬编码宽卡
                // 「🌸 生理期 / 记下周期，把照顾提前一点」；点击 push('/period')。
                const _PeriodEntryCard(),
                const SizedBox(height: 12),
                _AnniversaryCard(ann: ann),
                const SizedBox(height: 12),
                // 2.3.4：11 张工具卡 2 列宫格（原顺序零变化：年历→心情→留言→
                // 愿望→问答→打卡→清单→账本→歌单→看板→周报）
                _twoColumnGrid([
                  _toolCard(
                    context,
                    emoji: '🗓️',
                    title: '共同年历',
                    desc: '重要的日子，一眼看清',
                    route: '/together/calendar',
                  ),
                  _toolCard(
                    context,
                    emoji: '🌤',
                    title: '心情手记',
                    desc: '晴天雨天，都想陪着你',
                    route: '/together/mood',
                  ),
                  _toolCard(
                    context,
                    emoji: '💌',
                    title: '悄悄留言',
                    desc: '有些喜欢，值得慢慢读',
                    route: '/together/note',
                  ),
                  _toolCard(
                    context,
                    emoji: '✨',
                    title: '共同愿望',
                    desc: '把一起想做的事，一件件实现',
                    route: '/together/wish',
                  ),
                  _toolCard(
                    context,
                    emoji: '💭',
                    title: '情侣问答',
                    desc: '每天再多了解彼此一点',
                    route: '/together/question',
                  ),
                  _toolCard(
                    context,
                    emoji: '🌱',
                    title: '共同打卡',
                    desc: '和你一起，成为更好的我们',
                    route: '/together/habit',
                  ),
                  _toolCard(
                    context,
                    emoji: '💫',
                    title: '恋爱清单',
                    desc: '一起做完这些小事，就是我们的故事',
                    route: '/together/quest',
                  ),
                  _toolCard(
                    context,
                    emoji: '💰',
                    title: '共同账本',
                    desc: '为了彼此花过的钱，也是一段回忆',
                    route: '/together/ledger',
                  ),
                  _toolCard(
                    context,
                    emoji: '🎵',
                    title: '共同歌单',
                    desc: '把属于我们的歌，放在一起',
                    route: '/together/music',
                  ),
                  _toolCard(
                    context,
                    emoji: '📊',
                    title: '数据看板',
                    desc: '把日子过成数据，也过成回忆',
                    route: '/together/dashboard',
                  ),
                  _toolCard(
                    context,
                    emoji: '📬',
                    title: '回忆周报',
                    desc: '把这一周，收进一封小小的信',
                    route: '/together/weekly',
                  ),
                ]),
                // 2.4.0 设置拆分段：底部整个「⚙️ 设置」区（标题 + 8 卡宫格）
                // 退役——设置整体离开「我们」页，入口改为五 tab 顶栏齿轮
                // （shell_page.dart WebTopIconButton 'shell-settings'）。
                // 设置内容本体已拆入设置主页 /settings 及六张独立页。
                if (st.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    st.error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                ], // 内层 Column children（卡片内容 Padding）
              ), // 内层 Column
            ), // 卡片内容 Padding
            ], // 外层 Column children
          ), // 外层 Column
        ), // SingleChildScrollView
      ), // RefreshIndicator
    ), // Scaffold
    ); // SafeArea
  }

  // ── 2.3.4（推广段一重做）：Web tools-grid 2 列宫格 ──────────────────
  // Web 工具区/设置区为 tools-grid 2 列宫格（style.css:1078-1083：tool-card
  // radius 20 白卡 + emoji fs-xl 24 + h3 fs-body + p fs-sm muted；≤1150 两列
  // ——App 手机端即两列口径）。App 卡片沿用各自实读文案（web-visual-plan.md
  // 8.2 对照表：看板/周报/全部设置沿用既有副题），11+8 张卡零增减、去向与
  // 顺序零变化——只换呈现形态（纵向列表卡 → 2 列宫格卡）。

  /// 2 列宫格排布：顺序零变化（调用处原序传入，不足补空位占行）。
  /// IntrinsicHeight 实现两卡等高（Web grid 等高语义）；无界高度上下文
  /// （SingleChildScrollView）下不能用 stretch Row——会强制无穷高。
  Widget _twoColumnGrid(List<Widget> cards) => Column(
        children: [
          for (var i = 0; i < cards.length; i += 2)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: IntrinsicHeight(
                child: Row(
                  children: [
                    Expanded(child: cards[i]),
                    const SizedBox(width: 10),
                    Expanded(
                      child: i + 1 < cards.length
                          ? cards[i + 1]
                          : const SizedBox(),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );

  /// Web tool-card 形态：radius 20 白卡、emoji 24 顶部、标题 + 诗意副题。
  /// 2.4.1 第 10 项①：各工具卡淡彩底座色（同一饱和度、彼此可区分）——
  /// 年历蓝 / 心情橙 / 留言粉 / 愿望紫 / 问答青 / 打卡绿，其余按语义近似
  /// 补齐（周报信蓝、账本金、歌单紫红、清单灰绿、生理期粉由宽卡自带）。
  static const Map<String, (Color, Color)> _toolTints = <String, (Color, Color)>{
    '共同年历': (Color(0xFFE8F0F6), Color(0xFF3F6A8E)), // info 蓝
    '心情手记': (Color(0xFFF7EEDF), Color(0xFF8A5A22)), // amber 橙
    '悄悄留言': (Color(0xFFFBE3EC), Color(0xFFC23F68)), // 粉（--period-soft）
    '共同愿望': (Color(0xFFEDE8F6), Color(0xFF7B63A0)), // 紫
    '情侣问答': (Color(0xFFE0F4F0), Color(0xFF2F9E88)), // 青
    '共同打卡': (Color(0xFFEAF1E4), Color(0xFF4B6B3F)), // 绿
    '回忆周报': (Color(0xFFE8F0F6), Color(0xFF3F6A8E)), // 信蓝
    '共同账本': (Color(0xFFF7EEDF), Color(0xFF8A5A22)), // 金
    '歌单': (Color(0xFFFBE3EC), Color(0xFF953753)), // 紫红
    '恋爱清单': (Color(0xFFEAF1E4), Color(0xFF4B6B3F)), // 灰绿
  };

  Widget _gridCard(
    BuildContext context, {
    required String emoji,
    required String title,
    required String desc,
    required VoidCallback onTap,
    Key? cardKey,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tint = _toolTints[title] ?? (cs.surfaceContainerHighest, cs.onSurface);
    // 2.4.10 附录 B ②：按压四段——按下即微缩 0.97，松手回弹。
    return PressableScale(
      onTap: onTap,
      child: InkWell(
      key: cardKey,
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        // 2.4.1 第 10 项①：内边距收紧 14→10（约 -25% 高度参考）。
        padding: const EdgeInsets.all(10),
        constraints: const BoxConstraints(minHeight: 92),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // emoji 收进 35px 圆角方底座（圆角 11，每卡淡彩底 + 同色图形）。
            Container(
              width: 35,
              height: 35,
              decoration: BoxDecoration(
                color: tint.$1,
                borderRadius: BorderRadius.circular(11),
              ),
              alignment: Alignment.center,
              child: Text(emoji, style: const TextStyle(fontSize: 20)),
            ),
            const SizedBox(height: 6),
            Text(title, style: theme.textTheme.titleSmall), // h3 fs-body
            const SizedBox(height: 2),
            Text(desc, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.outline)), // p fs-sm muted
          ],
        ),
      ),
      ),
    );
  }

  /// 工具入口卡（仅已落地页面；后续段随页面落地逐段增补，不预放死卡）。
  /// 生理期为顶部独立宽卡 [_PeriodEntryCard]（条目 8 段 8-A 已落地），
  /// 不走此模板。2.3.4：形态改 Web tool-card 宫格卡（签名与调用处零变化）。
  Widget _toolCard(
    BuildContext context, {
    required String emoji,
    required String title,
    required String desc,
    required String route,
  }) {
    return _gridCard(
      context,
      emoji: emoji,
      title: title,
      desc: desc,
      onTap: () => context.push(route),
    );
  }
}

/// 🌸 生理期宽卡（条目 8 · 段 8-A · D1 · 决策点⑥「入口卡随条目 8 上」）。
///
/// 位置/文案对齐 Web `app.js:1229` tools-grid **首位硬编码宽卡**
/// `🌸 生理期 / 记下周期，把照顾提前一点`（不在 `toolsList :1219` 的 11 项里）。
/// 点击 `context.push('/period')` 进独立二级页：二级页 AppBar
/// `automaticallyImplyLeading` 不关，返回按钮 + 系统手势都能回上一页。
/// 聊天 ⊕ 面板 `chat_compose.dart` 的 `tool-period` 格改同一跳转，死入口清零。
class _PeriodEntryCard extends StatelessWidget {
  const _PeriodEntryCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // 2.3.4（推广段一重做）：对齐 Web `tool-card-wide` 120° 渐变底
    // （linear-gradient(120deg,var(--soft),var(--surface) 64%)，style.css:1085）
    // ——soft → primaryContainer 映射（浅档口径，与试点 chrome 同机制）。
    final dark = theme.brightness == Brightness.dark;
    // 2.4.1 第 10 项②：渐变换 --period 玫红系柔光（period_colors light/dark
    // 值低透明度自左向右渐隐）；樱花 emoji 收进玻璃圆（半透明白底 + 细边）。
    final periodColor = periodStageColor(context);
    return Container(
      margin: EdgeInsets.zero,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: cs.outlineVariant),
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: <Color>[
            periodColor.withValues(alpha: dark ? 0.22 : 0.14),
            cs.surface,
          ],
          stops: const [0, 0.72],
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: () => context.push('/period'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: dark ? 0.14 : 0.65),
                  border: Border.all(
                      color: periodColor.withValues(alpha: 0.45)),
                ),
                alignment: Alignment.center,
                child: const Text('🌸', style: TextStyle(fontSize: 24)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '生理期',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '记下周期，把照顾提前一点',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.outline,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: cs.outline),
            ],
          ),
        ),
      ),
    );
  }
}

/// 纪念日只读展示卡（决策点①）：最近纪念日倒计时（口径=首页/管理页共用
/// together_data 唯一实现）。段 B 起**点击直达管理页**（/together/anniversary，
/// 与首页纪念日区同一路由）；空态点击同样进管理页添加。
class _AnniversaryCard extends StatelessWidget {
  const _AnniversaryCard({required this.ann});
  final NextAnniversary? ann;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final a = ann;
    // 2.4.1 第 10 项③：容器形态与生理期宽卡对齐（AppRadius.card + 边框 +
    // padding 16/18，衬线大字保留）；Card→Container 消除双层 elevation 差。
    return Container(
      margin: EdgeInsets.zero,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: cs.outlineVariant),
        color: cs.surface,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: () => context.push('/together/anniversary'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: a == null
              ? Text(
                  '留一个日子，给仪式感 · 点此去首页添加纪念日。',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // 2.3.4（推广段一重做）：大数字 serif 档（Web .stat strong
                    // serif 24 档，style.css:479 系——webSerifStyle 走试点同族）
                    Text(
                      '${a.days}',
                      style: webSerifStyle(28,
                          color: cs.primary, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '天后 · ${(a.record.body['title'] ?? '纪念日')}\n'
                          '${a.due} · 点此管理纪念日',
                          softWrap: true,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.outline,
                          ),
                        ),
                      ),
                    ),
                    Icon(Icons.chevron_right, color: cs.outline),
                  ],
                ),
        ),
      ),
    );
  }
}
