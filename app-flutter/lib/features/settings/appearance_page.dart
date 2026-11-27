/// 主题与外观（2.4.1 修复包第 2 项改版；原 2.4.0 拆页，字段与保存链全不动）：
/// · 主题色卡：卡面带该主题 primary 低透明度渐变（渐隐到透明）、圆点放大
///   +柔和投影、选中态 = 该主题色描边 + 右上角勾徽，禁止整卡实心填充；
/// · 实时预览卡：样例气泡对 + 主按钮，用「当前正选中的候选主题」渲染，
///   点色卡预览即时跟随（仅预览，落库以「保存」为准，「取消」还原进页时主题）；
/// · 夜间模式 / 字号：Material 下拉 → 圆角分段器（SettingsSegmented，
///   与第 8 项相册分段器共用组件）；
/// · 「启用轻柔动效」改卡片行（左标题 + 说明，右开关）；
/// · 说明文字降为页脚注脚（SettingsFootnote）；
/// · 取消/保存移入底部玻璃操作栏（SettingsGlassBar 共享组件，1/3 + 2/3）；
/// · 页面顶部当前主题色极淡渐变罩（第 7 项，自顶部向下渐隐）。
/// 功能与保存链全不动：主题色 PUT /api/space 全量合并
/// （themeSpaceChanges + saveSpaceChanges）；dark/font 只写本机。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/theme/tokens.dart';
import '../auth/auth_state.dart';
import '../../core/ui/jelly_switch.dart' show JellySwitch;
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'settings_state.dart';
import 'settings_widgets.dart';

class AppearancePage extends ConsumerStatefulWidget {
  const AppearancePage({super.key});

