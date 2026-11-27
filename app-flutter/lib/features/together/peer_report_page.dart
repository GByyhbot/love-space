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
/// 明确不做：商业地图 SDK（示意画布自绘）、语音贴、调用外部逆地理。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/peer/peer_locator.dart';
import '../../core/peer/peer_permissions.dart';
import '../../core/peer/peer_report_api.dart';
import '../../core/peer/peer_report_data.dart';
import '../../core/peer/peer_state_collector.dart' show pullUsageSamples;
import '../../core/peer/peer_status_card.dart';
import '../../core/peer/peer_track_data.dart';
import '../../core/peer/peer_usage_data.dart';
import '../../core/peer/state_event_text.dart';
import '../../core/sse/sse_client.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/tokens.dart';
import '../../core/theme/typography.dart';
import '../../core/ui/apple_ui.dart';
import '../../core/ui/empty_view.dart';
import '../../core/ui/error_view.dart';
import '../../core/ui/liquid_glass.dart';
import '../../core/ui/pressable_scale.dart';
import '../../core/ui/progress.dart';
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'peer_poke_sheet.dart';

class PeerReportPage extends ConsumerStatefulWidget {
  const PeerReportPage({
    super.key,
    this.embedded = false,
    this.onSwitchTab,
  });

  /// 嵌入 [PeerHubPage] 四页签壳时置 true（隐藏内层 AppBar 与重复 FAB）。
  final bool embedded;

  /// 在四页签壳内直接切页签（0=今日 1=轨迹 2=手机 3=设置）。
  final ValueChanged<int>? onSwitchTab;

  @override
  ConsumerState<PeerReportPage> createState() => _PeerReportPageState();
}

