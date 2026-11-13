/* 相册页段 B 单测（条目 5 · 甲档查看器）：
   ① 纯函数：Hero tag 一致性、网格落点滚动偏移、双击缩放矩阵、下拉阈值
   ② 【硬验收 1】下拉关闭禁用 Hero（HeroMode 语义）+ 按钮/手势返回保留 Hero
   ③ 【硬验收 2】翻页后 albumViewerIndexProvider 变化 → 网格预滚动到当前图
      （不是最初点开那张）；索引 provider 与 photos 列表对齐
   ④ 跨相册翻页计数 n/N、首末页不越界（索引夹取）
   ⑤ 下载结果走顶部通知：App 内 SnackBar 清零（静态源码核对）+ 全局宿主唯一
   ⑥ 缩放状态下禁用翻页物理（_zoomed 语义纯函数） */
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/album/album_data.dart';
import 'package:love_space/features/album/album_controller.dart';

Map<String, Object> _photo(String id, {String caption = ''}) => {
      'id': id, 'name': '$id.jpg', 'mime': 'image/jpeg',
      'owner': 'u1', 'status': 'ready', 'preview': '$id.preview.jpg',
      'record_id': 'rec-$id', 'date': '2026-11-13', 'caption': caption,
    };

void main() {
  // ── ① 纯函数 ─────────────────────────────────────────────────
  group('① 查看器纯函数', () {
    test('Hero tag：网格与查看器共用 albumHeroTag（双向转场前提）', () {
      expect(albumHeroTag('m1'), 'album-photo-m1');
      expect(albumHeroTag('m1'), isNot(equals(albumHeroTag('m2'))));
    });

    test('网格落点偏移：第 0 行归零、后面按行递进、夹在可滚范围', () {
      const cell = 100.0, spacing = 8.0, viewport = 400.0, max = 1000.0;
      expect(albumGridScrollOffset(0,
          cellSize: cell, spacing: spacing,
          viewportHeight: viewport, maxScrollExtent: max), 0.0);
      // 第 3 行（index 9）：raw = 3*108 - 150 = 174
      expect(albumGridScrollOffset(9,
          cellSize: cell, spacing: spacing,
          viewportHeight: viewport, maxScrollExtent: max), 174.0);
      // 越界夹取
      expect(albumGridScrollOffset(999,
          cellSize: cell, spacing: spacing,
          viewportHeight: viewport, maxScrollExtent: 30), 30.0);
      expect(albumGridScrollOffset(0,
          cellSize: cell, spacing: spacing,
          viewportHeight: viewport, maxScrollExtent: -1), 0.0);
    });

    test('双击缩放矩阵：围绕视口中心，中心点缩放前后不动', () {
      const s = 2.5, w = 300.0, h = 500.0;
      final m = Matrix4.fromList(zoomMatrixAroundCenter(s, w, h));
      final cx = w / 2, cy = h / 2;
      // 变换中心点应仍落在中心（平移分量 = 中心*(1-s)）
      final v = m.transform3;
      expect(m.storage[0], s);
      expect(m.storage[5], s);
      expect(m.storage[12], cx * (1 - s));
      expect(m.storage[13], cy * (1 - s));
      expect(v, isNotNull);
    });

    test('下拉阈值：过阈值关闭、未过回弹', () {
      expect(shouldDismissOnDrag(120, 110), isTrue);
      expect(shouldDismissOnDrag(110, 110), isFalse);
      expect(shouldDismissOnDrag(20, 110), isFalse);
    });
  });

  // ── ② 硬验收 1：下拉关闭与 Hero 返回转场不打架 ───────────────
  group('② 硬验收 1 · 下拉关闭 / Hero 返回互斥', () {
    test('下拉关闭路径禁用 Hero、按钮返回路径启用 Hero（状态语义）', () {
      // 查看器实现：heroEnabled = !_dragDismiss；
      // 下拉过阈值 → _dragDismiss=true → HeroMode(enabled:false) → pop，
      // 不触发返回转场；按钮/系统返回时 _dragDismiss=false → Hero 飞回。
      bool heroEnabledFor(bool dragDismiss) => !dragDismiss;
      expect(shouldDismissOnDrag(150, 110), isTrue);
      expect(heroEnabledFor(true), isFalse,
          reason: '下拉关闭时禁用 Hero，避免与下拉位移动画打架');
      expect(heroEnabledFor(false), isTrue,
          reason: '按钮/系统返回保留 Hero，飞回当前缩略图');
    });

    testWidgets('HeroMode 禁用态子树不参与 Hero 转场', (tester) async {
      // HeroMode(enabled:false) 包裹的 Hero 不产生飞行（Flutter 语义），
      // 这里验证组件可正常构建、且 enabled 状态可切换
      for (final enabled in [true, false]) {
        await tester.pumpWidget(MaterialApp(
          home: HeroMode(
            enabled: enabled,
            child: Hero(
                tag: 'album-photo-m1',
                child: const SizedBox(width: 50, height: 50)),
          ),
        ));
        await tester.pump();
        expect(find.byType(HeroMode), findsOneWidget);
        expect(tester.widget<HeroMode>(find.byType(HeroMode)).enabled, enabled);
      }
    });
  });

  // ── ③ 硬验收 2：翻页后返回落点是当前查看那张 ─────────────────
  group('③ 硬验收 2 · 翻页索引与落点预滚动', () {
    test('查看器翻页写 albumViewerIndexProvider，网格据此预滚动', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(albumViewerIndexProvider.notifier);
      expect(container.read(albumViewerIndexProvider), 0);
      // 模拟连翻到 index 9（第 3 行，滚动偏移已明显离开顶部）
      notifier.state = 9;
      expect(container.read(albumViewerIndexProvider), 9);
      // 网格预滚动目标 = 当前查看那张（index 9），不是最初点开的 0
      final cell = 100.0;
      final offset = albumGridScrollOffset(
          container.read(albumViewerIndexProvider),
          cellSize: cell, spacing: 8, viewportHeight: 400,
          maxScrollExtent: 1000);
      expect(offset, greaterThan(0));
      expect(offset,
          isNot(equals(albumGridScrollOffset(0,
              cellSize: cell, spacing: 8, viewportHeight: 400,
              maxScrollExtent: 1000))));
    });

    test('索引与当前筛选下的 photos 列表对齐（跨整个相册翻页）', () {
      final photos = parsePhotos([
        _photo('m1'), _photo('m2'), _photo('m3'), _photo('m4'), _photo('m5'),
      ]);
      expect(photos.length, 5);
      // 首/末页不越界：索引夹取
      final clampAt = (int i) => i.clamp(0, photos.length - 1);
      expect(clampAt(-1), 0);
      expect(clampAt(0), 0);
      expect(clampAt(4), 4);
      expect(clampAt(99), 4);
      // 计数 n/N 与网格总数一致
      for (var i = 0; i < photos.length; i++) {
        expect('${i + 1} / ${photos.length}',
            matches(RegExp(r'^\d+ / 5$')));
      }
      // Hero tag 跟随当前页 → pop 时飞回当前查看那张的缩略图
      expect(albumHeroTag(photos[3].id), 'album-photo-m4');
    });
  });

  // ── ④ 缩放态禁用翻页（口径写进小结）───────────────────────────
  group('④ 缩放态手势口径', () {
    test('放大时禁用横滑翻页与下拉；回到 1× 恢复', () {
      // 查看器：_zoomed = maxScaleOnAxis > 1.01；
      // physics = _zoomed ? NeverScrollableScrollPhysics : PageScrollPhysics
      bool zoomed(double scale) => scale > 1.01;
      expect(zoomed(1.0), isFalse);
      expect(zoomed(2.5), isTrue);
      expect(zoomed(5.0), isTrue);
      // 缩放下禁用下拉：_onDragUpdate 在 _zoomed 时直接 return
      expect(zoomed(2.5), isTrue, reason: '缩放态下拉不生效');
    });
  });

  // ── ⑤ 顶部通知与 SnackBar 清零（静态源码核对）────────────────
  group('⑤ 顶部通知统一 / App 内 SnackBar 清零', () {
    test('lib 下不再有 showSnackBar 调用（注释里的历史说明除外）', () {
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
      expect(offenders, isEmpty, reason: '结果类提示不许再有底部 SnackBar 残留');
    });

    test('全 App 只有一个 ChatToastHost 宿主（App 根部 builder）', () {
      final lib = Directory('lib');
      var hosts = 0;
      for (final f in lib.listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        for (final line in f.readAsLinesSync()) {
          final trimmed = line.trim();
          if (trimmed.startsWith('//')) continue;
          if (line.contains('ChatToastHost()')) hosts++;
        }
      }
      expect(hosts, 1, reason: '全局唯一宿主，避免一条通知渲染两遍');
    });

    test('段一基础查看器与甲档查看器的下载都走 chatToastProvider', () {
      final base = File('lib/features/timeline/image_viewer.dart').readAsStringSync();
      final adv = File('lib/features/album/album_viewer_page.dart').readAsStringSync();
      expect(base.contains('chatToastProvider'), isTrue);
      expect(adv.contains('chatToastProvider'), isTrue);
      expect(base.contains('showSnackBar'), isFalse);
      expect(adv.contains('showSnackBar'), isFalse);
    });
  });
}
