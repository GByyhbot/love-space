// 2.4.10 乙批护栏（04 长按确认 / 05 上传进度环 / 09 双击爱心）：
// · HoldToConfirmButton：走满→对勾+落点；中途松手→归零不落点；
// · ChatRecord likes：解析/副本/rendersSameAs 参与 merge 判定；
// · 05/09 接线源码护栏（onSendProgress 真实字节进度、双击手势、
//   toggleChatLike 乐观通道、完成弧 100% 定案）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/chat/chat_models.dart';
import 'package:love_space/core/ui/hold_to_confirm.dart';

void main() {
  group('04 长按确认', () {
    testWidgets('走满 1.5s：对勾出现 → 驻留后 onConfirm 落点', (tester) async {
      var confirmed = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: HoldToConfirmButton(onConfirm: () => confirmed++),
          ),
        ),
      ));
      final g = await tester.startGesture(tester.getCenter(
          find.byType(HoldToConfirmButton)));
      // 长按识别 ~500ms + 进度环走满 1500ms
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 1600));
      expect(find.byIcon(Icons.check_rounded), findsOneWidget,
          reason: '走满后变对勾');
      expect(confirmed, 0, reason: '驻留期（已删除）内未落点');
      await tester.pumpAndSettle();
      // 驻留 450ms 定时器在帧停止点之后——补定量 pump 触发落点。
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(confirmed, 1, reason: '驻留后交还宿主');
      await g.up();
    });

    testWidgets('中途松手：进度归零，不落点', (tester) async {
      var confirmed = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: HoldToConfirmButton(onConfirm: () => confirmed++),
          ),
        ),
      ));
      final g = await tester.startGesture(tester.getCenter(
          find.byType(HoldToConfirmButton)));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 300));
      await g.up(); // 未走满松手
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_rounded), findsNothing,
          reason: '未走满不出现对勾');
      expect(confirmed, 0, reason: '未走满松手不执行任何操作');
    });
  });

  group('09 ChatRecord likes 模型', () {
    test('fromJson 解析 + copyLikes 副本 + toJson 回传', () {
      final j = {
        'id': 'c1',
        'author': 'u1',
        'created': 1.0,
        'updated': 2.0,
        'body': {'content': 'hi'},
        'likes': ['u2', 'u3'],
      };
      final r = ChatRecord.fromJson(j);
      expect(r.likes, ['u2', 'u3']);
      final flipped = r.copyLikes(['u2', 'u3', 'u1']);
      expect(flipped.likes, contains('u1'));
      expect(r.likes, ['u2', 'u3'], reason: '副本不改原对象');
      expect(flipped.toJson()['likes'], ['u2', 'u3', 'u1']);
    });

    test('rendersSameAs：likes 变化参与 merge 判定（对账不丢点赞态）', () {
      final base = {
        'id': 'c1',
        'author': 'u1',
        'created': 1.0,
        'updated': 2.0,
        'body': {'content': 'hi'},
        'likes': <String>[],
      };
      final a = ChatRecord.fromJson(base);
      final b = ChatRecord.fromJson(base);
      expect(a.rendersSameAs(b), isTrue);
      final c = ChatRecord.fromJson({...base, 'likes': ['u2']});
      expect(a.rendersSameAs(c), isFalse,
          reason: 'likes 变化必须触发原地更新（否则对账丢爱心）');
    });
  });

  group('05/09 接线源码护栏', () {
    test('05：uploadMedia 支持真实字节进度（onSendProgress）', () {
      final src =
          _read('lib/core/api/api_client.dart');
      expect(src.contains('onSendProgress'), isTrue,
          reason: '头像上传进度必须由真实字节驱动（dio onSendProgress）');
      final profile = _read('lib/features/account/profile_page.dart');
      expect(profile.contains('Curves.easeOut.transform(p)'), isTrue,
          reason: '进度节奏先快后慢 = ease-out 映射（提示词钦定）');
      expect(profile.contains('全部准备就绪'), isTrue);
      expect(profile.contains('正在上传头像'), isTrue);
      // 🔴 提示词定案：App 无对应指标，完成弧一律画到 100%，不自造假百分比。
      expect(profile.contains('画到 100%'), isTrue,
          reason: '完成弧 100% 定案注释在位');
      expect(profile.contains("'68%'"), isFalse, reason: '不塞示例假数据');
    });

    test('09：气泡双击手势 + 乐观 toggle + 爱心飞行动画接线', () {
      final page = _read('lib/features/chat/messages_page.dart');
      expect(page.contains('onDoubleTapDown'), isTrue,
          reason: '双击落点捕获');
      expect(page.contains('toggleChatLike'), isTrue,
          reason: '复用每记录点赞落库（不自创后端字段）');
      expect(page.contains('_HeartFlight'), isTrue);
      expect(page.contains('_PulsingAvatar'), isTrue,
          reason: '头像缩一下再弹回');
      final models = _read('lib/core/chat/chat_models.dart');
      expect(models.contains('copyLikes'), isTrue);
      final state = _read('lib/core/chat/chat_state.dart');
      expect(state.contains('回滚'), isTrue,
          reason: '点赞失败回滚乐观态');
    });
  });
}

String _read(String path) {
  // 测试根 = app-flutter；相对路径直接读。
  // ignore: avoid_slow_async_io
  return File(path).readAsStringSync();
}
