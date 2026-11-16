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
import '../../core/together/together_data.dart';
import '../settings/settings_state.dart' show spaceEditRequestedProvider;
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
            padding: const EdgeInsets.fromLTRB(16, 12, 16, Spacing.pageBottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('关于我们，还有好多好多',
                    style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.3)),
                Text(
                  '把喜欢落在实处，把日子过成纪念。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 16),
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
                // 「数据管理与通知渠道」章 段 A：hub 底部「⚙️ 设置」8 张卡
                //（对齐 app.js:1229 settings-tools 8 卡顺序）；第 7 张
                // 「🔔 提醒设置」在邀请另一半入住之后、全部设置之前，
                // context.push('/channels')，逐张点通无死卡。
                const SizedBox(height: 18),
                _settingsHeading(theme),
                const SizedBox(height: Spacing.gap),
                // 2.3.4：8 张设置卡 2 列宫格（原顺序零变化）
                _twoColumnGrid([
                  _settingsCard(
                    context,
                    key: 'settings-hub-space',
                    emoji: '🏡',
                    title: '空间信息',
                    desc: '空间名称与相恋日期',
                    onTap: () {
                      ref.read(spaceEditRequestedProvider.notifier).state = true;
                      context.go('/home');
                    },
                  ),
                  _settingsCard(
                    context,
                    key: 'settings-hub-theme',
                    emoji: '🎨',
                    title: '主题与外观',
                    desc: '主题色、夜间模式与动效',
                    onTap: () => context.push('/settings?section=theme'),
                  ),
                  _settingsCard(
                    context,
                    key: 'settings-hub-cover',
                    emoji: '🖼️',
                    title: '主页背景',
                    desc: '换一张首页封面照片',
                    onTap: () => context.push('/settings?section=cover'),
                  ),
                  _settingsCard(
                    context,
                    key: 'settings-hub-chat-bg',
                    emoji: '🌄',
                    title: '聊天背景',
                    desc: '聊天壁纸与文字对比度',
                    onTap: () => context.push('/messages'),
                  ),
                  _settingsCard(
                    context,
                    key: 'settings-hub-chat-bubble',
                    emoji: '💬',
                    title: '聊天气泡',
                    desc: '两千多款气泡皮肤随手挑',
                    onTap: () => context.push('/messages'),
                  ),
                  _settingsCard(
                    context,
                    key: 'settings-hub-invite',
                    emoji: '💌',
                    title: '邀请另一半入住',
                    desc: '把你们的专属空间分享给 TA',
                    onTap: () => context.push('/profile'),
                  ),
                  // 段 A 第 8 张卡：位置对齐 Web 8 卡（邀请之后、全部设置之前）。
                  _settingsCard(
                    context,
                    key: 'settings-hub-remind',
                    emoji: '🔔',
                    title: '提醒设置',
                    desc: '通知渠道与提醒偏好',
                    onTap: () => context.push('/channels'),
                  ),
                  _settingsCard(
                    context,
                    key: 'settings-hub-all',
                    emoji: '⚙️',
                    title: '全部设置',
                    desc: '主题、背景、链路检测与检查更新',
                    onTap: () => context.push('/settings'),
                  ),
                ]),
                if (st.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    st.error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ), // Column
          ), // SingleChildScrollView
        ), // RefreshIndicator
      ), // Scaffold
    ); // SafeArea
  }

  /// `app.js:1229` `settings-section-heading`「⚙️ 设置」。
  Widget _settingsHeading(ThemeData theme) => Row(
    children: [
      Text('⚙️', style: theme.textTheme.titleMedium),
      const SizedBox(width: 6),
      Text('设置', style: theme.textTheme.titleMedium),
    ],
  );

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
    return InkWell(
      key: cardKey,
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 24)), // fs-xl 24
            const SizedBox(height: 6),
            Text(title, style: theme.textTheme.titleSmall), // h3 fs-body
            const SizedBox(height: 2),
            Text(desc, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.outline)), // p fs-sm muted
          ],
        ),
      ),
    );
  }

  /// hub 设置卡（**只做导航，不复制已有能力的 UI**；8 张逐张点通、无死卡）。
  Widget _settingsCard(
    BuildContext context, {
    required String key,
    required String emoji,
    required String title,
    required String desc,
    required VoidCallback onTap,
  }) {
    return _gridCard(
      context,
      emoji: emoji,
      title: title,
      desc: desc,
      onTap: onTap,
      cardKey: Key(key),
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
    return Container(
      margin: EdgeInsets.zero,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: cs.outlineVariant),
        gradient: LinearGradient(
          begin: dark ? Alignment.topLeft : Alignment.centerLeft,
          end: dark ? Alignment.bottomRight : Alignment.centerRight,
          colors: <Color>[cs.primaryContainer, cs.surface],
          stops: const [0, 0.64],
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: () => context.push('/period'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Row(
            children: [
              const Text('🌸', style: TextStyle(fontSize: 30)),
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
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: () => context.push('/together/anniversary'),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.cardPad),
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