class _PeerReportPageState extends ConsumerState<PeerReportPage>
    with WidgetsBindingObserver {
  PeerReport? _data;
  bool _loading = false;
  String? _error;

  /// 我的侧实态（原生单一事实源）+ 期望态 + 电池豁免 + 权限快照。
  bool _running = false;
  int? _queue;
  bool _expectedOn = false;
  bool? _batteryIgnored;
  PeerPermissionSnapshot? _perms;

  /// 今日设备状态汇总（2.8.7；`GET /api/peer/state-daily` 当日）。
  PeerStateDaily? _stateDaily;

  /// 今日使用汇总（手机使用卡；`GET /api/peer/usage-daily` 当日）。
  PeerUsageDay? _usage;

  /// 今日轨迹（足迹卡与停留点；`GET /api/peer/track` 当日）。
  PeerTrackDay? _track;

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
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(_load);
    Future.microtask(_checkPermissionsOnOpen);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_loadPermissions());
      unawaited(pullUsageSamples());
      unawaited(_loadMine());
      unawaited(_load(silent: true));
    }
  }

  Future<void> _loadPermissions() async {
    final p = await peerPermissionStatus();
    if (!mounted) return;
    setState(() => _perms = p);
  }

  Future<void> _checkPermissionsOnOpen() async {
    final p = await peerPermissionStatus();
    if (!mounted) return;
    setState(() => _perms = p);
    if (!await shouldShowProactivePermissionPrompt(p) || !mounted) return;
    await markProactivePermissionPromptShown();
    if (!mounted) return;
    await _showMissingPermSheet(p);
  }

  Future<void> _showMissingPermSheet(PeerPermissionSnapshot p) async {
    final missing = <String>[
      if (!p.fine) '精确定位（实时位置与附近地点）',
      if (!p.background) '后台位置（熄屏与切后台持续报备）',
      if (!p.usage) '应用使用情况访问（手机使用与亮屏统计）',
      if (!p.notification) '系统通知（消息与低电量提醒）',
      if (!p.batteryIgnored) '忽略电池优化（避免后台被系统冻结）',
    ];
    if (missing.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final cs = theme.colorScheme;
        return SafeArea(
          child: Padding(
            key: const Key('peer-perm-prompt-sheet'),
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '开启完整报备能力',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  '检测到以下系统权限尚未开启，可能导致对方看不到你的位置或手机使用时长：',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
                ),
                const SizedBox(height: 10),
                for (final item in missing)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      Icon(Icons.circle, size: 6, color: cs.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(item, style: theme.textTheme.bodySmall),
                      ),
                    ]),
                  ),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('peer-perm-prompt-later'),
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('稍后再说'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const Key('peer-perm-prompt-go'),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        context.push('/settings/peer-share');
                      },
                      child: const Text('去补齐'),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        );
      },
    );
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
    await _loadUsage();
    await _loadTrack();
  }

  /// 今日使用汇总：拿不到就整块不显示（不拿旧值冒充今日）。
  Future<void> _loadUsage() async {
    try {
      final dio = await ref.read(api.dioProvider.future);
      final usage = await fetchPeerUsageDaily(dio);
      if (!mounted) return;
      setState(() => _usage = usage);
    } catch (_) {
      if (!mounted) return;
      setState(() => _usage = null);
    }
  }

  /// 今日轨迹（足迹卡与「已停留」的来源）：失败只影响这两块，不影响整页。
  Future<void> _loadTrack() async {
    try {
      final dio = await ref.read(api.dioProvider.future);
      final track = await fetchPeerTrack(dio);
      if (!mounted) return;
      setState(() => _track = track);
    } catch (_) {
      if (!mounted) return;
      setState(() => _track = null);
    }
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
    final topInset = widget.embedded ? ShellChromeScope.topInsetOf(context) : 0.0;
    final body = RefreshIndicator(
        onRefresh: () => _load(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            16,
            topInset + 12,
            16,
            widget.embedded ? Spacing.pageBottom + 64 : Spacing.pageBottom + 16,
          ),
          children: [
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
              // 照原型自上而下：状态大卡 → 手机使用 → 今日足迹 → 动态流 → 我方
              ..._statusSection(theme, cs, d),
              ..._usageSection(theme, cs, d),
              ..._footprintSection(theme, cs, d),
              ..._eventsSection(theme, cs),
              _sectionTitle(theme, '我的报备'),
              const SizedBox(height: Spacing.gap),
              _mineBlock(theme, cs, d),
            ],
          ],
        ),
      );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('报备信息')),
      // 互动抽屉入口（独立页模式保留原 FAB，嵌入四页签壳时由 PeerHubPage 统一承载）
      floatingActionButton: PressableScale(
        onTap: () => showPeerPokeSheet(context, ref),
        child: LiquidGlassSurface(
          key: const Key('report-poke-fab'),
          borderRadius: BorderRadius.circular(999),
          tint: cs.primaryContainer.withValues(alpha: 0.86),
          child: Material(
            type: MaterialType.transparency,
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => showPeerPokeSheet(context, ref),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.favorite_outline,
                        size: 18, color: cs.onPrimaryContainer),
                    const SizedBox(width: 8),
                    Text(
                      '想 TA 一下',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: cs.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      body: body,
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
          letterSpacing: -0.2,
        ),
      );

  /// 对方状态大卡（报备页顶部，照原型）：头像+名字 / 实时状态 / 右侧电量圆环 /
  /// 位置与停留 / 同心状态芯片（电量 / 网络 / 最后活跃 / 今日使用）。
  ///
  /// 铁律不变：取不到的项整行不出现，一行都没有则整卡不出现；停用（全局关闭/
  /// 暂停中）时整卡换原型形态「已完全关闭报备 / 已暂停至 x」。
  List<Widget> _statusSection(ThemeData theme, ColorScheme cs, PeerReport d) {
    final st = d.status;
    final halt = st.peerHalt;
    final name = _partnerName();
    if (halt.halted) {
      return [
        _sectionTitle(theme, 'TA 的状态'),
        const SizedBox(height: Spacing.gap),
        _card(
          cs,
          key: const Key('peer-status-card'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              _peerAvatar(cs, name),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    LiveStatusPill(
                      label: halt.isPaused ? '已暂停报备' : '已关闭报备',
                      tone: LivePillTone.warn,
                    ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: cs.errorContainer.withValues(alpha: 0.32),
                borderRadius: BorderRadius.circular(kGlassInnerRadius),
                border: Border.all(color: cs.error.withValues(alpha: 0.35)),
              ),
              child: Text(
                halt.isPaused
                    ? '已暂停至 ${absoluteTimeZh(halt.until)}'
                    : '已完全关闭报备 · 对方不可见',
                key: const Key('peer-halted-line'),
                style: theme.textTheme.bodyMedium?.copyWith(color: cs.error),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 16),
      ];
    }

    final card = buildPeerStatusCard(peer: st.peer, daily: _stateDaily);
    final live = _peerLiveLine(st);
    final locationLine = _peerLocationLine(st);
    // 对方从无任何上报：给一句空态（不当故障、不摆空壳卡）
    if (card == null && live.isEmpty && locationLine == null) {
      if (st.peer == null) {
        return [
          _sectionTitle(theme, 'TA 的状态'),
          const SizedBox(height: Spacing.gap),
          _card(
            cs,
            child: const AppEmptyView(
              icon: Icons.person_off_outlined,
              title: 'TA 还没有报备数据',
              hint: '开通位置共享后这里会显示 TA 的最新报备',
              padding: EdgeInsets.symmetric(vertical: 24),
            ),
          ),
          const SizedBox(height: 14),
        ];
      }
      return const <Widget>[];
    }
    final battery = st.peer?.battery;
    final lowBattery =
        battery != null && battery <= 20 && st.peer?.charging != true;
    final metaRows = card?.rows
            .where((r) => r.id != 'battery' && r.id != 'usage')
            .toList(growable: false) ??
        const <PeerStatusRow>[];
    return [
      _sectionTitle(theme, 'TA 的状态'),
      const SizedBox(height: 8),
      _card(
        cs,
        key: const Key('peer-status-card'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _peerAvatar(cs, name),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (live.isNotEmpty)
                          LiveStatusPill(
                            key: const Key('peer-live-line'),
                            label: live,
                            ellipsis: false,
                            tone: st.peerCurrentApp != null
                                ? LivePillTone.active
                                : (card?.stale == true
                                    ? LivePillTone.warn
                                    : LivePillTone.idle),
                          ),
                      ],
                    ),
                    if (locationLine != null) ...[
                      const SizedBox(height: 4),
                      Row(children: [
                        Icon(Icons.place_outlined,
                            size: 14, color: cs.outline),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            locationLine,
                            key: const Key('peer-stay-line'),
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ]),
                    ],
                  ],
                ),
              ),
              if (battery != null) ...[
                const SizedBox(width: 10),
                BatteryRing(
                  key: const Key('peer-card-battery'),
                  battery: battery,
                  charging: st.peer?.charging,
                ),
              ],
            ],
          ),
          // 距离（任一方无坐标就不显示——不显示 0、不估算）
          if (distanceLine(st.mine, st.peer) case final dist?)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                dist,
                key: const Key('peer-distance'),
                style: tabularStyle(
                  theme.textTheme.bodySmall?.copyWith(color: cs.outline),
                ),
              ),
            ),
          if (metaRows.isNotEmpty) ...[
            const SizedBox(height: 10),
            LayoutBuilder(builder: (ctx, box) {
              return Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final r in metaRows)
                    _statusMetaChip(
                      theme,
                      cs,
                      r,
                      maxWidth: box.maxWidth,
                      peerNet: st.peer?.net,
                      lowBattery: r.id == 'battery' && lowBattery,
                    ),
                ],
              );
            }),
          ],
          if (st.peerClosedOff)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('TA 已关闭位置共享（以下为最后一次报备）',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.error)),
            ),
        ]),
      ),
      const SizedBox(height: 14),
    ];
  }

  Widget _statusMetaChip(
    ThemeData theme,
    ColorScheme cs,
    PeerStatusRow r, {
    required double maxWidth,
    String? peerNet,
    bool lowBattery = false,
  }) {
    final warn = r.warn || lowBattery;
    final icon = switch (r.id) {
      'battery' =>
        lowBattery ? Icons.battery_alert_rounded : Icons.battery_std_rounded,
      'net' => networkIconFor(peerNet),
      'active' => Icons.schedule_rounded,
      'usage' => Icons.smartphone_rounded,
      _ => Icons.info_outline_rounded,
    };
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        key: Key('peer-card-${r.id}'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: warn
              ? cs.errorContainer.withValues(alpha: 0.42)
              : cs.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(kGlassInnerRadius),
          border: Border.all(
            color: warn
                ? cs.error.withValues(alpha: 0.45)
                : cs.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: warn ? cs.error : cs.primary),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                r.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tabularStyle(
                  theme.textTheme.labelMedium?.copyWith(
                    color: warn ? cs.error : cs.onSurface,
                    fontWeight: warn ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 对方名字（未绑定时给「TA」——不编名字）。
  String _partnerName() {
    final me = ref.watch(authProvider.notifier).me;
    if (me == null) return 'TA';
    for (final u in me.users) {
      if (u.id != me.user.id) return u.name;
    }
    return 'TA';
  }

  Widget _peerAvatar(ColorScheme cs, String name) => CircleAvatar(
        radius: 22,
        backgroundColor: cs.primaryContainer,
        child: Text(
          name.isEmpty ? 'TA' : name.characters.first,
          style: TextStyle(
            color: cs.onPrimaryContainer,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
      );

  /// 实时状态行：`正在使用 X` 优先，其次「N 分钟前活跃」；都取不到给空串。
  String _peerLiveLine(PeerStatusData st) {
    final app = st.peerCurrentApp;
    if (app != null) return '正在使用 ${app.app}';
    final p = st.peer;
    if (p == null) return '';
    final ts = [p.updated, p.stateUpdated]
        .whereType<double>()
        .where((v) => v > 0)
        .fold<double?>(null, (a, b) => a == null || b > a ? b : a);
    if (ts == null) return '';
    return '${relativeTimeZh(ts)}活跃';
  }

  /// 位置与停留：当日最后一个停留点（含「已停留」）；无停留点 → null。
  String? _peerStayLine() {
    final stays = _track?.peer.stays ?? const <PeerTrackStay>[];
    if (stays.isEmpty) return null;
    final s = stays.last;
    final dur = durationTextZh(s.durationSec);
    return s.ongoing ? '${s.displayName} · 已停留 $dur' : '${s.displayName} · 停留 $dur';
  }

  /// 地点文案优先级：① peer_places 停留点名；② 原生 Geocoder `place_name`；③「位置已更新 · 相对时间」。
  /// 绝不把裸经纬度坐标展示给用户。
  String? _peerLocationLine(PeerStatusData st) {
    final stayLine = _peerStayLine();
    if (stayLine != null) return stayLine;
    final p = st.peer;
    if (p == null) return null;
    if (p.placeName.isNotEmpty) return p.placeName;
    if (p.updated != null && p.updated! > 0) {
      return '位置已更新 · ${relativeTimeZh(p.updated!)}';
    }
    return '位置已更新';
  }

  /// 手机使用卡：三列横向概览大数字 + 当前正在使用胶囊；点进手机页。
  ///
  /// 分档降级：screen_only 只有两个数；app off 只是少当前应用行；usage off / 停用
  /// 整卡换关闭态（点进去看明细）。
  List<Widget> _usageSection(ThemeData theme, ColorScheme cs, PeerReport d) {
    final usage = _usage?.peer;
    final halt = d.status.peerHalt;
    final hidden = usage == null || usage.hidden;
    final hasScreen = usage?.screenSec != null && usage!.screenSec! > 0;
    final hasUnlocks = usage?.unlocks != null && usage!.unlocks! > 0;
    final hasLongest =
        usage?.longestSessionSec != null && usage!.longestSessionSec! > 0;
    final hasAnyUsage = hasScreen || hasUnlocks || hasLongest;
    final delta = usage == null
        ? null
        : usageDeltaText(usage.screenSec, usage.yesterdayScreenSec);
    return [
      _sectionTitle(theme, '手机使用'),
      const SizedBox(height: Spacing.gap),
      _tappableCard(
        cs,
        key: const Key('peer-usage-card'),
        onTap: () {
          if (widget.onSwitchTab != null) {
            widget.onSwitchTab!(2);
          } else {
            context.push('/together/peer-report/phone');
          }
        },
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(
              '手机使用速览',
              style: theme.textTheme.labelMedium?.copyWith(color: cs.outline),
            ),
            const Spacer(),
            Text(
              '查看时间流 ›',
              style: theme.textTheme.labelMedium?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ]),
          const SizedBox(height: 10),
          if (halt.halted)
            _hintLine(theme, cs, halt.isPaused ? 'TA 已暂停报备，看不到使用情况' : 'TA 已完全关闭报备')
          else if (hidden)
            _hintLine(theme, cs, 'TA 未共享手机使用情况')
          else ...[
            Row(children: [
              Expanded(
                child: _bigStat(
                  theme,
                  cs,
                  label: '今日亮屏',
                  value: !hasScreen ? '—' : durationTextZh(usage.screenSec!),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _bigStat(
                  theme,
                  cs,
                  label: '解锁',
                  value: !hasUnlocks ? '—' : '${usage.unlocks} 次',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _bigStat(
                  theme,
                  cs,
                  label: '最长连续',
                  value: !hasLongest
                      ? '—'
                      : durationTextZh(usage.longestSessionSec!),
                ),
              ),
            ]),
            if (!hasAnyUsage) ...[
              const SizedBox(height: 8),
              _hintLine(theme, cs, '对方今天还没有使用数据'),
            ],
            if (delta != null) ...[
              const SizedBox(height: 8),
              Text(
                delta,
                key: const Key('peer-usage-delta'),
                style: tabularStyle(
                  theme.textTheme.bodySmall?.copyWith(color: cs.outline),
                ),
              ),
            ],
            if (usage.currentApp != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: cs.primaryContainer.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(kGlassInnerRadius),
                ),
                child: Row(children: [
                  Icon(AppIcons.phone,
                      size: 15, color: cs.onPrimaryContainer),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      '正在使用 ${usage.currentApp!.app} · ${durationTextZh(((DateTime.now().millisecondsSinceEpoch / 1000) - (usage.currentApp!.since ?? 0)).round())}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.numeric(
                        theme,
                        base: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Text(
                    '详情 ›',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ]),
              ),
            ],
          ],
        ]),
      ),
      const SizedBox(height: 14),
    ];
  }

  /// 今日足迹卡：有轨迹点/停留点时左侧显示迷你轨迹图；空态隐藏缩略图、左对齐文案。
  List<Widget> _footprintSection(ThemeData theme, ColorScheme cs, PeerReport d) {
    final track = _track?.peer;
    final halt = d.status.peerHalt;
    final hidden = track == null || track.hidden;
    final hasTrackData =
        track != null && (track.points.isNotEmpty || track.stays.isNotEmpty);
    final names = (track?.stays ?? const <PeerTrackStay>[])
        .map((s) => s.displayName)
        .toList(growable: false);
    final summaryCol = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!hasTrackData)
          _hintLine(
            theme,
            cs,
            track?.isStreet == true
                ? '今天还没有足迹记录（仅街区共享）'
                : '今天还没有足迹记录',
          )
        else if (track.isStreet)
          _hintLine(
            theme,
            cs,
            '仅街区共享 · ${track.stays.length} 个停留点（不提供精确距离）',
          )
        else
          Text(
            '已移动 ${_distanceText(track.distanceM)} · ${track.stays.length} 个停留点',
            key: const Key('peer-footprint-line'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: tabularStyle(
              theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        if (names.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            names.take(5).join(' → '),
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (d.peerTodayPoints != null && d.peerTodayPoints! > 0) ...[
          const SizedBox(height: Spacing.xs),
          Text(
            '今日报备 ${d.peerTodayPoints} 点',
            style: tabularStyle(
              theme.textTheme.labelSmall?.copyWith(color: cs.outline),
            ),
          ),
        ],
        if (hasTrackData) ...[
          const SizedBox(height: Spacing.xs),
          Text(
            '打开轨迹地图 ›',
            style: theme.textTheme.labelSmall?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
    return [
      _sectionTitle(theme, '今日足迹'),
      const SizedBox(height: Spacing.gap),
      _tappableCard(
        cs,
        key: const Key('peer-footprint-card'),
        onTap: () {
          if (widget.onSwitchTab != null) {
            widget.onSwitchTab!(1);
          } else {
            context.push('/together/peer-report/track');
          }
        },
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(
              '今日足迹',
              style: theme.textTheme.labelMedium?.copyWith(color: cs.outline),
            ),
            const Spacer(),
            Text(
              '轨迹回放 ›',
              style: theme.textTheme.labelMedium?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ]),
          const SizedBox(height: 10),
          if (halt.halted)
            _hintLine(theme, cs, halt.isPaused ? 'TA 已暂停报备，看不到足迹' : 'TA 已完全关闭报备')
          else if (hidden)
            _hintLine(theme, cs, 'TA 未共享位置与足迹')
          else if (!hasTrackData)
            summaryCol
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _MiniTrackThumbnail(
                  key: const Key('peer-footprint-thumb'),
                  track: track,
                  pathColor: cs.primary,
                  stayColor: cs.secondary,
                  bgColor: cs.surfaceContainerHighest.withValues(alpha: 0.45),
                  borderColor: cs.outlineVariant.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 12),
                Expanded(child: summaryCol),
              ],
            ),
        ]),
      ),
      const SizedBox(height: 14),
    ];
  }

  String _distanceText(double? m) {
    if (m == null) return '—';
    if (m < 1000) return '${m.round()} 米';
    return '${(m / 1000).toStringAsFixed(1)} 公里';
  }

  Widget _hintLine(ThemeData theme, ColorScheme cs, String text) => Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(color: cs.outline),
      );

  Widget _bigStat(ThemeData theme, ColorScheme cs,
          {required String label, required String value}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: tabularStyle(
              theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(color: cs.outline),
        ),
      ]);

  Widget _tappableCard(
    ColorScheme cs, {
    required Widget child,
    VoidCallback? onTap,
    Key? key,
  }) =>
      LiquidGlassCard(
        key: key,
        onTap: onTap,
        child: child,
      );

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
    final myUsage = _usage?.mine;
    return _card(
      cs,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: cs.secondaryContainer,
            child: Text(
              '我',
              style: TextStyle(
                color: cs.onSecondaryContainer,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              d.status.myPolicy.isHalted
                  ? (d.status.myPolicy.globalOff ? '已完全关闭报备' : '已暂停报备')
                  : '我的报备运行中',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          TextButton(
            key: const Key('report-mine-preview'),
            onPressed: () => context.push('/settings/peer-share/preview'),
            child: const Text('对方视角预览'),
          ),
        ]),
        const SizedBox(height: Spacing.sm),
        Container(
          key: const Key('report-mine-preview-grid'),
          padding: const EdgeInsets.all(Spacing.sm),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.36),
            borderRadius: BorderRadius.circular(AppRadius.small),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.45),
            ),
          ),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('位置共享', style: AppType.caption(theme)),
                  const SizedBox(height: 2),
                  Text(
                    d.status.myPolicy.locLevel.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('网络显示', style: AppType.caption(theme)),
                  const SizedBox(height: 2),
                  Text(
                    d.status.myPolicy.netLevel.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('使用共享', style: AppType.caption(theme)),
                  const SizedBox(height: 2),
                  Text(
                    d.status.myPolicy.usageLevel.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ]),
        ),
        const SizedBox(height: Spacing.sm),
        if (mine?.battery != null)
          _kv(theme, cs, '我的电量', '${mine!.battery}%'),
        if (myUsage?.screenSec != null)
          _kv(theme, cs, '今日亮屏', durationTextZh(myUsage!.screenSec!)),
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
        if (_perms != null &&
            _perms!.channelAvailable &&
            (!_perms!.fine || !_perms!.background)) ...[
          const SizedBox(height: 8),
          Container(
            key: const Key('report-mine-loc-perm-hint'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: cs.errorContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(kGlassInnerRadius),
              border: Border.all(color: cs.error.withValues(alpha: 0.35)),
            ),
            child: Row(children: [
              Icon(AppIcons.locationOff, size: 16, color: cs.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  !_perms!.fine
                      ? '未开启定位权限，对方看不到你的实时位置'
                      : '仅授予「使用期间」定位，息屏/切后台后将无法持续报备',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
                ),
              ),
              TextButton(
                onPressed: () {
                  if (widget.onSwitchTab != null) {
                    widget.onSwitchTab!(3);
                  } else {
                    context.push('/settings/peer-share');
                  }
                },
                child: const Text('去开启'),
              ),
            ]),
          ),
        ],
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
      Row(children: [
        _sectionTitle(theme, '今日时间线'),
        const Spacer(),
        Text('实时更新', style: AppType.caption(theme)),
      ]),
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
          style: tabularStyle(
            theme.textTheme.bodySmall?.copyWith(color: cs.outline),
          ),
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
  return LiquidGlassCard(
    key: Key('report-event-${e.id}'),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: e.mine
                ? cs.primaryContainer.withValues(alpha: 0.65)
                : cs.secondaryContainer.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            e.mine ? '我' : 'TA',
            style: theme.textTheme.labelSmall?.copyWith(
              color: e.mine ? cs.onPrimaryContainer : cs.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
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
          style: tabularStyle(
            theme.textTheme.bodySmall?.copyWith(color: cs.outline),
          ),
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

  Widget _card(ColorScheme cs, {required Widget child, Key? key}) =>
      LiquidGlassCard(key: key, child: child);

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
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: tabularStyle(
                  theme.textTheme.bodyMedium?.copyWith(
                    color: warn ? cs.error : null,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}

/// 今日足迹卡左侧迷你轨迹缩略图（同心圆角 12；无底图自绘）。
class _MiniTrackThumbnail extends StatelessWidget {
  const _MiniTrackThumbnail({
    super.key,
    required this.track,
    required this.pathColor,
    required this.stayColor,
    required this.bgColor,
    required this.borderColor,
  });

  final PeerTrackSide track;
  final Color pathColor;
  final Color stayColor;
  final Color bgColor;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 104,
      height: 68,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(kGlassInnerRadius),
        border: Border.all(color: borderColor),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(kGlassInnerRadius),
        child: (track.points.isEmpty && track.stays.isEmpty)
            ? Center(
                child: Icon(Icons.route_outlined,
                    size: 24, color: pathColor.withValues(alpha: 0.65)),
              )
            : CustomPaint(
                painter: _MiniTrackPainter(
                  track: track,
                  pathColor: pathColor,
                  stayColor: stayColor,
                ),
              ),
      ),
    );
  }
}

