/// 登录页（脚手架阶段 1：真实登录，直接落地 auth_probe 结论——
/// Cookie 由共享 jar 管理、X-Love-Space 由拦截器注入，页面只管表单与文案）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_state.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (!_form.currentState!.validate() || _busy) return;
    setState(() { _busy = true; _error = null; });
    final err = await ref.read(authProvider.notifier).login(
          _username.text.trim(), _password.text,
        );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) setState(() => _error = err);
    // 成功后 authProvider 状态变化由路由 redirect 送进主框架
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  Text('恋爱空间', textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 4),
                  Text('把喜欢，写进每一天', textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline)),
                  const SizedBox(height: 30),
                  TextFormField(
                    controller: _username,
                    decoration: const InputDecoration(labelText: '用户名'),
                    autofillHints: const [AutofillHints.username],
                    validator: (v) => (v == null || v.trim().isEmpty) ? '输入用户名' : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '密码'),
                    autofillHints: const [AutofillHints.password],
                    onFieldSubmitted: (_) => _submit(),
                    validator: (v) => (v == null || v.isEmpty) ? '输入密码' : null,
                  ),
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('登录'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center,
                        style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: _busy ? null : () {
                      setState(() => _busy = true);
                      ref.read(authProvider.notifier).retryBootstrap().whenComplete(
                          () { if (mounted) setState(() => _busy = false); });
                    },
                    child: const Text('网络不稳？重试免登录恢复'),
                  ),
                  const SizedBox(height: 12),
                  Text('还没有空间？初始化与邀请绑定在「阶段 2 · 账号」接入',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
