/* 账号页保存反馈返修（B 段返修点 2）契约测试：
   背景：B 段清零 SnackBar 时漏了「账号页保存成功只在按钮下方行内文字」。
   本测试锁定契约，避免后续被改回行内-only：
   ① 保存成功：不再用行内 _notice，统一走全局顶部通知 chatToastProvider('已保存')
   ② 保存失败（服务端/上传/邀请）：行内 _error 保留 + 顶部通知（双通道）
   ③ 字段级校验「昵称不能为空」保留行内（符合口径，不强制顶部通知）
   ④ App 内不再有底部 SnackBar（与全局宿主统一口径一致） */
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late final String src;
  setUpAll(() {
    src = File('lib/features/account/profile_page.dart').readAsStringSync();
  });

  test('① 保存成功不再行内 _notice：_notice 已彻底移除', () {
    expect(src.contains('_notice'), isFalse,
        reason: '保存成功必须走顶部通知，不允许只剩按钮下方行内文字');
  });

  test('① 保存成功走顶部通知 chatToastProvider(' "'已保存'" ')', () {
    // 成功分支里必须出现顶部通知调用
    expect(src.contains("chatToastProvider.notifier).show(\n            '已保存'"),
        isTrue,
        reason: '保存成功统一补走顶部通知');
  });

  test('② 保存失败（服务端 err）补顶部通知且行内 _error 保留', () {
    expect(src.contains('setState(() => _error = err);'), isTrue);
    // 该分支紧跟 toast error
    final i = src.indexOf("setState(() => _error = err);");
    final tail = src.substring(i, i + 200);
    expect(tail.contains('chatToastProvider.notifier).show(err,'), isTrue,
        reason: '服务端失败结果反馈统一补走顶部通知');
  });

  test('② 头像上传失败 / 邀请失败 也补顶部通知', () {
    expect(
        src.contains(
            "ref.read(chatToastProvider.notifier).show(\n            '头像上传失败，可重试后重新保存'"),
        isTrue,
        reason: '头像上传失败反馈补走顶部通知');
    // 邀请失败分支：setState(_error) 后紧跟 toast
    final j = src.indexOf('setState(() => _error = err);\n      ref.read(chatToastProvider');
    expect(j >= 0, isTrue,
        reason: '邀请失败（err!=null）结果反馈补走顶部通知');
  });

  test('③ 字段级校验「昵称不能为空」保留行内 _error（不强制顶部通知）', () {
    expect(src.contains("_error = '昵称不能为空'"), isTrue,
        reason: '字段级校验错误可保留行内提示');
  });

  test('④ App 内不再有底部 SnackBar 残留', () {
    final lib = Directory('lib');
    final offenders = <String>[];
    for (final f in lib.listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      for (final line in f.readAsLinesSync()) {
        final trimmed = line.trim();
        if (trimmed.startsWith('//')) continue;
        if (line.contains('showSnackBar') || line.contains('SnackBar(')) {
          offenders.add('${f.path}: $trimmed');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: '结果类提示统一走顶部通知，不许残留底部 SnackBar');
  });
}
