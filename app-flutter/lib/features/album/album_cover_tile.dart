/// 相册封面图（条目 5 · 段 C · 方案③）：
/// 走 LowFreqCache 单槽位（retainLatest 删旧留新）——封面一旦更换，旧封面
/// 缓存文件自动回收，只留最新一份；其余低频资源（头像/壁纸）同款机制。
/// [coverMid] 为空 → 不发起网络请求，直接渲染 [placeholder]（无封面回退）。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/low_freq_cache.dart';
import '../../core/chat/chat_media.dart';

class AlbumCoverTile extends ConsumerStatefulWidget {
  const AlbumCoverTile({
    super.key,
    required this.base,
    required this.headers,
    required this.coverMid,
    required this.slot, // 单槽位标识（建议 'album_cover_$id'）
    required this.placeholder,
    this.borderRadius = 12,
  });
  final String base;
  final Map<String, String>? headers;
  final String coverMid;
  final String slot;
  final Widget placeholder;
  final double borderRadius;

  @override
  ConsumerState<AlbumCoverTile> createState() => _AlbumCoverTileState();
}

class _AlbumCoverTileState extends ConsumerState<AlbumCoverTile> {
  @override
  void initState() {
    super.initState();
    _prime();
  }

  @override
  void didUpdateWidget(covariant AlbumCoverTile old) {
    super.didUpdateWidget(old);
    if (old.coverMid != widget.coverMid || old.base != widget.base) _prime();
  }

  /// 单槽位低频缓存：下载新封面并删除上一版（换封面时旧图自动回收）。
  /// 同 URL 命中本地缓存时 retainLatest 直接返回、不再重复拉。
  void _prime() {
    final mid = widget.coverMid;
    if (mid.isEmpty || widget.base.isEmpty) return;
    Future.microtask(() => LowFreqCache.retainLatest(
          widget.slot,
          mediaUrl(widget.base, mid),
          headers: widget.headers,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final mid = widget.coverMid;
    if (mid.isEmpty || widget.base.isEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: widget.placeholder,
      );
    }
    final url = mediaUrl(widget.base, mid);
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: CachedNetworkImage(
        cacheManager: LowFreqCacheManager.instance, // 单槽位低频缓存（与 retainLatest 同管理器/同键）
        imageUrl: url,
        httpHeaders: widget.headers,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        fadeInDuration: const Duration(milliseconds: 220),
        placeholder: (_, _) => widget.placeholder,
        errorWidget: (_, _, _) => widget.placeholder,
      ),
    );
  }
}
