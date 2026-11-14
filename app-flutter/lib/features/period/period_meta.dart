/// 生理期展示口径（条目 8 · 段 8-B · 纯 Dart，可单测）。
///
/// 逐字移植 `static/period.js` 的常量表与纯函数：
/// `PERIOD_FLOW/COLOR/PAIN/DISCHARGE/MOODS/SEX/BODY_SYMPTOMS/SECRETION`
/// `:18-26`、`PERIOD_LOG_FIELDS :28`、`periodValueText :38-57`、
/// `periodSexEntries :318-322`、`greetWord :212-221`、`PHASE_CARD :203`、
/// `PHASE_CARE :206-211`、`FERTILITY/FERTILITY_NOTE :227-228`、
/// `periodWarnings :232-245`、`cycleHero :246-277`、`phaseBar :281-289`、
/// `periodPage :487-499`（下次预计 / 三联统计 / 症状统计）。
///
/// 🔴 硬边界：本文件所有「数字」只消费 [period_engine.dart] 的 [PeriodData]，
/// 不重算 cycle / length / nextStart / phases / dayIn / inWindow / dayOfPeriod；
/// 只做 Web 同款的**展示换算**（pct / 段权重 / 游标 / 文案），且这些换算的
/// 期望值全部由 Node vm 实跑 Web 原函数产出（见 `period_b_expected.json`）。
/// 日期一律用引擎 [dayNum] / [dayStr] / [spaceTodayIso]，不读本机时区日历日。
library;

import 'dart:math' as math;

import 'period_engine.dart';

// ── 常量表（`period.js:18-28` 逐字） ────────────────────────────────────

const Map<int, String> periodFlow = <int, String>{
  1: '非常少量',
  2: '少量',
  3: '中量',
  4: '大量',
  5: '非常大量',
};

/// 值 = [名称, 色值]（`period.js:19`）。
const Map<int, List<String>> periodColor = <int, List<String>>{
  1: ['浅红色', '#F6A8BB'],
  2: ['鲜红色', '#EF3F68'],
  3: ['深红色', '#B22340'],
  4: ['褐色', '#8A5432'],
  5: ['黑色', '#3B3431'],
};

const Map<int, List<String>> periodPain = <int, List<String>>{
  1: ['完全不痛', '😌'],
  2: ['轻微痛', '🙂'],
  3: ['比较痛', '😣'],
  4: ['非常痛', '😖'],
  5: ['痛到极致', '😫'],
};

const Map<int, List<String>> periodDischarge = <int, List<String>>{
  1: ['干燥', '内裤干爽，分泌物量少'],
  2: ['粘稠', '分泌物稠厚，触感像胶状物'],
  3: ['稀糊状', '含水量偏多偏黄，触感像乳液'],
  4: ['水状', '呈白色或透明，触感似水滴'],
  5: ['蛋清状', '呈透明状，两指间可拉丝'],
};

/// [图标, 文案]（`period.js:22`），1-based 编号。
const List<List<String>> periodMoods = <List<String>>[
  ['😄', '超开心'],
  ['😃', '挺开心'],
  ['😐', '一般'],
  ['🙁', '不开心'],
  ['😭', '好伤心'],
  ['🤩', '兴奋'],
  ['😲', '惊喜'],
  ['😌', '满足'],
  ['🥰', '心动'],
  ['😎', '自信'],
  ['😴', '放松'],
  ['😑', '平静'],
  ['😤', '烦躁'],
  ['😠', '易怒'],
  ['😡', '生气'],
  ['😰', '焦虑'],
  ['😞', '内耗'],
  ['😣', '压力'],
  ['😨', '害怕'],
  ['😶', '冷漠'],
];

