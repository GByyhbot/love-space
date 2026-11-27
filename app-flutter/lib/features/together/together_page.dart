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
import '../../core/api/api_client.dart' as api;
import '../../core/peer/peer_report_data.dart';
import '../../core/ui/apple_ui.dart';
import '../../core/ui/liquid_glass.dart';
import '../../core/ui/page_heading.dart';
import '../../core/together/together_data.dart';
import '../period/period_colors.dart' show periodStageColor;
import '../shell/web_chrome.dart' show webSerifStyle;
import 'together_controller.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/tokens.dart';
import '../../core/theme/typography.dart';

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
    final topInset = ShellChromeScope.topInsetOf(context);

    return SafeArea(
      top: topInset == 0,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: RefreshIndicator(
          edgeOffset: topInset,
          color: theme.colorScheme.primary,
          backgroundColor: theme.brightness == Brightness.dark
              ? theme.colorScheme.surfaceContainerHigh
              : theme.colorScheme.surface,
          onRefresh: () => ref.read(togetherControllerProvider.notifier).load(),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(
              top: topInset,
              bottom: Spacing.pageBottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                      const _PeriodEntryCard(),
                      const SizedBox(height: 12),
                      _AnniversaryCard(ann: ann),
                      const SizedBox(height: 12),
                      const _PeerReportCard(),
                      const SizedBox(height: 18),
                      // 11 项工具全部改 AppleIconBadge + AppleGroupedSection（零 emoji 图标）
                      AppleGroupedSection(
                        title: '日常互动',
                        children: [
                          AppleGroupedRow(
                            icon: Icons.calendar_month_rounded,
                            tone: AppleIconTone.blue,
                            title: '共同年历',
                            subtitle: '重要的日子，一眼看清',
                            onTap: () => context.push('/together/calendar'),
                          ),
                          AppleGroupedRow(
                            icon: Icons.wb_sunny_rounded,
                            tone: AppleIconTone.amber,
                            title: '心情手记',
                            subtitle: '晴天雨天，都想陪着你',
                            onTap: () => context.push('/together/mood'),
                          ),
                          AppleGroupedRow(
                            icon: Icons.mail_rounded,
                            tone: AppleIconTone.rose,
                            title: '悄悄留言',
                            subtitle: '有些喜欢，值得慢慢读',
                            onTap: () => context.push('/together/note'),
                          ),
                          AppleGroupedRow(
                            icon: Icons.auto_awesome_rounded,
                            tone: AppleIconTone.purple,
                            title: '共同愿望',
                            subtitle: '把一起想做的事，一件件实现',
                            onTap: () => context.push('/together/wish'),
                          ),
                          AppleGroupedRow(
                            icon: Icons.forum_rounded,
                            tone: AppleIconTone.teal,
                            title: '情侣问答',
                            subtitle: '每天再多了解彼此一点',
                            onTap: () => context.push('/together/question'),
                          ),
                          AppleGroupedRow(
                            icon: Icons.eco_rounded,
                            tone: AppleIconTone.emerald,
                            title: '共同打卡',
                            subtitle: '和你一起，成为更好的我们',
                            onTap: () => context.push('/together/habit'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      AppleGroupedSection(
                        title: '计划与回忆',
                        children: [
                          AppleGroupedRow(
                            icon: Icons.checklist_rounded,
                            tone: AppleIconTone.coral,
                            title: '恋爱清单',
                            subtitle: '一起做完这些小事，就是我们的故事',
                            onTap: () => context.push('/together/quest'),
                          ),
                          AppleGroupedRow(
                            icon: Icons.account_balance_wallet_rounded,
                            tone: AppleIconTone.amber,
                            title: '共同账本',
                            subtitle: '为了彼此花过的钱，也是一段回忆',
                            onTap: () => context.push('/together/ledger'),
                          ),
                          AppleGroupedRow(
                            icon: Icons.music_note_rounded,
                            tone: AppleIconTone.pink,
                            title: '共同歌单',
                            subtitle: '把属于我们的歌，放在一起',
                            onTap: () => context.push('/together/music'),
                          ),
                          AppleGroupedRow(
                            icon: Icons.insights_rounded,
                            tone: AppleIconTone.indigo,
                            title: '数据看板',
                            subtitle: '把日子过成数据，也过成回忆',
                            onTap: () => context.push('/together/dashboard'),
                          ),
                          AppleGroupedRow(
                            icon: Icons.mark_email_read_rounded,
                            tone: AppleIconTone.sky,
                            title: '回忆周报',
                            subtitle: '把这一周，收进一封小小的信',
                            onTap: () => context.push('/together/weekly'),
                          ),
                        ],
                      ),
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
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
        borderRadius: BorderRadius.circular(AppRadius.large),
        border: Border.all(
          color: dark
              ? Colors.white.withValues(alpha: 0.09)
              : periodColor.withValues(alpha: 0.25),
          width: 0.8,
        ),
        boxShadow: appleCardShadows(dark),
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: <Color>[
            periodColor.withValues(alpha: dark ? 0.24 : 0.14),
            dark ? cs.surfaceContainerHigh : cs.surface,
          ],
          stops: const [0, 0.72],
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(AppRadius.large),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.large),
          onTap: () => context.push('/period'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(
              children: [
                AppleIconBadge(
                  icon: Icons.spa_rounded,
                  color: periodColor,
                  size: 42,
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
    final dark = theme.brightness == Brightness.dark;
    return Container(
      margin: EdgeInsets.zero,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.large),
        border: Border.all(
          color: dark
              ? Colors.white.withValues(alpha: 0.08)
              : cs.outlineVariant.withValues(alpha: 0.45),
          width: 0.8,
        ),
        color: dark ? cs.surfaceContainerHigh : cs.surface,
        boxShadow: appleCardShadows(dark),
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(AppRadius.large),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.large),
          onTap: () => context.push('/together/anniversary'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
                              color: cs.primary, fontWeight: FontWeight.w600)
                          .copyWith(fontFeatures: AppType.tabularFeatures),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: Spacing.xs),
                        child: Text(
                          '天后 · ${(a.record.body['title'] ?? '纪念日')}\n'
                          '${a.due} · 点此管理纪念日',
                          softWrap: true,
                          style: AppType.caption(theme),
                        ),
                      ),
                    ),
                    Icon(AppIcons.chevronRight, color: cs.outline),
                  ],
                ),
        ),
      ),
      ),
    );
  }
}

