/// 2.8.0 报备入口 P0 · 首页快捷报备胶囊条（`features/home/`）。
///
/// 落位（盘线结论）：ListView 布局流内——**每日一句之下、历史上的今天之上**。
/// 🔴 冻结教训红线：本组件是普通布局子组件，**禁止任何 overlay / 悬浮层 /
/// Stack 覆盖主体**（2.3.2「首页主体点击全失效」的元凶就是覆盖层截获手势）。
///
/// 交互：
/// · 单击 = 用该预设直接发送（`summary`=预设 summary、`push`=预设 push）；
/// · 长按 = 底部 sheet（半径 16）填备注（≤500）与地点（≤80）后发送，
///   三要素（scene/summary/push）**仍沿预设**——避免静默预设（push:false）
///   在补备注时被误升级成强推送。
///
/// 取数：`GET /api/peer/report-presets`（失败且无缓存时回落后端同款 6 条，
/// 仅作渲染回落，**不落库冒充用户配置**）；对方最近一条 manual 报备走
/// `GET /api/peer/events`（仅当日，过零点自然清空，不额外回退查昨天）。
///
/// 422 关闭：固定文案 + 「去开启」动作（2.8.0 P1 起跳到 /settings/peer-share，
/// 开启后回到首页再点胶囊即可重发；已因 422 出队的旧报备不自动重发）。
///
/// 补发触发（令文二·3 三处）：组件初始化 / App 回前台 / SSE 重连成功。
/// 全部走 [ReportOutbox.flush] 的内存单飞锁，并发触发直接忽略。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart' show dioProvider;
import '../../core/peer/peer_report_api.dart';
import '../../core/peer/peer_report_data.dart' show relativeTimeZh;
import '../../core/peer/peer_report_queue.dart';
import '../../core/sse/sse_client.dart' show SsePhase, sseEventsProvider, sseProvider;
import '../../core/theme/tokens.dart';
import '../../core/ui/apple_ui.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;

/// 快捷预设（失败回落默认 6 条；回落值不写回服务端）。
final reportPresetsProvider = FutureProvider<List<ReportPreset>>((ref) async {
  try {
    final dio = await ref.watch(dioProvider.future);
    return await fetchReportPresets(dio);
  } catch (_) {
    return kDefaultReportPresets;
  }
});

/// 对方今日最近一条主动报备（null = 今天还没有 / 拉取失败）。
/// 两种情况都**整行不渲染**，不占位造假。
final reportTodayPeerProvider = FutureProvider<PeerEventItem?>((ref) async {
  try {
    final dio = await ref.watch(dioProvider.future);
    final day = await fetchPeerEvents(dio);
    if (day.peerClosedOff) return null;
    return day.latestPeerManualReport;
  } catch (_) {
    return null;
  }
});

class ReportCapsuleBar extends ConsumerStatefulWidget {
  const ReportCapsuleBar({super.key, this.outbox});

  /// 测试可注入独立队列实例（生产用全局单例）。
  final ReportOutbox? outbox;

  @override
  ConsumerState<ReportCapsuleBar> createState() => _ReportCapsuleBarState();
}

class _ReportCapsuleBarState extends ConsumerState<ReportCapsuleBar> {
  /// 正在发送的 scene（非空即整体防连点）。
  String? _sending;
  AppLifecycleListener? _lifecycle;
  ReportOutbox get _outbox => widget.outbox ?? reportOutbox;

