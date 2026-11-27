/// 权限中心共用清单与统一引导弹层（首次安装自动引导 + 报备页 24h 冷却引导共用同一套 UI）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/peer/peer_permissions.dart';
import '../../core/peer/peer_state_collector.dart' show openUsageAccessSettings;
import '../../core/theme/tokens.dart';
import '../../core/ui/apple_ui.dart';
import '../../core/ui/liquid_glass.dart';

/// 权限中心清单（用于 [PeerShareSettingsPage] 内嵌卡片与首次安装/主动引导弹层）。
class PeerPermissionChecklist extends StatefulWidget {
  const PeerPermissionChecklist({
    super.key,
    required this.perms,
    required this.onRefresh,
    this.wrapInCard = true,
    this.title = '权限与采集状态',
  });

  final PeerPermissionSnapshot perms;
  final Future<void> Function({bool pullUsage}) onRefresh;
  final bool wrapInCard;
  final String title;

  @override
  State<PeerPermissionChecklist> createState() =>
      _PeerPermissionChecklistState();
}

class _PeerPermissionChecklistState extends State<PeerPermissionChecklist> {
  bool _showAutoStartGuide = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final perms = widget.perms;
    final readyCount = [
      perms.usage,
      perms.fine,
      perms.background,
      perms.notification,
      perms.batteryIgnored,
    ].where((e) => e).length;
    final summaryText =
        perms.channelAvailable ? '$readyCount/5 已就绪' : '原生通道未连接';

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          Text(
            widget.title,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          Text(
            summaryText,
            style: tabularStyle(
              theme.textTheme.labelMedium?.copyWith(
                color: !perms.channelAvailable
                    ? cs.onSurfaceVariant
                    : (perms.allGranted ? cs.primary : cs.error),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ]),
        if (perms.channelAvailable) ...[
          const SizedBox(height: 6),
          _permRow(
            theme,
            cs,
            rowKey: const Key('peer-perm-usage'),
            btnKey: const Key('peer-perm-usage-btn'),
            title: '应用使用情况访问',
            desc: '统计亮屏时长与正在使用的应用',
            granted: perms.usage,
            onGrant: () async {
              await openUsageAccessSettings();
              await widget.onRefresh(pullUsage: true);
            },
          ),
          _permDivider(cs),
          _permRow(
            theme,
            cs,
            rowKey: const Key('peer-perm-fine'),
            btnKey: const Key('peer-perm-fine-btn'),
            title: '精确定位',
            desc: '采集最新位置与 Wi-Fi SSID',
            granted: perms.fine,
            onGrant: () async {
              final ok = await peerRequestLocationPermission(background: false);
              if (!ok) await peerOpenAppSettings();
              await widget.onRefresh(pullUsage: false);
            },
          ),
          _permDivider(cs),
          _permRow(
            theme,
            cs,
            rowKey: const Key('peer-perm-bg'),
            btnKey: const Key('peer-perm-bg-btn'),
            title: '后台始终定位',
            desc: '息屏或切后台后持续更新足迹',
            granted: perms.background,
            grantedLabel:
                perms.background ? '已开启' : (perms.fine ? '仅前台' : '未开启'),
            onGrant: () async {
              final ok = await peerRequestLocationPermission(
                background: perms.fine,
              );
              if (!ok) await peerOpenAppSettings();
              await widget.onRefresh(pullUsage: false);
            },
          ),
          _permDivider(cs),
          _permRow(
            theme,
            cs,
            rowKey: const Key('peer-perm-notify'),
            btnKey: const Key('peer-perm-notify-btn'),
            title: '系统通知',
            desc: '保证前台保活常驻通知与重要提醒送达',
            granted: perms.notification,
            onGrant: () async {
              await peerRequestNotificationPermission();
              await widget.onRefresh(pullUsage: false);
            },
          ),
          _permDivider(cs),
          _permRow(
            theme,
            cs,
            rowKey: const Key('peer-perm-battery'),
            btnKey: const Key('peer-perm-battery-btn'),
            title: '忽略电池优化',
            desc: '避免系统 Doze 限制定时心跳与使用采样',
            granted: perms.batteryIgnored,
            grantedLabel: perms.batteryIgnored ? '已豁免' : '未豁免',
            onGrant: () async {
              await peerRequestIgnoreBatterySetting();
              await widget.onRefresh(pullUsage: false);
            },
          ),
          _permDivider(cs),
          Padding(
            key: const Key('peer-perm-autostart'),
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('厂商自启动 / 后台保护',
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text('系统后台查杀白名单（部分机型需手动开启）',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    key: const Key('peer-perm-autostart-btn'),
                    onPressed: () async {
                      final opened = await peerOpenAutoStartSettings();
                      if (!opened && mounted) {
                        setState(() => _showAutoStartGuide = true);
                      }
                    },
                    child: Text(perms.autoStartIntentSupported ? '去开启' : '查看指引'),
                  ),
                ]),
                if (_showAutoStartGuide ||
                    (perms.channelAvailable && !perms.autoStartIntentSupported))
                  Padding(
                    key: const Key('peer-perm-autostart-guide'),
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      autoStartGuideForManufacturer(perms.manufacturer),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );

    if (!widget.wrapInCard) {
      return KeyedSubtree(
        key: const Key('peer-perm-center'),
        child: content,
      );
    }
    return LiquidGlassCard(
      key: const Key('peer-perm-center'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: content,
    );
  }

  Widget _permDivider(ColorScheme cs) => Divider(
        height: 1,
        color: cs.outlineVariant.withValues(alpha: 0.45),
      );

  Widget _permRow(
    ThemeData theme,
    ColorScheme cs, {
    required Key rowKey,
    required Key btnKey,
    required String title,
    required String desc,
    required bool granted,
    String? grantedLabel,
    required VoidCallback onGrant,
  }) {
    final badgeText = grantedLabel ?? (granted ? '已开启' : '未开启');
    return Padding(
      key: rowKey,
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(
                    title,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: (granted
                            ? cs.primaryContainer
                            : cs.errorContainer)
                        .withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    badgeText,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: granted ? cs.onPrimaryContainer : cs.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ]),
              if (!granted) ...[
                const SizedBox(height: 2),
                Text(desc,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ],
          ),
        ),
        if (!granted) ...[
          const SizedBox(width: 8),
          FilledButton.tonal(
            key: btnKey,
            onPressed: onGrant,
            child: const Text('去授权'),
          ),
        ],
      ]),
    );
  }
}

