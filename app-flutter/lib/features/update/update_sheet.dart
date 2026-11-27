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
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../../core/api/api_client.dart' show dioProvider;
import '../../core/theme/tokens.dart';
import '../../core/theme/typography.dart';
import '../chat/chat_toast.dart' show chatToastProvider;
import 'update_service.dart';
import 'update_trace.dart';
import 'sha256_verifier.dart';

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
            BorderRadius.vertical(top: Radius.circular(AppRadius.xl))),
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
  String _channelStatus = ''; // 慢速自动切换状态字（弹窗内一行，不弹 toast）
  CancelToken? _cancel;
  File? _apkFile;

  /// 本次更新的全链路快照（失败时一键复制给排障用）
  final UpdateTrace _trace = UpdateTrace(
      traceId: DateTime.now().millisecondsSinceEpoch.toRadixString(36));

  /// 失败主区域的简明原因（与 toast 解耦：这里要常驻可见）
  String _failureText = '';

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
      // 期望校验值**先取**：取不到就不下 28MB，直接 fail-closed
      final expected = await resolveExpectedSha256(dio, asset);
      final shaSource = asset.digestHex != null
          ? 'api_field'
          : (expected != null ? 'sha256_asset' : 'none');
      _trace.check['targetVersion'] = widget.release.appVersion;
      _trace.check['selectedAssetName'] = asset.name;
      _trace.currentVersion = _trace.currentVersion.isEmpty
          ? widget.release.appVersion
          : _trace.currentVersion;
      if (expected == null) {
        _failWith('verify', '未获取到安装包校验值（来源：$shaSource）');
        return;
      }
      _cancel = CancelToken();
      final outcome = await downloadApk(dio, asset, target,
          trace: _trace,
          expectedSha: expected,
          shaSource: shaSource,
          onVerifying: () {
            if (mounted) setState(() => _phase = _Phase.verifying);
          },
          onProgress: (received, total) {
        if (mounted) {
          setState(() {
            _received = received;
            _total = total;
          });
        }
      }, onChannelChange: (label) {
        // 2.4.5 乙组：慢速自动切换/通道切换 → 弹窗内一行状态字（不关弹窗、
        // 进度从头计、不弹 toast）
        if (mounted) {
          setState(() {
            _received = 0;
            _total = 0;
            _channel = label;
            _channelStatus = label.startsWith('当前线路较慢') ||
                    label.startsWith('所有线路均较慢')
                ? label
                : '';
          });
        }
      }, cancelToken: _cancel);
      if (!mounted) return;
      setState(() {
        _apkFile = outcome.file;
        _channel = outcome.channelUsed;
        _phase = _Phase.readyToInstall;
      });
      await _install();
    } on PackageVerifyException catch (e) {
      _failWith('verify',
          '安装包校验失败（期望 ${shortSha(e.expected)} / 实际 ${shortSha(e.actual)}，'
          '大小 ${humanSize(e.size)}）');
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
    _trace.install
      ..['filePath'] = f.path
      ..['resultType'] = result.type.name
      ..['resultMessage'] = result.message;
    if (!mounted) return;
    if (result.type == ResultType.done) {
      // 安装界面拉起；用户取消系统安装不报错、不 nag
      Navigator.of(context).pop();
    } else {
      // 透出枚举原值：permissionDenied / noAppToOpen / fileNotFound / unknown
      // （旧实现一律提示「允许安装未知应用」，把 FileProvider 失败也说成权限问题）
      _failWith('install', '调起安装失败（ResultType: ${result.type.name}）');
    }
  }

  void _fail(String text) => _failWith('download', text);

  /// 失败统一出口：记 Trace（阶段 + 原因）+ 常驻文案 + 清残包。
  /// 不再只靠 toast —— toast 一闪而过，排障时需要能复查。
  void _failWith(String stage, String text) {
    _cleanupPartial();
    _trace
      ..failedStage = stage
      ..failureReason = text;
    if (!mounted) return;
    setState(() {
      _phase = _Phase.failed;
      _failureText = text;
    });
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
              top: Radius.circular(AppRadius.xl)),
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
          if (_phase == _Phase.failed && _failureText.isNotEmpty) ...[
            const SizedBox(height: Spacing.gap),
            Container(
              key: const Key('update-failure-box'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_failureText, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 6),
                  // 一键复制完整 JSON 快照（含脱敏后的 URL 与每次通道尝试）
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      key: const Key('update-copy-diag'),
                      onPressed: () async {
                        await Clipboard.setData(
                            ClipboardData(text: _trace.toPrettyJson()));
                        if (mounted) _toast('诊断信息已复制');
                      },
                      icon: const Icon(Icons.copy_all, size: 16),
                      label: const Text('复制诊断信息'),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_phase == _Phase.downloading) ...[
            const SizedBox(height: Spacing.gap),
            LinearProgressIndicator(
              value: _total > 0 ? _received / _total : null,
            ),
            const SizedBox(height: 4),
            Text(
              _total > 0
                  ? '${_channel.isEmpty ? '下载中' : _channel} · ${(_received / _total * 100).toStringAsFixed(0)}%（${_sizeLabel(_received)} / ${_sizeLabel(_total)}）'
                  : '${_channel.isEmpty ? '下载中' : _channel} · 连接中…',
              style: AppType.numeric(
                theme,
                base: theme.textTheme.bodySmall,
                color: theme.colorScheme.outline,
              ),
            ),
            if (_channelStatus.isNotEmpty)
              Text(
                _channelStatus,
                key: const Key('update-channel-status'),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.tertiary),
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
