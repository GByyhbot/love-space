/// 更新器全链路结构化 Trace（ORD-UPDATER-HARDENING-01 §三.1）。
///
/// 设计要点：
/// · 一次更新一个 `traceId`，四个阶段**只追加不覆盖**——失败重试的每一次
///   通道尝试都留在 `attempts[]` 里，排障时能看到完整路径；
/// · 导出前统一做 URL 脱敏：自定义加速源可能是 `?token=…&sig=…` 形态，
///   复制诊断信息给别人时不能把凭据带出去；
/// · 本类不依赖 Flutter，纯 Dart，可单测。
library;

/// 单次通道尝试（下载或检查共用同一形状，`phase` 区分）。
class ChannelAttempt {
  ChannelAttempt({
    required this.phase,
    required this.channel,
    required this.channelType,
    required this.isAutoFallback,
    required this.url,
    this.statusCode,
    this.bytesReceived = 0,
    this.durationMs = 0,
    this.error,
    this.note,
  });

  /// `check` / `download`
  final String phase;

  /// 通道显示名（直连 / gh-proxy.com / 自定义 …）
  final String channel;

  /// `direct` / `builtin_proxy` / `custom_proxy`
  final String channelType;

  /// 是否「已经离开用户主选线路后的兜底尝试」
  final bool isAutoFallback;

  final String url;
  final int? statusCode;
  final int bytesReceived;
  final int durationMs;
  final Object? error;
  final String? note;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'phase': phase,
        'channel': channel,
        'channelType': channelType,
        'isAutoFallback': isAutoFallback,
        'url': redactUrl(url),
        if (statusCode != null) 'statusCode': statusCode,
        'bytesReceived': bytesReceived,
        'durationMs': durationMs,
        if (error != null) 'error': describeError(error),
        if (note != null) 'note': note,
      };
}

/// 一次更新流程的完整快照。
class UpdateTrace {
  UpdateTrace({required this.traceId, this.currentVersion = ''});

  final String traceId;

  /// 当前安装版本（检查阶段填入）
  String currentVersion;

  /// 目标版本（选版后填入）
  String targetVersion = '';

  /// 检查与选版阶段
  final Map<String, dynamic> check = <String, dynamic>{};

  /// 逐条通道尝试（检查 + 下载按发生顺序追加）
  final List<ChannelAttempt> attempts = <ChannelAttempt>[];

  /// 落盘与校验阶段
  final Map<String, dynamic> artifact = <String, dynamic>{};

  /// 安装调起阶段
  final Map<String, dynamic> install = <String, dynamic>{};

  /// 失败阶段标签（`check` / `download` / `verify` / `install`）
  String failedStage = '';

  /// 面向用户的简明原因（与下方 JSON 分离：弹窗只显示这一行）
  String failureReason = '';

  void addAttempt(ChannelAttempt a) => attempts.add(a);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'traceId': traceId,
        'currentVersion': currentVersion,
        'targetVersion': targetVersion,
        'failedStage': failedStage,
        'failureReason': failureReason,
        'check': check,
        'attempts': attempts.map((a) => a.toJson()).toList(),
        'artifact': artifact,
        'install': install,
      };

  /// 复制到剪贴板的文本（缩进过的 JSON，方便贴给我看）。
  String toPrettyJson() => _prettyJson(toJson());
}

/// 需要脱敏的 query 参数名（大小写不敏感，包含匹配）。
const List<String> _sensitiveKeys = <String>[
  'token',
  'key',
  'auth',
  'sig',
  'signature',
  'password',
  'secret',
];

/// URL 脱敏：命中敏感 query 参数就把值换成 `***`。
///
/// 只动 query，不动机器/路径——路径里带 `key` 这类词很常见，误伤会让
/// 诊断信息失去价值。
String redactUrl(String raw) {
  if (raw.isEmpty) return raw;
  final q = raw.indexOf('?');
  if (q < 0) return raw;
  final head = raw.substring(0, q);
  final tail = raw.substring(q + 1);
  final parts = tail.split('&');
  for (var i = 0; i < parts.length; i++) {
    final eq = parts[i].indexOf('=');
    if (eq < 0) continue;
    final name = parts[i].substring(0, eq).toLowerCase();
    final hit = _sensitiveKeys.any((k) => name.contains(k));
    if (hit) parts[i] = '${parts[i].substring(0, eq)}=***';
  }
  return '$head?${parts.join('&')}';
}

/// 异常的可读摘要（不抛、不依赖 dio 类型，便于纯 Dart 单测）。
String describeError(Object? e) {
  if (e == null) return '';
  final s = e.toString();
  return s.length > 300 ? '${s.substring(0, 300)}…' : s;
}

String _prettyJson(Object? v, [String indent = '']) {
  const step = '  ';
  if (v is Map) {
    if (v.isEmpty) return '{}';
    final b = StringBuffer('{\n');
    final keys = v.keys.toList();
    for (var i = 0; i < keys.length; i++) {
      b.write('$indent$step${_quote(keys[i].toString())}: ');
      b.write(_prettyJson(v[keys[i]], '$indent$step'));
      if (i != keys.length - 1) b.write(',');
      b.write('\n');
    }
    b.write('$indent}');
    return b.toString();
  }
  if (v is List) {
    if (v.isEmpty) return '[]';
    final b = StringBuffer('[\n');
    for (var i = 0; i < v.length; i++) {
      b.write('$indent$step${_prettyJson(v[i], '$indent$step')}');
      if (i != v.length - 1) b.write(',');
      b.write('\n');
    }
    b.write('$indent]');
    return b.toString();
  }
  if (v is String) return _quote(v);
  if (v is num || v is bool) return '$v';
  if (v == null) return 'null';
  return _quote(v.toString());
}

String _quote(String s) =>
    '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';
