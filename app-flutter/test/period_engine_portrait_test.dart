/* 条目 8 · 段 8-A · D2 硬门槛：Dart 引擎 × Web `static/period.js` 逐项对拍。
   🔴 期望值**全部来自 Web 公式实跑**，绝不手算：
   · 生成方式：`node app-flutter/tool/gen_period_expected.js`（一次性脚本，
     跑完即删；全文抄进 `docs/settings-period-plan.md` 定案文档「对拍结论」小节）。
     Node `vm` 把 `static/period.js` 整份源码与求值 IIFE 拼成**同一 script**
     跑在沙箱里，只注入 `recordsOf(kind)` / `today()` / probes 三类全局，
     `dayNum/dayStr/periodData/cyclePhases/periodEpisodeOf` 全部是 Web 原函数
     （不被 mock 覆盖），期望值由它们实跑产出。
   · `test/fixtures/period_cases.json` 是 Node 与 Dart **共用的同一组夹具**；
     `test/fixtures/period_expected.json` 是 Web 实跑产出的期望值。
   · 三组必备夹具：① multiCycle 多周期正常组（≥2 episode、有效 gaps 15–60、
     混入双方作者 + 日记录行）；② singleNoGap 只有一条经期记录、无 gap，
     body.cycle=31（≠28）证明前端 `period.js:128` 回落 `body.cycle||28`，
     **后端 `period.py:325` 直接回落 28 的差异只留痕、不移植（C4 关闭）**；
     ③ fragmentMerge 同一次经期拆成 2–3 行合并 + owner 选择。
   · 逐项：平均周期 cycle / 平均经期 length / 下次预测 nextStart /
     四阶段边界（cyclePhases 逐日 phase + predicted + ovu 全量 key 集合） /
     今天是否经期 inWindow / 经期第几天 dayOfPeriod；另对拍
     untilNext / estimated / lastLen / gaps / episodes / periodEpisodeOf /
     todayPhase / 周期第 N 天 / dayNum / dayStr / `||28` 缺省分支。
   · 运行前必须 unset 八个代理变量（flutter_tester 本地 WebSocket 会被
     127.0.0.1 代理劫持 → Invalid WebSocket upgrade request）。 */
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/features/period/period_engine.dart';

Map<String, dynamic> _load(String name) => jsonDecode(
      File('test/fixtures/$name').readAsStringSync(),
    ) as Map<String, dynamic>;

List<PeriodRow> _rows(Object? raw) => (raw as List)
    .map((e) => PeriodRow.fromJson((e as Map).cast<String, dynamic>()))
    .toList();

