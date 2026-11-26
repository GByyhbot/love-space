/// 2.8.7 动态加权预测 · App 侧对拍（与 Node `tests/period_weighted_287.mjs`
/// 读**同一份**夹具 `test/fixtures/period_weighted_cases.json`）。
///
/// 覆盖令文要求的四类断言（各自有独立用例，夹具也覆盖同样场景）：
/// ① 近期加权靠拢（近 3 次 33 天会把预测拉过 30）
/// ② 离群剔除（52 天被剔）
/// ③ 零样本回落（28 / 5 / predictionSampleCount=0）
/// ④ 超期天数（overdueDays=3）
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/features/period/period_engine.dart';

const String _fixturePath = 'test/fixtures/period_weighted_cases.json';

/// 与 JS 侧 `noonTs` 同口径：某日 +08:00 的 12:00 的 epoch 秒。
double _noonTs(String iso) {
  final d = DateTime.parse('${iso}T12:00:00+08:00');
  return d.millisecondsSinceEpoch / 1000.0;
}

List<PeriodRow> _rowsFrom(List<dynamic> specs) {
  final rows = <PeriodRow>[];
  for (var i = 0; i < specs.length; i++) {
    final s = specs[i] as Map<String, dynamic>;
    rows.add(PeriodRow(
      id: 'r$i',
      author: 'u1',
      body: <String, dynamic>{
        'start': s['start'],
        'length': s['length'],
        if (s['cycle'] != null) 'cycle': s['cycle'],
      },
      updated: _noonTs(s['start'] as String),
    ));
  }
  return rows;
}

void main() {
  final fixture = jsonDecode(File(_fixturePath).readAsStringSync())
      as Map<String, dynamic>;
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  test('夹具文件存在且非空（双端共用）', () {
    expect(cases.length, greaterThanOrEqualTo(4));
  });

  group('夹具逐例对拍（与 Node 同断言）', () {
    for (final c in cases) {
      test(c['name'] as String, () {
        final rows = _rowsFrom(c['records'] as List);
        final d = periodData(rows, today: c['today'] as String);
        final expectMap = c['expect'] as Map<String, dynamic>;
        expect(d.cycle, expectMap['cycle'], reason: 'cycle');
        expect(d.length, expectMap['length'], reason: 'length');
        expect(d.predictionSampleCount, expectMap['predictionSampleCount'],
            reason: 'predictionSampleCount');
        expect(d.cycleSpread, expectMap['cycleSpread'], reason: 'cycleSpread');
        expect(d.overdueDays, expectMap['overdueDays'], reason: 'overdueDays');
      });
    }
  });

  group('令文四条显式断言', () {
    test('① 近期加权：3 次 28 + 近 3 次 33 → 预测 > 30（且高于纯平均）', () {
      final rows = _rowsFrom([
        {'start': '2026-01-01', 'length': 5},
        {'start': '2026-01-29', 'length': 5},
        {'start': '2026-02-26', 'length': 5},
        {'start': '2026-03-26', 'length': 5},
        {'start': '2026-04-28', 'length': 5},
        {'start': '2026-05-31', 'length': 5},
        {'start': '2026-07-03', 'length': 5},
      ]);
      final d = periodData(rows, today: '2026-07-05');
      expect(d.cycle, greaterThan(30));
      // 纯平均 30.5→31；加权必须更靠近端（32）
      expect(d.cycle, 32);
    });

    test('② 离群：[28,29,28,52,29] → 52 被剔，预测 28 或 29', () {
      final rows = _rowsFrom([
        {'start': '2026-01-01', 'length': 5},
        {'start': '2026-01-29', 'length': 5},
        {'start': '2026-02-27', 'length': 5},
        {'start': '2026-03-27', 'length': 5},
        {'start': '2026-05-18', 'length': 5},
        {'start': '2026-06-16', 'length': 5},
      ]);
      final d = periodData(rows, today: '2026-06-18');
      expect(d.cycle, anyOf(28, 29));
      expect(d.cycle, 29, reason: '剔除后 4 个样本加权=28.55→29');
      expect(d.predictionSampleCount, 4, reason: '被剔样本不参与校准计数');
    });

    test('③ 零样本回落：28 / 5 / predictionSampleCount=0 / spread=null', () {
      final rows = _rowsFrom([
        {'start': '2026-11-01', 'length': 5},
      ]);
      final d = periodData(rows, today: '2026-11-03');
      expect(d.cycle, 28);
      expect(d.length, 5);
      expect(d.predictionSampleCount, 0);
      expect(d.cycleSpread, isNull);
    });

    test('④ 超期：过 nextStart 3 天 → overdueDays == 3', () {
      final rows = _rowsFrom([
        {'start': '2026-08-03', 'length': 5},
        {'start': '2026-08-31', 'length': 5},
        {'start': '2026-09-28', 'length': 5},
        {'start': '2026-10-26', 'length': 1},
      ]);
      final d = periodData(rows, today: '2026-11-26');
      expect(d.overdueDays, 3);
      expect(d.pending, isNull, reason: '超待确认窗自动定稿，不该同时报推迟+待确认');
    });

    test('在经期内不报超期（overdue 与「还在经期」互斥）', () {
      final rows = _rowsFrom([
        {'start': '2026-08-03', 'length': 5},
        {'start': '2026-08-31', 'length': 5},
        {'start': '2026-09-28', 'length': 5},
        {'start': '2026-11-24', 'length': 5},
      ]);
      final d = periodData(rows, today: '2026-11-26');
      expect(d.inWindow, isTrue);
      expect(d.overdueDays, 0);
    });
  });
}
