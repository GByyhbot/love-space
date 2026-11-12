/* 三项合并修复单测（气泡九宫格 + 五处取色归一 + 时光媒体铺满）：
   ① ninePatchPieces 目标矩形矩阵：角 42→16 缩放、边带 stretch、中心 fill、
      flipX 源列对调（且源区不出界）、目标盒过小时 clamp 与中带跳过；
   ② 皮肤态字色（#2B2029 / #fff + 淡投影）；
   ③ 五处外壳取色归一（同色同 alpha、深浅两模式、状态栏同源反推亮度）；
   ④ ChatBubbleFrame 宽度随内容扩展 widget 断言（短窄长宽、44 下限、
      85%/92% 上限、卡内 Expanded 不炸）；
   ⑤ 时光媒体网格宽度（纯函数 + PostCard 单图铺满卡片内容宽 widget 断言）。 */
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_chrome.dart';
import 'package:love_space/core/chat/chat_media.dart' show chatBaseProvider;
import 'package:love_space/core/chat/keyboard_metrics.dart';
import 'package:love_space/core/chat/nine_patch_border.dart';
import 'package:love_space/core/timeline/timeline_data.dart';
import 'package:love_space/features/auth/auth_state.dart';
import 'package:love_space/features/chat/input_slots.dart';
import 'package:love_space/features/chat/media_bubble_widgets.dart';
import 'package:love_space/features/chat/skin_bubble.dart';
import 'package:love_space/features/timeline/post_card.dart';

/// Web 素材与 border-image 参数（static/style.css:2517-2531 实读）
const _imgW = 128.0;
const _imgH = 112.0;
const _slice = 42.0;
const _border = 16.0;

List<NinePatchPiece> _pieces({
  required double dstW,
  required double dstH,
  bool flipX = false,
  double imgW = _imgW,
  double imgH = _imgH,
  double slice = _slice,
  double border = _border,
}) =>
    ninePatchPieces(
      imgW: imgW,
      imgH: imgH,
      slice: slice,
      dstW: dstW,
      dstH: dstH,
      border: border,
      flipX: flipX,
    );

/// 仿气泡内容：Column 在 loose 约束下随内容收缩；[withCard] 内放 Expanded，
/// 用于回归「IntrinsicWidth 给子树无界宽会让卡片里的 Expanded 炸掉」。
Widget _bubbleContent(String text, {bool withCard = false}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text),
          if (withCard)
            const Row(children: [
              Icon(Icons.place_rounded, size: 16),
              Expanded(child: Text('位置 · 点开用高德地图看')),
            ]),
        ],
      ),
    );

