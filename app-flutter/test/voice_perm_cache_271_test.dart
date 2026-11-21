/// 2.7.1 补丁 · 权限缓存毒化修复护栏。
///
/// 根因：ensurePermission 无条件置 _permChecked——首查 false 的假结果
/// 毒化整会话（用户事后在系统设置开启权限仍被假缓存拦住，杀进程才恢复）。
/// 修复：仅 ok==true 时置缓存；ok==false 不缓存，下次 tap 重新复查。
///
/// 测试缝：FakeRecorder 继承 VoiceRecorder 覆写 hasPermission()（可编程
/// 返回序列 + 调用计数），不依赖 record 插件平台通道。
/// 2.7.0 原 10 条护栏语义不变（文档注释对齐性由注释断言延续）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/features/chat/voice_recorder.dart';

class FakeRecorder extends VoiceRecorder {
  /// hasPermission 的返回序列（依次弹出；耗尽后重复最后一个）
  final List<bool> script;
  int calls = 0;

  FakeRecorder(this.script);

  @override
  Future<bool> hasPermission() async {
    calls += 1;
    return script.isEmpty ? true : script.removeAt(0);
  }
}

void main() {
  test('2.7.1 核心迁移：首查 false 不缓存 → 底层翻转 true → 再查返回 true 且底层被复查', () async {
    final rec = FakeRecorder([false, true]);
    expect(await rec.ensurePermission(), isFalse, reason: '首查 false');
    expect(rec.permissionGranted, isFalse);
    expect(rec.calls, 1);

    // 底层权限翻转（用户在系统设置开启）→ 再调必须重新复查并返回 true
    expect(await rec.ensurePermission(), isTrue,
        reason: '毒化修复：false 不缓存，第二次必须真实复查');
    expect(rec.permissionGranted, isTrue);
    expect(rec.calls, 2, reason: 'hasPermission 必须被重新调用（未被缓存短路）');
  });

  test('首查 true 后再调不重复调底层（幂等保持，2.7.0 口径不变）', () async {
    final rec = FakeRecorder([true, true]);
    expect(await rec.ensurePermission(), isTrue);
    expect(await rec.ensurePermission(), isTrue);
    expect(rec.calls, 1, reason: '已授权缓存命中，不得重复调底层');
  });

  test('连续 false 均不缓存：每次 tap 都重新复查（修前行为=只查一次）', () async {
    final rec = FakeRecorder([false, false, false, true]);
    for (var i = 0; i < 3; i++) {
      expect(await rec.ensurePermission(), isFalse);
    }
    expect(rec.calls, 3, reason: '三次 false 均不缓存，逐次复查');
    expect(await rec.ensurePermission(), isTrue, reason: '第四次授权成功');
    expect(await rec.ensurePermission(), isTrue);
    expect(rec.calls, 4, reason: '成功后才进入缓存幂等');
  });

  test('实现与「未授权不缓存」文档注释一致（不许改注释迁就实现）', () {
    final src = File('lib/features/chat/voice_recorder.dart').readAsStringSync();
    expect(src.contains('未授权不缓存（用户可能随后在系统设置开启，允许下次重试）'),
        isTrue, reason: '文档注释保留原文');
    // 修复后实现里 ok==false 分支不得触碰 _permChecked
    final fnStart = src.indexOf('Future<bool> ensurePermission()');
    final denyI = src.indexOf("voiceDbg('recorder ensurePermission deny", fnStart);
    // deny 分支体：从 deny 日志到「return false;」为止（成功段在其后，不计入）
    final returnFalseI = src.indexOf('return false;', denyI);
    final denyBody = src.substring(denyI, returnFalseI);
    expect(denyBody.indexOf('_permChecked'), -1,
        reason: 'deny 分支不得置 _permChecked（毒化根因）');
  });
}
