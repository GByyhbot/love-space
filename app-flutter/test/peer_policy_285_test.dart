/// 2.8.7 全量施工令 · 步 B 护栏（客户端）：策略模型 / 脱敏复核 / 队列清理。
///
/// 三件事必须钉住：
/// ① policy 解析与服务端同构（缺键即缺省；停用判定含暂停到期）；
/// ② 入队前的脱敏复核：命中敏感清单/自称 masked 却带真实包名 → 一律拦下；
/// ③ 暂停生效时队列只清遥测，**手动报备一条不动**。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/peer/peer_policy.dart';
import 'package:love_space/core/peer/peer_report_queue.dart';
import 'package:love_space/core/peer/peer_state_collector.dart';

PendingReport _item({
  required String clientId,
  String scene = '',
  String kind = '',
  Map<String, Object?>? payload,
}) =>
    PendingReport(
      scene: scene,
      clientId: clientId,
      createdAt: 1,
      kind: kind,
      payload: payload,
    );

void main() {
  group('① 策略模型（与服务端 DEFAULT_POLICY 同构）', () {
    test('空对象解析成全最高档（不是全关）', () {
      final p = PeerPolicy.fromJson(const <String, Object?>{});
      expect(p.locLevel, LocLevel.exact);
      expect(p.usageLevel, UsageLevel.full);
      expect(p.appLevel, AppLevel.stream);
      expect(p.netLevel, NetLevel.ssid);
      expect(p.battery, isTrue);
      expect(p.batteryAlert, isTrue);
      expect(p.foldShort, isTrue);
      expect(p.globalOff, isFalse);
      expect(p.pausedUntil, isNull);
      expect(p.sensitivePkgs, isEmpty);
    });

    test('非法档位回落缺省，不炸', () {
      final p = PeerPolicy.fromJson(const {
        'location_level': 'ultra',
        'usage_level': 42,
        'app_level': null,
        'network_level': 'ssid',
        'paused_until': -5,
        'battery': 'yes',
      });
      expect(p.locLevel, LocLevel.exact);
      expect(p.usageLevel, UsageLevel.full);
      expect(p.appLevel, AppLevel.stream);
      expect(p.netLevel, NetLevel.ssid);
      expect(p.pausedUntil, isNull, reason: '负值不是合法截止时刻');
      expect(p.battery, isTrue, reason: '非 bool 按缺省');
    });

    test('序列化恒 10 键且能往返', () {
      final p = PeerPolicy.fromJson(const {
        'location_level': 'street',
        'usage_level': 'screen_only',
        'app_level': 'top5',
        'network_level': 'type_only',
        'sensitive_pkgs': ['com.a', '', 'com.b'],
        'fold_short': false,
      });
      expect(p.sensitivePkgs, ['com.a', 'com.b'], reason: '空串要被滤掉');
      final back = PeerPolicy.fromJson(p.toJson());
      expect(back, p);
      expect(p.toJson().keys.toSet().length, 10);
    });

    test('停用判定：全局关闭 / 暂停未到期 / 暂停已过期', () {
      final now = DateTime(2026, 11, 27, 12);
      final off = PeerPolicy.defaults.copyWith(globalOff: true);
      expect(off.haltedAt(now), isTrue);
      expect(off.haltedReasonAt(now), 'off');

      final paused = PeerPolicy.defaults.copyWith(
        pausedUntil: pauseUntilHours(now, 2),
      );
      expect(paused.haltedAt(now), isTrue);
      expect(paused.haltedReasonAt(now), 'paused');
      // 两小时后到期
      expect(paused.haltedAt(now.add(const Duration(hours: 3))), isFalse);
      expect(paused.haltedReasonAt(now.add(const Duration(hours: 3))), '');
    });

    test('暂停到明早 8 点：过了今天 8 点就落到明天', () {
      final early = DateTime(2026, 11, 27, 3);
      final u1 = pauseUntilNextMorning(early);
      expect(DateTime.fromMillisecondsSinceEpoch((u1 * 1000).round()).day, 27);

      final late = DateTime(2026, 11, 27, 23);
      final u2 = pauseUntilNextMorning(late);
      final at2 = DateTime.fromMillisecondsSinceEpoch((u2 * 1000).round());
      expect(at2.day, 28);
      expect(at2.hour, 8);
    });
  });

  group('② 脱敏复核（入队之前）', () {
    test('未命中：原样通过', () {
      final p = sanitizeTelemetryPayload(
        'usage.session',
        {'pkg': 'com.wechat', 'app': '微信', 'dur': 60},
        policy: PeerPolicy.defaults,
      );
      expect(p!['pkg'], 'com.wechat');
      expect(p['masked'], isNull);
    });

    test('命中敏感清单：改写哨兵 + masked', () {
      final p = sanitizeTelemetryPayload(
        'usage.session',
        {'pkg': 'com.secret', 'app': '秘密', 'dur': 60},
        policy: PeerPolicy.defaults
            .copyWith(sensitivePkgs: const ['com.secret']),
      );
      expect(p!['pkg'], kMaskedPkg);
      expect(p['app'], kMaskedAppName);
      expect(p['masked'], isTrue);
      expect(p.toString().contains('com.secret'), isFalse,
          reason: '真实包名不许留在载荷里');
    });

    test('自称 masked 却带真实包名：整条拦掉（返回 null）', () {
      expect(
        sanitizeTelemetryPayload(
          'usage.session',
          {'pkg': 'com.wechat', 'app': '微信', 'masked': true},
          policy: PeerPolicy.defaults,
        ),
        isNull,
      );
    });

    test('自称 masked + 哨兵：通过且强制改写 app 名', () {
      final p = sanitizeTelemetryPayload(
        'usage.session',
        {'pkg': kMaskedPkg, 'app': '微信', 'masked': true},
        policy: PeerPolicy.defaults,
      );
      expect(p!['app'], kMaskedAppName);
    });

    test('状态事件不经脱敏逻辑（原样返回）', () {
      final raw = {'level': 80, 'charging': false};
      expect(sanitizeTelemetryPayload('state.battery', raw), raw);
    });
  });

  group('③ 暂停清队列：只清遥测，手动报备保留', () {
    late Directory tmp;
    late ReportOutbox outbox;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('outbox-285-');
      outbox = ReportOutbox(dirProvider: () async => tmp);
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('clearTelemetry 保留手动条目', () async {
      await outbox.enqueue(_item(clientId: 'm1', scene: 'miss'));
      await outbox.enqueue(_item(clientId: 's1', kind: 'state.battery'));
      await outbox.enqueue(_item(clientId: 'u1', kind: 'usage.session'));
      await outbox.enqueue(_item(clientId: 'u2', kind: 'usage.now'));

      final removed = await outbox.clearTelemetry();
      expect(removed, 3);
      final left = await outbox.load();
      expect(left.map((e) => e.clientId).toList(), ['m1']);
      expect(await outbox.telemetryCount(), 0);
    });

    test('没有遥测时不动文件', () async {
      await outbox.enqueue(_item(clientId: 'm1', scene: 'miss'));
      expect(await outbox.clearTelemetry(), 0);
      expect((await outbox.load()).length, 1);
    });

    test('isTelemetry 判定覆盖 state./usage. 两类', () {
      expect(_item(clientId: 'a', kind: 'state.net').isTelemetry, isTrue);
      expect(_item(clientId: 'b', kind: 'usage.session').isTelemetry, isTrue);
      expect(_item(clientId: 'c', scene: 'miss').isTelemetry, isFalse);
    });
  });
}
