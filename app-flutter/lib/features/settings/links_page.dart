/// 线路与连接（2.4.0 设置拆分段）：原全量 /settings 的「链路检测与线路
/// 切换」节整节搬入独立页，代码原样搬移零逻辑改动。检测/切换链不变：
/// GET /api/routes → probeRoutes 本地探测 → useLinkRoute 切换（下次打开
/// 直走新线）。Web 出处 linkCheckPage :1368-1386。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/config.dart';
import '../../core/theme/tokens.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'settings_state.dart';

class LinksPage extends ConsumerStatefulWidget {
  const LinksPage({super.key});

  @override
  ConsumerState<LinksPage> createState() => _LinksPageState();
}

class _LinksPageState extends ConsumerState<LinksPage> {
  List<LinkRoute> _routes = const <LinkRoute>[];
  List<LinkProbeResult> _probes = const <LinkProbeResult>[];
  bool _probing = false;
  bool _routesLoaded = false;
  String? _currentBase;

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadRoutes);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final best = fastestRoute(_probes);
    return Scaffold(
      appBar: AppBar(title: const Text('线路与连接')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('看看现在哪条线路最快，也可以手动切换。',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: Spacing.gap),
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
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
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
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
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
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: cs.primary),
                          ),
                        ),
                      if (row.current)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text(
                            '当前',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: cs.outline),
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
            const SizedBox(height: Spacing.gap),
            Text(
              '检测在手机本地直接发起，数值是访问 /api/status 的往返耗时。'
              '在这里切换后，下次打开 App 会直接走这条线路。',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: cs.outline),
            ),
          ],
        ),
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
      ref.read(chatToastProvider.notifier).show(
            alive > 0
                ? '检测完成，$alive/${rows.length} 条线路可用'
                : '所有线路都没连上，检查一下网络',
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
}
