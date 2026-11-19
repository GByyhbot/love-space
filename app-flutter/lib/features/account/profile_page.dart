/// 账号资料页（阶段 2 · 账号，对齐 Web profileForm + inviteModal + 账号菜单）：
/// · 昵称 / 头像 / 改密码（PUT /api/profile；改密成功服务端立即失效会话 → 回登录页）
/// · 未绑定两人时：生成邀请（POST /api/invite）展示专属链接 + 复制（仅一次、24h 有效）
/// · 已绑定时：显示两人的卡片
/// · 退出登录（POST /api/logout + 客户端全清理）
/// 头像显示与 Web avatar() 一致：无头像时显示昵称首字。
library;

import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/api/api_client.dart';
import '../../core/chat/chat_media.dart' show chatBaseProvider;
import '../../core/ui/avatar_media.dart';
import '../../core/ui/error_view.dart';
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../chat/voice_diag.dart';
import '../settings/settings_widgets.dart'
    show SettingsGlassBar, filledFieldDecoration;
import '../settings/invite_card.dart';
import '../../core/theme/tokens.dart';

class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  late final TextEditingController _name;
  final _oldPw = TextEditingController();
  final _newPw = TextEditingController();
  String? _avatarId;        // 当前头像媒体 id（''=无头像）
  String? _pendingAvatarId; // 本次已上传待保存的头像 id
  Uint8List? _avatarBytes;  // 头像预览字节
  bool _busy = false;
  String? _error;

  // 实际安装包版本（取自 PackageInfo，不写死）—— 诊断页/页脚共用
  String _pkgVersion = '';
  String _pkgBuild = '';
  String get _appVersionLabel =>
      _pkgVersion.isEmpty ? '版本加载中…' : 'v$_pkgVersion ($_pkgBuild)';

  @override
  void initState() {
    super.initState();
    final me = ref.read(authProvider.notifier).me;
    _name = TextEditingController(text: me?.user.name ?? '');
    _avatarId = me?.user.avatar ?? '';
    _loadAvatar();
    _loadPackageInfo();
  }

  /// 读取实际安装包版本（versionName + buildNumber），供页脚与诊断页展示
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
      // 读取失败时保留空值，UI 显示「版本加载中…」而非崩溃
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _oldPw.dispose();
    _newPw.dispose();
    super.dispose();
  }

  /// 头像字节走共享 dio（Cookie 自动附带）；失败静默回退首字头像
  Future<void> _loadAvatar() async {
    final id = _pendingAvatarId ?? _avatarId;
    if (id == null || id.isEmpty) return;
    try {
      final dio = await ref.read(dioProvider.future);
      final bytes = await fetchMediaBytes(dio, id);
      if (mounted) setState(() => _avatarBytes = Uint8List.fromList(bytes));
    } catch (_) {}
  }

  // 2.4.10 第 05 项：上传进度态（与资料保存的 _busy 拆分）。
  double? _uploadProgress; // null=空闲；0..1（ease-out 映射后）
  bool _uploadReady = false; // 填满后「全部准备就绪」交叉淡出期
  bool _showCompleteArc = false; // 阶段二：新头像外圈完成弧

  Future<void> _pickAvatar() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery, maxWidth: 1024, imageQuality: 85);
      if (picked == null) return;
      setState(() {
        _busy = true;
        _uploadProgress = 0;
        _uploadReady = false;
        _error = null;
      });
      final bytes = await picked.readAsBytes();
      final dio = await ref.read(dioProvider.future);
      final mid = await uploadMedia(dio, picked.name, bytes,
          // 真实字节进度，ease-out 映射（先快后慢，提示词钦定节奏）。
          onProgress: (p) {
        if (mounted) {
          setState(() => _uploadProgress = Curves.easeOut.transform(p));
        }
      });
      if (!mounted) return;
      setState(() {
        _pendingAvatarId = mid;
        _avatarBytes = Uint8List.fromList(bytes); // 本地即时预览（无需等服务端转码）
        _uploadReady = true; // 「正在上传头像」↔「全部准备就绪」交叉淡出
      });
      // 阶段一收尾驻留一拍，随后溶解过渡回账号页 + 新头像完成弧。
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted) return;
      setState(() {
        _busy = false;
        _uploadProgress = null;
        _uploadReady = false;
        _showCompleteArc = true;
      });
      // 完成弧 0→100% + 数字同步，画完整体淡出（动画时长在 widget 内）。
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      if (mounted) setState(() => _showCompleteArc = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '头像上传失败，可重试后重新保存';
          _uploadProgress = null;
          _uploadReady = false;
          _busy = false;
        });
        ref.read(chatToastProvider.notifier).show(
            '头像上传失败，可重试后重新保存', tone: ChatToastTone.error);
      }
    }
  }

  // 2.4.10：改返 Future<bool> 供三连变真实请求驱动（RELOGIN 分支属成功路径）。
  Future<bool> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) { setState(() => _error = '昵称不能为空'); return false; }
    setState(() { _busy = true; _error = null; });
    final err = await ref.read(authProvider.notifier).updateProfile(
          name: name,
          avatarId: _pendingAvatarId ?? (_avatarId?.isEmpty == true ? '' : null),
          oldPassword: _oldPw.text,
          newPassword: _newPw.text,
        );
    if (!mounted) return false;
    setState(() => _busy = false);
    if (err == null) {
      setState(() {
        if (_pendingAvatarId != null) _avatarId = _pendingAvatarId;
        _pendingAvatarId = null;
        _oldPw.clear();
        _newPw.clear();
      });
      // 保存成功：统一走顶部通知（全局宿主），不再只显示在按钮下方行内
      ref.read(chatToastProvider.notifier).show(
          '已保存', tone: ChatToastTone.success);
      if (_avatarId != null && _avatarId!.isNotEmpty) _loadAvatar();
      return true;
    } else if (err == 'RELOGIN') {
      // 改密成功：会话已失效，路由 redirect 自动送回登录页（authed→out）
      ref.read(chatToastProvider.notifier).show(
          '密码已修改，请用新密码重新登录', tone: ChatToastTone.success);
      return true;
    } else {
      // 服务端失败：行内保留 + 顶部通知（字段级校验「昵称不能为空」只走行内，不在此分支）
      setState(() => _error = err);
      ref.read(chatToastProvider.notifier).show(err, tone: ChatToastTone.error);
      return false;
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要暂时离开我们的小世界吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('再想想')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认')),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref.read(authProvider.notifier).logout();
    }
  }

  Future<void> _openVoiceDiag() async {
    final theme = Theme.of(context);
    final records = ref.read(voiceDiagProvider);
    final base = ref.read(chatBaseProvider).value;
    if (records.isEmpty) {
      ref.read(chatToastProvider.notifier).show(
          '暂无语音诊断记录，请先去聊天里点一条语音 / 等语音秒数加载',
          tone: ChatToastTone.info);
      return;
    }
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('语音诊断'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── 头部：实际安装包版本 + 当前线路 base ──
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('App 版本（实际安装包）：$_appVersionLabel',
                            style: theme.textTheme.bodySmall),
                        const SizedBox(height: Spacing.gap),
                        Text('当前线路 base（原样完整域名）：',
                            style: theme.textTheme.bodySmall),
                        SelectableText(
                            base ?? '(base 未解析)',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(fontFamily: 'monospace')),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // ── 最近一次完整异常原文（未截断、未改写）──
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(children: [
                          Chip(label: Text(records.first.kind)),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(records.first.summary,
                                  style: theme.textTheme.bodySmall)),
                        ]),
                        const SizedBox(height: Spacing.gap),
                        Text('最近一次完整异常原文（含 HTTP 状态码，未截断）：',
                            style: theme.textTheme.bodySmall),
                        const SizedBox(height: 4),
                        SelectableText(
                            records.first.exception,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(fontFamily: 'monospace')),
                        const SizedBox(height: Spacing.gap),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(
                                  text: records.first.exception));
                              if (mounted) {
                                ref.read(chatToastProvider.notifier).show(
                                    '已复制最近一次异常原文',
                                    tone: ChatToastTone.success);
                              }
                            },
                            icon: const Icon(Icons.copy, size: 16),
                            label: const Text('复制异常'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '全部失败记录（最新在上）。点「复制」可复制完整原文发给开发者；长按正文也可选择复制。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                for (final r in records) ...[
                  _diagCard(r),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => ref.read(voiceDiagProvider.notifier).clear(),
            child: const Text('清空记录'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _diagCard(VoiceDiagRecord r) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Chip(label: Text(r.kind)),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(r.summary,
                      style: theme.textTheme.bodySmall)),
            ]),
            const SizedBox(height: Spacing.gap),
            SelectableText(r.detail,
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontFamily: 'monospace')),
            const SizedBox(height: Spacing.gap),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: r.detail));
                  if (mounted) {
                    ref.read(chatToastProvider.notifier).show(
                        '已复制该条诊断详情', tone: ChatToastTone.success);
                  }
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = ref.watch(authProvider.notifier).me;
    if (me == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final partner = me.users.where((u) => u.id != me.user.id).toList();

    // 2.4.1 第 5 项：身份卡（大头像 + 编辑徽标 + 昵称 + 身份 chip）
    // + 圆角填充输入 + 底部玻璃操作栏（整行保存）。
    final roleLabel = me.user.admin ? '管理员' : '成员';
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(title: const Text('账号资料')),
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                  16, 12, 16, SettingsGlassBar.barReserveHeight + 12),
              children: [
          // ── 身份卡（头像 + 编辑徽标 + 昵称 + 身份 chip） ──
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Spacing.cardPad),
              child: Column(children: [
                GestureDetector(
                  onTap: _busy ? null : _pickAvatar,
                  child: Stack(children: [
                    // 2.4.10 阶段二：溶解过渡（缩放 1.04→1，约 0.5s）。
                    TweenAnimationBuilder<double>(
                      key: ValueKey(_showCompleteArc),
                      tween: Tween(
                          begin: _showCompleteArc ? 1.04 : 1.0, end: 1.0),
                      duration: _showCompleteArc
                          ? const Duration(milliseconds: 500)
                          : Duration.zero,
                      curve: Curves.easeOut,
                      builder: (context, scale, child) => Transform.scale(
                          scale: scale, child: child),
                      child: _Avatar(
                        bytes: _avatarBytes,
                        name: me.user.name,
                        size: 88,
                        avatarId: _pendingAvatarId ?? _avatarId ?? '',
                      ),
                    ),
                    // 2.4.10 阶段二：完成弧（底环细环 + 强调弧 12 点顺时针
                    // 画到 100%、端点圆头，环内百分比数字同步；画完淡出）。
                    if (_showCompleteArc)
                      Positioned.fill(
                        child: AnimatedOpacity(
                          opacity: 1,
                          duration: const Duration(milliseconds: 300),
                          child: const _AvatarCompleteArc(size: 88),
                        ),
                      ),
                    Positioned(right: 0, bottom: 0, child: CircleAvatar(
                      radius: 14, backgroundColor: theme.colorScheme.primary,
                      child: const Icon(Icons.edit, size: 14, color: Colors.white))),
                  ]),
                ),
                const SizedBox(height: Spacing.gap),
                // 2.4.10 阶段一：上传进度呈现（一行小字 + 进度胶囊 240×10）。
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  child: _uploadProgress != null
                      ? _UploadProgressLine(
                          key: const ValueKey('upload-line'),
                          progress: _uploadProgress!,
                          ready: _uploadReady,
                        )
                      : Text('点击更换头像',
                          key: const ValueKey('upload-idle'),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.outline)),
                ),
                const SizedBox(height: 10),
                // 居中昵称 + 身份 chip（@账号名 · 角色）。
                Text(me.user.name, style: theme.textTheme.titleMedium),
                const SizedBox(height: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '@${me.user.username} · $roleLabel',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ),
                const SizedBox(height: 14),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('昵称', style: theme.textTheme.labelSmall),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _name,
                    maxLength: 30,
                    decoration: filledFieldDecoration(hint: '让 TA 一眼认出你'),
                  ),
                ]),
              ]),
            ),
          ),
          // ── 修改密码 ──
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Spacing.cardPad),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('修改密码', style: theme.textTheme.titleSmall),
                const SizedBox(height: 10),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('原密码（修改密码时填写）', style: theme.textTheme.labelSmall),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _oldPw, obscureText: true,
                    decoration: filledFieldDecoration(),
                  ),
                ]),
                const SizedBox(height: 10),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('新密码（不修改请留空）', style: theme.textTheme.labelSmall),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _newPw, obscureText: true,
                    decoration: filledFieldDecoration(hint: '至少 10 个字符'),
                  ),
                ]),
              ]),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: Spacing.gap),
            // G14 收编：裸 TextStyle → 统一行内错误口径（AppErrorText）
            AppErrorText(_error!, textAlign: TextAlign.center),
          ],
          const SizedBox(height: 16),
          // ── 邀请 / 两人卡片（2.4.0：邀请卡抽为 InviteCard 共用组件，
          // 与设置独立邀请页 /settings/invite 同一实现同一数据源） ──
          if (!me.paired) const InviteCard() else Card(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.cardPad),
                child: Column(children: [
                  Text('我们', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 12),
                  _PersonLine(user: me.user),
                  const Divider(height: 24),
                  if (partner.isNotEmpty) _PersonLine(user: partner.first),
                ]),
              ),
            ),
          const SizedBox(height: 16),
          // ── 语音诊断（暴露失败原始异常，免去 logcat）──
          Builder(builder: (ctx) {
            final records = ref.watch(voiceDiagProvider);
            final latest = records.isNotEmpty ? records.first : null;
            return Card(
              child: ListTile(
                // 2.4.1 第 5 项⑤：图标收进淡彩圆角方块底座。
                leading: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.bug_report,
                      size: 20, color: theme.colorScheme.onSecondaryContainer),
                ),
                title: const Text('语音诊断'),
                subtitle: latest == null
                    ? const Text('暂无失败记录')
                    : Text('最近失败：${latest.summary}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openVoiceDiag,
                onLongPress: latest == null
                    ? null
                    : () async {
                        await Clipboard.setData(
                            ClipboardData(text: latest.detail));
                        if (mounted) {
                          ref.read(chatToastProvider.notifier).show(
                              '已复制最近一次诊断详情',
                              tone: ChatToastTone.success);
                        }
                      },
              ),
            );
          }),
          const SizedBox(height: 16),
          // ── 退出登录 ──
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                side: BorderSide(color: theme.colorScheme.error.withValues(alpha: 0.4))),
            onPressed: _logout,
            icon: const Icon(Icons.logout),
            label: const Text('退出登录'),
          ),
          const SizedBox(height: 12),
          // ── 实际安装包版本（取自 PackageInfo，不写死）──
          Text(_appVersionLabel,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 24),
        ],
      ),
          ),
          // 2.4.1 第 5 项③：保存移入底部玻璃操作栏（整行保存）。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SettingsGlassBar(
              saveLabel: '保存',
              // 2.4.10：保存走三连变（真实请求驱动）。
              onSave: () {},
              morphOnSave: _save,
            ),
          ),
        ],
      ),
    );
  }
}

