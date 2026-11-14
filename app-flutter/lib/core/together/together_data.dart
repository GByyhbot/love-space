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

/// 「我们」页一条工具记录（mood/note/wish/anniversary/question/habit…）。
/// body 保留原始 Map：编辑回填铁律需要原始 body 逐键复制。
class TogetherRecord {
  const TogetherRecord({
    required this.id,
    required this.kind,
    required this.body,
    required this.author,
    this.created = 0,
    this.answers = const [],
    this.answerCount = 0,
    this.checks = const [],
    this.media = const [],
    this.likeCount = 0,
    this.commentCount = 0,
    this.deleted = 0,
  });

  final String id;
  final String kind;
  final Map<String, dynamic> body;
  final String author;
  final double created; // 服务端 created 时间戳（秒），列表排序用
  /// 软删时间戳（秒）；0 = 未删除。回收站列表展示「X 删除」用（段 7-B）。
  final double deleted;

  /// question 附属答案（serializers.py:39-41：**内容按人过滤**——双方都答了
  /// 才互相可见，未齐时只含自己的）；{record_id, author, content}
  final List<Map<String, String>> answers;

  /// question 答案总数（**不过滤、双方可见**，serializers.py:41——
  /// UI 用它判断「双方都到齐」揭晓态）
  final int answerCount;

  /// habit 打卡（serializers.py:44，day 倒序）；{record_id, author, day}
  final List<Map<String, String>> checks;

  /// 附件媒体（序列化 media：{id,name,mime,status,preview}）——music 记录的
  /// 本地音频走这里（在线歌走 body.song.src）
  final List<Map<String, String>> media;

  /// 点赞 / 评论数（序列化记录的 likes/comments 数组长度；周报精选简卡用）
  final int likeCount;
  final int commentCount;

  factory TogetherRecord.fromJson(Map<String, dynamic> j) {
    final rawBody = (j['body'] ?? {}) as Map;
    List<Map<String, String>> strMaps(Object? list) {
      if (list is! List) return const [];
      return [
        for (final e in list)
          if (e is Map)
            {
              for (final k in ['record_id', 'author', 'content', 'day', 'id',
                    'mime', 'name'])
                if (e[k] != null) k: e[k].toString(),
            },
      ];
    }
    return TogetherRecord(
      id: (j['id'] ?? '').toString(),
      kind: (j['kind'] ?? '').toString(),
      body: Map<String, dynamic>.from(rawBody.cast<String, dynamic>()),
      author: (j['author'] ?? '').toString(),
      created: (j['created'] as num?)?.toDouble() ?? 0,
      answers: strMaps(j['answers']),
      answerCount: (j['answer_count'] as num?)?.toInt() ?? 0,
      checks: strMaps(j['checks']),
      media: strMaps(j['media']),
      likeCount: j['likes'] is List ? (j['likes'] as List).length : 0,
      commentCount: j['comments'] is List ? (j['comments'] as List).length : 0,
      deleted: (j['deleted'] as num?)?.toDouble() ?? 0,
    );
  }

  String get date => (body['date'] ?? '').toString();

