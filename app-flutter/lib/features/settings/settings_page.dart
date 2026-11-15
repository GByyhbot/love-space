/// 独立 `/settings` 二级页（条目 8 · 段 D）。
///
/// 🔴 边界：**只放本章缺口项**（主题与外观 / 主页背景 / 链路检测与线路切换 /
/// 检查更新 / 复制下载链接）；已有能力（空间信息 / 聊天背景 / 气泡 / 邀请）
/// **只放跳转入口，不复制 UI**（对应位置见定案文档 2.3）。
/// **账号资料页 `profile_page.dart` 完全不动**。
///
/// · 二级页一律 `context.push`，AppBar `automaticallyImplyLeading` 不关 →
///   返回按钮 + 系统手势都能回上一页。
/// · 主题与外观对齐 `themeForm :1870-1942`：7 套 + custom → `PUT /api/space`
///   `{...s, theme, custom_color, motion}`（空间级、双端同步）；dark / font
///   只写本机 SharedPreferences（Web localStorage 等价）；就地预览 + 取消还原。
/// · 主页背景对齐 `homeBgForm :1943-1956`：`POST /api/media` 上传取 id →
///   `PUT /api/space {...s, cover, cover_pos}`（🔴 全量 merge 防抹除）。
/// · 链路检测对齐 `linkCheckPage :1368-1386`；检查更新对齐 `app.js:2593-2612`。
/// · 写方法经 7-C 后的 `writeResponseError` 错误通道：4xx 显式判 + 服务端
///   `detail` 原文、失败不发成功通知 / 不 pop / 输入保留 / 不自动重试。
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import '../../core/config.dart';
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'export_api.dart';
import 'settings_state.dart';

