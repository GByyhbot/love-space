/// 2.8.1 点击直达 · 落点判定纯函数单测。
///
/// 通知行只有 event + record_id，kind 由点击时 `GET /api/records/{rid}` 取到
/// 记录后判定；这里覆盖映射表全部分支 + 冷启动 payload 往返。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/notify/notify_decision.dart';

void main() {
  group('2.8.1 · noticeTargetOf 按 kind 分流', () {
    test('event=chat → 聊天页（不吃兜底弹层）', () {
      final t = noticeTargetOf('chat', '');
      expect(t.kind, NoticeTargetKind.route);
      expect(t.route, '/messages');
      // 即便带了 rid 也优先按 event 走聊天页
      expect(noticeTargetOf('chat', 'rid').route, '/messages');
    });

    test('event=peer（报备/SOS）→ 报备详情页', () {
      final t = noticeTargetOf('peer', '');
      expect(t.kind, NoticeTargetKind.route);
      expect(t.route, '/together/peer-report');
    });

    test('kind=anniversary → 纪念日列表页（不是记录弹层）', () {
      final t = noticeTargetOf('activity', 'rid', 'anniversary');
      expect(t.kind, NoticeTargetKind.route);
      expect(t.route, '/together/anniversary');
    });

    test('kind=period → 生理期页', () {
      final t = noticeTargetOf('activity', 'rid', 'period');
      expect(t.kind, NoticeTargetKind.route);
      expect(t.route, '/period');
    });

    test('其余 kind → 记录底部弹层', () {
      const sheetKinds = [
        'post', 'album', 'mood', 'note', 'wish',
        'question', 'habit', 'music', 'ledger', 'quest',
      ];
      for (final k in sheetKinds) {
        expect(noticeTargetOf('activity', 'rid', k).kind,
            NoticeTargetKind.recordStory, reason: k);
      }
    });

    test('kind 未取到（空串）→ 先按弹层走，取回记录后二次分流', () {
      expect(noticeTargetOf('activity', 'rid').kind,
          NoticeTargetKind.recordStory);
      expect(noticeTargetOf('comment', 'rid', '').kind,
          NoticeTargetKind.recordStory);
    });

    test('无 rid 的提醒类 → 既有 kNoticeRoutes 功能页', () {
      expect(noticeTargetOf('anniversary', '').route, '/together/anniversary');
      expect(noticeTargetOf('period', '').route, '/period');
      expect(noticeTargetOf('wish', '').route, '/together/wish');
      expect(noticeTargetOf('habit', '').route, '/together/habit');
    });

    test('无 rid 的运维类 → 兜底弹层（备份/存储不许成死条目）', () {
      for (final e in ['system', 'storage', 'backup']) {
        expect(noticeTargetOf(e, '').kind, NoticeTargetKind.fallback, reason: e);
      }
    });

    test('全事件 × 有无 rid × kind 三态都给合法落点（不许抛）', () {
      const events = [
        'chat', 'comment', 'note', 'activity', 'anniversary', 'period',
        'wish', 'surprise', 'habit', 'backup', 'storage', 'system', 'peer',
      ];
      for (final e in events) {
        for (final rid in ['', 'rid']) {
          for (final k in ['', 'post', 'anniversary', 'period']) {
            final t = noticeTargetOf(e, rid, k);
            expect(NoticeTargetKind.values.contains(t.kind), isTrue,
                reason: '$e/$rid/$k');
          }
        }
      }
    });
  });

  group('2.8.1 · 系统通知 payload 往返（冷启动还原落点）', () {
    test('recordId / event 进 JSON 再出来不丢', () {
      final item = NotifyItem(
        key: 'notice:n1',
        androidId: 7,
        channelId: kChannelEvents,
        title: '新动态',
        body: '对方发布了一条时光：x',
        route: '',
        clearChatOnTap: false,
        recordId: 'rid-9',
        event: 'activity',
      );
      final back = NotifyItem.fromJson(item.toJson());
      expect(back.recordId, 'rid-9');
      expect(back.event, 'activity');
      // 冷启动只用 payload 就能还原到「有 rid → 需取记录」
      expect(noticeTargetOf(back.event, back.recordId).kind,
          NoticeTargetKind.recordStory);
    });
  });
}
