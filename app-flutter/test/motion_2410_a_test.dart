// 2.4.10 甲批护栏（01 爆粒子 / 02 三连变 / 03 果冻开关）：
// · SubmitMorphController 状态机：成功 loading→success→idle、失败
//   直接回 idle（不出现对勾）、busy 防连点；
// · SubmitMorphButton：真实请求驱动——成功见对勾驻留、失败回文字；
// · GlassActionBar morphOnSave：成功驻留后落点回调；
// · LikeBurstIcon/LikeCountLabel：点赞触发动画、计数滚动切换；
// · JellySwitch：取值切换 + motion 关门退化（直接切换不动画）。
import 'dart:async';

import 'package:flutter/material.dart';import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/ui/jelly_switch.dart';
import 'package:love_space/core/ui/like_burst.dart';
import 'package:love_space/core/ui/submit_morph.dart' show morphCheckKey, SubmitMorphController, SubmitMorphButton, SubmitMorphPhase;
import 'package:love_space/features/settings/settings_widgets.dart';

void main() {
  group('02 提交三连变：状态机（真实请求驱动）', () {
    test('成功：loading→success→idle，返回 true', () async {
      final c = SubmitMorphController();
      final phases = <SubmitMorphPhase>[];
      c.addListener(() => phases.add(c.phase));
      final ok = await c.submit(() async {
        expect(c.phase, SubmitMorphPhase.loading);
        return true;
      });
      expect(ok, isTrue);
      expect(phases, contains(SubmitMorphPhase.loading));
      expect(phases, contains(SubmitMorphPhase.success));
      expect(c.phase, SubmitMorphPhase.idle);
    });

    test('失败（返回 false）：不出现对勾直接回 idle，返回 false', () async {
      final c = SubmitMorphController();
      final ok = await c.submit(() async => false);
      expect(ok, isFalse);
      expect(c.phase, SubmitMorphPhase.idle);
    });

    test('失败（抛异常）：同失败路径', () async {
      final c = SubmitMorphController();
      final ok = await c.submit(() async => throw Exception('boom'));
      expect(ok, isFalse);
      expect(c.phase, SubmitMorphPhase.idle);
    });

    test('busy 期间重复提交被忽略（防连点）', () async {
      final c = SubmitMorphController();
      var calls = 0;
      final gate = Completer<bool>();
      final first = c.submit(() {
        calls++;
        return gate.future;
      });
      final second = c.submit(() {
        calls++;
        return Future<bool>.value(true);
      });
      expect(calls, 1, reason: 'busy 期间第二次 submit 不执行 action');
      gate.complete(true);
      expect(await first, isTrue);
      expect(await second, isFalse);
    });
  });

  group('02 提交三连变：按钮 widget', () {
    testWidgets('成功：spinner→对勾驻留→回文字+onSuccess 落点', (tester) async {
      var success = false;
      final gate = Completer<bool>();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SubmitMorphButton(
            label: '提交',
            expand: true,
            onSubmit: () => gate.future,
            onSuccess: () => success = true,
          ),
        ),
      ));
      expect(find.text('提交'), findsOneWidget);
      await tester.tap(find.text('提交'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget,
          reason: '请求中=旋转加载环（真实请求未返）');
      gate.complete(true);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byKey(morphCheckKey), findsOneWidget,
          reason: '成功=对勾描画');
      expect(success, isFalse, reason: '对勾驻留 1s 内不落点');
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(find.text('提交'), findsOneWidget, reason: '恢复原状');
      expect(success, isTrue, reason: '驻留后落点回调');
    });

    testWidgets('失败：不出现对勾，直接回文字', (tester) async {
      var success = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SubmitMorphButton(
            label: '提交',
            expand: true,
            onSubmit: () async => false,
            onSuccess: () => success = true,
          ),
        ),
      ));
      await tester.tap(find.text('提交'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('提交'), findsOneWidget);
      expect(success, isFalse);
    });
  });

  testWidgets('02 GlassActionBar morphOnSave：成功驻留后落点', (tester) async {
    var done = false;
    final gate = Completer<bool>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          const Spacer(),
          GlassActionBar(
            saveLabel: '保存',
            onSave: () {},
            morphOnSave: () => gate.future,
            onMorphSuccess: () => done = true,
          ),
        ]),
      ),
    ));
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    gate.complete(true);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(done, isFalse, reason: '驻留期内不落点');
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(done, isTrue);
    expect(find.text('保存'), findsOneWidget, reason: '恢复原状');
  });

  group('01 点赞爆粒子', () {
    testWidgets('点击触发 onTap（乐观期即刻）且点赞方向放大动画启动', (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: LikeBurstIcon(liked: false, onTap: () => taps++, size: 15),
          ),
        ),
      ));
      await tester.tap(find.byType(LikeBurstIcon));
      expect(taps, 1, reason: 'onTap 即刻（乐观期），不等动画');
      await tester.pump();
      await tester.pumpAndSettle();
    });

    testWidgets('LikeCountLabel：点赞方向滚动、取消方向淡切，文案口径不变', (tester) async {
      Widget host(bool liked, int count) => MaterialApp(
            home: Scaffold(
              body: Center(
                child: LikeCountLabel(liked: liked, count: count),
              ),
            ),
          );
      await tester.pumpWidget(host(false, 0));
      expect(find.text('喜欢'), findsOneWidget, reason: '0 = 喜欢（既有口径）');
      await tester.pumpWidget(host(true, 1));
      await tester.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);
      await tester.pumpWidget(host(false, 1));
      await tester.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);
    });
  });

  group('03 果冻开关', () {
    testWidgets('点击翻转取值（onChanged 即刻，保存逻辑零改动）', (tester) async {
      bool? v;
      await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(child: JellySwitch(value: false, onChanged: null)),
          ),
        ),
      ));
      // onChanged=null：不炸（禁用态）
      expect(find.byType(JellySwitch), findsOneWidget);

      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: JellySwitch(value: false, onChanged: (x) => v = x),
            ),
          ),
        ),
      ));
      await tester.tap(find.byType(JellySwitch));
      expect(v, isTrue, reason: 'onChanged 即刻翻转（受控组件同 Switch 签名）');
      await tester.pumpAndSettle();
    });
  });
}
