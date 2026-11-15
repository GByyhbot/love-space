/// 生理数据分析统计层（条目 8 · 段 C · 纯 Dart，**单一实现**）。
///
/// 逐字移植 `static/period.js`：
/// · `paMean/paSd/paRound/paMD` `:526-529`；
/// · 图表件 `paGrouped/paVBars/paLine/paDotRows` `:532-587`（`:524` 注释
///   「不引 Chart.js」——本文件只产出几何描述 [PaSvg]，由 [PaChartPainter]
///   一类的 CustomPaint 消费，不引任何图表库）；
/// · `periodAnalysis(d)` `:591-670`（完整度 / nth / nthColor / nthDischarge /
///   keySeries / cycleRows / 爱爱 / symCount / moodCount / 规律度）；
/// · `periodAnalysisPage()` `:674-807` 的 13 板块文案与数字，全部收敛进
///   [AnalysisView]（纯数据 + [AnalysisView.toJson] 可与 Web 实跑逐项对拍）。
///
/// 🔴 硬边界：**只消费 8-A [PeriodData] / [dayNum] / [dayStr] / [PeriodRow] /
/// [PeriodEpisode]**，不重算 cycle / length / nextStart / phases / inWindow；
/// 预警复用 [periodWarnings]、常量表复用 `period_meta.dart`，全项目只有一套推算。
/// `today` 为显式字符串入参（空间时区日历日），引擎与统计层都不读本机时钟。
///
/// 🔴 规律度 `:663-665`：`d.gaps.length < 2` 必须为 null，**不硬编分数**；
/// 只有 `>=2` 才按 `min(99,max(40,round(100-min(45,max(0,(sd-1.5)*6)))))` 算。
///
/// 对拍证据：`test/fixtures/period_c_expected.json` 由 Node `vm` 注入
/// `recordsOf/today/esc/button/icon/state` 后**实跑** Web 原函数产出，
/// `test/period_c_portrait_test.dart` 读同一份 cases 夹具逐项断言全等
/// （生成方式见定案文档附录 C.1）。
library;

import 'dart:math' as math;

import 'period_engine.dart';
import 'period_meta.dart';

// ── 常量（`period.js:525` / `:595` / `:673`） ──────────────────────────

/// `:525` 分组柱「近半年」色。
const String paPurple = '#A98BD8';

/// `:595` 数据完整度计入的 9 个字段（与 `PERIOD_LOG_FIELDS :28` 同集合）。
const List<String> paCompletenessFields = <String>[
  'flow', 'color', 'pain', 'sex', 'symptoms', 'mood', 'weight', 'discharge', 'temp',
];

/// `:673` 白带五档色（与 Web `PA_DIS_COLORS` 逐字）。
const Map<int, String> paDisColors = <int, String>{
  1: '#CFBBA6',
  2: '#B9A183',
  3: '#E0C58F',
  4: '#A6D5E4',
  5: '#78C4D8',
};

/// `:677` 页头（Web `back`）。
const String analysisHeadingTitle = '生理数据分析';
const String analysisHeadingDesc = '把这半年的记录，摊成看得懂的变化。';

/// `:678` 空态。
const String analysisEmptyText =
    '还没有经期记录。回到生理期页点一次「月经来了」，这里就会开始长出图表。';
const String analysisBackButton = '回到生理期';

/// `:701` 免责 mini / `:700` 预警小字 / `:805` 尾注。
const String analysisDisclaimer =
    '受孕概率为日历推算（低 / 中 / 高），不能作为避孕依据。';
const String analysisWarnsNote = '按记录推算，不能替代医生判断。';
const String analysisFoot =
    '图表只反映记过的那几天。想让它更准，经期每天顺手点两下就够了。';

/// 13 板块标题（`:688-803` 逐字）。
const String analysisSecPrediction = '🔮 经期预测';
const String analysisSecCycle = '🗓 周期变化';
const String analysisSecLength = '💧 经期变化';
const String analysisSecFlow = '🩸 流量变化';
const String analysisSecPain = '⚡ 痛经情况';
const String analysisSecColor = '🎨 颜色变化';
const String analysisSecSymptoms = '💊 常出现的症状';
const String analysisSecMood = '😊 心情';
const String analysisSecDischarge = '💧 白带变化';
const String analysisSecSex = '💗 爱爱';
const String analysisSecTemp = '🌡️ 体温';
const String analysisSecWeight = '⚖️ 体重';

// ── JS 语义辅助（`:526-529` 的 Math.round / toFixed / slice） ─────────

/// `Math.round(x) === Math.floor(x + 0.5)`。
int _jsRound(double v) => (v + 0.5).floor();

/// `String.prototype.toFixed(1)` 的 Dart 等价（已核对 JS/Dart 舍入一致；
/// 唯一差异 `-0.0` → JS 输出 `0.0`，此处归一化）。
String _f1(double v) => (v == 0 ? 0.0 : v).toStringAsFixed(1);

/// JS 数字转字符串（`String(v)`：整数不带 `.0`）。
String _jsNum(num v) {
  if (v is int) return v.toString();
  final d = v.toDouble();
  if (d.isFinite && d == d.truncateToDouble()) return d.toInt().toString();
  return d.toString();
}

/// JS 对象键（`obj[v]` 会把数字键转成字符串）。
String _jsKey(Object? v) {
  if (v is num) return _jsNum(v);
  return v.toString();
}

/// `String.prototype.slice(start, end)`（本项目只用到非负 end）。
String _jsSlice(String s, int start, [int? end]) {
  final len = s.length;
  int clamp(int i) => i < 0 ? (len + i).clamp(0, len) : i.clamp(0, len);
  final a = clamp(start);
  final b = end == null ? len : clamp(end);
  return b <= a ? '' : s.substring(a, b);
}

/// HTML 实体转义（Web `app.js:18` `esc`）；分析页文案无特殊字符，仍逐字保留。
String _esc(Object? v) => (v ?? '')
    .toString()
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

/// 去标签（仅用于生成 `leadText` 之类与 Web 实跑 HTML 比对的字符串）。
String _stripTags(String s) => s.replaceAll(RegExp(r'<[^>]*>'), '').trim();

int _intKey(Object? v) {
  if (v is num) return v.isNaN ? 0 : v.toInt();
  return int.tryParse(v.toString()) ?? 0;
}

/// JS `obj?.[key]` 等价（Dart 无 `?[]` 运算符）。
Object? _get(Object? obj, Object? key) {
  if (obj == null || key == null) return null;
  if (obj is Map) return obj[key];
  if (obj is List && key is int) return key < obj.length ? obj[key] : null;
  return null;
}

/// `typeof v === 'number'` 等价。
num? _numOf(Object? v) => v is num ? v : null;

/// `list?.[i]` 等价（常量表周期色 / 白带档位）。
String? _strAt(List<String>? l, int i) =>
    (l == null || i < 0 || i >= l.length) ? null : l[i];

