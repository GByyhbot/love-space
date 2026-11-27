/// 今日页时间线同类高频状态事件折叠（纯呈现层：不删不改任何原始事件或接口口径）。
library;

import 'peer_report_api.dart';
import 'state_event_text.dart';

const Set<String> kFoldableStateEventTypes = <String>{
  'state.battery',
  'state.unlock',
  'state.screen',
  'state.net',
};

/// 时间线展示条目：要么是一条原样事件，要么是一组相邻同类高频状态事件的折叠汇总。
sealed class TimelineDisplayEntry {
  const TimelineDisplayEntry();
}

class TimelineSingleEntry extends TimelineDisplayEntry {
  const TimelineSingleEntry(this.event);
  final PeerEventItem event;
}

class TimelineFoldedGroup extends TimelineDisplayEntry {
  const TimelineFoldedGroup({
    required this.groupKey,
    required this.type,
    required this.mine,
    required this.events,
    required this.summaryText,
    required this.latestTs,
    required this.earliestTs,
  });

  final String groupKey;
  final String type;
  final bool mine;
  final List<PeerEventItem> events;
  final String summaryText;
  final double latestTs;
  final double earliestTs;
}

/// 将已排序的 [events] 中连续、同类型且同一归属方（`mine`）的高频状态事件合并为折叠组；
/// 孤立单条（`run.length == 1`）或中间夹有其他类型/主动报备时保持散行展示，保证既有单测兼容。
List<TimelineDisplayEntry> foldTimelineEvents(List<PeerEventItem> events) {
  if (events.isEmpty) return const <TimelineDisplayEntry>[];

  final out = <TimelineDisplayEntry>[];
  var i = 0;
  while (i < events.length) {
    final first = events[i];
    if (!kFoldableStateEventTypes.contains(first.type)) {
      out.add(TimelineSingleEntry(first));
      i++;
      continue;
    }

    var j = i + 1;
    while (j < events.length &&
        events[j].type == first.type &&
        events[j].mine == first.mine) {
      j++;
    }

    final run = events.sublist(i, j);
    if (run.length == 1) {
      out.add(TimelineSingleEntry(first));
    } else {
      final latestTs = run.first.ts;
      final earliestTs = run.last.ts;
      out.add(TimelineFoldedGroup(
        groupKey: '${first.type}_${first.id}_${run.last.id}',
        type: first.type,
        mine: first.mine,
        events: List<PeerEventItem>.unmodifiable(run),
        summaryText: _summarizeRun(first.type, run, latestTs, earliestTs),
        latestTs: latestTs,
        earliestTs: earliestTs,
      ));
    }
    i = j;
  }
  return out;
}

String _summarizeRun(
  String type,
  List<PeerEventItem> run,
  double latestTs,
  double earliestTs,
) {
  final spanSec = (latestTs - earliestTs).round().abs();
  final spanLabel =
      spanSec >= 60 ? '约 ${durationTextZh(spanSec)}' : '共 ${run.length} 条';

  switch (type) {
    case 'state.battery':
      return _summarizeBattery(run, spanLabel);
    case 'state.unlock':
      var totalUnlocks = 0;
      for (final e in run) {
        totalUnlocks += (e.payload['count'] as num?)?.toInt() ?? 1;
      }
      return spanSec >= 60
          ? '连续解锁 $totalUnlocks 次 · $spanLabel'
          : '连续解锁 $totalUnlocks 次（${run.length} 条）';
    case 'state.screen':
      var totalSec = 0;
      for (final e in run) {
        totalSec += (e.payload['session_sec'] as num?)?.toInt() ?? 0;
      }
      return totalSec > 0
          ? '亮屏 ${run.length} 次 · 累计 ${durationTextZh(totalSec)}'
          : '亮屏 ${run.length} 次 · $spanLabel';
    case 'state.net':
      return '网络切换 ${run.length} 次 · 当前 ${timelineEventText(run.first)}';
    default:
      return timelineEventText(run.first);
  }
}

String _summarizeBattery(List<PeerEventItem> run, String spanLabel) {
  // run 已按时间倒序排列：run.last 为最早一条（起），run.first 为最新一条（止）。
  final startLevel = _batteryLevelOf(run.last);
  final endLevel = _batteryLevelOf(run.first);
  final chargeStates = run.map(_batteryChargingOf).whereType<bool>().toSet();

  final String stateText;
  if (chargeStates.length == 1) {
    stateText = chargeStates.first ? '充电中' : '使用中';
  } else if (chargeStates.length > 1) {
    stateText = '充放电切换';
  } else {
    stateText = '';
  }

  final parts = <String>[
    if (startLevel != null && endLevel != null)
      '电量 $startLevel% → $endLevel%'
    else
      '电量变化 ${run.length} 次',
    if (stateText.isNotEmpty) stateText,
    spanLabel,
  ];
  return parts.join(' · ');
}

final RegExp _pctRegex = RegExp(r'(\d{1,3})\s*%');

int? _batteryLevelOf(PeerEventItem e) {
  final raw = (e.payload['level'] as num?)?.toInt();
  if (raw != null && raw >= 0 && raw <= 100) return raw;
  final m = _pctRegex.firstMatch(e.summary);
  if (m != null) {
    final v = int.tryParse(m.group(1)!);
    if (v != null && v >= 0 && v <= 100) return v;
  }
  return null;
}

bool? _batteryChargingOf(PeerEventItem e) {
  final raw = e.payload['charging'];
  if (raw is bool) return raw;
  if (e.summary.contains('充电中')) return true;
  if (e.summary.contains('未充电') || e.summary.contains('停止充电')) return false;
  return null;
}