/// 头像：2.3.7 统一路径——刚选的新图（预览字节）优先本地即时显示；
/// 否则走 AvatarMedia（LowFreqCache 落盘缓存 + 鉴权头，顶栏/心情格同一路径，
/// media id 变化才重新拉取）；无图回退昵称首字（与 Web avatar() 一致）。
class _Avatar extends StatelessWidget {
  const _Avatar(
      {this.bytes, required this.name, this.size = 40, this.avatarId = ''});
  final Uint8List? bytes;
  final String name;
  final double size;
  final String avatarId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (bytes != null) {
      return ClipOval(
        child: Image.memory(bytes!, width: size, height: size, fit: BoxFit.cover,
            gaplessPlayback: true),
      );
    }
    if (avatarId.isNotEmpty) {
      return AvatarMedia(avatarId: avatarId, name: name, radius: size / 2);
    }
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: theme.colorScheme.primaryContainer,
      child: Text(name.isEmpty ? '?' : name.characters.first,
          style: TextStyle(fontSize: size * 0.38, color: theme.colorScheme.onPrimaryContainer)),
    );
  }
}

/// 2.4.10 阶段一：上传进度行——小字「正在上传头像」/「全部准备就绪」
/// + 进度胶囊（宽 240 高 10，圆角 999，填充+百分比由真实字节进度驱动）。
class _UploadProgressLine extends StatelessWidget {
  const _UploadProgressLine({
    super.key,
    required this.progress,
    required this.ready,
  });

