/// 报备信息（2.8.0 · 「我们」页新增二级页）。
///
/// 数据源（全部既有，**后端零改动、无新增轮询**）：
/// · `GET /api/peer/status` —— 双方 `peer_location_latest` + 对方共享开关；
/// · `GET /api/peer/track?date=` —— 对方今日报备点数（取当日 points 计数；
///   对方 track 关闭或该请求失败 → 该行整行不显示，不冒充 0）；
/// · 原生 `peer_loc/native` status（采集实态 / 待上报队列）——与设置页验证卡
///   同源同口径，不另建通道；
/// · `peerExpectedOn()` / `peerBatteryIgnored()` —— fix6 既有期望态与电池豁免。
///
/// 刷新语义：打开拉一次；页内订阅 SSE `peer` 段（第 7 段），到达即**静默**
/// 重拉（不弹提示、不打断操作）。失败 = 「状态未知」+ 重试；允许灰显上次
/// 成功数据，但必须标注其时间戳——不许把旧值当实时。
///
/// 2.8.7 第三段（纯呈现，后端零改动）：页首「TA 的状态」卡（电量/充电、网络、
/// 最后活跃含 6 小时失联警示、今日使用）+ 「今日时间线」（竖线串起状态变化与
/// 报备）。取不到的项整行不显示，一行都没有则整卡不显示——绝不拿 0 糊弄。
///
/// 明确不做：地图与轨迹回放、分档开关、应用使用记录（`top_apps`）、后端改动、
/// 设置页验证卡的任何改动（本页只读复用其数据源）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/peer/peer_locator.dart';
import '../../core/peer/peer_report_api.dart';
import '../../core/peer/peer_report_data.dart';
import '../../core/peer/peer_status_card.dart';
import '../../core/peer/state_event_text.dart';
import '../../core/sse/sse_client.dart';
import '../../core/theme/tokens.dart';
import '../../core/ui/empty_view.dart';
import '../../core/ui/error_view.dart';
import '../../core/ui/progress.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;

class PeerReportPage extends ConsumerStatefulWidget {
  const PeerReportPage({super.key});

  @override
  ConsumerState<PeerReportPage> createState() => _PeerReportPageState();
}

class _PeerReportPageState extends ConsumerState<PeerReportPage> {
  PeerReport? _data;
  bool _loading = false;
  String? _error;

  /// 我的侧实态（原生单一事实源）+ 期望态 + 电池豁免。
  bool _running = false;
  int? _queue;
  bool _expectedOn = false;
  bool? _batteryIgnored;

  /// 今日设备状态汇总（2.8.7；`GET /api/peer/state-daily` 当日）。
  PeerStateDaily? _stateDaily;

  /// 今日事件流（P0 新增；`GET /api/peer/events` 当日）。
  PeerEventsDay? _day;
  bool _dayLoading = false;
  String? _dayError;

  /// 正在回应的事件 id（非空即禁用全部回应按钮，防弱网连点重复推送）。
  String? _ackingId;

  /// 正在回应的 emoji（只给被点的那个按钮画 loading）。
  String? _ackingEmoji;

