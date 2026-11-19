// 2.4.10 丁批护栏（08 正在输入胶囊）：
// · SSE 载荷第 6 段解析（typing 字段；旧后端无字段=false 自然降级）；
// · 胶囊显隐以服务端信号为准 + 6s 兜底熄灭（本地不自造假状态）；
// · 心跳 ≥3s 节流、发送显式停报、旧后端 404 静默；
// · 🔴 前台服务隔离：notify_task 不消费 typing（不触发拉取/通知）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/sse/sse_client.dart';

void main() {
  test('SseEvent：typing 字段在位（旧后端缺字段 = false 自然降级）', () {
    const ev = SseEvent(raw: '', typing: true);
    expect(ev.typing, isTrue);
    const legacy = SseEvent(raw: '');
    expect(legacy.typing, isFalse, reason: '旧后端无该信号 → 胶囊永不出现');
  });

  test('源码护栏：胶囊信号链路接线完整', () {
    final page = _read('lib/features/chat/messages_page.dart');
    expect(page.contains('_TypingPill'), isTrue, reason: '胶囊组件在位');
    expect(page.contains('Duration(seconds: 6)'), isTrue,
        reason: '本地 6s 兜底熄灭（TTL 5s + 探针 5s 轮询上限）');
    expect(page.contains('_peerTyping = false'), isTrue);
    final compose = _read('lib/features/chat/chat_compose.dart');
    expect(compose.contains("inMilliseconds < 3000"), isTrue,
        reason: '心跳 ≥3s 节流（提示词钦定）');
    expect(compose.contains("'/api/typing'"), isTrue);
    expect(compose.contains("{'typing': on}"), isTrue,
        reason: '发送/退页显式停报通道');
    expect(compose.contains('静默'), isTrue,
        reason: '旧后端 404 静默（硬顺序：旧后端上新 App 不报错）');
    final sse = _read('lib/core/sse/sse_client.dart');
    expect(sse.contains('typing'), isTrue, reason: 'SSE 解析第 6 段字段');
  });

  test('🔴 前台服务隔离：notify_task 不消费 typing（通知隔离进程红线）', () {
    final src = _read('lib/core/notify/notify_task.dart');
    expect(src.contains('typing'), isFalse,
        reason: '前台服务必须忽略该信号，不因此触发拉取或通知判断');
  });

  test('后端载荷第 6 段契约（python 侧锁在 tests/test_typing_2410.py）', () {
    final py = File('../tests/test_typing_2410.py').readAsStringSync();
    expect(py.contains("peer_typing"), isTrue);
    expect(py.contains("_TYPING_TTL == 5.0"), isTrue, reason: 'TTL 钦定 5 秒');
    expect(py.contains("kind='chat' 点赞不发通知"), isTrue,
        reason: '09 特化与丁批同批（主人裁定）');
  });
}

String _read(String path) => File(path).readAsStringSync();
