/* 条目 8 · 段 8-B · 验收点①硬门槛：App 整月网格逐日 × Web `periodMonthGrid` 实跑全等。
   🔴 期望值**全部来自 Web 原函数实跑**，绝不手算、绝不 Dart 硬编码：
   · 生成：node app-flutter/tool/gen_period_b_expected.js（一次性脚本，全文抄进
     docs/settings-period-plan.md 附录 B.1，跑完即删）。
   · Node vm 把 static/period.js 整份源码 + 求值 IIFE 拼成**同一 script**，
     网格 sandbox 只注入 recordsOf(kind) / today() / state 三类全局；
     periodMonthGrid / periodData / cyclePhases / periodDayLogs 全是 Web 原函数，
     未被 mock 覆盖。期望值由 periodMonthGrid 真实产出的 HTML 逐日抽出
     class / title / aria-label 得到。
   · 夹具：8-A 的 period_cases.json `multiCycle`（含预测经期与排卵日）+
     period_b_cases.json 的 8 个月份；逐日断言 phase / predicted / ovu /
     has-rec / has-log / 是否阶段首日 / is-today / picked 的 class 集合全等。
   · 运行前必须 unset 八个代理变量（flutter_tester 本地 WebSocket 被
     127.0.0.1 代理劫持 → Invalid WebSocket upgrade request）。
*/
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/features/period/period_engine.dart';
import 'package:love_space/features/period/period_grid.dart';

Map<String, dynamic> _load(String name) => jsonDecode(
      File('test/fixtures/$name').readAsStringSync(),
    ) as Map<String, dynamic>;

List<PeriodRow> _rows(Object? raw) => (raw as List)
    .map((e) => PeriodRow.fromJson((e as Map).cast<String, dynamic>()))
    .toList();

