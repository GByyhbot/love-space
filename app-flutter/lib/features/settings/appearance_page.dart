/// 主题与外观（2.4.0 设置拆分段）：原全量 /settings 的「主题与外观」节
/// 整节搬入独立页（settings_page.dart 退役，节代码原样搬移零逻辑改动）。
/// 保存链不变：saveSpaceChanges + themeSpaceChanges（全量 space 合并 PUT，
/// 绝不丢字段）；失败行内保留 + 顶部 toast、成功顶部 toast。
/// Web 出处 themeForm :1870-1942。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/theme/tokens.dart';
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'settings_state.dart';

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
    return Scaffold(
      appBar: AppBar(title: const Text('主题与外观')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('主题配色　·　两个人共用',
                style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: Spacing.gap),
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
            const SizedBox(height: Spacing.gap),
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
              style:
                  Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.outline),
            ),
            if (_themeError != null) ...[
              const SizedBox(height: Spacing.gap),
              Text(
                _themeError!,
                style:
                    Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.error),
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
      borderRadius: BorderRadius.circular(AppRadius.sm),
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
          borderRadius: BorderRadius.circular(AppRadius.sm),
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
              style: Theme.of(context).textTheme.labelSmall,
              textAlign: TextAlign.center,
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
        ref.read(chatToastProvider.notifier).show('主题保存失败：$err',
            tone: ChatToastTone.error);
        return; // 不发成功通知、不 pop、输入保留、不重试
      }
      // dark / font 只写本机，绝不进 PUT body
      await ref.read(appearancePrefsProvider.notifier).save(dark: _dark, font: _font);
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
      ref.read(chatToastProvider.notifier).show(
          '主题保存失败：${api.errorDetail(e)}',
          tone: ChatToastTone.error);
    } finally {
      if (mounted) setState(() => _themeBusy = false);
    }
  }
}
