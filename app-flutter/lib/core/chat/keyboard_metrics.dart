/// 键盘高度实测与槽位等高推导（复验 5 项 · item 2 核心，纯逻辑可单测）。
///
/// 规则（主人定版）：
/// · 键盘高度**实测并持久化**——viewInsets.bottom 落定（连续帧稳定）后记录，
///   本地持久化，下次启动直接用；不写死、不估算；
/// · ⊕面板与贴纸坞高度一律等于该实测键盘高度；
/// · **高度恒定论证**：键盘/面板/坞任一激活时，输入栏底部偏移 =
///   slotHeight + insets。slotHeightFor 在面板态返回 (kbHeight - insets).clamp(0, kbHeight)，
///   键盘态返回 0——两种状态下均有 slotHeight + insets == kbHeight（0 ≤ insets ≤ kbHeight
///   的整个过渡区间内恒等成立），故两两切换时输入栏位置逐帧不动、底部总高度恒定；
/// · 从零展开（键盘关 → 面板开，insets==0）才走抬升动画（槽位 0 → kbHeight）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 无实测值前的兜底高度（旧版估算值；首次键盘弹出后自动纠正并覆盖）
const double fallbackKeyboardHeight = 300.0;

/// 视为「键盘」的最小 insets（过滤手势条等微小 padding）
const double minKeyboardInsets = 60.0;

/// 槽位高度推导（纯函数）：
/// · 槽位未开 → 0（键盘态时底部总高 = insets = 键盘）；
/// · 槽位开 → (kbHeight - insets).clamp(0, kbHeight)——键盘收起过渡期间
///   槽位等量补位（总高恒定 kbHeight），键盘全收后槽位 = kbHeight。
double slotHeightFor({
  required bool slotOpen,
  required double insets,
  required double kbHeight,
}) {
  if (!slotOpen) return 0;
  return (kbHeight - insets).clamp(0.0, kbHeight);
}

/// insets 是否「落定」（连续两帧相同且达到键盘门槛）
bool insetsStable(double previous, double current) =>
    previous > minKeyboardInsets &&
    (previous - current).abs() < 0.5 &&
    current > minKeyboardInsets;

/// 持久化抽象（默认 secure_storage；单测换内存实现）
abstract class KeyboardMetricsStore {
  Future<void> save(double height);
  Future<double?> load();
}

class SecureKeyboardMetricsStore implements KeyboardMetricsStore {
  static const _key = 'kb_height_logical';
  final FlutterSecureStorage _storage;

  SecureKeyboardMetricsStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<void> save(double height) =>
      _storage.write(key: _key, value: height.toString());

  @override
  Future<double?> load() async {
    final v = await _storage.read(key: _key);
    if (v == null) return null;
    final parsed = double.tryParse(v);
    if (parsed == null || parsed < minKeyboardInsets) return null;
    return parsed;
  }
}

final keyboardMetricsStoreProvider =
    Provider<KeyboardMetricsStore>((_) => SecureKeyboardMetricsStore());
