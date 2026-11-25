/**
 * 重生成 `test/fixtures/period_expected.json`（2.8.2 待确认模型）。
 *
 * 方法沿用既有定案：Node 把 `static/period.js` 源码整体求值，只注入
 * recordsOf/today 两个全局桩，**调用的都是 Web 原函数**（periodData /
 * cyclePhases / periodEpisodeOf / dayNum / dayStr），期望值不是手算。
 *
 * 运行：node tests/gen_period_expected_282.mjs
 * 说明：2.8.2 起 phases 每天多一个 `pending` 标记（经期待确认），
 *       Dart 对拍测试同步断言它。
 */
import { readFileSync, writeFileSync } from 'node:fs';

const ROOT = new URL('..', import.meta.url);
const SRC = readFileSync(new URL('static/period.js', ROOT), 'utf8');
const CASES = JSON.parse(readFileSync(new URL('app-flutter/test/fixtures/period_cases.json', ROOT), 'utf8'));

const DAYNUM_INPUTS = ['1970-01-01', '2024-02-29', '2026-01-01', '2026-06-01', '2026-11-14', '2026-06-01T12:34:56'];
const DAYSTR_INPUTS = [0, 1, 19875, 20454, 20678, -1];

function load(records, todayIso) {
  const stubs = {
    recordsOf: (kind) => (kind === 'period' ? records : []),
    today: () => todayIso,
    state: { me: { user: { name: '测试' } }, periodDay: todayIso },
    post: async () => {}, put: async () => {}, del: async () => {}, uuid: () => 'cid',
    toast: () => {}, refresh: async () => {},
    esc: (s) => String(s ?? ''), icon: () => '',
    openModal: () => {}, closeModal: () => {}, field: () => '', selectField: () => '',
    formError: () => {}, modalActions: () => {},
  };
  const names = Object.keys(stubs);
  const factory = new Function(
    ...names,
    `${SRC}\n;return {periodData, cyclePhases, periodEpisodeOf, dayNum, dayStr, dayInCycleProbe: (d)=>{const last=d.last;if(!last)return 1;const cyc=Math.max(1,d.cycle);const raw=d.todayN-dayNum(last.body.start)+1;return Math.min(cyc,Math.max(1,raw));}};`,
  );
  return factory(...names.map((n) => stubs[n]));
}

const out = {
  meta: {
    source: 'static/period.js',
    generatedBy: 'tests/gen_period_expected_282.mjs（2.8.2 待确认模型重生成；可重复运行）',
    method: 'Node vm 把 period.js 源码与求值 IIFE 拼成同一 script 实跑；仅注入 recordsOf/today；dayNum/dayStr/periodData/cyclePhases/periodEpisodeOf 均为 Web 原函数',
    functions: ['periodData', 'periodEpisodeOf', 'cyclePhases', 'dayNum', 'dayStr'],
    today: CASES.meta.today,
    ovuNormalization: 'ovu 缺省归一成 false；2.8.2 起每天另带 pending 标记',
    fixedToday: '2026-11-14（三组夹具共用；Node mock today() 返回固定字符串，Dart 侧 periodData(records, today: ...) 显式传参，同一口径）',
    todaySweepMethod: 'Node vm 实跑 static/period.js 的 periodData()，仅改注入的 today()，其余夹具原样；期望值非手算',
  },
  cases: {},
  dayNumSamples: {},
  dayStrSamples: {},
  fallback28: {},
};

