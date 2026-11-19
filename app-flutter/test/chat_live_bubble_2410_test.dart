// 2.4.10 丙批 07 打回防回归：输入气泡长高全链。
// 🔴 缺陷根因：_OvershootGrow 的 OverflowBox 未设宽度维度时对子默认
// min 0 / max infinity（非透传）→ TextField 无界宽横向长、永不折行、
// 气泡恒单行（真机实证）。本测试锁死：超宽长文本下输入框必须折行
// （渲染高度 ≥2 行）、包装容器高度跟随（≥2 行高），不许只断「无异常」。
// 🔴 07 第二轮打回（宽度口径）：常驻三按钮与输入框同行，占 152px
// 把文本区挤到气泡内宽 58%、折行点钉死在 60%（真机截图实证）。
// 修复：按钮收敛为右对齐细行上移、输入框独占整行。本测试锁死：
// ① 输入框宽 ≥ 气泡内宽 90%（常驻按钮不得挤压文本区）；
// ② 长度介于旧 60% 折行点与满宽之间的文本必须单行不折。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/chat/chat_media.dart' show chatBaseProvider;
import 'package:love_space/features/chat/chat_compose.dart';

// chatBaseProvider 挂起（同 chat_merge_fix_test 手法：不发网络请求）
Completer<String> _hang() => Completer<String>();

// 🔴 新 Flutter 的 EditableText 元素 renderObject 是 composition callback
// 包装层（_RenderCompositionCallback），不是 RenderEditable 本体——递归下探。
RenderEditable _findEditable(RenderObject node) {
  if (node is RenderEditable) return node;
  RenderEditable? hit;
  node.visitChildren((child) {
    hit ??= _findEditable(child);
  });
  if (hit == null) throw StateError('RenderEditable not found');
  return hit!;
}

void main() {
  Future<Size> pumpAndMeasure(WidgetTester tester, String text) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        chatBaseProvider.overrideWith((ref) => _hang().future),
      ],
      child: MaterialApp(
        home: Scaffold(
          // 🔴 挂载必须 tight 宽（对齐真机 Scaffold body 链路）：Align 给
          // loose 宽会让 Expanded 失去 flex 分配、输入框收缩到内容宽——
          // 与真机缺陷同表象但根因不同（环境假象，曾误导排查）。
          body: Column(children: [
            const Spacer(),
            ChatCompose(),
          ]),
        ),
      ),
    ));
    await tester.pump();
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.pumpAndSettle();
    final box = tester.renderObject<RenderBox>(find.byType(TextField));
    return box.size;
  }

  testWidgets('单行基准：输入短文本，输入框高 < 2 行', (tester) async {
    tester.view.physicalSize = const Size(393, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final short = await pumpAndMeasure(tester, '你好');
    final long = await pumpAndMeasure(tester, '长' * 200); // 无空格超宽文本
    expect(long.height, greaterThan(short.height * 1.5),
        reason: '超宽长文本必须折行：高度显著超过单行（07 打回缺陷回归线）');
    expect(long.height, greaterThanOrEqualTo(short.height * 2),
        reason: '200 字无空格在 393 宽下至少 2 行');
  });

  testWidgets('包装容器高度跟随行数（气泡真的长高，不是只靠内部滚动）', (tester) async {
    tester.view.physicalSize = const Size(393, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        chatBaseProvider.overrideWith((ref) => _hang().future),
      ],
      child: MaterialApp(
        home: Scaffold(
          // 🔴 挂载必须 tight 宽（对齐真机 Scaffold body 链路）：Align 给
          // loose 宽会让 Expanded 失去 flex 分配、输入框收缩到内容宽——
          // 与真机缺陷同表象但根因不同（环境假象，曾误导排查）。
          body: Column(children: [
            const Spacer(),
            ChatCompose(),
          ]),
        ),
      ),
    ));
    await tester.pump();
    // 未输入：找输入气泡容器（_OvershootGrow 的 SizedBox）高度
    Size fieldBox() =>
        tester.renderObject<RenderBox>(find.byType(TextField)).size;
    final single = fieldBox().height;
    await tester.enterText(find.byType(TextField), '行' * 300);
    await tester.pump();
    await tester.pumpAndSettle();
    final multi = fieldBox().height;
    expect(multi, greaterThan(single * 1.8),
        reason: '输入气泡必须按行数长高（maxLines 4 封顶语义下的 2+ 行）');
    // 折行验证：TextField 宽度必须等于父约束宽（393-两侧边距），不许横向溢出
    expect(
        tester.renderObject<RenderBox>(find.byType(TextField)).size.width,
        lessThan(393),
        reason: 'TextField 处于有界宽内（无界宽=横向一路长不折行，打回根因）');
  });

  testWidgets('07 第二轮宽度口径：输入框独占气泡整行，中长文本不提前折行',
      (tester) async {
    tester.view.physicalSize = const Size(393, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        chatBaseProvider.overrideWith((ref) => _hang().future),
      ],
      child: MaterialApp(
        home: Scaffold(
          // 🔴 挂载必须 tight 宽（对齐真机 Scaffold body 链路）：Align 给
          // loose 宽会让 Expanded 失去 flex 分配——环境假象，曾误导排查。
          body: Column(children: [
            const Spacer(),
            ChatCompose(),
          ]),
        ),
      ),
    ));
    await tester.pump();

    // 断言①：常驻按钮细行上移后，输入框宽 ≥ 气泡内宽 90%。
    // 气泡内宽单一来源：393 - 胶囊外 margin(10×2) - 胶囊内 padding(6×2)。
    final field =
        tester.renderObject<RenderBox>(find.byType(TextField)).size.width;
    const capsuleInner = 393.0 - 20 - 12;
    expect(field, greaterThanOrEqualTo(capsuleInner * 0.9),
        reason: '常驻按钮必须让出文本区：输入框宽 ≥ 气泡内宽 90%'
            '（07 第二轮打回：按钮区占 42% 把折行点钉死在 60%）');

    // 断言②：长度介于「内宽 60% 折行点」与「满宽」之间的文本必须单行。
    // 用 TextPainter 按实际字宽取 0.8×可用宽的字符数，保证介于两界之间。
    final charTp = TextPainter(
      text: const TextSpan(text: '长', style: TextStyle(fontSize: 16)),
      textDirection: TextDirection.ltr,
    )..layout();
    final textAvail = field - 28; // contentPadding horizontal 14×2
    final n = ((textAvail * 0.8) / charTp.width).floor();
    expect(n * charTp.width, greaterThan(capsuleInner * 0.58),
        reason: '测试文本长度必须超过旧 60% 折行点（实测 209px ≈ 内宽 58%，'
            '否则断言无区分度）');
    await tester.enterText(find.byType(TextField), '长' * n);
    await tester.pump();
    await tester.pumpAndSettle();

    final editableRoot =
        tester.renderObject<RenderObject>(find.byType(EditableText));
    final editable = _findEditable(editableRoot);
    final boxes = editable.getBoxesForSelection(TextSelection(
      baseOffset: 0,
      extentOffset: n,
    ));
    final lineTops = boxes.map((b) => b.top).toSet();
    expect(lineTops.length, 1,
        reason: '长度介于内宽 60% 与满宽之间的文本必须单行放下'
            '（折行点必须落在内宽 90% 以后，右侧不许成段空白）');
  });
}
