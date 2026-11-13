/// 首页（阶段 2 · 条目 2，对齐 Web homePage）：主视觉 hero（两人名/相恋天数/相恋日期
/// 设置）、今天的心情（两人 mood 行，自己的可记可改）、最近纪念日倒计时、最新动态
/// （post 前 3）、每日一句（本地轮换）。
/// 数据：GET /api/records?kind=<排除 chat>&limit=1000（与 Web 聚合一致）+ /api/dashboard；
/// SSE other 事件 → invalidate 重拉（增量重拉在聊天专章细化）。
/// 本页不含：心愿/歌单/共同打卡（归条目 6「我们」）、封面与天数卡片（媒体能力，阶段 4）、
/// on-this-day / 小年报（归属待主人定，小结对照清单已注明）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/sse/sse_client.dart';
import '../../core/together/together_data.dart' show anniversaryDue;
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;

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
  '喜欢是乍见之欢，爱是久处不厌。', '日子很普通，但有你就不一样。', '今天也想和你一起，把生活过成一件件小事。',
  '你是我所有计划里，唯一不变的那一项。', '一起吃饭，一起发呆，一起把日子过成小事。', '世界很大，我的坐标是你。',
  '想和你把「以后」两个字，慢慢过成具体的日子。', '不必每天都惊喜，只要每天都有你。', '我们不用很厉害，只要一直在一起。',
  '喜欢你这件事，我做得最久。', '天气预报说明天有雨，我记得带伞，也记得带你。', '你笑的时候，我觉得今天没白过。',
  '柴米油盐里，也藏着浪漫。', '不用去很远的地方，回家就是最好的旅行。', '你在的地方，就是我想去的地方。',
  '想和你一起变老，慢慢的那种。', '今天的月亮很好，你也在，就更好了。', '爱是记得，也是愿意。',
  '日子一天天过去，喜欢一天天变多。', '我们把普通的日子，过成了纪念日。', '你说话的时候，我在认真听。',
  '抱一下，今天就算圆满。', '一天很短，但装得下想念。', '明天也一起吃早饭吧。',
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

    if (me == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return records.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('加载失败'),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => ref.invalidate(recordsProvider),
            child: const Text('重试'),
          ),
        ]),
      ),
      data: (list) => RefreshIndicator(
        onRefresh: () async => ref.invalidate(recordsProvider),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _Hero(me: me, list: list,
                dashboard: ref.watch(dashboardProvider).valueOrNull,
                onGoTab: onGoTab),
            const SizedBox(height: 12),
            _TodayCard(me: me, list: list, onGoTab: onGoTab),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(children: [
                Text('✦', style: TextStyle(color: theme.colorScheme.primary)),
                const SizedBox(width: 8),
                Expanded(child: Text(dailyQuotes[DateTime.now().day % dailyQuotes.length],
                    style: theme.textTheme.bodyMedium)),
                Text('今天的一句', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
              ]),
            ),
            const SizedBox(height: 16),
            Text('最近的小美好', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            ..._recentPosts(context, me, list, onGoTab: onGoTab),
          ],
        ),
      ),
    );
  }

  List<Widget> _recentPosts(BuildContext context, MeData me, List<Record> list,
      {void Function(int tab)? onGoTab}) {
    final theme = Theme.of(context);
    final posts = list.where((r) => r.kind == 'post').toList()
      ..sort((a, b) => b.created.compareTo(a.created));
    final top = posts.take(3).toList();
    if (top.isEmpty) {
      return [
        Card(child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => onGoTab?.call(1), // 空态也可点：去时光页开始记录
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text('故事，从这一刻开始——点这里去时光页写下第一篇。',
                style: theme.textTheme.bodyMedium),
          ),
        )),
      ];
    }
    return top.map((r) {
      final author = me.byId(r.author);
      return Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => onGoTab?.call(1), // 详情与点赞评论在时光页（条目 4）
          child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(radius: 12,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Text((author?.name.isEmpty ?? true) ? '?' : author!.name.characters.first,
                      style: TextStyle(fontSize: 11, color: theme.colorScheme.onPrimaryContainer))),
              const SizedBox(width: 8),
              Text(author?.name ?? '…', style: theme.textTheme.labelLarge),
              const SizedBox(width: 8),
              Text(r.date, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
            ]),
            if ((r.body['title'] ?? '').toString().isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 8),
                  child: Text(r.body['title'].toString(), style: theme.textTheme.titleSmall)),
            if ((r.body['content'] ?? '').toString().isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 4),
                  child: Text(r.body['content'].toString(), style: theme.textTheme.bodyMedium)),
            const SizedBox(height: 6),
            Row(children: [
              Icon(Icons.favorite_border, size: 14, color: theme.colorScheme.outline),
              const SizedBox(width: 4),
              Text('${r.likes.length}', style: theme.textTheme.bodySmall),
              const SizedBox(width: 16),
              Icon(Icons.chat_bubble_outline, size: 14, color: theme.colorScheme.outline),
              const SizedBox(width: 4),
              Text('${r.comments.length}', style: theme.textTheme.bodySmall),
              const Spacer(),
              Text('媒体 ${r.media.length} · 完整互动在时光页（条目 4）',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
            ]),
          ]),
        ),
        ),
      );
    }).toList();
  }
}