for (const [name, c] of Object.entries(CASES.cases)) {
  const m = load(c.records, c.today);
  const d = m.periodData();
  const phases = m.cyclePhases(d);

  const expPhases = {};
  for (const [iso, v] of Object.entries(phases)) {
    expPhases[iso] = { phase: v.phase, predicted: !!v.predicted, ovu: !!v.ovu, pending: !!v.pending };
  }

  // 探针：所有已铺日 + 今天前后 + 每段边界前后（覆盖「命中/不命中/待确认」三态）
  const probes = new Set(Object.keys(phases));
  const tN = d.todayN;
  for (const off of [-1, 0, 1]) probes.add(m.dayStr(tN + off));
  for (const e of d.episodes) {
    for (const off of [-1, 0, e.length - 1, e.length]) probes.add(m.dayStr(e.start + off));
  }
  const hits = [...probes].sort().map((iso) => {
    const n = m.dayNum(iso);
    const hit = m.periodEpisodeOf(d, n);
    return hit
      ? { iso, n, hit: true, epStart: hit.ep.start, epEnd: hit.ep.end, epLength: hit.ep.length, ownerId: hit.owner.id }
      : { iso, n, hit: false };
  });

  out.cases[name] = {
    cycle: d.cycle,
    length: d.length,
    nextStart: d.nextStart,
    nextStartIso: d.nextStart == null ? null : m.dayStr(d.nextStart),
    todayN: d.todayN,
    inWindow: d.inWindow,
    dayOfPeriod: d.dayOfPeriod,
    untilNext: d.untilNext,
    estimated: d.estimated,
    lastLen: d.lastLen,
    pending: d.pending
      ? { start: d.pending.start, confirmedEnd: d.pending.confirmedEnd, end: d.pending.end, days: d.pending.days }
      : null,
    gaps: d.gaps,
    itemCount: d.items.length,
    episodes: d.episodes.map((e) => ({ start: e.start, end: e.end, length: e.length })),
    dayInCycle: m.dayInCycleProbe(d),
    todayPhase: phases[c.today] ? { phase: phases[c.today].phase, predicted: !!phases[c.today].predicted, ovu: !!phases[c.today].ovu } : null,
    phases: expPhases,
    hits,
    dayNumSamples: Object.fromEntries(DAYNUM_INPUTS.map((s) => [s, m.dayNum(s)])),
    dayStrSamples: Object.fromEntries(DAYSTR_INPUTS.map((n) => [String(n), m.dayStr(n)])),
  };
}

// dayNum/dayStr 顶层样本（与最早 fixture 同形）
{
  const m = load([], CASES.meta.today);
  out.dayNumSamples = Object.fromEntries(DAYNUM_INPUTS.map((s) => [s, m.dayNum(s)]));
  out.dayStrSamples = Object.fromEntries(DAYSTR_INPUTS.map((n) => [String(n), m.dayStr(n)]));
}

// todaySweep：固定 6 个注入日（singleNoGap），逐日实跑 periodData
{
  const c = CASES.cases.singleNoGap;
  const dates = ['2026-11-09', '2026-11-10', '2026-11-14', '2026-11-15', '2026-11-16', '2026-12-11'];
  out.todaySweep = dates.map((today) => {
    const m = load(c.records, today);
    const d = m.periodData();
    return {
      today,
      cycle: d.cycle,
      nextStart: d.nextStart,
      nextStartIso: d.nextStart == null ? null : m.dayStr(d.nextStart),
      todayN: d.todayN,
      inWindow: d.inWindow,
      dayOfPeriod: d.dayOfPeriod,
      untilNext: d.untilNext,
      estimated: d.estimated,
    };
  });
}

// `||28` 缺省分支：把 singleNoGap 的 cycle 键全删掉后实跑（该用例无有效 gap）
{
  const c = CASES.cases.singleNoGap;
  const noCycle = c.records.map((r) => {
    const body = { ...r.body };
    delete body.cycle;
    return { ...r, body };
  });
  const m = load(noCycle, c.today);
  const d = m.periodData();
  out.fallback28 = { cycle: d.cycle, nextStart: d.nextStart, nextStartIso: d.nextStart == null ? null : m.dayStr(d.nextStart) };
}

const dest = new URL('app-flutter/test/fixtures/period_expected.json', ROOT);
writeFileSync(dest, JSON.stringify(out, null, 1) + '\n', 'utf8');
console.log('已写入', dest.pathname);
for (const [k, v] of Object.entries(out.cases)) {
  console.log(`  ${k}: cycle=${v.cycle} length=${v.length} pending=${v.pending ? v.pending.days + '天' : '无'} phases=${Object.keys(v.phases).length}`);
}
