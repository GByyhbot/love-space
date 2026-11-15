/* 条目 8 · 段 C · 分析对拍硬门槛：Dart 统计层 × Web `static/period.js` 逐项全等。
   🔴 期望值**全部来自 Web 公式实跑**，绝不手算、绝不 Dart 硬编码：
   · 生成方式：`node app-flutter/tool/gen_period_c_expected.js`（一次性脚本，
     跑完即删；全文抄进 `docs/settings-period-plan.md` 附录 C.1）。Node `vm`
     把 `static/period.js` 整份源码与求值 IIFE 拼成**同一 script** 跑在沙箱里，
     `periodAnalysis` / `periodAnalysisPage` / `paGrouped` / `paVBars` /
     `paLine` / `paDotRows` / `periodData` 全是 Web 原函数，不被 mock 覆盖；
     只注入 recordsOf / today / state / esc / button / icon / console 七个全局。
   · `test/fixtures/period_c_expected.json` 是 Web 实跑期望值（meta 记
     source / method / functions / sandboxGlobals / casesSources / today）。
   · 夹具：`test/fixtures/period_cases.json` 三组（multiCycle / singleNoGap /
     fragmentMerge）+ `test/fixtures/period_c_cases.json` 八组新增
     （score=null / 完整度边界 / 体温体重 >1 条 / 空态 / 波动档位…）。
   · 逐项：periodAnalysis 全结构（complete/slots/filled/score/sd/flow/pain/
     color/discharge/cycleRows/cycleMax/sexCount/sexThisCycle/monthly/symCount/moodCount/
     temp/weight）+ periodAnalysisPage 13 板块全部文案/数字 + 6 张手画图
     的 SVG 几何（rect/line/path/circle/text 坐标逐项全等）。
   · 运行前必须 unset 八个代理变量（flutter_tester 本地 WebSocket 会被
     127.0.0.1 代理劫持 → Invalid WebSocket upgrade request）。 */
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/features/period/period_analysis.dart';
import 'package:love_space/features/period/period_engine.dart';

Map<String, dynamic> _load(String name) => jsonDecode(
      File('test/fixtures/$name').readAsStringSync(),
    ) as Map<String, dynamic>;

List<PeriodRow> _rows(Object? raw) => (raw as List)
    .map((e) => PeriodRow.fromJson((e as Map).cast<String, dynamic>()))
    .toList();

/// 深度比对：Map 逐键、List 逐项、num 用数值等价（int/double 不敏感）、
/// 字符串/bool/null 严格相等；不匹配时打印完整路径，方便定位。
void _assertDeep(Object? actual, Object? expected, String path) {
  if (expected is Map) {
    expect(actual, isA<Map>(), reason: '$path 应为 Map');
    final a = (actual! as Map).cast<String, dynamic>();
    final e = expected.cast<String, dynamic>();
    expect(a.keys.toSet(), e.keys.toSet(), reason: '$path · 键集合全等');
    for (final k in e.keys) {
      _assertDeep(a[k], e[k], '$path.$k');
    }
    return;
  }
  if (expected is List) {
    expect(actual, isA<List>(), reason: '$path 应为 List');
    final a = actual! as List;
    expect(a.length, expected.length, reason: '$path · 长度全等');
    for (var i = 0; i < expected.length; i++) {
      _assertDeep(a[i], expected[i], '$path[$i]');
    }
    return;
  }
  if (expected is num) {
    expect(actual, isA<num>(), reason: '$path 应为 num');
    final av = (actual! as num).toDouble();
    final ev = expected.toDouble();
    if ((av - ev).abs() > 1e-9) {
      fail('$path · 数值不等：Web=$expected Dart=$actual');
    }
    return;
  }
  expect(actual, expected, reason: '$path · 全等');
}