void main() {
  // ── ① 九宫格目标矩形矩阵 ────────────────────────────────────────────
  group('① ninePatchPieces（42 源角 → 16 目标角 / stretch / fill）', () {
    test('标准 200×100 目标盒：9 片、角缩放/边带拉伸/中心 fill、矩形无缝铺满',
        () {
      final ps = _pieces(dstW: 200, dstH: 100);
      expect(ps, hasLength(9));

      // 角：源 42×42 → 目标 16×16（centerSlice 缺的正是这层缩放语义）
      expect(ps[0].src, const Rect.fromLTWH(0, 0, 42, 42));
      expect(ps[0].dst, const Rect.fromLTWH(0, 0, 16, 16));
      expect(ps[2].src, const Rect.fromLTWH(86, 0, 42, 42));
      expect(ps[2].dst, const Rect.fromLTWH(184, 0, 16, 16));
      expect(ps[6].src, const Rect.fromLTWH(0, 70, 42, 42));
      expect(ps[6].dst, const Rect.fromLTWH(0, 84, 16, 16));
      expect(ps[8].src, const Rect.fromLTWH(86, 70, 42, 42));
      expect(ps[8].dst, const Rect.fromLTWH(184, 84, 16, 16));

      // 边带 stretch：源 44×42 → 目标 168×16；中心 fill：44×28 → 168×68
      expect(ps[1].src, const Rect.fromLTWH(42, 0, 44, 42));
      expect(ps[1].dst, const Rect.fromLTWH(16, 0, 168, 16));
      expect(ps[3].src, const Rect.fromLTWH(0, 42, 42, 28));
      expect(ps[3].dst, const Rect.fromLTWH(0, 16, 16, 68));
      expect(ps[4].src, const Rect.fromLTWH(42, 42, 44, 28));
      expect(ps[4].dst, const Rect.fromLTWH(16, 16, 168, 68));
      expect(ps[5].src, const Rect.fromLTWH(86, 42, 42, 28));
      expect(ps[5].dst, const Rect.fromLTWH(184, 16, 16, 68));
      expect(ps[7].src, const Rect.fromLTWH(42, 70, 44, 42));
      expect(ps[7].dst, const Rect.fromLTWH(16, 84, 168, 16));

      // 全部落在源图与目标盒内
      for (final p in ps) {
        expect(p.src.left, greaterThanOrEqualTo(0));
        expect(p.src.top, greaterThanOrEqualTo(0));
        expect(p.src.right, lessThanOrEqualTo(_imgW + 1e-9));
        expect(p.src.bottom, lessThanOrEqualTo(_imgH + 1e-9));
        expect(p.dst.left, greaterThanOrEqualTo(0));
        expect(p.dst.top, greaterThanOrEqualTo(0));
        expect(p.dst.right, lessThanOrEqualTo(200 + 1e-9));
        expect(p.dst.bottom, lessThanOrEqualTo(100 + 1e-9));
      }
    });

    test('flipX：源区三列左右对调、目标列不变，且源矩形不出界（无负宽）', () {
      final ps = _pieces(dstW: 200, dstH: 100, flipX: true);
      expect(ps, hasLength(9));
      // 目标左上角取源右上角（角饰换边）
      expect(ps[0].src, const Rect.fromLTWH(86, 0, 42, 42));
      expect(ps[0].dst, const Rect.fromLTWH(0, 0, 16, 16));
      // 中带左右对称，源区不变
      expect(ps[1].src, const Rect.fromLTWH(42, 0, 44, 42));
      expect(ps[4].src, const Rect.fromLTWH(42, 42, 44, 28));
      // 目标右上角取源左上角
      expect(ps[2].src, const Rect.fromLTWH(0, 0, 42, 42));
      expect(ps[2].dst, const Rect.fromLTWH(184, 0, 16, 16));
      for (final p in ps) {
        expect(p.src.left, greaterThanOrEqualTo(0));
        expect(p.src.width, greaterThan(0));
        expect(p.src.right, lessThanOrEqualTo(_imgW + 1e-9));
      }
    });

    test('目标盒 20×20 < 2×border：边带 clamp 到 10、中带跳过只剩 4 角', () {
      final ps = _pieces(dstW: 20, dstH: 20);
      expect(ps, hasLength(4));
      expect(ps[0].dst, const Rect.fromLTWH(0, 0, 10, 10));
      expect(ps[1].dst, const Rect.fromLTWH(10, 0, 10, 10));
      expect(ps[2].dst, const Rect.fromLTWH(0, 10, 10, 10));
      expect(ps[3].dst, const Rect.fromLTWH(10, 10, 10, 10));
      for (final p in ps) {
        expect(p.dst.width, 10);
        expect(p.dst.height, 10);
      }
    });

    test('源图过窄（imgW<2×slice）：源中带为负 → 跳过中列', () {
      final ps = _pieces(dstW: 200, dstH: 100, imgW: 60);
      // 每行只剩左右两列 × 3 行 = 6 片
      expect(ps, hasLength(6));
      for (final p in ps) {
        expect(p.src.width, greaterThan(0));
      }
    });
  });

  // ── ② 皮肤态字色 ───────────────────────────────────────────────────
  group('② 皮肤态字色（Web .skinned / .skinned.light 写死）', () {
    test('深色字 #2B2029 无投影；浅色字 #fff + 0 1px 3px 淡投影', () {
      final dark = skinTextStyle(const TextStyle(fontSize: 14), fgLight: false);
      expect(dark.color, skinDarkFg);
      expect(skinDarkFg, const Color(0xFF2B2029));
      expect(dark.shadows, isEmpty);
      expect(dark.fontSize, 14, reason: '基础样式须保留');

      final light = skinTextStyle(const TextStyle(fontSize: 14), fgLight: true);
      expect(light.color, skinLightFg);
      expect(skinLightFg, Colors.white);
      expect(light.shadows, skinLightShadows);
      expect(light.shadows!.single.blurRadius, 3);
      expect(light.shadows!.single.offset, const Offset(0, 1));
      expect(light.shadows!.single.color, const Color(0x52000000));
    });
  });

  // ── ③ 五处外壳取色归一 ─────────────────────────────────────────────
  group('③ 五处取色归一（顶栏/状态栏/输入栏/⊕面板/贴纸坞）', () {
    test('浅/深主题 × 沉浸/普通：同一 alpha，状态栏同源反推图标亮度', () {
      for (final theme in <ThemeData>[ThemeData.light(), ThemeData.dark()]) {
        for (final immersive in <bool>[false, true]) {
          final c = chatChromeColor(theme, immersive: immersive);
          expect(c.a, closeTo(chatChromeAlpha, 1e-9),
              reason: 'immersive=$immersive 也必须是同一个 alpha');
          final overlay =
              chatChromeOverlayStyle(theme, immersive: immersive);
          expect(overlay.statusBarColor, c, reason: '状态栏底色与顶栏同源');
          expect(overlay.systemNavigationBarColor, c);
          final darkBg =
              ThemeData.estimateBrightnessForColor(c) == Brightness.dark;
          expect(overlay.statusBarIconBrightness,
              darkBg ? Brightness.light : Brightness.dark);
          expect(overlay.systemNavigationBarIconBrightness,
              darkBg ? Brightness.light : Brightness.dark);
        }
      }
      final normal = chatChromeColor(ThemeData.light(), immersive: false);
      final immersive = chatChromeColor(ThemeData.light(), immersive: true);
      expect(normal.a, immersive.a, reason: '不许一块实一块透');
      expect(
          chatChromeColor(ThemeData.dark(), immersive: false), isNot(normal),
          reason: '深色主题 surface 自动跟随');
    });

    test('气泡宽度上下限纯函数（Web 85%/92% + min-width:44px）', () {
      expect(bubbleMinWidth, 44.0);
      expect(boxMax(320), closeTo(320 * 0.92 - 44, 1e-9));
      expect(boxMax(800), closeTo(800 * 0.85 - 44, 1e-9));
      final c = ChatBubbleFrame.constraintsFor(400);
      expect(c.minWidth, bubbleMinWidth);
      expect(c.maxWidth, bubbleMaxWidth(400));
    });
  });

  // ── ④ 气泡宽度随内容扩展（生产组件 widget 断言）─────────────────────
  group('④ ChatBubbleFrame 宽度随内容扩展', () {
    testWidgets('短消息窄 / 长文本宽至上限 / 卡内 Expanded 不炸', (tester) async {
      const viewport = 400.0;

      Future<double> widthOf(String text, {bool withCard = false}) async {
        await tester.pumpWidget(MaterialApp(
          home: Builder(builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(size: const Size(viewport, 800)),
                child: Scaffold(
                  body: SizedBox(
                    width: viewport,
                    child: Row(children: [
                      Flexible(
                        child: ChatBubbleFrame(
                          child: _bubbleContent(text, withCard: withCard),
                        ),
                      ),
                    ]),
                  ),
                ),
              )),
        ));
        await tester.pump();
        return tester.getSize(find.byType(ChatBubbleFrame)).width;
      }

      final short = await widthOf('好');
      final long = await widthOf(
          '今天天气很好，我们一起去了很多很多地方玩了一整天，还拍了好多好多照片，'
          '下次还要再一起去更远的地方看看风景吃好吃的');
      expect(short, greaterThanOrEqualTo(bubbleMinWidth));
      expect(long, greaterThan(short), reason: '长文本气泡必须随内容变宽');
      expect(long, lessThanOrEqualTo(bubbleMaxWidth(viewport) + 1.0));

      // 位置/歌卡内含 Expanded：不用 IntrinsicWidth 的回归断言
      final card = await widthOf('位置', withCard: true);
      expect(card, greaterThanOrEqualTo(bubbleMinWidth));
      expect(tester.takeException(), isNull);
    });
  });

  // ── ⑤ 时光媒体网格铺满卡宽 ─────────────────────────────────────────
  group('⑤ 时光媒体网格（Web .media-grid 3 列 / .single 16:10）', () {
    test('纯函数：3 列等分、8dp 间隙、单图 16/10 且封顶 360', () {
      expect(timelineMediaGap, 8.0);
      expect(timelineMediaCell(308), closeTo((308 - 16) / 3, 1e-9));
      expect(timelineSingleMediaHeight(320), closeTo(200.0, 1e-9));
      expect(timelineSingleMediaHeight(1000), 360.0);
    });

    testWidgets('PostCard 单图铺满卡片内容宽（右侧不再留 2/3 空白）',
        (tester) async {
      const viewport = 400.0;
      final record = api.Record(
        id: 'r1',
        kind: 'post',
        author: 'u1',
        body: const {'content': '配图'},
        created: 1.0,
        media: const [
          {'id': 'm1', 'mime': 'image/jpeg', 'name': 'a.jpg'},
        ],
      );
      final me = MeData(
        user: const SpaceUser(id: 'u1', name: '我', username: 'u'),
        users: const [SpaceUser(id: 'u1', name: '我', username: 'u')],
        spaceName: '',
        spaceRaw: const {},
        spaceSince: '',
      );
      // base 永远 loading → MediaImageView 走中性占位，测试不发任何网络请求
      await tester.pumpWidget(ProviderScope(
        overrides: [
          chatBaseProvider.overrideWith((ref) => Completer<String>().future),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: viewport,
                child: PostCard(record: record, me: me),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();

      // 卡片：margin 16×2 + padding 14×2 + 1px 边框×2
      const expected = viewport - 32 - 28 - 2;
      final img = tester.widget<MediaImageView>(find.byType(MediaImageView));
      expect(img.width, closeTo(expected, 1.0), reason: '单图宽 = 卡片内容宽');
      expect(img.height,
          closeTo(timelineSingleMediaHeight(expected), 1.0));
      // 实际渲染盒也铺满（占位与真图同尺寸）
      final box = tester.getSize(find.byType(MediaImageView));
      expect(box.width, closeTo(expected, 1.0));
      expect(box.height,
          closeTo(timelineSingleMediaHeight(expected), 1.0));
    });

    testWidgets('PostCard 多图 3 列等分（每格 = (卡宽-16)/3）', (tester) async {
      const viewport = 400.0;
      api.Record rec(int n) => api.Record(
            id: 'r$n',
            kind: 'post',
            author: 'u1',
            body: const {'content': '多图'},
            created: 1.0,
            media: [
              for (var i = 0; i < n; i++)
                {'id': 'm$i', 'mime': 'image/jpeg', 'name': '$i.jpg'},
            ],
          );
      final me = MeData(
        user: const SpaceUser(id: 'u1', name: '我', username: 'u'),
        users: const [SpaceUser(id: 'u1', name: '我', username: 'u')],
        spaceName: '',
        spaceRaw: const {},
        spaceSince: '',
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [
          chatBaseProvider.overrideWith((ref) => Completer<String>().future),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: viewport,
                child: PostCard(record: rec(3), me: me),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();

      // 卡片：margin 16×2 + padding 14×2 + 1px 边框×2
      const expected = viewport - 32 - 28 - 2;
      final cell = timelineMediaCell(expected);
      final found = find.byType(MediaImageView);
      expect(found, findsNWidgets(3));
      for (final element in found.evaluate()) {
        final w = element.findRenderObject()! as RenderBox;
        expect(w.size.width, closeTo(cell, 1.0));
        expect(w.size.height, closeTo(cell, 1.0), reason: '1:1 方格');
      }
    });
  });

  group('⑥ CSS 盒模型：border-image 的 16px 边框占布局空间', () {
    test('skinBubblePadding = padding(3,7) + border(16)，成功/回退同源', () {
      final p = skinBubblePadding(_border);
      // Web：border-box = 内容 + 2×padding(3/7) + 2×border(16)
      expect(p.horizontal, 2 * (7 + _border)); // 46
      expect(p.vertical, 2 * (3 + _border)); // 38
      expect(skinBubblePadding(0),
          const EdgeInsets.symmetric(horizontal: 7, vertical: 3));
    });

    test('单行文本目标盒：中心 fill 区恰好容纳「内容+padding」，文字不被边带压住',
        () {
      const contentW = 100.0;
      const contentH = 20.0;
      final p = skinBubblePadding(_border);
      final dstW = contentW + p.horizontal;
      final dstH = contentH + p.vertical;
      expect(dstW, 146);
      expect(dstH, 58, reason: '旧实现只给 26px 高 → 上下 16px 边带把文字夹住');
      final pieces = _pieces(dstW: dstW, dstH: dstH);
      expect(pieces, hasLength(9));
      // 四角各 16×16；中心 fill 区 = (W-32)×(H-32) = 114×26
      expect(pieces[4].dst, const Rect.fromLTWH(16, 16, 114, 26));
      expect(pieces[4].dst.width, closeTo(contentW + 14, 1e-9));
      expect(pieces[4].dst.height, closeTo(contentH + 6, 1e-9),
          reason: '内容区与中心 fill 区严格对齐，换行文本不会溢出气泡');
    });

    testWidgets('SkinBubble 回退态用同一套内边距（解码完成不跳变）',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          chatBaseProvider.overrideWith((ref) => Completer<String>().future),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SkinBubble(
                url: 'https://test.local/api/bubbles/p1/1000.png',
                child: const Text('嗯嗯'),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      final container = tester.widget<Container>(find.descendant(
          of: find.byType(SkinBubble), matching: find.byType(Container)));
      expect(container.padding, skinBubblePadding(_border));
    });
  });

  group('⑦ 键盘与工具栏互切：槽位恒占位 + 键盘独占位移', () {
    test('slotOccupied / visibleSlot：面板被键盘压住期间槽位与内容都不撤', () {
      final m = InputSlotMachine()..handle(InputSlotEvent.toggleFn);
      expect(m.slotOccupied, isTrue);
      expect(m.visibleSlot, InputSlot.fn);
      m.handle(InputSlotEvent.keyboardFocus); // 键盘压住面板
      expect(m.slot, InputSlot.none);
      expect(m.intent, InputSlot.fn);
      expect(m.slotOccupied, isTrue, reason: '槽位仍占位，输入栏不下沉');
      expect(m.visibleSlot, InputSlot.fn, reason: '面板内容不闪空白');
      m.handle(InputSlotEvent.keyboardClosed); // 回位
      expect(m.slotOccupied, isTrue);
      expect(m.visibleSlot, InputSlot.fn, reason: '回位前后可见内容不变');
      m.handle(InputSlotEvent.toggleFn); // 亲手收起
      expect(m.slotOccupied, isFalse);
      expect(m.visibleSlot, InputSlot.none);
    });

    test('slotAnimationDuration：键盘过渡零动画，纯面板展开保留电梯动效', () {
      expect(
          slotAnimationDuration(slotOccupied: true, keyboardActive: true),
          Duration.zero);
      expect(
          slotAnimationDuration(slotOccupied: true, keyboardActive: false),
          const Duration(milliseconds: 200));
      expect(
          slotAnimationDuration(slotOccupied: false, keyboardActive: true),
          const Duration(milliseconds: 200),
          reason: '纯键盘态槽位恒 0，无高度变化可动画');
    });

    test('互切全程恒等式：slotHeight + insets ≡ kbHeight，输入栏零位移', () {
      const kb = 320.0;
      final m = InputSlotMachine()..handle(InputSlotEvent.toggleSticker);
      // 键盘→面板：insets 逐帧降到 0
      for (final insets in [320.0, 240.0, 160.0, 80.0, 0.0]) {
        final h = slotHeightFor(
            slotOpen: m.slotOccupied, insets: insets, kbHeight: kb);
        expect(h + insets, closeTo(kb, 1e-9));
      }
      // 面板→键盘：状态机压掉面板（intent 保住占位），insets 从 0 升回 kb
      m.handle(InputSlotEvent.keyboardFocus);
      for (final insets in [0.0, 80.0, 160.0, 240.0, 320.0]) {
        final h = slotHeightFor(
            slotOpen: m.slotOccupied, insets: insets, kbHeight: kb);
        expect(h + insets, closeTo(kb, 1e-9),
            reason: '旧实现此处槽位归零 → 输入栏下沉再展开');
      }
      // 键盘收起 → 面板回位，insets 降回 0，仍恒定
      m.handle(InputSlotEvent.keyboardClosed);
      for (final insets in [320.0, 160.0, 0.0]) {
        final h = slotHeightFor(
            slotOpen: m.slotOccupied, insets: insets, kbHeight: kb);
        expect(h + insets, closeTo(kb, 1e-9));
      }
    });

    test('纯键盘展开/收起：无面板占位时槽位恒 0，不叠任何 App 侧动画', () {
      const kb = 320.0;
      final m = InputSlotMachine();
      for (final insets in [0.0, 100.0, 320.0, 150.0, 0.0]) {
        final h = slotHeightFor(
            slotOpen: m.slotOccupied, insets: insets, kbHeight: kb);
        expect(h, 0);
        expect(m.visibleSlot, InputSlot.none);
      }
    });
  });
}

/// 取宽度上限（便于断言里少写一层）
double boxMax(double viewportWidth) => bubbleMaxWidth(viewportWidth);
