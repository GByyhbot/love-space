/// 设置页状态层（条目 8 · 段 D）：主题目录 / 本机偏好 / 空间全量 merge /
/// 线路探测 / 版本状态。纯 Dart + Riverpod，可单测。
///
/// 🔴 **防抹除（主人特别强调，`main.py:849` 实读）**：服务端 `data = body.model_dump()`
/// 后只对 `chat_bg*` / `chat_bubble*` / `chat_bg_users` / `cover_pos` 做 `None`
/// 回退（`main.py:876-901`）；**`name` / `since` / `cover` / `theme` /
/// `custom_color` / `motion` / `timezone` 不回退**。故客户端 `PUT /api/space`
/// 必须**先拿完整 space 作底**（`/api/me` 或 `me.spaceRaw`），只在副本上盖
/// 改动字段后**全量提交**（等价 Web `{...s, ...}` `:1937`/`:1951`）。
/// [mergeSpace] 是唯一入口，绝不发 `{theme:...}` / `{cover:...}` 这种部分体。
library;

import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/config.dart';

// ── 主题目录（`app.js:98-99` / `:103-113` / `:1876` / `main.py:815`） ──

/// Web `DARK_KEY` / `FONT_KEY`（本机 localStorage 等价 SharedPreferences key）。
const String darkPrefKey = 'love-dark-mode';
const String fontPrefKey = 'love-font-scale';

/// Web `THEME_IDS :103` 七套 + `custom`（`themeForm :1876` 的 `ALL`）。
const List<String> themeIds = <String>[
  'rose',
  'peach',
  'lemon',
  'mint',
  'sky',
  'lavender',
  'cocoa',
  'custom',
];

/// 后端 `SPACE_THEMES main.py:815` 同七套 + `custom`。
const Set<String> serverThemeIds = <String>{
  'rose',
  'peach',
  'lemon',
  'mint',
  'sky',
  'lavender',
  'cocoa',
  'custom',
};

/// Web `CUSTOM_FALLBACK :113`。
const String customColorFallback = '#9A6B5A';

/// Web `THEME_META :104-112`（名称/描述/明暗三色块，逐字）。
const Map<String, List<String>> themeMeta = <String, List<String>>{
  'rose': <String>['草莓牛奶', '莓果粉，最经典的那一版', '#953753', '#DA8BA3'],
  'peach': <String>['蜜桃奶油', '暖橘调，傍晚的光', '#975935', '#DCA789'],
  'lemon': <String>['柠檬挞', '一点酸甜的黄油色', '#936E2F', '#DFBE86'],
  'mint': <String>['薄荷气泡', '清透的青绿', '#3A826D', '#91D4C0'],
  'sky': <String>['海盐汽水', '安稳的雾蓝', '#396993', '#8CB5D9'],
  'lavender': <String>['香芋云朵', '软软的薰衣草', '#644389', '#B094D1'],
  'cocoa': <String>['焦糖可可', '低饱和的暖棕，安静耐看', '#7C5D50', '#C8AA9D'],
};

/// `main.py:827-830` custom 需 `#RRGGBB`。
bool isValidCustomColor(String v) => RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(v);

/// 主题色 → seedColor（light 取 `THEME_META.light[0]`，dark 取 `dark[0]`；
/// custom 用自定义色，非法回落 `#9A6B5A`）。
Color themeSeedColor(String theme, String customColor, {bool dark = false}) {
  String hex;
  if (theme == 'custom') {
    hex = isValidCustomColor(customColor) ? customColor : customColorFallback;
  } else {
    final meta = themeMeta[theme] ?? themeMeta['rose']!;
    hex = dark ? meta[3] : meta[2];
  }
  return Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));
}

/// `themeForm :1872` 当前主题回落：合法 id → 原样；否则 rose。
String normalizedTheme(String raw) => themeIds.contains(raw) ? raw : 'rose';

/// `applyDarkMode() :176-179` 的 App 等价：`auto` → 跟随系统。
ThemeMode themeModeOf(String pref) => switch (pref) {
  'on' => ThemeMode.dark,
  'off' => ThemeMode.light,
  _ => ThemeMode.system,
};

/// `applyFontScale() :124-127` + `style.css:202-203` 的 `--fs-scale`。
double fontScaleOf(String pref) => switch (pref) {
  'large' => 1.08,
  'xl' => 1.16,
  _ => 1.0,
};

