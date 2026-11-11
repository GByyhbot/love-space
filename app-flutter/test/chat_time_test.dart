/* 时间分隔条判定矩阵：逐条对齐 static/chat.js chatTimeLabel()。
   · 同天间隔 ≤300s 不加；同天超 300s / 跨天加；
   · 今天 HH:mm；昨天 HH:mm；同年 M月d日 HH:mm；跨年加年份前缀。 */
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/chat/chat_time.dart';

// 固定「现在」：2026-11-11 12:00（周三），排除真实时间漂移
DateTime fixedNow() => DateTime(2026, 11, 11, 12, 0);

double at(int y, int m, int d, int hh, int mm) =>
    DateTime(y, m, d, hh, mm).millisecondsSinceEpoch / 1000;

void main() {
  test('同天间隔 ≤300s：不加分隔条', () {
    final t = at(2026, 11, 11, 10, 0);
    expect(chatTimeLabel(t + 300, t, now: fixedNow), isNull);
    expect(chatTimeLabel(t + 100, t, now: fixedNow), isNull);
  });

  test('同天间隔 >300s：加分隔条（HH:mm）', () {
    final t = at(2026, 11, 11, 10, 0);
    expect(chatTimeLabel(t + 301, t, now: fixedNow), '10:05');
  });

  test('跨天即使间隔 ≤300s 也要加（Web toDateString 判定）', () {
    // 23:59:30 → 次日 00:00:30，间隔 60s 但跨天
    final last = at(2026, 11, 10, 23, 59);
    final ts = at(2026, 11, 11, 0, 0);
    expect(ts - last, lessThanOrEqualTo(300));
    final label = chatTimeLabel(ts, last, now: fixedNow);
    expect(label, '00:00'); // 今天
  });

  test('昨天：前缀「昨天 HH:mm」', () {
    final label = chatTimeLabel(at(2026, 11, 10, 8, 30), null, now: fixedNow);
    expect(label, '昨天 08:30');
  });

  test('同年更早：M月d日 HH:mm（月/日不补零，对齐 Web）', () {
    final label = chatTimeLabel(at(2026, 3, 5, 9, 7), null, now: fixedNow);
    expect(label, '3月5日 09:07');
  });

  test('跨年：年份前缀 yyyy年M月d日 HH:mm', () {
    final label = chatTimeLabel(at(2025, 12, 31, 22, 1), null, now: fixedNow);
    expect(label, '2025年12月31日 22:01');
  });

  test('HH:mm 补零（Web padStart 口径）', () {
    expect(chatTimeLabel(at(2026, 11, 11, 6, 5), null, now: fixedNow), '06:05');
  });
}