  final double progress;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        child: Text(
          ready ? '全部准备就绪' : '正在上传头像',
          key: ValueKey(ready),
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: cs.outline),
        ),
      ),
      const SizedBox(height: 6),
      SizedBox(
        width: 240,
        height: 10,
        child: Stack(children: [
          Container(
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          FractionallySizedBox(
            widthFactor: progress.clamp(0.0, 1.0),
            child: Container(
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 4),
      Text('${(progress * 100).round()}%',
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: cs.primary)),
    ]);
  }
}

/// 2.4.10 阶段二：新头像外圈完成弧——底环细环 + 强调弧 12 点顺时针
/// 画到 100%（端点圆头），环内百分比数字同步；画完随宿主淡出。
/// 🔴 提示词定案：App 无对应指标，弧一律画到 100%（上传完成），不自造假百分比。
class _AvatarCompleteArc extends StatelessWidget {
  const _AvatarCompleteArc({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeOut,
      builder: (context, v, _) => CustomPaint(
        size: Size.square(size),
        painter: _CompleteArcPainter(progress: v, track: cs.outlineVariant, arc: cs.primary),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: cs.surface.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '${(v * 100).round()}%',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: cs.primary, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }
}

class _CompleteArcPainter extends CustomPainter {
  const _CompleteArcPainter({
    required this.progress,
    required this.track,
    required this.arc,
  });

  final double progress;
  final Color track;
  final Color arc;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = 3.0;
    final rect = (Offset.zero & size).deflate(stroke);
    canvas.drawArc(rect, 0, 2 * math.pi, false,
        Paint()..style = PaintingStyle.stroke..strokeWidth = stroke..color = track);
    if (progress <= 0) return;
    canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * progress, false,
        Paint()..style = PaintingStyle.stroke..strokeWidth = stroke..strokeCap = StrokeCap.round..color = arc);
  }

  @override
  bool shouldRepaint(_CompleteArcPainter old) => old.progress != progress;
}

class _PersonLine extends StatelessWidget {
  const _PersonLine({required this.user});
  final SpaceUser user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(children: [
      // 2.4.1 第 5 项④ BUG 修复：补传 avatarId → 有照片走 AvatarMedia
      // （low_freq_cache 同源），无照片才回退首字母；原实现漏传恒显首字母。
      _Avatar(name: user.name, size: 44, avatarId: user.avatar),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(user.name, style: theme.textTheme.titleSmall),
        Text('@${user.username}${user.admin ? ' · 管理员' : ''}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
      ])),
    ]);
  }
}
