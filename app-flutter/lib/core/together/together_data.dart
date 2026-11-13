/// 「我们」页数据层纯函数（条目 6 · 段 A，可单测）。
/// 契约（app/main.py 实读 + static/app.js:1833 recordForm 对照）：
/// · 列表读 = GET /api/records?kind=mood,note,wish,anniversary&limit=1000
///   （Web 同款一次全量、客户端过滤，app.js:270；后端 main.py:1141）；
/// · 写 = POST/PUT/DELETE /api/records，kind 区分；
///   🔴 PUT 是全量替换（clean_body 的 previous 不参与合并，main.py:925）→
///   编辑必须以原始 body 为底增量覆盖（回填铁律，mergeRecordBody）；
/// · mood 表单字段（app.js:1840）：emoji（MOOD_OPTIONS 十种）+ date 必填 + content 可选；
/// · note：content 必填、无 title（app.js:1849 note 例外分支）；
/// · wish：title 必填 + category 五选 + target 可选 + content 可选；
///   done 勾选 = PUT {...body, done:!done}（app.js:2536 toggle-wish 同口径）；
/// · 纪念日倒计时逐字对齐 Web nextAnniversary（app.js:483）：
///   annual=true 按年推进 + 02-29 回退；lunar 按原样日期近似（与 Web/首页现状一致）；
///   一次性/已过（days<0）跳过，取 days 最小者为「最近纪念日」。
library;

/// 「我们」页一条工具记录（mood/note/wish/anniversary…）。
/// body 保留原始 Map：编辑回填铁律需要原始 body 逐键复制。
class TogetherRecord {
  const TogetherRecord({
    required this.id,
    required this.kind,
    required this.body,
    required this.author,
    this.created = 0,
  });

  final String id;
  final String kind;
  final Map<String, dynamic> body;
  final String author;
  final double created; // 服务端 created 时间戳（秒），列表排序用

  factory TogetherRecord.fromJson(Map<String, dynamic> j) {
    final rawBody = (j['body'] ?? {}) as Map;
    return TogetherRecord(
      id: (j['id'] ?? '').toString(),
      kind: (j['kind'] ?? '').toString(),
      body: Map<String, dynamic>.from(rawBody.cast<String, dynamic>()),
      author: (j['author'] ?? '').toString(),
      created: (j['created'] as num?)?.toDouble() ?? 0,
    );
  }

  String get date => (body['date'] ?? '').toString();
}

/// 解析记录列表（畸形条目容错跳过，绝不抛异常）
List<TogetherRecord> parseTogetherRecords(Object? data) {
  if (data is! List) return const [];
  final out = <TogetherRecord>[];
  for (final e in data) {
    if (e is Map) {
      final r = TogetherRecord.fromJson(e.cast<String, dynamic>());
      if (r.id.isNotEmpty && r.kind.isNotEmpty) out.add(r);
    }
  }
  return out;
}

/// 记录编辑回填铁律（与相册 mergeAlbumBody 同语义）：
/// PUT 提交的 body 必须以服务器原始 body 为底逐键复制（含未知字段），
/// 只覆盖实际改动的字段；服务端 clean_body 不合并旧 body（main.py:925）。
Map<String, dynamic> mergeRecordBody(
    Map<String, dynamic> original, Map<String, dynamic> changes) {
  final body = <String, dynamic>{...original};
  body.addAll(changes);
  return body;
}

/// 按 created 倒序（同刻保序稳定）
List<TogetherRecord> sortByCreatedDesc(List<TogetherRecord> src) {
  final indexed = <int, TogetherRecord>{
    for (var i = 0; i < src.length; i++) i: src[i],
  };
  final order = indexed.keys.toList()
    ..sort((a, b) {
      final c = indexed[b]!.created.compareTo(indexed[a]!.created);
      return c != 0 ? c : a.compareTo(b);
    });
  return [for (final i in order) indexed[i]!];
}

/// 心情手记排序：body.date 倒序（无日期归末尾），同日期 created 倒序。
/// 对齐 Web「心情手记」按发生日回看的语义。
List<TogetherRecord> sortMoodsByDateDesc(List<TogetherRecord> src) {
  final indexed = <int, TogetherRecord>{
    for (var i = 0; i < src.length; i++) i: src[i],
  };
  final order = indexed.keys.toList()
    ..sort((a, b) {
      final da = indexed[a]!.date, db = indexed[b]!.date;
      if (da.isEmpty != db.isEmpty) return da.isEmpty ? 1 : -1;
      final c = db.compareTo(da);
      if (c != 0) return c;
      final cc = indexed[b]!.created.compareTo(indexed[a]!.created);
      return cc != 0 ? cc : a.compareTo(b);
    });
  return [for (final i in order) indexed[i]!];
}

/// 心情表情选项（逐字对齐 Web MOOD_OPTIONS，app.js:94，十种）
const moodOptions = <String, String>{
  '☀️': '☀️ 开心',
  '🥰': '🥰 想你',
  '😌': '😌 平静',
  '✨': '✨ 小确幸',
  '☁️': '☁️ 有点低落',
  '🌧️': '🌧️ 想要抱抱',
  '🌱': '🌱 充满期待',
  '🌊': '🌊 疲惫',
  '😵': '😵 压力大',
  '🥱': '🥱 无聊',
};

/// wish 分类选项（逐字对齐 Web recordForm wish 分支，app.js:1845）
const wishCategories = ['日常', '旅行', '美食', '约会', '其他'];