/// [名称, 图标]（`period.js:23`），1-based 编号。
const List<List<String>> periodSex = <List<String>>[
  ['无措施', '⚠️'],
  ['避孕套', '🛡️'],
  ['体外排精', '💦'],
  ['未射精', '🚫'],
  ['紧急避孕药', '💊'],
  ['短效避孕药', '💊'],
  ['长效避孕药', '💊'],
  ['节育环', '⭕'],
  ['其他措施', '🌸'],
  ['自慰', '✋'],
];

const List<List<String>> periodBodySymptoms = <List<String>>[
  ['没有症状', '👍'],
  ['腰酸', '🧍'],
  ['腹痛', '🤕'],
  ['小腹坠胀', '🎈'],
  ['乳房胀痛', '💗'],
  ['身体酸痛', '💪'],
  ['头痛', '🤯'],
  ['眩晕', '💫'],
  ['失眠', '🌙'],
  ['粉刺', '🫧'],
  ['皮肤干燥', '🧴'],
  ['食欲不振', '🍽️'],
  ['贪冷饮', '🧊'],
  ['腹泻', '🚽'],
  ['便秘', '🧻'],
  ['疲惫', '😪'],
];

const List<List<String>> periodSecretion = <List<String>>[
  ['褐色分泌物', '🟤'],
  ['出血', '🩸'],
  ['有血块', '🔴'],
  ['白带增多', '⚪'],
];

/// `PERIOD_SYMPTOMS`（`period.js:26`）：身体症状 + 分泌物，取名称。
final List<String> periodSymptoms = <String>[
  for (final pair in <List<String>>[
    ...periodBodySymptoms,
    ...periodSecretion,
  ])
    pair[0],
];

/// 记录项清单（`period.js:28`）：[key, 名称, 图标]，顺序即美柚记录页顺序。
const List<List<String>> periodLogFields = <List<String>>[
  ['flow', '流量', '🩸'],
  ['color', '颜色', '🎨'],
  ['pain', '痛经', '⚡'],
  ['sex', '爱爱', '💗'],
  ['symptoms', '症状', '💊'],
  ['mood', '心情', '😊'],
  ['weight', '体重', '⚖️'],
  ['discharge', '白带', '💧'],
  ['temp', '体温', '🌡️'],
];

/// 日记行（`period.js:313`）。
const String periodDiaryKey = 'content';
const String periodDiaryName = '日记';
const String periodDiaryIcon = '📝';

// ── 阶段卡 / 照护 / 受孕概率（`period.js:203/:206-211/:227-228` 逐字） ───

const Map<String, String> phaseCard = <String, String>{
  'period': '经期',
  'follicular': '卵泡期',
  'fertile': '排卵期',
  'luteal': '黄体期',
};

const Map<String, String> phaseCare = <String, String>{
  'period': '多休息、保暖',
  'follicular': '状态正好，适合一起出门走走',
  'fertile': '身体状态不错，别熬夜就行',
  'luteal': '容易情绪起伏，多担待一点',
};

/// 受孕概率三档，**不给百分比**（`period.js:224-227`）。
const Map<String, List<String>> fertility = <String, List<String>>{
  'period': ['低', '经期几乎不会受孕'],
  'follicular': ['中', '越接近排卵日越高'],
  'fertile': ['高', '排卵期前后，概率最高'],
  'luteal': ['低', '排卵已过，概率回落'],
};

/// 免责原文（`:228`，**带句号**）。
const String fertilityNote = '按日历推算，仅供参考，不能作为避孕依据。';

// ── 空态 / 预警块 / 表单说明 文案（逐字） ────────────────────────────

const String periodEmptyTitle = '🌸 开始记录';
const String periodEmptyText =
    '点下面「月经来了 · 是」，把这次的第一天记下来；之后每天顺手记一点，周期会越来越准。谁记都行，两个人看到的是同一份。';
const String periodHeadingSub = '记下周期，把照顾提前一点。';
const String warnBlockTitle = '有几点需要留意';
const String warnBlockNote = '按记录推算的提示，身体不舒服还是去看医生。';
const String periodFormNote =
    '周期默认按历史记录的平均值填好，也可以手动改。数据加密保存，两个人一起维护同一条周期。';