// ── `:526-529` 纯统计函数 ────────────────────────────────────────────

/// `:526` `paMean=a=>a.length?a.reduce((s,v)=>s+v,0)/a.length:0`。
double paMean(List<num> a) =>
    a.isEmpty ? 0.0 : a.fold<double>(0.0, (s, v) => s + v.toDouble()) / a.length;

/// `:527` `paSd`：样本 <2 给 0；否则总体标准差。
double paSd(List<num> a) {
  if (a.length < 2) return 0.0;
  final m = paMean(a);
  return math.sqrt(paMean(a.map((v) => (v.toDouble() - m) * (v.toDouble() - m)).toList()));
}

/// `:528` `paRound=(v,n=0)=>{const p=10**n;return Math.round(v*p)/p;}`。
double paRound(double v, [int n = 0]) {
  final p = math.pow(10, n).toDouble();
  return _jsRound(v * p) / p;
}

/// `:529` `paMD=s=>\`${Number(s.slice(5,7))} 月 ${Number(s.slice(8,10))} 日\``。
String paMD(String s) =>
    '${int.parse(_jsSlice(s, 5, 7))} 月 ${int.parse(_jsSlice(s, 8, 10))} 日';

// ── 返回值结构（对齐 `:666-669`） ────────────────────────────────────

/// `nth(key)` 的一行：本次第 i 天 [cur] 与近半年同期均值 [hist]。
class PaNthRow {
  const PaNthRow(this.label, this.cur, this.hist);

  final String label;
  final num? cur;
  final num? hist;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'label': label, 'cur': cur, 'hist': hist};
}

/// `nthColor` / `nthDischarge` 的 `{cur,his,n}`。
class PaBuf {
  const PaBuf(this.cur, this.his, this.n);

  final List<num?> cur;
  final List<num?> his;
  final int n;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'cur': cur, 'his': his, 'n': n};
}

/// `cycleRows` 的一行：`cur=true` 为最后一段（报「当前第 N 天」）。
class PaCycleRow {
  const PaCycleRow({
    required this.cur,
    required this.date,
    this.gap,
    this.days,
  });

  final bool cur;
  final int date;
  final int? gap;
  final int? days;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'cur': cur, 'date': date, 'gap': gap, 'days': days,
      };
}

/// `keySeries` 的一个点 / `paLine` 的一个点。
class PaSeriesPoint {
  const PaSeriesPoint(this.label, this.v);

  final String label;
  final num v;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'label': label, 'v': v};
}

/// `monthly` 的一行（近 6 个月爱爱次数）。
class PaMonthlyRow {
  const PaMonthlyRow(this.label, this.v, this.now);

  final String label;
  final int v;
  final bool now;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'label': label, 'v': v, 'now': now};
}

/// `periodAnalysis(d)` `:666-669` 的完整返回结构。
class PeriodAnalysis {
  const PeriodAnalysis({
    required this.eps,
    required this.last,
    required this.prev,
    required this.complete,
    required this.slots,
    required this.filled,
    required this.flow,
    required this.pain,
    required this.color,
    required this.discharge,
    required this.cycleRows,
    required this.cycleMax,
    required this.sexCount,
    required this.sexThisCycle,
    required this.monthly,
    required this.symCount,
    required this.moodCount,
    required this.sd,
    required this.score,
    required this.temp,
    required this.weight,
    required this.dayRows,
  });

  final List<PeriodEpisode> eps;
  final PeriodEpisode? last;
  final PeriodEpisode? prev;
  final int complete;
  final int slots;
  final int filled;
  final List<PaNthRow> flow;
  final List<PaNthRow> pain;
  final PaBuf color;
  final PaBuf discharge;
  final List<PaCycleRow> cycleRows;
  final int cycleMax;
  final int sexCount;
  final int sexThisCycle;
  final List<PaMonthlyRow> monthly;
  final Map<String, int> symCount;
  final Map<String, int> moodCount;
  final double sd;

  /// 🔴 `gaps.length < 2` 时为 null（`:665`），绝不硬编分数。
  final int? score;
  final List<PaSeriesPoint> temp;
  final List<PaSeriesPoint> weight;

  /// `periodDayRows()` 数量（概览三联统计 `:698` 要用到）。
  final int dayRows;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'eps': eps.map(_epJson).toList(),
        'last': _epJson(last),
        'prev': _epJson(prev),
        'complete': complete,
        'slots': slots,
        'filled': filled,
        'flow': flow.map((r) => r.toJson()).toList(),
        'pain': pain.map((r) => r.toJson()).toList(),
        'color': color.toJson(),
        'discharge': discharge.toJson(),
        'cycleRows': cycleRows.map((r) => r.toJson()).toList(),
        'cycleMax': cycleMax,
        'sexCount': sexCount,
        'sexThisCycle': sexThisCycle,
        'monthly': monthly.map((r) => r.toJson()).toList(),
        'symCount': symCount,
        'moodCount': moodCount,
        'sd': sd,
        'score': score,
        'temp': temp.map((r) => r.toJson()).toList(),
        'weight': weight.map((r) => r.toJson()).toList(),
      };
}

Map<String, dynamic>? _epJson(PeriodEpisode? e) => e == null
    ? null
    : <String, dynamic>{
        'start': e.start,
        'end': e.end,
        'length': e.length,
        'recId': e.rec.id,
        'fragIds': e.frags.map((f) => f.id).toList(),
      };

// ── `:591-670` periodAnalysis 逐条移植 ──────────────────────────────

/// `periodDayLogs()` `:36`：日记录按 `date.slice(0,10)` 建表（后者覆盖前者）。
Map<String, Map<String, dynamic>> _dayLogs(List<PeriodRow> records) {
  final map = <String, Map<String, dynamic>>{};
  for (final r in records) {
    if (!r.isDayRow) continue;
    map[_jsSlice(r.date, 0, 10)] = r.body;
  }
  return map;
}

/// `:599` 某天 9 字段是否至少填上了一项。
bool _filled(Object? body) {
  if (body == null) return false;
  final b = body as Map<String, dynamic>;
  for (final k in paCompletenessFields) {
    final v = b[k];
    if (v is List) {
      if (v.isNotEmpty) return true;
    } else if (v != null && v != '') {
      return true;
    }
  }
  return false;
}

/// `:618` 众数：出现次数最多者；并列时取最先出现者（V8 稳定排序等价）。
num? _mode(List<num> h) {
  if (h.isEmpty) return null;
  final counts = <num, int>{};
  for (final v in h) {
    counts[v] = (counts[v] ?? 0) + 1;
  }
  var best = h.first;
  var bestCount = counts[best]!;
  for (final v in h) {
    final c = counts[v]!;
    if (c > bestCount) {
      best = v;
      bestCount = c;
    }
  }
  return best;
}