/// 今天的 yyyy-MM-dd（本地时区；与 home_page._fmtDate 同口径）
String todayDateStr() {
  final d = DateTime.now();
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// 两个 yyyy-MM-dd 之间的天数（b - a；与 home_page.daysBetween 同口径）
int daysBetweenDates(String a, String b) {
  final da = DateTime.parse(a), db = DateTime.parse(b);
  return db.difference(da).inDays;
}

/// 推算后的最近纪念日
class NextAnniversary {
  const NextAnniversary(this.record, this.due, this.days);
  final TogetherRecord record;
  final String due; // 推算后的生效日期（展示不得用原始 date 重算）
  final int days;
}

/// 单条纪念日推算（**全 App 唯一实现**）：
/// 首页倒计时区 / 「我们」hub 展示卡 / 纪念日管理页列表三处共用本函数，
/// 数字必须永远一致——不许在任何页面再写第二套推算。
/// · annual=true：按年推进（今年已过 → 明年），02-29 回退 02-28；
/// · annual='lunar'：按原样日期近似（与 Web/首页现状一致，服务端年历另有
///   lunardate 精确换算，客户端列表只做近似展示）；
/// · 其它（一次性/无 annual）：按原始 date；
/// · days<0（已过去且不循环）→ null（不倒计时）。
class AnniversaryDue {
  const AnniversaryDue(this.due, this.days);
  final String due;
  final int days;
}

AnniversaryDue? anniversaryDue(Map<String, dynamic> body, String today) {
  final raw = (body['date'] ?? '').toString();
  if (raw.length < 10) return null;
  var date = raw;
  if (body['annual'] == true) {
    final year = int.parse(today.substring(0, 4));
    date = '$year${raw.substring(4)}';
    // 闰年判定（Web 口径 new Date(year,1,29).getMonth()!==1 的 Dart 对应）：
    // 非闰年 DateTime(year,2,29) 会滚到 3 月 → month!=2 → 回退 02-28；
    // 闰年保留 02-29。（🔴 旧首页实现误写 DateTime(year,3,1).month!=2 ——
    // 恒为真导致闰年也被回退，段 B 契约核实中修正，随三处共用自然修复）
    if (date.endsWith('02-29') && DateTime(year, 2, 29).month != 2) {
      date = '$year-02-28';
    }
    if (date.compareTo(today) < 0) {
      final next = year + 1;
      date = '$next${raw.substring(4)}';
      if (date.endsWith('02-29') && DateTime(next, 2, 29).month != 2) {
        date = '$next-02-28';
      }
    }
  }
  final days = daysBetweenDates(today, date);
  if (days < 0) return null;
  return AnniversaryDue(date, days);
}

/// 最近纪念日：对全部 anniversary 记录逐条 [anniversaryDue]，取 days 最小者。
NextAnniversary? nextAnniversary(List<TogetherRecord> records, String today) {
  NextAnniversary? best;
  for (final r in records) {
    if (r.kind != 'anniversary') continue;
    final d = anniversaryDue(r.body, today);
    if (d == null) continue;
    if (best == null || d.days < best.days) {
      best = NextAnniversary(r, d.due, d.days);
    }
  }
  return best;
}

// ── 段 B · 共同年历（/api/calendar，main.py:2341 实读）──────────────
// 返回 {month:'yyyy-MM', days:{'dd': {anniversaries/posts: [{id,title}],
// moods: [{author,emoji}], checks: [{author}]}}}；纪念日含服务端 lunardate
// 换算，mood 无 id（仅作者+表情），年历整体只读浏览。

/// 年历某天的条目
class CalendarDay {
  const CalendarDay({
    this.anniversaries = const [],
    this.posts = const [],
    this.moods = const [],
    this.checks = const [],
  });
  final List<Map<String, String>> anniversaries; // {id,title}
  final List<Map<String, String>> posts; // {id,title}
  final List<Map<String, String>> moods; // {author,emoji}
  final List<Map<String, String>> checks; // {author}

  bool get hasEvents =>
      anniversaries.isNotEmpty || posts.isNotEmpty ||
      moods.isNotEmpty || checks.isNotEmpty;
}

/// 年历整月数据：days 键为两位日期字符串 '01'..'31'
class CalendarMonth {
  const CalendarMonth({required this.month, required this.days});
  final String month;
  final Map<String, CalendarDay> days;
}

/// 解析 /api/calendar 响应（畸形条目容错跳过，绝不抛异常）
CalendarMonth parseCalendarMonth(Object? data) {
  if (data is! Map) return CalendarMonth(month: '', days: const {});
  final month = (data['month'] ?? '').toString();
  final rawDays = (data['days'] ?? {}) as Map;
  final days = <String, CalendarDay>{};
  rawDays.forEach((k, v) {
    if (v is! Map) return;
    List<Map<String, String>> pick(String key, List<String> fields) {
      final list = (v[key] ?? []) as List?;
      if (list == null) return const [];
      return [
        for (final e in list)
          if (e is Map)
            {
              for (final f in fields) f: (e[f] ?? '').toString(),
            },
      ];
    }
    days[k.toString()] = CalendarDay(
      anniversaries: pick('anniversaries', ['id', 'title']),
      posts: pick('posts', ['id', 'title']),
      moods: pick('moods', ['author', 'emoji']),
      checks: pick('checks', ['author']),
    );
  });
  return CalendarMonth(month: month, days: days);
}
