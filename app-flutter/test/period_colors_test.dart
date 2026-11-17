// 2.3.9 视觉对齐 rollout 段防回归：生理期阶段色语义表两档逐值断言 +
// 写死色回流源码护栏。数学零涉及（period parity 在 engine 测试）。
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
            // 同 context 顺带断言其余五个函数（机制：同一 brightness 下一
            // 致取值，即「跟随明暗模式」的直接证明）。
            expect(periodSoftColor(context),
                b == Brightness.dark ? const Color(0xFF3D1C28) : const Color(0xFFFBE3EC),
                reason: '--period-soft（style.css:58/:1510）');
            expect(periodInkColor(context),
                b == Brightness.dark ? const Color(0xFFFFC6D8) : const Color(0xFF8A2445),
                reason: '--period-ink（style.css:59/:1510）');
            expect(fertileStageColor(context),
                b == Brightness.dark ? const Color(0xFFB49BD6) : const Color(0xFF7B63A0),
                reason: '--fertile（style.css:61/:1511）');
            expect(follicularStageColor(context),
                b == Brightness.dark ? const Color(0xFF8FB27C) : const Color(0xFF4B6B3F),
                reason: '--green 卵泡期（style.css:38/:1506）');
            expect(lutealStageColor(context),
                b == Brightness.dark ? const Color(0xFFD2A472) : const Color(0xFF8A5A22),
                reason: '--amber 黄体期（style.css:40/:1506）');
            return const SizedBox.shrink();
          }),
        ),
      ),
    );
  }

  testWidgets('浅色档：--period=#C23F68（style.css:57）', (tester) async {
    await pumpProbe(tester, Brightness.light);
    expect(captured, const Color(0xFFC23F68));
  });

  testWidgets('夜色档：--period=#EE7C9F（style.css:1510）', (tester) async {
    await pumpProbe(tester, Brightness.dark);
    expect(captured, const Color(0xFFEE7C9F));
  });

  test('🔴 写死色回流护栏：period 页源码不得再出现旧阶段色字面量', () {
    final src = File('lib/features/period/period_page.dart').readAsStringSync();
    for (final banned in [
      '0xFFEF3F68)', // 阶段表旧色（注释中的引用不带右括号，不误伤）
      '0xFF81C784)',
      '0xFFFFB74D)',
      'Color(0xFF7E57C2)', // 第二套紫（排卵日）
      'Color(0xFFF8BBD0)', // 图例旧浅粉
    ]) {
      expect(src.contains(banned), isFalse,
          reason: '2.3.9 起阶段色只允许走 period_colors.dart 语义表，'
              '发现写死色回流: $banned');
    }
    // 语义表文件本身必须存在且是唯一色源。
    final table =
        File('lib/features/period/period_colors.dart').readAsStringSync();
    expect(table.contains('0xFFC23F68'), isTrue, reason: '浅色 --period');
    expect(table.contains('0xFFEE7C9F'), isTrue, reason: '夜色 --period');
  });
}