const String periodDeleteEpisodeTitle = '删掉这次经期？';

String periodDeleteEpisodeText(int count) =>
    '这次经期被拆成了 $count 段记录，会一起进回收站，三十天内可以恢复。';

// ── JS 语义辅助 ───────────────────────────────────────────────────────

/// JS truthy（`:38-57` 的 `b.x?` 判定）：0 / '' / null / false / NaN 为假。
/// 供 [period_actions.dart] 的 `periodSaveDay` 清键判定共用，避免第二套口径。
bool jsTruthy(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0 && !v.isNaN;
  if (v is String) return v.isNotEmpty;
  return true;
}

/// `Number(v||fallback)` 的 int 版（`period.js:105` `Number(ep.body.length||5)`）。
int jsNumberOr(Object? v, int fallback) {
  if (!jsTruthy(v)) return fallback;
  final n = v is num ? v : num.tryParse(v.toString());
  if (n == null || n.isNaN) return fallback;
  return n.toInt();
}

/// `Math.round`（向 +∞）的 Dart 等价。
int _jsRound(double v) => (v + 0.5).floor();

int _maxInt(int a, int b) => a > b ? a : b;

/// `String(s).slice(0,10)`。
String periodIso10(String s) => s.length >= 10 ? s.substring(0, 10) : s;

/// JS 对象键取 int（`PERIOD_X[b.x]` 会把字符串/数字统一成键）。
int? _intKey(Object? v) {
  if (v is num) return v.isNaN ? null : v.toInt();
  return int.tryParse(v.toString());
}

// ── 日记录行 helpers（`period.js:34-36`） ──────────────────────────────

List<PeriodRow> periodDayRowsOf(List<PeriodRow> records) =>
    records.where((r) => r.isDayRow).toList();

/// `periodDayRow(date)`：取第一条 date 匹配的日记录行（`:35` `.find`）。
PeriodRow? periodDayRowOf(List<PeriodRow> records, String day) {
  for (final r in records) {
    if (r.isDayRow && periodIso10(r.date) == day) return r;
  }
  return null;
}

/// `periodDayLogs()[day] || {}`（`:36`/`:299`）。
Map<String, dynamic> periodDayLogOf(List<PeriodRow> records, String day) =>
    periodDayRowOf(records, day)?.body ?? const <String, dynamic>{};

// ── periodSexEntries `:318-322` ────────────────────────────────────────

/// 一次同房记录（`{t:'HH:MM', w:[1..10]}`）。
class SexEntry {
  const SexEntry(this.t, this.w);

  final String t;
  final List<int> w;

  Map<String, dynamic> toJson() => <String, dynamic>{
        't': t,
        'w': List<int>.from(w),
      };
}

/// 老数据纯编号数组 `[2,4]` → `[{t:'',w:[2]},…]`；界面只处理一种形状。
List<SexEntry> periodSexEntries(Map<String, dynamic> b) {
  final raw = b['sex'];
  if (raw is! List) return const <SexEntry>[];
  return raw.map((item) {
    if (item is Map) {
      final t = (item['t'] ?? '').toString();
      final w = item['w'] is List
          ? (item['w'] as List)
              .whereType<num>()
              .where((x) => !x.isNaN)
              .map((x) => x.toInt())
              .toList()
          : <int>[];
      return SexEntry(t, w);
    }
    return SexEntry('', item is num && !item.isNaN
        ? <int>[item.toInt()]
        : <int>[]);
  }).toList();
}

// ── periodValueText `:38-57`（逐键，已存值回显必须原样） ────────────────