  /// music 记录的本地音频附件 mid（media 里第一个 audio/*）；在线歌为空
  String get audioMid {
    for (final m in media) {
      if ((m['mime'] ?? '').startsWith('audio/')) return m['id'] ?? '';
    }
    return '';
  }
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

/// 情侣问答内置题库（逐字对齐 Web QUESTION_BANK，app.js:1249-1252，四组 40 条）
const questionBank = <String, List<String>>{
  '回忆': [
    '第一次心动，是哪个瞬间？', '如果可以重温一天，你会选哪天？',
    '你记得我说过最温柔的话是哪句？', '我们第一次见面，你心里在想什么？',
    '你最想封存的一个我们共同的瞬间是？', '我做过最让你感动的事是什么？',
    '你记得我们第一次吵架是为什么吗？', '有没有一个瞬间，你觉得"就是TA了"？',
    '我们之间最默契的一次不用说话的经历是？', '你最想回到我们关系的哪个阶段？',
  ],
  '默契': [
    '什么样的陪伴让你最有安全感？', '你觉得我们最像的地方是什么？',
    '如果用一个词形容我们的关系，会是什么？', '你觉得我最懂你的时候是什么时候？',
    '我们之间最不需要解释就能懂的事是什么？', '你觉得我们在一起后，彼此最大的变化是？',
    '你最欣赏我性格里的哪一点？', '你觉得我们最互补的地方在哪？',
    '如果我们的默契值满分是100，现在你打几分？', '你觉得我们最不像情侣的地方是什么？',
  ],
  '未来': [
    '今年最想和我一起完成什么事？', '如果明年我们可以去任何地方，你最想去哪？',
    '你觉得十年后的我们会是什么样子？', '你最想和我一起学的新技能是？',
    '如果我们有一个只属于我们的传统，你希望是什么？', '你最想和我一起完成的三个愿望是？',
    '你觉得我们未来最需要一起面对的挑战是？', '如果时间可以倒流但只能改一件事，你会改什么？',
    '你最想和我一起过的一个节日是？', '你觉得我们在一起最应该坚持的习惯是？',
  ],
  '趣味': [
    '如果我是一种动物，你觉得我是什么？', '你觉得我喝醉之后最可爱的地方是？',
    '如果我们要一起拍一部电影，你最想演什么角色？', '你觉得我最像哪种食物？',
    '如果我们要一起开一家店，你最想开什么？', '你觉得我最应该改掉的一个坏习惯是？',
    '如果我们要一起学一门乐器，你最想学什么？', '你觉得我最应该在公众场合少做的事是？',
    '如果我们要一起做一个短视频，你最想拍什么？', '你觉得我最应该尝试的一件新事物是？',
  ],
};

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

// ── 段 D · 恋爱清单 / 共同账本 / 共同歌单 ─────────────────────────
// 契约（Web 实读）：quest 完成机制 = 记录级 PUT body {...r.body, done:!done}
// （app.js:2537 toggle-quest，与 wish 同口径，非 check 子资源）；
// ledger 金额 = body.amount 数值（元，可两位小数，0–1 亿，clean_body 校验），
// 付款人=记录作者；music 记录 = {title, content(歌手/想说的话), song:{title,
// artist, src, art, dur}}（在线歌，src 走 /api/music/stream 转发）或
// media 音频附件（本地上传，Web 口径）。

/// quest 分类（逐字对齐 Web recordForm quest 分支，app.js:1847，六选）
const questCategories = ['日常', '旅行', '美食', '约会', '生活', '其他'];

/// ledger 分类（逐字对齐 Web recordForm ledger 分支，app.js:1849，七选）
const ledgerCategories = ['餐饮', '交通', '旅行', '礼物', '生活', '娱乐', '其他'];

/// 恋爱清单精选（逐字对齐 Web QUEST_IDEAS，app.js:1233-1246，五组 40 条）
const questIdeas = <String, List<String>>{
  '日常': [
    '一起做一顿完整的早餐', '互换一天的家务', '一起逛一次菜市场', '给对方读一段书',
    '一起养一盆植物', '写一封手写信给对方', '一起拍一组生活照', '给对方剪一次指甲',
  ],
  '旅行': [
    '一起看一次日出', '一起看一次日落', '去一次海边踩水', '坐一次绿皮火车',
    '在陌生的城市迷路一次', '一起看一场livehouse', '去一次露营看星星', '拍一张跳起来的合照',
  ],
  '美食': [
    '一起做一次火锅', '一起排队买一次网红小吃', '互相喂对方吃一样没吃过的', '一起去一次夜市',
    '一起烤一次蛋糕', '记住对方最爱的三道菜', '一起喝到微醺', '给对方做一次生日面',
  ],
  '约会': [
    '看一场电影并牵着手', '一起去一次游乐园', '一起逛一次美术馆', '去一次城市最高的地方',
    '一起看一次烟花', '重走第一次见面的路', '一起唱一次KTV', '雨天共撑一把伞',
  ],
  '生活': [
    '一起做一次体检', '一起存一笔旅行基金', '一起布置一次房间', '一起过完一个没有手机的晚上',
    '一起吵一架然后和好', '一起制定一次年度计划', '互相写一份「喜欢你的十件事」', '一起看完一部很长的剧',
  ],
};

/// 账本金额显示（逐字对齐 Web money()，static/app.js:1253：'¥'+toFixed(2)）
String ledgerMoney(num v) => '¥${v.toDouble().toStringAsFixed(2)}';

/// 恋爱清单排序：未完成在前（对齐 Web questPage，app.js:1257），同态按
/// created 倒序（新添加的排前面）。
List<TogetherRecord> sortQuests(List<TogetherRecord> src) {
  final indexed = <int, TogetherRecord>{
    for (var i = 0; i < src.length; i++) i: src[i],
  };
  final order = indexed.keys.toList()
    ..sort((a, b) {
      final da = indexed[a]!.body['done'] == true ? 1 : 0;
      final db = indexed[b]!.body['done'] == true ? 1 : 0;
      if (da != db) return da - db;
      final c = indexed[b]!.created.compareTo(indexed[a]!.created);
      return c != 0 ? c : a.compareTo(b);
    });
  return [for (final i in order) indexed[i]!];
}

/// 账本按月汇总（**算法逐字对齐 Web ledgerPage**，app.js:1267-1287）：
/// · sum = reduce(Number(amount||0))；付款人=记录作者，按 author 聚合；
/// · monthTotal/allTotal、byUser（当月按人）、allByUser（累计按人）、
///   byCat（当月按分类，降序）、trend（含选中月在内的近六个月，空月占位 0）。
class LedgerSummary {
  const LedgerSummary({
    required this.monthTotal,
    required this.allTotal,
    required this.monthCount,
    required this.byUser,
    required this.allByUser,
    required this.byCat,
    required this.trend,
  });
  final double monthTotal;
  final double allTotal;
  final int monthCount;
  final List<(String author, double total)> byUser; // 当月按人
  final List<(String author, double total)> allByUser; // 累计按人
  final List<(String category, double total)> byCat; // 当月按分类（降序）
  final List<(String month, double total)> trend; // 近六个月（旧→新）
}

LedgerSummary ledgerSummary(
    List<TogetherRecord> items, String month, List<String> userIds) {
  double sum(Iterable<TogetherRecord> rows) => rows.fold(
      0.0, (s, r) => s + (num.tryParse('${r.body['amount'] ?? ''}') ?? 0).toDouble());
  final inMonth = items
      .where((r) => (r.body['date'] ?? '').toString().startsWith(month))
      .toList();
  final byUser = [
    for (final u in userIds)
      (u, sum(inMonth.where((r) => r.author == u))),
  ];
  final allByUser = [
    for (final u in userIds) (u, sum(items.where((r) => r.author == u))),
  ];
  final catMap = <String, double>{};
  for (final r in inMonth) {
    final k = (r.body['category'] ?? '其他').toString();
    catMap[k] = (catMap[k] ?? 0) +
        (num.tryParse('${r.body['amount'] ?? ''}') ?? 0).toDouble();
  }
  final byCat = catMap.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final y = int.parse(month.substring(0, 4));
  final m = int.parse(month.substring(5, 7));
  final trend = <(String, double)>[];
  for (var i = 5; i >= 0; i--) {
    final d = DateTime(y, m - i, 1); // 空月也占位（对齐 Web trend）
    final key =
        '${d.year}-${d.month.toString().padLeft(2, '0')}';
    trend.add((
      key,
      sum(items.where((r) =>
          (r.body['date'] ?? '').toString().startsWith(key))),
    ));
  }
  return LedgerSummary(
    monthTotal: sum(inMonth),
    allTotal: sum(items),
    monthCount: inMonth.length,
    byUser: byUser,
    allByUser: allByUser,
    byCat: [for (final e in byCat) (e.key, e.value)],
    trend: trend,
  );
}

// ── 段 E · 数据看板 / 回忆周报（只读） ────────────────────────────
// 契约（app/main.py:2082 dashboard、:2126 weekly 实读，2026-11-14）：
// · /api/dashboard：{total, by_kind, months(12 项旧→新, {month,count}),
//   moods{emoji:n}, likes, comments, photos, days_together(可 null),
//   wishes_total, wishes_done}
// · /api/weekly?offset=：{offset, label, start(周一 ISO), end(周日 ISO),
//   total, prev_total, delta, days_active, photos, by_kind, moods,
//   top_mood(可 null), likes, comments, streak, last_record_days_ago
//   (可 null), highlights(serialize_many 记录数组), message}
//   offset>0 或 <-52 → 422（Web 同口径：下一周在 off>=0 禁用）。
// 数字口径逐字对齐 Web dashboardPage/weeklyPage（app.js:1303/:1317）。

/// kind 中文名（Web app.js:92 kindLabel 逐字）
const kindLabel = {
  'post': '时光动态', 'diary': '私密日记', 'draft': '草稿',
  'surprise': '定时惊喜', 'anniversary': '纪念日', 'wish': '共同愿望',
  'personal_wish': '个人心愿', 'mood': '每日心情', 'note': '留言板',
  'question': '情侣问答', 'habit': '共同打卡', 'chat': '聊天',
  'album': '相册', 'quest': '恋爱清单', 'ledger': '共同账本',
  'period': '生理期', 'music': '共同歌单',
};

class MonthCount {
  const MonthCount({required this.month, required this.count});
  final String month;
  final int count;
}

class DashboardData {
  const DashboardData({
    required this.total,
    required this.byKind,
    required this.months,
    required this.moods,
    required this.likes,
    required this.comments,
    required this.photos,
    required this.daysTogether,
    required this.wishesTotal,
    required this.wishesDone,
  });
  final int total;
  final Map<String, int> byKind;
  final List<MonthCount> months; // 旧→新
  final Map<String, int> moods;
  final int likes;
  final int comments;
  final int photos;
  final int? daysTogether;
  final int wishesTotal;
  final int wishesDone;