  @override
  ConsumerState<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends ConsumerState<AppearancePage> {
  late String _theme;
  late String _customColor;
  late bool _motion;
  late String _dark;
  late String _font;
  late String _oldDark;
  late String _oldFont;
  String? _themeError;
  bool _themeBusy = false;

  Map<String, dynamic>? get _knownSpace =>
      ref.read(authProvider.notifier).me?.spaceRaw;

  @override
  void initState() {
    super.initState();
    final appearance = ref.read(spaceAppearanceProvider);
    final prefs = ref.read(appearancePrefsProvider);
    _theme = appearance.theme;
    _customColor = appearance.customColor.isEmpty
        ? customColorFallback
        : appearance.customColor;
    _motion = appearance.motion;
    _dark = prefs.dark;
    _font = prefs.font;
    _oldDark = prefs.dark;
    _oldFont = prefs.font;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 对象端改主题 → SSE other → auth.reload() → 重新播种（双端同步）。
    ref.listen(authProvider, (prev, next) {
      if (next == AuthPhase.authed) {
        final me = ref.read(authProvider.notifier).me;
        if (me != null) {
          ref.read(spaceAppearanceProvider.notifier).seed(me.spaceRaw);
        }
      }
    });
    // 第 7 项：顶部当前主题色极淡渐变罩（自顶部向下渐隐）。
    final halo = themeSeedColor(_theme, _customColor);
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(title: const Text('主题与外观')),
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    halo.withValues(alpha: 0.10),
                    cs.surface,
                  ],
                  stops: const [0, 0.28],
                ),
              ),
              child: const SizedBox.expand(),
            ),
          ),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                  16, 12, 16, SettingsGlassBar.barReserveHeight + 12),
              children: [
                _themeSwatches(context),
                const SizedBox(height: 14),
                _previewCard(context),
                const SizedBox(height: 14),
                Text('夜间模式', style: Theme.of(context).textTheme.labelSmall),
                const SizedBox(height: 6),
                SettingsSegmented<String>(
                  key: const Key('settings-dark'),
                  segments: const [
                    ('auto', '跟随系统'),
                    ('on', '浅色'),
                    ('off', '深色'),
                  ],
                  selected: _dark,
                  onChanged: (v) {
                    setState(() => _dark = v);
                    // 夜间模式即时预览（`:1917-1923`）
                    ref.read(appearancePrefsProvider.notifier).preview(dark: v);
                  },
                ),
                const SizedBox(height: 12),
                Text('字号', style: Theme.of(context).textTheme.labelSmall),
                const SizedBox(height: 6),
                SettingsSegmented<String>(
                  key: const Key('settings-font'),
                  segments: const [
                    ('std', '标准'),
                    ('large', '大一号'),
                    ('xl', '特大'),
                  ],
                  selected: _font,
                  onChanged: (v) {
                    setState(() => _font = v);
                    ref.read(appearancePrefsProvider.notifier).preview(font: v);
                  },
                ),
                const SizedBox(height: 12),
                // 第 4 项：动效开关改卡片行（左标题+说明，右开关）。
                // 2.4.10：开关换果冻开关（取值/预览/保存链路零改动）。
                Card(
                  child: ListTile(
                    key: const Key('settings-motion'),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 14),
                    title: const Text('启用轻柔动效'),
                    subtitle: Text('转场与点按的柔感动画',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: cs.outline)),
                    trailing: JellySwitch(
                      value: _motion,
                      onChanged: (v) {
                        setState(() => _motion = v);
                        _previewTheme();
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // 第 5 项：说明降为页脚注脚。
                SettingsFootnote(themeFormNote),
                if (_themeError != null) ...[
                  const SizedBox(height: Spacing.gap),
                  Text(
                    _themeError!,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: cs.error),
                  ),
                ],
              ],
            ),
          ),
          // 第 6 项：取消/保存固定底部玻璃操作栏（共享组件 1/3 + 2/3）。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SettingsGlassBar(
              cancelLabel: '取消',
              onCancel: _themeBusy ? null : _cancelTheme,
              saveLabel: '保存',
              // 2.4.10：保存走三连变（真实请求驱动）。
              onSave: () {},
              saveEnabled: !_themeBusy,
              morphOnSave: _saveTheme,
            ),
          ),
        ],
      ),
    );
  }

  // ── 主题色卡（第 2 项①：渐变卡面 + 大圆点投影 + 描边勾徽选中态） ──
  Widget _themeSwatches(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [for (final id in themeIds) _swatch(context, id)],
    );
  }

  Widget _swatch(BuildContext context, String id) {
    final on = _theme == id;
    final meta = themeMeta[id];
    final label = meta?[0] ?? '自定义';
    final seed = themeSeedColor(id, _customColor);
    return InkWell(
      key: Key('settings-theme-$id'),
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        setState(() => _theme = id);
        _previewTheme();
      },
      child: Container(
        width: 104,
        height: 86,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          // 卡面：该主题 primary 低透明度渐变（由该色渐隐到透明），
          // 禁止整卡实心填充（第 2 项①）。
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              seed.withValues(alpha: on ? 0.22 : 0.10),
              Colors.transparent,
            ],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            // 选中态 = 该主题色描边。
            color: on ? seed : Theme.of(context).colorScheme.outlineVariant,
            width: on ? 2 : 1,
          ),
        ),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 圆点放大 + 柔和投影。
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: seed,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: seed.withValues(alpha: 0.45),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            // 选中态右上角勾徽。
            if (on)
              Positioned(
                right: 0,
                top: 0,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration:
                          BoxDecoration(color: seed, shape: BoxShape.circle),
                      child: const Icon(Icons.check_rounded,
                          size: 13, color: Colors.white),
                    ),
              ),
          ],
        ),
      ),
    );
  }

  // ── 第 2 项②：实时预览卡（候选主题渲染样例气泡对 + 主按钮） ────────
  Widget _previewCard(BuildContext context) {
    final candidateSeed = themeSeedColor(_theme, _customColor);
    final candidateScheme = ColorScheme.fromSeed(
      seedColor: candidateSeed,
      brightness: Theme.of(context).brightness,
    );
    return Card(
      key: const Key('settings-theme-preview'),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.cardPad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('实时预览　·　当前候选主题',
                style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 10),
            // 候选主题的隔离渲染域：气泡对 + 主按钮全部用候选配色。
            Theme(
              data: Theme.of(context).copyWith(colorScheme: candidateScheme),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Flexible(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          constraints:
                              const BoxConstraints(maxWidth: 220),
                          decoration: BoxDecoration(
                            color: candidateScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text('对方的一条样例消息',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                      color:
                                          candidateScheme.onSurface)),
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    Flexible(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          constraints:
                              const BoxConstraints(maxWidth: 220),
                          decoration: BoxDecoration(
                            color: candidateScheme.primary,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text('我方的一条样例消息',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                      color:
                                          candidateScheme.onPrimary)),
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const Key('settings-theme-preview-button'),
                    onPressed: null,
                    style: FilledButton.styleFrom(
                      // 主按钮柔光（Web btn-primary 同款口径）。
                      elevation: 3,
                      shadowColor:
                          candidateScheme.primary.withValues(alpha: 0.35),
                    ),
                    child: const Text('回到我们的世界'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _previewTheme() {
    ref.read(spaceAppearanceProvider.notifier).preview(
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
      _customColor =
          a.customColor.isEmpty ? customColorFallback : a.customColor;
      _motion = a.motion;
      _dark = _oldDark;
      _font = _oldFont;
      _themeError = null;
    });
  }

  // 2.4.10：改返 Future<bool> 供三连变真实请求驱动（失败不 pop 不重试口径不变）。
  Future<bool> _saveTheme() async {
    if (_theme == 'custom' && !isValidCustomColor(_customColor)) {
      setState(() => _themeError = '自定义颜色要是 #RRGGBB');
      return false;
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
        ref.read(chatToastProvider.notifier).show('主题保存失败：$err',
            tone: ChatToastTone.error);
        return false; // 不发成功通知、不 pop、输入保留、不重试
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
      if (!mounted) return false;
      ref.read(chatToastProvider.notifier).show('主题换好了，两个人都看得见');
      return true;
    } catch (e) {
      if (mounted) setState(() => _themeError = api.errorDetail(e));
      ref.read(chatToastProvider.notifier).show(
          '主题保存失败：${api.errorDetail(e)}',
          tone: ChatToastTone.error);
      return false;
    } finally {
      if (mounted) setState(() => _themeBusy = false);
    }
  }
}
