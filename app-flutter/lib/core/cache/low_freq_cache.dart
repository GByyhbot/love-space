/// 低频大图本地缓存（复验 5 项 · item 5 新增通则；后续时光/相册同类资源沿用）。
///
/// 适用范围（本段）：头像、聊天背景/壁纸、气泡皮肤图。列表图仍走原策略。
///
/// 键策略（注释即通则，写入 handover）：
/// · **缓存键 = 完整 URL**（flutter_cache_manager 的 file key 默认取 URL）；
///   URL 必须包含服务端版本/更新标识——头像与壁纸 URL 含媒体 mid（资源被替换
///   = 换了 mid = 换了 URL = 新键新文件）；气泡皮肤图文件名即内容（发上去不改，
///   /api/bubbles/<包>/<名> 天然不可变）；
/// · **删除旧缓存只留最新一份**：头像/壁纸这类「单槽位」资源走
///   [LowFreqCache.retainLatest]——新版 URL 下载成功后删除上一版 URL 的缓存
///   文件（上一版记录在本组件内，随槽位保存）；气泡这类海量静态图走
///   LRU 上限（maxNrOfCacheObjects）自然淘汰；
/// · 服务端 /media/ 下发 `Cache-Control: private, max-age=0, must-revalidate`
///   （main.py:300-313 实读）——HTTP 层不缓存，必须由本 CacheManager
///   强制落盘（stalePeriod 长设 365 天），禁止每次进页重复拉图。
library;

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 低频资源专用 CacheManager：长 stalePeriod + LRU 上限（bubbles 海量图）。
/// 与 cached_network_image 默认的 DefaultCacheManager（30 天/200 张）隔离，
/// 避免聊天低频大图挤掉其它页面的缓存。
class LowFreqCacheManager extends CacheManager with ImageCacheManager {
  static const _cacheKey = 'lowFreqChat';

  LowFreqCacheManager._()
      : super(Config(
          _cacheKey,
          stalePeriod: const Duration(days: 365), // 长设：文件名即内容，基本不失效
          maxNrOfCacheObjects: 2000, // LRU 上限：bubbles 两千+张封顶后按最近使用淘汰
          repo: JsonCacheInfoRepository(databaseName: _cacheKey),
        ));

  static final LowFreqCacheManager instance = LowFreqCacheManager._();
}

/// 槽位化「删旧留新」
class LowFreqCache {
  LowFreqCache._();

  static const _retentionKeyPrefix = 'lowfreq_retain_';
  static final Map<String, String?> _lastUrlBySlot = {};
  static final FlutterSecureStorage _storage = const FlutterSecureStorage();

  /// 单槽位资源（头像/壁纸）的缓存键推导：URL 含 mid/更新标识，
  /// 资源变了 URL 变 → 键变（测试锁定此约定）
  static String keyOf(String url) => url;

  /// 记录槽位当前 URL（供 retainLatest 比对）
  static String? lastUrlOf(String slot) => _lastUrlBySlot[slot];

  /// 预取并落盘；若槽位上一版 URL 与本次不同（资源被替换），
  /// 新图成功落盘后删除旧缓存文件——只留最新一份。
  /// 返回是否发起了新下载（同 URL 命中本地缓存时为 false）。
  /// [manager]/[previousLookup]/[previousSaver] 供单测注入替身。
  static Future<bool> retainLatest(
    String slot,
    String url, {
    Map<String, String>? headers,
    CacheManager? manager,
    Future<String?> Function(String slot)? previousLookup,
    Future<void> Function(String slot, String url)? previousSaver,
  }) async {
    if (url.isEmpty) return false;
    final lookup = previousLookup ??
        (slot) async => _lastUrlBySlot[slot] ??
            await _storage.read(key: '$_retentionKeyPrefix$slot');
    final saver = previousSaver ??
        (slot, url) async {
          _lastUrlBySlot[slot] = url;
          await _storage.write(key: '$_retentionKeyPrefix$slot', value: url);
        };
    final mgr = manager ?? LowFreqCacheManager.instance;

    final previous = await lookup(slot);
    if (previous == url) return false; // 命中本地缓存，不重复拉
    await mgr.downloadFile(url, authHeaders: headers, key: keyOf(url));
    await saver(slot, url);
    // 新图落盘成功 → 删旧缓存只留最新一份
    if (previous != null && previous != url) {
      try {
        await mgr.removeFile(keyOf(previous));
      } catch (_) {
        // 旧文件已不存在等场景静默
      }
    }
    return true;
  }
}

/// 低频缓存管理器 Provider（页面/组件统一取此实例）
final lowFreqCacheManagerProvider =
    Provider<LowFreqCacheManager>((_) => LowFreqCacheManager.instance);
