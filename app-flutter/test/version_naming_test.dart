/// 🔴 版本命名铁律护栏（2026-11-21 主人明令，永久生效）：
/// 版本名称与 VC 逐字镜像，名称永远由 VC 推导、不单独计数。
/// 公式：名称 = 2.<(VC−200) div 10>.<(VC−200) mod 10>；个位永远一位 0–9，
/// 满 10 进位，不存在 2.5.10 这类两位数个位。
/// 例：VC259=2.5.9、VC260=2.6.0、VC261=2.6.1。
/// 镜像标签同规：镜像版本 = git tag 去 v 前缀，与 App 同名。
/// 任何两位个位的命名（2.5.10 之流）在门禁阶段就出不去。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 公式本体（唯一事实源，pubspec 断言与未来工具共用此推导）
String versionNameFor(int vc) {
  final n = vc - 200;
  if (n < 0) throw ArgumentError('VC 必须 ≥ 200（2.0.0 起）');
  return '2.${n ~/ 10}.${n % 10}';
}

void main() {
  test('公式自证：既有里程碑版本全部命中', () {
    expect(versionNameFor(200), '2.0.0');
    expect(versionNameFor(225), '2.2.5');
    expect(versionNameFor(255), '2.5.5');
    expect(versionNameFor(258), '2.5.8');
    expect(versionNameFor(259), '2.5.9');
    expect(versionNameFor(260), '2.6.0', reason: '满 10 进位，个位只有一位');
    expect(versionNameFor(261), '2.6.1');
    expect(versionNameFor(300), '2.10.0',
        reason: '铁律只约束个位一位 0–9；十位按 div 10 自然增长');
  });

  test('pubspec 的 version 严格等于由 VC 推导的结果（不等即红）', () {
    final raw = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(raw);
    expect(m, isNotNull, reason: 'pubspec.yaml 必须有 version 行');
    final v = m!.group(1)!;
    final parts = v.split('+');
    expect(parts.length, 2, reason: 'version 格式必须为 X.Y.Z+VC：$v');
    final vc = int.parse(parts[1]);
    final name = parts[0];
    expect(name, versionNameFor(vc),
        reason: '版本名称必须由 VC 推导：VC$vc 应为 ${versionNameFor(vc)}，'
            '实为 $name——两位个位（如 2.5.10）或手改名称都是违规');
    // 名称三段、个位一位：正结构校验（双保险，防止未来公式被改坏）
    final segs = name.split('.');
    expect(segs.length, 3, reason: '名称固定三段');
    expect(int.parse(segs[0]), 2);
    expect(segs[2].length, 1, reason: '个位永远一位 0–9，两位个位违规');
  });
}
