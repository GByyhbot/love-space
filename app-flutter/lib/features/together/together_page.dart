/// 「我们」页 hub（条目 6 · 段 A/B）：
/// heading + 纪念日只读展示卡（最近纪念日倒计时，段 B 起点击直达管理页——
/// 决策点①定案：管理页归首页入口 + 本卡双入口）+ 已落地工具卡
/// （共同年历 / 心情手记 / 悄悄留言 / 共同愿望），后续段页面落地后逐段增补卡，
/// 🔴 不预放死卡。数据与工具页共用 togetherControllerProvider（一次全量）。
/// SSE other 且 tab 激活 → reset 重拉；顶部通知由全局 ChatToastHost 承载。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/sse/sse_client.dart';
import '../../core/together/together_data.dart';
import 'together_controller.dart';

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
        () => ref.read(togetherControllerProvider.notifier).bootstrap());
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
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Text('关于我们，还有好多好多', style: theme.textTheme.headlineSmall),
              Text('把喜欢落在实处，把日子过成纪念。',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
              const SizedBox(height: 16),
              _AnniversaryCard(ann: ann),
              const SizedBox(height: 12),
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
              if (st.error != null) ...[
                const SizedBox(height: 12),
                Text(st.error!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 工具入口卡（仅本段已落地页面；后续段随页面落地逐段增补，不预放死卡）
  Widget _toolCard(BuildContext context,
      {required String emoji,
      required String title,
      required String desc,
      required String route}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => context.push(route),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(children: [
              Text(emoji, style: const TextStyle(fontSize: 26)),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(desc,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.outline)),
              ])),
              Icon(Icons.chevron_right_rounded, color: cs.outline),
            ]),
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
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/together/anniversary'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: a == null
              ? Text('留一个日子，给仪式感 · 点此去首页添加纪念日。',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.outline))
              : Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${a.days}',
                      style: theme.textTheme.headlineMedium
                          ?.copyWith(color: cs.primary)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '天后 · ${(a.record.body['title'] ?? '纪念日')}\n'
                        '${a.due} · 点此管理纪念日',
                        softWrap: true,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.outline),
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: cs.outline),
                ]),
        ),
      ),
    );
  }
}