  @override
  void initState() {
    super.initState();
    // 触发①：组件初始化（冷启动补发）
    Future.microtask(_flush);
    _lifecycle = AppLifecycleListener(onResume: _flush);
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  /// 补发：结果只在「遇到关闭」时提示（正常补发静默，不打扰）。
  Future<void> _flush() async {
    if (!mounted) return;
    try {
      final dio = await ref.read(dioProvider.future);
      final res = await _outbox.flush(dio);
      if (!mounted || res.skipped) return;
      if (res.sent > 0) ref.invalidate(reportTodayPeerProvider);
      if (res.closedOff) _toastShareClosed();
    } catch (_) {
      // 补发失败静默：下次触发再来
    }
  }

  void _toast(String text, {ChatToastTone tone = ChatToastTone.info}) {
    ref.read(chatToastProvider.notifier).show(text, tone: tone);
  }

  /// 422「报备事件共享已关闭」：固定文案 + 「去开启」动作（2.8.0 P1 闭环）。
  /// 动作按钮跳 `PeerShareSettingsPage`（设置二级页，push 语义）。
  void _toastShareClosed() {
    ref.read(chatToastProvider.notifier).showAction(
      _shareClosedText,
      actionLabel: '去开启',
      onAction: () {
        if (!mounted) return;
        context.push('/settings/peer-share');
      },
    );
  }

  static const String _shareClosedText = '已关闭报备事件共享，开启后才能发报备';

  Future<void> _send(
    ReportPreset preset, {
    String note = '',
    String placeName = '',
  }) async {
    if (_sending != null) return; // 防连点
    setState(() => _sending = preset.scene);
    // 每次新报备换新 client_id；同一次发送的重试/补发复用同一个
    final clientId = newReportClientId();
    try {
      final dio = await ref.read(dioProvider.future);
      await sendReport(
        dio,
        scene: preset.scene,
        summary: preset.summary,
        note: note,
        placeName: placeName,
        push: preset.push,
        clientId: clientId,
      );
      if (!mounted) return;
      _toast('已报备给 TA');
      ref.invalidate(reportTodayPeerProvider);
    } on ReportShareClosed {
      if (!mounted) return;
      // 2.8.0 P1：开关页已落地（/settings/peer-share），提示带「去开启」跳转
      _toastShareClosed();
    } on PeerApiException catch (e) {
      if (!mounted) return;
      _toast(e.detail, tone: ChatToastTone.error); // 其他 4xx：业务错误不入队
    } catch (_) {
      // 网络类 / 5xx：入队待发（client_id 原样带过去，服务端幂等兜重）
      await _outbox.enqueue(PendingReport(
        scene: preset.scene,
        clientId: clientId,
        createdAt: DateTime.now().millisecondsSinceEpoch / 1000,
        summary: preset.summary,
        note: note,
        placeName: placeName,
        push: preset.push,
      ));
      if (!mounted) return;
      _toast('网络不畅，已存待发');
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final presets = ref.watch(reportPresetsProvider).value ??
        kDefaultReportPresets;
    final latest = ref.watch(reportTodayPeerProvider).value;

    // 触发③：SSE 重连成功（断线期间可能有漏事件）→ 补发 + 刷最近一条
    ref.listen(sseProvider, (prev, next) {
      if (prev?.phase != SsePhase.connected &&
          next.phase == SsePhase.connected) {
        _flush();
        ref.invalidate(reportTodayPeerProvider);
      }
    });
    // 触发②之一：SSE peer 段到达 → 只刷「最近一条对方报备」这一行
    ref.listen(sseEventsProvider, (prev, next) {
      if (next.value?.peer == true) ref.invalidate(reportTodayPeerProvider);
    });

    final recentLine = _recentLine(presets, latest);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: presets.length,
            separatorBuilder: (_, _) => const SizedBox(width: Spacing.gap),
            itemBuilder: (context, i) {
              final p = presets[i];
              final busy = _sending == p.scene;
              return _Capsule(
                preset: p,
                busy: busy,
                // 任一发送进行中，其余胶囊一并禁用（防连点/防并发）
                enabled: _sending == null,
                onTap: () => _send(p),
                onLongPress: () => _composeSheet(p),
              );
            },
          ),
        ),
        if (recentLine != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 2),
            child: Text(
              recentLine,
              key: const Key('report-capsule-recent'),
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  /// 「TA · 到家了 · 12 分钟前」——label 优先（预设 label 比 summary 更像状态词），
  /// 找不到对应 presets 时退回事件 summary。
  String? _recentLine(List<ReportPreset> presets, PeerEventItem? latest) {
    if (latest == null) return null;
    var word = latest.summary;
    for (final p in presets) {
      if (p.scene == latest.scene) {
        word = p.label;
        break;
      }
    }
    if (word.isEmpty) return null;
    return 'TA · $word · ${relativeTimeZh(latest.ts)}';
  }

  /// 长按补备注：sheet 只收集文本，发送沿用预设三要素（scene/summary/push）。
  Future<void> _composeSheet(ReportPreset preset) async {
    if (_sending != null) return;
    final draft = await showModalBottomSheet<({String note, String placeName})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      builder: (_) => _ReportComposeSheet(preset: preset),
    );
    if (draft == null || !mounted) return;
    await _send(preset, note: draft.note, placeName: draft.placeName);
  }
}

/// 单个胶囊：emoji + label；发送中显示 loading 且不可点。
class _Capsule extends StatelessWidget {
  const _Capsule({
    required this.preset,
    required this.busy,
    required this.enabled,
    required this.onTap,
    required this.onLongPress,
  });

  final ReportPreset preset;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final fg = enabled
        ? cs.onSurface
        : cs.onSurface.withValues(alpha: dark ? 0.45 : 0.48);
    return Container(
      decoration: BoxDecoration(
        color: !enabled
            ? (dark
                ? cs.surfaceContainerHighest.withValues(alpha: 0.45)
                : cs.surfaceContainerHighest.withValues(alpha: 0.65))
            : (dark
                ? cs.surfaceContainerHigh.withValues(alpha: 0.88)
                : cs.surface),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(
          color: !enabled
              ? cs.outline.withValues(alpha: dark ? 0.22 : 0.28)
              : (dark
                  ? Colors.white.withValues(alpha: 0.14)
                  : cs.outline.withValues(alpha: 0.34)),
          width: 0.9,
        ),
        boxShadow: enabled ? appleCardShadows(dark) : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: InkWell(
          key: Key('report-capsule-${preset.scene}'),
          borderRadius: BorderRadius.circular(AppRadius.pill),
          onTap: enabled ? onTap : null,
          onLongPress: enabled ? onLongPress : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (busy)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: cs.primary,
                  ),
                )
              else
                Text(preset.emoji, style: const TextStyle(fontSize: 14)),
              const SizedBox(width: 6),
              Text(
                preset.label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 补备注 sheet：备注 ≤500、地点 ≤80；「发送」回传草稿，网络动作由外层完成。
class _ReportComposeSheet extends StatefulWidget {
  const _ReportComposeSheet({required this.preset});
  final ReportPreset preset;

  @override
  State<_ReportComposeSheet> createState() => _ReportComposeSheetState();
}

class _ReportComposeSheetState extends State<_ReportComposeSheet> {
  final _note = TextEditingController();
  final _place = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    _place.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop((
      note: _note.text.trim(),
      placeName: _place.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AppleSheetContainer(
      title: '${widget.preset.emoji} ${widget.preset.label}',
      subtitle: '发送后 TA 会收到「${widget.preset.summary}」',
      onClose: () => Navigator.of(context).pop(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _note,
            maxLength: 500,
            maxLines: 3,
            minLines: 1,
            decoration: const InputDecoration(
              labelText: '备注（可选）',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _place,
            maxLength: 80,
            decoration: const InputDecoration(
              labelText: '地点（可选）',
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: FilledButton(
                key: const Key('report-compose-send'),
                onPressed: _submit,
                child: const Text('发送'),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
