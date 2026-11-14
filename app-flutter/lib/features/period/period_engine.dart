/// 生理期推算引擎（条目 8 · 段 8-A · D2 对拍前置的**单一实现**）。
///
/// 逐字移植 `static/period.js`：
/// · `dayNum` / `dayStr` / `DAY_MS` —— `:29-31`；
/// · `periodData()` —— `:110-141`（碎片合并 / 有效 gap / 平均周期 / 平均经期 /
///   下次预测 / 今天是否经期 / 经期第几天 / 参考值标记）；
/// · `periodEpisodeOf()` —— `:145-150`（含 owner = 开始日不晚于该天的最后一个碎片）；
/// · `cyclePhases()` —— `:155-170`（四阶段 + 预测先铺、实际覆盖 + ovu 标记）；
/// · `todayPhase()` `:171`、`cycleHero` 的「周期第 N 天」`:249-252` 一并提供，
///   页面状态摘要**只准调用本文件**，不许另写第二套推算。
///
/// 🔴 口径定案（2026-11-14 主人拍板，D2 / C4）：
/// · 无有效 gap 时平均周期回落 `lastEp.rec.body.cycle || 28`（`:128`，**以前端
///   period.js 为准**）；后端 `period.py:325` 直接回落 28 的差异**只留痕、不移植**。
///   对拍夹具 `singleNoGap` 特意用 `cycle:31`（≠28）证明本实现跟的是前端口径。
/// · `dayNum/dayStr` 按 `:30-31` 的 UTC 语义实读移植；`today()` 在 Web 是
///   `app.js` 的全局（本地日期串），这里改为**显式参数 [today] 注入**，
///   保证纯函数、可对拍、不随运行日期漂移。
/// · 经期记录**没有 `end` 键**（`period.js` 全文未见），结束靠改 `length` 或删整条；
///   本文件的 `end` 只是内存里合并段的推算结果，绝不写回 body。
///
/// 对拍证据：`test/fixtures/period_expected.json` 由 Node `vm` 注入
/// `recordsOf/today` 后**实跑** `static/period.js` 的这三个函数产出，
/// `test/period_engine_portrait_test.dart` 用同一份
/// `test/fixtures/period_cases.json` 夹具逐项断言全等（生成方式见定案文档）。
library;

/// 一天的毫秒数（`period.js:29` `DAY_MS=864e5`）。
const int dayMs = 86400000;

/// 对齐 JS `Math.round(x) === Math.floor(x + 0.5)`。
///
/// Dart 的 `num.round()` 对 `.5` 是「远离零」，而 JS 是「向 +∞」；虽然本引擎
/// 输入的平均值恒为正（gap 15–60、经期 1–15），不存在负数差异，仍逐字复刻
/// JS 语义，避免任何潜在的半整数漂移。
int _jsRound(double v) => (v + 0.5).floor();

int _maxInt(int a, int b) => a > b ? a : b;

/// `period.js:118` `Number(r.body.length||1)` 的 Dart 等价：
/// 空 / 0 / NaN / 非数字一律按 1 处理（再由 `Math.max(1, …)` 兜底）。
/// 服务端 `clean_body`（`main.py:1005-1010`）把 length 落为 1–15 的 int，
/// 夹具与真实 API 形状均为 int，此处兼容字符串只是为对齐 JS 的 `Number()`。
int _jsLength(Object? v) {
  if (v == null) return 1;
  if (v is num) return v == 0 || v.isNaN ? 1 : v.toInt();
  final n = num.tryParse(v.toString());
  if (n == null || n == 0 || n.isNaN) return 1;
  return n.toInt();
}