String periodValueText(String key, Map<String, dynamic> b) {
  switch (key) {
    case 'flow':
      final v = b['flow'];
      if (!jsTruthy(v)) return '';
      if (v is num) return periodFlow[v.toInt()] ?? '';
      return '经量$v';
    case 'color':
      final v = b['color'];
      if (!jsTruthy(v)) return '';
      final k = _intKey(v);
      return (periodColor[k] ?? const <String>[''])[0];
    case 'pain':
      final v = b['pain'];
      if (!jsTruthy(v)) return '';
      final k = _intKey(v);
      return (periodPain[k] ?? const <String>[''])[0];
    case 'discharge':
      final v = b['discharge'];
      if (!jsTruthy(v)) return '';
      final k = _intKey(v);
      return (periodDischarge[k] ?? const <String>[''])[0];
    case 'mood':
      final v = b['mood'];
      if (!jsTruthy(v)) return '';
      final n = _intKey(v) ?? 0;
      if (n - 1 < 0 || n - 1 >= periodMoods.length) return '';
      final m = periodMoods[n - 1];
      return '${m[0]} ${m[1]}';
    case 'sex':
      final list = periodSexEntries(b);
      if (list.isEmpty) return '';
      final first = list.first;
      final ways = first.w
          .map((i) => i - 1 >= 0 && i - 1 < periodSex.length
              ? periodSex[i - 1][0]
              : '')
          .where((s) => s.isNotEmpty)
          .join('、');
      return <String>[
        if (list.length > 1) '${list.length} 次',
        first.t,
        ways,
      ].where((s) => s.isNotEmpty).join(' · ');
    case 'symptoms':
      final v = b['symptoms'];
      if (v is List) return v.map((e) => e.toString()).join(' · ');
      return '';
    case 'weight':
      final v = b['weight'];
      return jsTruthy(v) ? '$v 公斤' : '';
    case 'temp':
      final v = b['temp'];
      return jsTruthy(v) ? '$v ℃' : '';
    default:
      return '';
  }
}

// ── greetWord `:212-221` / nowTime `:326` ─────────────────────────────

/// 问候语。Web 用 `new Date().getHours()`；App 用**空间默认时区（UTC+8）**
/// 的小时（与 [spaceTodayIso] 同源），不读设备本机时区日历日。
String greetWord(DateTime utcNow) {
  final h = utcNow.toUtc().add(const Duration(hours: 8)).hour;
  if (h < 5) return '夜深了';
  if (h < 9) return '早上好';
  if (h < 12) return '上午好';
  if (h < 14) return '中午好';
  if (h < 18) return '下午好';
  if (h < 23) return '晚上好';
  return '夜深了';
}

/// `nowTime()`（`period.js:326`）：`HH:MM`，空间默认时区。
String nowTimeOf(DateTime utcNow) {
  final d = utcNow.toUtc().add(const Duration(hours: 8));
  return '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
}

// ── periodWarnings `:232-245`（四条规则逐字） ──────────────────────────

/// 🔴 注意：这里用的是**全部相邻段的原始 gaps**（`eps[i].start-eps[i-1].start`），
/// 不是 [PeriodData.gaps]（那个只含 15–60 的有效间隔）；夹具 `invalidGap`
/// 专门证明这一点（10 天不在 d.gaps 里，但预警必须出现）。
List<String> periodWarnings(PeriodData d) {
  final out = <String>[];
  final eps = d.episodes;
  if (eps.length < 2) return out;

  final gaps = <int>[];
  for (var i = 1; i < eps.length; i++) {
    gaps.add(eps[i].start - eps[i - 1].start);
  }
  final recent = gaps.length > 3 ? gaps.sublist(gaps.length - 3) : gaps;
  final short = recent.where((g) => g < 21).toList();
  final long = recent.where((g) => g > 35).toList();

  if (short.isNotEmpty) {
    out.add('最近三次里有 ${short.length} 次周期只有 ${short.join('、')} 天，'
        '偏短——可能是一次点滴出血，也可能记漏了');
  }
  if (long.isNotEmpty) {
    out.add('最近三次里有 ${long.length} 次周期到 ${long.join('、')} 天，偏长');
  }
  final len = d.lastEp?.length ?? 0;
  if (len > 7) out.add('这次经期记了 $len 天，超过 7 天建议留意');
  final since = d.lastEp == null ? 0 : d.todayN - d.lastEp!.start;
  if (d.lastEp != null && since > _maxInt(45, d.cycle + 21)) {
    out.add('距离上一次经期已经 $since 天，可能漏记了');
  }
  return out;
}