class _MiniTrackPainter extends CustomPainter {
  const _MiniTrackPainter({
    required this.track,
    required this.pathColor,
    required this.stayColor,
  });

  final PeerTrackSide track;
  final Color pathColor;
  final Color stayColor;

  @override
  void paint(Canvas canvas, Size size) {
    final lats = <double>[
      for (final p in track.points) p.lat,
      for (final s in track.stays) s.lat,
    ];
    final lngs = <double>[
      for (final p in track.points) p.lng,
      for (final s in track.stays) s.lng,
    ];
    if (lats.isEmpty) return;

    var minLat = lats.first, maxLat = lats.first;
    var minLng = lngs.first, maxLng = lngs.first;
    for (var i = 1; i < lats.length; i++) {
      minLat = math.min(minLat, lats[i]);
      maxLat = math.max(maxLat, lats[i]);
      minLng = math.min(minLng, lngs[i]);
      maxLng = math.max(maxLng, lngs[i]);
    }
    final centerLat = (minLat + maxLat) / 2;
    final cosLat = math.cos(centerLat * math.pi / 180.0).clamp(0.2, 1.0);
    final spanLat = math.max(maxLat - minLat, 1e-4);
    final spanLng = math.max((maxLng - minLng) * cosLat, 1e-4);

    const pad = 10.0;
    final w = math.max(1.0, size.width - pad * 2);
    final h = math.max(1.0, size.height - pad * 2);
    final scale = math.min(w / spanLng, h / spanLat);
    final dxOff = pad + (w - spanLng * scale) / 2;
    final dyOff = pad + (h - spanLat * scale) / 2;

    Offset toPx(double lat, double lng) {
      final x = dxOff + (lng - minLng) * cosLat * scale;
      final y = dyOff + (maxLat - lat) * scale;
      return Offset(x, y);
    }

    if (!track.isStreet && track.points.length >= 2) {
      final path = Path();
      final p0 = toPx(track.points.first.lat, track.points.first.lng);
      path.moveTo(p0.dx, p0.dy);
      for (var i = 1; i < track.points.length; i++) {
        final p = toPx(track.points[i].lat, track.points[i].lng);
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = pathColor
          ..strokeWidth = 2.0
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    for (final s in track.stays) {
      canvas.drawCircle(toPx(s.lat, s.lng), 3.5, Paint()..color = stayColor);
    }
  }

  @override
  bool shouldRepaint(_MiniTrackPainter old) =>
      old.track != track || old.pathColor != pathColor;
}
