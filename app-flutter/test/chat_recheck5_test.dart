/* 复验 5 项新增单测：
   ① 键盘高度持久化与槽位等高推导（slotHeightFor 恒等式矩阵 + insetsStable
      + KeyboardMetricsStore 内存实现往返）
   ② 缓存键策略（keyOf=url 约定：URL 含 mid/更新标识，资源变了键才变）
   ③ 低频缓存删旧留新（retainLatest：同 URL 命中不重复拉 / 新 URL 下载并删旧 /
      空槽位首次只下载不删） */
import 'dart:io';

import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/cache/low_freq_cache.dart';
import 'package:love_space/core/chat/keyboard_metrics.dart';

/// 假 CacheManager：只记录 download/remove 调用
class _FakeManager implements CacheManager {
  final downloaded = <String>[];
  final removed = <String>[];

  @override
  Future<FileInfo> downloadFile(String url,
      {Map<String, String>? authHeaders, bool force = false, String? key}) async {
    downloaded.add(key ?? url);
    return FileInfo(
      const LocalFileSystem().file('${Directory.systemTemp.path}/fake'),
      FileSource.Online,
      DateTime.now().add(const Duration(days: 1)),
      key ?? url,
    );
  }

  @override
  Future<void> removeFile(String key, {bool ignoreMisses = false}) async {
    removed.add(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 内存持久化实现（与 SecureKeyboardMetricsStore 共享同一抽象契约）
class _MemKeyboardStore implements KeyboardMetricsStore {
  _MemKeyboardStore(this._map);
  final Map<String, String> _map;

  @override
  Future<void> save(double height) async => _map['kb'] = height.toString();

  @override
  Future<double?> load() async {
    final v = _map['kb'];
    if (v == null) return null;
    final parsed = double.tryParse(v);
    if (parsed == null || parsed < minKeyboardInsets) return null;
    return parsed;
  }
}

void main() {
  // ── ① 槽位等高推导与键盘高度持久化 ────────────────────────────────
  group('① slotHeightFor 恒等式与持久化', () {
    const kbHeight = 280.0;

    test('槽位未开 → 0（底部总高=insets=键盘）', () {
      expect(slotHeightFor(slotOpen: false, insets: 0, kbHeight: kbHeight), 0);
      expect(
          slotHeightFor(
              slotOpen: false, insets: kbHeight, kbHeight: kbHeight),
          0);
    });

    test('槽位开：insets 全区间内 slotHeight + insets 恒等于 kbHeight（高度恒定论证）',
        () {
      // 键盘↔面板两两切换的整个过渡区间逐点验证
      for (var insets = 0.0; insets <= kbHeight + 40; insets += 10) {
        final slot = slotHeightFor(
            slotOpen: true, insets: insets, kbHeight: kbHeight);
        if (insets <= kbHeight) {
          expect(slot + insets, kbHeight,
              reason: 'insets=$insets 时输入栏位置应逐帧不动');
        } else {
          // 实测键盘高于记忆值（换输入法等）：槽位夹 0，总高=insets，输入栏
          // 位置随实际键盘走（下一轮实测自动纠正）
          expect(slot, 0);
        }
      }
    });

    test('键盘全收（insets=0）槽位=kbHeight；从零展开才有抬升动画空间', () {
      expect(slotHeightFor(slotOpen: true, insets: 0, kbHeight: kbHeight),
          kbHeight);
    });

    test('insetsStable：连续两帧相同且超门槛才落定（过滤手势条/抖动）', () {
      expect(insetsStable(280, 280), true);
      expect(insetsStable(280, 281), false); // 抖动 1px
      expect(insetsStable(280, 200), false); // 尚在过渡
      expect(insetsStable(30, 30), false); // 手势条高度不足键盘门槛
      expect(insetsStable(-1, 280), false); // 首帧无前值
    });

    test('KeyboardMetricsStore 内存实现往返（持久化契约）', () async {
      final store = _MemKeyboardStore({});
      expect(await store.load(), isNull);
      await store.save(278.0);
      expect(await store.load(), 278.0);
      await store.save(312.5);
      expect(await store.load(), 312.5);
    });
  });

  // ── ② 缓存键策略 ──────────────────────────────────────────────────
  group('② 低频缓存键策略（URL 含版本/更新标识）', () {
    test('头像：URL 含 mid → 换头像即换键', () {
      final old = LowFreqCache.keyOf('https://x/media/aaaa?preview=true');
      final afterChange = LowFreqCache.keyOf('https://x/media/bbbb?preview=true');
      expect(old != afterChange, true);
    });

    test('壁纸：URL 含 chat_bg_media 的 mid → 换图即换键', () {
      expect(LowFreqCache.keyOf('https://x/media/w1?preview=true'),
          'https://x/media/w1?preview=true');
    });

    test('皮肤图：/api/bubbles/<包>/<名> 文件名即内容（不可变 URL 稳定键）', () {
      expect(LowFreqCache.keyOf('https://x/api/bubbles/p1/a.png'),
          'https://x/api/bubbles/p1/a.png');
    });
  });

  // ── ③ 低频缓存删旧留新 ────────────────────────────────────────────
  test('③ retainLatest：同 URL 命中本地缓存 → 不重复拉', () async {
    final manager = _FakeManager();
    final saved = <String, String>{};
    Future<bool> call(String mid) => LowFreqCache.retainLatest(
        'avatar:u1', 'https://x/media/$mid?preview=true',
        manager: manager,
        previousLookup: (s) async => saved[s],
        previousSaver: (s, u) async => saved[s] = u);

    expect(await call('a'), true);
    expect(await call('a'), false); // 命中
    expect(manager.downloaded, hasLength(1));
    expect(manager.removed, isEmpty);
  });

  test('③ retainLatest：换图（新 mid）→ 新键下载 + 删旧缓存只留最新一份', () async {
    final manager = _FakeManager();
    final saved = <String, String>{};
    Future<bool> call(String mid) => LowFreqCache.retainLatest(
        'wallpaper:u1', 'https://x/media/$mid?preview=true',
        manager: manager,
        previousLookup: (s) async => saved[s],
        previousSaver: (s, u) async => saved[s] = u);

    expect(await call('w1'), true);
    expect(manager.downloaded, ['https://x/media/w1?preview=true']);
    expect(manager.removed, isEmpty); // 首次无旧图

    expect(await call('w2'), true);
    expect(manager.downloaded.last, 'https://x/media/w2?preview=true');
    expect(manager.removed, ['https://x/media/w1?preview=true']); // 删旧留新
  });

  test('③ retainLatest：空 URL 直接跳过', () async {
    final manager = _FakeManager();
    final r = await LowFreqCache.retainLatest('s', '',
        manager: manager,
        previousLookup: (_) async => null,
        previousSaver: (_, _) async {});
    expect(r, false);
    expect(manager.downloaded, isEmpty);
  });
}