  /// 记录构成行（Web 口径：过滤有中文标签的 kind，按数量降序）
  List<(String, int)> get kindRows => (byKind.entries
        .where((e) => kindLabel[e.key] != null)
        .map((e) => (e.key, e.value))
        .toList()
      ..sort((a, b) => b.$2.compareTo(a.$2)));

  /// 心情分布行（按数量降序）
  List<(String, int)> get moodRows =>
      (moods.entries.map((e) => (e.key, e.value)).toList()
        ..sort((a, b) => b.$2.compareTo(a.$2)));
}

/// 解析 /api/dashboard 响应（畸形容错，绝不抛异常）
DashboardData parseDashboard(Object? data) {
  if (data is! Map) {
    return DashboardData(
        total: 0, byKind: const {}, months: const [], moods: const {},
        likes: 0, comments: 0, photos: 0, daysTogether: null,
        wishesTotal: 0, wishesDone: 0);
  }
  int asInt(Object? v) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);
  final months = <MonthCount>[];
  for (final e in (data['months'] ?? const []) as List) {
    if (e is Map) {
      months.add(MonthCount(
          month: (e['month'] ?? '').toString(),
          count: asInt(e['count'])));
    }
  }
  Map<String, int> asIntMap(Object? raw) => {
        for (final e in ((raw ?? const {}) as Map).entries)
          e.key.toString(): asInt(e.value),
      };
  return DashboardData(
    total: asInt(data['total']),
    byKind: asIntMap(data['by_kind']),
    months: months,
    moods: asIntMap(data['moods']),
    likes: asInt(data['likes']),
    comments: asInt(data['comments']),
    photos: asInt(data['photos']),
    daysTogether:
        data['days_together'] is num ? (data['days_together'] as num).toInt() : null,
    wishesTotal: asInt(data['wishes_total']),
    wishesDone: asInt(data['wishes_done']),
  );
}