/// 统一权限引导弹层（首次安装自动引导 + 报备页 24h 冷却引导共用）。
Future<void> showPeerPermissionGuideSheet(
  BuildContext context, {
  PeerPermissionSnapshot? initialSnapshot,
  bool isFirstInstall = false,
  VoidCallback? onOpenSettings,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    builder: (_) => _PeerPermissionGuideSheet(
      initialSnapshot: initialSnapshot,
      isFirstInstall: isFirstInstall,
      onOpenSettings: onOpenSettings,
    ),
  );
}

class _PeerPermissionGuideSheet extends StatefulWidget {
  const _PeerPermissionGuideSheet({
    this.initialSnapshot,
    required this.isFirstInstall,
    this.onOpenSettings,
  });

  final PeerPermissionSnapshot? initialSnapshot;
  final bool isFirstInstall;
  final VoidCallback? onOpenSettings;

  @override
  State<_PeerPermissionGuideSheet> createState() =>
      _PeerPermissionGuideSheetState();
}

class _PeerPermissionGuideSheetState extends State<_PeerPermissionGuideSheet>
    with WidgetsBindingObserver {
  late PeerPermissionSnapshot _perms =
      widget.initialSnapshot ?? PeerPermissionSnapshot.unavailable;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.initialSnapshot == null) {
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh({bool pullUsage = false}) async {
    final snap = await peerPermissionStatus();
    if (!mounted) return;
    setState(() => _perms = snap);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final allOk = _perms.allGranted;

    return AppleSheetContainer(
      key: const Key('peer-perm-prompt-sheet'),
      icon: Icons.verified_user_rounded,
      iconTone: AppleIconTone.emerald,
      title: widget.isFirstInstall ? '开启完整守护权限' : '开启完整报备能力',
      subtitle: widget.isFirstInstall
          ? '首次使用建议一次补齐，定位、提醒与使用统计才能稳定工作。'
          : '检测到以下系统权限尚未开启，可能导致对方看不到你的状态或位置。',
      onClose: () => Navigator.of(context).pop(),
      maxHeightFactor: 0.84,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: dark
                      ? cs.surfaceContainerHighest.withValues(alpha: 0.42)
                      : cs.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(AppRadius.medium),
                  border: Border.all(
                    color: cs.outlineVariant.withValues(alpha: 0.55),
                    width: 0.8,
                  ),
                ),
                child: PeerPermissionChecklist(
                  perms: _perms,
                  onRefresh: _refresh,
                  wrapInCard: false,
                  title: '逐项授权清单',
                ),
              ),
            ),
          ),
          const SizedBox(height: Spacing.lg),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                key: const Key('peer-perm-prompt-later'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('稍后再说'),
              ),
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: FilledButton(
                key: const Key('peer-perm-prompt-go'),
                onPressed: () {
                  Navigator.of(context).pop();
                  if (!widget.isFirstInstall) {
                    widget.onOpenSettings?.call();
                  }
                },
                child: Text(
                  widget.isFirstInstall
                      ? (allOk ? '全部已就绪' : '完成')
                      : '去补齐',
                ),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
