/// 2.8.7 全量施工令 · 手机页（照原型：四格统计 + 交互 24h 分布 + 3 子标签：
/// 软件时间流 / 使用排行 Top5 / 网络切换记录）。
///
/// 分档渲染是这一页的重点（服务端已裁，页面按缺字段降级）：
/// · usage off / 停用 → 整页关闭态 + 去设置；
/// · screen_only → 只留统计与分布图（或缺失提示），应用三子标签降级明示；
/// · app off → 统计与分布照常，时间流与排行换明示行；
/// · 自己侧未授权 / 全缺 → 引导卡，不摆假 0。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/peer/peer_permissions.dart';
import '../../core/peer/peer_state_collector.dart'
    show openUsageAccessSettings, pullUsageSamples;
import '../../core/peer/peer_usage_data.dart';
import '../../core/peer/state_event_text.dart'
    show durationTextZh, usageDeltaText;
import '../../core/theme/tokens.dart';
import '../../core/ui/empty_view.dart';
import '../../core/ui/error_view.dart';
import '../../core/ui/liquid_glass.dart';
import '../../core/ui/progress.dart';

class PeerPhonePage extends ConsumerStatefulWidget {
  const PeerPhonePage({super.key});

  @override
  ConsumerState<PeerPhonePage> createState() => _PeerPhonePageState();
}

