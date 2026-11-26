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

  group('围栏：usage/top_apps 不许被消费', () {
    test('lib/ 内无 top_apps 写入、无 usage 开关读取', () {
      // 范围限定「采集与上报路径」：设置页里渲染 usage 开关是 2.8.0 既有行为
      // （展示 ≠ 消费），本阶段新增的采集器不许碰它——这才是围栏要钉的。
      final scoped = <String>[
        'lib/core/peer',
        'lib/features/together/peer_report_page.dart',
      ];
      final files = <File>[];
      for (final path in scoped) {
        final f = File(path);
        if (f.existsSync()) {
          files.add(f);
        } else {
          files.addAll(Directory(path)
              .listSync(recursive: true)
              .whereType<File>()
              .where((x) => x.path.endsWith('.dart')));
        }
      }
      final offenders = <String>[];
      for (final f in files) {
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final code = lines[i].split('//').first; // 行注释不算证据
          if (code.trim().isEmpty) continue;
          if (code.contains('top_apps')) {
            offenders.add('${f.path}:${i + 1}: ${lines[i].trim()}');
          }
          // usage 开关：只允许出现在 PeerShareSettings 的字段声明/序列化里，
          // 业务代码读 `settings.usage` 一律算越界（本阶段不消费）
          if (RegExp(r'\.usage\b').hasMatch(code) &&
              !code.contains('this.usage') &&
              !code.contains('usage ??') &&
              !code.contains('usage:') &&
              !code.contains('other.usage') &&
              !code.contains('final bool usage')) {
            offenders.add('${f.path}:${i + 1}: ${lines[i].trim()}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: '采集/上报路径不许消费 usage/top_apps，越界处：$offenders');
    });
  });
}
