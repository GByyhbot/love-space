/// 2.8.2 生理期「待确认模型」App 侧单测。
///
/// 与 `tests/period_web_282.mjs`（Web 侧最小断言脚本）同口径、同用例：
/// 六条公式 + 2026-11-25 裁定的四种定稿情形。两边都跑，防止只改一侧。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/features/period/period_engine.dart';

PeriodRow ep(String id, String start, int length, {String? updatedIso}) => PeriodRow(
      id: id,
      author: 'u1',
      body: <String, dynamic>{'start': start, 'length': length},
      // updatedIso 给「哪一天写回的」（按 UTC+8 日界换算）；不给则 = 开始日
      updated: _updatedOf(updatedIso ?? start),
    );

/// 'YYYY-MM-DD' 当天 12:00（UTC+8）的 epoch 秒 → 落在这一天的日界内。
double _updatedOf(String iso) {
  final n = dayNum(iso);
  return n * 86400.0 - 8 * 3600 + 12 * 3600;
}

String addDays(String iso, int n) => dayStr(dayNum(iso) + n);

const today = '2026-11-25';

void main() {
  group('令文 §三 · 公式六条', () {
    test('① 预测 21 来、实际 22 来 → 21 号有分期（黄体期），不是白格', () {
      final d = periodData(<PeriodRow>[
        ep('e1', '2026-10-22', 5, updatedIso: '2026-10-26'),
        ep('e2', '2026-11-22', 3, updatedIso: '2026-11-24'),
      ], today: today);
      final ph = cyclePhases(d)['2026-11-21'];
      expect(ph, isNotNull, reason: '21 号必须有分期');
      expect(ph!.phase, 'luteal', reason: '21 号落在上一段的黄体期');
    });

    test('② 新建段 length=1（不再用历史平均预填）', () {
      // periodStart 走网络层，这里直接断言引擎对新段的读法：
      // body.length=1 即「只确认了 1 天」，不当成 5 天经期。
      final d = periodData(<PeriodRow>[
        ep('p1', '2026-10-22', 5, updatedIso: '2026-10-26'),
        ep('p2', '2026-11-24', 1, updatedIso: '2026-11-24'),
      ], today: today);
      expect(d.lastEp!.length, 1);
      expect(d.pending, isNotNull, reason: '次日即进入待确认');
      expect(d.pending!.days, 2);
    });

    test('③ 确认 3 天、今天第 5 天 → 第 4–5 天待确认', () {
      final start = addDays(today, -4);
      final d = periodData(<PeriodRow>[ep('e1', start, 3)], today: today);
      expect(d.pending, isNotNull);
      expect(d.pending!.days, 5);
      final ph = cyclePhases(d);
      expect(ph[addDays(today, -1)]!.pending, isTrue, reason: '第 4 天');
      expect(ph[today]!.pending, isTrue, reason: '第 5 天');
      expect(ph[addDays(today, -2)]!.pending, isFalse, reason: '第 3 天是已确认');
    });

    test('④ 待确认第 8 天自动定稿（pending 为空）', () {
      final start = addDays(today, -10); // 确认末 = 今天-8
      final d = periodData(<PeriodRow>[ep('e1', start, 3)], today: today);
      expect(d.pending, isNull);
    });

    test('⑤ 平均经期排除未定稿的最后一段', () {
      final lastStart = addDays(today, -1);
      final d = periodData(<PeriodRow>[
        ep('e1', '2026-10-22', 5, updatedIso: '2026-10-26'),
        ep('e2', lastStart, 1),
      ], today: today);
      expect(d.pending, isNotNull, reason: '前提：最后一段待确认');
      expect(d.length, 5, reason: '只统计定稿段，不含最后那段 1 天');
    });

    test('⑥ 新段开始后旧段定稿，中间天数不追认经期', () {
      final d = periodData(<PeriodRow>[
        ep('e1', '2026-11-01', 5, updatedIso: '2026-11-05'),
        ep('e2', '2026-11-25', 1, updatedIso: '2026-11-25'),
      ], today: today);
      final ph = cyclePhases(d);
      expect(ph['2026-11-10']!.phase, isNot('period'));
      expect(ph['2026-11-20']!.phase, isNot('period'));
      expect(ph['2026-11-20'], isNotNull, reason: '段与段之间仍有分期');
    });
  });

  group('2026-11-25 定稿判据裁定 · 四种情形', () {
    test('① 月经走了：length 止于昨天、更新日=今天 → 定稿，待确认消失', () {
      final start = addDays(today, -4);
      // 点「月经走了」写回 length=4（止于昨天），updated=今天
      final d = periodData(<PeriodRow>[ep('e1', start, 4, updatedIso: today)],
          today: today);
      expect(d.pending, isNull);
    });

    test('② 月经又来了延长：结束日被推到更新日之后 → 不定稿；越过新结束日后恢复', () {
      final start = addDays(today, -4);
      // 更新日=今天，length=6 → 结束日=今天+1 > 更新日 → 不定稿
      final d = periodData(<PeriodRow>[ep('e1', start, 6, updatedIso: today)],
          today: today);
      expect(d.pending, isNull, reason: '延长当天不该判成待确认');
      // 两天后：今天+2 > 结束日(今天+1) → 待确认恢复
      final d2 = periodData(<PeriodRow>[ep('e1', start, 6, updatedIso: today)],
          today: addDays(today, 2));
      expect(d2.pending, isNotNull, reason: '越过新结束日后待确认应恢复');
    });

    test('③ 只记日记录：独立行不触碰段记录，无副作用', () {
      final start = addDays(today, -4);
      final d = periodData(<PeriodRow>[
        ep('e1', start, 3),
        PeriodRow(
          id: 'd1',
          author: 'u1',
          body: <String, dynamic>{'date': today, 'flow': 2},
          updated: _updatedOf(today),
        ),
      ], today: today);
      expect(d.pending, isNotNull, reason: '记日记录不影响待确认');
      expect(d.items.length, 1, reason: '只有 1 条段记录参与推算');
    });

    test('④ 新建段当天 length=1 → 不定稿；次日起进待确认', () {
      final sameDay = periodData(<PeriodRow>[ep('e1', today, 1, updatedIso: today)],
          today: today);
      expect(sameDay.pending, isNull);
      final nextDay = periodData(<PeriodRow>[ep('e1', today, 1, updatedIso: today)],
          today: addDays(today, 1));
      expect(nextDay.pending, isNotNull);
    });
  });
}
