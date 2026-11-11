/// 微信式时间分隔条：逐字对齐 static/chat.js 的 chatTimeLabel()。
/// 规则（Web 原样）：
/// · 同一天且与上一条间隔 ≤300s → 不加分隔（返回 null）；
/// · 今天 → HH:mm；昨天 → 「昨天 HH:mm」；
/// · 同年 → 「M月d日 HH:mm」（月/日不补零，与 Web `${m}月${d}日` 一致）；
/// · 跨年 → 「yyyy年M月d日 HH:mm」。
library;

String? chatTimeLabel(double ts, double? last, {DateTime Function()? now}) {
  final n = (now ?? DateTime.now)();
  final d = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
  if (last != null && ts - last <= 300) {
    final ld = DateTime.fromMillisecondsSinceEpoch((last * 1000).round());
    if (_sameDay(d, ld)) return null;
  }
  final hm =
      '${_two(d.hour)}:${_two(d.minute)}';
  if (_sameDay(d, n)) return hm;
  if (_sameDay(d, n.subtract(const Duration(days: 1)))) return '昨天 $hm';
  final ymd = '${d.month}月${d.day}日 $hm';
  return d.year == n.year ? ymd : '${d.year}年$ymd';
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _two(int v) => v.toString().padLeft(2, '0');
