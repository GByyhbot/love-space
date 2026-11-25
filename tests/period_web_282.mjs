/**
 * 2.8.2 生理期「待确认模型」Web 侧最小断言脚本。
 *
 * 为什么不是 pytest：`static/period.js` 是浏览器脚本（依赖 recordsOf/today 等全局），
 * 没有现成前端测试框架。这里用 Node 把它整体求值、注入最小全局桩，直接调用真实
 * 的 periodData/cyclePhases/periodEpisodeOf/periodStart —— 断言的是**线上那份代码本身**，
 * 不是另写一份等价实现。
 *
 * 运行：node tests/period_web_282.mjs
 */
import { readFileSync } from 'node:fs';

const SRC = readFileSync(new URL('../static/period.js', import.meta.url), 'utf8');
const DAY_MS = 86400000;

/** 'YYYY-MM-DD' → 与 period.js dayNum() 同口径的日序（UTC 天数）。 */
const dayNumOf = (iso) => {
  const [y, m, d] = iso.split('-').map(Number);
  return Date.UTC(y, m - 1, d) / DAY_MS;
};

let failures = 0;
const ok = (cond, name, extra = '') => {
  if (cond) {
    console.log(`  ✅ ${name}`);
  } else {
    failures += 1;
    console.log(`  ❌ ${name}${extra ? ' — ' + extra : ''}`);
  }
};

/**
 * 用给定记录集与"今天"装载 period.js。
 * records: [{id, kind:'period', body:{start,length}, created, updated}]
 */
function load(records, todayIso) {
  const stubs = {
    recordsOf: (kind) => (kind === 'period' ? records : []),
    today: () => todayIso,
    state: { me: { user: { name: '测试' } }, periodDay: todayIso },
    post: async () => {},
    put: async () => {},
    del: async () => {},
    uuid: () => 'cid',
    toast: () => {},
    refresh: async () => {},
    esc: (s) => String(s ?? ''),
    icon: () => '',
    openModal: () => {},
    closeModal: () => {},
    field: () => '',
    selectField: () => '',
    formError: () => '',
    modalActions: () => '',
    recordLabel: () => '',
  };
  const names = Object.keys(stubs);
  const factory = new Function(
    ...names,
    `${SRC}\n;return {periodData, cyclePhases, periodEpisodeOf, periodStart, periodEnd, periodMore};`,
  );
  return factory(...names.map((n) => stubs[n]));
}

/** 造一条段记录：updated 可指定为"哪一天"写回的（按 UTC+8 日界换算）。 */
function ep(id, startIso, length, updatedIso) {
  const updated = updatedIso
    ? Date.UTC(...updatedIso.split('-').map((v, i) => (i === 1 ? Number(v) - 1 : Number(v)))) / 1000 - 8 * 3600
    : dayNumOf(startIso) * 86400 - 8 * 3600;
  return { id, kind: 'period', body: { start: startIso, length }, created: updated, updated };
}

const addDays = (iso, n) => {
  const t = dayNumOf(iso) + n;
  const d = new Date(t * DAY_MS);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
};

const TODAY = '2026-11-25';

console.log('\n【令文 §三 公式单测 6 条】');

// ① 预测 21 来、实际 22 来 → 21 号有分期（黄体期），不是白格
{
  const m = load([ep('e1', '2026-10-22', 5, '2026-10-26'), ep('e2', '2026-11-22', 3, '2026-11-24')], TODAY);
  const d = m.periodData();
  const ph = m.cyclePhases(d)['2026-11-21'];
  ok(!!ph, '① 21 号有分期（不再是白格）');
  ok(ph && ph.phase === 'luteal', '① 21 号落在黄体期', ph && ph.phase);
}

// ② 新建段 length=1（不再是历史平均预填）
{
  let posted = null;
  const m = load([ep('e1', '2026-10-22', 5, '2026-10-26')], TODAY);
  // 直接把 post 桩换掉：重新装载一份能捕获 body 的实例
  const src = readFileSync(new URL('../static/period.js', import.meta.url), 'utf8');
  const stubs = {
    recordsOf: () => [ep('e1', '2026-10-22', 5, '2026-10-26')],
    today: () => TODAY,
    state: { me: { user: { name: '测试' } } },
    post: async (_p, payload) => { posted = payload.body; },
    put: async () => {}, del: async () => {}, uuid: () => 'cid',
    toast: () => {}, refresh: async () => {}, esc: (s) => String(s ?? ''), icon: () => '',
    openModal: () => {}, closeModal: () => {}, field: () => '', selectField: () => '',
    formError: () => '', modalActions: () => {},
  };
  const names = Object.keys(stubs);
  const f = new Function(...names, `${src}\n;return {periodStart};`);
  const mod = f(...names.map((n) => stubs[n]));
  await mod.periodStart('2026-11-24');
  ok(posted && posted.length === 1, '② 新建段 length=1', JSON.stringify(posted));
  ok(posted && posted.start === '2026-11-24', '② start=当天');
  void m;
}