void _checkCase(String name, Map<String, dynamic> c, Map<String, dynamic> e) {
  final records = _rows(c['records']);
  final today = c['today'] as String;
  final d = periodData(records, today: today);

  // ── 六项硬指标 ──────────────────────────────────────────────────
  expect(d.cycle, e['cycle'], reason: '$name · 平均周期 cycle');
  expect(d.length, e['length'], reason: '$name · 平均经期 length');
  expect(d.nextStart, e['nextStart'], reason: '$name · 下次预测 nextStart');
  expect(d.nextStartStr, e['nextStartIso'], reason: '$name · nextStart ISO');
  expect(d.inWindow, e['inWindow'], reason: '$name · 今天是否经期 inWindow');
  expect(d.dayOfPeriod, e['dayOfPeriod'], reason: '$name · 经期第几天 dayOfPeriod');

  // ── 其余 periodData 字段 ────────────────────────────────────────
  expect(d.todayN, e['todayN'], reason: '$name · todayN');
  expect(d.untilNext, e['untilNext'], reason: '$name · untilNext');
  expect(d.estimated, e['estimated'], reason: '$name · estimated');
  expect(d.lastLen, e['lastLen'], reason: '$name · lastLen');
  expect(d.gaps, e['gaps'], reason: '$name · gaps');
  expect(d.items.length, e['itemCount'], reason: '$name · 参与推算的经期行数');

  final expEps = (e['episodes'] as List)
      .map((x) => (x as Map).cast<String, dynamic>())
      .toList();
  expect(d.episodes.length, expEps.length, reason: '$name · 合并段数');
  for (var i = 0; i < d.episodes.length; i++) {
    expect(d.episodes[i].start, expEps[i]['start'],
        reason: '$name · episodes[$i].start');
    expect(d.episodes[i].end, expEps[i]['end'],
        reason: '$name · episodes[$i].end');
    expect(d.episodes[i].length, expEps[i]['length'],
        reason: '$name · episodes[$i].length');
  }

  // ── 四阶段边界：全量逐日 key 集合 + 每天 phase/predicted/ovu ─────
  final phases = cyclePhases(d);
  final expPh = (e['phases'] as Map).cast<String, dynamic>();
  expect(phases.keys.toSet(), expPh.keys.toSet(),
      reason: '$name · cyclePhases 逐日 key 集合全等');
  for (final entry in expPh.entries) {
    final v = (entry.value as Map).cast<String, dynamic>();
    final got = phases[entry.key];
    expect(got, isNotNull, reason: '$name · ${entry.key} 缺 phase');
    expect(got!.phase, v['phase'], reason: '$name · ${entry.key} phase');
    expect(got.predicted, v['predicted'],
        reason: '$name · ${entry.key} predicted');
    expect(got.ovu, v['ovu'], reason: '$name · ${entry.key} ovu 标记');
  }

  // ── 状态摘要另两项（也必须来自引擎，不许页面另写一套）────────────
  final expTp = e['todayPhase'];
  final tp = todayPhase(d, today: today);
  if (expTp == null) {
    expect(tp, isNull, reason: '$name · todayPhase 应为 null');
  } else {
    final tpm = (expTp as Map).cast<String, dynamic>();
    expect(tp, isNotNull, reason: '$name · todayPhase 不应为 null');
    expect(tp!.phase, tpm['phase'], reason: '$name · todayPhase.phase');
    expect(tp.predicted, tpm['predicted'],
        reason: '$name · todayPhase.predicted');
    expect(tp.ovu, tpm['ovu'], reason: '$name · todayPhase.ovu');
  }
  expect(dayInCycle(d), e['dayInCycle'], reason: '$name · 周期第 N 天');

  // ── periodEpisodeOf：ep 边界 + owner（哪个碎片）─────────────────
  for (final raw in (e['hits'] as List)) {
    final h = (raw as Map).cast<String, dynamic>();
    final n = h['n'] as int;
    // n 本身来自 Web 的 dayNum(iso)，顺带对拍 dayNum 语义。
    expect(dayNum(h['iso'] as String), n,
        reason: '$name · dayNum(${h['iso']}) 与 Web 一致');
    final got = periodEpisodeOf(d, n);
    if (h['hit'] == true) {
      expect(got, isNotNull, reason: '$name · n=$n 应命中段');
      expect(got!.ep.start, h['epStart'], reason: '$name · n=$n ep.start');
      expect(got.ep.end, h['epEnd'], reason: '$name · n=$n ep.end');
      expect(got.ep.length, h['epLength'], reason: '$name · n=$n ep.length');
      expect(got.owner.id, h['ownerId'], reason: '$name · n=$n owner.id');
    } else {
      expect(got, isNull, reason: '$name · n=$n 不应命中段');
    }
  }
}

