/// 首页（阶段 2 · 条目 2，对齐 Web homePage）：页头（我们的每一天）、hero 渐变卡
/// （两人名/相恋天数/封面/相恋日期设置）、stats 三格（天数/照片/心愿）、today
/// 双格（心情 + 纪念日倒计时）、每日一句、最近动态（post 前 3）。
///
/// 2.3.1（视觉对齐 Web 试点段）：一页 1:1 还原（web-visual-plan.md 2.2 差异表
/// 逐行落地）。🔴 红线：数据来源/请求时机/Provider 零变化——仍是
/// recordsProvider（kind 排除 chat）+ dashboardProvider + authProvider，
/// SSE other → invalidate 重拉不变；只换呈现层。数值出处逐条标注
/// `static/style.css:行号` / `static/app.js:行号`（盘点表口径）。
/// S1（Expanded+ellipsis 长昵称）/S2（mood 行 Flexible）修复保留不回退。
library;

import 'dart:ui' as ui show Gradient;

import 'package:dio/dio.dart' show Response;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import '../../core/sse/sse_client.dart';
import '../../core/together/together_data.dart' show anniversaryDue;
import '../../core/ui/error_view.dart';
import '../../core/ui/progress.dart';
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../settings/settings_state.dart' show spaceEditRequestedProvider;
import '../../core/ui/avatar_media.dart';
import '../shell/web_chrome.dart';
import '../../core/theme/tokens.dart';

