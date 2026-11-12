/// 账号资料页（阶段 2 · 账号，对齐 Web profileForm + inviteModal + 账号菜单）：
/// · 昵称 / 头像 / 改密码（PUT /api/profile；改密成功服务端立即失效会话 → 回登录页）
/// · 未绑定两人时：生成邀请（POST /api/invite）展示专属链接 + 复制（仅一次、24h 有效）
/// · 已绑定时：显示两人的卡片
/// · 退出登录（POST /api/logout + 客户端全清理）
/// 头像显示与 Web avatar() 一致：无头像时显示昵称首字。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/api/api_client.dart';
import '../../core/chat/chat_media.dart' show chatBaseProvider;
import '../auth/auth_state.dart';
import '../chat/voice_diag.dart';

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
  bool _inviting = false;
  String? _inviteUrl;       // 生成的邀请链接
  String? _error;
  String? _notice;

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

  Future<void> _pickAvatar() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery, maxWidth: 1024, imageQuality: 85);
      if (picked == null) return;
      setState(() { _busy = true; _error = null; });
      final bytes = await picked.readAsBytes();
      final dio = await ref.read(dioProvider.future);
      final mid = await uploadMedia(dio, picked.name, bytes);
      if (!mounted) return;
      setState(() {
        _pendingAvatarId = mid;
        _avatarBytes = Uint8List.fromList(bytes); // 本地即时预览（无需等服务端转码）
      });
    } catch (e) {
      if (mounted) setState(() => _error = '头像上传失败，可重试后重新保存');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) { setState(() => _error = '昵称不能为空'); return; }
    setState(() { _busy = true; _error = null; _notice = null; });
    final err = await ref.read(authProvider.notifier).updateProfile(
          name: name,
          avatarId: _pendingAvatarId ?? (_avatarId?.isEmpty == true ? '' : null),
          oldPassword: _oldPw.text,
          newPassword: _newPw.text,
        );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err == null) {
      setState(() {
        _notice = '已保存';
        if (_pendingAvatarId != null) _avatarId = _pendingAvatarId;
        _pendingAvatarId = null;
        _oldPw.clear();
        _newPw.clear();
      });
      if (_avatarId != null && _avatarId!.isNotEmpty) _loadAvatar();
    } else if (err == 'RELOGIN') {
      // 改密成功：会话已失效，路由 redirect 自动送回登录页（authed→out）
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('密码已修改，请用新密码重新登录')));
      }
    } else {
      setState(() => _error = err);
    }
  }

  Future<void> _createInvite() async {
    setState(() { _inviting = true; _error = null; });
    final (token, err) = await ref.read(authProvider.notifier).createInvite();
    if (!mounted) return;
    setState(() => _inviting = false);
    if (err != null) { setState(() => _error = err); return; }
    final base = await ref.read(baseProvider.future);
    setState(() => _inviteUrl = '$base/?invite=${Uri.encodeComponent(token ?? '')}');
  }

  Future<void> _copyInvite() async {
    if (_inviteUrl == null) return;
    await Clipboard.setData(ClipboardData(text: _inviteUrl!));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('邀请链接已复制，私下发给 TA')));
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
    final messenger = ScaffoldMessenger.of(context);
    if (records.isEmpty) {
      if (mounted) {
        messenger.showSnackBar(const SnackBar(
            content: Text('暂无语音诊断记录，请先去聊天里点一条语音 / 等语音秒数加载')));
      }
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
                        const SizedBox(height: 8),
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
                        const SizedBox(height: 8),
                        Text('最近一次完整异常原文（含 HTTP 状态码，未截断）：',
                            style: theme.textTheme.bodySmall),
                        const SizedBox(height: 4),
                        SelectableText(
                            records.first.exception,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(fontFamily: 'monospace')),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(
                                  text: records.first.exception));
                              if (mounted) {
                                messenger.showSnackBar(const SnackBar(
                                    content: Text('已复制最近一次异常原文')));
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
    final messenger = ScaffoldMessenger.of(context);
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
            const SizedBox(height: 8),
            SelectableText(r.detail,
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontFamily: 'monospace')),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: r.detail));
                  if (mounted) {
                    messenger.showSnackBar(
                        const SnackBar(content: Text('已复制该条诊断详情')));
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

    return Scaffold(
      appBar: AppBar(title: const Text('账号资料')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── 头像 + 昵称 ──
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                GestureDetector(
                  onTap: _busy ? null : _pickAvatar,
                  child: Stack(children: [
                    _Avatar(bytes: _avatarBytes, name: me.user.name, size: 88),
                    Positioned(right: 0, bottom: 0, child: CircleAvatar(
                      radius: 14, backgroundColor: theme.colorScheme.primary,
                      child: const Icon(Icons.edit, size: 14, color: Colors.white))),
                  ]),
                ),
                const SizedBox(height: 6),
                Text('点击更换头像', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                const SizedBox(height: 14),
                TextField(
                  controller: _name,
                  maxLength: 30,
                  decoration: const InputDecoration(labelText: '昵称',
                      hintText: '让 TA 一眼认出你', counterText: ''),
                ),
              ]),
            ),
          ),
          // ── 修改密码 ──
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('修改密码', style: theme.textTheme.titleSmall),
                const SizedBox(height: 10),
                TextField(
                  controller: _oldPw, obscureText: true,
                  decoration: const InputDecoration(labelText: '原密码（修改密码时填写）'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _newPw, obscureText: true,
                  decoration: const InputDecoration(labelText: '新密码（不修改请留空）',
                      hintText: '至少 10 个字符'),
                ),
              ]),
            ),
          ),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: _busy
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('保存'),
          ),
          if (_notice != null) ...[
            const SizedBox(height: 8),
            Text(_notice!, textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.primary)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 16),
          // ── 邀请 / 两人卡片 ──
          if (!me.paired)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('邀请你，住进我的小世界', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Text('生成专属邀请链接，私下发给另一半。邀请仅可使用一次，二十四小时内有效；重新生成会让旧链接失效。',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _inviting ? null : _createInvite,
                    child: _inviting
                        ? const SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('生成邀请链接'),
                  ),
                  if (_inviteUrl != null) ...[
                    const SizedBox(height: 12),
                    TextField(
                      readOnly: true,
                      controller: TextEditingController(text: _inviteUrl),
                      decoration: const InputDecoration(labelText: '专属邀请链接'),
                    ),
                    const SizedBox(height: 10),
                    FilledButton.tonal(onPressed: _copyInvite, child: const Text('复制邀请链接')),
                  ],
                ]),
              ),
            )
          else
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
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
            final messenger = ScaffoldMessenger.of(context);
            return Card(
              child: ListTile(
                leading: const Icon(Icons.bug_report),
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
                          messenger.showSnackBar(const SnackBar(
                              content: Text('已复制最近一次诊断详情')));
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
    );
  }
}

/// 头像：有图显示图，无图显示昵称首字（与 Web avatar() 行为一致）
class _Avatar extends StatelessWidget {
  const _Avatar({this.bytes, required this.name, this.size = 40});
  final Uint8List? bytes;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (bytes != null) {
      return ClipOval(
        child: Image.memory(bytes!, width: size, height: size, fit: BoxFit.cover,
            gaplessPlayback: true),
      );
    }
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: theme.colorScheme.primaryContainer,
      child: Text(name.isEmpty ? '?' : name.characters.first,
          style: TextStyle(fontSize: size * 0.38, color: theme.colorScheme.onPrimaryContainer)),
    );
  }
}

class _PersonLine extends StatelessWidget {
  const _PersonLine({required this.user});
  final SpaceUser user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(children: [
      _Avatar(name: user.name, size: 44),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(user.name, style: theme.textTheme.titleSmall),
        Text('@${user.username}${user.admin ? ' · 管理员' : ''}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
      ])),
    ]);
  }
}
