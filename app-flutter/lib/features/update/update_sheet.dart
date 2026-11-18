/// 更新提示弹层（2.4.3 第 4 项第 7 点）：底部 sheet 套现有设计语言——
/// 新版本号、Release 说明全文（纯文本）、「下载更新」主按钮 +「以后再说」
/// 次按钮；自动检查与手动检查共用本弹层。点「以后再说」本次冷启动不再弹
/// （sessionDeferredVersions，下次冷启动仍可提示）。
///
/// 下载流程（第 4 项第 8/9/10/11 点）：Dio 通道（直连→代理逐个切换）带
/// 进度条（百分比 + 已下载/总量）可取消（删半成品）；下载完成先算本地
/// SHA-256 与 Release 资产 .sha256 对账（校验值只取 GitHub 元数据直连
/// 获取），不一致→立即删文件+错误 toast+禁止进入安装步；一致→open_filex
/// 调起系统安装器（REQUEST_INSTALL_PACKAGES + FileProvider）。安装包落
/// 私有目录 downloads/，文件名带版本号防串版。任何失败 App 照常可用。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:open_filex/open_filex.dart';

import '../../core/api/api_client.dart' show dioProvider;
import '../../core/theme/tokens.dart';
import '../chat/chat_toast.dart' show chatToastProvider;
import 'update_service.dart';

Future<void> showUpdateSheet(
  BuildContext context, {
  required WidgetRef ref,
  required GithubRelease release,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    useSafeArea: true,
    barrierColor: Colors.black54, // 遮罩压暗
    backgroundColor: Colors.transparent,
    shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.lg))),
    builder: (_) => _UpdateSheet(release: release),
  );
}

enum _Phase { idle, downloading, verifying, readyToInstall, failed }

class _UpdateSheet extends ConsumerStatefulWidget {
  const _UpdateSheet({required this.release});

  final GithubRelease release;

  @override
  ConsumerState<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends ConsumerState<_UpdateSheet> {
  _Phase _phase = _Phase.idle;
  int _received = 0;
  int _total = 0;
  String _channel = '';
  CancelToken? _cancel;
  File? _apkFile;

  @override
  void dispose() {
    // 用户中途关 sheet：取消下载并清理半成品（不许堆积）
    if (_phase == _Phase.downloading || _phase == _Phase.verifying) {
      _cancel?.cancel('sheet closed');
    }
    super.dispose();
  }

  void _toast(String text) {
    ref.read(chatToastProvider.notifier).show(text);
  }

  Future<void> _startDownload() async {
    if (_phase == _Phase.downloading) {
      // 二次点「取消下载」
      _cancel?.cancel('user cancel');
      return;
    }
    final asset = widget.release.apkAsset;
    if (asset == null) return;
    setState(() {
      _phase = _Phase.downloading;
      _received = 0;
      _total = 0;
    });
    try {
      final dio = await ref.read(dioProvider.future);
      final target = await apkTargetFile(widget.release.appVersion);
      _cancel = CancelToken();
      final outcome = await downloadApk(dio, asset, target,
          onProgress: (received, total) {
        if (mounted) {
          setState(() {
            _received = received;
            _total = total;
          });
        }
      }, cancelToken: _cancel);
      if (!mounted) return;
      setState(() {
        _apkFile = outcome.file;
        _channel = outcome.channelUsed;
        _phase = _Phase.verifying;
      });
      // ── 验签（硬性）：本地 SHA-256 vs GitHub 元数据 .sha256 ──
      final expected = await fetchSha256(dio, asset);
      final actual = expected == null || !_apkFile!.existsSync()
          ? null
          : crypto
              .sha256
              .convert(await _apkFile!.readAsBytes())
              .toString();
      if (expected == null || actual != expected) {
        // 不一致 → 立即删文件，禁止进入安装步
        if (_apkFile!.existsSync()) _apkFile!.deleteSync();
        setState(() => _phase = _Phase.failed);
        _toast('安装包校验失败，已删除，请稍后重试');
        return;
      }
      if (!mounted) return;
      setState(() => _phase = _Phase.readyToInstall);
      await _install();
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        _cleanupPartial();
        if (mounted) setState(() => _phase = _Phase.idle);
        return; // 用户取消：不报错
      }
      _fail('下载失败，请稍后重试');
    } catch (_) {
      _fail('下载失败，请稍后重试');
    }
  }

  Future<void> _install() async {
    final f = _apkFile;
    if (f == null || !f.existsSync()) return;
    final result = await OpenFilex.open(f.path, type: 'application/vnd.android.package-archive');
    if (!mounted) return;
    if (result.type == ResultType.done) {
      // 安装界面拉起；用户取消系统安装不报错、不 nag
      Navigator.of(context).pop();
    } else {
      _toast('请在系统设置里允许「安装未知应用」后再试');
    }
  }

  void _fail(String text) {
    _cleanupPartial();
    if (mounted) setState(() => _phase = _Phase.failed);
    _toast(text);
  }

  void _cleanupPartial() {
    final f = _apkFile;
    if (f != null && f.existsSync()) f.deleteSync();
  }

  String _sizeLabel(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ver = widget.release.appVersion;
    return Container(
      margin: const EdgeInsets.only(top: 60),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadius.lg)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // 抓手（既有 sheet 家族同款 38×4.5）
          Center(
            child: Container(
              width: 38,
              height: 4.5,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant
                    .withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          Text('发现新版本 v$ver',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: Spacing.gap),
          // Release 说明全文（纯文本）
          Flexible(
            child: SingleChildScrollView(
              child: Text(
                widget.release.body.isEmpty
                    ? '本次更新包含问题修复与体验优化。'
                    : widget.release.body,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
          if (_phase == _Phase.downloading) ...[
            const SizedBox(height: Spacing.gap),
            LinearProgressIndicator(
              value: _total > 0 ? _received / _total : null,
            ),
            const SizedBox(height: 4),
            Text(
              _total > 0
                  ? '$_channel · ${(_received / _total * 100).toStringAsFixed(0)}%（${_sizeLabel(_received)} / ${_sizeLabel(_total)}）'
                  : '$_channel · 连接中…',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
          const SizedBox(height: Spacing.gap),
          Row(children: [
            // 主按钮：下载更新 / 下载中=取消下载
            Expanded(
              child: FilledButton(
                key: Key(_phase == _Phase.downloading
                    ? 'update-cancel'
                    : 'update-download'),
                onPressed:
                    (_phase == _Phase.verifying || _phase == _Phase.readyToInstall)
                        ? null
                        : _startDownload,
                child: Text(
                  _phase == _Phase.downloading
                      ? '取消下载'
                      : (_phase == _Phase.verifying
                          ? '校验中…'
                          : '下载更新'),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 次按钮：以后再说（本次冷启动不再弹；下次冷启动仍可提示）
            Expanded(
              child: OutlinedButton(
                key: const Key('update-later'),
                onPressed: () {
                  sessionDeferredVersions.add(ver);
                  Navigator.of(context).pop();
                },
                child: const Text('以后再说'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
