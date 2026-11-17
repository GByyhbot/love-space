/// 数据导出（2.4.0 设置拆分段）：原全量 /settings 的「数据管理」节整节
/// 搬入独立页，代码原样搬移零逻辑改动。三行导出共用限流桶（统一忙碌态
/// 防连撞 429）；下载落 downloads/ + 顶部通知报文件名；4xx 原文透传。
/// 原 admin「备份」行按主人裁定不随迁——备份入口统一挂设置主页。
/// Web 出处 settingsPage 数据管理卡 app.js:1481-1482。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/theme/tokens.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'export_api.dart';

class ExportPage extends ConsumerStatefulWidget {
  const ExportPage({super.key});

  @override
  ConsumerState<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends ConsumerState<ExportPage> {
  // 🔴 全卡统一忙碌态：三个导出共用服务端限流桶（records/markdown 共用
  // rate_limit('export',10,300)、ics 无限流），任一在途时全卡禁用，
  // 避免连撞 429，也天然做到单按钮防重入。
  bool _exportBusy = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final busy = _exportBusy;
    Widget row(
      ExportKind kind,
      String key,
      String label,
      IconData icon,
    ) =>
        ListTile(
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
    return Scaffold(
      appBar: AppBar(title: const Text('数据导出')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.cardPad),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(exportCardTitle,
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 10),
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
              ),
            ),
          ],
        ),
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
}
