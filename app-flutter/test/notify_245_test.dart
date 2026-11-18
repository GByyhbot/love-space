/// 2.4.5 甲组测试：判定矩阵四类用例 + 去重跨重启 + 摘要映射表 + 事件表护栏。
/// 判定核心是纯函数（notify_decision.dart）与文件存储（notified_store.dart），
/// 普通 test 直接覆盖；服务 isolate 连接/重连逻辑不可单测部分（SSE 链路、
/// 线路跟随）由真机实测覆盖（摘要注明）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/chat/chat_models.dart';
import 'package:love_space/core/notify/notified_store.dart';
import 'package:love_space/core/notify/notify_decision.dart';
import 'package:love_space/features/notify/notify_models.dart';

ChatRecord chat(String id, String author, {String content = ''}) =>
    ChatRecord.fromJson({
      'id': id,
      'author': author,
      'created': 1000.0,
      'updated': 1000.0,
      'body': {'content': content, 'media': []},
    });

const meId = 'u-me';
const partner = 'u-other';
const partnerName = '小洋';

void main() {
  group('判定矩阵（提示词四条用例）', () {
    test('① 本人事件不弹（包括本人在另一台设备产生）但记 seen', () {
      final d = decideChatNotifications(
        fresh: [chat('r1', meId, content: '我自己发的')],
        myId: meId,
        partnerName: partnerName,
        foreground: false,
        isNotified: (_) => false,
      );
      expect(d.items, isEmpty); // 不弹
      expect(d.seenDelta, contains('chat:r1')); // 🔴 记 seen（回后台不重弹）
    });

    test('② 前台不弹（SSE 前台链已实时呈现）但记 seen', () {
      final d = decideChatNotifications(
        fresh: [chat('r1', partner, content: '对方发的')],
        myId: meId,
        partnerName: partnerName,
        foreground: true,
        isNotified: (_) => false,
      );
      expect(d.items, isEmpty);
      expect(d.seenDelta, contains('chat:r1'));
    });

    test('③ 重复事件不弹（id∈已决定集合 → 跳过且不重复记）', () {
      final first = decideChatNotifications(
        fresh: [chat('r1', partner, content: '第一条')],
        myId: meId,
        partnerName: partnerName,
        foreground: false,
        isNotified: (_) => false,
      );
      expect(first.items, hasLength(1));
      final decided = <String>{...first.seenDelta};
      final second = decideChatNotifications(
        fresh: [chat('r1', partner, content: '第一条')],
        myId: meId,
        partnerName: partnerName,
        foreground: false,
        isNotified: decided.contains,
      );
      expect(second.items, isEmpty); // 已通知过
      expect(second.seenDelta, isEmpty); // 也不再进 seen delta
    });

    test('④ 补拉超量（>3 条）合并为一条摘要通知', () {
      final fresh = List.generate(5, (i) => chat('r$i', partner, content: '消息 $i'));
      final d = decideChatNotifications(
        fresh: fresh,
        myId: meId,
        partnerName: partnerName,
        foreground: false,
        isNotified: (_) => false,
      );
      expect(d.items, hasLength(1));
      expect(d.items.single.count, 5);
      expect(d.items.single.body, contains('5'));
      expect(d.items.single.body, contains('有'));
      expect(d.items.single.title, partnerName);
      expect(d.items.single.channelId, kChannelMessages);
      expect(d.items.single.route, '/messages');
      expect(d.items.single.clearChatOnTap, isTrue);
      // 合并口径：计数=对方产生的未通知消息数；全部 id 记 seen
      expect(d.seenDelta, hasLength(5));
    });

    test('3 条以内逐条弹', () {
      final fresh = List.generate(3, (i) => chat('r$i', partner, content: '消息 $i'));
      final d = decideChatNotifications(
        fresh: fresh,
        myId: meId,
        partnerName: partnerName,
        foreground: false,
        isNotified: (_) => false,
      );
      expect(d.items, hasLength(3));
      expect(d.items.every((i) => i.route == '/messages'), isTrue);
    });

    test('合并计数只算对方消息（本人消息混入不计数）', () {
      final fresh = [
        chat('a1', partner, content: '1'),
        chat('a2', meId, content: '2'),
        chat('a3', partner, content: '3'),
        chat('a4', partner, content: '4'),
        chat('a5', partner, content: '5'),
      ];
      final d = decideChatNotifications(
        fresh: fresh,
        myId: meId,
        partnerName: partnerName,
        foreground: false,
        isNotified: (_) => false,
      );
      expect(d.items, hasLength(1));
      expect(d.items.single.count, 4); // 只算对方的
      expect(d.items.single.body, contains('4'));
      expect(d.seenDelta, hasLength(5)); // 全部记 seen
    });
  });

  group('聊天摘要映射表（提示词逐类）', () {
    ChatRecord body(Map<String, dynamic> body, {List<Map> media = const []}) =>
        ChatRecord.fromJson({
          'id': 'x',
          'author': partner,
          'created': 1.0,
          'updated': 1.0,
          'body': body,
          'media': media,
        });

    test('文字截断到一行量级（约 30 字超出省略）', () {
      final short = body({'content': '短消息'});
      expect(chatNotifySnippet(short), '短消息');
      final long = body({'content': '字' * 40});
      final s = chatNotifySnippet(long);
      expect(s.length, kNotifyTextSnippetMax + 1); // 30 字 + 省略号
      expect(s.endsWith('…'), isTrue);
    });

    test('图片/语音/视频/表情/位置/歌曲/附件/引用/撤回', () {
      expect(chatNotifySnippet(body({'content': '', 'media': ['m1']},
          media: [{'id': 'm1', 'mime': 'image/png'}])), '[图片]');
      expect(chatNotifySnippet(body({'content': '', 'media': ['m1']},
          media: [{'id': 'm1', 'mime': 'audio/mp4'}])), '[语音]');
      expect(chatNotifySnippet(body({'content': '', 'media': ['m1']},
          media: [{'id': 'm1', 'mime': 'video/mp4'}])), '[视频]');
      expect(chatNotifySnippet(body({'content': '', 'sticker': '/static/stickers/bigmoji/0.webp'})),
          '[表情]');
      expect(chatNotifySnippet(body({'content': '', 'location': {'lat': 1.0, 'lng': 2.0}})),
          '[位置]');
      expect(chatNotifySnippet(body({'content': '', 'song': {'title': '告白气球'}})),
          '[歌曲] 告白气球');
      expect(chatNotifySnippet(body({'content': '', 'media': ['m1']})), '[附件]');
      expect(chatNotifySnippet(body({'content': '', 'reply_to': {'id': 'q', 'text': '原话'}})),
          '[引用]');
      expect(chatNotifySnippet(body({'content': '被撤回', 'recalled': true})), '[消息已撤回]');
    });
  });

  group('去重存储跨重启（NotifiedStore）', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('notify245test');
    });

    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 句柄竞态（60af347 家族）：容忍式清理，不因清理失败报测试失败
      }
    });

    test('写后重建实例仍判定已通知（跨 App 重启有效）', () async {
      final path = '${tmp.path}${Platform.pathSeparator}seen.json';
      final first = NotifiedStore(path);
      await first.load();
      first.addAll(['chat:r1', 'notice:n1']);
      await first.save();

      final second = NotifiedStore(path); // 模拟重启后重建
      await second.load();
      expect(second.contains('chat:r1'), isTrue);
      expect(second.contains('notice:n1'), isTrue);
      expect(second.contains('chat:r2'), isFalse);
    });

    test('文件缺失/损坏 = 全新开始不抛异常', () async {
      final path = '${tmp.path}${Platform.pathSeparator}broken.json';
      File(path).writeAsStringSync('{not json');
      final store = NotifiedStore(path);
      await store.load(); // 不抛
      expect(store.contains('chat:any'), isFalse);
    });

    test('LRU 上限淘汰（800/类）', () async {
      final path = '${tmp.path}${Platform.pathSeparator}cap.json';
      final store = NotifiedStore(path);
      await store.load();
      final keys = List.generate(kNotifiedCapPerKind + 10, (i) => 'chat:k$i');
      store.addAll(keys);
      expect(store.contains('chat:k0'), isFalse); // 最旧的被淘汰
      expect(store.contains('chat:k${kNotifiedCapPerKind + 9}'), isTrue);
      await store.save();
      final reloaded = NotifiedStore(path);
      await reloaded.load();
      expect(reloaded.contains('chat:k${kNotifiedCapPerKind + 9}'), isTrue);
    });
  });

  group('通知 id 与路由策略', () {
    test('同 key 恒同 id（去重与「点开清除」可实现）；id 恒非 0（0 留给常驻通知）',
        () {
      for (final key in ['chat:r1', 'notice:n1', 'chat:merge', 'x']) {
        expect(notifyAndroidId(key), notifyAndroidId(key));
        expect(notifyAndroidId(key), isNot(0));
      }
      expect(notifyAndroidId('chat:a'), isNot(notifyAndroidId('chat:b')));
    });

    test('事件路由表落点正确（功能提醒类直达页）', () {
      expect(noticeRoute('anniversary'), '/together/anniversary');
      expect(noticeRoute('period'), '/period');
      expect(noticeRoute('wish'), '/together/wish');
      expect(noticeRoute('habit'), '/together/habit');
      expect(noticeRoute('activity'), isEmpty); // 记录类 v1 打开 App
      expect(noticeRoute('comment'), isEmpty);
      expect(noticeRoute('note'), isEmpty);
      expect(noticeRoute('surprise'), isEmpty);
    });

    test('⑤ 事件弹/不弹表（第 0 步定案）：弹 8 类，system/storage/backup/chat 不弹',
        () {
      expect(
        kNoticeNotifyEvents,
        unorderedEquals(<String>{
          'activity', 'comment', 'note', 'surprise',
          'anniversary', 'period', 'wish', 'habit',
        }),
      );
      expect(kNoticeNotifyEvents.contains('system'), isFalse);
      expect(kNoticeNotifyEvents.contains('storage'), isFalse);
      expect(kNoticeNotifyEvents.contains('backup'), isFalse);
      expect(kNoticeNotifyEvents.contains('chat'), isFalse);
    });
  });

  group('notices 判定（unread 增量信号链）', () {
    NoticeItem notice(String id, String event, String title,
            {String recordId = ''}) =>
        NoticeItem.fromJson({
          'id': id,
          'event': event,
          'title': title,
          'created': 1000.0,
          'seen': 0,
          'record_id': recordId,
        });

    test('对方互动事件弹（标题=事件名，正文=服务端 title 原文）', () {
      final d = decideNoticeNotifications(
        notices: [
          notice('n1', 'comment', '有人喜欢了你的记录', recordId: 'rec1'),
          notice('n2', 'period', '生理期临近'),
        ],
        foreground: false,
        isNotified: (_) => false,
      );
      expect(d.items, hasLength(2));
      final c = d.items.firstWhere((i) => i.key == 'notice:n1');
      expect(c.title, '点赞与评论');
      expect(c.body, '有人喜欢了你的记录'); // 服务端原文
      expect(c.route, isEmpty);
      expect(c.channelId, kChannelEvents); // 非聊天事件不响铃渠道
      final p = d.items.firstWhere((i) => i.key == 'notice:n2');
      expect(p.route, '/period');
    });

    test('前台不弹但记 seen；不弹类事件也记 seen', () {
      final d = decideNoticeNotifications(
        notices: [
          notice('n1', 'comment', '有人喜欢了你的记录'),
          notice('n2', 'system', '你们的双人空间已开启'),
          notice('n3', 'backup', '自动备份失败'),
        ],
        foreground: true,
        isNotified: (_) => false,
      );
      expect(d.items, isEmpty);
      expect(d.seenDelta, hasLength(3)); // 全记（含不弹类）
    });
  });
}