/// `/settings` 独立二级页。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _keys = <String, GlobalKey>{
    'theme': GlobalKey(),
    'cover': GlobalKey(),
    'link': GlobalKey(),
    'about': GlobalKey(),
  };

  // ── 主题与外观本地表单状态 ───────────────────────────────────────
  late String _theme;
  late String _customColor;
  late bool _motion;
  late String _dark;
  late String _font;
  late String _oldDark;
  late String _oldFont;
  String? _themeError;
  bool _themeBusy = false;
  bool _initialized = false;

  // ── 主页背景 ─────────────────────────────────────────────────────
  XFile? _picked;
  Uint8List? _pickedBytes;
  String? _coverError;
  bool _coverBusy = false;

  // ── 数据导出（段 B · D3 定案：复用 downloads/ 落盘范式，不引新依赖）──
  // 🔴 全卡统一忙碌态：三个导出共用服务端限流桶（records/markdown 共用
  // rate_limit('export',10,300)、ics 无限流），任一在途时全卡禁用，
  // 避免连撞 429，也天然做到单按钮防重入。
  bool _exportBusy = false;

  // ── 链路检测 ─────────────────────────────────────────────────────
  List<LinkRoute> _routes = const <LinkRoute>[];
  List<LinkProbeResult> _probes = const <LinkProbeResult>[];
  bool _probing = false;
  bool _routesLoaded = false;
  String? _currentBase;

  // ── 检查更新 ─────────────────────────────────────────────────────
  ApkStatus? _status;
  String _pkgVersion = '';
  String _pkgBuild = '';
  String? _updateError;

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
    Future.microtask(_bootstrap);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadPackageInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _pkgVersion = info.version;
          _pkgBuild = info.buildNumber;
        });
      }
    } catch (_) {
      // 读不到时保持空值，UI 显示「版本加载中…」
    }
  }

  Future<void> _bootstrap() async {
    final appearance = ref.read(spaceAppearanceProvider);
    final prefs = ref.read(appearancePrefsProvider);
    if (!_initialized) {
      _initialized = true;
      setState(() {
        _theme = appearance.theme;
        _customColor = appearance.customColor.isEmpty
            ? customColorFallback
            : appearance.customColor;
        _motion = appearance.motion;
        _dark = prefs.dark;
        _font = prefs.font;
        _oldDark = prefs.dark;
        _oldFont = prefs.font;
      });
    }
    await _loadRoutes();
    await _checkUpdate();
    _scrollToSection();
  }

  void _scrollToSection() {
    final section = GoRouterState.of(context).uri.queryParameters['section'];
    if (section == null || !_keys.containsKey(section)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _keys[section]!;
      if (key.currentContext == null) return;
      Scrollable.ensureVisible(
        key.currentContext!,
        duration: const Duration(milliseconds: 260),
      );
    });
  }

  Map<String, dynamic>? get _knownSpace =>
      ref.read(authProvider.notifier).me?.spaceRaw;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    if (!_initialized) {
      return Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // 对象端改主题 → SSE other → auth.reload() → 重新播种（双端同步）。
    ref.listen(authProvider, (prev, next) {
      if (next == AuthPhase.authed) {
        final me = ref.read(authProvider.notifier).me;
        if (me != null) {
          ref.read(spaceAppearanceProvider.notifier).seed(me.spaceRaw);
        }
      }
    });

    return Scaffold(
      // 🔴 automaticallyImplyLeading 不关：返回按钮 + 系统手势都能回上一页。
      appBar: AppBar(title: const Text('设置')),
      body: RefreshIndicator(
        onRefresh: _bootstrap,
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
          children: [
            Text(
              '管理空间、账号和数据。',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
            ),
            const SizedBox(height: 12),
            _heading(context, '外观与背景'),
            _themeCard(context),
            _coverCard(context),
            _navCard(context),
            const SizedBox(height: 16),
            _heading(context, '连接'),
            _linkCard(context),
            const SizedBox(height: 16),
            _exportCard(context),
            const SizedBox(height: 16),
            _heading(context, '关于'),
            _aboutCard(context),
          ],
        ),
      ),
    );
  }

  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );

  Widget _card(
    BuildContext context, {
    required String title,
    required Widget child,
    GlobalKey? key,
  }) => Card(
    key: key,
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );

  // ── 主题与外观（themeForm :1870-1942） ────────────────────────────
  Widget _themeCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _card(
      context,
      key: _keys['theme'],
      title: '主题与外观',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('主题配色　·　两个人共用', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final id in themeIds) _swatch(context, id)],
          ),
          if (_theme == 'custom') ...[
            const SizedBox(height: 10),
            TextField(
              key: const Key('settings-custom-color'),
              controller: TextEditingController(text: _customColor)
                ..selection = TextSelection.collapsed(
                  offset: _customColor.length,
                ),
              onChanged: (v) {
                _customColor = v;
                _previewTheme();
              },
              decoration: const InputDecoration(
                labelText: '自定义颜色（#RRGGBB）',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: const Key('settings-dark'),
                  initialValue: _dark,
                  decoration: const InputDecoration(
                    labelText: '夜间模式',
                    isDense: true,
                  ),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem(value: 'auto', child: Text('跟随系统')),
                    DropdownMenuItem(value: 'on', child: Text('始终开启')),
                    DropdownMenuItem(value: 'off', child: Text('始终关闭')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _dark = v);
                    // 夜间模式即时预览（`:1917-1923`）
                    ref.read(appearancePrefsProvider.notifier).preview(dark: v);
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: const Key('settings-font'),
                  initialValue: _font,
                  decoration: const InputDecoration(
                    labelText: '字号',
                    isDense: true,
                  ),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem(value: 'std', child: Text('标准')),
                    DropdownMenuItem(value: 'large', child: Text('大一号')),
                    DropdownMenuItem(value: 'xl', child: Text('特大')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _font = v);
                    ref.read(appearancePrefsProvider.notifier).preview(font: v);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SwitchListTile(
            key: const Key('settings-motion'),
            contentPadding: EdgeInsets.zero,
            title: const Text('启用轻柔动效'),
            value: _motion,
            onChanged: (v) {
              setState(() => _motion = v);
              _previewTheme();
            },
          ),
          Text(
            themeFormNote,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: cs.outline),
          ),
          if (_themeError != null) ...[
            const SizedBox(height: 8),
            Text(
              _themeError!,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: cs.error),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton(
                key: const Key('settings-theme-cancel'),
                onPressed: _themeBusy ? null : _cancelTheme,
                child: const Text('取消'),
              ),
              const SizedBox(width: 10),
              FilledButton(
                key: const Key('settings-theme-save'),
                onPressed: _themeBusy ? null : _saveTheme,
                child: _themeBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _swatch(BuildContext context, String id) {
    final on = _theme == id;
    final meta = themeMeta[id];
    final label = meta?[0] ?? '自定义';
    final seed = themeSeedColor(id, _customColor);
    return InkWell(
      key: Key('settings-theme-$id'),
      borderRadius: BorderRadius.circular(10),
      onTap: () {
        setState(() => _theme = id);
        _previewTheme();
      },
      child: Container(
        width: 92,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: on
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: on
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(color: seed, shape: BoxShape.circle),
              child: on
                  ? const Icon(Icons.check, size: 16, color: Colors.white)
                  : null,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  void _previewTheme() {
    ref
        .read(spaceAppearanceProvider.notifier)
        .preview(
          theme: _theme,
          customColor: _theme == 'custom' ? _customColor : '',
          motion: _motion,
        );
  }

  Future<void> _cancelTheme() async {
    // `:1906` cleanup 等价：还原 class / DARK_KEY / 自定义色 / 字号。
    ref.read(spaceAppearanceProvider.notifier).cancel();
    await ref.read(appearancePrefsProvider.notifier).cancel(_oldDark, _oldFont);
    if (!mounted) return;
    final a = ref.read(spaceAppearanceProvider);
    setState(() {
      _theme = a.theme;
      _customColor = a.customColor.isEmpty
          ? customColorFallback
          : a.customColor;
      _motion = a.motion;
      _dark = _oldDark;
      _font = _oldFont;
      _themeError = null;
    });
  }

  Future<void> _saveTheme() async {
    if (_theme == 'custom' && !isValidCustomColor(_customColor)) {
      setState(() => _themeError = '自定义颜色要是 #RRGGBB');
      return;
    }
    setState(() {
      _themeBusy = true;
      _themeError = null;
    });
    try {
      final dio = await ref.read(api.dioProvider.future);
      final (merged, err) = await saveSpaceChanges(
        dio,
        themeSpaceChanges(
          theme: _theme,
          customColor: _customColor,
          motion: _motion,
        ),
        knownSpace: _knownSpace,
      );
      if (err != null) {
        if (mounted) setState(() => _themeError = err);
        ref
            .read(chatToastProvider.notifier)
            .show('主题保存失败：$err', tone: ChatToastTone.error);
        return; // 不发成功通知、不 pop、输入保留、不重试
      }
      // dark / font 只写本机，绝不进 PUT body
      await ref
          .read(appearancePrefsProvider.notifier)
          .save(dark: _dark, font: _font);
      if (merged != null) {
        ref.read(spaceAppearanceProvider.notifier).commit(merged);
      }
      _oldDark = _dark;
      _oldFont = _font;
      await ref.read(authProvider.notifier).reload();
      if (!mounted) return;
      ref.read(chatToastProvider.notifier).show('主题换好了，两个人都看得见');
    } catch (e) {
      if (mounted) setState(() => _themeError = api.errorDetail(e));
      ref
          .read(chatToastProvider.notifier)
          .show('主题保存失败：${api.errorDetail(e)}', tone: ChatToastTone.error);
    } finally {
      if (mounted) setState(() => _themeBusy = false);
    }
  }

  // ── 主页背景（homeBgForm :1943-1956） ─────────────────────────────
  Widget _coverCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final cover = (_knownSpace?['cover'] ?? '').toString();
    return _card(
      context,
      key: _keys['cover'],
      title: '主页背景',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('首页封面照片', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 8),
          _coverPreview(context, cover),
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton.icon(
                key: const Key('settings-cover-pick'),
                onPressed: _coverBusy ? null : _pickCover,
                icon: const Icon(Icons.image_outlined),
                label: Text(_picked == null ? '选择封面照片' : '重新选择'),
              ),
              const SizedBox(width: 10),
              FilledButton(
                key: const Key('settings-cover-save'),
                onPressed: _coverBusy || _picked == null ? null : _saveCover,
                child: _coverBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保存'),
              ),
            ],
          ),
          if (_picked != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _picked!.name,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          if (_coverError != null) ...[
            const SizedBox(height: 8),
            Text(
              _coverError!,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: cs.error),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            '换好照片保存后会直接更新首页封面；想再换，回这里重选就行。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: cs.outline),
          ),
        ],
      ),
    );
  }

  Widget _coverPreview(BuildContext context, String cover) {
    final cs = Theme.of(context).colorScheme;
    final headers = ref.watch(mediaCookieHeadersProvider).valueOrNull;
    final base = ref.watch(chatBaseProvider).valueOrNull;
    final bytes = _pickedBytes;
    Widget image;
    if (bytes != null) {
      image = Image.memory(bytes, fit: BoxFit.cover);
    } else if (cover.isNotEmpty && base != null) {
      image = Image.network(
        '$base/media/$cover?preview=true',
        fit: BoxFit.cover,
        headers: headers,
        errorBuilder: (_, _, _) => _coverPlaceholder(cs),
      );
    } else {
      image = _coverPlaceholder(cs);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(height: 120, width: double.infinity, child: image),
    );
  }

  Widget _coverPlaceholder(ColorScheme cs) => Container(
    color: cs.surfaceContainerHighest,
    alignment: Alignment.center,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('🖼️', style: TextStyle(fontSize: 26)),
        const SizedBox(height: 4),
        Text(
          '选择一张照片作为我们的空间封面',
          style: TextStyle(fontSize: 11, color: cs.outline),
        ),
      ],
    ),
  );

  Future<void> _pickCover() async {
    try {
      final x = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        imageQuality: 88,
      );
      if (x == null) return;
      final bytes = await x.readAsBytes();
      if (!mounted) return;
      setState(() {
        _picked = x;
        _pickedBytes = Uint8List.fromList(bytes);
        _coverError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _coverError = api.errorDetail(e));
    }
  }

  Future<void> _saveCover() async {
    final x = _picked;
    final bytes = _pickedBytes;
    if (x == null || bytes == null) return;
    setState(() {
      _coverBusy = true;
      _coverError = null;
    });
    try {
      final dio = await ref.read(api.dioProvider.future);
      final id = await api.uploadMedia(dio, x.name, bytes);
      final (merged, err) = await saveSpaceChanges(
        dio,
        coverSpaceChanges(cover: id),
        knownSpace: _knownSpace,
      );
      if (err != null) {
        if (mounted) setState(() => _coverError = err);
        ref
            .read(chatToastProvider.notifier)
            .show('封面保存失败：$err', tone: ChatToastTone.error);
        return;
      }
      if (merged != null) {
        ref.read(spaceAppearanceProvider.notifier).commit(merged);
      }
      await ref.read(authProvider.notifier).reload();
      if (!mounted) return;
      setState(() {
        _picked = null;
        _pickedBytes = null;
      });
      ref.read(chatToastProvider.notifier).show('主页封面换好了');
    } catch (e) {
      if (mounted) setState(() => _coverError = api.errorDetail(e));
      ref
          .read(chatToastProvider.notifier)
          .show('封面保存失败：${api.errorDetail(e)}', tone: ChatToastTone.error);
    } finally {
      if (mounted) setState(() => _coverBusy = false);
    }
  }

  // ── 已有能力：只放跳转入口，不复制 UI ─────────────────────────────
  Widget _navCard(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Column(
      children: [
        ListTile(
          key: const Key('settings-nav-space'),
          leading: const Text('🏡', style: TextStyle(fontSize: 20)),
          title: const Text('空间信息'),
          subtitle: const Text('空间名称与相恋日期（首页封面卡片编辑）'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            ref.read(spaceEditRequestedProvider.notifier).state = true;
            context.go('/home');
          },
        ),
        ListTile(
          key: const Key('settings-nav-chat-bg'),
          leading: const Text('🌄', style: TextStyle(fontSize: 20)),
          title: const Text('聊天背景'),
          subtitle: const Text('聊天页右上角「聊天背景」按钮'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/messages'),
        ),
        ListTile(
          key: const Key('settings-nav-chat-bubble'),
          leading: const Text('💬', style: TextStyle(fontSize: 20)),
          title: const Text('聊天气泡'),
          subtitle: const Text('聊天页右上角「聊天气泡」按钮'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/messages'),
        ),
        ListTile(
          key: const Key('settings-nav-invite'),
          leading: const Text('💌', style: TextStyle(fontSize: 20)),
          title: const Text('邀请另一半入住'),
          subtitle: const Text('账号资料页生成专属邀请链接'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/profile'),
        ),
      ],
    ),
  );

  // ── 链路检测与手动切线路（linkCheckPage :1368-1386） ───────────────
  Widget _linkCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final best = fastestRoute(_probes);
    return _card(
      context,
      key: _keys['link'],
      title: '链路检测与线路切换',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '看看现在哪条线路最快，也可以手动切换。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const Key('settings-link-probe'),
            onPressed: _probing ? null : _runProbe,
            icon: _probing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.network_check, size: 18),
            label: Text(_probing ? '检测中…' : '开始检测'),
          ),
          const SizedBox(height: 10),
          if (!_routesLoaded)
            Text('线路清单加载中…', style: Theme.of(context).textTheme.labelSmall)
          else if (_probes.isEmpty)
            Text(
              '还没有检测结果，点上面的「开始检测」。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: cs.outline),
            )
          else
            for (final row in _probes)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: row.current
                      ? cs.primaryContainer.withValues(alpha: 0.45)
                      : cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            row.route.name,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Text(
                            row.route.url
                                .replaceFirst(RegExp(r'^https?://'), '')
                                .replaceAll(RegExp(r'/+$'), ''),
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: cs.outline),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      row.ms < 0 ? '不可达' : '${row.ms} ms',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: row.ms < 0
                            ? cs.error
                            : row.ms <= 300
                            ? cs.primary
                            : cs.tertiary,
                      ),
                    ),
                    if (identical(row, best))
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          '最快',
                          style: TextStyle(fontSize: 10, color: cs.primary),
                        ),
                      ),
                    if (row.current)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          '当前',
                          style: TextStyle(fontSize: 10, color: cs.outline),
                        ),
                      )
                    else
                      TextButton(
                        key: Key('settings-link-use-${row.route.url}'),
                        onPressed: () => _useRoute(row.route.url),
                        child: const Text('切换'),
                      ),
                  ],
                ),
              ),
          const SizedBox(height: 6),
          Text(
            '检测在手机本地直接发起，数值是访问 /api/status 的往返耗时。'
            '在这里切换后，下次打开 App 会直接走这条线路。',
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: cs.outline),
          ),
        ],
      ),
    );
  }

  Future<void> _loadRoutes() async {
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.get('/api/routes');
      final list = routesFromResponse(r.data);
      _currentBase = await ref.read(api.baseProvider.future);
      if (mounted) {
        setState(() {
          _routes = list;
          _routesLoaded = true;
        });
      }
    } catch (_) {
      // 空/异常一律兜底本地线路清单，不许崩、不许无线路可测
      _currentBase = await ref.read(api.baseProvider.future);
      if (mounted) {
        setState(() {
          _routes = routesFromResponse(null);
          _routesLoaded = true;
        });
      }
    }
  }

  Future<void> _runProbe() async {
    if (_probing) return;
    setState(() => _probing = true);
    try {
      final rows = await probeRoutes(
        _routes,
        currentBase: _currentBase ?? AppConfig.builtinMainRoute,
        probeOne: (url, ua) async {
          final d = Dio(
            BaseOptions(
              connectTimeout: AppConfig.probeTimeout,
              receiveTimeout: AppConfig.probeTimeout,
              validateStatus: (s) => s != null && s < 500,
            ),
          )..httpClientAdapter = api.directAdapter();
          return d.get(
            url,
            options: Options(
              headers: <String, String>{
                'User-Agent': ua,
                'Cache-Control': 'no-store',
              },
            ),
          );
        },
      );
      if (mounted) setState(() => _probes = rows);
      final alive = rows.where((r) => r.ms >= 0).length;
      ref
          .read(chatToastProvider.notifier)
          .show(
            alive > 0 ? '检测完成，$alive/${rows.length} 条线路可用' : '所有线路都没连上，检查一下网络',
            tone: alive > 0 ? ChatToastTone.info : ChatToastTone.error,
          );
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _useRoute(String base) async {
    await useLinkRoute(
      base,
      invalidateBase: () => ref.invalidate(api.baseProvider),
    );
    _currentBase = base;
    ref.read(chatToastProvider.notifier).show('正在切换到新线路…');
    if (!mounted) return;
    setState(() {
      _probes = <LinkProbeResult>[
        for (final r in _probes)
          LinkProbeResult(
            route: r.route,
            ms: r.ms,
            current: r.route.url == base,
          ),
      ];
    });
  }

  // ── 数据导出三件（Web settingsPage 数据管理卡 app.js:1481-1482 · 段 B）──
  // · 三个下载入口逐字对齐 Web：/api/export · /api/export/markdown ·
  //   /api/export/ics（W8–W10）；Web 的 admin「完整备份与存储占用」按钮与
  //   存储摘要条属段 C，本段不加。
  // · 承接按 D3 定案：downloadExport 落 downloads/ + 顶部通知报文件名；
  //   不做分享/打开文件通道、不做进度条、不做加密。
  // · 4xx 原文透传（429「尝试过于频繁…」/ 404「还没有可导出的纪念日或
  //   计划」）：error tone 顶部通知，不吞、不改写、不假成功。
  Widget _exportCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final busy = _exportBusy;
    Widget row(
      ExportKind kind,
      String key,
      String label,
      IconData icon,
    ) => ListTile(
      key: Key(key),
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 22),
      title: Text(label),
      // 任一在途：该按钮点不动（统一禁用，防共享限流桶连撞 429）
      trailing: busy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.download_rounded, size: 20, color: cs.outline),
      enabled: !busy,
      onTap: busy ? null : () => _startExport(kind),
    );
    return _card(
      context,
      title: exportCardTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          row(
            ExportKind.records,
            'settings-export-records',
            exportRecordsLabel,
            Icons.folder_zip_outlined,
          ),
          row(
            ExportKind.markdown,
            'settings-export-markdown',
            exportMarkdownLabel,
            Icons.article_outlined,
          ),
          row(
            ExportKind.ics,
            'settings-export-ics',
            exportIcsLabel,
            Icons.event_outlined,
          ),
          if (busy)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '导出中…',
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: cs.outline),
              ),
            ),
          Text(
            exportCardNote,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: cs.outline),
          ),
        ],
      ),
    );
  }

  Future<void> _startExport(ExportKind kind) async {
    if (_exportBusy) return; // 在途防重入：请求未回不许叠发
    setState(() => _exportBusy = true);
    try {
      final dio = await ref.read(api.dioProvider.future);
      final (saved, err) = await downloadExport(dio, kind);
      if (!mounted) return;
      if (err != null) {
        // 失败：服务端 detail 原文（429/404 同样），不假成功
        ref.read(chatToastProvider.notifier).show(err, tone: ChatToastTone.error);
        return;
      }
      // 成功：通知里报的文件名与实际落盘文件名同源（同一字符串）
      ref
          .read(chatToastProvider.notifier)
          .show('已保存到本地：downloads/${saved!.filename}',
              tone: ChatToastTone.success);
    } finally {
      if (mounted) setState(() => _exportBusy = false);
    }
  }

  // ── 检查更新 + 复制下载链接（app.js:2593-2612 / :2569） ───────────
  Widget _aboutCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = _status;
    final updateTarget = s?.apkVersion ?? '';
    final notes = s?.apkNotes ?? '';
    final hasUpdate =
        s != null &&
        s.apkVersion.isNotEmpty &&
        _pkgVersion.isNotEmpty &&
        newerVer(s.apkVersion, _pkgVersion);
    final link = s == null
        ? ''
        : apkDownloadLink(s, _currentBase ?? AppConfig.builtinMainRoute);
    return _card(
      context,
      key: _keys['about'],
      title: '关于',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Text('💕', style: TextStyle(fontSize: 26)),
            title: const Text('恋爱空间'),
            subtitle: Text(
              _pkgVersion.isEmpty ? '版本加载中…' : 'APK v$_pkgVersion ($_pkgBuild)',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (hasUpdate)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '可更新到 v$updateTarget',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: cs.error),
              ),
            ),
          if (notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '更新说明：$notes',
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: cs.outline),
              ),
            ),
          if (!hasUpdate && s != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '已是最新版本 v$_pkgVersion',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: cs.outline),
              ),
            ),
          if (_updateError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _updateError!,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: cs.error),
              ),
            ),
          Wrap(
            spacing: 10,
            children: [
              OutlinedButton(
                key: const Key('settings-check-update'),
                onPressed: _checkUpdate,
                child: const Text('检查更新'),
              ),
              OutlinedButton(
                key: const Key('settings-copy-apk'),
                onPressed: link.isEmpty ? null : () => _copyLink(link),
                child: const Text('复制 App 下载链接'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '网页功能自动更新；原生功能需下载新版 APK，可在检查更新中获取，'
            '也可复制下载链接发给对方在手机浏览器打开。',
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: cs.outline),
          ),
        ],
      ),
    );
  }

  Future<void> _checkUpdate() async {
    try {
      final dio = await ref.read(api.dioProvider.future);
      final r = await dio.get('/api/status');
      if (mounted) {
        setState(() {
          _status = ApkStatus.fromJson(r.data);
          _updateError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _updateError = api.errorDetail(e));
    }
  }

  Future<void> _copyLink(String link) async {
    await Clipboard.setData(ClipboardData(text: link));
    ref.read(chatToastProvider.notifier).show('下载链接已复制，可以直接发给对方');
  }
}
