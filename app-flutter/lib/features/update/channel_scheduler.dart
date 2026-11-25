/// 更新器统一通道调度（ORD-UPDATER-HARDENING-01 §三.3，按修订页收口）。
///
/// 修订页（2026-11-25）落定的口径：
/// · 内置线路只保留 **直连 GitHub / gh-proxy.com / ghproxy.net**
///   （删 `ghfast.top`、`gh-proxy.org`；`hub.gitmirror.com` 实测已死，一并移除）；
/// · 「更新下载线路」选择 UI 与测速排序**降为二期**——盘线确认现行 App
///   根本没有这套 UI，本批不新建，所以这里不读任何用户偏好；
/// · 但**检查（Releases API）与下载必须共用同一套迭代**：同一候选表、
///   同一切换判定、任一通道成功即停。这就是本文件存在的理由——
///   以前检查阶段只走直连，墙内一挂就没有第二条路。
library;

import 'update_trace.dart';

/// 通道类型（对齐 Trace 的 `channelType` 枚举值）。
enum ChannelType {
  direct('direct', '直连 GitHub'),
  builtinProxy('builtin_proxy', '内置加速源'),
  customProxy('custom_proxy', '自定义加速源');

  const ChannelType(this.code, this.label);
  final String code;
  final String label;
}

/// 一条候选线路。
class UpdateChannel {
  const UpdateChannel({
    required this.template,
    required this.type,
    required this.name,
    this.isCustom = false,
  });

  /// 直连通道的 template 是空串（直接使用目标地址）。
  final String template;
  final ChannelType type;
  final String name;
  final bool isCustom;

  /// 目标 URL 经本通道转换后的最终地址。
  String urlFor(String targetUrl) => buildChannelUrl(template, targetUrl);

  bool get isDirect => template.isEmpty;
}

/// 内置加速源（修订一：只有这两条 + 直连）。
const List<String> kBuiltinProxyTemplates = <String>[
  'https://gh-proxy.com/',
  'https://ghproxy.net/',
];

/// 默认候选表：直连优先，再走内置加速源。
///
/// [customTemplate] 有值时插到最前（用户自填的源优先试）；当前 App 无 UI
/// 写入该值，保留形参是为了二期接线与单测，不引入设置页。
List<UpdateChannel> buildChannelQueue({String? customTemplate}) {
  final q = <UpdateChannel>[];
  final custom = (customTemplate ?? '').trim();
  if (custom.isNotEmpty) {
    q.add(UpdateChannel(
      template: custom,
      type: ChannelType.customProxy,
      name: _nameOf(custom),
      isCustom: true,
    ));
  }
  q.add(const UpdateChannel(
    template: '',
    type: ChannelType.direct,
    name: '直连 GitHub',
  ));
  for (final t in kBuiltinProxyTemplates) {
    q.add(UpdateChannel(
      template: t,
      type: ChannelType.builtinProxy,
      name: _nameOf(t),
    ));
  }
  return q;
}

/// 通道显示名：取域名（`https://gh-proxy.com/` → `gh-proxy.com`）。
String _nameOf(String template) {
  final m = RegExp(r'^[a-zA-Z]+://([^/]+)').firstMatch(template);
  return m?.group(1) ?? template;
}

/// 拼接通道 URL（§三.3「双格式 URL 模板拼接」）。
///
/// · **占位符式**（模板含 `{url}`）：只替换占位符，**不做任何编码**——
///   目标地址本身已由 dio 处理，二次编码会让 GitHub 认不出路径；
/// · **前缀式**（不含 `{url}`）：补齐末尾 `/` 后直接拼接；
/// · 空模板 = 直连，原样返回。
String buildChannelUrl(String template, String targetUrl) {
  var t = template.trim();
  if (t.isEmpty) return targetUrl;
  if (t.contains('{url}')) {
    return t.replaceAll('{url}', targetUrl);
  }
  if (!t.endsWith('/')) t = '$t/';
  return '$t$targetUrl';
}

/// 切下一个通道还是就地终止（§三.3「切换条件与超时控制」）。
class SwitchDecision {
  const SwitchDecision(this.retryNext, this.reason);
  final bool retryNext;
  final String reason;
}

/// 确定性错误：目标确实不存在/无权限，换线路也没用。
const Set<int> kTerminalStatusCodes = <int>{404, 410};

/// 判定：HTTP 404/410 → 立即终止不切换；403（限流）、5xx、超时、建连失败
/// → 换下一条。其余 4xx（400/422 等）按确定性错误处理，避免无意义轮换。
SwitchDecision decideSwitch({int? statusCode, Object? error}) {
  if (statusCode != null) {
    if (kTerminalStatusCodes.contains(statusCode)) {
      return SwitchDecision(false, 'HTTP $statusCode：目标不存在，停止切换');
    }
    if (statusCode >= 500 || statusCode == 403 || statusCode == 429) {
      return SwitchDecision(true, 'HTTP $statusCode：可换线路重试');
    }
    if (statusCode >= 400) {
      return SwitchDecision(false, 'HTTP $statusCode：确定性客户端错误，停止切换');
    }
    return SwitchDecision(true, 'HTTP $statusCode：非预期状态，尝试下一条');
  }
  // 无状态码 = 网络层异常（超时 / DNS / 建连 / 中断）→ 换线路
  return SwitchDecision(true, '网络异常：${describeError(error)}');
}
