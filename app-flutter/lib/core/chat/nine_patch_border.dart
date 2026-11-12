/// 气泡皮肤九宫格自绘（复验皮肤第二轮修复）。
///
/// Web 契约（static/style.css:2502-2531 实读）：
/// · 源图 128×112 整图，四角画装饰；
/// · border-image-slice: 42 fill——42px 源区切九宫格，中心 fill 填充；
/// · border-image-width: 16px——**角部 42px 源区等比缩小到 16px 目标区**绘制
///   （Flutter centerSlice 只做「源区=目标区」的等比放大，没有 width 缩放语义，
///   这正是「皮肤角饰大了一圈半」的根因——故自绘复刻）；
/// · border-image-repeat: stretch——边带随内容拉伸、中心 fill 拉伸；
/// · 皮肤态内边距 padding: 3px 7px（Web .skinned 实读照抄）；
/// · mine 侧用服务器预翻转的 -r 镜像图（flipX 仅作无镜像素材时的等价渲染）。
///
/// 纯函数 [ninePatchPieces] 可单测（锁定角 42→16 缩放与边带拉伸）。
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 九宫格一片：源矩形（图内）+ 目标矩形（气泡内）
class NinePatchPiece {
  const NinePatchPiece({required this.src, required this.dst});
  final Rect src;
  final Rect dst;

  @override
  bool operator ==(Object other) =>
      other is NinePatchPiece && other.src == src && other.dst == dst;

  @override
  int get hashCode => Object.hash(src, dst);
}

/// 计算 border-image 九宫格的 9 片源/目标矩形。
/// · [imgW]/[imgH] 源图尺寸（Web 素材 128×112）；
/// · [slice] 切片边长（Web 42）；[border] 目标边宽（Web 16）；
/// · [flipX] 源区左右列对调（角饰换边；无 -r 镜像素材时的等价降级渲染，
///   服务器已提供 -r 预翻转图时恒传 false）。
/// 目标盒小于 2×border 时边带 clamp（Web border-image 的重叠语义等价简化）。
List<NinePatchPiece> ninePatchPieces({
  required double imgW,
  required double imgH,
  required double slice,
  required double dstW,
  required double dstH,
  required double border,
  bool flipX = false,
}) {
  final corner = slice; // 源区角边长
  final b = border.clamp(0.0, dstW / 2).clamp(0.0, dstH / 2).toDouble();
  final midSrcW = imgW - corner * 2;
  final midSrcH = imgH - corner * 2;
  final midDstW = dstW - b * 2;
  final midDstH = dstH - b * 2;

  // 源列 x：flipX 时三列左右对调（右列→目标左列、中列不变、左列→目标右列）。
  // drawImageRect 的 src 必须是正向矩形（left<=right），无法做源区反向，
  // 故降级语义明确为「列对调」而非逐像素镜像；服务器 -r 图已做逐像素翻转。
  Rect srcRect(double left, double top, double w, double h) =>
      Rect.fromLTWH(left, top, w, h);

  // 列宽（源）：左 corner、中 midSrcW、右 corner
  // 行高（源）：上 corner、中 midSrcH、下 corner
  // 目标三列：b / midDstW / b；目标三行：b / midDstH / b
  final dstX = [0.0, b, dstW - b];
  final dstWd = [b, midDstW, b];
  final dstY = [0.0, b, dstH - b];
  final dstHt = [b, midDstH, b];
  final srcX = flipX
      ? [corner + midSrcW, corner, 0.0]
      : [0.0, corner, corner + midSrcW];
  final srcWd = [corner, midSrcW, corner];
  final srcY = [0.0, corner, corner + midSrcH];
  final srcHt = [corner, midSrcH, corner];

  final pieces = <NinePatchPiece>[];
  for (var row = 0; row < 3; row++) {
    for (var col = 0; col < 3; col++) {
      // 负尺寸中带（目标盒过小/源图过小）跳过
      if (midDstW <= 0 && col == 1) continue;
      if (midSrcW <= 0 && col == 1) continue;
      if (midDstH <= 0 && row == 1) continue;
      if (midSrcH <= 0 && row == 1) continue;
      pieces.add(NinePatchPiece(
        src: srcRect(srcX[col], srcY[row], srcWd[col], srcHt[row]),
        dst: Rect.fromLTWH(dstX[col], dstY[row], dstWd[col], dstHt[row]),
      ));
    }
  }
  return pieces;
}

/// 皮肤图解码缓存（静态；按 url 复用 ui.Image，超上限 dispose 最旧——
/// painter 持有的是缓存内的 image，不自行 dispose）
class SkinImageCache {
  SkinImageCache._();

  static const _maxEntries = 24;
  // Dart 默认 Map 即 LinkedHashMap（插入顺序），LRU 用 keys.first 取最旧
  static final _images = <String, ui.Image>{};

  /// 取皮肤图（命中缓存直接返回；未命中经 CacheManager 落盘字节解码）
  static Future<ui.Image?> load(
    String url, {
    Map<String, String>? headers,
    required Future<List<int>?> Function(String url, Map<String, String>? headers)
        fetchBytes,
  }) {
    final hit = _images[url];
    if (hit != null) return Future.value(hit);
    return fetchBytes(url, headers).then((bytes) async {
      if (bytes == null || bytes.isEmpty) return null;
      final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
      final frame = await codec.getNextFrame();
      final image = frame.image;
      _images[url] = image;
      // LRU：超上限 dispose 最旧（painter 下一帧重建，按 url 再取）
      while (_images.length > _maxEntries) {
        final oldest = _images.keys.first;
        final old = _images.remove(oldest);
        old?.dispose();
      }
      return image;
    }).catchError((_) => null);
  }
}

/// 皮肤气泡画笔：按 border-image 语义把源图九片绘制到目标盒
/// （角 42→16 等比缩小、边带拉伸、中心 fill 拉伸；medium 滤波防角饰缩小锯齿）
class NinePatchBorderPainter extends CustomPainter {
  NinePatchBorderPainter({
    required this.image,
    required this.slice,
    required this.border,
    this.flipX = false,
    this.repaintToken,
  });

  final ui.Image image;
  final double slice;
  final double border;
  final bool flipX;

  /// 外部信号（如 url 变化导致 image 更新）触发重绘
  final Object? repaintToken;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..filterQuality = FilterQuality.medium;
    for (final p in ninePatchPieces(
        imgW: image.width.toDouble(),
        imgH: image.height.toDouble(),
        slice: slice,
        dstW: size.width,
        dstH: size.height,
        border: border,
        flipX: flipX)) {
      canvas.drawImageRect(image, p.src, p.dst, paint);
    }
  }

  @override
  bool shouldRepaint(covariant NinePatchBorderPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.slice != slice ||
      oldDelegate.border != border ||
      oldDelegate.flipX != flipX ||
      oldDelegate.repaintToken != repaintToken;
}