// ③ 确认 3 天、今天第 5 天 → 第 4–5 天待确认
{
  const start = addDays(TODAY, -4);          // 今天 = start+4 → 第 5 天
  const m = load([ep('e1', start, 3, start)], TODAY);
  const d = m.periodData();
  ok(!!d.pending, '③ 进入待确认');
  ok(d.pending && d.pending.days === 5, '③ 待确认天数=5（经期第 5 天）', d.pending && d.pending.days);
  const ph = m.cyclePhases(d);
  ok(ph[addDays(TODAY, -1)]?.pending === true, '③ 第 4 天标为待确认');
  ok(ph[TODAY]?.pending === true, '③ 第 5 天标为待确认');
}

// ④ 待确认第 8 天自动定稿（不再画待确认）
{
  const start = addDays(TODAY, -10);         // 确认末 = start+2 = 今天-8
  const m = load([ep('e1', start, 3, start)], TODAY);
  const d = m.periodData();
  ok(!d.pending, '④ 超 7 天自动定稿（pending 为空）');
}

// ⑤ 平均经期排除未定稿的最后一段
{
  const lastStart = addDays(TODAY, -1);      // 最后一段 length=1、今天第 2 天 → 待确认
  const m = load([ep('e1', '2026-10-22', 5, '2026-10-26'), ep('e2', lastStart, 1, lastStart)], TODAY);
  const d = m.periodData();
  ok(d.pending !== null, '⑤ 前提：最后一段在待确认');
  ok(d.length === 5, '⑤ 平均经期只统计定稿段（=5，不含最后那段 1 天）', d.length);
}

// ⑥ 新段开始后旧段定稿，中间天数不追认经期
{
  const m = load([ep('e1', '2026-11-01', 5, '2026-11-05'), ep('e2', '2026-11-25', 1, '2026-11-25')], TODAY);
  const d = m.periodData();
  const ph = m.cyclePhases(d);
  ok(ph['2026-11-10'] && ph['2026-11-10'].phase !== 'period', '⑥ 中间天数不被追认成经期',
    ph['2026-11-10'] && ph['2026-11-10'].phase);
  ok(ph['2026-11-20'] && ph['2026-11-20'].phase !== 'period', '⑥ 旧段与新段之间仍有分期');
}

console.log('\n【2026-11-25 定稿判据裁定 · 四种情形】');

// ① 点「月经走了」：length 止于昨天、更新日=今天 → 定稿，待确认消失
{
  const start = addDays(TODAY, -4);
  const m = load([ep('e1', start, 4, TODAY)], TODAY);   // length=4 → 结束日=今天-1
  const d = m.periodData();
  ok(d.pending === null, '① 月经走了 → 定稿，待确认消失');
}

// ② 点「月经又来了」延长：结束日被推到更新日之后 → 不定稿；越过新结束日后能恢复
{
  const start = addDays(TODAY, -4);
  // 更新日=今天，length=6 → 结束日=今天+1 > 更新日 → 不定稿
  const m = load([ep('e1', start, 6, TODAY)], TODAY);
  ok(m.periodData().pending === null, '② 延长当天不定稿');
  // 两天后：今天+2 > 结束日(今天+1) → 待确认恢复
  const later = addDays(TODAY, 2);
  const m2 = load([ep('e1', start, 6, TODAY)], later);
  const d2 = m2.periodData();
  ok(!!d2.pending, '② 越过新结束日后待确认恢复');
}

// ③ 只记日记录：独立行，不触碰段记录
{
  const start = addDays(TODAY, -4);
  const seg = ep('e1', start, 3, start);
  const dayRow = { id: 'd1', kind: 'period', body: { date: TODAY, flow: 2 }, created: 0, updated: 0 };
  const m = load([seg, dayRow], TODAY);
  ok(!!m.periodData().pending, '③ 记日记录不影响待确认');
}

// ④ 新建段当天 length=1 → 不定稿；次日起进待确认
{
  const m = load([ep('e1', TODAY, 1, TODAY)], TODAY);
  ok(m.periodData().pending === null, '④ 新建当天不定稿');
  const tomorrow = addDays(TODAY, 1);
  const m2 = load([ep('e1', TODAY, 1, TODAY)], tomorrow);
  ok(!!m2.periodData().pending, '④ 次日起进待确认');
}

console.log(`\n结果：${failures === 0 ? '全部通过 ✅' : failures + ' 条失败 ❌'}`);
process.exit(failures === 0 ? 0 : 1);