/// `keySeries(key,limit=12)` `:631-635`。
List<PaSeriesPoint> _keySeries(List<PeriodRow> dayRows, String key, [int limit = 12]) {
  final rows = dayRows
      .where((r) => r.body[key] is num)
      .toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  final start = rows.length > limit ? rows.length - limit : 0;
  return <PaSeriesPoint>[
    for (final r in rows.sublist(start))
      PaSeriesPoint(_jsSlice(r.date, 5, 10).replaceFirst('-', '/'), r.body[key] as num),
  ];
}

/// 逐字移植 `period.js:591-670` `periodAnalysis(d)`。
///
/// [d] 必须由 8-A [periodData] 产出；[records] 为同一份未删 period 记录；
/// [today] 为空间时区日历日（`yyyy-MM-dd`，供 `:651` monthly 使用）。
PeriodAnalysis periodAnalysis(PeriodData d, List<PeriodRow> records,
    {required String today}) {
  final eps = d.episodes;
  final logs = _dayLogs(records);
  final dayRows = periodDayRowsOf(records);
  Map<String, dynamic>? at(int n) => logs[dayStr(n)];

  final last = eps.isEmpty ? null : eps.last;
  final prev = eps.length < 2 ? null : eps[eps.length - 2];

  // `:597-600` 数据完整度：经期里每一天都算一格，记了至少一项算填上。
  var slots = 0;
  var filled = 0;
  for (final e in eps) {
    for (var i = 0; i < e.length; i++) {
      slots++;
      if (_filled(at(e.start + i))) filled++;
    }
  }
  final complete = slots > 0 ? _jsRound(filled / slots * 100) : 0;

  // `:601` 横轴上限。
  var maxLen = 1;
  for (final e in eps) {
    if (e.length > maxLen) maxLen = e.length;
  }
  if (maxLen > 7) maxLen = 7;

  // `:602-611` nth(key)。
  List<PaNthRow> nth(String key) {
    final rows = <PaNthRow>[];
    for (var i = 0; i < maxLen; i++) {
      final cb = (last != null && i < last.length) ? at(last.start + i) : null;
      final cv = _get(cb, key);
      final num? cur = cb != null ? (cv is num ? cv : null) : null;
      final hist = <num>[];
      for (final e in eps) {
        if (identical(e, last) || i >= e.length) continue;
        final v = _get(at(e.start + i), key);
        if (v is num) hist.add(v);
      }
      if (cur == null && hist.isEmpty) continue;
      rows.add(PaNthRow('第${i + 1}天', cur,
          hist.isEmpty ? null : paRound(paMean(hist))));
    }
    return rows;
  }

  // `:612-621` nthColor（历史同期取众数）。
  var bufN = 1;
  for (final e in eps) {
    if (e.length > bufN) bufN = e.length;
  }
  if (bufN > 5) bufN = 5;

  PaBuf nthColor() {
    final cur = <num?>[];
    final his = <num?>[];
    for (var i = 0; i < bufN; i++) {
      cur.add((last != null && i < last.length)
          ? _numOf(_get(at(last.start + i), 'color'))
          : null);
      final h = <num>[];
      for (final e in eps) {
        if (identical(e, last) || i >= e.length) continue;
        final v = _get(at(e.start + i), 'color');
        if (v is num) h.add(v);
      }
      his.add(h.isEmpty ? null : _mode(h));
    }
    return PaBuf(cur, his, bufN);
  }

  // `:622-630` nthDischarge（历史同期取均值）。
  PaBuf nthDischarge() {
    final cur = <num?>[];
    final his = <num?>[];
    for (var i = 0; i < bufN; i++) {
      cur.add((last != null && i < last.length)
          ? _numOf(_get(at(last.start + i), 'discharge'))
          : null);
      final h = <num>[];
      for (final e in eps) {
        if (identical(e, last) || i >= e.length) continue;
        final v = _get(at(e.start + i), 'discharge');
        if (v is num) h.add(v);
      }
      his.add(h.isEmpty ? null : paRound(paMean(h)));
    }
    return PaBuf(cur, his, bufN);
  }

  // `:638-644` 周期行：从新到旧，gap 记在「该段开始日」。
  final cycleRows = <PaCycleRow>[];
  for (var i = eps.length - 1; i >= 0; i--) {
    final e = eps[i];
    final next = i + 1 < eps.length ? eps[i + 1] : null;
    if (next != null) {
      cycleRows.add(PaCycleRow(cur: false, date: e.start, gap: next.start - e.start));
    } else {
      cycleRows.add(PaCycleRow(
          cur: true, date: e.start, days: d.todayN - e.start + 1));
    }
  }
  var cycleMax = 1;
  for (final r in cycleRows) {
    final v = r.cur ? r.days! : r.gap!;
    if (v > cycleMax) cycleMax = v;
  }

  // `:646-657` 爱爱。
  final sexRows = dayRows
      .where((r) => r.body['sex'] is List && (r.body['sex'] as List).isNotEmpty)
      .toList();
  int sexLen(PeriodRow r) => (r.body['sex'] as List).length;
  final sexCount = sexRows.fold<int>(0, (s, r) => s + sexLen(r));
  var sexThisCycle = 0;
  if (last != null) {
    for (final r in sexRows) {
      final n = dayNum(r.date);
      if (n >= last.start && n <= last.end) sexThisCycle += sexLen(r);
    }
  }

  final y0 = int.parse(_jsSlice(today, 0, 4));
  final m0 = int.parse(_jsSlice(today, 5, 7));
  final monthly = <PaMonthlyRow>[];
  for (var k = 5; k >= 0; k--) {
    var mm = m0 - k;
    var yy = y0;
    while (mm < 1) {
      mm += 12;
      yy -= 1;
    }
    final pre = '$yy-${mm.toString().padLeft(2, '0')}';
    var v = 0;
    for (final r in sexRows) {
      if (_jsSlice(r.date, 0, 7) == pre) v += sexLen(r);
    }
    monthly.add(PaMonthlyRow('$mm' '月', v, k == 0));
  }

  // `:658-660` 症状排行（日记录 + 每次经期最后一条碎片，排除「没有症状」）。
  final symCount = <String, int>{};
  void countSymptoms(PeriodRow r) {
    final list = r.body['symptoms'];
    if (list is! List) return;
    for (final s in list) {
      if (s == '没有症状') continue;
      final k = s.toString();
      symCount[k] = (symCount[k] ?? 0) + 1;
    }
  }

  for (final r in dayRows) {
    countSymptoms(r);
  }
  for (final e in eps) {
    countSymptoms(e.rec);
  }

  // `:661-662` 心情（只数日记录，且 mood truthy）。
  final moodCount = <String, int>{};
  for (final r in dayRows) {
    final v = r.body['mood'];
    if (!jsTruthy(v)) continue;
    final k = _jsKey(v);
    moodCount[k] = (moodCount[k] ?? 0) + 1;
  }

  // `:663-665` 规律度：样本 <2 个间隔时必须为 null。
  final gapNums = <num>[for (final g in d.gaps) g];
  final sd = paSd(gapNums);
  final int? score = d.gaps.length >= 2
      ? math.min(
          99,
          math.max(40, _jsRound(100 - math.min(45, math.max(0, (sd - 1.5) * 6)))))
      : null;

  return PeriodAnalysis(
    eps: eps,
    last: last,
    prev: prev,
    complete: complete,
    slots: slots,
    filled: filled,
    flow: nth('flow'),
    pain: nth('pain'),
    color: nthColor(),
    discharge: nthDischarge(),
    cycleRows: cycleRows,
    cycleMax: cycleMax,
    sexCount: sexCount,
    sexThisCycle: sexThisCycle,
    monthly: monthly,
    symCount: symCount,
    moodCount: moodCount,
    sd: sd,
    score: score,
    temp: _keySeries(dayRows, 'temp'),
    weight: _keySeries(dayRows, 'weight'),
    dayRows: dayRows.length,
  );
}