/// ── Hero：两人名 / 相恋天数 / 相恋日期设置 ─────────────────────────
class _Hero extends ConsumerWidget {
  const _Hero({required this.me, required this.list, required this.dashboard, this.onGoTab});
  final MeData me;
  final List<Record> list;
  final Dashboard? dashboard;
  final void Function(int tab)? onGoTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final partner = me.users.where((u) => u.id != me.user.id).toList();
    final paired = partner.isNotEmpty;
    // 未绑定时名字区点击 → 账号资料页的邀请卡片（App 无 Web 链接入口，功能等价）
    final names = paired
        ? '${me.user.name} ♥ ${partner.first.name}'
        : '等你，把另一半邀请进来';
    // 与 Web 一致：since 起算「第几天」= daysBetween+1；dashboard.days_together 服务端口径
    final days = me.spaceSince.isNotEmpty
        ? daysBetween(me.spaceSince, todayStr()) + 1
        : (dashboard?.daysTogether);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        // 已绑定：整卡可点 → 相恋日期/空间信息设置层（含编辑角标 affordance）；
        // 未绑定：点卡 → 账号资料页的邀请卡片（App 无 Web 链接入口，功能等价）
        onTap: () {
          if (partner.isNotEmpty) {
            _editSince(context, ref);
          } else {
            context.push('/profile');
          }
        },
        child: Stack(children: [
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(names, textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
              const SizedBox(height: 10),
              Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                Text('我们相恋  ', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                Text(days == null ? '—' : '$days',
                    style: theme.textTheme.displaySmall?.copyWith(color: theme.colorScheme.primary)),
                Text(' 天', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
              ]),
              const SizedBox(height: 8),
              if (me.spaceSince.isEmpty)
                Text('点这里设置相恋日期 →', textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary))
              else
                Text('${me.spaceSince} 起 · 点卡片可编辑 · 今天也要好好相爱',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
            ]),
          ),
          Positioned(
            right: 8, top: 8,
            child: Icon(Icons.edit, size: 16, color: theme.colorScheme.outline),
          ),
        ]),
      ),
    );
  }

  /// 设置相恋日期（对齐 Web spaceForm：PUT /api/space 全量覆盖，只改 name/since）
  Future<void> _editSince(BuildContext context, WidgetRef ref) async {
    final nameCtrl = TextEditingController(text: me.spaceName);
    DateTime? picked = me.spaceSince.isNotEmpty ? DateTime.tryParse(me.spaceSince) : null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) => AlertDialog(
        title: const Text('空间信息'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: nameCtrl, maxLength: 60,
              decoration: const InputDecoration(labelText: '空间名称')),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: Text(picked == null
                ? '还没选择相恋日期'
                : '从 ${_fmtDate(picked!)} 开始相爱')),
            TextButton(
              onPressed: () async {
                final d = await showDatePicker(
                    context: ctx,
                    initialDate: picked ?? DateTime.now(),
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now());
                if (d != null) setState(() => picked = d);
              },
              child: const Text('选日期'),
            ),
          ]),
          const SizedBox(height: 4),
          Text('日期决定首页「在一起第几天」从哪天算起。',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(color: Theme.of(ctx).colorScheme.outline)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      )),
    );
    if (ok != true || picked == null) return;
    try {
      final dio = await ref.read(dioProvider.future);
      final name = nameCtrl.text.trim().isEmpty ? me.spaceName : nameCtrl.text.trim();
      final since = _fmtDate(picked!);
      await updateSpace(dio, me.spaceRaw, name: name, since: since);
      // me（space 原样对象）与聚合数据全部失效重拉
      await ref.read(authProvider.notifier).reload();
      ref.invalidate(recordsProvider);
      ref.invalidate(dashboardProvider);
    } catch (e) {
      if (context.mounted) {
        ref.read(chatToastProvider.notifier).show('保存失败：$e',
            tone: ChatToastTone.error);
      }
    }
  }
}