void main() {
  final fixture = _load('period_cases.json');
  final expected = _load('period_expected.json');
  final cases = (fixture['cases'] as Map).cast<String, dynamic>();
  final expCases = (expected['cases'] as Map).cast<String, dynamic>();

  test('期望值来源自证：meta 标明 Web 原函数实跑', () {
    final meta = (expected['meta'] as Map).cast<String, dynamic>();
    expect(meta['source'], 'static/period.js');
    expect((meta['functions'] as List).toSet(), {
      'periodData', 'periodEpisodeOf', 'cyclePhases', 'dayNum', 'dayStr',
    });
    expect(meta['today'], '2026-11-14');
  });

  for (final name in const ['multiCycle', 'singleNoGap', 'fragmentMerge']) {
    test('对拍 · $name · 三组夹具逐项全等', () {
      _checkCase(
        name,
        (cases[name] as Map).cast<String, dynamic>(),
        (expCases[name] as Map).cast<String, dynamic>(),
      );
    });
  }

  test('dayNum / dayStr 样本逐项全等（period.js:30-31 实读移植）', () {
    final dns = (expected['dayNumSamples'] as Map).cast<String, dynamic>();
    dns.forEach((s, v) => expect(dayNum(s), v, reason: 'dayNum($s)'));
    final dss = (expected['dayStrSamples'] as Map).cast<String, dynamic>();
    dss.forEach((k, v) =>
        expect(dayStr(int.parse(k)), v, reason: 'dayStr($k)'));
  });

  test('C4 关闭：无有效 gap 以前端 body.cycle||28 为准（后端硬 28 只留痕）', () {
    final c = (cases['singleNoGap'] as Map).cast<String, dynamic>();
    final e = (expCases['singleNoGap'] as Map).cast<String, dynamic>();
    final records = _rows(c['records']);
    final today = c['today'] as String;
    final d = periodData(records, today: today);

    // 前端 period.js:128 回落 body.cycle=31（≠后端 period.py:325 的直接 28）。
    expect(d.gaps, isEmpty, reason: 'singleNoGap 必须真的没有任何有效 gap');
    expect(d.estimated, isTrue);
    expect(d.cycle, 31, reason: '必须回落记录自带 cycle，不能硬编码 28');
    expect(d.cycle, isNot(28), reason: '后端口径不移植');
    expect(e['cycle'], 31, reason: 'Web 实跑期望值同样是 31');

    // `||28` 的缺省分支：删掉 cycle 后由 Web 公式实跑得到 28（非手算）。
    final noCycle = records
        .map((r) {
          final b = Map<String, dynamic>.from(r.body)..remove('cycle');
          return PeriodRow(id: r.id, author: r.author, body: b);
        })
        .toList();
    final fd = periodData(noCycle, today: today);
    final fb = (expected['fallback28'] as Map).cast<String, dynamic>();
    expect(fd.cycle, fb['cycle'], reason: '||28 缺省分支与 Web 实跑全等');
    expect(fd.nextStart, fb['nextStart']);
    expect(fd.nextStartStr, fb['nextStartIso']);
  });

  test('两种记录形状分别解析：日记录不参与推算、绝不虚构 end 键', () {
    final c = (cases['multiCycle'] as Map).cast<String, dynamic>();
    final records = _rows(c['records']);
    final today = c['today'] as String;

    final episodeRows = records.where((r) => r.isEpisodeRow).toList();
    final dayRows = records.where((r) => r.isDayRow).toList();
    expect(episodeRows.length, 4);
    expect(dayRows.length, 2);
    // period.js 全文无 body.end；本引擎只把 end 作为内存合并段的推算结果。
    expect(records.every((r) => !r.body.containsKey('end')), isTrue);
    expect(periodData(records, today: today).items.length, 4);
    // 把日记录行单独喂进去：没有任何经期行 → 空 episodes、cycle 回落 28。
    final onlyDays = periodData(dayRows, today: today);
    expect(onlyDays.items, isEmpty);
    expect(onlyDays.episodes, isEmpty);
    expect(onlyDays.cycle, 28);
    expect(onlyDays.length, 5);
    expect(onlyDays.nextStart, isNull);
    expect(onlyDays.inWindow, isFalse);
    expect(onlyDays.dayOfPeriod, 0);
  });

  test('fragmentMerge：碎片合并 + owner 取开始日不晚于该天的最后一个碎片', () {
    final c = (cases['fragmentMerge'] as Map).cast<String, dynamic>();
    final d = periodData(_rows(c['records']), today: c['today'] as String);
    expect(d.episodes.length, 2, reason: '5 行碎片应合并成 2 次月经');
    expect(d.episodes[0].frags.length, 3);
    expect(d.episodes[0].length, 7);
    expect(d.episodes[1].frags.length, 2);
    expect(d.episodes[1].length, 5);
    // 09-04 落在 f1 与 f3 之间，owner 必须是 f2（period.js:148）。
    expect(periodEpisodeOf(d, dayNum('2026-09-04'))!.owner.id, 'f2');
    expect(periodEpisodeOf(d, dayNum('2026-09-06'))!.owner.id, 'f3');
    expect(periodEpisodeOf(d, dayNum('2026-10-03'))!.owner.id, 'f5');
    expect(periodEpisodeOf(d, dayNum('2026-09-08')), isNull);
  });

  // ── 口径补强（主理人 D2 补充）：固定 today / UTC 解析 / 与本机时区隔离 ──
  test('固定 today：三组夹具共用 2026-11-14，Node 与 Dart 同源注入', () {
    final meta = (expected['meta'] as Map).cast<String, dynamic>();
    expect(meta['today'], '2026-11-14');
    expect(meta['source'], 'static/period.js');
    expect(meta['fixedToday'].toString().contains('2026-11-14'), isTrue);
    for (final name in const ['multiCycle', 'singleNoGap', 'fragmentMerge']) {
      final c = (cases[name] as Map).cast<String, dynamic>();
      expect(c['today'], '2026-11-14', reason: '$name 夹具 today 必须固定');
      final e = (expCases[name] as Map).cast<String, dynamic>();
      expect(e['todayN'], dayNum('2026-11-14'),
          reason: '$name todayN 来自 UTC 解析 dayNum(today)');
    }
  });

  test('不同 today 注入：inWindow / dayOfPeriod / untilNext 与 Web 实跑全等', () {
    final c = (cases['singleNoGap'] as Map).cast<String, dynamic>();
    final records = _rows(c['records']);
    final sweep = (expected['todaySweep'] as List)
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    expect(sweep.length, 6);
    for (final s in sweep) {
      final today = s['today'] as String;
      final d = periodData(records, today: today);
      expect(d.cycle, s['cycle'], reason: '$today cycle');
      expect(d.nextStart, s['nextStart'], reason: '$today nextStart');
      expect(d.nextStartStr, s['nextStartIso'], reason: '$today nextStart ISO');
      expect(d.todayN, s['todayN'], reason: '$today todayN（UTC 解析）');
      expect(d.inWindow, s['inWindow'], reason: '$today inWindow');
      expect(d.dayOfPeriod, s['dayOfPeriod'], reason: '$today dayOfPeriod');
      expect(d.untilNext, s['untilNext'], reason: '$today untilNext');
      expect(d.estimated, s['estimated'], reason: '$today estimated');
    }
  });

  test('引擎与真实时钟/本机时区隔离：代码里无 DateTime.now()、无 toLocal()', () {
    final src = File('lib/features/period/period_engine.dart').readAsStringSync();
    // 只检查**代码行**：文档注释里描述契约时会提到 `DateTime.now()` 字面量，
    // 直接全文 contains 会误报（注释不是代码）。
    final code = src
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    expect(code.contains('DateTime.now()'), isFalse,
        reason: '引擎代码不得读真实时钟；today 一律显式字符串注入');
    expect(code.contains('.toLocal()'), isFalse,
        reason: '引擎代码不得用本机时区换算；dayNum/dayStr 全走 UTC');
    expect(code.contains('DateTime.utc('), isTrue,
        reason: 'dayNum 必须按 UTC 午夜解析字符串');
    expect(code.contains('isUtc: true'), isTrue,
        reason: 'dayStr 必须按 UTC 输出 YYYY-MM-DD');
  });

  test('spaceTodayIso：空间时区（UTC+8）日历日，跨日边界与本机时区无关', () {
    // 与 Web Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Shanghai'}) 对照：
    // UTC 15:59 → 上海 23:59 当天；UTC 16:00 → 上海 次日 00:00。
    expect(spaceTodayIso(DateTime.utc(2026, 11, 14, 15, 59)), '2026-11-14');
    expect(spaceTodayIso(DateTime.utc(2026, 11, 14, 16, 0)), '2026-11-15');
    expect(spaceTodayIso(DateTime.utc(2026, 1, 1, 0, 0)), '2026-01-01');
    expect(spaceTodayIso(DateTime.utc(2026, 12, 31, 20, 30)), '2027-01-01');
    // 纯函数：同一绝对时刻反复调用恒等，只取 UTC 绝对时刻（不依赖设备时区）。
    final instant = DateTime.utc(2026, 11, 14, 16, 0);
    expect(spaceTodayIso(instant), spaceTodayIso(instant.toUtc()));
    expect(spaceTodayIso(instant), '2026-11-15');
  });
}