/// `period.js:128` `lastEp?.rec.body.cycle||28` 的 Dart 等价。
///
/// 🔴 C4 定案：以前端为准，回落到**记录自带的 cycle**（可 ≠28），不是硬编码 28；
/// `period.py:325` 的「直接 28」只留痕、不移植。
/// 服务端 `clean_body` 把 cycle 落为 15–60 的 int（`main.py:1005-1010`），
/// 故按数值处理；若历史数据是字符串，Web 的 `startN + avg` 会退化成字符串拼接，
/// 但真实 API 形状不会出现该情形，夹具亦不含。
int _cycleFallback(PeriodEpisode? lastEp) {
  if (lastEp == null) return 28;
  final v = lastEp.rec.body['cycle'];
  if (v == null) return 28;
  if (v is num) return v == 0 || v.isNaN ? 28 : v.toInt();
  final n = num.tryParse(v.toString());
  if (n == null || n == 0 || n.isNaN) return 28;
  return n.toInt();
}

/// `period.js:30` `Math.round(Date.parse(String(s).slice(0,10)+'T00:00:00Z')/DAY_MS)`。
///
/// ISO 日期（或带时间的 ISO 串，取前 10 位）→ 自 1970-01-01 UTC 起的整天数。
/// UTC 午夜的毫秒数恰为 [dayMs] 的整数倍，故 `~/` 与 JS 的 `/`+`Math.round`
/// 结果完全一致。非法输入按 0 兜底（Web 为 NaN；夹具/落库数据均为合法 ISO，
/// 该兜底不参与对拍）。
int dayNum(String s) {
  final raw = s.length >= 10 ? s.substring(0, 10) : s;
  final parts = raw.split('-');
  if (parts.length != 3) return 0;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return 0;
  return DateTime.utc(y, m, d).millisecondsSinceEpoch ~/ dayMs;
}

/// `period.js:31` `new Date(n*DAY_MS).toISOString().slice(0,10)`。
String dayStr(int n) => DateTime.fromMillisecondsSinceEpoch(n * dayMs, isUtc: true)
    .toIso8601String()
    .substring(0, 10);