/// 报备信息摘要卡（2.8.0 · 「我们」页入口）。
///
/// 形态与 [_PeriodEntryCard] 同族（AppRadius.card + outlineVariant 边框 +
/// 16/18 padding + 左图标 + 标题/摘要 + chevron），点击 `context.push`
/// 进 `/together/peer-report`（二级页；返回按钮 + 系统手势都回本页）。
///
/// 🔴 摘要口径（施工令一）：一行「TA · 12 分钟前报备 · 电量 82%」；
/// 对方无任何报备 → 「TA 还没有报备数据」；拉取失败 → 「状态未知」——
/// **失败时清空旧值**，不拿旧缓存冒充实时。数据由本卡自拉（一次），
/// 页内 SSE `peer` 段到达时静默重拉（不弹提示）。
class _PeerReportCard extends ConsumerStatefulWidget {
  const _PeerReportCard();

  @override
  ConsumerState<_PeerReportCard> createState() => _PeerReportCardState();
}

class _PeerReportCardState extends ConsumerState<_PeerReportCard> {
  PeerReport? _data;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final dio = await ref.read(api.dioProvider.future);
      final data = await fetchPeerReport(dio);
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      // 失败即置未知：清掉旧值，摘要不显示陈旧的新鲜度/电量
      setState(() {
        _data = null;
        _error = '状态未知';
        _loading = false;
      });
    }
  }

  /// 摘要一行文案（口径见 peer_report_data.peerSummaryLine 与类注释）。
  String get _summary {
    if (_error != null) return peerSummaryLine(null, failed: true);
    final d = _data;
    if (d == null) return _loading ? '正在读取…' : peerSummaryLine(null);
    return peerSummaryLine(d.status);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    ref.listen(sseEventsProvider, (prev, next) {
      if (next.value?.peer == true) _load();
    });

    final peerSnap = _data?.status.peer;
    final hasLive = peerSnap != null && _error == null;
    final battery = peerSnap?.battery;
    return AppleGroupedSection(
      children: [
        AppleGroupedRow(
          icon: Icons.my_location_rounded,
          tone: AppleIconTone.emerald,
          title: '报备信息',
          subtitle: _summary,
          trailing: hasLive
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppleIconTone.emerald.resolve(theme.brightness),
                      ),
                    ),
                    if (battery != null) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Text(
                          '$battery%',
                          style: tabularStyle(
                            theme.textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                )
              : null,
          onTap: () => context.push('/together/peer-report'),
        ),
      ],
    );
  }
}
