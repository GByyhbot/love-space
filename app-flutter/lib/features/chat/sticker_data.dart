/// 贴纸坞静态数据（逐字对齐 static/chat.js：CUTE_EMOJI / SPICY_EMOJI / STICKER_PACKS）。
library;

class StickerPack {
  const StickerPack({
    required this.id,
    required this.label,
    required this.dir,
    required this.ext,
    required this.count,
    this.local = false,
  });
  final String id;
  final String label;
  final String dir; // /static/stickers/<dir>/<序号>.<ext>
  final String ext;
  final int count;

  /// true = 打包进 App assets（`assets/stickers/<dir>/<序号>.<ext>`）：
  /// 面板本地渲染离线秒开（2.4.4 第 2 项老规矩）；发送载荷仍是服务端
  /// 相对路径 `/static/stickers/<dir>/...`（资产双落位，双方渲染互通）。
  final bool local;
}

/// 内置贴纸包（对齐 chat.js STICKER_PACKS：包名/序号 → /static/stickers/...）
const List<StickerPack> stickerPacks = [
  StickerPack(id: 'pk-dancer', label: '🕺 舞动', dir: 'musicfuckdancer3', ext: 'webm', count: 50),
  StickerPack(id: 'pk-tsrj8', label: '🫧 TSRJ8', dir: 'tsrj8', ext: 'webm', count: 120),
  StickerPack(id: 'pk-lolitax', label: '🎀 Lolitax', dir: 'lolitax', ext: 'webp', count: 119),
  // 2.4.4 第 2 项新增：App 本地资产（发送走服务端同路径，资产已部署 /static/stickers/）
  StickerPack(id: 'pk-bigmoji', label: '🤪 大表情', dir: 'bigmoji', ext: 'webp', count: 60, local: true),
  StickerPack(id: 'pk-memes', label: '🐼 梗图', dir: 'memes', ext: 'webp', count: 28, local: true),
];

/// emoji 两组（对齐 chat.js CUTE_EMOJI / SPICY_EMOJI，逐字照抄）
const List<String> cuteEmoji = [
  '😊', '😄', '🥰', '😘', '😗', '💋', '❤️', '🧡', '💕', '💞', '🤗', '😳',
  '🙈', '✨', '🌹', '🍰', '🍜', '☕', '🌙', '⭐', '🍀', '🎁', '📷', '🎵',
  '💤', '🫶', '🏠', '🌈', '☀️', '🌧️',
];

const List<String> spicyEmoji = [
  '😈', '🫦', '😏', '💗', '🍑', '🍌', '🍆', '💦', '👅', '🔥', '🛌', '🙈',
  '💋', '🤫', '💞', '🌙',
];

/// 贴纸坞 tab 定义（对齐 Web renderStickerTabs 的 tabs 顺序与文案；
/// 2.4.4 新增两标签按主人口径就近落位：「我的」之后、内置 pk 系列之前）
const List<(String, String)> stickerTabs = [
  ('cute', '💕 日常'),
  ('spicy', '🔥 涩涩'),
  ('mine', '🌟 我的'),
  ('pk-bigmoji', '🤪 大表情'),
  ('pk-memes', '🐼 梗图'),
  ('pk-dancer', '🕺 舞动'),
  ('pk-tsrj8', '🫧 TSRJ8'),
  ('pk-lolitax', '🎀 Lolitax'),
];