String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// ── 今天的心情（两人 mood 行）+ 最近纪念日倒计时 ────────────────────
class _TodayCard extends ConsumerWidget {
  const _TodayCard({required this.me, required this.list, this.onGoTab});
  final MeData me;
  final List<Record> list;
  final void Function(int tab)? onGoTab;

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
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final ann = nextAnniversary();
    final today = todayStr();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('☀ 今天的心情', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          // 两人 mood 行（对齐 Web moodRows：没记可记，已记可改，对方只读展示）
          for (final u in me.users)
            _MoodRow(me: me, user: u, today: today,
                record: list.where((r) => r.kind == 'mood' && r.author == u.id && r.date == today).firstOrNull),
          const Divider(height: 24),
          Text('📅 最近纪念日', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          // 整区可点 → 纪念日管理页（段 B 二级页；决策点①定案的直达接线）
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => context.push('/together/anniversary'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (ann != null)
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${ann.days}',
                      style: theme.textTheme.headlineMedium?.copyWith(color: theme.colorScheme.primary)),
                  const SizedBox(width: 8),
                  Expanded(child: Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('天后 · ${(ann.r.body['title'] ?? '纪念日')}\n${ann.due} · 别忘了给彼此一个拥抱 · 点此查看全部',
                        softWrap: true,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                  )),
                  Icon(Icons.chevron_right, color: theme.colorScheme.outline),
                ])
              else
                Text('留一个日子，给仪式感 · 点此添加纪念日。',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
              ]),
            ),
          ),
        ]),
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
  const _MoodRow({required this.me, required this.user, required this.today, required this.record});
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

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        CircleAvatar(radius: 14,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Text(user.name.isEmpty ? '?' : user.name.characters.first,
                style: TextStyle(fontSize: 13, color: theme.colorScheme.onPrimaryContainer))),
        const SizedBox(width: 10),
        Text(user.name, style: theme.textTheme.labelLarge),
        const SizedBox(width: 10),
        Expanded(child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: (m != null && !mine)
              ? null // 对方的心情手记回顾在「我们」页（条目 6）
              : () => _openMoodSheet(context, ref),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: m != null
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.45)
                  : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(bubble, style: theme.textTheme.bodyMedium),
          ),
        )),
      ]),
    );
  }

  /// 记/改今日心情：emoji 快选 + 一句话（POST 或 PUT /api/records，带 client_id 防重）
  Future<void> _openMoodSheet(BuildContext context, WidgetRef ref) async {
    const emojis = ['☀️', '😊', '🥰', '😮‍💨', '😢', '😤', '😴', '🎉'];
    String emoji = record?.body['emoji']?.toString() ?? '☀️';
    final contentCtrl = TextEditingController(text: record?.body['content']?.toString() ?? '');
    final saved = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) => Padding(
        padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('今天的心情', style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: emojis.map((e) => ChoiceChip(
              label: Text(e, style: const TextStyle(fontSize: 20)),
              selected: emoji == e,
              onSelected: (_) => setState(() => emoji = e))).toList()),
          const SizedBox(height: 12),
          TextField(controller: contentCtrl, maxLength: 60,
              decoration: const InputDecoration(labelText: '一句话（可留空）', counterText: '')),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(record == null ? '记一笔' : '更新'),
          ),
        ]),
      )),
    );
    if (saved != true) return;
    try {
      final dio = await ref.read(dioProvider.future);
      final body = {'date': today, 'emoji': emoji, 'content': contentCtrl.text.trim(), 'media': []};
      if (record == null) {
        await dio.post('/api/records', data: {
          'kind': 'mood', 'body': body, 'client_id': newClientId(),
        });
      } else {
        await dio.put('/api/records/${record!.id}', data: {
          'kind': 'mood', 'body': body, 'client_id': record!.clientId,
        });
      }
      ref.invalidate(recordsProvider);
      ref.invalidate(dashboardProvider);
    } catch (e) {
      if (context.mounted) {
        ref.read(chatToastProvider.notifier).show('保存失败：$e',
            tone: ChatToastTone.error);
      }
    }
  }
}