class _PeerPhonePageState extends ConsumerState<PeerPhonePage>
    with WidgetsBindingObserver {
  PeerUsageDay? _data;
  bool _loading = false;
  String? _error;
  bool _peerView = true;
  PeerPermissionSnapshot? _perms;

  /// 子视图索引：0=软件时间流，1=使用排行 Top5，2=网络切换记录。
  int _subTab = 0;

  /// 24 小时图选中小时（null = 自动挑峰值小时）。
  int? _selectedHour;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(() async {
      await _loadPerms();
      await pullUsageSamples();
      await _load();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(pullUsageSamples());
      unawaited(_loadPerms());
      unawaited(_load());
    }
  }

  Future<void> _loadPerms() async {
    final p = await peerPermissionStatus();
    if (!mounted) return;
    setState(() => _perms = p);
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final dio = await ref.read(api.dioProvider.future);
      final data = await fetchPeerUsageDaily(dio);
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = api.errorDetail(e);
        _loading = false;
      });
    }
  }

  PeerUsageSide get _side =>
      _peerView ? (_data?.peer ?? const PeerUsageSide()) : (_data?.mine ?? const PeerUsageSide());

  bool _allEmpty(PeerUsageSide s) =>
      s.screenSec == null &&
      s.unlocks == null &&
      s.longestSessionSec == null &&
      s.hourly == null &&
      s.sessions == null &&
      s.topApps == null &&
      s.networkEvents == null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final side = _side;
    return Scaffold(
      appBar: AppBar(title: const Text('手机使用')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, Spacing.pageBottom),
          children: [
            _topBar(theme, cs, side),
            const SizedBox(height: 12),
            if (_loading && _data == null)
              const AppProgress()
            else if (_data == null)
              AppErrorView(
                detail: '使用数据拉不到：${_error ?? api.genericErrorText}',
                onRetry: _load,
              )
            else if (side.hidden)
              _closedCard(theme, cs, side)
            else ...[
              if (!_peerView &&
                  _perms?.channelAvailable == true &&
                  _perms?.usage == false) ...[
                _usagePermHintCard(theme, cs),
                const SizedBox(height: 12),
              ],
              if (_allEmpty(side))
                _emptyCard(theme, cs)
              else ...[
                _statsGrid(theme, cs, side),
                const SizedBox(height: 12),
                if (side.hourly != null)
                  _hourlyCard(theme, cs, side)
                else
                  _hintCard(theme, cs, 'TA 只共享亮屏总时长，不共享小时分布'),
                const SizedBox(height: 12),
                _subTabSwitcher(),
                const SizedBox(height: 10),
                _subTabBody(theme, cs, side),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _topBar(ThemeData theme, ColorScheme cs, PeerUsageSide side) {
    final LivePillTone pillTone;
    final String pillLabel;
    if (side.hidden) {
      pillTone = LivePillTone.warn;
      pillLabel = side.halted.isPaused ? '已暂停报备' : '报备已关闭';
    } else if (side.currentApp != null) {
      pillTone = LivePillTone.active;
      pillLabel = '正在使用 ${side.currentApp!.app}';
    } else {
      pillTone = LivePillTone.idle;
      pillLabel = _peerView ? 'TA · 今日统计' : '我 · 今日统计';
    }
    return Row(children: [
      LiquidPillSegmented<bool>(
        key: const Key('phone-side-toggle'),
        selected: _peerView,
        segments: const [
          LiquidPillSegment(value: true, label: 'TA'),
          LiquidPillSegment(value: false, label: '我'),
        ],
        onChanged: (v) => setState(() {
          _peerView = v;
          _selectedHour = null;
        }),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Align(
          alignment: Alignment.centerRight,
          child: LiveStatusPill(label: pillLabel, tone: pillTone),
        ),
      ),
    ]);
  }

  Widget _closedCard(ThemeData theme, ColorScheme cs, PeerUsageSide side) => _card(
        cs,
        key: const Key('phone-closed'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            side.halted.isPaused ? '已暂停报备 · 看不到手机使用' : '手机使用报备已关闭',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            side.halted.isPaused
                ? '暂停期间不采集，恢复后也不补报这段。'
                : '对方关闭手机使用共享时不显示任何使用数据。',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            key: const Key('phone-go-settings'),
            onPressed: () => context.push('/settings/peer-share'),
            child: const Text('去设置'),
          ),
        ]),
      );

  Widget _usagePermHintCard(ThemeData theme, ColorScheme cs) => _card(
        cs,
        key: const Key('phone-usage-perm-hint'),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.privacy_tip_outlined, size: 20, color: cs.error),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '未开启「应用使用情况访问权限」',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: cs.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '开启后才能在本机统计每日亮屏与软件使用时长',
                    style:
                        theme.textTheme.bodySmall?.copyWith(color: cs.outline),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              key: const Key('phone-usage-perm-go'),
              onPressed: openUsageAccessSettings,
              child: const Text('去授权'),
            ),
          ],
        ),
      );

  Widget _emptyCard(ThemeData theme, ColorScheme cs) => _card(
        cs,
        key: const Key('phone-empty'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AppEmptyView(
            icon: Icons.phonelink_lock_outlined,
            title: _peerView ? '今天还没有使用记录' : '本机尚未授权或暂无记录',
            hint: _peerView
                ? '对方开启使用共享并有亮屏后这里会更新'
                : '请在系统设置允许「应用使用情况访问权限」后重试',
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          if (!_peerView)
            Center(
              child: FilledButton.tonal(
                onPressed: () => context.push('/settings/peer-share'),
                child: const Text('去报备设置检查'),
              ),
            ),
        ]),
      );

  Widget _statsGrid(ThemeData theme, ColorScheme cs, PeerUsageSide side) {
    final screenSub = usageDeltaText(side.screenSec, side.yesterdayScreenSec);
    final hasScreen = side.screenSec != null && side.screenSec! > 0;
    final hasUnlocks = side.unlocks != null && side.unlocks! > 0;
    final hasLongest =
        side.longestSessionSec != null && side.longestSessionSec! > 0;
    final unlockSub = (hasUnlocks && hasScreen)
        ? '平均 ${durationTextZh(side.screenSec! ~/ side.unlocks!)}'
        : null;
    final netHead = side.networkEvents?.isNotEmpty == true
        ? _netShortLabel(side.networkEvents!.first)
        : '—';
    final netSub = side.networkEvents?.isNotEmpty == true
        ? _netDetailLabel(side.networkEvents!.first)
        : null;

    return _card(
      cs,
      key: const Key('phone-stats'),
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _statBox(
                    theme,
                    cs,
                    label: '总使用时长',
                    value: !hasScreen ? '—' : durationTextZh(side.screenSec!),
                    sub: screenSub,
                    subWarn: hasScreen &&
                        (side.yesterdayScreenSec ?? 0) > 0 &&
                        side.screenSec! > side.yesterdayScreenSec!,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _statBox(
                    theme,
                    cs,
                    label: '解锁次数',
                    value: !hasUnlocks ? '—' : '${side.unlocks} 次',
                    sub: unlockSub,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _statBox(
                    theme,
                    cs,
                    label: '最长连续',
                    value: !hasLongest
                        ? '—'
                        : durationTextZh(side.longestSessionSec!),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _statBox(
                    theme,
                    cs,
                    label: '当前网络',
                    value: netHead,
                    sub: netSub,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statBox(
    ThemeData theme,
    ColorScheme cs, {
    required String label,
    required String value,
    String? sub,
    bool subWarn = false,
  }) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(kGlassInnerRadius),
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: cs.outline),
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                maxLines: 1,
                style: tabularStyle(
                  theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ),
            if (sub != null) ...[
              const SizedBox(height: 2),
              Text(
                sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tabularStyle(
                  theme.textTheme.labelSmall?.copyWith(
                    color: subWarn ? cs.error : cs.outline,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ],
        ),
      );

  int _defaultSelectedHour(List<int> hourly) {
    var bestNight = -1;
    var bestNightV = 0;
    for (var h = 0; h < 6 && h < hourly.length; h++) {
      if (hourly[h] > bestNightV) {
        bestNightV = hourly[h];
        bestNight = h;
      }
    }
    if (bestNight >= 0) return bestNight;
    var best = 0;
    for (var h = 1; h < hourly.length; h++) {
      if (hourly[h] > hourly[best]) best = h;
    }
    return best;
  }

  Widget _hourlyCard(ThemeData theme, ColorScheme cs, PeerUsageSide side) {
    final hourly = side.hourly!;
    final maxV = hourly.fold<int>(0, (a, b) => b > a ? b : a);
    final sel = (_selectedHour != null && _selectedHour! < hourly.length)
        ? _selectedHour!
        : _defaultSelectedHour(hourly);
    final selVal = hourly.isEmpty ? 0 : hourly[sel];
    final hh = sel.toString().padLeft(2, '0');

    return _card(
      cs,
      key: const Key('phone-hourly'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(
              '24 小时亮屏分布',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            key: const Key('phone-hourly-tip'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: cs.primaryContainer.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$hh:00 · ${selVal ~/ 60} 分钟',
              style: tabularStyle(
                theme.textTheme.labelSmall?.copyWith(
                  color: cs.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        SizedBox(
          height: 92,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var h = 0; h < math.min(24, hourly.length); h++)
                Expanded(
                  child: GestureDetector(
                    key: Key('phone-hour-bar-$h'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _selectedHour = h),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Tooltip(
                        message: '$h 点 · ${hourly[h] ~/ 60} 分钟',
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            height: hourly[h] <= 0 || maxV == 0
                                ? 3
                                : (6 + 80 * hourly[h] / maxV),
                            decoration: BoxDecoration(
                              color: hourly[h] <= 0
                                  ? cs.outlineVariant.withValues(alpha: 0.35)
                                  : (h < 6 ? cs.error : cs.primary).withValues(
                                      alpha: h == sel ? 1.0 : 0.72,
                                    ),
                              borderRadius: BorderRadius.circular(3),
                              border: h == sel
                                  ? Border.all(
                                      color: cs.onSurface.withValues(alpha: 0.45),
                                      width: 1,
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(children: [
          for (final t in const ['00:00', '06:00', '12:00', '18:00', '23:00']) ...[
            if (t != '00:00') const Spacer(),
            Text(
              t,
              style: tabularStyle(
                theme.textTheme.labelSmall
                    ?.copyWith(color: cs.outline, fontSize: 10),
              ),
            ),
          ],
        ]),
        const SizedBox(height: 4),
        Text(
          '点击柱条看各时段分钟数 · 00:00–05:59 为凌晨警示色',
          style: theme.textTheme.labelSmall?.copyWith(color: cs.outline),
        ),
      ]),
    );
  }

  Widget _subTabSwitcher() => LiquidPillSegmented<int>(
        key: const Key('phone-sub-tabs'),
        expand: true,
        selected: _subTab,
        segments: const [
          LiquidPillSegment(
            key: Key('phone-tab-stream'),
            value: 0,
            label: '软件时间流',
          ),
          LiquidPillSegment(
            key: Key('phone-tab-top'),
            value: 1,
            label: '使用排行 Top5',
          ),
          LiquidPillSegment(
            key: Key('phone-tab-net'),
            value: 2,
            label: '网络切换记录',
          ),
        ],
        onChanged: (v) => setState(() => _subTab = v),
      );

  Widget _subTabBody(ThemeData theme, ColorScheme cs, PeerUsageSide side) {
    switch (_subTab) {
      case 0:
        return _sessionsCard(theme, cs, side);
      case 1:
        return _topCard(theme, cs, side);
      default:
        return _networkCard(theme, cs, side);
    }
  }

  Widget _sessionsCard(ThemeData theme, ColorScheme cs, PeerUsageSide side) {
    final sessions = side.sessions;
    return _card(
      cs,
      key: const Key('phone-sessions'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('软件时间流',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const Spacer(),
          if ((side.foldedCount ?? 0) > 0)
            Text(
              '已折叠 ${side.foldedCount} 条 <10s',
              style: tabularStyle(
                theme.textTheme.labelSmall?.copyWith(color: cs.outline),
              ),
            ),
        ]),
        const SizedBox(height: 10),
        if (sessions == null)
          Text(
            side.topApps != null
                ? '对方仅共享 Top5 排行，不展示精确打开时间流'
                : '对方仅共享亮屏数据（不含应用明细）',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
          )
        else if (sessions.isEmpty)
          Text('今天还没有应用使用记录',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline))
        else
          for (var i = 0; i < sessions.length; i++)
            _sessionRow(theme, cs, sessions[i], isLast: i == sessions.length - 1),
      ]),
    );
  }

  Widget _topCard(ThemeData theme, ColorScheme cs, PeerUsageSide side) {
    final top = side.topApps;
    return _card(
      cs,
      key: const Key('phone-top'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('使用排行 Top5',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        if (top == null || top.isEmpty)
          Text('暂无排行（对方未共享应用记录）',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline))
        else
          for (final t in top) _topRow(theme, cs, t, top.first.sec),
      ]),
    );
  }

  Widget _sessionRow(
    ThemeData theme,
    ColorScheme cs,
    PeerUsageSession s, {
    bool isLast = false,
  }) {
    final name = s.masked ? '其他应用（已隐藏）' : s.app;
    final badgeText = s.masked ? '隐' : (name.isEmpty ? '应' : name.characters.first);
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: s.masked
                  ? cs.surfaceContainerHighest
                  : cs.primaryContainer.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.center,
            child: Text(
              badgeText,
              style: theme.textTheme.labelMedium?.copyWith(
                color: s.masked ? cs.outline : cs.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Text(
                  _clock(s.start ?? s.ts),
                  style: tabularStyle(
                    theme.textTheme.labelSmall?.copyWith(color: cs.outline),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            durationTextZh(s.sec),
            style: tabularStyle(
              theme.textTheme.labelMedium?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _topRow(ThemeData theme, ColorScheme cs, PeerTopApp t, int maxSec) {
    final masked = t.app == '其他应用';
    final badgeText = masked ? '隐' : (t.app.isEmpty ? '应' : t.app.characters.first);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: masked
                ? cs.surfaceContainerHighest
                : cs.secondaryContainer.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(9),
          ),
          alignment: Alignment.center,
          child: Text(
            badgeText,
            style: theme.textTheme.labelMedium?.copyWith(
              color: masked ? cs.outline : cs.onSecondaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(t.app,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              Text(
                durationTextZh(t.sec),
                style: tabularStyle(
                  theme.textTheme.labelSmall?.copyWith(color: cs.outline),
                ),
              ),
            ]),
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: maxSec <= 0 ? 0 : (t.sec / maxSec).clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: cs.outlineVariant.withValues(alpha: 0.35),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _networkCard(ThemeData theme, ColorScheme cs, PeerUsageSide side) {
    final list = side.networkEvents ?? const <PeerNetEvent>[];
    return _card(
      cs,
      key: const Key('phone-network'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('网络切换记录',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        if (list.isEmpty)
          Text('今天没有网络切换记录',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline))
        else
          for (var i = 0; i < math.min(20, list.length); i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                color: cs.outlineVariant.withValues(alpha: 0.4),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    networkIconFor(list[i].net),
                    size: 17,
                    color: list[i].net == 'none'
                        ? cs.error
                        : cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _netLabel(list[i]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _clock(list[i].ts),
                  style: tabularStyle(
                    theme.textTheme.labelSmall?.copyWith(color: cs.outline),
                  ),
                ),
              ]),
            ),
          ],
      ]),
    );
  }

  String _netShortLabel(PeerNetEvent e) {
    switch (e.net) {
      case 'wifi':
        return e.ssid.isEmpty ? 'Wi-Fi' : e.ssid;
      case 'cell':
        return '移动数据';
      case 'none':
        return '无网络';
    }
    return e.net.isEmpty ? '未知' : e.net;
  }

  String? _netDetailLabel(PeerNetEvent e) {
    switch (e.net) {
      case 'wifi':
        return e.ssid.isEmpty ? null : 'Wi-Fi';
      case 'cell':
        return '蜂窝网络';
    }
    return null;
  }

  String _netLabel(PeerNetEvent e) {
    switch (e.net) {
      case 'wifi':
        return e.ssid.isEmpty ? 'Wi-Fi' : 'Wi-Fi（${e.ssid}）';
      case 'cell':
        return '移动数据';
      case 'none':
        return '无网络';
    }
    return e.net.isEmpty ? '未知' : e.net;
  }

  Widget _hintCard(ThemeData theme, ColorScheme cs, String text) => _card(
        cs,
        child: Text(text,
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
      );

  Widget _card(
    ColorScheme cs, {
    required Widget child,
    Key? key,
    EdgeInsetsGeometry padding = const EdgeInsets.all(Spacing.cardPad),
  }) =>
      LiquidGlassCard(key: key, padding: padding, child: child);

  String _clock(double? ts) {
    if (ts == null || ts <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}';
  }
}
