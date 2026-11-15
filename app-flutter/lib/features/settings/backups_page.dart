/// 「数据管理与通知渠道」章 · 段 C · 2.2.7 / VC227：完整备份与存储占用页。
///
/// 结构逐项对齐 Web `app.js:1500` `backupsPage()`：
/// heading「让回忆，有一个安心的家」/「完整备份、迁移和恢复。」→「立即备份」
/// 按钮（`_busy` 期间禁用 + 「备份中…」）→ 存储占用卡（三格 + 三类媒体条
/// + meta 行）→ hint 逐字 → 备份列表卡（名称/加密标记/时间/大小/下载）。
///
/// 🔴 D5：恢复**只放说明文案，不放按钮、不做假入口**（后端无 HTTP 恢复
/// 端点）；页面里没有任何 restore 请求、没有「恢复」可点控件。
///
/// 🔴 数字纪律：存储卡所有数字**只呈现服务端下发值**（`backups_api.dart`
/// `StorageUsage.fromJson`），不估算/不补算；POST 成功后重拉列表确认新
/// 备份出现（同时重拉 storage 反映服务端下发的新占用）。
///
/// 错误通道：GET 4xx 原文页面内呈现；POST 503/403、下载 4xx 原文走顶部
/// error 通知，均不假成功、不刷列表。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/timeline/timeline_data.dart' show timelineDateLabel;
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'backups_api.dart';

class BackupsPage extends ConsumerStatefulWidget {
  const BackupsPage({super.key});

  @override
  ConsumerState<BackupsPage> createState() => _BackupsPageState();
}

class _BackupsPageState extends ConsumerState<BackupsPage> {
  StorageUsage? _storage;
  List<BackupItem>? _backups;
  bool _loading = true;
  String? _error;
  bool _busy = false;
  String? _downloading;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Dio> _dio() => ref.read(api.dioProvider.future);

  /// 重拉 storage + backups（初始加载 / 下拉刷新 / POST 成功后）。
  /// 任一 GET 4xx → `_error` 呈现服务端 detail **原文**，不呈现假数据。
  Future<void> _load() async {
    final dio = await _dio();
    final (storage, sErr) = await fetchStorage(dio);
    final (backups, bErr) = await fetchBackups(dio);
    if (!mounted) return;
    setState(() {
      _loading = false;
      final err = sErr ?? bErr;
      if (err != null) {
        _error = err;
      } else {
        _error = null;
        _storage = storage;
        _backups = backups;
      }
    });
  }

