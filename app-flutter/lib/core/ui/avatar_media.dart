/// 2.3.7 统一头像组件：顶栏 / 心情格 / 动态卡等所有头像统一走
/// 「LowFreqCache 低频缓存 + mediaCookieHeaders 鉴权头」这一条路径
/// （与动态图/相册封面同鉴权与缓存机制；此前顶栏/心情格只有字母、
/// 根本没有照片渲染代码——根因见 2.3.7 小结）。
///
/// 缓存键 = 完整 URL（URL 含媒体 mid：换头像 = mid 变 = URL 变 = 新键）；
/// [LowFreqCache.retainLatest] 在新头像落盘后删除上一版缓存只留最新一份
/// ——「media id 变化才重新拉取，否则命中本地缓存」。
/// 加载失败 / avatarId 为空回退现行字母口径（用户名首字，'?' 兜底）。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cache/low_freq_cache.dart';
import '../chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider, mediaUrl;

class AvatarMedia extends ConsumerStatefulWidget {
  const AvatarMedia({
    super.key,
    required this.avatarId,
    required this.name,
    this.radius = 14,
    this.slotPrefix = 'avatar',
  });

  /// 头像媒体 id（users.avatar；空串 = 没设置，回退字母）
  final String avatarId;

  /// 字母兜底用的昵称
  final String name;

  /// 圆形半径（直径 = radius * 2）
  final double radius;

  /// 低频缓存槽位前缀（按用户分槽：'avatar:userId'）
  final String slotPrefix;

  @override
  ConsumerState<AvatarMedia> createState() => _AvatarMediaState();
}

class _AvatarMediaState extends ConsumerState<AvatarMedia> {
  @override
  void initState() {
    super.initState();
    _prime();
  }

  @override
  void didUpdateWidget(covariant AvatarMedia old) {
    super.didUpdateWidget(old);
    if (old.avatarId != widget.avatarId) _prime();
  }

  /// 单槽位预取：换头像（mid 变）时新图落盘并删上一版缓存；
  /// 同 URL 命中本地缓存时 retainLatest 直接返回，不再重复拉。
  void _prime() {
    final base = ref.read(chatBaseProvider).valueOrNull;
    final headers = ref.read(mediaCookieHeadersProvider).valueOrNull;
    final id = widget.avatarId;
    if (id.isEmpty || base == null || base.isEmpty) return;
    Future.microtask(() => LowFreqCache.retainLatest(
          '${widget.slotPrefix}:${id.isEmpty ? '_' : id}',
          mediaUrl(base, id),
          headers: headers,
        ));
  }

  Widget _fallback() {
    final cs = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: cs.primaryContainer,
      child: Text(
        widget.name.isEmpty ? '?' : widget.name.characters.first,
        style: TextStyle(
          fontSize: widget.radius * 0.82,
          color: cs.onPrimaryContainer,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final id = widget.avatarId;
    if (id.isEmpty) return _fallback();
    final base = ref.watch(chatBaseProvider).valueOrNull;
    final headers = ref.watch(mediaCookieHeadersProvider).valueOrNull;
    if (base == null || base.isEmpty) return _fallback();
    return ClipOval(
      child: SizedBox(
        width: widget.radius * 2,
        height: widget.radius * 2,
        child: CachedNetworkImage(
          imageUrl: mediaUrl(base, id),
          httpHeaders: headers, // 与动态图/相册同一路径：会话 Cookie 头
          cacheManager: LowFreqCacheManager.instance, // 低频缓存强制落盘
          width: widget.radius * 2,
          height: widget.radius * 2,
          fit: BoxFit.cover,
          placeholder: (_, _) => CircleAvatar(
            radius: widget.radius,
            backgroundColor: cs.primaryContainer,
          ),
          errorWidget: (_, _, _) => _fallback(),
        ),
      ),
    );
  }
}