class WeeklyData {
  const WeeklyData({
    required this.offset,
    required this.label,
    required this.start,
    required this.end,
    required this.total,
    required this.prevTotal,
    required this.delta,
    required this.daysActive,
    required this.photos,
    required this.byKind,
    required this.moods,
    required this.topMood,
    required this.likes,
    required this.comments,
    required this.streak,
    required this.lastRecordDaysAgo,
    required this.highlights,
    required this.message,
  });
  final int offset;
  final String label;
  final String start; // 周一 yyyy-MM-dd
  final String end; // 周日 yyyy-MM-dd
  final int total;
  final int prevTotal;
  final int delta;
  final int daysActive;
  final int photos;
  final Map<String, int> byKind;
  final Map<String, int> moods;
  final String? topMood;
  final int likes;
  final int comments;
  final int streak;
  final int? lastRecordDaysAgo;
  final List<TogetherRecord> highlights;
  final String message;

  /// 记录构成行 / 心情分布行（口径同 DashboardData）
  List<(String, int)> get kindRows => (byKind.entries
        .where((e) => kindLabel[e.key] != null)
        .map((e) => (e.key, e.value))
        .toList()
      ..sort((a, b) => b.$2.compareTo(a.$2)));
  List<(String, int)> get moodRows =>
      (moods.entries.map((e) => (e.key, e.value)).toList()
        ..sort((a, b) => b.$2.compareTo(a.$2)));

