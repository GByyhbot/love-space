/// `/channels` 通知渠道二级页（「数据管理与通知渠道」章 · 段 A · 2.2.5/VC225）。
///
/// 契约（全部只读自服务端 / Web 原文）：
/// · `GET /api/channels` `main.py:2518-2527` 逐行 `pop('config')` 不回传配置 →
///   列表只呈现中文类型 / name / enabled / 「服务端已保存配置」/ `events` 中文名；
///   🔴 不展示 / 不回填任何凭据，config 也绝不落客户端。
/// · `POST /api/channels` `main.py:2530-2544`：10 种 config 字段逐项对齐
///   `app.js:2436` configs 表，提交体对齐 `app.js:2437` 末尾；12 事件订阅
///   **是新建表单里的 checkbox**（`app.js:2437` 默认全选），无独立订阅开关、
///   无 PUT、无本地缓存；POST 成功后重拉 GET 确认 `events` 落库。
/// · `DELETE /api/channels/{cid}` `main.py:2547-2551`（删前确认、成功后重拉）；
///   `POST /api/channels/{cid}/test` `:2554-2564`（404「渠道不存在」原文透传）；
///   `GET /api/deliveries` `:2567-2572` + `POST /api/deliveries/{did}/retry` `:2575-2579`。
/// · 🔴 无编辑（`app.js` 亦只能删重建）、WebPush 原生端全跳过（不做假开关、
///   不调 `/api/webpush*`）、不做 App 侧提前天数设置（D6）。
/// · 🔴 全部写方法经 `NotifyApi._write` → `writeResponseError`：4xx 服务端
///   `detail` 原文走「顶部通知(error) + 表单内联错误区」双呈现；失败不发成功
///   通知 / 不 pop / 输入保留 / 不自动重试 / 不本地改动列表，成功才重拉。
/// · 二级页 `context.push` 打开，AppBar `automaticallyImplyLeading` 不关 →
///   返回按钮 + 系统返回手势都能回上一页。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'notify_api.dart';
import 'notify_models.dart';
import 'notify_widgets.dart';
import '../../core/theme/tokens.dart';

class ChannelsPage extends ConsumerStatefulWidget {
  const ChannelsPage({super.key});

  @override
  ConsumerState<ChannelsPage> createState() => _ChannelsPageState();
}

class _ChannelsPageState extends ConsumerState<ChannelsPage> {
  List<ChannelItem> _channels = const <ChannelItem>[];
  List<DeliveryItem> _deliveries = const <DeliveryItem>[];
  bool _loading = true;
  bool _busy = false;
  bool _showForm = false;
  String? _pageError;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<NotifyApi> _service() async =>
      NotifyApi(await ref.read(api.dioProvider.future));

