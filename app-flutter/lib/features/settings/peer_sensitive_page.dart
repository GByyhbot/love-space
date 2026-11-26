/// 2.8.7 全量施工令 · 敏感软件过滤（多选清单）。
///
/// 勾选即脱敏：命中的应用在对方那边只显示「其他应用」，真实包名**永不出设备**
/// （端侧改写 + 服务端哨兵校验，两道）。
///
/// 清单来源：原生 `installedApps`（启动器入口枚举，排除本 App）。拿不到就明说，
/// 不摆一个空列表假装「你没有应用」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/peer/peer_report_api.dart';
import '../../core/peer/peer_state_collector.dart';
import '../../core/theme/tokens.dart';
import '../../core/ui/empty_view.dart';
import '../../core/ui/error_view.dart';
import '../../core/ui/progress.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;

class PeerSensitivePage extends ConsumerStatefulWidget {
  const PeerSensitivePage({super.key});

  @override
  ConsumerState<PeerSensitivePage> createState() => _PeerSensitivePageState();
}

class _PeerSensitivePageState extends ConsumerState<PeerSensitivePage> {
  PeerShareSettings? _settings;
  List<Map<String, String>> _apps = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final dio = await ref.read(api.dioProvider.future);
      final s = await fetchPeerSettings(dio);
      final apps = await fetchInstalledApps();
      if (!mounted) return;
      setState(() {
        _settings = s;
        _apps = apps;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = api.errorDetail(e);
      });
    }
  }

  Future<void> _toggle(String pkg, bool on) async {
    final s = _settings;
    if (s == null || _saving) return;
    final next = [...s.policy.sensitivePkgs];
    if (on) {
      if (!next.contains(pkg)) next.add(pkg);
    } else {
      next.remove(pkg);
    }
    setState(() {
      _saving = true;
      _settings = s.copyWith(policy: s.policy.copyWith(sensitivePkgs: next));
    });
    try {
      final dio = await ref.read(api.dioProvider.future);
      final saved = await updatePeerSettings(dio, _settings!);
      if (!mounted) return;
      setState(() => _settings = saved);
      await applyPeerPolicy(saved.policy, force: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _settings = s);
      ref
          .read(chatToastProvider.notifier)
          .show('未保存：${api.errorDetail(e)}', tone: ChatToastTone.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final selected = _settings?.policy.sensitivePkgs ?? const <String>[];
    // 已勾选的排在最前（几百个应用里好找）
    final sorted = [..._apps]..sort((a, b) {
        final sa = selected.contains(a['pkg']);
        final sb = selected.contains(b['pkg']);
        if (sa != sb) return sa ? -1 : 1;
        return (a['label'] ?? '').compareTo(b['label'] ?? '');
      });
    return Scaffold(
      appBar: AppBar(title: const Text('敏感软件过滤')),
      body: SafeArea(
        child: _loading
            ? const AppProgress()
            : _error != null
                ? AppErrorView(detail: _error!, onRetry: _load)
                : _apps.isEmpty
                    ? const AppEmptyView(
                        icon: Icons.apps_outlined,
                        title: '本机拿不到应用清单',
                        hint: '请在系统设置里允许读取应用列表后重进此页',
                      )
                    : ListView(
                        key: const Key('sensitive-scroll'),
                        padding: const EdgeInsets.fromLTRB(
                            16, 12, 16, Spacing.pageBottom),
                        children: [
                          Text(
                            '勾选的应用在对方那边只显示为「其他应用」，真实包名不会离开这台手机。',
                            key: const Key('sensitive-note'),
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: cs.outline),
                          ),
                          const SizedBox(height: Spacing.gap),
                          for (final a in sorted)
                            SwitchListTile(
                              key: Key('sensitive-${a['pkg']}'),
                              title: Text(a['label'] ?? ''),
                              subtitle: Text(a['pkg'] ?? '',
                                  style: theme.textTheme.bodySmall
                                      ?.copyWith(color: cs.outline)),
                              value: selected.contains(a['pkg']),
                              onChanged: _saving
                                  ? null
                                  : (v) => _toggle(a['pkg']!, v),
                            ),
                        ],
                      ),
      ),
    );
  }
}