  /// 回应按钮文案（三个一键回应）。
  static const List<String> _ackEmojis = ['❤️', '🫂', '👍'];

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  /// [silent] = SSE peer 段触发的静默刷新：不切 loading、不清旧值。
  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final dio = await ref.read(api.dioProvider.future);
      final data = await fetchPeerReport(dio);
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // 失败不清数据：旧值可灰显，但页面顶部会标注其时间（不冒充实时）
      setState(() {
        _error = api.errorDetail(e);
        _loading = false;
      });
    }
    await _loadMine();
    await _loadEvents(silent: silent);
    await _loadStateDaily(silent: silent);
  }

  /// 今日设备状态汇总（亮屏/解锁）。拿不到就整段不显示——**不许冒充 0**
  /// （对方关闭共享时后端给 closed_off，我们连 0 都不显示，只写「已关闭」）。
  Future<void> _loadStateDaily({bool silent = false}) async {
    try {
      final dio = await ref.read(api.dioProvider.future);
      final daily = await fetchStateDaily(dio);
      if (!mounted) return;
      setState(() => _stateDaily = daily);
    } catch (_) {
      if (!mounted) return;
      setState(() => _stateDaily = null);
    }
  }

  /// 今日事件流：打开拉一次 + SSE peer 静默重拉（沿本页现行刷新通道）。
  Future<void> _loadEvents({bool silent = false}) async {
    if (!silent) setState(() => _dayLoading = true);
    try {
      final dio = await ref.read(api.dioProvider.future);
      final day = await fetchPeerEvents(dio);
      if (!mounted) return;
      setState(() {
        _day = day;
        _dayError = null;
        _dayLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // 失败不清旧值：旧流可留，但横幅会标明「非实时」
      setState(() {
        _dayError = api.errorDetail(e);
        _dayLoading = false;
      });
    }
  }

  /// 一键回应：只在接口真返回后改本地态（**不做本地假成功**）；
  /// 请求期间 [_ackingId] 非空 → 全部按钮禁用（防弱网连点）。
  Future<void> _ack(PeerEventItem item, String emoji) async {
    if (_ackingId != null) return;
    setState(() {
      _ackingId = item.id;
      _ackingEmoji = emoji;
    });
    try {
      final dio = await ref.read(api.dioProvider.future);
      final updated = await ackReport(dio, item.id, emoji);
      if (!mounted) return;
      final ack = updated.ack ?? PeerEventAck(by: '', emoji: emoji);
      setState(() {
        final day = _day;
        if (day == null) return;
        _day = PeerEventsDay(
          date: day.date,
          events: day.events
              .map((e) => e.id == item.id ? e.withAck(ack) : e)
              .toList(growable: false),
          peerClosedOff: day.peerClosedOff,
        );
      });
    } catch (e) {
      if (!mounted) return;
      // 失败：按钮恢复可用（_ackingId 在 finally 清空）+ 顶部通知重试
      ref.read(chatToastProvider.notifier).show(
            api.errorDetail(e),
            tone: ChatToastTone.error,
          );
    } finally {
      if (mounted) {
        setState(() {
          _ackingId = null;
          _ackingEmoji = null;
        });
      }
    }
  }

  /// 我的侧状态：原生 status（running/queue）与 fix6 两项本地状态，读不到给 null。
  Future<void> _loadMine() async {
    final status = await peerVerifyStatus();
    final expected = await peerExpectedOn();
    final battery = await peerBatteryIgnored();
    if (!mounted) return;
    setState(() {
      _running = status['running'] == true;
      final q = status['queue'];
      _queue = q is int ? q : (q is num ? q.toInt() : null);
      _expectedOn = expected;
      _batteryIgnored = battery;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    // 页内订阅既有 SSE 第 7 段 peer：到达即静默重拉（不弹提示）
    ref.listen(sseEventsProvider, (prev, next) {
      if (next.value?.peer == true) _load(silent: true);
    });

    final d = _data;
    return Scaffold(
      appBar: AppBar(title: const Text('报备信息')),
      body: RefreshIndicator(
        onRefresh: () => _load(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, Spacing.pageBottom),
          children: [
            Text('TA 最近报备的位置与电量，都在这里。',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
            const SizedBox(height: 12),
            // 失败横幅只在「有旧值可灰显」时出现（无旧值走下方全屏错误态，
            // 避免出现两个「重试」）
            if (_error != null && d != null) _errorBanner(cs, theme, d),
            if (_loading && d == null)
              const AppProgress()
            else if (d == null)
              // 无旧值：全屏错误态（文案统一「状态未知：<原文>」+ 重试）
              AppErrorView(
                detail: '状态未知：${_error ?? api.genericErrorText}',
                onRetry: _load,
              )
            else ...[
              // 对方状态卡（顶部）：取不到的项整行不出现，一行都没有则整卡不出现
              ..._statusSection(theme, cs, d),
              _sectionTitle(theme, 'TA 的报备'),
              const SizedBox(height: Spacing.gap),
              _peerBlock(theme, cs, d),
              const SizedBox(height: 16),
              _sectionTitle(theme, '我的报备'),
              const SizedBox(height: Spacing.gap),
              _mineBlock(theme, cs, d),
              const SizedBox(height: 16),
              ..._eventsSection(theme, cs),
            ],
          ],
        ),
      ),
    );
  }

  /// 失败横幅：状态未知 + 重试；有旧值时标注旧值时间（不许冒充实时）。
  Widget _errorBanner(ColorScheme cs, ThemeData theme, PeerReport? d) {
    final stale = d?.status.peer?.updated;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: cs.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: cs.error.withValues(alpha: 0.5)),
      ),
      child: Row(children: [
        Expanded(
          child: Text(
            stale == null
                ? '状态未知：${_error ?? api.genericErrorText}'
                : '状态未知：${_error ?? api.genericErrorText}\n'
                    '以下为 ${absoluteTimeZh(stale)} 的数据（非实时）',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
          ),
        ),
        TextButton(
          onPressed: () => _load(),
          child: const Text('重试'),
        ),
      ]),
    );
  }

  Widget _sectionTitle(ThemeData theme, String text) => Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700, // 段 C 口径：w700 上限，不用 w800
        ),
      );

  /// 对方状态卡（报备页顶部）：电量/充电、网络、最后活跃、今日使用。
  ///
  /// 口径全在 [buildPeerStatusCard] 里（纯函数，已单测）：这里只排版，
  /// **不做任何兜底计算**——取不到就整行没有，一行都没有就整卡没有。
  List<Widget> _statusSection(ThemeData theme, ColorScheme cs, PeerReport d) {
    final card = buildPeerStatusCard(peer: d.status.peer, daily: _stateDaily);
    if (card == null) return const <Widget>[];
    return [
      _sectionTitle(theme, 'TA 的状态'),
      const SizedBox(height: Spacing.gap),
      _card(
        cs,
        key: const Key('peer-status-card'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final r in card.rows)
            _kv(
              theme,
              cs,
              r.label,
              r.value,
              key: Key('peer-card-${r.id}'),
              // 「长时间无更新」用警示色：只是颜色，文案本身已写明
              warn: r.warn,
            ),
        ]),
      ),
      const SizedBox(height: 16),
    ];
  }

  Widget _peerBlock(ThemeData theme, ColorScheme cs, PeerReport d) {
    final p = d.status.peer;
    final closedOff = d.status.peerClosedOff;
    return _card(
      cs,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (closedOff)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text('TA 已关闭位置共享（以下为最后一次报备）',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.error)),
          ),
        if (p == null)
          const AppEmptyView(
            icon: Icons.person_off_outlined,
            title: 'TA 还没有报备数据',
            hint: '开通位置共享后这里会显示 TA 的最新报备',
            padding: EdgeInsets.symmetric(vertical: 24),
          )
        else ...[
          // 电量/充电、网络、状态新鲜度、今日亮屏已上移到顶部「TA 的状态」卡，
          // 本块只管「报备」本身：时间、位置、距离、点数（不再重复同一批数字）
          _kv(theme, cs, '最近报备', _timeLine(p.updated)),
          _kv(theme, cs, '位置（GCJ-02）', coordText(p)),
          // 距离行：任一方无坐标则整行不渲染（不显示 0 / 不估算）
          if (distanceLine(d.status.mine, p) case final line?)
            _kv(theme, cs, '距离', line),
          // 今日报备点数：接口给不出（track 关闭/失败）则整行不显示
          if (d.peerTodayPoints case final n?)
            _kv(theme, cs, '今日报备', '$n 点'),
        ],
      ]),
    );
  }

  /// 状态采集三态：采集中 / 因「报备共享」关闭而暂停 / 采集未运行。
  ///
  /// 判定顺序：开关关 > 采集停 > 正常。开关关是最强原因——用户关的是
  /// 「共享」，采集必须跟着停（服务端 422 是第二道保险）。
  String _stateCollectionText() {
    final d = _data;
    if (d == null) return '未知';
    if (!d.status.mineEventsOn) return '已暂停 · 你关闭了「报备共享」';
    if (!_running) return '已暂停 · 采集未运行';
    return '采集中';
  }

  Widget _mineBlock(ThemeData theme, ColorScheme cs, PeerReport d) {
    final mine = d.status.mine;
    return _card(
      cs,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _kv(theme, cs, '采集实态', _running ? '运行中' : '已停止'),
        // 2.8.7：状态采集三态（不许黑箱运行）
        _kv(theme, cs, '状态采集', _stateCollectionText()),
        _kv(theme, cs, '期望态', _expectedOn ? '期望开启' : '未开启'),
        _kv(theme, cs, '最近一次上报', _timeLine(mine?.updated)),
        _kv(theme, cs, '待上报队列', _queue == null ? '未知' : '$_queue 条'),
        _kv(
          theme,
          cs,
          '电池优化',
          _batteryIgnored == null
              ? '未知（通道未注册）'
              : (_batteryIgnored! ? '已豁免' : '未豁免'),
        ),
      ]),
    );
  }

  /// 今日时间线：状态变化与报备按时间排成一条竖线。
  ///
  /// 条目形态**沿用既有两种**（手填报备=卡片+回应区，自动/状态=简行），
  /// 不发明新组件；本方法只加一条竖线与圆点，把两者串成一条线。
  List<Widget> _eventsSection(ThemeData theme, ColorScheme cs) {
    final day = _day;
    final out = <Widget>[
      _sectionTitle(theme, '今日时间线'),
      const SizedBox(height: Spacing.gap),
    ];
    if (day == null) {
      if (_dayLoading) {
        out.add(const AppProgress());
        return out;
      }
      out.add(_card(
        cs,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            '事件流拉不到：${_dayError ?? api.genericErrorText}',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
          ),
          const SizedBox(height: Spacing.gap),
          TextButton(
            key: const Key('report-events-retry'),
            onPressed: () => _loadEvents(),
            child: const Text('重试'),
          ),
        ]),
      ));
      return out;
    }
    // 对方关闭共享：整节明示（对等口径），但仍列出我自己的报备
    if (day.peerClosedOff) {
      out.add(_card(
        cs,
        child: Text(
          'TA 已关闭报备共享',
          key: const Key('report-events-closed'),
          style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
        ),
      ));
      if (day.events.isNotEmpty) out.add(const SizedBox(height: Spacing.gap));
    }
    if (day.events.isEmpty) {
      out.add(_card(
        cs,
        child: AppEmptyView(
          icon: Icons.forum_outlined,
          title: '今天还没有报备',
          hint: '在首页点一下快捷报备，TA 就能看到',
          padding: const EdgeInsets.symmetric(vertical: 20),
        ),
      ));
      return out;
    }
    out.add(_timeline(theme, cs, day.events));
    return out;
  }

  /// 竖线 + 圆点。线用 Stack 的 Positioned 一次性铺满整列（不用
  /// IntrinsicHeight 逐条测量，长列表也不掉帧）。
  Widget _timeline(
    ThemeData theme,
    ColorScheme cs,
    List<PeerEventItem> events,
  ) {
    // 排序的权威在 `sortEventsForTimeline`（fetch 时已排）；这里只渲染，
    // 不再二次排序，避免两处口径漂移。
    return Stack(children: [
      Positioned(
        left: 7,
        top: 12,
        bottom: 12,
        child: Container(width: 1, color: cs.outlineVariant),
      ),
      Column(children: [
        for (final e in events)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.gap),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 15,
                  child: Padding(
                    // 圆点对齐各自形态的标题行：卡片有 16 内边距，简行只有 2
                    padding: EdgeInsets.only(top: e.isManualReport ? 22 : 6),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: e.isManualReport
                              ? cs.primary
                              : cs.outlineVariant,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(child: _eventCard(theme, cs, e)),
              ],
            ),
          ),
      ]),
    ]);
  }

  Widget _eventCard(ThemeData theme, ColorScheme cs, PeerEventItem e) {
    if (!e.isManualReport) {
      // 自动事件：简行（时间 + 摘要），无回应按钮。
      // 文案优先用服务器现成中文；空则按 payload/类型兜底，绝不出空行。
      final line = timelineEventText(e);
      return Padding(
        key: Key('report-event-${e.id}'),
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Row(children: [
          Expanded(
            child: Text(
              line,
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            relativeTimeZh(e.ts),
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
          ),
        ]),
      );
    }
    final extra = <Widget>[
      if (e.note.isNotEmpty)
        Text(e.note, style: theme.textTheme.bodyMedium),
      if (e.placeName.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(children: [
            Icon(Icons.place_outlined, size: 13, color: cs.outline),
            const SizedBox(width: 3),
            Expanded(
              child: Text(
                e.placeName,
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
        ),
    ];
    return Container(
      key: Key('report-event-${e.id}'),
      width: double.infinity,
      padding: const EdgeInsets.all(Spacing.cardPad),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(e.mine ? '我' : 'TA',
              style: theme.textTheme.labelSmall?.copyWith(color: cs.outline)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              timelineEventText(e),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            relativeTimeZh(e.ts),
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
          ),
        ]),
        if (extra.isNotEmpty) ...[
          const SizedBox(height: 6),
          ...extra,
        ],
        const SizedBox(height: Spacing.gap),
        _ackArea(theme, cs, e),
      ]),
    );
  }

  /// 回应区：
  /// · 对方未 ack → 三个按钮；点击后整区禁用/loading 直到接口返回；
  /// · 对方已 ack → 「已回应 {emoji}」，不再给按钮；
  /// · 我的报备 → 「对方已收到」**只与 ack 绑定**（后端没有独立已读字段，
  ///   不许用其它信号伪造已收到）。
  Widget _ackArea(ThemeData theme, ColorScheme cs, PeerEventItem e) {
    final ack = e.ack;
    if (e.mine) {
      return Text(
        ack == null ? '等待对方回应' : '对方已收到 ${ack.emoji}',
        key: Key('report-ack-state-${e.id}'),
        style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
      );
    }
    if (ack != null) {
      return Text(
        '已回应 ${ack.emoji}',
        key: Key('report-ack-state-${e.id}'),
        style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
      );
    }
    final busy = _ackingId == e.id;
    return Row(
      key: Key('report-ack-buttons-${e.id}'),
      children: [
        for (final emoji in _ackEmojis)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: OutlinedButton(
              key: Key('report-ack-${e.id}-$emoji'),
              // 任一回应进行中 → 全部按钮禁用（防弱网连点重复推送）
              onPressed: _ackingId == null ? () => _ack(e, emoji) : null,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(48, 32),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: busy && _ackingEmoji == emoji
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(emoji, style: const TextStyle(fontSize: 15)),
            ),
          ),
      ],
    );
  }

  Widget _card(ColorScheme cs, {required Widget child, Key? key}) => Container(
        key: key,
        width: double.infinity,
        padding: const EdgeInsets.all(Spacing.cardPad),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: child,
      );

  /// 时间行：相对 + 绝对并列；无时间戳给「未知」（不拼出「未知 · 未知」）。
  String _timeLine(double? updated) => updated == null || updated <= 0
      ? '未知'
      : '${relativeTimeZh(updated)} · ${absoluteTimeZh(updated)}';

  Widget _kv(
    ThemeData theme,
    ColorScheme cs,
    String label,
    String value, {
    Key? key,
    bool warn = false,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          key: key,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: Text(label,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.outline)),
            ),
            Expanded(
              child: Text(
                value,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: warn ? cs.error : null,
                ),
              ),
            ),
          ],
        ),
      );
}