/// 今日日期（本地时区，与 Web today() 一致格式 yyyy-MM-dd）
String todayStr() {
  final d = DateTime.now();
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

int daysBetween(String a, String b) {
  final da = DateTime.tryParse('${a}T00:00:00');
  final db = DateTime.tryParse('${b}T00:00:00');
  if (da == null || db == null) return 0;
  return db.difference(da).inDays;
}

const dailyQuotes = [
  '喜欢是乍见之欢，爱是久处不厌。',
  '日子很普通，但有你就不一样。',
  '今天也想和你一起，把生活过成一件件小事。',
  '你是我所有计划里，唯一不变的那一项。',
  '一起吃饭，一起发呆，一起把日子过成小事。',
  '世界很大，我的坐标是你。',
  '想和你把「以后」两个字，慢慢过成具体的日子。',
  '不必每天都惊喜，只要每天都有你。',
  '我们不用很厉害，只要一直在一起。',
  '喜欢你这件事，我做得最久。',
  '天气预报说明天有雨，我记得带伞，也记得带你。',
  '你笑的时候，我觉得今天没白过。',
  '柴米油盐里，也藏着浪漫。',
  '不用去很远的地方，回家就是最好的旅行。',
  '你在的地方，就是我想去的地方。',
  '想和你一起变老，慢慢的那种。',
  '今天的月亮很好，你也在，就更好了。',
  '爱是记得，也是愿意。',
  '日子一天天过去，喜欢一天天变多。',
  '我们把普通的日子，过成了纪念日。',
  '你说话的时候，我在认真听。',
  '抱一下，今天就算圆满。',
  '一天很短，但装得下想念。',
  '明天也一起吃早饭吧。',
];

class HomePage extends ConsumerWidget {
  const HomePage({super.key, this.onGoTab});

  /// 首页不留死卡片：跳转 shell 其它 tab（1=时光 3=我们），由 shell 注入
  final void Function(int tab)? onGoTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // SSE other 事件 → 重拉聚合数据（chat 事件不触发：首页不含聊天）
    ref.listen(sseEventsProvider, (prev, next) {
      if (next.value?.other == true || next.value?.refresh == true) {
        ref.invalidate(recordsProvider);
        ref.invalidate(dashboardProvider);
        ref.read(authProvider.notifier).reload();
      }
    });

    final records = ref.watch(recordsProvider);
    final theme = Theme.of(context);
    final me = ref.watch(authProvider.notifier).me;
    // 段 D：「空间信息」跳转入口（设置页 / hub 卡）置位后，回首页自动打开
    // 已有的空间信息编辑弹层——只做导航，不复制该弹层 UI。
    ref.listen(spaceEditRequestedProvider, (prev, next) {
      if (next == true) {
        ref.read(spaceEditRequestedProvider.notifier).state = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted && ref.read(authProvider.notifier).me != null) {
            showSpaceEditDialog(
              context,
              ref,
              ref.read(authProvider.notifier).me!,
            );
          }
        });
      }
    });

    if (me == null) {
      return const AppProgress();
    }

    // 2.3.5（紧急 BugFix，主人真机点测拍板）：摘除「最近的小美好」动态卡区。
    // 🔴 主人最终裁定：问题出在动态卡（最近的小美好），心情与纪念日双格保留。
    // 首页构成：页头 → hero → today 双格 → 每日一句。
    // 真机二分实验链：C1 空页可点 → C3 hero 可点 → C4 纪念日格可点 →
    // C5 起含动态卡后 tap/drag 失效 → C8 摘动态卡 drag 恢复 → 本形态。
    return records.when(
      loading: () => const AppProgress(),
      error: (e, _) => Center(
        child: AppErrorView(
          // detail 原文口径（errorDetail），不自造文案
          detail: errorDetail(e),
          onRetry: () => ref.invalidate(recordsProvider),
        ),
      ),
      data: (list) => RefreshIndicator(
        onRefresh: () async => ref.invalidate(recordsProvider),
        child: ListView(
          // Web `.main` 手机档 padding 18px 18px 104px（style.css:1391/:2750；
          // 底部 104 为 Dock 让位，ChromeMetrics.contentBottom）
          padding: const EdgeInsets.fromLTRB(
              18, 18, 18, ChromeMetrics.contentBottom),
          children: [
            // 页头：h1 + 副题（文案逐字 app.js:725；布局 style.css:342-343）
            _PageHeading(theme: theme),
            const SizedBox(height: ChromeMetrics.headingMargin),
            _Hero(
              me: me,
              list: list,
              dashboard: ref.watch(dashboardProvider).valueOrNull,
              onGoTab: onGoTab,
            ),
            const SizedBox(height: 12), // hero margin-bottom 12（:1407）
            // 2.3.4（推广段一重做）：摘除 stats-grid 三格——试点段误补回，
            // 真 Web 手机端并无此区（index.html/app.js 全库无 stats-grid 引用，
            // 盘点偏差，主人已裁定摘除）。首页构成与真 Web 1:1：
            // 页头→hero→today 双格→每日一句→最近动态。
            _TodayCells(me: me, list: list),
            const SizedBox(height: 14), // today-card margin-bottom 14（:1414）
            _DailyQuote(theme: theme),
            const SizedBox(height: 18), // daily-quote margin-bottom 18（:1906）
            // 2.3.5：「最近的小美好」动态卡区摘除（主人裁定吞首页手势）——
            // 完整动态与互动仍在时光页；_recentPosts 保留待复用。
            // ListView 尾部留白保持 104（Dock 让位）.
          ],
        ),
      ),
    );
  }

  // ignore: unused_element
  List<Widget> _recentPosts(
    BuildContext context,
    MeData me,
    List<Record> list, {
    void Function(int tab)? onGoTab,
  }) {
    final theme = Theme.of(context);
    final posts = list.where((r) => r.kind == 'post').toList()
      ..sort((a, b) => b.created.compareTo(a.created));
    final top = posts.take(3).toList();
    if (top.isEmpty) {
      return [
        _recentCard(
          context,
          tinted: false,
          onTap: () => onGoTab?.call(1), // 空态也可点：去时光页开始记录
          child: Text(
            '故事，从这一刻开始——点这里去时光页写下第一篇。',
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ];
    }
    return top.map((r) {
      final author = me.byId(r.author);
      return _recentCard(
        context,
        kind: r.kind,
        onTap: () => onGoTab?.call(1), // 详情与点赞评论在时光页（条目 4）
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Text(
                    (author?.name.isEmpty ?? true)
                        ? '?'
                        : author!.name.characters.first,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // S1（必改）：昵称无 flex 时长昵称把日期挤出右边界
                // → RenderFlex overflow。Expanded + ellipsis 截断，
                // 日期恒在右侧可见；卡片信息结构不变。
                Expanded(
                  child: Text(
                    author?.name ?? '…',
                    style: theme.textTheme.labelLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  r.date,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
            if ((r.body['title'] ?? '').toString().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  r.body['title'].toString(),
                  style: theme.textTheme.titleSmall,
                ),
              ),
            if ((r.body['content'] ?? '').toString().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  r.body['content'].toString(),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            const SizedBox(height: Spacing.gap),
            Row(
              children: [
                Icon(
                  Icons.favorite_border,
                  size: 14,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 4),
                Text('${r.likes.length}', style: theme.textTheme.bodySmall),
                const SizedBox(width: 16),
                Icon(
                  Icons.chat_bubble_outline,
                  size: 14,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 4),
                Text(
                  '${r.comments.length}',
                  style: theme.textTheme.bodySmall,
                ),
                const Spacer(),
                // 长提示语在窄屏会挤出 Row（320 宽 +8.2px 实测）：
                // Flexible + ellipsis 截断，计数恒可见。
                Flexible(
                  child: Text(
                    '媒体 ${r.media.length} · 完整互动在时光页（条目 4）',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }).toList();
  }

  /// 最近动态卡容器：`.card` 手机档 radius 17 / padding 15（style.css:1421）+
  /// kind-* 低饱和渐变 tint（165deg tint→surface 72%，style.css:1944-1956）+
  /// 顶部 1px 内高光 hairline（style.css:1937/:2017）。[kind] 为空 = 无 tint
  /// 素卡（空态提示）。
  Widget _recentCard(
    BuildContext context, {
    required VoidCallback onTap,
    required Widget child,
    String? kind,
    bool tinted = true,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final brightness = theme.brightness;
    final radius = BorderRadius.circular(17);
    return Container(
      key: kind == null ? null : const Key('home-recent-card'),
      margin: const EdgeInsets.only(bottom: 13), // .card margin-bottom 13（:298）
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: cs.outlineVariant),
        gradient: tinted && kind != null
            ? LinearGradient(
                // 165deg 方向近似（sin165°≈0.26）：tint 起点在左上、surface 72% 收
                begin: const Alignment(-0.13, -0.97),
                end: const Alignment(0.13, 0.97),
                colors: [_kindTint(kind, cs, brightness), cs.surface],
                stops: const [0, 0.72],
              )
            : null,
        color: tinted && kind == null ? cs.surface : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: [
            // 顶部内高光（--hairline，style.css:1937 浅 .72 / :2017 夜 .05）
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 1,
              child: ColoredBox(
                color: WebSemanticColors.cardHairline(brightness),
              ),
            ),
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: radius,
                child: Padding(
                  padding: const EdgeInsets.all(15), // 手机档 padding 15（:1421）
                  child: child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// kind-* 低饱和 tint（首色 α 值出处 style.css:1930-1956；rgb 通道随主题/明暗，
/// App 端等价映射为 colorScheme/语义色 withValues α）：
/// mood=tint-rose(primary .055)；post/diary/note/surprise/question/period 等默认
/// primary .04；anniversary=amber .06；wish/personal_wish/music=fertile .06；
/// quest/habit=amber .055；ledger=green .06；album=info .05（App 暂只出现前族）。
Color _kindTint(String kind, ColorScheme cs, Brightness brightness) {
  switch (kind) {
    case 'mood':
      return cs.primary.withValues(alpha: 0.055); // tint-rose（:1930）
    case 'anniversary':
      return WebSemanticColors.amber(brightness).withValues(alpha: 0.06);
    case 'wish':
    case 'personal_wish':
    case 'music':
      return WebSemanticColors.fertile(brightness).withValues(alpha: 0.06);
    case 'quest':
    case 'habit':
      return WebSemanticColors.amber(brightness).withValues(alpha: 0.055);
    case 'ledger':
      return WebSemanticColors.green(brightness).withValues(alpha: 0.06);
    default: // post/diary/draft/surprise/question/note/period（:1955-1956）
      return cs.primary.withValues(alpha: 0.04);
  }
}

/// 页头：「我们的每一天」+ 副题「一半是生活，一半是你。」
/// 文案逐字 app.js:725；布局 style.css:342-343（h1 26px/600、副题 13px muted、
/// 间距 5px）。字阶映射：h1 26 → headlineSmall（24，任务定案「26→headlineSmall
/// 或体感一致档」，App 手机档 Web 实为 22/:1401，取字阶中档并注明）；副题 13 →
/// bodySmall（12）；muted → outline（全 App 辅助文字基线）。
class _PageHeading extends StatelessWidget {
  const _PageHeading({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '我们的每一天',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.3, // h1 letter-spacing -.3px（style.css:212）
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: ChromeMetrics.headingSubGap), // 副题 mt 5（:343）
        Text(
          '一半是生活，一半是你。',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
      ],
    );
  }
}

/// ── Hero：渐变卡（两人名 / 相恋天数 / 封面 / 相恋日期设置）────────────
///
/// Web：radius 20、min-height 230（手机）、padding 18px 16px（手机）、
/// 底层三段 120° 渐变 + 双 radial 光晕（style.css:448/:1959-1964）、有封面时
/// `--hero-shade` 双向遮罩（:2258-2260）+ 文字转白（:2246-2250）。
/// 字号取手机档断点（style.css:2265-2266/@media≤720 :2289）：名字 serif 22/600
/// （任务简报 26 为桌面档）、天数 serif 42/500（桌面 52）——盘点表 2.2 双档口径，
/// App 视口属手机档；serif 字族走 webSerifStyle（不引新字体包）。
class _Hero extends ConsumerWidget {
  const _Hero({
    required this.me,
    required this.list,
    required this.dashboard,
    this.onGoTab,
  });
  final MeData me;
  final List<Record> list;
  final Dashboard? dashboard;
  final void Function(int tab)? onGoTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final partner = me.users.where((u) => u.id != me.user.id).toList();
    final paired = partner.isNotEmpty;
    // 未绑定时名字区点击 → 账号资料页的邀请卡片（App 无 Web 链接入口，功能等价）
    // 与 Web 一致：since 起算「第几天」= daysBetween+1；dashboard.days_together 服务端口径
    final days = me.spaceSince.isNotEmpty
        ? daysBetween(me.spaceSince, todayStr()) + 1
        : (dashboard?.daysTogether);
    final hasCover = (me.spaceRaw['cover'] ?? '').toString().isNotEmpty;
    // 有封面：文字转白（style.css:2246-2250）；无封面：ink（--ink 映射 onSurface）
    final namesColor = hasCover ? Colors.white : cs.onSurface;
    final daysColor = hasCover ? Colors.white : cs.onSurface;
    final metaColor = hasCover
        ? Colors.white.withValues(alpha: 0.94) // hero-foot 白 .94（:2277）
        : cs.outline;

    return Container(
      key: const Key('home-hero'),
      constraints: const BoxConstraints(minHeight: 230), // 手机 min-height（:1406）
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20), // --radius（style.css:448）
        border: Border.all(color: cs.outlineVariant), // 1px --line（:449）
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            // 已绑定：整卡可点 → 相恋日期/空间信息设置层（含编辑角标 affordance）；
            // 未绑定：点卡 → 账号资料页的邀请卡片（App 无 Web 链接入口，功能等价）
            onTap: () {
              if (partner.isNotEmpty) {
                _editSince(context, ref);
              } else {
                context.push('/profile');
              }
            },
            child: Stack(
              children: [
                // 三段 120° 渐变 + 双 radial 光晕（CustomPaint，详见 painter 注释）
                Positioned.fill(
                  child: CustomPaint(
                    painter: _HeroGradientPainter(theme.brightness, cs),
                  ),
                ),
                // 段 D：主页封面（space.cover / cover_pos），保存后立刻变。
                if (hasCover) _HomeCover(me: me),
                // 2.3.7（主人构图拍板）：名字行固定顶部；天数大数字与日期行
                // 整体下移锚到封面卡下边缘上方（底部可读性靠 hero-shade 遮罩）。
                Padding(
                  // 手机档 hero padding 18px 16px（style.css:1405）
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                      Text.rich(
                        TextSpan(
                          children: <InlineSpan>[
                            TextSpan(text: paired ? me.user.name : '等你，把另一半邀请进来'),
                            if (paired)
                              TextSpan(
                                // heart-symbol（style.css:2283-2285）：主色、
                                // fs-body、有封面转白 .72
                                text: ' ♥ ',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w400,
                                  color: hasCover
                                      ? Colors.white.withValues(alpha: 0.72)
                                      : cs.primary,
                                ),
                              ),
                            if (paired) TextSpan(text: partner.first.name),
                          ],
                        ),
                        // hero-names-text：serif、手机档 fs-h2 22、w600、ls .5（:2264-2266）
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontFamily: webSerifFamily,
                          fontFamilyFallback: webSerifFallback,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                          height: 1.3,
                          color: namesColor,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      ],
                    ),
                  ),
                ),
                // 天数大数字 + 日期行：锚到封面卡下边缘上方（padding 18）
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                      Text.rich(
                        TextSpan(
                          children: <InlineSpan>[
                            TextSpan(
                              // hero-days strong：serif 42（手机档 :2289）/500
                              text: days == null ? '—' : '$days',
                              style: webSerifStyle(42, color: daysColor, height: 1.15),
                            ),
                            TextSpan(
                              // em「天」：fs-body、常规字族（:2272-2274）
                              text: ' 天',
                              style: TextStyle(fontSize: 14, color: daysColor),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (me.spaceSince.isEmpty)
                        Text(
                          '点这里设置相恋日期 →',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: cs.primary),
                        )
                      else
                        Text(
                          '${me.spaceSince} 起 · 今天也要好好相爱',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: metaColor),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: Icon(
                    Icons.edit,
                    size: 16,
                    color: hasCover
                        ? Colors.white.withValues(alpha: 0.8)
                        : cs.outline,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 设置相恋日期（对齐 Web spaceForm：PUT /api/space 全量覆盖，只改 name/since）
  Future<void> _editSince(BuildContext context, WidgetRef ref) =>
      showSpaceEditDialog(context, ref, me);
}

/// hero 渐变底 painter（三层，绘制顺序 = CSS 层序：linear 最底、右下光晕、
/// 左上白光晕最顶——style.css:1959-1964）：
/// ① 底层 linear-gradient(120deg, soft 0%, surface 55%, green-soft 100%)（:448）：
///    soft → primaryContainer（--soft 最近语义档）、surface、green-soft
///    （Web 语义色跟明暗两换，style.css:39/:1512）。120° 方向 ≈ 对齐
///    (-0.43,-0.25)→(0.43,0.25)。
/// ② 右下 primary 光晕：radial 95% 85% at 100% 105%、primary α.10 → 透明 60%
///    （:1961-1962；Flutter 无椭圆 radial，用圆半径 0.95×W 近似）。
/// ③ 左上白光晕：radial 130% 100% at 0 0、白 .55 → 透明 52%（:1960；同上近似）。
class _HeroGradientPainter extends CustomPainter {
  const _HeroGradientPainter(this.brightness, this.cs);

  final Brightness brightness;
  final ColorScheme cs;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    void paintShader(Shader shader) =>
        canvas.drawRect(rect, Paint()..shader = shader);

    // ① 底层三段 120° 渐变
    paintShader(
      LinearGradient(
        begin: const Alignment(-0.43, -0.25),
        end: const Alignment(0.43, 0.25),
        colors: <Color>[
          cs.primaryContainer,
          cs.surface,
          WebSemanticColors.greenSoft(brightness),
        ],
        stops: const <double>[0, 0.55, 1],
      ).createShader(rect),
    );

    // ② 右下 primary 光晕（α .10 → 透明 60%）
    paintShader(
      ui.Gradient.radial(
        Offset(size.width, size.height * 1.05),
        size.width * 0.95,
        <Color>[
          cs.primary.withValues(alpha: 0.10),
          cs.primary.withValues(alpha: 0),
        ],
        <double>[0, 0.6],
      ),
    );

    // ③ 左上白光晕（白 .55 → 透明 52%）
    paintShader(
      ui.Gradient.radial(
        Offset.zero,
        size.width * 1.3,
        <Color>[
          Colors.white.withValues(alpha: 0.55),
          Colors.white.withValues(alpha: 0),
        ],
        <double>[0, 0.52],
      ),
    );
  }

  @override
  bool shouldRepaint(_HeroGradientPainter oldDelegate) =>
      oldDelegate.brightness != brightness || oldDelegate.cs != cs;
}

/// 空间信息编辑弹层（首页封面卡 + 设置页 / hub「空间信息」跳转入口共用，
/// 段 D 只做导航，不复制 UI）。
Future<void> showSpaceEditDialog(
  BuildContext context,
  WidgetRef ref,
  MeData me,
) async {
  // 2.3.7（主人实证：改了没用）：「空间名称」输入框摘除——PUT 全量合并
  // 口径不破，name 固定带回 me.spaceName 原值（updateSpace ...spaceRaw 展开），
  // 名字不会存没。
  DateTime? picked = me.spaceSince.isNotEmpty
      ? DateTime.tryParse(me.spaceSince)
      : null;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('空间信息'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 2.3.7：空间名称输入框已摘除（只读展示当前名，不可在此改）。
            Row(
              children: [
                Text('空间名称',
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.outline)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(me.spaceName,
                      style: Theme.of(ctx).textTheme.bodyLarge),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    picked == null ? '还没选择相恋日期' : '从 ${_fmtDate(picked!)} 开始相爱',
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: ctx,
                      initialDate: picked ?? DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime.now(),
                    );
                    if (d != null) setState(() => picked = d);
                  },
                  child: const Text('选日期'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '日期决定首页「在一起第几天」从哪天算起。',
              style: Theme.of(ctx).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(ctx).colorScheme.outline),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  if (ok != true || picked == null) return;
  try {
    final dio = await ref.read(dioProvider.future);
    // 2.3.7：名称原样带回（输入框已摘除，全量合并口径不破）。
    final name = me.spaceName;
    final since = _fmtDate(picked!);
    // 7-C：4xx 被 validateAppStatus 放行，updateSpace 返回服务端 detail 原文；
    // 失败只发错误通知、不重拉、不自动重试（输入随弹层关闭本就保留在控件里）。
    final err = await updateSpace(dio, me.spaceRaw, name: name, since: since);
    if (err != null) {
      if (context.mounted) {
        ref
            .read(chatToastProvider.notifier)
            .show('保存失败：$err', tone: ChatToastTone.error);
      }
      return;
    }
    // me（space 原样对象）与聚合数据全部失效重拉
    await ref.read(authProvider.notifier).reload();
    ref.invalidate(recordsProvider);
    ref.invalidate(dashboardProvider);
  } catch (e) {
    if (context.mounted) {
      ref
          .read(chatToastProvider.notifier)
          .show('保存失败：${errorDetail(e)}', tone: ChatToastTone.error);
    }
  }
}

String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// ── today 双格：今天的心情 + 最近纪念日倒计时 ─────────────────────
///
/// Web 手机档 today-card 两列双格（style.css:494/:1414）：today-cell radius 16
/// （:496）、手机 padding 11px 13px（:1417）、1px --line 描边、surface 底；
/// 倒计时 strong serif 26/500 primary-dark（:505）。原单卡分区拆为双格，
/// 数据与交互零变化（mood 记/改走原 _MoodRow；纪念日格直达管理页）。
class _TodayCells extends StatelessWidget {
  const _TodayCells({required this.me, required this.list});

  final MeData me;
  final List<Record> list;

  /// 最近纪念日（🔴 段 B 起委托 together_data.anniversaryDue 唯一实现——
  /// 首页/hub 展示卡/纪念日管理页三处数字必须永远一致，不再各写一套；
  /// 口径不变：annual=true 按年推进 + 02-29 回退；lunar 按原样近似；
  /// days<0 跳过（2026-11-11 真机抓到 -97 天的教训已锁进纯函数）。
  _Ann? nextAnniversary() {
    final t = todayStr();
    _Ann? best;
    for (final r in list) {
      if (r.kind != 'anniversary') continue;
      final d = anniversaryDue(r.body, t);
      if (d == null) continue;
      if (best == null || d.days < best.days) best = _Ann(r, d.due, d.days);
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final ann = nextAnniversary();
    final today = todayStr();

    TextStyle headerStyle() => theme.textTheme.bodySmall!.copyWith(
          fontWeight: FontWeight.w500,
          letterSpacing: 0.5, // .tiny letter-spacing .5（:497）
          color: cs.primary, // .tiny primary-dark → primary 映射
        );

    // IntrinsicHeight + stretch：双格等高（对齐 Web grid 拉伸语义），
    // ListView 无界高度下 IntrinsicHeight 给 Row 提供有界约束。
    return IntrinsicHeight(
      child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 格 ①：今天的心情（两人 mood 行，自己的可记可改，对方只读）
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(16), // :496
              border: Border.all(color: cs.outlineVariant),
            ),
            // Material 透明层：原单卡结构由 Card 提供 ink 介质，拆格后自补
            child: Material(
              color: Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.all(13), // 手机档 11px 13px（:1417）
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('今天的心情', style: headerStyle()),
                    const SizedBox(height: 8), // .tiny margin-bottom 8（:498）
                    for (final u in me.users)
                      _MoodRow(
                        me: me,
                        user: u,
                        today: today,
                        record: list
                            .where(
                              (r) =>
                                  r.kind == 'mood' &&
                                  r.author == u.id &&
                                  r.date == today,
                            )
                            .firstOrNull,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10), // today-card gap 10（:1414）
        // 格 ②：最近纪念日倒计时（整格可点 → 纪念日管理页，段 B 直达接线）
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(16), // :496
              border: Border.all(color: cs.outlineVariant),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => context.push('/together/anniversary'),
                child: Padding(
                  padding: const EdgeInsets.all(13),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text('最近纪念日', style: headerStyle()),
                          ),
                          Icon(Icons.chevron_right,
                              size: 14, color: cs.outline), // tiny-go（:508）
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (ann != null) ...[
                        // 2.3.7（主人实证标题腰斩）：标题独占一行、最多两行、
                        // 超宽字号自适应（FittedBox scaleDown）——不再与「天后」
                        // 挤同一行省略；倒计时数字口径不变。
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '${ann.r.body['title'] ?? '纪念日'}',
                            maxLines: 1,
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            // countdown-mini strong：serif 26/500（:505），
                            // primary-dark → primary 映射（深浅随主题）
                            Text('${ann.days}',
                                style: webSerifStyle(26, color: cs.primary)),
                            const SizedBox(width: 6),
                            Text('天后',
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: cs.outline)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${ann.due} · 别忘了给彼此一个拥抱',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: cs.outline),
                        ),
                      ] else
                        Text(
                          '留一个日子，给仪式感 · 点此添加纪念日。',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: cs.outline),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
      ),
    );
  }
}

/// 推算后的最近纪念日（原始记录 + 生效日期 + 天数）
class _Ann {
  const _Ann(this.r, this.due, this.days);
  final Record r;
  final String due;
  final int days;
}

/// 一行心情：自己已记 → 点开改；自己没记 → 点开记一笔；对方 → 只读展示
class _MoodRow extends ConsumerWidget {
  const _MoodRow({
    required this.me,
    required this.user,
    required this.today,
    required this.record,
  });
  final MeData me;
  final SpaceUser user;
  final String today;
  final Record? record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mine = user.id == me.user.id;
    final m = record;
    final bubble = m != null
        ? '${(m.body['emoji'] ?? '')} ${(m.body['content'] ?? '已记录')}'
        : (mine ? '＋ 记一笔' : '还没记');

    // 2.3.7 范围再修正（主人裁定）：「头像 + 胶囊」一行式——每人一行，
    // 左头像圈、右胶囊（记一笔/还没记），不显示名字文本；两行胶囊左缘对齐、
    // 同尺寸（同 Expanded + 同 padding，头像半径一致 14）；点胶囊既有行为不变。
    // 头像保留 AvatarMedia 照片本体（低频缓存 + 鉴权头，空/失败回退首字母）。
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 2.3.7：照片头像（低频缓存 + 鉴权头），空/失败回退首字母。
          AvatarMedia(
            key: Key('mood-avatar-${user.id}'),
            avatarId: user.avatar,
            name: user.name,
            radius: 14,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              key: Key('mood-pill-${user.id}'),
              borderRadius: BorderRadius.circular(999),
              onTap: (m != null && !mine)
                  ? null // 对方的心情手记回顾在「我们」页（条目 6）
                  : () => _openMoodSheet(context, ref),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: m != null
                      ? theme.colorScheme.primaryContainer.withValues(
                          alpha: 0.45,
                        )
                      : theme.colorScheme.surfaceContainerHighest.withValues(
                          alpha: 0.5,
                        ),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  bubble,
                  style: theme.textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 记/改今日心情：emoji 快选 + 一句话（POST 或 PUT /api/records，带 client_id 防重）
  Future<void> _openMoodSheet(BuildContext context, WidgetRef ref) async {
    const emojis = ['☀️', '😊', '🥰', '😮‍💨', '😢', '😤', '😴', '🎉'];
    String emoji = record?.body['emoji']?.toString() ?? '☀️';
    final contentCtrl = TextEditingController(
      text: record?.body['content']?.toString() ?? '',
    );
    final saved = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('今天的心情', style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: emojis
                    .map(
                      (e) => ChoiceChip(
                        label: Text(e, style: const TextStyle(fontSize: 20)),
                        selected: emoji == e,
                        onSelected: (_) => setState(() => emoji = e),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentCtrl,
                maxLength: 60,
                decoration: const InputDecoration(
                  labelText: '一句话（可留空）',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(record == null ? '记一笔' : '更新'),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved != true) return;
    try {
      final dio = await ref.read(dioProvider.future);
      final body = {
        'date': today,
        'emoji': emoji,
        'content': contentCtrl.text.trim(),
        'media': [],
      };
      final Response<dynamic> r;
      if (record == null) {
        r = await dio.post(
          '/api/records',
          data: {'kind': 'mood', 'body': body, 'client_id': newClientId()},
        );
      } else {
        r = await dio.put(
          '/api/records/${record!.id}',
          data: {'kind': 'mood', 'body': body, 'client_id': record!.clientId},
        );
      }
      // 段 A（7-C）：validateAppStatus 放行 4xx——显式判定；失败 detail 原文
      // 直通呈现、不 invalidate（不刷新假数据）。
      final err = writeResponseError(r);
      if (err != null) {
        if (context.mounted) {
          ref
              .read(chatToastProvider.notifier)
              .show(err, tone: ChatToastTone.error);
        }
        return;
      }
      ref.invalidate(recordsProvider);
      ref.invalidate(dashboardProvider);
    } catch (e) {
      if (context.mounted) {
        ref
            .read(chatToastProvider.notifier)
            .show(errorDetail(e), tone: ChatToastTone.error);
      }
    }
  }
}

/// 每日一句 soft 胶囊（style.css:1906-1909）：radius 12、padding 14px 18px、
/// --soft 底（→ primaryContainer 映射）、正文 fs-lg（→ bodyMedium 14）、
/// 右侧 small fs-xs muted（→ labelSmall 11 / outline）。
class _DailyQuote extends StatelessWidget {
  const _DailyQuote({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(12), // --radius-s（:1906）
      ),
      child: Row(
        children: [
          Text('✦', style: TextStyle(color: cs.primary)), // 图标 primary（:1907）
          const SizedBox(width: 10), // gap 10（:1906）
          Expanded(
            child: Text(
              dailyQuotes[DateTime.now().day % dailyQuotes.length],
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: cs.onPrimaryContainer),
            ),
          ),
          Text(
            '今天的一句',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: cs.outline), // small muted（:1909）
          ),
        ],
      ),
    );
  }
}

/// 段 D 主页封面：`space.cover` 媒体 id + `cover_pos` 构图（默认 x/y=50,z=1）。
/// 只消费 `/api/me` 的 space，媒体 URL 走 `chatBaseProvider`，Cookie 头走
/// `mediaCookieHeadersProvider`；换封面后 `auth.reload()` 让本卡重建。
/// 2.3.1：遮罩改 `--hero-shade` 双向渐变（style.css:2258-2260）——90deg 横向
/// 压暗（.74→.4@58%→.1）+ 0deg 自下而上（.52→透明@52%），色值固定深棕
/// （rgba(37,28,34,·)，跟主题无关）；替换原 surface α0.45 单色。
class _HomeCover extends ConsumerWidget {
  const _HomeCover({required this.me});

  final MeData me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cover = (me.spaceRaw['cover'] ?? '').toString();
    if (cover.isEmpty) return const SizedBox.shrink();
    final base = ref.watch(chatBaseProvider).valueOrNull;
    if (base == null) return const SizedBox.shrink();
    final headers = ref.watch(mediaCookieHeadersProvider).valueOrNull;
    final pos = me.spaceRaw['cover_pos'];
    final x = pos is Map
        ? (num.tryParse((pos['x'] ?? 50).toString()) ?? 50)
        : 50;
    final y = pos is Map
        ? (num.tryParse((pos['y'] ?? 50).toString()) ?? 50)
        : 50;
    final z = pos is Map ? (num.tryParse((pos['z'] ?? 1).toString()) ?? 1) : 1;
    return Positioned.fill(
      child: Stack(
        children: [
          Transform.scale(
            scale: z.toDouble().clamp(1.0, 3.0),
            child: Image.network(
              '$base/media/$cover?preview=true',
              key: Key('home-cover-$cover'),
              headers: headers,
              fit: BoxFit.cover,
              alignment: Alignment(
                (x.toDouble() / 50 - 1).clamp(-1.0, 1.0),
                (y.toDouble() / 50 - 1).clamp(-1.0, 1.0),
              ),
              width: double.infinity,
              height: double.infinity,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
          // --hero-shade 第 1 层：90deg（style.css:2259）
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: <Color>[
                    const Color.fromRGBO(37, 28, 34, 0.74),
                    const Color.fromRGBO(37, 28, 34, 0.40),
                    const Color.fromRGBO(37, 28, 34, 0.10),
                  ],
                  stops: const <double>[0, 0.58, 1],
                ),
              ),
            ),
          ),
          // --hero-shade 第 2 层：0deg 自下而上（style.css:2259）
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  // 2.3.7：下移后底部文字可读性加强（主人拍板口径：靠既有
                  // hero-shade 加强下半部）——下缘 alpha .52→.62。
                  colors: <Color>[
                    const Color.fromRGBO(37, 28, 34, 0.62),
                    const Color.fromRGBO(37, 28, 34, 0),
                  ],
                  stops: const <double>[0, 0.52],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
