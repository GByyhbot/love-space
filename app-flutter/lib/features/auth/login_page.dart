/// 认证页（三态，对齐 Web renderAuth）：
/// · setup：空间未初始化（GET /api/status.initialized=false）→ 创建账号（可能要 SETUP_TOKEN）
/// · join：从另一半拿到邀请链接/码 → 注册并绑定（App 无 deep link，改为粘贴邀请链接）
/// · login：常规登录
/// 表单校验与服务端一致：用户名 3-40 位 [a-zA-Z0-9_.@-]、密码 ≥10 位、昵称 ≤30 字。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import 'auth_state.dart';
import '../../core/theme/tokens.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _token = TextEditingController();
  bool _showPw = false; // 2.4.1 第 6 项④：密码显隐（纯客户端，不改校验/提交）
  AuthMode _mode = AuthMode.login;
  bool _tokenRequired = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 未初始化的空间自动切 setup 态（与 Web 一致）；探测失败保持 login 态可手切
    Future.microtask(() async {
      try {
        final status = await ref.read(statusProvider.future);
        if (!status.initialized && mounted) {
          setState(() {
            _mode = AuthMode.setup;
            _tokenRequired = status.setupTokenRequired;
          });
        }
      } catch (_) {/* 探测失败不阻塞登录态 */}
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _password.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate() || _busy) return;
    setState(() { _busy = true; _error = null; });
    // join 支持粘贴完整邀请链接：提取 ?invite= 后的 token（等价 Web 链接直达）
    var token = _token.text.trim();
    if (_mode == AuthMode.join && token.contains('invite=')) {
      token = Uri.tryParse(token)?.queryParameters['invite'] ?? token;
    }
    final err = await ref.read(authProvider.notifier).submitAuth(
          _mode,
          username: _username.text.trim(),
          password: _password.text,
          name: _mode == AuthMode.login ? null : _name.text.trim(),
          token: _mode == AuthMode.join ? token : (_tokenRequired ? token : null),
        );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) setState(() => _error = err);
    // 成功后 authProvider 状态变化由路由 redirect 送进主框架
  }

  String get _title => switch (_mode) {
        AuthMode.setup => '开启我们的小世界',
        AuthMode.join => '赴一场两个人的约定',
        AuthMode.login => '好久不见，亲爱的',
      };

  String get _subtitle => switch (_mode) {
        AuthMode.setup => '先创建你的账号，再邀请另一半入住。',
        AuthMode.join => '你的另一半正在这个小世界里等你。',
        AuthMode.login => '登录，继续书写属于你们的故事。',
      };

  String get _buttonText => switch (_mode) {
        AuthMode.setup => '创建恋爱空间',
        AuthMode.join => '接受邀请，成为我们',
        AuthMode.login => '回到我们的小世界',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final halo = cs.primary;
    return Scaffold(
      body: Stack(children: [
      // 2.4.1 第 6 项①：主题光晕背景——顶部居中 primary 径向光（低透明度）
      // + 右上玫红余光；深浅两档底色随主题（跟随主题色的光晕）。
      Positioned.fill(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: cs.surface,
            gradient: RadialGradient(
              center: const Alignment(0, -1.1),
              radius: 1.1,
              colors: [
                halo.withValues(alpha: theme.brightness == Brightness.dark ? 0.22 : 0.16),
                halo.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
      Positioned.fill(
        child: Align(
          alignment: Alignment.topRight,
          child: Container(
            width: 220,
            height: 220,
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [
                  const Color(0x33C23F68),
                  const Color(0x00C23F68),
                ],
              ),
            ),
          ),
        ),
      ),
      Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Form(
              key: _form,
              // 2.4.1 第 6 项④：表单进毛玻璃卡。
              child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: cs.surface.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                    color: cs.outlineVariant.withValues(alpha: 0.7)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 2.4.1 第 6 项②：玻璃圆徽（半透底 + 细边 + 爱心，不引新资源）。
                  Center(
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: cs.surface.withValues(alpha: 0.55),
                        border: Border.all(
                            color: cs.outlineVariant.withValues(alpha: 0.9)),
                      ),
                      child: Icon(Icons.favorite_rounded,
                          size: 28, color: cs.primary),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text('恋爱空间', textAlign: TextAlign.center,
                      // 标题字距拉开（约 3）。
                      style: theme.textTheme.headlineMedium
                          ?.copyWith(letterSpacing: 3)),
                  const SizedBox(height: 4),
                  Text('把喜欢，写进每一天', textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                  const SizedBox(height: 30),
                  Text(_title, textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(_subtitle, textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                  const SizedBox(height: 22),
                  if (_mode != AuthMode.login) ...[
                    TextFormField(
                      controller: _name,
                      decoration: const InputDecoration(labelText: '你的昵称',
                          hintText: '希望 TA 怎么称呼你'),
                      validator: (v) => (v == null || v.trim().isEmpty) ? '输入昵称' : null,
                    ),
                    const SizedBox(height: 14),
                  ],
                  TextFormField(
                    controller: _username,
                    decoration: const InputDecoration(labelText: '登录账号',
                        hintText: '英文、数字，至少 3 位'),
                    autofillHints: const [AutofillHints.username],
                    validator: (v) {
                      final s = v?.trim() ?? '';
                      if (s.isEmpty) return '输入登录账号';
                      if (s.length < 3 || s.length > 40) return '账号 3-40 位';
                      if (!RegExp(r'^[a-zA-Z0-9_.@-]+$').hasMatch(s)) return '只允许英文、数字和 _.@-';
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _password,
                    obscureText: !_showPw,
                    decoration: InputDecoration(
                        labelText: '密码',
                        hintText: _mode == AuthMode.login
                            ? null
                            : '至少 10 个字符',
                        suffixIcon: IconButton(
                          icon: Icon(_showPw
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded),
                          onPressed: () =>
                              setState(() => _showPw = !_showPw),
                        )),
                    autofillHints: [if (_mode == AuthMode.login) AutofillHints.password else AutofillHints.newPassword],
                    onFieldSubmitted: (_) => _submit(),
                    validator: (v) {
                      final s = v ?? '';
                      if (s.isEmpty) return '输入密码';
                      if (_mode != AuthMode.login && s.length < 10) return '密码至少 10 个字符';
                      return null;
                    },
                  ),
                  if (_mode == AuthMode.setup && _tokenRequired) ...[
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _token,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '初始化口令',
                          hintText: '部署时设置的 SETUP_TOKEN'),
                      validator: (v) => (v == null || v.isEmpty) ? '输入初始化口令' : null,
                    ),
                  ],
                  if (_mode == AuthMode.join) ...[
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _token,
                      decoration: const InputDecoration(labelText: '邀请链接或邀请码',
                          hintText: '粘贴 TA 发你的专属链接'),
                      validator: (v) => (v == null || v.trim().isEmpty) ? '粘贴邀请链接' : null,
                    ),
                  ],
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    // 2.4.1 第 6 项⑤：实心主色 + 柔和投影。
                    style: FilledButton.styleFrom(
                      elevation: 3,
                      shadowColor: cs.primary.withValues(alpha: 0.35),
                    ),
                    child: _busy
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(_buttonText),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.error)),
                  ],
                  const SizedBox(height: Spacing.gap),
                  // 2.4.1 第 6 项⑥：模式切换改两个等宽描边胶囊并排一行
                  //（当前模式自隐，语义同原文字链，跳转不变）。
                  Row(children: [
                    if (_mode != AuthMode.setup)
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _busy ? null : () => setState(() {
                            _mode = AuthMode.setup;
                            _error = null;
                          }),
                          style: OutlinedButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 10)),
                          child: const Text('初始化新空间'),
                        ),
                      ),
                    if (_mode != AuthMode.setup && _mode != AuthMode.join)
                      const SizedBox(width: 10),
                    if (_mode != AuthMode.join)
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _busy ? null : () => setState(() {
                            _mode = AuthMode.join;
                            _error = null;
                          }),
                          style: OutlinedButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 10)),
                          child: const Text('我有邀请链接'),
                        ),
                      ),
                    if (_mode == AuthMode.setup)
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _busy ? null : () => setState(() {
                            _mode = AuthMode.login;
                            _error = null;
                          }),
                          style: OutlinedButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 10)),
                          child: const Text('已有账号，直接登录'),
                        ),
                      ),
                  ]),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: _busy ? null : () {
                      setState(() => _busy = true);
                      ref.read(authProvider.notifier).retryBootstrap().whenComplete(
                          () { if (mounted) setState(() => _busy = false); });
                    },
                    child: const Text('网络不稳？重试免登录恢复'),
                  ),
                  const SizedBox(height: Spacing.gap),
                  Text('私密记录 · 只属于彼此', textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                ],
              ),
              ),
            ),
          ),
        ),
      ),
      ]),
    );
  }
}
