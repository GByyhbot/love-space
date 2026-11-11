/// 聊天背景（段三 · Step 9，纯函数可单测）。
/// 契约（app.js chatBgForm/chatBgOf + chat.js 实读）：
/// · 每人一份：space.chat_bg_users[uid] = {bg, media, dim}；没单独设过退回
///   space 级共同默认（chat_bg/chat_bg_media/chat_bg_dim）；
/// · PUT /api/space 全量覆盖：以 spaceRaw 原样为基础只覆盖 chat_bg_target/
///   chat_bg/chat_bg_media/chat_bg_dim 四键（对齐首页 spaceRaw 原样回传做法）；
/// · 7 预设：''默认 / sakura樱粉 / cream奶油 / mint薄荷 / stars星光 / night夜幕 /
///   photo用照片（media 为背景照片媒体 id）；
/// · dim 0–80（默认 35），只为一件事：保证气泡文字在任何底图上读得清。
library;

/// 预设（key + 中文标签；逐字对齐 Web CHAT_BG_PRESETS）
const List<(String, String)> chatBgPresets = [
  ('', '默认'),
  ('sakura', '樱粉'),
  ('cream', '奶油'),
  ('mint', '薄荷'),
  ('stars', '星光'),
  ('night', '夜幕'),
  ('photo', '用照片'),
];

/// 单人背景配置
class ChatWallpaper {
  const ChatWallpaper({this.bg = '', this.media = '', this.dim = 35});
  final String bg; // ''=默认，预设 key，或 'photo'
  final String media; // bg=='photo' 时的媒体 id
  final int dim; // 0–80

  bool get isPhoto => bg == 'photo' && media.isNotEmpty;
  bool get hasWallpaper => bg.isNotEmpty;
}

/// 读取某人当前生效的背景（对齐 Web chatBgOf：chat_bg_users[uid] 优先，
/// 否则退回空间级共同默认）
ChatWallpaper chatBgOf(Map<String, dynamic> space, String uid) {
  final users = (space['chat_bg_users'] ?? const {}) as Map;
  final own = users[uid];
  if (own is Map) {
    return ChatWallpaper(
      bg: (own['bg'] ?? '').toString(),
      media: (own['media'] ?? '').toString(),
      dim: (own['dim'] as num?)?.toInt() ?? 35,
    );
  }
  return ChatWallpaper(
    bg: (space['chat_bg'] ?? '').toString(),
    media: (space['chat_bg_media'] ?? '').toString(),
    dim: (space['chat_bg_dim'] as num?)?.toInt() ?? 35,
  );
}

/// 构造 PUT /api/space 全量覆盖 payload：spaceRaw 原样带回 + 四键覆盖
/// （chat_bg_target=要设给谁的 uid；photo 未选图时 media 清空，对齐 Web）。
/// 返回 (payload, 错误文案?)：photo 且无 media 时返回错误。
(Map<String, dynamic>?, String?) applyChatBgPayload(
    Map<String, dynamic> spaceRaw,
    {required String target,
    required String bg,
    required String media,
    required int dim}) {
  if (bg == 'photo' && media.isEmpty) return (null, '先用「上传」或「从相册选」挑一张照片');
  final payload = <String, dynamic>{...spaceRaw};
  payload['chat_bg_target'] = target;
  payload['chat_bg'] = bg;
  payload['chat_bg_media'] = bg == 'photo' ? media : '';
  payload['chat_bg_dim'] = dim.clamp(0, 80);
  return (payload, null);
}