/// `themeForm :1903` 说明文案（逐字）。
const String themeFormNote =
    '夜间模式与字号只记在这台设备上，只影响你自己看到的界面；主题配色是两个人共用的。'
    '选中的配色会立刻套用，取消即还原。';

// ── 🔴 空间全量 merge（防抹除唯一入口） ─────────────────────────────

/// `{...spaceRaw, ...changes}`：以 `GET /api/me` 返回的**完整 space** 为底，
/// 只盖改动字段，返回**全量** PUT body。等价 Web `put('/space',{...s,...})`。
///
/// 绝不允许调用方直接构造 `{theme:...}` / `{cover:...}` 的部分体：
/// `main.py:849` 的 `model_dump()` 会把没带的 `name/since/cover/theme/
/// custom_color/motion/timezone` 落空，抹掉空间名 / 相恋日期 / 聊天背景 / 气泡。
Map<String, dynamic> mergeSpace(
  Map<String, dynamic> spaceRaw,
  Map<String, dynamic> changes,
) => <String, dynamic>{...spaceRaw, ...changes};

/// 主题与外观改动（`:1937`）：`theme` / `custom_color` / `motion` 是空间级。
Map<String, dynamic> themeSpaceChanges({
  required String theme,
  required String customColor,
  required bool motion,
}) => <String, dynamic>{
  'theme': theme,
  'custom_color': theme == 'custom' ? customColor : '',
  'motion': motion,
};

/// 主页背景改动（`:1951`）：`cover` + `cover_pos`（默认 `{x:50,y:50,z:1}`）。
Map<String, dynamic> coverSpaceChanges({
  required String cover,
  Object? coverPos,
}) => <String, dynamic>{
  'cover': cover,
  'cover_pos': coverPos ?? <String, dynamic>{'x': 50, 'y': 50, 'z': 1},
};

/// 空间级字段（服务端**不做 None 回退**，必须逐字段带回）。
const List<String> spaceNonFallbackKeys = <String>[
  'name',
  'since',
  'cover',
  'theme',
  'custom_color',
  'motion',
  'timezone',
];

/// 逐字段比对（验收点③断言用）：除了 [changedKeys]，其它字段 PUT 前后全等。
Map<String, Object?> spaceFieldDiff(
  Map<String, dynamic> before,
  Map<String, dynamic> after,
  Set<String> changedKeys,
) {
  final out = <String, Object?>{};
  final keys = <String>{...before.keys, ...after.keys};
  for (final k in keys) {
    if (changedKeys.contains(k)) continue;
    final a = before[k];
    final b = after[k];
    if (a is Map && b is Map) {
      if (_jsonEqual(a, b)) continue;
    } else if (a is List && b is List) {
      if (_jsonEqual(a, b)) continue;
    } else if (a == b) {
      continue;
    }
    out[k] = <String, Object?>{'before': a, 'after': b};
  }
  return out;
}

