/* 条目 8 · 段 8-B 契约对拍（验收点②③④）：Dart 纯函数 × Web `period.js` 实跑。
   期望值全部来自 `test/fixtures/period_b_expected.json`（Node vm 实跑 Web 原函数，
   生成方式见定案文档附录 B.1），**不手算、不硬编码**。
   覆盖：四条预警逐字 / 经期四动作（含首日 DELETE、中途改 length、幂等）/ 
   9 字段 periodSaveDay 逐项 / periodValueText 逐键回显 / cycleHero 环形数值 /
   phaseBar 四段权重与游标 / periodForm body 形状 / 日记录不污染推算。
*/
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/features/period/period_actions.dart';
import 'package:love_space/features/period/period_engine.dart';
import 'package:love_space/features/period/period_meta.dart';

Map<String, dynamic> _load(String name) => jsonDecode(
      File('test/fixtures/$name').readAsStringSync(),
    ) as Map<String, dynamic>;

List<PeriodRow> _rows(Object? raw) => (raw as List)
    .map((e) => PeriodRow.fromJson((e as Map).cast<String, dynamic>()))
    .toList();

/// 把 plan 转成 Web 期望值同形状（writes / toasts / refreshed）。
Map<String, dynamic> _planShape(PeriodWritePlan p) {
  final write = <String, dynamic>{
    'method': p.kind == PeriodWriteKind.post
        ? 'post'
        : p.kind == PeriodWriteKind.put
            ? 'put'
            : 'del',
    'path': p.path,
    if (p.kind != PeriodWriteKind.delete)
      'data': <String, dynamic>{
        'kind': 'period',
        'body': p.body,
        if (p.kind == PeriodWriteKind.post) 'client_id': p.clientId,
      },
  };
  return <String, dynamic>{
    'writes': p.hasWrite ? <Map<String, dynamic>>[write] : <Object>[],
    'toasts': p.message.isEmpty ? <Object>[] : <String>[p.message],
    'refreshed': p.refresh,
  };
}