  /// 周范围短标签（Web short=d.slice(5).replace('-','.')：'11.10'）
  String get rangeLabel =>
      '${start.substring(0, 4)} 年 · '
      '${_short(start)} – ${_short(end)}';
  static String _short(String d) =>
      d.length >= 10 ? d.substring(5).replaceFirst('-', '.') : d;

  /// delta 文案（Web app.js:1322 逐字）
  String get deltaText => delta > 0
      ? '比上一周多写了 $delta 条'
      : delta < 0
          ? '比上一周少了 ${-delta} 条'
          : '和上一周一样多';

  /// streak 行（Web app.js:1323 逐字）
  String get streakLine => streak > 0
      ? '🔥 已连续记录 $streak 天'
      : lastRecordDaysAgo != null
          ? '上次记录在 $lastRecordDaysAgo 天前'
          : '还没有开始记录';
}

/// 解析 /api/weekly 响应（畸形容错；highlights 走 parseTogetherRecords）
WeeklyData parseWeekly(Object? data) {
  if (data is! Map) {
    return WeeklyData(
        offset: 0, label: '', start: '', end: '', total: 0, prevTotal: 0,
        delta: 0, daysActive: 0, photos: 0, byKind: const {}, moods: const {},
        topMood: null, likes: 0, comments: 0, streak: 0,
        lastRecordDaysAgo: null, highlights: const [], message: '');
  }
  int asInt(Object? v) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);
  Map<String, int> asIntMap(Object? raw) => {
        for (final e in ((raw ?? const {}) as Map).entries)
          e.key.toString(): asInt(e.value),
      };
  return WeeklyData(
    offset: asInt(data['offset']),
    label: (data['label'] ?? '').toString(),
    start: (data['start'] ?? '').toString(),
    end: (data['end'] ?? '').toString(),
    total: asInt(data['total']),
    prevTotal: asInt(data['prev_total']),
    delta: asInt(data['delta']),
    daysActive: asInt(data['days_active']),
    photos: asInt(data['photos']),
    byKind: asIntMap(data['by_kind']),
    moods: asIntMap(data['moods']),
    topMood: data['top_mood']?.toString(),
    likes: asInt(data['likes']),
    comments: asInt(data['comments']),
    streak: asInt(data['streak']),
    lastRecordDaysAgo: data['last_record_days_ago'] is num
        ? (data['last_record_days_ago'] as num).toInt()
        : null,
    highlights: parseTogetherRecords(data['highlights']),
    message: (data['message'] ?? '').toString(),
  );
}

/// 周报复制文字版（Web app.js:2479 act('week-copy') 逐字 4 行）
String weeklyCopyText(WeeklyData w) => [
      '${w.label}的回忆周报（${w.start} 至 ${w.end}）',
      w.message,
      '记录 ${w.total} 条 · 照片 ${w.photos} 张 · 有记录 ${w.daysActive} 天',
      '喜欢 ${w.likes} 次 · 留言与评论 ${w.comments} 条',
    ].join('\n');

