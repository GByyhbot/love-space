/// 贴纸坞静态数据（逐字对齐 static/chat.js：CUTE_EMOJI / SPICY_EMOJI / STICKER_PACKS）。
library;

class StickerPack {
  const StickerPack({
    required this.id,
    required this.label,
    required this.dir,
    required this.ext,
    required this.count,
  });
  final String id;
  final String label;
  final String dir; // /static/stickers/<dir>/<序号>.<ext>
  final String ext;
  final int count;
}

/// 内置贴纸包（对齐 chat.js STICKER_PACKS：包名/序号 → /static/stickers/...）
const List<StickerPack> stickerPacks = [
  StickerPack(id: 'pk-dancer', label: '🕺 舞动', dir: 'musicfuckdancer3', ext: 'webm', count: 50),
  StickerPack(id: 'pk-tsrj8', label: '🫧 TSRJ8', dir: 'tsrj8', ext: 'webm', count: 120),
  StickerPack(id: 'pk-lolitax', label: '🎀 Lolitax', dir: 'lolitax', ext: 'webp', count: 119),
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

/// 贴纸坞 tab 定义（对齐 Web renderStickerTabs 的 tabs 顺序与文案）
const List<(String, String)> stickerTabs = [
  ('cute', '💕 日常'),
  ('spicy', '🔥 涩涩'),
  ('mine', '🌟 我的'),
  ('pk-dancer', '🕺 舞动'),
  ('pk-tsrj8', '🫧 TSRJ8'),
  ('pk-lolitax', '🎀 Lolitax'),
];