/// Web `app.js:90` `today()` 的 Dart 对应 —— **本段「今天」的唯一来源**。
///
/// Web 口径（`static/app.js:90` 实读）：
/// `new Intl.DateTimeFormat('sv-SE',{timeZone: state.me?.space.timezone ||
/// 'Asia/Shanghai', year:'numeric', month:'2-digit', day:'2-digit'}).format(new Date())`
/// 返回**空间时区的日历日** `yyyy-MM-dd`；而 `period.js:30` [dayNum] 把这个字符串
/// 按 **UTC 午夜**解析（`String(s).slice(0,10)+'T00:00:00Z'`）。二者组合即
/// 「空间时区当天日期字符串 → UTC 天序号」，本引擎 1:1 保留：
/// [periodData] 的 `today` 是显式字符串入参，`todayN = dayNum(today)`，
/// **引擎内部绝不读 `DateTime.now()`、绝不读设备本机时区**。
///
/// 后端 `space.timezone` 默认恒为 `Asia/Shanghai`（`app/db.py:285`，`main.py`
/// 多处 fallback；本段不做设置页、无法改该值），该时区全年固定 UTC+8、无 DST，
/// 故用「UTC 绝对时刻 + 8h」取年/月/日与 Web `Intl` 结果**逐日一致**。
/// [utcNow] 必须是绝对时刻（调用方传 `DateTime.now().toUtc()`）；对拍时三组夹具
/// 的 today 全部显式注入固定 `'2026-11-14'`，与真实时钟/设备时区完全隔离。
///
/// 🔴 已知偏差（定案文档附录 A.6 留痕）：若空间在 Web 端被改成其它 IANA 时区，
/// Web 会按该时区（含 DST）取日历日，而 Dart 无内置 IANA 库；本段不引入新依赖、
/// 不用 DST 近似冒充精确，仍按默认 UTC+8 处理。后端默认口径下不会命中。
String spaceTodayIso(DateTime utcNow) {
  final local = utcNow.toUtc().add(const Duration(hours: 8));
  return '${local.year}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

/// 一条 period 记录（对齐 `recordsOf('period')` 的元素形状：`{id, author, body}`）。
///
/// 保留原始 [body]：编辑回填铁律需要逐键复制；两种记录形状靠
/// 「有 `start` 无 `date`」（经期区间型）/「有 `date` 无 `start`」（日记录型）区分
/// （`period.js:32-34`、`:66`）。**绝不虚构 `end` 键**。
class PeriodRow {
  const PeriodRow({
    required this.id,
    required this.author,
    required this.body,
  });

  final String id;
  final String author;
  final Map<String, dynamic> body;

  /// 从 `/api/records` 的 JSON 元素解析（测试夹具同形状）。
  factory PeriodRow.fromJson(Map<String, dynamic> j) => PeriodRow(
        id: (j['id'] ?? '').toString(),
        author: (j['author'] ?? '').toString(),
        body: Map<String, dynamic>.from((j['body'] ?? const {}) as Map),
      );

  /// 经期开始日（日记录行为空串）；`period.js:112` 的 `r.body.start` truthy 判定。
  String get start => (body['start'] ?? '').toString();

  /// 日记录日期（经期区间行为空串）；`period.js:34` 的 `r.body.date`。
  String get date => (body['date'] ?? '').toString();

  /// 是否经期区间型（参与推算）；对齐 `period.js:112` `filter(r=>r.body.start)`。
  bool get isEpisodeRow => start.isNotEmpty;

  /// 是否日记录型（不参与推算）；对齐 `period.js:34` `!r.body.start&&r.body.date`。
  bool get isDayRow => start.isEmpty && date.isNotEmpty;
}

/// 合并后的「一次月经」（`period.js:116-124` 的 episode 对象）。
///
/// [end] / [length] / [rec] / [frags] 在合并碎片时会被就地更新，故不用 const。
class PeriodEpisode {
  PeriodEpisode({
    required this.start,
    required this.end,
    required this.length,
    required this.rec,
    required this.frags,
  });

  /// 段的开始日（dayNum），取第一个碎片的 start。
  final int start;

  /// 段的结束日（dayNum，含），= max(各碎片 end)。仅内存推算结果，不写回 body。
  int end;

  /// 合并段长 = end - start + 1。
  int length;

  /// 合并时最后覆盖进来的那条碎片（`period.js:121` `prev.rec=r`）。
  PeriodRow rec;

  /// 组成该段的所有碎片，按 start 升序（来自排序后的 items）。
  final List<PeriodRow> frags;
}

/// `periodData()` 的返回值（`period.js:138-140`）。
class PeriodData {
  const PeriodData({
    required this.items,
    required this.episodes,
    required this.gaps,
    required this.cycle,
    required this.length,
    required this.last,
    required this.lastEp,
    required this.lastLen,
    required this.nextStart,
    required this.todayN,
    required this.inWindow,
    required this.dayOfPeriod,
    required this.untilNext,
    required this.estimated,
  });

  /// 参与推算的经期区间行（按 start 升序）。
  final List<PeriodRow> items;

  /// 碎片合并后的经期段列表。
  final List<PeriodEpisode> episodes;

  /// 有效间隔（仅 15–60 天计入）。
  final List<int> gaps;

  /// 平均周期（无有效 gap 时回落 body.cycle||28）。
  final int cycle;

  /// 平均经期天数（无任何经期记录时为 5）。
  final int length;

  /// 最后一段的最后一条碎片（`period.js:138` `last`）。
  final PeriodRow? last;

  /// 最后一段（`period.js:138` `lastEp`）。
  final PeriodEpisode? lastEp;

  /// 最后一段的实际合并长度（判断今天是否经期用，`:133-137`）。
  final int lastLen;

  /// 下次预测开始日（dayNum），无记录时为 null。
  final int? nextStart;

  /// 今天的 dayNum。
  final int todayN;

  /// 今天是否在最后一次经期的实际窗口内。
  final bool inWindow;

  /// 经期第几天（不在窗口内为 0）。
  final int dayOfPeriod;

  /// 距下次预测还有几天（负数=已推迟）。
  final int? untilNext;

  /// 是否「参考值」（无有效 gap，即按 body.cycle||28 推算）。
  final bool estimated;

  /// 下次预测的 ISO 日期（页面展示用；Web `periodPage()` `:488` 用 `dayStr`）。
  String? get nextStartStr => nextStart == null ? null : dayStr(nextStart!);
}

/// 逐字移植 `period.js:110-141` `periodData()`。
///
/// [records] 为全部 period 记录（含日记录行，会在 :112 被过滤掉）；
/// [today] 为 `yyyy-MM-dd`，对应 Web 全局 `today()` 的注入（纯函数化）。
PeriodData periodData(List<PeriodRow> records, {required String today}) {
  // :112 filter(r=>r.body.start).slice().sort(按 start 的字符串序)
  // 注：JS 用 localeCompare，ISO 日期串全为 ASCII 数字/连字符，与 Dart
  // String.compareTo 的码点序一致；两者对夹具/落库数据结果相同。
  final items = records.where((r) => r.isEpisodeRow).toList()
    ..sort((a, b) => a.start.compareTo(b.start));

  // :116-124 同一次月经常被拆成 2–3 行，按「首尾相接即同一段」合并。
  final episodes = <PeriodEpisode>[];
  for (final r in items) {
    final s = dayNum(r.start);
    final len = _maxInt(1, _jsLength(r.body['length']));
    final e = s + len - 1;
    final prev = episodes.isEmpty ? null : episodes.last;
    if (prev != null && s <= prev.end + 1) {
      prev.end = _maxInt(prev.end, e);
      prev.length = prev.end - prev.start + 1;
      prev.rec = r;
      prev.frags.add(r);
      continue;
    }
    episodes.add(PeriodEpisode(
        start: s, end: e, length: len, rec: r, frags: <PeriodRow>[r]));
  }

  // :125-126 有效间隔：仅相邻两段 start 之差落在 15–60 才计入。
  final gaps = <int>[];
  for (var i = 1; i < episodes.length; i++) {
    final g = episodes[i].start - episodes[i - 1].start;
    if (g >= 15 && g <= 60) gaps.add(g);
  }

  final lastEp = episodes.isEmpty ? null : episodes.last;

  // :128 平均周期：有有效 gap 取平均（JS Math.round），否则回落 body.cycle||28。
  final int avg = gaps.isNotEmpty
      ? _jsRound(gaps.fold<int>(0, (a, b) => a + b) / gaps.length)
      : _cycleFallback(lastEp);

  // :129 平均经期：合并段的平均长度（JS Math.round），无记录时 5。
  final int length = episodes.isEmpty
      ? 5
      : _jsRound(
          episodes.fold<int>(0, (s, e) => s + e.length) / episodes.length);

  // :130-140 今天/下次预测/窗口/经期第几天/参考值。
  final todayN = dayNum(today);
  final startN = lastEp?.start;
  final nextStart = startN != null ? startN + avg : null;
  // :133-137 判断今天在不在经期里必须用「这次记录的实际合并段长」，
  // 不能用平均天数（否则「卵泡期」标题配「经期第 2 天」副标题会自相矛盾）。
  final lastLen = lastEp?.length ?? 5;
  final inWindow =
      startN != null && todayN >= startN && todayN < startN + lastLen;

  return PeriodData(
    items: items,
    episodes: episodes,
    gaps: gaps,
    cycle: avg,
    length: length,
    last: lastEp?.rec,
    lastEp: lastEp,
    lastLen: lastLen,
    nextStart: nextStart,
    todayN: todayN,
    inWindow: inWindow,
    dayOfPeriod: inWindow ? todayN - startN + 1 : 0,
    untilNext: nextStart != null ? nextStart - todayN : null,
    estimated: gaps.isEmpty,
  );
}

/// `periodEpisodeOf()` 的命中结果（`period.js:149` `{ep, owner}`）。
class PeriodEpisodeHit {
  const PeriodEpisodeHit(this.ep, this.owner);
  final PeriodEpisode ep;
  final PeriodRow owner;
}

/// 逐字移植 `period.js:145-150` `periodEpisodeOf(d,n)`。
///
/// 取开始日不晚于这天的最后一个碎片作为 [owner]：这样即便这天正好落在两个
/// 碎片之间的空档（隔一天才又「月经又来了」），改长度也改在正确的那一行上。
PeriodEpisodeHit? periodEpisodeOf(PeriodData d, int n) {
  PeriodEpisode? ep;
  for (final e in d.episodes) {
    if (n >= e.start && n <= e.end) {
      ep = e;
      break; // :146 find 取第一个匹配的段
    }
  }
  if (ep == null) return null;
  PeriodRow? owner;
  for (final r in ep.frags) {
    if (dayNum(r.start) <= n) owner = r; // :148 filter(…).pop() → 最后一个满足
  }
  owner ??= ep.frags.first; // :148 ||ep.frags[0]
  return PeriodEpisodeHit(ep, owner);
}

/// `cyclePhases()` 里某一天的四阶段标记（`period.js:155-165`）。
///
/// [ovu] 只在排卵日被就地置 true（`:164`），其余为 false（JS 里是 undefined，
/// 对拍时统一归一成布尔，不改变 phase/predicted 语义）。
class PhaseMark {
  PhaseMark(this.phase, this.predicted, {this.ovu = false});
  final String phase; // period / follicular / fertile / luteal
  final bool predicted;
  bool ovu;
}

/// 四阶段中文名（`period.js:154` `PHASE_NAMES`），页面展示用。
const phaseNames = <String, String>{
  'period': '月经期',
  'follicular': '卵泡期',
  'fertile': '排卵期',
  'luteal': '黄体期',
};

/// 逐字移植 `period.js:155-170` `cyclePhases(d)`。
///
/// 锚点是每次月经开始日，排卵日按「下次月经前 14 天」推（黄体期长度固定）。
/// 顺序至关重要：先铺预测（远的先写 k=2→0），再用实际记录覆盖 —— 有真实
/// 数据时永远以真实为准（`:166-168`）；`put` 对同一天是**覆盖**语义。
Map<String, PhaseMark> cyclePhases(PeriodData d) {
  final map = <String, PhaseMark>{};
  void mark(int s, int len, bool predicted) {
    final ovu = s + d.cycle - 14;
    void put(int n, String phase) {
      if (n >= 0) map[dayStr(n)] = PhaseMark(phase, predicted);
    }

    for (var i = 0; i < len; i++) {
      put(s + i, 'period');
    }
    for (var i = s + len; i <= ovu - 6; i++) {
      put(i, 'follicular');
    }
    for (var i = ovu - 5; i <= ovu + 1; i++) {
      put(i, 'fertile');
    }
    for (var i = ovu + 2; i < s + d.cycle; i++) {
      put(i, 'luteal');
    }
    final k = dayStr(ovu);
    final existing = map[k];
    if (existing != null) existing.ovu = true; // :164 if(map[k])map[k].ovu=true
  }

  // :167 先铺预测（远的先写），预测经期天数用平均经期 d.length。
  final next = d.nextStart;
  if (next != null) {
    for (var k = 2; k >= 0; k--) {
      mark(next + d.cycle * k, d.length, true);
    }
  }
  // :168 再用实际记录覆盖，实际经期天数用合并段 e.length。
  for (final e in d.episodes) {
    mark(e.start, e.length, false);
  }
  return map;
}

/// `period.js:171` `todayPhase(d)`（Web 用全局 `today()`，这里显式注入）。
PhaseMark? todayPhase(PeriodData d, {required String today}) =>
    cyclePhases(d)[today];

/// `period.js:249-252` `cycleHero` 里的「周期第 N 天」：
/// `min(cyc, max(1, todayN - dayNum(d.last.body.start) + 1))`。
///
/// 🔴 注意用的是 `d.last.body.start`（最后一条**碎片**的开始日），
/// 而非合并段 `lastEp.start` —— 这是 Web 的既有口径，逐字移植，不自作修正。
/// 页面状态摘要只准调用本函数，不许另写一套推算。
int dayInCycle(PeriodData d) {
  final last = d.last;
  if (last == null) return 1;
  final cyc = d.cycle < 1 ? 1 : d.cycle;
  final startN = dayNum(last.start);
  final raw = d.todayN - startN + 1;
  final lo = raw < 1 ? 1 : raw;
  return lo < cyc ? lo : cyc;
}
