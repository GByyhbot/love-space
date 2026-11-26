/**
 * 2.8.7 动态加权预测 · Web 侧对拍脚本（与 Dart 跑同一份夹具）。
 *
 * 为什么用 Node 而不是 pytest：`static/period.js` 是浏览器脚本（依赖 recordsOf/today
 * 等全局），这里把它整体求值、注入最小桩，直接调用**线上那份实现**。
 *
 * 夹具：`app-flutter/test/fixtures/period_weighted_cases.json`
 * 同一份文件也被 Dart `test/period_weighted_287_test.dart` 读取断言。
 *
 * 运行：node tests/period_weighted_287.mjs
 */
import { readFileSync } from 'node:fs';

const SRC = readFileSync(new URL('../static/period.js', import.meta.url), 'utf8');
const FIXTURE = JSON.parse(
  readFileSync(new URL('../app-flutter/test/fixtures/period_weighted_cases.json', import.meta.url), 'utf8'),
);
const DAY_MS = 86400000;

/** 'YYYY-MM-DD' → 与 period.js dayNum() 同口径（UTC 日序）。 */
const dayNumOf = (iso) => {
  const [y, m, d] = iso.split('-').map(Number);
  return Date.UTC(y, m - 1, d) / DAY_MS;
};

/** 某日 UTC+8 的 12:00 对应 epoch 秒（avoid 日界抖动）。 */
const noonTs = (iso) => dayNumOf(iso) * 86400 + 4 * 3600; // +04:00Z = 12:00+08:00

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
    `${SRC}\n;return {periodData};`,
  );
  return factory(...names.map((n) => stubs[n]));
}

/** 夹具里的一条段 → period.js 认识的记录行。 */
function toRecord(spec, index) {
  const updated = spec.updatedSameDay
    ? noonTs(spec.start)
    : noonTs(spec.start); // 默认「当天建的段」，与 updatedSameDay 等价，留字段是为了夹具自述
  const body = { start: spec.start, length: spec.length };
  if (spec.cycle != null) body.cycle = spec.cycle;
  return {
    id: `r${index}`,
    kind: 'period',
    body,
    created: updated,
    updated,
  };
}

let failures = 0;
for (const c of FIXTURE.cases) {
  const records = c.records.map(toRecord);
  const api = load(records, c.today);
  const d = api.periodData();
  const got = {
    cycle: d.cycle,
    length: d.length,
    predictionSampleCount: d.predictionSampleCount,
    cycleSpread: d.cycleSpread ?? null,
    overdueDays: d.overdueDays,
  };
  const bad = Object.keys(c.expect).filter((k) => got[k] !== c.expect[k]);
  if (bad.length === 0) {
    console.log(`  ✅ ${c.name}`);
  } else {
    failures += 1;
    console.log(`  ❌ ${c.name}`);
    for (const k of bad) console.log(`       ${k}: expect=${c.expect[k]} got=${got[k]}`);
  }
}

if (failures > 0) {
  console.log(`\n${failures} 个用例失败（Web 侧 / static/period.js）`);
  process.exit(1);
}
console.log(`\n全部通过：${FIXTURE.cases.length} 个用例（Web 侧 / static/period.js）`);