void main() {
  final expected = _load('period_c_expected.json');
  final aCases = _load('period_cases.json');
  final cCases = _load('period_c_cases.json');

  // meta：证明期望值来自 Web 实跑而非手算。
  group('期望值来源（Web 实跑，不许手算）', () {
    test('meta 记 source / method / functions / sandboxGlobals / today', () {
      final meta = (expected['meta'] as Map).cast<String, dynamic>();
      expect(meta['source'], 'static/period.js');
      expect(meta['method'], contains('Web original functions'));
      expect(meta['note'], contains('不许手算'));
      expect(meta['today'], '2026-11-14');
      final globals = (meta['sandboxGlobals'] as List).cast<String>();
      expect(globals.toSet(), <String>{
        'recordsOf', 'today', 'state', 'esc', 'button', 'icon', 'console',
      });
      final functions = (meta['functions'] as List).cast<String>();
      for (final f in <String>[
        'periodData', 'periodAnalysis', 'periodAnalysisPage', 'periodWarnings',
        'paMean', 'paSd', 'paRound', 'paMD', 'paGrouped', 'paVBars', 'paLine',
        'paDotRows',
      ]) {
        expect(functions, contains(f), reason: '$f 必须是 Web 原函数');
      }
      expect((meta['casesSources'] as List).length, 2);
    });

    test('夹具沿用 8-A 三组 + C 段八组新增', () {
      final reuse = (cCases['meta'] as Map)['reuseFromPeriodCases'] as List;
      expect(reuse.cast<String>(),
          <String>['multiCycle', 'singleNoGap', 'fragmentMerge']);
      final cases = (expected['cases'] as Map).keys.toSet();
      expect(cases.length, 11);
      for (final n in reuse) {
        expect(cases, contains(n));
      }
    });
  });

  // 汇总所有夹具（Node 与 Dart 用同一份 cases）。
  final allCases = <String, Map<String, dynamic>>{};
  for (final name in (cCases['meta'] as Map)['reuseFromPeriodCases'] as List) {
    final c = ((aCases['cases'] as Map)[name] as Map).cast<String, dynamic>();
    allCases[name as String] = c;
  }
  for (final entry in (cCases['cases'] as Map).entries) {
    allCases[entry.key as String] =
        (entry.value as Map).cast<String, dynamic>();
  }

  group('periodAnalysis / periodAnalysisPage 逐项全等（11 组夹具）', () {
    for (final entry in allCases.entries) {
      final name = entry.key;
      final c = entry.value;
      final exp = ((expected['cases'] as Map)[name] as Map)
          .cast<String, dynamic>();

      test('$name · 全结构 + 13 板块 + 图表几何逐项全等', () {
        final records = _rows(c['records']);
        final today = c['today'] as String;
        final d = periodData(records, today: today);
        final a = periodAnalysis(d, records, today: today);
        final view = buildAnalysisView(a, d);

        // ① `periodAnalysis(d)` 全结构（对齐 :666-669）。
        _assertDeep(a.toJson(), exp['analysis'], '$name.analysis');
        // ② `periodData()` 派生字段 + 预警。
        _assertDeep(
            analysisDataJson(d, records), exp['data'], '$name.data');
        // ③ `periodAnalysisPage()` 13 板块全部文案/数字 + 6 张 SVG 几何。
        _assertDeep(view.toJson(), exp['page'], '$name.page');
      });
    }
  });

  // 分档护栏：score=null（gaps<2）绝不硬编分数；五档 grade 全覆盖。
  group('规律度分档护栏（:663-665 / :684）', () {
    final Map<String, int?> scores = <String, int?>{
      for (final e in (expected['cases'] as Map).entries)
        e.key as String:
            ((e.value as Map)['analysis'] as Map)['score'] as int?,
    };
    final Map<String, String> grades = <String, String>{
      for (final e in (expected['cases'] as Map).entries)
        e.key as String:
            ((((e.value as Map)['page'] as Map)['overview'] as Map?)?['grade']
                    ?.toString()) ??
                '',
    };

    test('gaps<2 的四组 score 必为 null、grade 必为「样本还太少」', () {
      for (final name in <String>[
        'singleNoGap', 'fragmentMerge', 'scoreNullTwoEps', 'flowPainNoHist',
        'noFlowPain', 'empty',
      ]) {
        final records = _rows(allCases[name]!['records']);
        final d = periodData(records, today: allCases[name]!['today'] as String);
        expect(d.gaps.length < 2, isTrue, reason: '$name 应是 gaps<2 夹具');
        expect(periodAnalysis(d, records, today: allCases[name]!['today'] as String).score,
            isNull,
            reason: '$name · gaps<2 不许硬编分数');
        expect(scores[name], isNull, reason: '$name · Web 实跑也应为 null');
        if (grades[name]!.isNotEmpty) {
          expect(grades[name], '样本还太少');
        }
      }
    });

    test('gaps>=2 的四档 grade 与 Web 实跑逐字一致', () {
      final seen = <String>{};
      for (final name in allCases.keys) {
        final records = _rows(allCases[name]!['records']);
        final today = allCases[name]!['today'] as String;
        final d = periodData(records, today: today);
        final a = periodAnalysis(d, records, today: today);
        final g = buildAnalysisView(a, d).overview?.grade;
        if (g != null) {
          seen.add(g);
          expect(g, grades[name], reason: '$name grade 与 Web 实跑全等');
        }
        expect(a.score, scores[name], reason: '$name score 与 Web 实跑全等');
      }
      expect(seen, containsAll(<String>['很规律', '比较规律', '有些波动', '样本还太少']),
          reason: '五档覆盖（波动明显需 sd 极大，夹具不含该极端）');
    });

    test('sd / score 公式逐字：multiCycle 的 Web 实跑值', () {
      final c = allCases['multiCycle']!;
      final records = _rows(c['records']);
      final d = periodData(records, today: c['today'] as String);
      final a = periodAnalysis(d, records, today: c['today'] as String);
      expect(d.gaps, <int>[27, 28, 29]);
      expect(a.sd, closeTo(0.816496580927726, 1e-12));
      expect(a.score, 99);
      expect(paSd(<num>[27, 28, 29]), closeTo(0.816496580927726, 1e-12));
      expect(paRound(a.sd, 1), closeTo(0.8, 1e-12));
      expect(paMD('2026-09-21'), '9 月 21 日');
    });
  });

  // 图表件护栏：SVG 几何非空且坐标来自 Web 实跑（非手算）。
  group('图表件 paGrouped/paVBars/paLine 与 Web 几何全等', () {
    test('analysisRich 六张图、元素数量与坐标逐项可复核', () {
      final c = allCases['analysisRich']!;
      final records = _rows(c['records']);
      final d = periodData(records, today: c['today'] as String);
      final a = periodAnalysis(d, records, today: c['today'] as String);
      final view = buildAnalysisView(a, d);
      expect(view.svgs.length, 6);
      final expSvgs = ((expected['cases'] as Map)['analysisRich'] as Map)['page']
          as Map;
      final list = expSvgs['svgs'] as List;
      expect(list.length, 6);
      // 抽查第一张 paVBars 的基线 y（Web 实跑 74）与第一根柱坐标。
      final first = (list[0] as Map)['els'] as List;
      expect((first[0] as Map)['attrs']['y1'], '74');
      expect((first[1] as Map)['attrs']['x'], '31.0');
      expect((first[1] as Map)['attrs']['height'], '51.7');
      // 抽查 paLine 折线 path（体温）：Web 实跑 M18.0 60.7 …。
      final line = (list[4] as Map)['els'] as List;
      final path = (line[1] as Map)['attrs']['d'] as String;
      expect(path, startsWith('M18.0 60.7'));
      expect(path, endsWith('L302.0 18.0'));
    });

    test('paLine 少于 2 点返回 null（Web :565 等价）', () {
      expect(paLine(<PaSeriesPoint>[const PaSeriesPoint('01/01', 36.5)]), isNull);
      expect(
          paLine(<PaSeriesPoint>[
            const PaSeriesPoint('01/01', 36.5),
            const PaSeriesPoint('01/02', 36.7),
          ]),
          isNotNull);
    });
  });
}
