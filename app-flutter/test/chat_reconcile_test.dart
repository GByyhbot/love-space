/* SSE 对账合并单测（Step 4）：
   · 新消息插入（created 升序）；
   · 已有 id 原地更新：撤回（recall）/ 置顶（pinned）/ body 变化 → 行内容更新，
     未变化的行保持同一对象实例（不整列表重建，对齐 Web paintChat 语义）；
   · pending 幂等收尾：client_id 与服务端返回记录相同的 pending 被删除。 */
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/chat/chat_models.dart';
import 'package:love_space/core/chat/chat_repository.dart';

ChatRecord rec(String id, double created,
    {String author = 'a1',
    String content = 'hi',
    bool recalled = false,
    bool pinned = false,
    String clientId = ''}) =>
    ChatRecord(
      id: id, author: author, created: created, updated: created,
      body: ChatBody(
          content: recalled ? '' : content,
          recalled: recalled,
          pinned: pinned),
      clientId: clientId,
    );

void main() {
  test('新消息插入：按 created 升序排列', () {
    final base = mergeChats(const [], [rec('b', 2)]).merged;
    final result = mergeChats(base, [rec('a', 1), rec('c', 3)]).merged;
    expect(result.map((r) => r.id).toList(), ['a', 'b', 'c']);
  });

  test('原地更新：撤回后行内容变为撤回态', () {
    final base = mergeChats(const [], [rec('a', 1, content: '原话')]).merged;
    final before = base.single;
    final result =
        mergeChats(base, [rec('a', 1, content: '原话', recalled: true)]).merged;
    expect(result.single.body.recalled, true);
    expect(result.single.body.content, '');
    expect(identical(result.single, before), false); // 行对象已替换
  });

  test('原地更新：置顶变化（pin toggle 后 updated/内容变化）', () {
    final base = mergeChats(const [], [rec('a', 1)]).merged;
    final pinned =
        mergeChats(base, [rec('a', 1, pinned: true)]);
    expect(pinned.merged.single.body.pinned, true);
    expect(pinned.changedCount, 1);
  });

  test('未变化的行保持同一对象实例（对账不重建）', () {
    final base = mergeChats(const [], [rec('a', 1), rec('b', 2)]).merged;
    final a = base[0];
    final result = mergeChats(base, [rec('a', 1)]).merged;
    expect(result, hasLength(2));
    expect(identical(result[0], a), true); // 内容没变的行一个不碰
    expect(result[0].rendersSameAs(rec('a', 1)), true);
  });

  test('pending 幂等收尾：client_id 与服务端记录相同 → 进 confirmedClientIds', () {
    // 场景：发送成功但响应丢失（断网），SSE 对账拉回该记录 →
    // 控制器据 confirmedClientIds 删掉对应 pending（幂等收尾）
    final result = mergeChats(const [], [rec('a', 1, clientId: 'p-1')]);
    expect(result.confirmedClientIds, contains('p-1'));
  });

  test('服务端无变化：changedCount == 0（UI 可跳过刷新）', () {
    final base = mergeChats(const [], [rec('a', 1), rec('b', 2)]).merged;
    final again = mergeChats(base, [rec('b', 2), rec('a', 1)]);
    expect(again.changedCount, 0);
    expect(again.merged.map((r) => r.id).toList(), ['a', 'b']);
  });
}