bool _jsonEqual(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_jsonEqual(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEqual(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

// ── 本机偏好（SharedPreferences，等价于 Web localStorage） ───────────

/// 本机持久化读取（Web `localStorage.getItem(DARK_KEY)||'auto'` 等价）。
class LocalAppearancePrefs {
  const LocalAppearancePrefs({this.dark = 'auto', this.font = 'std'});

  final String dark;
  final String font;

  LocalAppearancePrefs copyWith({String? dark, String? font}) =>
      LocalAppearancePrefs(dark: dark ?? this.dark, font: font ?? this.font);
}

/// 读本机偏好（重启保留）；测试用 `SharedPreferences.setMockInitialValues`。
Future<LocalAppearancePrefs> readLocalPrefs() async {
  final p = await SharedPreferences.getInstance();
  return LocalAppearancePrefs(
    dark: p.getString(darkPrefKey) ?? 'auto',
    font: p.getString(fontPrefKey) ?? 'std',
  );
}

/// 写本机偏好（`themeForm :1933-1934` 等价，只写本机、不进 PUT body）。
Future<void> writeLocalPrefs({
  required String dark,
  required String font,
}) async {
  final p = await SharedPreferences.getInstance();
  await p.setString(darkPrefKey, dark);
  await p.setString(fontPrefKey, font);
}

/// Riverpod 驱动：本地偏好（MaterialApp 重建的触发源之一）。
class AppearancePrefsNotifier extends Notifier<LocalAppearancePrefs> {
  bool _loaded = false;

  @override
  LocalAppearancePrefs build() {
    _loaded = false;
    Future.microtask(_load);
    return const LocalAppearancePrefs();
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final v = await readLocalPrefs();
    if (state != v) state = v;
  }

  /// 就地预览（`themeForm :1879-1885` / `:1917-1923` 等价）。
  void preview({String? dark, String? font}) =>
      state = state.copyWith(dark: dark, font: font);

  /// 保存：先落本机，再更新 Riverpod（不写服务端）。
  Future<void> save({required String dark, required String font}) async {
    await writeLocalPrefs(dark: dark, font: font);
    state = LocalAppearancePrefs(dark: dark, font: font);
  }

  /// 取消还原（`:1906` cleanup 等价）。
  Future<void> cancel(String oldDark, String oldFont) async {
    await writeLocalPrefs(dark: oldDark, font: oldFont);
    state = LocalAppearancePrefs(dark: oldDark, font: oldFont);
  }
}

final appearancePrefsProvider =
    NotifierProvider<AppearancePrefsNotifier, LocalAppearancePrefs>(
      AppearancePrefsNotifier.new,
    );

/// 「空间信息」跳转入口的意图标志（`home_page.dart` 的 `_Hero` 消费后打开
/// 已有的空间信息编辑弹层；设置页与 hub 卡都只置位，不复制该弹层 UI）。
final spaceEditRequestedProvider = StateProvider<bool>((ref) => false);

// ── 空间外观状态（Riverpod 驱动 MaterialApp 立刻重建） ───────────────

/// 空间外观（来自 `/api/me` 的 space，主题色/预览色/动效）。
class SpaceAppearance {
  const SpaceAppearance({
    this.theme = 'rose',
    this.customColor = '',
    this.motion = true,
    this.previewTheme,
    this.previewCustomColor,
    this.previewMotion,
  });

  final String theme;
  final String customColor;
  final bool motion;

  /// 就地预览值（非 null 时覆盖实际值，取消时清空）。
  final String? previewTheme;
  final String? previewCustomColor;
  final bool? previewMotion;

  String get effectiveTheme => previewTheme ?? theme;
  String get effectiveCustomColor => previewCustomColor ?? customColor;
  bool get effectiveMotion => previewMotion ?? motion;

  SpaceAppearance copyWith({
    String? theme,
    String? customColor,
    bool? motion,
    String? previewTheme,
    String? previewCustomColor,
    bool? previewMotion,
    bool clearPreview = false,
  }) => SpaceAppearance(
    theme: theme ?? this.theme,
    customColor: customColor ?? this.customColor,
    motion: motion ?? this.motion,
    previewTheme: clearPreview ? null : (previewTheme ?? this.previewTheme),
    previewCustomColor: clearPreview
        ? null
        : (previewCustomColor ?? this.previewCustomColor),
    previewMotion: clearPreview ? null : (previewMotion ?? this.previewMotion),
  );

  static SpaceAppearance fromSpace(Map<String, dynamic> s) => SpaceAppearance(
    theme: normalizedTheme((s['theme'] ?? 'rose').toString()),
    customColor: (s['custom_color'] ?? '').toString(),
    motion: s['motion'] != false,
  );
}

/// 空间外观 Notifier：`/api/me` 播种 + 保存后立刻生效 + 就地预览/取消还原。
class SpaceAppearanceNotifier extends Notifier<SpaceAppearance> {
  @override
  SpaceAppearance build() => const SpaceAppearance();

  /// `/api/me` 返回后播种（auth bootstrap / reload 调）。
  void seed(Map<String, dynamic> spaceRaw) {
    state = SpaceAppearance.fromSpace(spaceRaw);
  }

  /// 就地预览（`:1879-1885`）：只改内存，MaterialApp 立刻重建。
  void preview({
    required String theme,
    required String customColor,
    required bool motion,
  }) => state = state.copyWith(
    previewTheme: theme,
    previewCustomColor: customColor,
    previewMotion: motion,
  );

  /// 取消还原（`:1906`）：清预览，回到空间当前值。
  void cancel() => state = state.copyWith(clearPreview: true);

  /// 保存成功后提交（预览转正，仍由 `me.reload()` 再播种一次）。
  void commit(Map<String, dynamic> mergedSpace) {
    state = SpaceAppearance.fromSpace(mergedSpace);
  }
}

final spaceAppearanceProvider =
    NotifierProvider<SpaceAppearanceNotifier, SpaceAppearance>(
      SpaceAppearanceNotifier.new,
    );

/// 主题色 seed（供 `main.dart` 生成 light/dark `ThemeData`）。
final themeSeedProvider = Provider<Color>((ref) {
  final a = ref.watch(spaceAppearanceProvider);
  final dark = ref.watch(appearancePrefsProvider).dark;
  return themeSeedColor(
    a.effectiveTheme,
    a.effectiveCustomColor,
    dark: dark == 'on',
  );
});

/// 当前 `ThemeMode`（夜间模式与主题色叠加）。
final appThemeModeProvider = Provider<ThemeMode>(
  (ref) => themeModeOf(ref.watch(appearancePrefsProvider).dark),
);

/// 当前字号乘数（`:124-127` / `style.css:202-203`）。
final appFontScaleProvider = Provider<double>(
  (ref) => fontScaleOf(ref.watch(appearancePrefsProvider).font),
);

// ── 空间读取 / 全量写（7-C 后的 writeResponseError 错误通道） ────────

/// 从 `GET /api/me` 拿**完整 space**（防抹除的「底」）。
Future<Map<String, dynamic>> fetchFullSpace(Dio dio) async {
  final r = await dio.get('/api/me');
  final data = r.data;
  if (data is! Map) return <String, dynamic>{};
  final s = data['space'];
  return s is Map
      ? Map<String, dynamic>.from(s.cast<String, dynamic>())
      : <String, dynamic>{};
}

/// 全量 `PUT /api/space`；4xx 显式判（服务端 `detail` 原文），失败返回错误串。
Future<String?> putFullSpace(Dio dio, Map<String, dynamic> body) async {
  final r = await dio.put('/api/space', data: body);
  return api.writeResponseError(r);
}

/// 合并写入的统一入口：**先拿完整 space → merge 只改动字段 → 全量 PUT**。
/// 返回 `(mergedSpace, error)`；失败不提交、不发成功通知、不重试。
Future<(Map<String, dynamic>?, String?)> saveSpaceChanges(
  Dio dio,
  Map<String, dynamic> changes, {
  Map<String, dynamic>? knownSpace,
}) async {
  final base = knownSpace ?? await fetchFullSpace(dio);
  final merged = mergeSpace(base, changes);
  final err = await putFullSpace(dio, merged);
  if (err != null) return (null, err);
  return (merged, null);
}

// ── 链路检测（`app.js:1348-1356` / `:1407-1456` / `main.py:423-429`） ─

/// 一条可选线路。
class LinkRoute {
  const LinkRoute({required this.name, required this.url});

  final String name;
  final String url;

  Map<String, dynamic> toJson() => <String, dynamic>{'name': name, 'url': url};
}

/// `GET /api/routes` → 线路清单；**空列表兜底** `AppConfig.effectiveRoutes`
/// （本地测试环境主人实测为空，不许崩/无线路可测）。
List<LinkRoute> routesFromResponse(Object? data, {List<String>? fallback}) {
  final list = <LinkRoute>[];
  if (data is Map) {
    final raw = data['routes'];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        final url = (e['url'] ?? '').toString();
        if (url.isEmpty) continue;
        list.add(LinkRoute(name: (e['name'] ?? url).toString(), url: url));
      }
    }
  }
  if (list.isNotEmpty) return list;
  final bases = fallback ?? AppConfig.effectiveRoutes;
  return <LinkRoute>[
    for (var i = 0; i < bases.length; i++)
      LinkRoute(name: '线路 ${i + 1}', url: bases[i]),
  ];
}

/// 探测结果（ms<0 = 不可达，对齐 `:1359` linkText）。
class LinkProbeResult {
  const LinkProbeResult({
    required this.route,
    required this.ms,
    required this.current,
  });

  final LinkRoute route;
  final int ms;
  final bool current;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': route.name,
    'url': route.url,
    'ms': ms,
    'current': current,
  };
}