// ── `:532-587` 图表几何（纯数据，供 CustomPaint 与对拍共用） ─────────

/// SVG 元素描述（与 Web 实跑 HTML 解析出的结构逐项对齐）。
class PaSvgElement {
  const PaSvgElement(this.tag, this.attrs, [this.text]);

  final String tag;
  final Map<String, String> attrs;
  final String? text;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'tag': tag,
        'attrs': attrs,
        'text': ?text,
      };
}

/// 一张手画图（`:540` `viewBox="0 0 320 h" width="100%"`）。
class PaSvg {
  const PaSvg(this.aria, this.height, this.els);

  final String aria;
  final int height;
  final List<PaSvgElement> els;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'aria': aria,
        'viewBox': '0 0 320 $height',
        'w': '100%',
        'h': '$height',
        'els': els.map((e) => e.toJson()).toList(),
      };
}

PaSvgElement _rect({
  required double x,
  required double y,
  required double width,
  required double height,
  required String rx,
  required String fill,
  String? stroke,
  String? dash,
  bool rawY = false,
  bool rawHeight = false,
}) =>
    PaSvgElement('rect', <String, String>{
      'x': _f1(x),
      'y': rawY ? _jsNum(y) : _f1(y),
      'width': _f1(width),
      'height': rawHeight ? _jsNum(height) : _f1(height),
      'rx': rx,
      'fill': fill,
      'stroke': ?stroke,
      'stroke-dasharray': ?dash,
    });

/// `paVBars` 的一行。
class PaBarRow {
  const PaBarRow(this.label, this.v, this.now);

  final String label;
  final num v;
  final bool now;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'label': label, 'v': v, 'now': now};
}

/// `:532-546` paGrouped：每天一组，左本周期、右近半年；未记录画虚线空框。
PaSvg paGrouped(List<PaNthRow> rows, {double? max, int? h, String aria = ''}) {
  const w = 320.0;
  final height = h ?? (rows.length <= 2 ? 84 : 104);
  const top = 10.0;
  final base = height - 22.0;
  final n = rows.isEmpty ? 1 : rows.length;
  final slot = w / n;
  var mx = max ?? 1.0;
  if (max == null) {
    for (final r in rows) {
      for (final v in <num?>[r.cur, r.hist]) {
        if (v is num && v.toDouble() > mx) mx = v.toDouble();
      }
    }
  }
  final bw = math.min(12.0, slot * 0.26);
  double y(num v) => base - (base - top) * (v.toDouble() / mx);

  PaSvgElement bar(double x, num? v, String fill) {
    if (v is num && v.toDouble() > 0) {
      return _rect(
          x: x,
          y: y(v),
          width: bw,
          height: base - y(v),
          rx: '3',
          fill: fill);
    }
    return _rect(
        x: x,
        y: base - 18,
        width: bw,
        height: 18,
        rx: '3',
        fill: 'none',
        stroke: 'var(--line)',
        dash: '3 3',
        rawY: true,
        rawHeight: true);
  }

  final els = <PaSvgElement>[
    for (final f in <double>[0, 0.5, 1])
      PaSvgElement('line', <String, String>{
        'x1': '0',
        'x2': _jsNum(w),
        'y1': _f1(top + (base - top) * f),
        'y2': _f1(top + (base - top) * f),
        'stroke': 'var(--line)',
        'stroke-dasharray': '2 4',
      }),
  ];
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    final c = slot * i + slot / 2;
    els.add(bar(c - bw - 2, r.cur, 'var(--primary)'));
    els.add(bar(c + 2, r.hist, paPurple));
    els.add(PaSvgElement('text', <String, String>{
      'x': _f1(c),
      'y': _jsNum(base + 14),
      'text-anchor': 'middle',
      'class': 'pa-tick',
    }, _esc(r.label)));
  }
  return PaSvg(aria, height, els);
}

/// `:548-561` paVBars：近期经期天数、每月爱爱次数。
PaSvg paVBars(List<PaBarRow> rows, {double? max, int? h, String aria = ''}) {
  const w = 320.0;
  final height = h ?? (rows.length <= 3 ? 86 : 96);
  const top = 12.0;
  final base = height - 22.0;
  final n = rows.isEmpty ? 1 : rows.length;
  final slot = w / n;
  var mx = max ?? 1.0;
  if (max == null) {
    for (final r in rows) {
      final v = r.v.toDouble();
      if (v > mx) mx = v;
    }
  }
  final bw = math.min(18.0, slot * 0.44);
  final els = <PaSvgElement>[
    PaSvgElement('line', <String, String>{
      'x1': '0',
      'x2': _jsNum(w),
      'y1': _jsNum(base),
      'y2': _jsNum(base),
      'stroke': 'var(--line)',
    }),
  ];
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    final c = slot * i + slot / 2;
    final v = r.v.toDouble();
    final hh = (base - top) * (v / mx);
    final h1 = v > 0 ? hh : 3.0;
    final fill = v > 0
        ? (r.now ? 'var(--primary)' : 'var(--soft-strong)')
        : 'var(--line)';
    els.add(_rect(
        x: c - bw / 2,
        y: base - h1,
        width: bw,
        height: h1,
        rx: '4',
        fill: fill));
    if (v != 0) {
      els.add(PaSvgElement('text', <String, String>{
        'x': _f1(c),
        'y': _f1(base - hh - 6),
        'text-anchor': 'middle',
        'class': 'pa-val',
      }, _jsNum(r.v)));
    }
    els.add(PaSvgElement('text', <String, String>{
      'x': _f1(c),
      'y': _jsNum(base + 14),
      'text-anchor': 'middle',
      'class': 'pa-tick',
    }, _esc(r.label)));
  }
  return PaSvg(aria, height, els);
}

