/// 邀请另一半入住（2.4.0 设置拆分段）：设置主页「邀请另一半入住」行的
/// 落点——进入即见可生成/复制邀请链接的界面（InviteCard 共用组件）。
/// 空间已绑定两人时无需邀请，直接展示提示（原落点 /profile 只能滚到
/// 账号页邀请区，按主人裁定「现落点不对一并修正」改为直达界面）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart';
import 'invite_card.dart';

class InvitePage extends ConsumerWidget {
  const InvitePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authProvider.notifier).me;
    final paired = me?.paired ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('邀请另一半入住')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (paired)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('你们已经住在一起啦',
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 8),
                      Text(
                        '这个空间已经有两个人了，不需要再发邀请。想换设备登录，直接用各自的账号就行。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.outline),
                      ),
                    ],
                  ),
                ),
              )
            else
              const InviteCard(),
          ],
        ),
      ),
    );
  }
}