void main() {
  final aCases = _load('period_cases.json');
  final bCases = _load('period_b_cases.json');
  final expected = _load('period_b_expected.json');
  final multi = (aCases['cases'] as Map)['multiCycle'] as Map;
  final multiRecords = _rows(multi['records']);
  final multiToday = multi['today'] as String;
  final grids = (expected['grids'] as Map).cast<String, dynamic>();

  test('期望值来源自证：meta 标明 Web periodMonthGrid 原函数实跑', () {
    final meta = (expected['meta'] as Map).cast<String, dynamic>();
    expect(meta['source'], 'static/period.js');
    expect(meta['gridSourceCase'], 'multiCycle');
    expect(meta['today'], '2026-11-14');
    expect((meta['functions'] as List).contains('periodMonthGrid'), isTrue);
    expect((meta['functions'] as List).contains('periodData'), isTrue);
    expect((meta['functions'] as List).contains('cyclePhases'), isTrue);
    expect((meta['gridSandboxGlobals'] as List).toSet(),
        {'recordsOf', 'today', 'state', 'console'},
        reason: '网格 sandbox 严格只注入三类全局（+console）');
  });

  final months = (bCases['grid'] as Map)['months'] as List;
  for (final raw in months) {
    final g = (raw as Map).cast<String, dynamic>();
    final y = g['y'] as int;
    final m = g['m'] as int;
    final picked = g['picked'] as String;
    final key = '$y-${m.toString().padLeft(2, '0')}';
    test('网格逐日对拍 · $key · Web 实跑 class 集合全等', () {
      final d = periodData(multiRecords, today: multiToday);
      final grid = buildPeriodMonthGrid(
        year: y,
        month: m,
        d: d,
        records: multiRecords,
        today: multiToday,
        picked: picked,
      );
      final e = (grids[key] as Map).cast<String, dynamic>();
      final expCells = (e['cells'] as Map).cast<String, dynamic>();

      expect(grid.lead, e['lead'], reason: '$key · lead（月初前置空格）');
      expect(grid.days, e['days'], reason: '$key · days（当月天数）');
      expect(grid.cells.length, e['days']);
      expect(expCells.length, e['days'],
          reason: '$key · Web 期望值必须逐日齐全');

      for (final cell in grid.cells) {
        final ec = expCells[cell.iso];
        expect(ec, isNotNull, reason: '$key · ${cell.iso} 期望值缺失');
        final em = (ec! as Map).cast<String, dynamic>();
        final expClasses = (em['classes'] as List).cast<String>();
        expect(cell.classes, expClasses,
            reason: '$key · ${cell.iso} class 集合（阶段/预测/排卵日/'
                '记录点/是否阶段首日/is-today/picked）');
        expect(cell.tip, em['title'],
            reason: '$key · ${cell.iso} tip 逐字');
        expect(cell.ariaLabel, em['aria'],
            reason: '$key · ${cell.iso} aria-label 逐字');
      }
    });
  }

  test('prevPhase 边界：月初第一天不误标 ph-start（period.js:179 实跑证据）', () {
    // 2026-07-01 承接 06-28 那次经期的「月经期」，Web 实跑无 ph-start。
    final jul = (grids['2026-07'] as Map)['cells'] as Map;
    final first = (jul['2026-07-01'] as Map)['classes'] as List;
    expect(first.contains('ph-period'), isTrue);
    expect(first.contains('ph-start'), isFalse,
        reason: '若不取上月最后一天 phase，1 号会被误标成阶段首日');
    // 预测经期开始日（2026-11-16）必须标 ph-start。
    final nov = (grids['2026-11'] as Map)['cells'] as Map;
    final start = (nov['2026-11-16'] as Map)['classes'] as List;
    expect(start.contains('ph-period'), isTrue);
    expect(start.contains('ph-pred'), isTrue);
    expect(start.contains('ph-start'), isTrue);
  });

  test('覆盖度自证：8 个月 × 逐日 = 245 格，含预测/排卵/记录点', () {
    var total = 0;
    var pred = 0;
    var ovu = 0;
    var rec = 0;
    var log = 0;
    var start = 0;
    for (final raw in grids.values) {
      final cells = ((raw as Map)['cells'] as Map).values;
      for (final c in cells) {
        final cls = ((c as Map)['classes'] as List).cast<String>();
        total++;
        if (cls.contains('ph-pred')) pred++;
        if (cls.contains('ph-ovu')) ovu++;
        if (cls.contains('has-rec')) rec++;
        if (cls.contains('has-log')) log++;
        if (cls.contains('ph-start')) start++;
      }
    }
    expect(total, 245, reason: '8 个月总天数');
    expect(pred, greaterThan(0), reason: '必须覆盖预测经期');
    expect(ovu, greaterThan(0), reason: '必须覆盖排卵日');
    expect(rec, greaterThan(0), reason: '必须覆盖经期开始记录点');
    expect(log, greaterThan(0), reason: '必须覆盖日记录点');
    expect(start, greaterThan(0), reason: '必须覆盖阶段首日');
  });

  test('shiftMonth 逐项与 Web 实跑全等（含月末夹取）', () {
    final sweep = (expected['shiftMonth'] as List)
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    expect(sweep.length, 7);
    for (final s in sweep) {
      expect(shiftMonth(s['day'] as String, s['delta'] as int), s['result'],
          reason: 'shiftMonth(${s['day']}, ${s['delta']})');
    }
  });

  test('网格源码级护栏：不读 DateTime.now() / 不读本机时区 / 只用引擎阶段', () {
    final src = File('lib/features/period/period_grid.dart').readAsStringSync();
    final code = src
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .where((line) => !line.trimLeft().startsWith('///'))
        .join('\n');
    expect(code.contains('DateTime.now()'), isFalse,
        reason: '网格不得读真实时钟');
    expect(code.contains('.toLocal()'), isFalse,
        reason: '网格不得用本机时区');
    expect(code.contains('cyclePhases(d)'), isTrue,
        reason: '阶段着色只调引擎 cyclePhases');
    expect(code.contains('dayStr('), isTrue);
    expect(code.contains('dayNum('), isTrue);
  });
}