  /// 全量拉取（进页 / 下拉刷新 / **写成功后**）。列表状态只来自服务端。
  Future<void> _load() async {
    try {
      final NotifyApi svc = await _service();
      final List<ChannelItem> channels = await svc.loadChannels();
      final List<DeliveryItem> deliveries = await svc.loadDeliveries();
      if (!mounted) return;
      setState(() {
        _channels = channels;
        _deliveries = deliveries;
        _loading = false;
        _pageError = null;
      });
    } on NotifyFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _pageError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _pageError = api.errorDetail(e);
      });
    }
  }

  void _toast(String text, {ChatToastTone tone = ChatToastTone.info}) {
    ref.read(chatToastProvider.notifier).show(text, tone: tone);
  }

  /// 🔴 统一写后处理（删除 / 测试 / 重试）：
  /// 失败＝服务端 detail 原文顶部通知 + 页面内联错误条，不重拉、不改列表、
  /// 不重试、不 pop；成功＝顶部成功通知 + **重拉 GET 确认落库 / 消失**。
  Future<void> _runWrite(
    Future<String?> Function(NotifyApi svc) action, {
    required String successText,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _actionError = null;
    });
    String? err;
    try {
      final NotifyApi svc = await _service();
      err = await action(svc);
    } catch (e) {
      err = api.errorDetail(e);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      setState(() => _actionError = err);
      _toast(err, tone: ChatToastTone.error);
      return;
    }
    setState(() => _actionError = null);
    _toast(successText, tone: ChatToastTone.success);
    await _load();
  }

  /// 新建提交。`payload` 里的 config（凭据）只在 POST 请求体里过一遍：
  /// 不落存储 / 不进日志 / 不入 provider / 不入内存缓存，提交后立即丢弃。
  Future<String?> _submitChannel(Map<String, dynamic> payload) async {
    String? err;
    try {
      final NotifyApi svc = await _service();
      err = await svc.createChannel(payload);
    } catch (e) {
      err = api.errorDetail(e);
    }
    if (!mounted) return err;
    if (err != null) {
      // 双呈现之一：顶部通知（服务端 detail 原文）；内联错误区由表单显示。
      _toast(err, tone: ChatToastTone.error);
      return err; // 失败：表单保留输入、不 pop、不重试
    }
    _toast('渠道已添加，订阅已保存到服务端', tone: ChatToastTone.success);
    setState(() => _showForm = false); // 成功才关闭表单（凭据即弃）
    await _load(); // POST 后重拉 GET /api/channels 确认 events 落库
    return null;
  }

  /// 删除确认（对齐 `app.js:2674` confirmAction 文案，可取消）。
  Future<void> _confirmDelete(ChannelItem c) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('移除这个通知渠道？'),
        content: const Text('该渠道的配置和发送日志会一并移除。'),
        actions: <Widget>[
          TextButton(
            key: const Key('channel-delete-cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('channel-delete-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _runWrite(
      (NotifyApi svc) => svc.deleteChannel(c.id),
      successText: '渠道已移除',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // automaticallyImplyLeading 不关：返回按钮 + 系统手势都能回上一页。
      appBar: AppBar(
        title: Text(_showForm ? '添加一个通知渠道' : '通知渠道'),
        actions: <Widget>[
          if (!_showForm)
            IconButton(
              key: const Key('channels-refresh'),
              tooltip: '刷新',
              onPressed: _busy ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
          if (!_showForm)
            TextButton(
              key: const Key('channels-new'),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _showForm = true;
                        _actionError = null;
                      }),
              child: const Text('添加渠道'),
            ),
        ],
      ),
      body: _showForm
          ? _ChannelForm(
              onSubmit: _submitChannel,
              onCancel: () => setState(() => _showForm = false),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, Spacing.pageBottom),
                children: <Widget>[
                  const NotifyInfoCard(
                    title: '不错过，每一份在意',
                    subtitle: '让想念与提醒，抵达你喜欢的地方。',
                    lines: <String>[
                      '可同时启用多个渠道，各自设置事件和免打扰时间。外部通知只发送提醒摘要，详情请登录空间查看。测试发送会跳过免打扰。',
                      '浏览器系统通知仅网页端可用，原生端请使用第三方渠道。',
                      '渠道配置由服务端加密保存，不支持修改；需要调整请删除后重新添加。',
                      '订阅事件只在新建渠道时勾选，服务端保存后不回传配置；需要调整订阅请删除后重新添加。',
                    ],
                  ),
                  if (_pageError != null) NotifyErrorBanner(text: _pageError!),
                  if (_actionError != null)
                    NotifyErrorBanner(text: _actionError!),
                  if (_busy) const LinearProgressIndicator(),
                  if (_loading && _channels.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(28),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_channels.isEmpty)
                    const NotifyEmptyCard(
                      title: '选择你的提醒方式',
                      detail:
                          '支持邮件、Bark、Server酱、PushPlus、企业微信、Telegram、钉钉、飞书、ntfy 和 Webhook。',
                    )
                  else
                    ..._channels.map(_channelCard),
                  const SizedBox(height: 12),
                  _deliveriesSection(),
                ],
              ),
            ),
    );
  }

  Widget _channelCard(ChannelItem c) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    return Card(
      key: Key('channel-card-${c.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.cardPad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.notifications_none_rounded,
                    size: 20, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(c.name, style: theme.textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: Spacing.gap),
            Text(
              // config 不回传：只说明「服务端已保存配置」，绝不展示明文凭据。
              '${channelLabel(c.kind)} · ${c.enabled ? '已启用' : '已停用'} · 服务端已保存配置',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
            ),
            const SizedBox(height: 4),
            Text(
              '已订阅：${eventsLabel(c.events)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              '${quietLabel(c.quietStart, c.quietEnd)} · 最短间隔 ${c.interval} 秒',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
            ),
            const SizedBox(height: Spacing.gap),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton.icon(
                  key: Key('channel-test-${c.id}'),
                  onPressed: _busy
                      ? null
                      : () => _runWrite(
                            (NotifyApi svc) => svc.testChannel(c.id),
                            successText: '测试已加入发送队列，请刷新发送记录',
                          ),
                  icon: const Icon(Icons.send_outlined, size: 16),
                  label: const Text('测试'),
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  key: Key('channel-delete-${c.id}'),
                  onPressed: _busy ? null : () => _confirmDelete(c),
                  icon: const Icon(Icons.delete_outline_rounded, size: 16),
                  label: const Text('移除'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _deliveriesSection() {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text('最近发送记录', style: theme.textTheme.titleMedium),
            ),
            TextButton.icon(
              key: const Key('deliveries-refresh'),
              onPressed: _busy ? null : _load,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('刷新'),
            ),
          ],
        ),
        if (_deliveries.isEmpty)
          const Card(
            margin: EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: EdgeInsets.all(Spacing.cardPad),
              child: Text('配置好渠道后，点击测试即可验证能否收到通知。'),
            ),
          )
        else
          ..._deliveries.map(_deliveryCard),
      ],
    );
  }

  Widget _deliveryCard(DeliveryItem d) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final String detail = d.error.isNotEmpty
        ? d.error
        : (d.sentAt != null ? noticeTimeLabel(d.sentAt!) : '等待发送');
    return Card(
      key: Key('delivery-card-${d.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('${d.title} · ${d.name}',
                      style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 3),
                  Text(
                    '$detail · 尝试 ${d.attempts} 次',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.outline),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(deliveryStatusLabel(d.status),
                    style: theme.textTheme.labelMedium),
                if (d.isFailed)
                  TextButton(
                    key: Key('delivery-retry-${d.id}'),
                    onPressed: _busy
                        ? null
                        : () => _runWrite(
                              (NotifyApi svc) => svc.retryDelivery(d.id),
                              successText: '已重新加入发送队列',
                            ),
                    child: const Text('重试'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 新建渠道表单（页内展开，不新增路由）。
///
/// 🔴 凭据红线（与个人心愿密码同级）：`token` / `key` / `secret` /
/// `password` / `chat_id` 等只在 [TextEditingController] 这一**表单局部临时
/// 输入缓冲**里停留，提交时一次性写入 `POST /api/channels` 请求体；
/// 不落本地存储（SharedPreferences / secure_storage / 文件）、不进日志、
/// 不入任何 provider / 页面 state 缓存；提交成功后立即 `clear()` 并随表单
/// dispose 销毁；失败则按纪律「输入保留」不清空。
class _ChannelForm extends StatefulWidget {
  const _ChannelForm({required this.onSubmit, required this.onCancel});

  final Future<String?> Function(Map<String, dynamic> payload) onSubmit;
  final VoidCallback onCancel;

  @override
  State<_ChannelForm> createState() => _ChannelFormState();
}

class _ChannelFormState extends State<_ChannelForm> {
  String _kind = 'smtp';
  final TextEditingController _name = TextEditingController();
  final TextEditingController _quietStart = TextEditingController(text: '22');
  final TextEditingController _quietEnd = TextEditingController(text: '8');
  final TextEditingController _interval = TextEditingController(text: '300');
  Map<String, TextEditingController> _configControllers =
      <String, TextEditingController>{};
  Set<String> _selectedEvents = <String>{};
  String? _inlineError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Web `app.js:2437`：12 个事件 checkbox 默认全部 checked。
    _selectedEvents = defaultSelectedEvents().toSet();
    _rebuildConfigControllers(_kind);
  }

  /// 切换渠道类型时销毁旧输入（含凭据）并重建字段，避免旧类型凭据残留。
  void _rebuildConfigControllers(String kind) {
    for (final TextEditingController c in _configControllers.values) {
      c.dispose();
    }
    final Map<String, TextEditingController> next =
        <String, TextEditingController>{};
    for (final ChannelConfigField f in
        channelConfigs[kind] ?? const <ChannelConfigField>[]) {
      next[f.key] = TextEditingController(text: f.initialValue);
    }
    _configControllers = next;
  }

  /// 提交成功后立刻清空 config 输入（凭据不留副本）。
  void _clearCredentialControllers() {
    for (final TextEditingController c in _configControllers.values) {
      c.clear();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _quietStart.dispose();
    _quietEnd.dispose();
    _interval.dispose();
    for (final TextEditingController c in _configControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final String name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _inlineError = '请填写渠道名称');
      return;
    }
    // 一次性快照：只在本次 POST 请求体里过一遍，不写 state / provider。
    final Map<String, String> values = <String, String>{
      for (final MapEntry<String, TextEditingController> e
          in _configControllers.entries)
        e.key: e.value.text,
    };
    final Map<String, String> config = buildChannelConfig(_kind, values);
    final List<String> events = defaultSelectedEvents()
        .where((String id) => _selectedEvents.contains(id))
        .toList();
    final Map<String, dynamic> payload = buildChannelPayload(
      kind: _kind,
      name: name,
      config: config,
      events: events,
      quietStart: int.tryParse(_quietStart.text.trim()) ?? 22,
      quietEnd: int.tryParse(_quietEnd.text.trim()) ?? 8,
      interval: int.tryParse(_interval.text.trim()) ?? 300,
    );
    setState(() {
      _busy = true;
      _inlineError = null;
    });
    final String? err = await widget.onSubmit(payload);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _inlineError = err;
    });
    if (err == null) {
      _clearCredentialControllers();
    }
    // 失败：输入保留、表单不 pop、不自动重试；错误走内联 + 顶部双呈现。
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<ChannelConfigField> fields =
        channelConfigs[_kind] ?? const <ChannelConfigField>[];
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, Spacing.pageBottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('添加一个通知渠道', style: theme.textTheme.titleMedium),
          const SizedBox(height: Spacing.gap),
          Text(
            '渠道配置由服务端加密保存，不支持修改；需要调整请删除后重新添加。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (_inlineError != null) NotifyErrorBanner(text: _inlineError!),
          Row(
            children: <Widget>[
              const Text('渠道类型'),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<String>(
                  key: const Key('channel-kind'),
                  value: _kind,
                  isExpanded: true,
                  items: channelNames.entries
                      .map((MapEntry<String, String> e) =>
                          DropdownMenuItem<String>(
                            value: e.key,
                            child: Text(e.value),
                          ))
                      .toList(),
                  onChanged: (String? v) {
                    if (v == null || v == _kind) return;
                    setState(() {
                      _kind = v;
                      _rebuildConfigControllers(v);
                      _inlineError = null;
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('channel-name'),
            controller: _name,
            maxLength: 60,
            decoration: const InputDecoration(
              labelText: '给渠道起个名字',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 14),
          Text('渠道配置', style: theme.textTheme.titleSmall),
          const SizedBox(height: Spacing.gap),
          for (final ChannelConfigField f in fields)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                key: Key('channel-config-${f.key}'),
                controller: _configControllers[f.key],
                obscureText: f.type == ChannelFieldType.password,
                keyboardType: _fieldKeyboardType(f.type),
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: f.required ? f.label : '${f.label}（可选）',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          const SizedBox(height: Spacing.gap),
          Text('接收哪些提醒', style: theme.textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(
            '勾选后由服务端保存；需要调整订阅请删除渠道后重新添加。',
            style: theme.textTheme.bodySmall,
          ),
          for (final MapEntry<String, String> e in eventNames.entries)
            CheckboxListTile(
              key: Key('channel-event-${e.key}'),
              value: _selectedEvents.contains(e.key),
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(e.value, style: theme.textTheme.bodySmall),
              onChanged: (bool? v) {
                setState(() {
                  if (v == true) {
                    _selectedEvents.add(e.key);
                  } else {
                    _selectedEvents.remove(e.key);
                  }
                });
              },
            ),
          const SizedBox(height: Spacing.gap),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const Key('channel-quiet-start'),
                  controller: _quietStart,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '免打扰开始（小时）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  key: const Key('channel-quiet-end'),
                  controller: _quietEnd,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '免打扰结束（小时）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('channel-interval'),
            controller: _interval,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '最短发送间隔（秒）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: Spacing.gap),
          Text(
            '开始与结束相同表示全天接收。聊天消息会合并提醒。保存后可发送测试消息。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  key: const Key('channel-cancel'),
                  onPressed: _busy ? null : widget.onCancel,
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const Key('channel-submit'),
                  onPressed: _busy ? null : _submit,
                  child: Text(_busy ? '保存中…' : '保存渠道'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

TextInputType _fieldKeyboardType(ChannelFieldType t) {
  switch (t) {
    case ChannelFieldType.number:
      return TextInputType.number;
    case ChannelFieldType.email:
      return TextInputType.emailAddress;
    case ChannelFieldType.url:
      return TextInputType.url;
    case ChannelFieldType.password:
      return TextInputType.visiblePassword;
    case ChannelFieldType.text:
      return TextInputType.text;
  }
}
