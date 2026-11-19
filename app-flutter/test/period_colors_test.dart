// 2.4.8 方案 B 换色段防回归：生理期阶段色语义表两档逐值断言 +
// 写死色回流源码护栏（禁旧方案 A 色回流）。数学零涉及（period parity
// 在 engine 测试）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/features/period/period_colors.dart';

void main() {
  // 色表函数按 Theme.of(context).brightness 取值——pumpWidget 实取
  // context，逐值断言的同时直接验证「跟随明暗模式」机制本身。
  Color? captured;

  Future<void> pumpProbe(WidgetTester tester, Brightness b) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: b, useMaterial3: true),
        home: Scaffold(
          body: Builder(builder: (context) {
            captured = periodStageColor(context);
            // 同 context 顺带断言其余六个函数（机制：同一 brightness 下一
            // 致取值，即「跟随明暗模式」的直接证明）。
            expect(periodSoftColor(context),
                b == Brightness.dark ? const Color(0xFF40222C) : const Color(0xFFFBE9EE),
                reason: 'period-soft 方案 B');
            expect(periodInkColor(context),
                b == Brightness.dark ? const Color(0xFFFFC9D6) : const Color(0xFF96455C),
                reason: 'period-ink 方案 B');
            expect(fertileStageColor(context),
                b == Brightness.dark ? const Color(0xFFBFA5E0) : const Color(0xFF9C7CC4),
                reason: 'fertile 方案 B');
            expect(fertileInkColor(context),
                b == Brightness.dark ? const Color(0xFFE2D4F5) : const Color(0xFF5F4A86),
                reason: 'fertile-ink 方案 B（2.4.8 新增派生档）');
            expect(follicularStageColor(context),
                b == Brightness.dark ? const Color(0xFFA3D191) : const Color(0xFF84B96E),
                reason: 'follicular 方案 B');
            expect(lutealStageColor(context),
                b == Brightness.dark ? const Color(0xFFEFBE6E) : const Color(0xFFE3AC55),
                reason: 'luteal 方案 B');
            return const SizedBox.shrink();
          }),
        ),
      ),
    );
  }

  testWidgets('浅色档：月经期=#DE6B87（方案 B 定案表）', (tester) async {
    await pumpProbe(tester, Brightness.light);
    expect(captured, const Color(0xFFDE6B87));
  });

  testWidgets('夜色档：月经期=#F08CA6（方案 B 同相提亮）', (tester) async {
    await pumpProbe(tester, Brightness.dark);
    expect(captured, const Color(0xFFF08CA6));
  });

  test('🔴 写死色回流护栏：period 页源码不得出现旧方案 A 阶段色字面量', () {
    final src = File('lib/features/period/period_page.dart').readAsStringSync();
    for (final banned in [
      '0xFFEF3F68)', // 2.3.9 前阶段表旧色（注释中的引用不带右括号，不误伤）
      '0xFF81C784)',
      '0xFFFFB74D)',
      'Color(0xFF7E57C2)', // 第二套紫（排卵日）
      'Color(0xFFF8BBD0)', // 图例旧浅粉
      // 2.4.8 起退役的方案 A 色值（2026-11-19 主人裁定与 Web 分道）
      '0xFFC23F68',
      '0xFFEE7C9F',
      '0xFF4B6B3F',
      '0xFF8FB27C',
      '0xFF7B63A0',
      '0xFFB49BD6',
      '0xFF8A5A22',
      '0xFFD2A472',
    ]) {
      expect(src.contains(banned), isFalse,
          reason: '2.4.8 起阶段色只允许走 period_colors.dart 方案 B 语义表，'
              '发现写死色回流: $banned');
    }
    // 语义表文件本身必须存在且是唯一色源（新值在表、旧值已退役）。
    final table =
        File('lib/features/period/period_colors.dart').readAsStringSync();
    expect(table.contains('0xFFDE6B87'), isTrue, reason: '浅色月经期（方案 B）');
    expect(table.contains('0xFFF08CA6'), isTrue, reason: '夜色月经期（方案 B）');
    for (final retired in [
      '0xFFC23F68', '0xFFEE7C9F', '0xFF4B6B3F', '0xFF8FB27C',
      '0xFF7B63A0', '0xFFB49BD6', '0xFF8A5A22', '0xFFD2A472',
    ]) {
      expect(table.contains(retired), isFalse,
          reason: '方案 A 旧值已退役，语义表不得回留: $retired');
    }
  });
}
