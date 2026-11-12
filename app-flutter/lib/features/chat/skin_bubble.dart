/// 皮肤气泡组件（复验皮肤第二轮：自绘九宫格复刻 Web border-image 语义）。
/// 预览行与实际气泡共用本组件，保证「预览=实际」。
/// 内边距/字色对照 Web .chat-panel.skin-on .chat-bubble 实读：padding 3px 7px、
/// 深字 #2B2029 / 浅字 #fff + 极淡投影；引用块等子元素底色由调用方按皮肤态给。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/low_freq_cache.dart';
import '../../core/chat/chat_media.dart';
import '../../core/chat/nine_patch_border.dart';

/// 皮肤态字色（Web .skinned / .skinned.light 实读写死，不随主题变化）：
/// `color:#2B2029`；浅色字 `color:#fff; text-shadow:0 1px 3px rgba(0,0,0,.32)`。
const Color skinDarkFg = Color(0xFF2B2029);
const Color skinLightFg = Color(0xFFFFFFFF);

/// rgba(0,0,0,.32) → alpha 0x52；Web 的 0 1px 3px 极淡投影
const List<Shadow> skinLightShadows = <Shadow>[
  Shadow(offset: Offset(0, 1), blurRadius: 3, color: Color(0x52000000)),
];

/// 皮肤态正文样式（纯函数，可单测锁定字色与投影）
TextStyle skinTextStyle(TextStyle? base, {required bool fgLight}) =>
    (base ?? const TextStyle()).copyWith(
      color: fgLight ? skinLightFg : skinDarkFg,
      shadows: fgLight ? skinLightShadows : const <Shadow>[],
    );

/// CSS 盒模型下的气泡内边距（纯函数，可单测）。
///
/// Web `static/style.css:2517-2531`：
/// `border-width:16px` + `border-image-width:16px` + `padding:3px 7px`。
/// 这 16px 边框在 CSS 里**占布局空间**，气泡 border-box =
/// 内容 + 2×padding(3/7) + 2×border(16)；九宫格的角/边带就画在这圈边框上，
/// 文字只能待在中心 fill 区。
///
/// 只给 `padding(7,3)` 时 painter 会把「内容+padding」当成整个 border-box，
/// 上下各 16px 边带直接压在文字上：单行文本目标盒仅 20 余 px 高，
/// 中心区被夹到接近 0，表现为气泡扁成一条横带、换行文字溢出（真机复验缺陷）。
EdgeInsets skinBubblePadding(double border) => EdgeInsets.symmetric(
      horizontal: 7 + border,
      vertical: 3 + border,
    );

/// 皮肤九宫格气泡：url 为皮肤图完整地址（含 -r 镜像选择），
/// [fgLight] 浅色字（Web skin-light：白字+淡投影），深字 #2B2029。
class SkinBubble extends ConsumerStatefulWidget {
  const SkinBubble({
    super.key,
    required this.url,
    required this.child,
    this.fgLight = false,
    this.slice = 42,
    this.border = 16,
  });

  final String url;
  final Widget child;
  final bool fgLight;
  final double slice;
  final double border;

  @override
  ConsumerState<SkinBubble> createState() => _SkinBubbleState();
}

class _SkinBubbleState extends ConsumerState<SkinBubble> {
  Future<ui.Image?>? _loader;
  String? _loadedUrl;

  @override
  void didUpdateWidget(SkinBubble old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _loader = null;
  }

  /// 皮肤图字节：LowFreqCacheManager 落盘链（365 天 stalePeriod）→ 解码
  Future<List<int>?> _fetchBytes(
      String url, Map<String, String>? headers) async {
    try {
      final file = await LowFreqCacheManager.instance
          .getSingleFile(url, headers: headers);
      final bytes = await file.readAsBytes();
      return Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<ui.Image?> _ensureImage() async {
    final headers = ref.watch(mediaCookieHeadersProvider).valueOrNull;
    if (_loader == null || _loadedUrl != widget.url) {
      _loadedUrl = widget.url;
      _loader = SkinImageCache.load(widget.url,
          headers: headers, fetchBytes: _fetchBytes);
    }
    return _loader;
  }

  /// 字色跟随气泡图（Web .skinned 写死 #2B2029；.skinned.light 白字+淡投影）。
  /// 用 DefaultTextStyle 下发，子层显式 style 仍可覆盖（实际气泡的正文样式）。
  Widget _styledChild(ThemeData theme) => DefaultTextStyle.merge(
        style: skinTextStyle(theme.textTheme.bodyMedium,
            fgLight: widget.fgLight),
        child: widget.child,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<ui.Image?>(
      future: _ensureImage(),
      builder: (context, snap) {
        final image = snap.data;
        // 成功/回退必须用同一套尺寸，否则皮肤图解码完成瞬间气泡会跳一下。
        final padding = skinBubblePadding(widget.border);
        if (image == null) {
          // 未解码/解码失败：回退半透明底（不发请求风暴，URL 不变不再拉）
          return Container(
            padding: padding,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(16),
            ),
            child: _styledChild(theme),
          );
        }
        return CustomPaint(
          painter: NinePatchBorderPainter(
            image: image,
            slice: widget.slice,
            border: widget.border,
          ),
          child: Padding(
            padding: padding,
            child: _styledChild(theme),
          ),
        );
      },
    );
  }
}