// ── cycleHero `:246-277` 的展示换算（只消费引擎结果） ───────────────────

/// Web `R=31, C=+(2πR).toFixed(1)` → 194.8。
double get ringCircumference =>
    double.parse((2 * math.pi * 31).toStringAsFixed(1));

/// `:252` `pct=max(4,round(dayIn/cyc*100))`；`dayIn` 只取 [dayInCycle]。
int heroPercent(PeriodData d) {
  final cyc = d.cycle < 1 ? 1 : d.cycle;
  final pct = _jsRound(dayInCycle(d) / cyc * 100);
  return pct < 4 ? 4 : pct;
}

/// `:271` `stroke-dashoffset`（字符串，逐字对拍 Web 实跑值）。
String ringOffset(PeriodData d) =>
    (ringCircumference * (1 - heroPercent(d) / 100)).toStringAsFixed(1);

/// `:254-256` 阶段标题（Web 的 `<em>预测</em>` 在 App 里直接跟「预测」二字）。
String heroTitle(PeriodData d, String today) {
  final ph = todayPhase(d, today: today);
  if (ph != null) {
    return '当前阶段：${phaseCard[ph.phase] ?? ph.phase}'
        '${ph.predicted ? '预测' : ''}';
  }
  final until = d.untilNext;
  return until != null && until < 0 ? '已推迟 ${-until} 天' : '周期还在推算';
}

/// `:257-259` 照护提示。
String heroTip(PeriodData d, String today) {
  final ph = todayPhase(d, today: today);
  if (d.inWindow) {
    return '今天是经期第 ${d.dayOfPeriod} 天，${phaseCare['period']}';
  }
  if (ph != null) return phaseCare[ph.phase] ?? '';
  final until = d.untilNext;
  return until != null && until >= 0
      ? '预计还有 $until 天'
      : '记一次就能重新推算';
}

/// `:260` 受孕概率（无阶段时 null）；**不给百分比**，免责语见 [fertilityNote]。
List<String>? fertilityOf(PeriodData d, String today) {
  final ph = todayPhase(d, today: today);
  return ph == null ? null : fertility[ph.phase];
}

/// `:488` 下次预计行：`dayStr(nextStart)` 的月/日 +（参考值）+ 还有/已推迟。
String heroNextLine(PeriodData d) {
  final iso = d.nextStartStr;
  if (iso == null) return '下次预计 记一次就能推算';
  final m = int.parse(iso.substring(5, 7));
  final day = int.parse(iso.substring(8, 10));
  final until = d.untilNext ?? 0;
  final tail = until >= 0 ? '还有 $until 天' : '已推迟 ${-until} 天';
  return '下次预计 $m 月 $day 日${d.estimated ? '（参考值）' : ''} · $tail';
}

// ── phaseBar `:281-289`（相对天数权重，绝不用绝对 dayNum） ───────────────

class PhaseSegment {
  const PhaseSegment(this.phase, this.name, this.days);

  final String phase;
  final String name;
  final int days;
}

/// `:283-285` 四段权重 `[len, max(1,ovuRel-5-len), 7, max(1,cyc-ovuRel-2)]`。
List<PhaseSegment> phaseSegments(PeriodData d) {
  final cyc = d.cycle < 1 ? 1 : d.cycle;
  final len = d.length < 1 ? 1 : d.length;
  final ovuRel = cyc - 14;
  return <PhaseSegment>[
    PhaseSegment('period', '月经期', len),
    PhaseSegment('follicular', '卵泡期', _maxInt(1, ovuRel - 5 - len)),
    PhaseSegment('fertile', '排卵期', 7),
    PhaseSegment('luteal', '黄体期', _maxInt(1, cyc - ovuRel - 2)),
  ];
}

