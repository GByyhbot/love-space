/// 气泡皮肤数据（段三 · Step 9，纯函数可单测）。
/// 契约（chat.js bubblePicker + app.js chatSkinAttrs 实读）：
/// · GET /api/bubbles → {groups:[{id, count, items:[名]}]}（一次全量名单，
///   客户端分批渲染：BP_PAGE=90，滚动到底续载）；
/// · 图：/api/bubbles/<组>/<名>（整张气泡图，128×112，四角带装饰）；
/// · 落库：chat_bubble='<组>/<名>'、chat_bubble_fg='dark'|'light'、
///   chat_bubble_swap=bool（PUT /api/space 全量覆盖）；
/// · 左右两张图：右侧是同名 -r.png 镜像（skin.replace(/\.png$/,'-r.png')）；
///   swap 时把两张图对调（不生成新素材）；
/// · 九宫格：border-image-slice:42 fill、border-width:16px、repeat:stretch。
library;

import 'package:dio/dio.dart';

/// 皮肤配置（落库三件套）
class ChatSkin {
  const ChatSkin({this.skin = '', this.fg = 'dark', this.swap = true});
  final String skin; // '<组>/<名>'；''=不用皮肤
  final String fg; // dark / light
  final bool swap;

  bool get enabled => skin.isNotEmpty;

  /// 作者消息渲染图（2.4.6 各发各的）：swap=true 用 -r 镜像图，false 用原图。
  /// 与查看者无关——同一条消息在两台手机上渲染同一张图（验收标准「两台看到
  /// 的一致」）；swap 是作者对「自己的气泡用哪张图」的偏好（yang 拍板按人三键）。
  String get authorMessageUrl =>
      swap ? skin.replaceAll(RegExp(r'\.png$'), '-r.png') : skin;

  ChatSkin copyWith({String? skin, String? fg, bool? swap}) => ChatSkin(
        skin: skin ?? this.skin,
        fg: fg ?? this.fg,
        swap: swap ?? this.swap,
      );

  static ChatSkin fromSpace(Map<String, dynamic> space) => ChatSkin(
        skin: (space['chat_bubble'] ?? '').toString(),
        fg: (space['chat_bubble_fg'] ?? 'dark').toString(),
        swap: space['chat_bubble_swap'] != false,
      );

  /// 2.4.6 气泡各发各的（作者原则，纯函数三态可单测）：
  /// 每条消息的气泡皮肤 = 该消息作者的按人皮肤；作者未设置（skin 空）→
  /// 回退现行空间级选择；空间级也没有 → 默认皮肤。
  /// fg/swap 同样按人优先：作者未设对应键则回退空间级（yang 拍板「按人三键」）。
  /// [skin] 作者 bubbleSkin；[fg] 作者 bubbleFg（''=未设）；[swap] 作者
  /// bubbleSwap（null=未设）；[fallback] 空间级 ChatSkin（fromSpace）。
  static ChatSkin fromAuthor(
      {String skin = '', String fg = '', bool? swap, required ChatSkin fallback}) {
    if (skin.isEmpty) return fallback; // 作者未设 → 空间级回退（可能仍是默认）
    return ChatSkin(
      skin: skin,
      fg: fg.isEmpty ? fallback.fg : fg,
      swap: swap ?? fallback.swap,
    );
  }
}

/// 分批渲染页大小（对齐 Web BP_PAGE=90）
const int bubblePageSize = 90;

/// 滚动到底后的下一批可见数（纯函数，分批加载参数可单测）
int nextBubbleVisible(int total, int shown) {
  if (shown >= total) return shown;
  return (shown + bubblePageSize).clamp(0, total);
}

/// 组 + 单元格
class BubbleGroup {
  const BubbleGroup({required this.id, required this.count, required this.items});
  final String id;
  final int count;
  final List<String> items;

  factory BubbleGroup.fromJson(Map<String, dynamic> j) => BubbleGroup(
        id: (j['id'] ?? '').toString(),
        count: (j['count'] as num?)?.toInt() ?? 0,
        items: ((j['items'] ?? const []) as List).map((e) => e.toString()).toList(),
      );
}

/// GET /api/bubbles（缺组容错跳过，绝不抛异常中断选择器）
Future<List<BubbleGroup>> fetchBubbleGroups(Dio dio) async {
  final r = await dio.get('/api/bubbles');
  final data = (r.data ?? const {}) as Map;
  return ((data['groups'] ?? const []) as List)
      .whereType<Map>()
      .map((g) => BubbleGroup.fromJson(g.cast<String, dynamic>()))
      .toList();
}
