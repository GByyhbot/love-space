/// 2.8.7 第三段 · 今日时间线（排序 + 文案兜底）单测。
///
/// 两个纯函数各自钉住施工令里的两条：
/// · [sortEventsForTimeline]：按时间排（新在上），同秒按 id 稳定兜底，
///   不改动入参列表（fetch 与页面共用同一份）；
/// · [timelineEventText]：优先服务器现成中文，空则按 payload/类型兜底，
///   **任何输入都不许返回空串**（空白行事故不许复现）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/peer/peer_report_api.dart';
import 'package:love_space/core/peer/state_event_text.dart';

PeerEventItem _ev({
  String id = 'e1',
  String type = 'manual_report',
  String summary = '',
  double ts = 1000,
  String note = '',
  Map<String, Object?> payload = const <String, Object?>{},
}) =>
    PeerEventItem(
      id: id,
      user: 'ta',
      type: type,
      ts: ts,
      summary: summary,
      note: note,
      payload: payload,
    );

void main() {
  group('时间线排序', () {
    test('按时间倒序（新的在上）', () {
      final sorted = sortEventsForTimeline([
        _ev(id: 'a', ts: 100),
        _ev(id: 'b', ts: 300),
        _ev(id: 'c', ts: 200),
      ]);
      expect(sorted.map((e) => e.id).toList(), ['b', 'c', 'a']);
    });

    test('同秒按 id 倒序兜底：刷新前后顺序不跳', () {
      final sorted = sortEventsForTimeline([
        _ev(id: 'b', ts: 300),
        _ev(id: 'a', ts: 300),
        _ev(id: 'c', ts: 300),
      ]);
      expect(sorted.map((e) => e.id).toList(), ['c', 'b', 'a']);
    });

    test('不改动入参列表（mine/peer 合并用的是同一个列表）', () {
      final input = [_ev(id: 'a', ts: 100), _ev(id: 'b', ts: 300)];
      sortEventsForTimeline(input);
      expect(input.map((e) => e.id).toList(), ['a', 'b']);
    });

    test('空列表不炸', () {
      expect(sortEventsForTimeline(const <PeerEventItem>[]), isEmpty);
    });
  });

  group('文案兜底（优先服务器中文，绝不出空行）', () {
    test('服务器 summary 优先于 payload 自算', () {
      expect(
        timelineEventText(_ev(
          type: 'state.battery',
          summary: '电量 66%，充电中（服务端）',
          payload: const {'level': 66, 'charging': true},
        )),
        '电量 66%，充电中（服务端）',
      );
    });

    test('summary 空 → 状态事件按 payload 生成', () {
      expect(
        timelineEventText(_ev(
            type: 'state.battery',
            payload: const {'level': 66, 'charging': true})),
        '电量 66%，充电中',
      );
      expect(
        timelineEventText(_ev(
            type: 'state.net', payload: const {'net': 'wifi', 'ssid': 'home'})),
        '连上 Wi-Fi（home）',
      );
      expect(
        timelineEventText(_ev(
            type: 'state.net', payload: const {'net': 'wifi', 'ssid': ''})),
        '连上 Wi-Fi',
      );
      expect(
        timelineEventText(_ev(
            type: 'state.screen', payload: const {'session_sec': 3900})),
        '亮屏 1 小时 5 分钟',
      );
      expect(
        timelineEventText(
            _ev(type: 'state.unlock', payload: const {'count': 3})),
        '解锁 3 次',
      );
    });

    test('summary 与 payload 都空 → 按类型兜底（不空行）', () {
      expect(timelineEventText(_ev(type: 'state.battery')), '电量发生变化');
      expect(timelineEventText(_ev(type: 'state.net')), '网络发生变化');
      expect(timelineEventText(_ev(type: 'state.screen')), '亮屏');
      expect(timelineEventText(_ev(type: 'state.unlock')), '有解锁');
      expect(timelineEventText(_ev(type: 'state.unknown')), '设备状态发生变化');
    });

    test('手填报备 summary 空 → 退备注，再退固定文案', () {
      expect(
        timelineEventText(_ev(type: 'manual_report', note: '加班到十点')),
        '加班到十点',
      );
      expect(timelineEventText(_ev(type: 'manual_report')), '报备');
    });

    test('非状态自动事件 summary 空 → 一句通用文案', () {
      expect(timelineEventText(_ev(type: 'arrive_place')), '有一条动态');
    });

    test('只有空白字符的 summary 视为空', () {
      expect(
        timelineEventText(_ev(type: 'state.unlock', summary: '   ',
            payload: const {'count': 2})),
        '解锁 2 次',
      );
    });

    test('任意组合都不返回空串', () {
      final cases = <PeerEventItem>[
        _ev(),
        _ev(type: 'manual_report'),
        _ev(type: 'state.battery'),
        _ev(type: 'state.net', payload: const {'net': 'weird'}),
        _ev(type: 'state.screen', payload: const {'session_sec': 0}),
        _ev(type: 'manual_report', summary: ' '),
        _ev(type: 'unknown.type'),
      ];
      for (final e in cases) {
        expect(timelineEventText(e).trim(), isNotEmpty,
            reason: '事件 ${e.type} 渲染出空行');
      }
    });
  });
}
