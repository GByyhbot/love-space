/// 2.8.7 自动报备：端上聚合/节流纯函数护栏。
///
/// 钉住阈值与窗口口径（设计 §五）：
/// · 电量 Δ≥2% 或充电翻转才报，60s 防抖；
/// · 网络类型变化即报（30s 防抖），SSID 抖动 5min 冷却；
/// · 解锁 10min 窗口聚合；
/// · 亮屏会话按 ON/OFF 算时长。
/// 另含队列项的 kind/payload 往返（主动报备语义不许被改变）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/peer/peer_report_queue.dart';
import 'package:love_space/core/peer/state_aggregator.dart';

const int _s = 1000;

void main() {
  group('BatteryGate', () {
    test('首次采样建基线并上报（不能因为"没变化"就永远不报）', () {
      final g = BatteryGate();
      final r = g.onReading(level: 80, charging: false, nowMs: 0);
      expect(r, isNotNull);
      expect(r!.kind, 'state.battery');
      expect(r.payload, {'level': 80, 'charging': false});
    });

    test('Δ<2 不报、Δ≥2 报', () {
      final g = BatteryGate();
      g.onReading(level: 80, charging: false, nowMs: 0);
      expect(g.onReading(level: 81, charging: false, nowMs: 120 * _s), isNull);
      final r = g.onReading(level: 82, charging: false, nowMs: 240 * _s);
      expect(r?.payload['level'], 82);
    });

    test('充电翻转即时报（电量不动也算变化）', () {
      final g = BatteryGate();
      g.onReading(level: 50, charging: false, nowMs: 0);
      final r = g.onReading(level: 50, charging: true, nowMs: 120 * _s);
      expect(r?.payload, {'level': 50, 'charging': true});
    });

    test('60s 防抖：窗口内的第二个变化被丢弃', () {
      final g = BatteryGate();
      g.onReading(level: 50, charging: false, nowMs: 0);
      expect(g.onReading(level: 55, charging: false, nowMs: 30 * _s), isNull,
          reason: '30s < 60s 窗口');
      expect(g.onReading(level: 58, charging: false, nowMs: 61 * _s), isNotNull);
    });

    test('越界电量（原生读不到给 -1）不报', () {
      final g = BatteryGate();
      expect(g.onReading(level: -1, charging: false, nowMs: 0), isNull);
      expect(g.onReading(level: 101, charging: false, nowMs: 0), isNull);
    });

    test('reset 后重新建基线', () {
      final g = BatteryGate();
      g.onReading(level: 80, charging: false, nowMs: 0);
      g.reset();
      expect(g.onReading(level: 80, charging: false, nowMs: 0), isNotNull);
    });
  });

  group('NetGate', () {
    test('首次采样上报当前网络', () {
      final g = NetGate();
      final r = g.onNetwork(net: 'wifi', ssid: 'home', nowMs: 0);
      expect(r?.payload, {'net': 'wifi', 'ssid': 'home'});
    });

    test('类型不变且 SSID 不变 → 不报', () {
      final g = NetGate();
      g.onNetwork(net: 'wifi', ssid: 'home', nowMs: 0);
      expect(g.onNetwork(net: 'wifi', ssid: 'home', nowMs: 60 * _s), isNull);
    });

    test('类型变化即报（wifi → none）', () {
      final g = NetGate();
      g.onNetwork(net: 'wifi', ssid: 'home', nowMs: 0);
      final r = g.onNetwork(net: 'none', ssid: '', nowMs: 60 * _s);
      expect(r?.payload['net'], 'none');
    });

    test('SSID 抖动在 5min 冷却内被丢弃，过了冷却才报', () {
      final g = NetGate();
      g.onNetwork(net: 'wifi', ssid: 'home', nowMs: 0);
      expect(g.onNetwork(net: 'wifi', ssid: '', nowMs: 60 * _s), isNull,
          reason: '漫游抖动 1 分钟内不该刷出一条');
      final r = g.onNetwork(net: 'wifi', ssid: 'home2', nowMs: 301 * _s);
      expect(r?.payload['ssid'], 'home2');
    });

    test('未知网络类型不报', () {
      final g = NetGate();
      expect(g.onNetwork(net: '4g', nowMs: 0), isNull);
    });

    test('非 wifi 时 ssid 恒为空串（降级 type-only，不伪造名字）', () {
      final g = NetGate();
      final r = g.onNetwork(net: 'cell', ssid: 'should-be-dropped', nowMs: 0);
      expect(r?.payload, {'net': 'cell', 'ssid': ''});
    });
  });

  group('UnlockAggregator', () {
    test('窗口未满不落、满 10 分钟落一条 count', () {
      final agg = UnlockAggregator();
      agg.onUnlock(0);
      agg.onUnlock(1000);
      expect(agg.drainIfDue(60 * _s), isNull, reason: '1 分钟远未满窗');
      final sample = agg.drainIfDue(601 * _s);
      expect(sample?.payload['count'], 2);
      expect(sample?.payload['window_sec'], 600);
    });

    test('落窗后计数清零', () {
      final agg = UnlockAggregator();
      agg.onUnlock(0);
      agg.drain();
      expect(agg.pending, 0);
      expect(agg.drain(), isNull);
    });
  });

  group('ScreenSessionTracker', () {
    test('ON → OFF 得出会话秒数', () {
      final t = ScreenSessionTracker();
      t.onScreenOn(0);
      final r = t.onScreenOff(120 * _s);
      expect(r?.payload, {'session_sec': 120, 'on': false});
      expect(t.inSession, isFalse);
    });

    test('未记录 ON 直接 OFF → 不报（不臆造时长）', () {
      final t = ScreenSessionTracker();
      expect(t.onScreenOff(10 * _s), isNull);
    });

    test('重复 ON 不重置起点', () {
      final t = ScreenSessionTracker();
      t.onScreenOn(0);
      t.onScreenOn(50 * _s);
      expect(t.onScreenOff(100 * _s)?.payload['session_sec'], 100);
    });
  });

  group('PendingReport kind/payload 往返', () {
    test('状态事件（无 scene）能入库并原样回读', () {
      const item = PendingReport(
        scene: '',
        clientId: 'cid-1',
        createdAt: 100,
        kind: 'state.battery',
        payload: {'level': 30, 'charging': false},
      );
      final back = PendingReport.fromJson(item.toJson());
      expect(back, isNotNull);
      expect(back!.kind, 'state.battery');
      expect(back.payload, {'level': 30, 'charging': false});
    });

    test('主动报备语义不变（scene 仍在、kind 为空）', () {
      const item = PendingReport(
        scene: 'arrive',
        clientId: 'cid-2',
        createdAt: 100,
        summary: '到家了',
      );
      final back = PendingReport.fromJson(item.toJson())!;
      expect(back.scene, 'arrive');
      expect(back.kind, '');
      expect(back.payload, isNull);
      expect(back.summary, '到家了');
    });

    test('scene 与 kind 都空 → 视为废记录丢弃（旧口径保留）', () {
      expect(PendingReport.fromJson({'client_id': 'x'}), isNull);
    });
  });
}