/// 纯 ASCII UA（Web `:1363` 靠 `LoveSpaceApp/` 识别原生端；探测头不许带中文）。
const String linkProbeUserAgent = 'LoveSpaceApp/2.2.4 (link-probe; ASCII)';

/// 逐条测**真实延迟**：对每条线路 `GET /api/status` 计时（加时间戳避缓存，
/// 纯 ASCII UA，3s 硬超时）。返回后标记最快线路。
Future<List<LinkProbeResult>> probeRoutes(
  List<LinkRoute> routes, {
  required String currentBase,
  required Future<Response<dynamic>> Function(String url, String userAgent)
  probeOne,
}) async {
  final out = <LinkProbeResult>[];
  for (final r in routes) {
    final base = r.url.replaceAll(RegExp(r'/+$'), '');
    final sw = Stopwatch()..start();
    var ms = -1;
    try {
      await probeOne(
        '$base/api/status?_p=${DateTime.now().millisecondsSinceEpoch}',
        linkProbeUserAgent,
      );
      sw.stop();
      ms = sw.elapsedMilliseconds;
    } catch (_) {
      sw.stop();
      ms = -1;
    }
    out.add(
      LinkProbeResult(
        route: LinkRoute(name: r.name, url: base),
        ms: ms,
        current: base == currentBase.replaceAll(RegExp(r'/+$'), ''),
      ),
    );
  }
  return out;
}