  /// 「立即备份」：`_busy` 防重入；POST 503/403 原文 error 通知、不刷列表；
  /// 成功 → 重拉列表（+storage）确认新备份出现，success 通知。
  Future<void> _createBackup() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final (name, err) = await createBackup(await _dio());
      if (!mounted) return;
      if (err != null) {
        ref
            .read(chatToastProvider.notifier)
            .show(err, tone: ChatToastTone.error);
        return;
      }
      // 成功：重拉列表确认新备份出现（storage 一并重拉，只呈现服务端下发值）
      await _load();
      if (!mounted) return;
      ref
          .read(chatToastProvider.notifier)
          .show('备份已创建：${name ?? ''}', tone: ChatToastTone.success);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 单份备份下载：复用段 B 落盘范式（`downloadBackup`）；下载中防连点；
  /// 成功/失败都走顶部通知（同款「已保存到本地：downloads/<文件名>」）。
  Future<void> _download(BackupItem item) async {
    if (_downloading != null) return;
    setState(() => _downloading = item.name);
    try {
      final (saved, err) = await downloadBackup(await _dio(), item.name);
      if (!mounted) return;
      if (err != null) {
        ref
            .read(chatToastProvider.notifier)
            .show(err, tone: ChatToastTone.error);
        return;
      }
      ref.read(chatToastProvider.notifier).show(
            '已保存到本地：downloads/${saved!.filename}',
            tone: ChatToastTone.success,
          );
    } finally {
      if (mounted) setState(() => _downloading = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // automaticallyImplyLeading 不关 → AppBar 自动返回 + 系统手势可回
      appBar: AppBar(title: const Text(backupsPageTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return ListView(
        children: const <Widget>[
          SizedBox(height: 160),
          Center(child: CircularProgressIndicator()),
        ],
      );
    }
    if (_error != null) {
      return ListView(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _error!,
              key: const Key('backups-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      );
    }
    final s = _storage!;
    final items = _backups ?? const <BackupItem>[];
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text(backupsHeading, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(backupsSubtitle, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 14),
        FilledButton.icon(
          key: const Key('backups-now'),
          onPressed: _busy ? null : _createBackup,
          icon: const Icon(Icons.backup_outlined, size: 20),
          label: Text(_busy ? backupBusyLabel : backupNowLabel),
        ),
        const SizedBox(height: 16),
        _storageCard(context, s),
        const SizedBox(height: 12),
        Text(
          backupsHint,
          key: const Key('backups-hint'),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        _backupsCard(context, items),
      ],
    );
  }

  Widget _storageCard(BuildContext context, StorageUsage s) {
    final theme = Theme.of(context);
    final kinds = <String, num>{
      'image': s.imageBytes,
      'video': s.videoBytes,
      'audio': s.audioBytes,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('存储占用', style: theme.textTheme.titleMedium),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                _stat(context, 'backups-stat-used', '已使用',
                    formatStorageSize(s.total)),
                _stat(context, 'backups-stat-free', '可用空间',
                    formatStorageSize(s.diskFree)),
                _stat(context, 'backups-stat-pct', '磁盘占用率',
                    '${storageUsedPercent(s.diskFree, s.diskTotal)}%'),
              ],
            ),
            const SizedBox(height: 16),
            for (final entry in kinds.entries)
              _mediaBar(
                context,
                entry.key,
                mediaKindLabels[entry.key]!,
                entry.value,
                s.mediaTotal,
              ),
            const SizedBox(height: 10),
            Text(
              storageMetaLine(s),
              key: const Key('backups-meta'),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(
    BuildContext context,
    String key,
    String label,
    String value,
  ) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        key: Key(key),
        children: <Widget>[
          Text(value,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(label, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }

  Widget _mediaBar(
    BuildContext context,
    String key,
    String label,
    num value,
    num mediaTotal,
  ) {
    final pct = mediaKindPercent(value, mediaTotal);
    return Padding(
      key: Key('backups-media-$key'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          SizedBox(width: 40, child: Text(label)),
          Expanded(
            child: LinearProgressIndicator(
              value: pct / 100,
              minHeight: 8,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 76,
            child: Text(
              formatStorageSize(value),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _backupsCard(BuildContext context, List<BackupItem> items) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: items.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: <Widget>[
                    Text(backupsEmptyTitle, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(backupsEmptySubtitle,
                        style: theme.textTheme.bodySmall),
                  ],
                ),
              )
            : Column(
                children: <Widget>[
                  for (final b in items) _backupTile(context, b),
                ],
              ),
      ),
    );
  }

  Widget _backupTile(BuildContext context, BackupItem b) {
    final downloading = _downloading == b.name;
    return ListTile(
      key: Key('backups-item-${b.name}'),
      title: Row(
        children: <Widget>[
          Flexible(child: Text(b.name)),
          if (b.encrypted)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                '🔒 已加密',
                key: Key('backups-encrypted-${b.name}'),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
        ],
      ),
      subtitle: Text('${timelineDateLabel(b.created)} · ${formatBackupSize(b.size)}'),
      trailing: TextButton(
        key: Key('backups-download-${b.name}'),
        onPressed: _downloading != null ? null : () => _download(b),
        child: Text(downloading ? '下载中…' : '下载'),
      ),
    );
  }
}
