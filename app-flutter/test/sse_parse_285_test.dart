/// 2.8.5 护栏：SSE 帧解析（审计 P2-7「双端无 SSE 测试」的 App 侧）。
///
/// 被测对象是 `parseSseChunk` —— 2.8.5 从 stream 监听闭包里抽出的纯函数
/// （抽出前后行为逐字等价：同样的 trim、同样跳过 retry/注释/空行、同样对
/// 畸形 JSON 容错）。
///
/// 🔴 如实说明一处**未覆盖**：令文要求的「修订号新旧比较逻辑」在 App 侧
/// **不存在**。服务端已在 `/api/events` 里用七段签名做新旧比对（
/// `_sse_payload` 的 `prev(i)` 比较），客户端只消费布尔标志
/// （chat/other/refresh/typing/peer），从不读 `rev`。没有这段逻辑就不能
/// 假造一个比较函数来"测过"——此处如实报未覆盖并说明原因。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/sse/sse_client.dart';

void main() {
  test('合法 data 帧：解析出 raw 与五个布尔标志', () {
    const chunk = 'data: {"refresh":true,"chat":true,"other":false,'
        '"typing":false,"peer":true,"rev":"1:2:3:4:5:0:6"}\n\n';
    final r = parseSseChunk('', chunk);
    expect(r.carry, '');
    expect(r.events.length, 1);
    final e = r.events.single;
    expect(e.refresh, isTrue);
    expect(e.chat, isTrue);
    expect(e.other, isFalse);
    expect(e.typing, isFalse);
    expect(e.peer, isTrue);
    expect(e.raw.contains('"rev"'), isTrue, reason: '原始帧保留，便于排障');
  });

  test('跨块半行：先到的半帧不产事件，补齐后产出一条', () {
    final r1 = parseSseChunk('', 'data: {"refresh":tr');
    expect(r1.events, isEmpty, reason: '行未结束不许解析，否则会丢半帧');
    expect(r1.carry, 'data: {"refresh":tr');

    final r2 = parseSseChunk(r1.carry, 'ue}\n\n');
    expect(r2.events.length, 1);
    expect(r2.events.single.refresh, isTrue);
    expect(r2.carry, '');
  });

  test('畸形帧不崩，且不阻断后续帧', () {
    // 按代码实情：jsonDecode 失败时 j 为 null，但仍会构造一条**全 false**
    // 的事件（等价于「这一帧没带来任何变化」），而不是丢弃整行。
    const chunk = 'data: {not-json\n\ndata: {"chat":true}\n\n';
    final r = parseSseChunk('', chunk);
    expect(r.events.length, 2, reason: '坏帧也成帧（全 false），好帧照常解析');
    final bad = r.events[0];
    expect(bad.chat || bad.other || bad.refresh || bad.typing || bad.peer, isFalse,
        reason: '畸形帧退化成一帧无变化，不得误判成任何类别刷新');
    expect(r.events[1].chat, isTrue);
  });

  test('retry / 注释 / 空行都被忽略，不产生事件', () {
    const chunk = 'retry: 3000\n\n: ready\n\n: heartbeat\n\n\n';
    final r = parseSseChunk('', chunk);
    expect(r.events, isEmpty);
  });

  test('多帧同块：逐帧解析，顺序保持', () {
    const chunk = 'data: {"chat":true}\n\ndata: {"other":true}\n\n';
    final r = parseSseChunk('', chunk);
    expect(r.events.length, 2);
    expect(r.events[0].chat, isTrue);
    expect(r.events[1].other, isTrue);
  });
}
