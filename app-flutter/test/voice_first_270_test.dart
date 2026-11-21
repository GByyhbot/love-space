/// 2.7.0 第①项 · 首装首次发送语音卡死（P0）四条结构修复护栏。
///
/// 机主裁决：四条修复直接落地（logcat 定点仅在复现仍卡死时补）。
/// 本文件钉死四条修复的落地位置与关键语义：
/// 1. 权限预请求移出长按路径（tap 上 ensurePermission，手势内只读缓存）；
/// 2. 授权后重建（VoiceRecorder.start 内 justGranted → recycle）；
/// 3. 启动 3 秒超时兜底（chat_compose 与 composer_sheet 两入口）；
/// 4. 防幽灵录音（pressActive 同步置位/清零 + 逐 await 校验）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String src(String rel) => File(rel).readAsStringSync();

void main() {
  group('①-1 权限预请求移出长按路径', () {
    test('长按启动链内不再调用 hasPermission，只读会话级缓存', () {
      final compose = src('lib/features/chat/chat_compose.dart');
      // _startRecording 函数体（到 catch 之前）不含 hasPermission
      final start = compose.indexOf('Future<void> _startRecording');
      final catchI = compose.indexOf('} catch (e, s) {', start);
      final body = compose.substring(start, catchI);
      expect(body.contains('hasPermission()'), isFalse,
          reason: '长按启动链内不许再调 hasPermission（弹窗打断手势根因）');
      expect(body.contains('!_recorder.permissionGranted'), isTrue,
          reason: '手势内只读授权缓存标志');
      expect(body.contains('请点麦克风图标开启后重试'), isTrue,
          reason: '未授权提示文案按提示词口径');
    });

    test('麦克风图标 tap 上挂预请求 ensurePermission（结果缓存会话级）', () {
      final compose = src('lib/features/chat/chat_compose.dart');
      expect(compose.contains('_preflightPermission()'), isTrue,
          reason: 'onTap 预请求');
      expect(compose.contains('Future<void> _preflightPermission'), isTrue);
      expect(compose.contains('await _recorder.ensurePermission()'), isTrue);
    });

    test('VoiceRecorder.ensurePermission 幂等且未授权不缓存', () {
      final rec = src('lib/features/chat/voice_recorder.dart');
      expect(rec.contains('if (_permChecked)'), isTrue, reason: '幂等：已缓存直接返回');
      expect(rec.contains('_permChecked = true;\n    _permOk = ok;'), isTrue);
      expect(rec.contains('bool get permissionGranted => _permChecked && _permOk;'),
          isTrue, reason: '手势内只读的授权缓存 getter');
    });
  });

  group('①-2 授权后重建', () {
    test('VoiceRecorder.start 内 justGranted → recycle 换全新实例', () {
      final rec = src('lib/features/chat/voice_recorder.dart');
      expect(rec.contains('if (_justGranted) {'), isTrue);
      expect(rec.contains('_justGranted = false;\n      await recycle();'), isTrue,
          reason: '首次授权后第一次 start() 前先 recycle');
      expect(rec.contains('_everGranted'), isTrue,
          reason: '会话内只标记一次（后续 recycle 不重复触发重建）');
    });
  });

  group('①-3 启动 3 秒超时兜底', () {
    test('chat_compose start 包 3s 超时（走既有 catch 路径）', () {
      final compose = src('lib/features/chat/chat_compose.dart');
      expect(compose.contains('await _recorder.start().timeout(const Duration(seconds: 3));'),
          isTrue);
      // 超时异常落进既有 catch（catch 内 recycle + 「录音失败」）
      final catchI = compose.indexOf('} catch (e, s) {');
      final endI = compose.indexOf('\n  }', catchI);
      final catchBody = compose.substring(catchI, endI);
      expect(catchBody.contains('await _recorder.recycle();'), isTrue);
      expect(catchBody.contains('录音失败'), isTrue);
    });

    test('composer_sheet（时光线入口）start 同样包 3s 超时', () {
      final sheet = src('lib/features/timeline/composer_sheet.dart');
      expect(sheet.contains('await _rec.start().timeout(const Duration(seconds: 3));'),
          isTrue, reason: '①-5：时光线入口同款超时；既有交互形态不动');
    });

    test('预请求路径无超时属合法（弹窗等待用户操作，注释明示）', () {
      final rec = src('lib/features/chat/voice_recorder.dart');
      expect(rec.contains('弹窗等待用户操作是合法阻塞，不属于录音启动链'), isTrue);
    });
  });

  group('①-4 防幽灵录音', () {
    test('手势三钩子同步置位/清零 pressActive', () {
      final compose = src('lib/features/chat/chat_compose.dart');
      expect(compose.contains('_pressActive = true; // ①-4：同步置位，先于一切异步'),
          isTrue, reason: 'onLongPressStart 同步置位');
      expect(compose.indexOf('_pressActive = false; // ①-4：同步清零', 0) > 0, isTrue);
      // End 与 Cancel 两处都清零
      final endI = compose.indexOf('onLongPressEnd:');
      final cancelI = compose.indexOf('onLongPressCancel:');
      expect(compose.indexOf('_pressActive = false;', endI) < cancelI, isTrue,
          reason: 'End 清零');
      expect(compose.indexOf('_pressActive = false;', cancelI) > cancelI, isTrue,
          reason: 'Cancel 清零');
    });

    test('_startRecording 逐 await 校验 pressActive，幽灵分支 recycle 收尾不置态', () {
      final compose = src('lib/features/chat/chat_compose.dart');
      final start = compose.indexOf('Future<void> _startRecording');
      final endI = compose.indexOf('\n  }', compose.indexOf('} catch (e, s) {', start));
      final body = compose.substring(start, endI);
      expect('!_pressActive'.allMatches(body).length, greaterThanOrEqualTo(3),
          reason: '至少 3 个 await 后校验点（post-start/playback-stop/pre-state）');
      expect(body.contains('ghost-abort'), isTrue, reason: '幽灵分支 voice-dbg 标记');
      // 幽灵分支：recycle 收尾、不进录音态（在 start() 与 chatRecord.start() 之间 return）
      final ghostI = body.indexOf('if (!_pressActive)');
      final recordStartI = body.indexOf('chatRecordProvider.notifier).start()');
      expect(ghostI, lessThan(recordStartI),
          reason: '幽灵放弃必须发生在录音态置位之前');
    });
  });

  test('[voice-dbg] 日志保留（通用护栏：本段不许删除/改语义）', () {
    final rec = src('lib/features/chat/voice_recorder.dart');
    final compose = src('lib/features/chat/chat_compose.dart');
    expect(rec.contains('[voice-dbg]'), isTrue);
    expect(compose.contains('voiceDbg('), isTrue);
  });
}
