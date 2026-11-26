/// 2.8.7 自动报备：简行文案与状态卡文案纯函数。
///
/// 钉住两条口径：
/// ① SSID 取不到只说类型，**不伪造网络名**；
/// ② 对方关闭共享 / 今日无数据时返回 null（整行不渲染），**不显示 0**。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/peer/peer_report_api.dart';
import 'package:love_space/core/peer/state_event_text.dart';

PeerEventItem _ev(String type, Map<String, Object?> payload,
        {String summary = ''}) =>
    PeerEventItem(
      id: 'e1',
      user: 'u1',
      type: type,
      ts: 1000,
      summary: summary,
      payload: payload,
    );

void main() {
  group('stateEventText', () {
    test('电量：未充电 / 充电中两种说法', () {
      expect(stateEventText(_ev('state.battery', {'level': 18, 'charging': false})),
          '电量 18%');
      expect(stateEventText(_ev('state.battery', {'level': 18, 'charging': true})),
          '电量 18%，充电中');
    });

    test('网络：有 SSID 带名字，无 SSID 只说类型（不伪造）', () {
      expect(stateEventText(_ev('state.net', {'net': 'wifi', 'ssid': 'home'})),
          '连上 Wi-Fi（home）');
      expect(stateEventText(_ev('state.net', {'net': 'wifi', 'ssid': ''})),
          '连上 Wi-Fi');
      expect(stateEventText(_ev('state.net', {'net': 'cell'})), '切到移动数据');
      expect(stateEventText(_ev('state.net', {'net': 'none'})), '断开网络');
    });

    test('解锁与亮屏', () {
      expect(stateEventText(_ev('state.unlock', {'count': 14})), '解锁 14 次');
      expect(stateEventText(_ev('state.screen', {'session_sec': 720})),
          '亮屏 12 分钟');
    });

    test('payload 与 summary 都空 → 按类型兜底（真机空白事故回归）', () {
      expect(stateEventText(_ev('state.battery', {})), '电量发生变化');
      expect(stateEventText(_ev('state.net', {})), '网络发生变化');
      expect(stateEventText(_ev('state.unlock', {})), '有解锁');
      expect(stateEventText(_ev('state.screen', {})), '亮屏');
      expect(stateEventText(_ev('state.unknown', {})), '设备状态发生变化');
    });

    test('未知类型/缺字段回落到后端 summary（不出现空白行）', () {
      expect(stateEventText(_ev('state.other', {}, summary: '别的什么')), '别的什么');
      expect(stateEventText(_ev('state.battery', {}, summary: '兜底')), '兜底');
    });

    test('isStateEvent 只认 state. 前缀', () {
      expect(_ev('state.battery', {}).isStateEvent, isTrue);
      expect(_ev('manual_report', {}).isStateEvent, isFalse);
    });
  });

  group('durationTextZh', () {
    test('分级时长文案', () {
      expect(durationTextZh(0), '不足 1 分钟');
      expect(durationTextZh(30), '不足 1 分钟');
      expect(durationTextZh(60), '1 分钟');
      expect(durationTextZh(65 * 60), '1 小时 5 分钟');
      expect(durationTextZh(120 * 60), '2 小时');
    });
  });

  group('peerScreenLine（状态卡今日亮屏行）', () {
    test('对方关闭共享 → null（整行不渲染，不显示 0）', () {
      expect(peerScreenLine(true, 0, 0), isNull);
      expect(peerScreenLine(true, 600, 3), isNull);
    });

    test('今日无数据 → null（不冒充"没亮屏"）', () {
      expect(peerScreenLine(false, 0, 0), isNull);
    });

    test('有数据 → 亮屏+解锁组合串，单项可缺', () {
      expect(peerScreenLine(false, 3600, 12), '亮屏 1 小时 · 解锁 12 次');
      expect(peerScreenLine(false, 720, 0), '亮屏 12 分钟');
      expect(peerScreenLine(false, 0, 5), '解锁 5 次');
    });
  });

  group('围栏（2026-11-27 令解除 usage 围栏，换脱敏红线）', () {
    test('采集路径必须带脱敏：哨兵常量存在且在入队前生效', () {
      // 旧断言「采集/上报路径不许消费 usage/top_apps」已被本令作废。
      // 新红线：真实包名不许出设备——采集入口必须引用哨兵与脱敏函数。
      final f = File('lib/core/peer/peer_state_collector.dart');
      final src = f.readAsStringSync();
      expect(src.contains("const String kMaskedPkg = 'masked.other'"), isTrue);
      expect(src.contains('sanitizeTelemetryPayload'), isTrue);
      expect(src.contains('reportOutbox.enqueue'), isTrue);
      // 入队前必须先过脱敏：出现顺序即证据（sanitize 在 enqueue 之前）
      final sanitizeAt = src.indexOf('sanitizeTelemetryPayload(kind');
      final enqueueAt = src.indexOf('reportOutbox.enqueue');
      expect(sanitizeAt, greaterThan(0));
      expect(enqueueAt, greaterThan(sanitizeAt),
          reason: '脱敏必须在入队之前，否则真实包名会先落盘');
    });

    test('usage 开关只在设置/预览路径被读，采集器不直接读它', () {
      final f = File('lib/core/peer/peer_state_collector.dart');
      final src = f.readAsStringSync();
      // 采集器只认 policy（applyPeerPolicy），不认四键里的 usage
      expect(src.contains('.usage'), isFalse,
          reason: '采集器应读 policy，不该绕过档位直接读 usage 开关');
    });
  });
}