/// `:563-581` paLine：只在首尾与最高最低处标数值。
PaSvg? paLine(List<PaSeriesPoint> pts,
    {int h = 104, String color = '#2F9E88', String Function(num)? fmt, String aria = ''}) {
  final list = pts.where((p) => _numOf(p.v) != null).toList();
  if (list.length < 2) return null;
  const w = 320.0;
  const top = 18.0;
  final base = h - 22.0;
  var lo = list.map((p) => p.v.toDouble()).reduce(math.min);
  var hi = list.map((p) => p.v.toDouble()).reduce(math.max);
  if (hi - lo < 0.4) {
    hi += 0.2;
    lo -= 0.2;
  }
  double x(int i) => 18 + (w - 36) * i / (list.length - 1);
  double y(double v) => base - (base - top) * ((v - lo) / (hi - lo));

  var hiIdx = -1;
  var loIdx = -1;
  for (var i = 0; i < list.length; i++) {
    if (hiIdx < 0 && list[i].v.toDouble() == hi) hiIdx = i;
    if (loIdx < 0 && list[i].v.toDouble() == lo) loIdx = i;
  }
  final marked = <int>{0, list.length - 1};
  if (hiIdx >= 0) marked.add(hiIdx);
  if (loIdx >= 0) marked.add(loIdx);

  final d = <String>[
    for (var k = 0; k < list.length; k++)
      '${k > 0 ? 'L' : 'M'}${_f1(x(k))} ${_f1(y(list[k].v.toDouble()))}',
  ].join(' ');

  final els = <PaSvgElement>[
    PaSvgElement('line', <String, String>{
      'x1': '0',
      'x2': _jsNum(w),
      'y1': _jsNum(base),
      'y2': _jsNum(base),
      'stroke': 'var(--line)',
    }),
    PaSvgElement('path', <String, String>{
      'd': d,
      'fill': 'none',
      'stroke': color,
      'stroke-width': '2',
      'stroke-linejoin': 'round',
      'stroke-linecap': 'round',
    }),
  ];
  for (var k = 0; k < list.length; k++) {
    els.add(PaSvgElement('circle', <String, String>{
      'cx': _f1(x(k)),
      'cy': _f1(y(list[k].v.toDouble())),
      'r': '3.5',
      'fill': 'var(--surface)',
      'stroke': color,
      'stroke-width': '2',
    }));
  }
  for (var k = 0; k < list.length; k++) {
    if (!marked.contains(k)) continue;
    final v = list[k].v;
    els.add(PaSvgElement('text', <String, String>{
      'x': _f1(x(k)),
      'y': _f1(y(v.toDouble()) - 8),
      'text-anchor': 'middle',
      'class': 'pa-val',
    }, _esc(fmt == null ? _jsNum(v) : fmt(v))));
  }
  els.add(PaSvgElement('text', <String, String>{
    'x': '2',
    'y': _jsNum(base + 13),
    'class': 'pa-tick',
  }, _esc(list.first.label)));
  els.add(PaSvgElement('text', <String, String>{
    'x': _jsNum(w - 2),
    'y': _jsNum(base + 13),
    'text-anchor': 'end',
    'class': 'pa-tick',
  }, _esc(list.last.label)));
  return PaSvg(aria, h, els);
}

/// `:583-587` paDotRows 的一个格子。
class PaDotCell {
  const PaDotCell(this.color, this.tip);

  final String? color;
  final String tip;

  bool get hollow => color == null;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'hollow': hollow,
        'color': color,
        'tip': tip,
      };
}

/// `:583-587` paDotRows 的一行。
class PaDotRow {
  const PaDotRow(this.name, this.cells);

  final String name;
  final List<PaDotCell> cells;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'cells': cells.map((c) => c.toJson()).toList(),
      };
}

// ── `:674-807` 13 板块视图模型（纯数据，供页面渲染 + 对拍） ──────────

/// `:688-702` 概览。
class AnalysisOverview {
  const AnalysisOverview({
    required this.grade,
    required this.note,
    required this.ringDeg,
    required this.ringLabel,
    required this.meterWidth,
    required this.completeLine,
    required this.stats,
    required this.warns,
    required this.warnsNote,
    required this.mini,
  });

  final String grade;
  final String note;
  final String ringDeg;
  final String ringLabel;
  final String meterWidth;
  final String completeLine;
  final List<String> stats;
  final List<String> warns;
  final String? warnsNote;
  final String mini;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'grade': grade,
        'note': note,
        'ringDeg': ringDeg,
        'ringLabel': ringLabel,
        'meterWidth': meterWidth,
        'completeLine': completeLine,
        'stats': stats,
        'warns': warns,
        'warnsNote': warnsNote,
        'mini': mini,
      };
}

/// `:705-719` 经期预测的一格日期。
class PaDayCell {
  const PaDayCell(this.cls, this.day, this.wd);

  final String cls;
  final int day;
  final String wd;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'cls': cls, 'day': day, 'wd': wd};
}

/// `:705-719` 经期预测。
class AnalysisPrediction {
  const AnalysisPrediction({
    required this.sub,
    required this.lead,
    required this.leadText,
    required this.cells,
    required this.legend,
  });

  final String sub;
  final String lead;
  final String leadText;
  final List<PaDayCell> cells;
  final String legend;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sub': sub,
        'lead': lead,
        'leadText': leadText,
        'cells': cells.map((c) => c.toJson()).toList(),
        'legend': legend,
      };
}

/// `:731` KPI（周期变化 / 经期变化共用）。
class AnalysisKpi {
  const AnalysisKpi(this.value, this.tagCls, this.tag, this.diffText);

  final int value;
  final String tagCls;
  final String tag;
  final String diffText;
}

/// `:723-734` 周期变化的一行。
class PaCycleViewRow {
  const PaCycleViewRow({
    required this.date,
    required this.width,
    required this.days,
    this.chip,
    this.diff,
    this.diffCls = '',
  });

  final String date;
  final int width;
  final int days;
  final String? chip;
  final String? diff;
  final String diffCls;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'date': date,
        'chip': chip,
        'width': width,
        'days': days,
        'diff': diff,
        'diffCls': diffCls,
      };
}

/// `:722-734` 周期变化。
class AnalysisCycle {
  const AnalysisCycle(this.kpi, this.mini, this.rows);

  final AnalysisKpi? kpi;
  final String mini;
  final List<PaCycleViewRow> rows;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kpi': kpi == null
            ? null
            : <String, dynamic>{
                'gapNow': kpi!.value,
                'tagCls': kpi!.tagCls,
                'tag': kpi!.tag,
                'diffText': kpi!.diffText,
              },
        'mini': mini,
        'rows': rows.map((r) => r.toJson()).toList(),
      };
}

/// `:737-745` 经期变化。
class AnalysisLength {
  const AnalysisLength(this.kpi, this.mini, this.bars);

  final AnalysisKpi kpi;
  final String mini;
  final List<PaBarRow> bars;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kpi': <String, dynamic>{
          'lastLen': kpi.value,
          'tagCls': kpi.tagCls,
          'tag': kpi.tag,
          'diffText': kpi.diffText,
        },
        'mini': mini,
      };
}

/// `:778-781` 症状排行一行。
class PaSymRow {
  const PaSymRow(this.name, this.width, this.n);

