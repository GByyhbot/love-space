/// 生理期引擎的**唯一入参构造入口**（接线层）。
///
/// 为什么单独一个文件：`period_engine.dart` 是纯计算（对齐 `static/period.js`，
/// 不 import 任何 app 类型，便于与 JS 逐行对拍）；而这里必须认识
/// `TogetherRecord`，属于接线层。把它放引擎里会污染纯函数边界。
///
/// 🔴 2.8.7 P0 教训：`period_controller.periodRows` 与 `period_page` 曾各写一份
/// `PeriodRow(id: r.id, author: r.author, body: r.body)`，**两处都漏传 updated**
/// → `settledLast` 恒 false → 点「月经走了」接口 200 但待确认态关不掉。
/// 现在两条接线都只走 [periodRowsOf]，字段来源一处，不会再漂移。
library;

import '../../core/together/together_data.dart';
import 'period_engine.dart';

/// 把记录列表转成引擎入参（与 `recordsOf('period')` 同源同形）。
List<PeriodRow> periodRowsOf(Iterable<TogetherRecord> records) => <PeriodRow>[
      for (final r in records)
        PeriodRow(
          id: r.id,
          author: r.author,
          body: r.body,
          // P0 关键：updated 必须一路带下去（0 会被引擎判成「未定稿」）
          updated: r.updated,
        ),
    ];