/// 最快线路（ms>=0 中最小，对齐 `:1403-1404`）。
LinkProbeResult? fastestRoute(List<LinkProbeResult> rows) {
  final alive = rows.where((r) => r.ms >= 0).toList();
  if (alive.isEmpty) return null;
  var best = alive.first;
  for (final r in alive) {
    if (r.ms < best.ms) best = r;
  }
  return best;
}

/// 手动切换：`storeLastRoute(base)`（`api_client.dart:190-193`）+
/// `ref.invalidate(baseProvider)` 让 Dio 重建；冷启动 `baseProvider :354-368`
/// 快路径 `readLastRoute()` 优先验活 → 杀进程重开仍走手动那条。
Future<void> useLinkRoute(
  String base, {
  required void Function() invalidateBase,
}) async {
  await api.storeLastRoute(base);
  invalidateBase();
}

// ── 检查更新（`app.js:2843` / `main.py:401-413`） ────────────────────

/// `/api/status` 的 APK 相关字段。
class ApkStatus {
  const ApkStatus({
    required this.webVersion,
    required this.build,
    required this.apkVersion,
    required this.apkUrl,
    required this.apkMirror,
    required this.apkHasLocal,
    required this.apkNotes,
  });

  final String webVersion;
  final String build;
  final String apkVersion;
  final String apkUrl;
  final String apkMirror;
  final bool apkHasLocal;
  final String apkNotes;

  factory ApkStatus.fromJson(Object? data) {
    final m = data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
    return ApkStatus(
      webVersion: (m['version'] ?? '').toString(),
      build: (m['build'] ?? '').toString(),
      apkVersion: (m['apk_version'] ?? '').toString().trim(),
      apkUrl: (m['apk_url'] ?? '/apk/download').toString(),
      apkMirror: (m['apk_mirror'] ?? '').toString(),
      apkHasLocal: m['apk_has_local'] == true,
      apkNotes: (m['apk_notes'] ?? '').toString(),
    );
  }
}

/// `newerVer(a,b)` `app.js:2843`：语义化版本比较，a>b 返回 true。
bool newerVer(String a, String b) {
  List<int> parts(String s) =>
      s.split('.').map((x) => int.tryParse(x.trim()) ?? 0).toList();
  final x = parts(a);
  final y = parts(b);
  for (var i = 0; i < math.max(x.length, y.length); i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d > 0) return true;
    if (d < 0) return false;
  }
  return false;
}

/// `copy-apk-link :2569`：`apkMirror || '/apk/download'`，相对路径拼当前 base。
String apkDownloadLink(ApkStatus s, String base) {
  final path = s.apkMirror.isNotEmpty
      ? s.apkMirror
      : s.apkUrl.isNotEmpty
      ? s.apkUrl
      : '/apk/download';
  if (path.startsWith('http://') || path.startsWith('https://')) return path;
  return '${base.replaceAll(RegExp(r'/+$'), '')}/${path.replaceFirst(RegExp(r'^/+'), '')}';
}
