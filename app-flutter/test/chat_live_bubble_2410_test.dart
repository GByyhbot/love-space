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

  testWidgets('07 宽度口径：按钮收敛小圆钮同行，文字折行点 ≥ 气泡内宽 90%',
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

    // 断言①：按钮收敛 30px×3 同行后，气泡（TextField）占胶囊内宽 ~71%；
    // 钉住下限防回涨——23:37 缺陷时三枚标准钮占 152px 把气泡挤到 58%。
    // 气泡内宽基准：393 - 胶囊外 margin(10×2) - 胶囊内 padding(6×2) = 361。
    final field =
        tester.renderObject<RenderBox>(find.byType(TextField)).size.width;
    const capsuleInner = 393.0 - 20 - 12;
    expect(field, greaterThanOrEqualTo(capsuleInner * 0.65),
        reason: '常驻按钮必须收敛：气泡宽 ≥ 胶囊内宽 65%'
            '（原三枚标准钮 152px 曾把气泡挤到 58% → 折行点 60%）');

    // 断言②：长度介于「旧 60% 折行点」与「气泡满宽」之间的文本必须单行，
    // 且折行点 ≥ 文本可用宽 90%。🔴 文本可用宽单一事实源 = RenderEditable
    // 实际宽度；🔴 单字 advance 也用渲染实测（裸 TextPainter 量不含主题
    // letterSpacing，实测 16.53 vs 裸量 16.0——曾因此选字数全部失准）。
    final editableRoot =
        tester.renderObject<RenderObject>(find.byType(EditableText));
    final editable = _findEditable(editableRoot);
    final editableW = editable.size.width;
    await tester.enterText(find.byType(TextField), '长');
    await tester.pump();
    await tester.pumpAndSettle();
    final charW = _findEditable(
            tester.renderObject<RenderObject>(find.byType(EditableText)))
        .getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 1))
        .first
        .right;
    final n = ((editableW * 0.985) / charW).floor();
    expect(n * charW, greaterThan(capsuleInner * 0.58),
        reason: '测试文本长度必须超过旧 60% 折行点（实测 209px ≈ 内宽 58%，'
            '否则断言无区分度）');
    await tester.enterText(find.byType(TextField), '长' * n);
    await tester.pump();
    await tester.pumpAndSettle();

    final boxes = editable.getBoxesForSelection(TextSelection(
      baseOffset: 0,
      extentOffset: n,
    ));
    final lineTops = boxes.map((b) => b.top).toSet();
    expect(lineTops.length, 1,
        reason: '长度介于旧 60% 折行点与气泡满宽之间的文本必须单行放下');
    // 折行点（文本行右端）≥ 文本可用宽 90%：右侧不许成段空白
    final foldPoint =
        boxes.map((b) => b.right).reduce((a, b) => a > b ? a : b);
    expect(foldPoint, greaterThanOrEqualTo(editableW * 0.9),
        reason: '折行点必须落在气泡内宽 90% 以后'
            '（07 第二轮打回口径，气泡自身坐标系）');
  });

  testWidgets('07 第三轮结构断言：输入区单条——TextField 全树唯一且'
      '渲染矩形完整落在屏幕宽度内（常态 + 键盘态）', (tester) async {
    tester.view.physicalSize = const Size(393, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        chatBaseProvider.overrideWith((ref) => _hang().future),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Column(children: [
            const Spacer(),
            ChatCompose(),
          ]),
        ),
      ),
    ));
    await tester.pump();

    void assertSingleInScreen(String phase) {
      // ① 树里 TextField 只许一个（真机「重复渲染/两份输入框」防线）
      expect(tester.widgetList(find.byType(TextField)).length, 1,
          reason: '输入区有且只有一条：TextField 全树唯一（$phase）');
      // ② 渲染矩形左右不越屏（真机「左裁切/圆角被切」防线）
      final box = tester.renderObject<RenderBox>(find.byType(TextField));
      final topLeft = box.localToGlobal(Offset.zero);
      final bottomRight =
          box.localToGlobal(box.size.bottomRight(Offset.zero));
      expect(topLeft.dx, greaterThanOrEqualTo(0),
          reason: '输入区左缘不许越出屏幕（$phase）');
      expect(bottomRight.dx, lessThanOrEqualTo(393),
          reason: '输入区右缘不许越出屏幕（$phase）');
    }

    // 常态
    assertSingleInScreen('常态');
    final widthBefore = tester
        .renderObject<RenderBox>(find.byType(TextField))
        .size
        .width;

    // 键盘打开态：viewInsets 注入 300px，Scaffold resize 压缩 body
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    assertSingleInScreen('键盘打开态');
    // 形态不错位：键盘开合气泡宽度恒定（单条不换行不重排）
    final widthAfter = tester
        .renderObject<RenderBox>(find.byType(TextField))
        .size
        .width;
    expect(widthAfter, widthBefore,
        reason: '键盘开合输入区形态恒定：气泡宽度不许变化（单条纪律）');

    // 键盘收起再验一轮（开/合各一轮）
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    assertSingleInScreen('键盘收起态');
  });
}