  final String name;
  final int width;
  final int n;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'name': name, 'width': width, 'n': n};
}

/// `:783-787` 心情 chip。
class PaMoodChip {
  const PaMoodChip(this.emoji, this.name, this.n);

  final String emoji;
  final String name;
  final int n;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'emoji': emoji, 'name': name, 'n': n};
}

/// 一个 Web `sec()` 板块（标题 + 可选副标题 + 主体 widget 类型标记）。
class AnalysisSection {
  const AnalysisSection(this.title, this.sub, this.kind);

  final String title;
  final String sub;
  final String kind;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'title': title, 'sub': sub, 'kind': kind};
}

/// `:674-807` `periodAnalysisPage()` 的完整纯数据模型。
///
/// [toJson] 产出的结构与 Node 实跑 Web 页面后解析出的
/// `period_c_expected.json → cases[n].page` **逐键一致**，供对拍断言全等；
/// 页面 widget 直接消费这些字段，不再自己重算任何数字。
class AnalysisView {
  const AnalysisView({
    required this.isEmpty,
    required this.sections,
    required this.overview,
    required this.prediction,
    required this.cycle,
    required this.length,
    required this.flowText,
    required this.painText,
    required this.symRows,
    required this.moodChips,
    required this.moodTotal,
    required this.sexLine,
    required this.colorDots,
    required this.disDots,
    required this.colorLegend,
    required this.disLegend,
    required this.tempPresent,
    required this.weightPresent,
    required this.legends,
    required this.svgs,
    required this.flowChart,
    required this.painChart,
    required this.lengthChart,
    required this.monthlyChart,
    required this.tempChart,
    required this.weightChart,
  });

  final bool isEmpty;
  final List<AnalysisSection> sections;
  final AnalysisOverview? overview;
  final AnalysisPrediction? prediction;
  final AnalysisCycle? cycle;
  final AnalysisLength? length;
  final String? flowText;
  final String? painText;
  final List<PaSymRow> symRows;
  final List<PaMoodChip> moodChips;
  final String? moodTotal;
  final String? sexLine;
  final List<PaDotRow> colorDots;
  final List<PaDotRow> disDots;
  final String? colorLegend;
  final String? disLegend;
  final bool tempPresent;
  final bool weightPresent;
  final List<String> legends;
  final List<PaSvg> svgs;

  // 页面渲染用的图表几何（与 [svgs] 同源，顺序同 Web 文档流）。
  final PaSvg? flowChart;
  final PaSvg? painChart;
  final PaSvg? lengthChart;
  final PaSvg? monthlyChart;
  final PaSvg? tempChart;
  final PaSvg? weightChart;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'isEmpty': isEmpty,
        'headingTitle': analysisHeadingTitle,
        'headingDesc': analysisHeadingDesc,
        'emptyText': isEmpty ? analysisEmptyText : null,
        'emptyButton': isEmpty ? analysisBackButton : null,
        'sectionTitles': sections.map((s) => s.title).toList(),
        'sectionSubs': <String, String>{
          for (final s in sections) s.title: s.sub,
        },
        'overview': overview?.toJson(),
        'pred': prediction?.toJson(),
        'cycle': cycle?.toJson(),
        'len': length?.toJson(),
        'flowText': flowText,
        'painText': painText,
        'symRows': symRows.map((r) => r.toJson()).toList(),
        'moodChips': moodChips.map((r) => r.toJson()).toList(),
        'moodTotal': moodTotal,
        'sexLine': sexLine,
        'colorDots': colorDots.map((r) => r.toJson()).toList(),
        'disDots': disDots.map((r) => r.toJson()).toList(),
        'colorLegend': colorLegend,
        'disLegend': disLegend,
        'tempPresent': tempPresent,
        'weightPresent': weightPresent,
        // `:678` 空态早返回，不带 `:805` 尾注。
        'foot': isEmpty ? null : analysisFoot,
        'legends': legends,
        'svgs': svgs.map((s) => s.toJson()).toList(),
      };
}

/// JS `Object.entries` 顺序：整数形键按数值升序，其余按插入序。
List<MapEntry<String, int>> _jsEntries(Map<String, int> m) {
  final ints = <MapEntry<String, int>>[];
  final others = <MapEntry<String, int>>[];
  for (final e in m.entries) {
    final n = int.tryParse(e.key);
    if (n != null && n.toString() == e.key && n >= 0) {
      ints.add(e);
    } else {
      others.add(e);
    }
  }
  ints.sort((a, b) => int.parse(a.key).compareTo(int.parse(b.key)));
  return <MapEntry<String, int>>[...ints, ...others];
}

