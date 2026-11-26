/// 2.8.7 第三段 · 对方状态卡装配（`buildPeerStatusCard`）单测。
///
/// 施工令点名的四种形态，逐一钉死：
/// ① 齐全（电量/网络/最后活跃/今日使用 四行都在，值按口径拼）
/// ② 缺项隐藏（取不到的**整行**不出现，其余行照常）
/// ③ 全缺隐藏（一行都没有 → 整卡不显示，返回 null）
/// ④ 超 6 小时警告（明写「长时间无更新」，且严格大于 6 小时）
///
/// 另钉：绝不拿 0 糊弄（0% 是真值照显、今日 0 亮屏 0 解锁不显示）、
/// 关闭共享不显示今日使用、状态快照比定位新时取状态时刻。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/peer/peer_report_api.dart';
import 'package:love_space/core/peer/peer_report_data.dart';
import 'package:love_space/core/peer/peer_status_card.dart';

/// 固定「现在」，避开真实时钟（相对时间才可断言）。
final DateTime _now = DateTime(2026, 11, 26, 23, 0);

double _ts(Duration ago) =>
    _now.subtract(ago).millisecondsSinceEpoch / 1000;

PeerLatest _peer({
  int? battery = 82,
  bool? charging = false,
  String? net = 'wifi',
  String? wifi = 'home',
  double? updated,
  double? stateUpdated,
}) =>
    PeerLatest(
      lat: 39.9087,
      lng: 116.3975,
      updated: updated ?? _ts(const Duration(minutes: 12)),
      battery: battery,
      charging: charging,
      net: net,
      wifi: wifi,
      stateUpdated: stateUpdated,
    );

PeerStateDaily _daily({int screenSec = 3900, int unlocks = 12, bool closedOff = false}) =>
    PeerStateDaily(
      date: '2026-11-26',
      mineScreenSec: 0,
      mineUnlocks: 0,
      peerClosedOff: closedOff,
      peerScreenSec: screenSec,
      peerUnlocks: unlocks,
    );

List<String> _ids(PeerStatusCardData? d) =>
    d == null ? const <String>[] : d.rows.map((r) => r.id).toList();

String _value(PeerStatusCardData? d, String id) =>
    d!.rows.firstWhere((r) => r.id == id).value;