void main() {
  final aCases = _load('period_cases.json');
  final bCases = _load('period_b_cases.json');
  final expected = _load('period_b_expected.json');

  PeriodData dataOf(Map<String, dynamic> c) =>
      periodData(_rows(c['records']), today: c['today'] as String);

  // ── ① 四条预警规则各触发一次 + 文字逐字 + 真实夹具预警有无一致 ─────
  group('periodWarnings :232-245（四条规则逐字）', () {
    final warnings = (expected['warnings'] as Map).cast<String, dynamic>();
    for (final raw in (bCases['warningCases'] as List)) {
      final c = (raw as Map).cast<String, dynamic>();
      final name = c['name'] as String;
      test('预警 · $name · 与 Web 实跑逐字全等', () {
        expect(periodWarnings(dataOf(c)),
            equals((warnings[name] as List).cast<String>()));
      });
    }
    for (final name in const ['multiCycle', 'singleNoGap', 'fragmentMerge']) {
      test('预警 · 8-A 真实夹具 $name · App 与 Web 有无一致', () {
        final c = ((aCases['cases'] as Map)[name] as Map)
            .cast<String, dynamic>();
        expect(periodWarnings(dataOf(c)),
            equals((warnings[name] as List).cast<String>()));
      });
    }
    test('invalidGap：必须读原始 gaps，不能用 d.gaps（已过滤 15–60）', () {
      final c = (bCases['warningCases'] as List)
          .map((e) => (e as Map).cast<String, dynamic>())
          .firstWhere((e) => e['name'] == 'invalidGap');
      final d = dataOf(c);
      expect(d.gaps, equals(<int>[28]), reason: '10 天不在有效 gaps 里');
      final w = periodWarnings(d);
      expect(w.length, 1);
      expect(w.single.contains('10 天'), isTrue,
          reason: '预警必须用未过滤的 10 天');
    });
    test('文案逐字常量核过（偏短/偏长/过长/漏记 + 免责原文带句号）', () {
      final short = (bCases['warningCases'] as List)
          .map((e) => (e as Map).cast<String, dynamic>())
          .firstWhere((e) => e['name'] == 'short');
      expect(periodWarnings(dataOf(short)).single,
          '最近三次里有 1 次周期只有 18 天，偏短——可能是一次点滴出血，也可能记漏了');
      expect(fertilityNote, '按日历推算，仅供参考，不能作为避孕依据。');
      expect(fertilityNote.endsWith('。'), isTrue);
      expect(warnBlockTitle, '有几点需要留意');
      expect(warnBlockNote, '按记录推算的提示，身体不舒服还是去看医生。');
    });
  });

  // ── ② 经期四动作：method/path/body/提示逐项全等 ──────────────────
  group('经期四动作（period.js:77-109 / app.js:2507-2510）', () {
    final actions = (expected['actions'] as Map).cast<String, dynamic>();
    for (final raw in (bCases['actionCases'] as List)) {
      final c = (raw as Map).cast<String, dynamic>();
      final name = c['name'] as String;
      test('动作 · $name · 与 Web 实跑全等', () {
        final d = dataOf(c);
        final day = c['day'] as String;
        final action = c['action'] as String;
        final plan = action == 'start'
            ? planStart(d, day, clientId: 'uuid-fixed-8b')
            : action == 'end'
                ? planEnd(d, day)
                : planMore(d, day);
        expect(_planShape(plan), equals(actions[name]),
            reason: '$name · Web 期望 ${jsonEncode(actions[name])}');
      });
    }

    test('「走了」首日 DELETE / 中途改 length 两种情形都不带 end 键', () {
      final byName = <String, Map<String, dynamic>>{};
      for (final raw in (bCases['actionCases'] as List)) {
        final m = Map<String, dynamic>.from(raw as Map);
        byName[m['name'] as String] = m;
      }
      final first = planEnd(dataOf(byName['endFirstDay']!), '2026-11-14');
      expect(first.kind, PeriodWriteKind.delete);
      expect(first.message, '已撤掉这次经期');
      final middle = planEnd(dataOf(byName['endMiddle']!), '2026-11-12');
      expect(middle.kind, PeriodWriteKind.put);
      expect(middle.body!['length'], 2);
      expect(middle.body!.containsKey('end'), isFalse);
      expect(middle.message, '这次经期到昨天为止');
      for (final name in const ['startNew', 'startAttach', 'moreExtend']) {
        final p = name == 'startNew'
            ? planStart(dataOf(byName[name]!), '2026-11-14',
                clientId: 'uuid-fixed-8b')
            : name == 'startAttach'
                ? planStart(dataOf(byName[name]!), '2026-11-14',
                    clientId: 'uuid-fixed-8b')
                : planMore(dataOf(byName[name]!), '2026-11-12');
        expect(p.body?.containsKey('end') ?? false, isFalse,
            reason: '$name 不得出现 end 键');
      }
    });

    test('删整次：对 episode 全部碎片 id 逐个 DELETE', () {
      final c = ((aCases['cases'] as Map)['fragmentMerge'] as Map)
          .cast<String, dynamic>();
      final d = dataOf(c);
      expect(deleteEpisodeIds(d.episodes.first), ['f1', 'f2', 'f3']);
      expect(deleteEpisodeIds(d.episodes.last), ['f4', 'f5']);
      expect(periodDeleteEpisodeTitle, '删掉这次经期？');
      expect(periodDeleteEpisodeText(3),
          '这次经期被拆成了 3 段记录，会一起进回收站，三十天内可以恢复。');
    });
  });

  // ── ③ 9 字段 periodSaveDay 逐项 + 整份覆盖/清键/强制删 start ───────
  group('日记录 9 字段（periodSaveDay :59-70）', () {
    final dayLogs = (expected['dayLogs'] as Map).cast<String, dynamic>();
    for (final raw in (bCases['dayLogCases'] as List)) {
      final c = (raw as Map).cast<String, dynamic>();
      final name = c['name'] as String;
      test('日记录 · $name · body/端点/client_id 与 Web 实跑全等', () {
        final plan = planSaveDay(
          records: _rows(c['records']),
          day: c['day'] as String,
          patch: (c['patch'] as Map).cast<String, dynamic>(),
          clientId: 'uuid-fixed-8b',
        );
        expect(_planShape(plan), equals(dayLogs[name]),
            reason: '$name · Web 期望 ${jsonEncode(dayLogs[name])}');
      });
    }

    test('🔴 日记录保存后不污染推算：body 永不带 start、periodData 不变', () {
      // 有经期行 + 日记录行，逐字段各存一遍；每次都断言无 start、推算不变。
      final base = <PeriodRow>[
        PeriodRow(id: 'ep1', author: 'u1', body: <String, dynamic>{
          'start': '2026-11-10',
          'length': 6,
          'cycle': 31,
        }),
      ];
      final before = periodData(base, today: '2026-11-14');
      var records = List<PeriodRow>.from(base);
      const patches = <Map<String, dynamic>>[
        {'flow': 4},
        {'color': 3},
        {'pain': 2},
        {'sex': [{'t': '21:30', 'w': [2]}]},
        {'symptoms': ['腰酸']},
        {'mood': 7},
        {'weight': 52.5},
        {'discharge': 1},
        {'temp': 36.8},
        {'content': '今天有点累'},
      ];
      for (final patch in patches) {
        final body = periodSaveDayBody(
            records: records, day: '2026-11-11', patch: patch);
        expect(body.containsKey('start'), isFalse,
            reason: '日记录永不带 start（period.js:66）');
        expect(body.containsKey('end'), isFalse);
        expect(body['date'], '2026-11-11');
        records = <PeriodRow>[
          ...records.where((r) => !r.isDayRow),
          PeriodRow(id: 'day1', author: 'u2', body: body),
        ];
        final after = periodData(records, today: '2026-11-14');
        expect(after.cycle, before.cycle);
        expect(after.length, before.length);
        expect(after.nextStart, before.nextStart);
        expect(after.todayN, before.todayN);
        expect(after.inWindow, before.inWindow);
        expect(after.dayOfPeriod, before.dayOfPeriod);
        expect(after.episodes.length, before.episodes.length);
        expect(after.items.length, 1, reason: '日记录不参与推算');
      }
      // 即使 patch 里有 start（畸形），也必须被强制删掉。
      final poisoned = periodSaveDayBody(
          records: records,
          day: '2026-11-11',
          patch: <String, dynamic>{'start': '2026-11-10', 'pain': 1});
      expect(poisoned.containsKey('start'), isFalse);
    });

    test('9 字段各填一遍后逐键文字化回显与 Web 实跑全等', () {
      final valueText = (expected['valueText'] as Map).cast<String, dynamic>();
      for (final raw in (bCases['valueTextCases'] as List)) {
        final c = (raw as Map).cast<String, dynamic>();
        final name = c['name'] as String;
        final body = (c['body'] as Map).cast<String, dynamic>();
        final exp = (valueText[name] as Map).cast<String, dynamic>();
        for (final f in periodLogFields) {
          expect(periodValueText(f[0], body), exp[f[0]],
              reason: '$name · ${f[0]} 回显');
        }
      }
    });

    test('periodSexEntries：老数据纯编号数组 → [{t:"",w:[n]}]', () {
      final legacy = periodSexEntries(<String, dynamic>{
        'sex': [2, 4],
      });
      expect(legacy.length, 2);
      expect(legacy[0].t, '');
      expect(legacy[0].w, [2]);
      expect(legacy[1].w, [4]);
      final modern = periodSexEntries(<String, dynamic>{
        'sex': [
          {'t': '21:30', 'w': [2, 5, 9]},
        ],
      });
      expect(modern.single.t, '21:30');
      expect(modern.single.w, [2, 5, 9]);
      expect(modern.single.toJson()['t'], '21:30');
    });
  });

  // ── ④ cycleHero / phaseBar 数值与文案（Web 实跑） ─────────────────
  group('cycleHero :246-277 / phaseBar :281-289', () {
    final derived = (expected['derived'] as Map).cast<String, dynamic>();
    for (final raw in (bCases['derivedCases'] as List)) {
      final spec = (raw as Map).cast<String, dynamic>();
      final name = spec['name'] as String;
      test('hero/phaseBar · $name · 与 Web 实跑全等', () {
        final c = spec['fromCases'] == true
            ? ((aCases['cases'] as Map)[name] as Map)
                .cast<String, dynamic>()
            : (bCases['warningCases'] as List)
                .map((e) => (e as Map).cast<String, dynamic>())
                .firstWhere((e) => e['name'] == name);
        final d = dataOf(c);
        final today = c['today'] as String;
        final e = (derived[name] as Map).cast<String, dynamic>();
        expect(d.items.isEmpty, e['empty']);
        expect(ringCircumference, e['ringC']);
        expect(dayInCycle(d), e['dayIn']);
        expect(ringOffset(d), e['ringOffset'], reason: '$name ringOffset');
        expect(d.cycle < 1 ? 1 : d.cycle, e['cyc']);
        expect(heroTitle(d, today), e['title']);
        expect(heroTip(d, today), e['tip']);
        final fert = fertilityOf(d, today);
        expect(fert?[0] ?? '', e['fertLevel']);
        expect(fert?[1] ?? '', e['fertDesc']);
        final segs = phaseSegments(d)
            .map((s) => <Object>[s.phase, s.days])
            .toList();
        expect(segs, equals(e['segs']), reason: '$name phaseBar 四段权重');
        expect(phaseCursor(d), closeTo((e['cursorPos'] as num).toDouble(), 1e-9),
            reason: '$name 游标用相对天数，绝不能用绝对 dayNum');
      });
    }

    test('phaseBar 权重恒为相对天数（不塌成一段）', () {
      final c = ((aCases['cases'] as Map)['multiCycle'] as Map)
          .cast<String, dynamic>();
      final segs = phaseSegments(dataOf(c));
      expect(segs.map((s) => s.days).toList(), [5, 4, 7, 12]);
      expect(segs.every((s) => s.days > 0 && s.days < 100), isTrue);
    });
  });

  // ── ⑤ periodForm body 形状（:824-826） ─────────────────────────────
  group('periodForm :809-833', () {
    test('提交 body 恰为 {start,length,cycle,flow?,symptoms,content}', () {
      final body = periodFormBody(
        start: '2026-11-10',
        lengthText: '6',
        cycleText: '30',
        flowText: '3',
        symptoms: const <String>['腰酸', '腹痛'],
        content: '这次特别难受',
        defaultCycle: 28,
      );
      expect(body.keys.toSet(),
          {'start', 'length', 'cycle', 'flow', 'symptoms', 'content'});
      expect(body['start'], '2026-11-10');
      expect(body['length'], 6);
      expect(body['cycle'], 30);
      expect(body['flow'], 3);
      expect(body['symptoms'], ['腰酸', '腹痛']);
      expect(body['content'], '这次特别难受');
      expect(body.containsKey('end'), isFalse);
      expect(body.containsKey('date'), isFalse);
      expect(body.containsKey('client_id'), isFalse);
    });

    test('flow 不记 / length 空回落 5 / cycle 空回落 d.cycle / flow 老数据映射', () {
      final body = periodFormBody(
        start: '2026-11-10',
        lengthText: '',
        cycleText: '',
        flowText: '',
        symptoms: const <String>[],
        content: '',
        defaultCycle: 31,
      );
      expect(body['length'], 5);
      expect(body['cycle'], 31);
      expect(body.containsKey('flow'), isFalse);
      expect(body['symptoms'], <String>[]);
      expect(body['content'], '');
      // periodForm :815 老数据「少/中/多」→ 2/3/4（表单预填映射）。
      for (final pair in const [
        ['少', 2],
        ['中', 3],
        ['多', 4],
      ]) {
        final v = pair[0] as String;
        final num = int.tryParse(v);
        expect(num ?? const {'少': 2, '中': 3, '多': 4}[v], pair[1]);
      }
    });

    test('有记录 PUT 不带 client_id / 无记录 POST 带 client_id', () {
      final body = <String, dynamic>{'start': '2026-11-10'};
      final put = planSaveEpisodeForm(
          recordId: 'r1', body: body, clientId: 'cid');
      expect(put.kind, PeriodWriteKind.put);
      expect(put.path, '/records/r1');
      expect(put.clientId, isNull);
      expect(put.message, '已记下这次');
      final post = planSaveEpisodeForm(
          recordId: null, body: body, clientId: 'cid');
      expect(post.kind, PeriodWriteKind.post);
      expect(post.clientId, 'cid');
      expect(_planShape(post)['writes'][0]['data']['client_id'], 'cid');
    });
  });

  test('常量表逐字：9 字段顺序 / 20 症状 / 受孕三档 / 免责带句号', () {
    expect(periodLogFields.map((f) => f[0]).toList(), [
      'flow', 'color', 'pain', 'sex', 'symptoms', 'mood', 'weight',
      'discharge', 'temp',
    ]);
    expect(periodSymptoms.length, 20);
    expect(periodSymptoms.first, '没有症状');
    expect(periodSymptoms.contains('白带增多'), isTrue);
    expect(fertility.length, 4);
    expect(fertility.values.every((v) => v.length == 2), isTrue);
    expect(fertility.values.map((v) => v[0]).toSet(), {'低', '中', '高'});
    expect(periodFormNote.contains('数据加密保存，两个人一起维护同一条周期。'),
        isTrue);
    expect(periodEmptyTitle, '🌸 开始记录');
    expect(periodEmptyText.contains('月经来了 · 是'), isTrue);
    expect(periodLogFields.length, 9);
  });

  test('greetWord / nowTime 用空间时区（UTC+8），与设备本机时区无关', () {
    expect(greetWord(DateTime.utc(2026, 11, 14, 0, 30)), '早上好');
    expect(greetWord(DateTime.utc(2026, 11, 14, 4, 0)), '中午好');
    expect(greetWord(DateTime.utc(2026, 11, 14, 9, 0)), '下午好');
    expect(greetWord(DateTime.utc(2026, 11, 14, 10, 0)), '晚上好');
    expect(greetWord(DateTime.utc(2026, 11, 14, 15, 0)), '夜深了');
    expect(nowTimeOf(DateTime.utc(2026, 11, 14, 13, 5)), '21:05');
  });
}