/// `:286` 游标 `min(100,max(0,(todayN-s+1)/cyc*100))`，s 取 `d.last.body.start`。
double phaseCursor(PeriodData d) {
  final last = d.last;
  if (last == null) return 0;
  final cyc = d.cycle < 1 ? 1 : d.cycle;
  final pos = (d.todayN - dayNum(last.start) + 1) / cyc * 100;
  if (pos < 0) return 0;
  if (pos > 100) return 100;
  return pos;
}

// ── 症状统计 `periodPage :493-499` ────────────────────────────────────

class SymptomCount {
  const SymptomCount(this.name, this.count);

  final String name;
  final int count;
}

class SymptomSummary {
  const SymptomSummary({
    required this.items,
    required this.total,
    required this.spread,
    required this.note,
  });

  /// top6（按次数降序，同次数保持插入序）。
  final List<SymptomCount> items;
  final int total;
  final int spread;
  final String note;
}

SymptomSummary symptomSummary(PeriodData d, List<PeriodRow> records) {
  final spread = d.gaps.length > 1
      ? d.gaps.reduce(math.max) - d.gaps.reduce(math.min)
      : 0;
  final counts = <String, int>{};
  final order = <String>[];
  void addAll(Map<String, dynamic> b) {
    final v = b['symptoms'];
    if (v is! List) return;
    for (final raw in v) {
      final s = raw.toString();
      if (s == '没有症状') continue;
      if (!counts.containsKey(s)) order.add(s);
      counts[s] = (counts[s] ?? 0) + 1;
    }
  }

  for (final r in records) {
    if (r.isDayRow) addAll(r.body);
  }
  // Web 用 `d.items`（经期**行**，含碎片），不是 episodes。
  for (final r in d.items) {
    addAll(r.body);
  }

  final sorted = List<String>.from(order)
    ..sort((a, b) {
      final c = counts[b]!.compareTo(counts[a]!);
      return c != 0 ? c : order.indexOf(a).compareTo(order.indexOf(b));
    });
  final items = sorted
      .take(6)
      .map((s) => SymptomCount(s, counts[s]!))
      .toList();
  final dayCount = periodDayRowsOf(records).length;
  final rawTotal = dayCount + d.episodes.length;
  final total = rawTotal < 1 ? 1 : rawTotal;
  final note = spread > 7
      ? '周期波动 $spread 天，波动大的时候多留一点休息的时间。'
      : '周期还算规律，保持记录会更准。';
  return SymptomSummary(
      items: items, total: total, spread: spread, note: note);
}

/// 历史卡「记了 N 天细节」（`:504`）：日记录行 date 落在段区间内的条数。
int episodeDetailDays(PeriodEpisode ep, List<PeriodRow> records) {
  var n = 0;
  for (final r in records) {
    if (!r.isDayRow) continue;
    final dn = dayNum(periodIso10(r.date));
    if (dn >= ep.start && dn <= ep.end) n++;
  }
  return n;
}

/// 历史卡备注拼接（`:507`）。
String episodeWords(PeriodEpisode ep) => ep.frags
    .map((r) => (r.body['content'] ?? '').toString())
    .where((s) => s.isNotEmpty)
    .join('\n');

/// 历史卡症状 chips（`:506`，去重保序）。
List<String> episodeSymptoms(PeriodEpisode ep) {
  final out = <String>[];
  for (final r in ep.frags) {
    final v = r.body['symptoms'];
    if (v is! List) continue;
    for (final raw in v) {
      final s = raw.toString();
      if (!out.contains(s)) out.add(s);
    }
  }
  return out;
}