void main() {
  group('① 齐全：四行都在，文案按口径', () {
    test('电量/网络/最后活跃/今日使用 顺序与取值', () {
      final d = buildPeerStatusCard(peer: _peer(), daily: _daily(), now: _now);
      expect(_ids(d), ['battery', 'net', 'active', 'usage']);
      expect(_value(d, 'battery'), '82% · 未充电');
      expect(_value(d, 'net'), 'Wi-Fi（home）');
      expect(_value(d, 'active'), startsWith('12 分钟前 · '));
      expect(_value(d, 'active'), contains('2026-11-26 22:48'));
      expect(_value(d, 'usage'), '亮屏 1 小时 5 分钟 · 解锁 12 次');
      expect(d!.stale, isFalse);
      expect(d.rows.firstWhere((r) => r.id == 'active').warn, isFalse);
    });

    test('充电中 / 充电未知 不编造', () {
      expect(
        _value(buildPeerStatusCard(peer: _peer(charging: true), now: _now),
            'battery'),
        '82% · 充电中',
      );
      // 充电状态缺字段：只写百分比，不写「未充电」
      expect(
        _value(buildPeerStatusCard(peer: _peer(charging: null), now: _now),
            'battery'),
        '82%',
      );
    });

    test('电量 0 是真实值 → 照常显示 0%（不当作「取不到」隐藏）', () {
      final d = buildPeerStatusCard(peer: _peer(battery: 0), now: _now);
      expect(_value(d, 'battery'), '0% · 未充电');
    });

    test('网络三种类型 + 未知取值原样呈现', () {
      String netOf(PeerLatest p) =>
          _value(buildPeerStatusCard(peer: p, now: _now), 'net');
      expect(netOf(_peer(net: 'wifi', wifi: '')), 'Wi-Fi',
          reason: '拿不到 SSID 只写类型，不编「未知网络」');
      expect(netOf(_peer(net: 'wifi', wifi: '  ')), 'Wi-Fi');
      expect(netOf(_peer(net: 'cell', wifi: '')), '移动数据');
      expect(netOf(_peer(net: 'none', wifi: '')), '无网络');
      expect(netOf(_peer(net: '5g', wifi: '')), '5g',
          reason: '未枚举取值原样呈现，不猜测');
    });
  });

  group('② 缺项隐藏：取不到就整行不出现（卡片仍在）', () {
    test('电量/网络缺 → 只剩最后活跃一行', () {
      final d = buildPeerStatusCard(
        peer: _peer(battery: null, net: null),
        now: _now,
      );
      expect(d, isNotNull);
      expect(_ids(d), ['active']);
    });

    test('今日汇总拉不到（daily=null）→ 不显示今日使用，其余照常', () {
      final d = buildPeerStatusCard(peer: _peer(), now: _now);
      expect(_ids(d), ['battery', 'net', 'active']);
      expect(_ids(d).contains('usage'), isFalse);
    });

    test('只有电量也能成卡', () {
      // 直接构造：`_peer()` 的 updated 有缺省值，这里要的正是「没有时间戳」
      final d = buildPeerStatusCard(
        peer: const PeerLatest(
          lat: 39.9087,
          lng: 116.3975,
          updated: null,
          battery: 82,
          charging: true,
        ),
        now: _now,
      );
      expect(_ids(d), ['battery']);
      expect(_value(d, 'battery'), '82% · 充电中');
    });

    test('今日 0 亮屏 0 解锁 → 整行不显示（不写 0，不当成「没亮屏」）', () {
      final d = buildPeerStatusCard(
        peer: _peer(),
        daily: _daily(screenSec: 0, unlocks: 0),
        now: _now,
      );
      expect(_ids(d).contains('usage'), isFalse);
    });

    test('对方关闭共享 → 今日使用整行不显示（closed_off 的 0 是「看不到」）', () {
      final d = buildPeerStatusCard(
        peer: _peer(),
        daily: _daily(closedOff: true),
        now: _now,
      );
      expect(_ids(d).contains('usage'), isFalse);
    });

    test('只有亮屏没解锁 → 只写亮屏那半句', () {
      final d = buildPeerStatusCard(
        peer: _peer(),
        daily: _daily(screenSec: 3900, unlocks: 0),
        now: _now,
      );
      expect(_value(d, 'usage'), '亮屏 1 小时 5 分钟');
    });
  });

  group('③ 全缺隐藏：一行都取不到 → 整卡不显示', () {
    test('快照里没有任何可用字段 → null', () {
      final d = buildPeerStatusCard(
        peer: const PeerLatest(lat: 39.9, lng: 116.4, updated: null),
        now: _now,
      );
      expect(d, isNull, reason: '全空还渲染就是空壳卡');
    });

    test('对方从无快照（peer=null）→ null', () {
      expect(buildPeerStatusCard(peer: null, daily: _daily(), now: _now), isNull,
          reason: '没有快照就没有任何数，daily 也不许单独撑起一张卡');
    });

    test('时间戳 0 不算有效活跃（0 不是合法时间哨兵）', () {
      final d = buildPeerStatusCard(
        peer: _peer(battery: null, net: null, updated: 0, stateUpdated: 0),
        now: _now,
      );
      expect(d, isNull);
    });
  });

  group('④ 超 6 小时警告', () {
    test('7 小时前 → 明写「长时间无更新」+ 警示标记', () {
      final d = buildPeerStatusCard(
        peer: _peer(updated: _ts(const Duration(hours: 7))),
        now: _now,
      );
      expect(d!.stale, isTrue);
      final row = d.rows.firstWhere((r) => r.id == 'active');
      expect(row.warn, isTrue);
      expect(row.value, contains('长时间无更新'));
      expect(row.value, contains('最近一次 2026-11-26 16:00'));
    });

    test('5 小时 59 分 → 不算超时（不误报）', () {
      final d = buildPeerStatusCard(
        peer: _peer(updated: _ts(const Duration(hours: 5, minutes: 59))),
        now: _now,
      );
      expect(d!.stale, isFalse);
      expect(_value(d, 'active'), isNot(contains('长时间无更新')));
    });

    test('正好 6 小时 → 不算「超过」（严格大于）', () {
      final d = buildPeerStatusCard(
        peer: _peer(updated: _ts(const Duration(hours: 6))),
        now: _now,
      );
      expect(d!.stale, isFalse);
    });

    test('状态快照比定位新 → 取状态时刻，不误判失联', () {
      final d = buildPeerStatusCard(
        peer: _peer(
          updated: _ts(const Duration(hours: 30)),
          stateUpdated: _ts(const Duration(minutes: 5)),
        ),
        now: _now,
      );
      expect(d!.stale, isFalse);
      expect(_value(d, 'active'), startsWith('5 分钟前 · '));
    });

    test('定位比状态新 → 取定位时刻', () {
      final d = buildPeerStatusCard(
        peer: _peer(
          updated: _ts(const Duration(minutes: 3)),
          stateUpdated: _ts(const Duration(hours: 20)),
        ),
        now: _now,
      );
      expect(_value(d, 'active'), startsWith('3 分钟前 · '));
    });
  });
}