/// 稳定降序（JS `sort((x,y)=>y[1]-x[1])` 在 V8 稳定，并列保持插入序）。
List<T> _stableSortDesc<T>(List<T> src, int Function(T) count) {
  final indexed = <MapEntry<int, T>>[
    for (var i = 0; i < src.length; i++) MapEntry(i, src[i]),
  ];
  indexed.sort((a, b) {
    final c = count(b.value).compareTo(count(a.value));
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  return <T>[for (final e in indexed) e.value];
}

/// `:749-755` flowText / `:760-767` painText 等 13 板块的纯数据计算。
AnalysisView buildAnalysisView(PeriodAnalysis a, PeriodData d) {
  if (a.eps.isEmpty) {
    return AnalysisView(
      isEmpty: true,
      sections: const [],
      overview: null,
      prediction: null,
      cycle: null,
      length: null,
      flowText: null,
      painText: null,
      symRows: const [],
      moodChips: const [],
      moodTotal: null,
      sexLine: null,
      colorDots: const [],
      disDots: const [],
      colorLegend: null,
      disLegend: null,
      tempPresent: false,
      weightPresent: false,
      legends: const [],
      svgs: const [],
      flowChart: null,
      painChart: null,
      lengthChart: null,
      monthlyChart: null,
      tempChart: null,
      weightChart: null,
    );
  }

  final warns = periodWarnings(d);

  // ① 概览 `:684-702`。
  final score = a.score;
  final grade = score == null
      ? '样本还太少'
      : score >= 85
          ? '很规律'
          : score >= 70
              ? '比较规律'
              : score >= 55
                  ? '有些波动'
                  : '波动明显';
  final note = score == null
      ? '至少记满 3 个完整周期，规律度才有意义。'
      : score >= 85
          ? '继续保持，预测会越来越准。'
          : '周期波动 ${_jsNum(paRound(a.sd, 1))} 天，预测日期按前后 '
              '±${math.max(2, _jsRound(a.sd))} 天准备更稳妥。';
  final overview = AnalysisOverview(
    grade: grade,
    note: note,
    ringDeg: _jsNum((score ?? 0) * 3.6),
    ringLabel: score == null ? '--' : '$score',
    meterWidth: '${a.complete}',
    completeLine: '完整度 ${a.complete}%　·　已记 ${a.filled}/${a.slots} 天',
    stats: <String>['${d.cycle}', '${d.length}', '${a.dayRows}'],
    warns: warns,
    warnsNote: warns.isEmpty ? null : analysisWarnsNote,
    mini: analysisDisclaimer,
  );

  // ② 经期预测 `:705-719`。
  AnalysisPrediction? prediction;
  if (d.nextStart != null) {
    final cells = <PaDayCell>[];
    for (var i = -3; i <= 3; i++) {
      final n = d.nextStart! + i;
      final iso = dayStr(n);
      final cls = i == 0 ? 'on' : (i.abs() <= 2 ? 'soft' : '');
      final weekday =
          DateTime.fromMillisecondsSinceEpoch(n * dayMs, isUtc: true).weekday % 7;
      final wd = '日一二三四五六'[weekday];
      cells.add(PaDayCell(cls, int.parse(_jsSlice(iso, 8, 10)), '周$wd'));
    }
    final due = d.untilNext ?? 0;
    final md = paMD(dayStr(d.nextStart!));
    final lead = '预测下次经期将于 <b>$md</b> 开始，'
        '${due >= 0 ? '距离经期开始还有 <b>$due</b> 天' : '已经推迟 <b>${-due}</b> 天'}。';
    prediction = AnalysisPrediction(
      sub: d.estimated ? '参考值' : '',
      lead: lead,
      leadText: _stripTags(lead),
      cells: cells,
      legend: '预测开始日可能的开始日',
    );
  }

  // ③ 周期变化 `:722-734`。
  final cycleRows = <PaCycleViewRow>[];
  for (final r in a.cycleRows.take(6)) {
    final date = paMD(dayStr(r.date));
    if (r.cur) {
      cycleRows.add(PaCycleViewRow(
        date: date,
        width: _jsRound(r.days! / a.cycleMax * 100),
        days: r.days!,
        chip: '当前第 ${r.days} 天',
      ));
    } else {
      final diff = r.gap! - d.cycle;
      final text = diff == 0
          ? '准时'
          : diff < 0
              ? '提前 ${-diff} 天'
              : '推迟 $diff 天';
      cycleRows.add(PaCycleViewRow(
        date: date,
        width: _jsRound(r.gap! / a.cycleMax * 100),
        days: r.gap!,
        diff: text,
        diffCls: diff < 0 ? 'early' : diff > 0 ? 'late' : '',
      ));
    }
  }
  AnalysisKpi? cycleKpi;
  var range = '';
  if (a.eps.length > 1) {
    final gapNow = a.eps.last.start - a.eps[a.eps.length - 2].start;
    final diffNow = gapNow - d.cycle;
    final normal = gapNow >= 21 && gapNow <= 35;
    cycleKpi = AnalysisKpi(
      gapNow,
      normal ? '' : 'warn',
      normal ? '正常' : '需留意',
      diffNow == 0
          ? '相同'
          : diffNow < 0
              ? '短 ${-diffNow} 天'
              : '长 $diffNow 天',
    );
    range = '${paMD(dayStr(a.eps[a.eps.length - 2].start))} – '
        '${paMD(dayStr(a.eps.last.start - 1))}';
  }
  final cycle = AnalysisCycle(
    cycleKpi,
    '近期周期天数${range.isEmpty ? '' : '　·　最近一次 $range'}',
    cycleRows,
  );

  // ④ 经期变化 `:737-745`。
  final tail = a.eps.length > 6 ? a.eps.sublist(a.eps.length - 6) : a.eps;
  final lenBars = <PaBarRow>[
    for (var i = 0; i < tail.length; i++)
      PaBarRow(
        '${int.parse(_jsSlice(dayStr(tail[i].start), 5, 7))}/'
            '${int.parse(_jsSlice(dayStr(tail[i].start), 8, 10))}',
        tail[i].length,
        i == tail.length - 1,
      ),
  ];
  final lastLen = a.last?.length ?? 0;
  final prevLen = a.prev?.length;
  final diff = prevLen == null ? null : lastLen - prevLen;
  final lenNormal = lastLen >= 2 && lastLen <= 7;
  final length = AnalysisLength(
    AnalysisKpi(
      lastLen,
      lenNormal ? '' : 'warn',
      lenNormal ? '正常' : '需留意',
      diff == null
          ? '—'
          : diff == 0
              ? '相同'
              : diff > 0
                  ? '多 $diff 天'
                  : '少 ${-diff} 天',
    ),
    '近期经期天数',
    lenBars,
  );

  // ⑤ 流量 / ⑥ 痛经 `:748-769`。
  String? flowText;
  String? painText;
  PaSvg? flowChart;
  PaSvg? painChart;
  if (a.flow.isNotEmpty) {
    final cur = a.flow.where((r) => r.cur != null).map((r) => r.cur!).toList();
    final his = a.flow.where((r) => r.hist != null).map((r) => r.hist!).toList();
    if (cur.isEmpty) {
      flowText = '这个周期还没记流量';
    } else if (his.isEmpty) {
      flowText = '再多记一次经期，就能和近半年对比';
    } else {
      final dd = paMean(cur) - paMean(his);
      flowText = dd.abs() < 0.4
          ? '和近半年差不多'
          : dd > 0
              ? '比近半年偏多一点（约高 ${_jsNum(paRound(dd, 1))} 档）'
              : '比近半年偏少一点（约低 ${_jsNum(paRound(dd.abs(), 1))} 档）';
    }
    flowChart = paGrouped(a.flow,
        max: 5, aria: '按经期第几天对比本周期与近半年的经量档位');
  }
  if (a.pain.isNotEmpty) {
    final cur = a.pain.where((r) => r.cur != null).toList();
    if (cur.isEmpty) {
      painText = '这个周期还没记痛经';
    } else {
      var peak = cur.first;
      for (final r in cur) {
        if ((r.cur ?? 0).toDouble() > (peak.cur ?? 0).toDouble()) peak = r;
      }
      if (!jsTruthy(peak.cur)) {
        painText = '这个周期完全没痛，挺好的';
      } else {
        final nm = periodPain[_intKey(peak.cur)]?.first ?? '';
        painText = '这个周期最痛是「$nm」，出现在${peak.label}';
      }
    }
    painChart = paGrouped(a.pain,
        max: 5, aria: '按经期第几天对比本周期与近半年的痛经程度');
  }

  // ⑦ 颜色 `:771-776`。
  final usedColors = <int>[];
  for (final v in <num?>[...a.color.cur, ...a.color.his]) {
    if (!jsTruthy(v)) continue;
    final k = _intKey(v);
    if (!usedColors.contains(k)) usedColors.add(k);
  }
  List<PaDotRow> colorDots = const [];
  String? colorLegend;
  if (usedColors.isNotEmpty) {
    List<PaDotCell> cells(List<num?> buf) => <PaDotCell>[
          for (var i = 0; i < buf.length; i++)
            PaDotCell(
              jsTruthy(buf[i]) ? _strAt(periodColor[_intKey(buf[i])], 1) : null,
              jsTruthy(buf[i])
                  ? '第${i + 1}天 ${_strAt(periodColor[_intKey(buf[i])], 0) ?? ''}'
                  : '第${i + 1}天未记录',
            ),
        ];
    colorDots = <PaDotRow>[
      PaDotRow('本周期', cells(a.color.cur)),
      PaDotRow('近半年', cells(a.color.his)),
    ];
    colorLegend = <String>[
      for (final v in usedColors) _strAt(periodColor[v], 0) ?? '',
      '未记录',
    ].join();
  }

  // ⑧ 症状排行 `:778-781`。
  final symEntries = _stableSortDesc<MapEntry<String, int>>(
      _jsEntries(a.symCount), (e) => e.value).take(6).toList();
  final symRows = <PaSymRow>[
    for (final e in symEntries)
      PaSymRow(e.key,
          symEntries.isEmpty ? 0 : _jsRound(e.value / symEntries.first.value * 100),
          e.value),
  ];

  // ⑨ 心情 `:783-787`。
  final moodEntries = _stableSortDesc<MapEntry<String, int>>(
      _jsEntries(a.moodCount), (e) => e.value).take(8).toList();
  final moodChips = <PaMoodChip>[
    for (final e in moodEntries)
      PaMoodChip(
        (int.tryParse(e.key) != null &&
                int.parse(e.key) >= 1 &&
                int.parse(e.key) <= periodMoods.length)
            ? periodMoods[int.parse(e.key) - 1][0]
            : '🙂',
        (int.tryParse(e.key) != null &&
                int.parse(e.key) >= 1 &&
                int.parse(e.key) <= periodMoods.length)
            ? periodMoods[int.parse(e.key) - 1][1]
            : '心情',
        e.value,
      ),
  ];
  final moodTotal = moodEntries.isEmpty
      ? null
      : '${a.moodCount.values.fold<int>(0, (s, n) => s + n)}';

  // ⑩ 白带 `:789-794`。
  final hasDis = a.discharge.cur.any(jsTruthy) || a.discharge.his.any(jsTruthy);
  List<PaDotRow> disDots = const [];
  String? disLegend;
  if (hasDis) {
    List<PaDotCell> cells(List<num?> buf) => <PaDotCell>[
          for (var i = 0; i < buf.length; i++)
            PaDotCell(
              jsTruthy(buf[i]) ? paDisColors[_intKey(buf[i])] : null,
              jsTruthy(buf[i])
                  ? '第${i + 1}天 ${_strAt(periodDischarge[_intKey(buf[i])], 0) ?? ''}'
                  : '第${i + 1}天未记录',
            ),
        ];
    disDots = <PaDotRow>[
      PaDotRow('本周期', cells(a.discharge.cur)),
      PaDotRow('近半年', cells(a.discharge.his)),
    ];
    disLegend = <String>[
      for (final e in periodDischarge.entries) e.value[0],
      '未记录',
    ].join();
  }

  // ⑪ 爱爱 `:796-799`。
  final sexLine = '本周期 ${a.sexThisCycle} 次，累计 ${a.sexCount} 次';
  final monthlyChart = paVBars(
    <PaBarRow>[for (final r in a.monthly) PaBarRow(r.label, r.v, r.now)],
    aria: '近 6 个月每个月的次数',
  );

  // ⑫ 体温 / ⑬ 体重 `:802-803`（>1 条才画线）。
  final tempChart = a.temp.length > 1
      ? paLine(a.temp,
          color: '#2F9E88',
          fmt: (v) => '${_f1(v.toDouble())}℃',
          aria: '体温记录折线')
      : null;
  final weightChart = a.weight.length > 1
      ? paLine(a.weight,
          color: '#7A93C4',
          fmt: (v) => _f1(v.toDouble()),
          aria: '体重记录折线')
      : null;

  // 文档流顺序（与 Web `:806` return 一致）。
  final sections = <AnalysisSection>[
    if (prediction != null)
      AnalysisSection(analysisSecPrediction, prediction.sub, 'pred'),
    AnalysisSection(analysisSecCycle, '', 'cycle'),
    AnalysisSection(analysisSecLength, '', 'len'),
    if (flowChart != null) AnalysisSection(analysisSecFlow, '', 'flow'),
    if (painChart != null) AnalysisSection(analysisSecPain, '', 'pain'),
    if (colorDots.isNotEmpty) AnalysisSection(analysisSecColor, '', 'color'),
    if (symRows.isNotEmpty) AnalysisSection(analysisSecSymptoms, '', 'syms'),
    if (moodChips.isNotEmpty) AnalysisSection(analysisSecMood, '', 'mood'),
    if (disDots.isNotEmpty) AnalysisSection(analysisSecDischarge, '', 'dis'),
    AnalysisSection(analysisSecSex, '', 'sex'),
    if (tempChart != null) AnalysisSection(analysisSecTemp, '', 'temp'),
    if (weightChart != null) AnalysisSection(analysisSecWeight, '', 'weight'),
  ];

  final legends = <String>[
    if (prediction != null) prediction.legend,
    if (flowChart != null) '本周期近半年未记录',
    if (painChart != null) '本周期近半年未记录',
    if (colorDots.isNotEmpty) colorLegend!,
    if (disDots.isNotEmpty) disLegend!,
  ];

  final lengthChart = paVBars(lenBars, aria: '近期每次经期的天数');
  final svgs = <PaSvg>[
    lengthChart,
    ?flowChart,
    ?painChart,
    monthlyChart,
    ?tempChart,
    ?weightChart,
  ];

  return AnalysisView(
    isEmpty: false,
    sections: sections,
    overview: overview,
    prediction: prediction,
    cycle: cycle,
    length: length,
    flowText: flowText,
    painText: painText,
    symRows: symRows,
    moodChips: moodChips,
    moodTotal: moodTotal,
    sexLine: sexLine,
    colorDots: colorDots,
    disDots: disDots,
    colorLegend: colorLegend,
    disLegend: disLegend,
    tempPresent: tempChart != null,
    weightPresent: weightChart != null,
    legends: legends,
    svgs: svgs,
    flowChart: flowChart,
    painChart: painChart,
    lengthChart: lengthChart,
    monthlyChart: monthlyChart,
    tempChart: tempChart,
    weightChart: weightChart,
  );
}

/// `periodData()` 派生字段（对拍 `expected.cases[n].data`）。
Map<String, dynamic> analysisDataJson(PeriodData d, List<PeriodRow> records) =>
    <String, dynamic>{
      'cycle': d.cycle,
      'length': d.length,
      'gaps': d.gaps,
      'todayN': d.todayN,
      'nextStart': d.nextStart,
      'nextStartIso': d.nextStartStr,
      'untilNext': d.untilNext,
      'estimated': d.estimated,
      'inWindow': d.inWindow,
      'dayOfPeriod': d.dayOfPeriod,
      'dayRows': periodDayRowsOf(records).length,
      'warns': periodWarnings(d),
    };
