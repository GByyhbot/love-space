/// 空间信息独立页（2.4.1 修复包第 1 项）：原首页「空间信息」弹窗的字段
/// 原样搬家成独立路由页（/settings/space）——字段不增不减：
/// · 🔴 「空间名称」输入框保持摘除（2.3.7 定案：改了没用），只读展示；
/// · 相恋日期选择（showDatePicker 已中文化）；
/// · 保存走 updateSpace 全量合并（name 固定原样带回 me.spaceName，
///   字段一个不丢），成功顶部 toast 并返回设置主页，失败留在本页、
///   输入保留、toast 透传原文。
/// 首页 hero tap 的编辑入口仍走原弹窗（showSpaceEditDialog，不经
/// spaceEditRequestedProvider——该机制 2.4.1 随设置主页入口改 push 退役）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../../core/theme/tokens.dart';
import '../auth/auth_state.dart';
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import '../../core/ui/submit_morph.dart' show SubmitMorphButton;

class SpaceInfoPage extends ConsumerStatefulWidget {
  const SpaceInfoPage({super.key});

  @override
  ConsumerState<SpaceInfoPage> createState() => _SpaceInfoPageState();
}

class _SpaceInfoPageState extends ConsumerState<SpaceInfoPage> {
  DateTime? _picked;
  bool _saving = false;

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    final me = ref.read(authProvider.notifier).me;
    _picked = me != null && me.spaceSince.isNotEmpty
        ? DateTime.tryParse(me.spaceSince)
        : null;
  }

  /// 保存链与原弹窗逐位等价（updateSpace 全量合并 + reload + 聚合失效），
  /// 返回 null = 成功；非 null = 服务端 detail 原文。
  Future<String?> _save() async {
    final me = ref.read(authProvider.notifier).me;
    final picked = _picked;
    if (me == null || picked == null) return '还没选择相恋日期';
    final dio = await ref.read(api.dioProvider.future);
    // 2.3.7：名称原样带回（输入框已摘除，全量合并口径不破）。
    return api.updateSpace(dio, me.spaceRaw,
        name: me.spaceName, since: _fmtDate(picked));
  }

  // 2.4.10：改返 Future<bool> 供三连变真实请求驱动（pop 归 onSuccess）。
  Future<bool> _onSave() async {
    if (_saving) return false;
    setState(() => _saving = true);
    try {
      final err = await _save();
      if (!mounted) return false;
      if (err != null) {
        // 失败：留在本页、输入保留、toast 报原文。
        ref
            .read(chatToastProvider.notifier)
            .show('保存失败：$err', tone: ChatToastTone.error);
        return false;
      }
      // me（space 原样对象）与聚合数据全部失效重拉（与原弹窗一致）。
      await ref.read(authProvider.notifier).reload();
      ref.invalidate(api.recordsProvider);
      ref.invalidate(api.dashboardProvider);
      ref.read(chatToastProvider.notifier).show('空间信息保存好了');
      return true;
    } catch (e) {
      if (mounted) {
        ref
            .read(chatToastProvider.notifier)
            .show('保存失败：${api.errorDetail(e)}', tone: ChatToastTone.error);
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final me = ref.watch(authProvider.notifier).me;
    final picked = _picked;
    return Scaffold(
      appBar: AppBar(title: const Text('空间信息')),
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
                    // 2.3.7：空间名称输入框保持摘除（只读展示，不可在此改）。
                    Row(
                      children: [
                        Text('空间名称',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: cs.outline)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(me?.spaceName ?? '…',
                              style: theme.textTheme.bodyLarge),
                        ),
                      ],
                    ),
                    const SizedBox(height: Spacing.lg),
                    // 相恋日期：字段原样搬（选日期按钮 + 当前值文案）。
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            picked == null
                                ? '还没选择相恋日期'
                                : '从 ${_fmtDate(picked)} 开始相爱',
                          ),
                        ),
                        TextButton(
                          key: const Key('space-info-pick'),
                          onPressed: () async {
                            final d = await showDatePicker(
                              context: context,
                              initialDate: picked ?? DateTime.now(),
                              firstDate: DateTime(2000),
                              lastDate: DateTime.now(),
                            );
                            if (d != null) setState(() => _picked = d);
                          },
                          child: const Text('选日期'),
                        ),
                      ],
                    ),
                    const SizedBox(height: Spacing.xs),
                    Text(
                      '日期决定首页「在一起第几天」从哪天算起。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.outline),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // 2.4.10：保存走三连变（对勾驻留后 pop）。
            SubmitMorphButton(
              key: const Key('space-info-save'),
              label: '保存',
                onSubmit: () async => picked != null && await _onSave(),
              onSuccess: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}
