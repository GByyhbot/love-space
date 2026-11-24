"""通知标题构造（2.8.1 通知明文批）。

只负责把「记录 kind + body」翻译成一句给人看的明文标题——不读不写数据库、
不碰通知队列。调用方（app/main.py）负责把需要的媒体/相册名查好再传进来。

口径（机主 2026-11-24 拍板，钉死）：
· 摘录 = 正文纯文本、空白压成单空格、截 30 字、超长加「…」；
· 聊天恒「收到一条新消息」，不带任何内容（聊天不解密）；
· PRIVATE 三 kind（diary/draft/surprise）本来就不发通知，绝不因本模块而发；
· personal_wish 由调用方给固定文案，不经这里（密码封存物不带标题/内容）；
· period 只报类型，绝不带任何内容字段。

旧版那句泛化文案（"空间有新记录"式的空话）在本批彻底移除：源码里不再出现该串，
行为层由 pytest 断言钉死（新建任何 kind 都不会产出泛化标题）。
"""

import re

# 摘录长度：机主口径 30 字（含标点，不区分中英文宽度）
EXCERPT_LIMIT = 30

# 兜底文案用的 kind 中文名；未收录的 kind 直接显示原 kind 串
KIND_NAMES = {
    'post': '时光',
    'album': '相册',
    'anniversary': '纪念日',
    'wish': '共同愿望',
    'personal_wish': '个人心愿',
    'mood': '心情',
    'note': '留言',
    'question': '情侣问答',
    'habit': '打卡目标',
    'quest': '清单任务',
    'ledger': '账本',
    'period': '生理期',
    'music': '音乐',
}

_WS = re.compile(r'\s+')


def plain(text) -> str:
    """正文 → 纯文本单行（空白压缩；非字符串一律当空）。"""
    if not isinstance(text, str):
        return ''
    return _WS.sub(' ', text).strip()


def excerpt(text, limit: int = EXCERPT_LIMIT) -> str:
    """取摘录：超长截断加「…」。这里的 limit 是字符数，不做字节对齐。"""
    s = plain(text)
    if len(s) <= limit:
        return s
    return s[:limit] + '…'


def media_word(first_mime, has_song: bool = False) -> str:
    """首个附件的占位词：[图片]/[视频]/[语音]/[音乐]。

    有 song 字段一律算 [音乐]（在线搜来的歌没有本地媒体行）；
    音频但无 song → [语音]（语音消息）。
    """
    if has_song:
        return '[音乐]'
    mime = (first_mime or '').lower()
    if mime.startswith('video'):
        return '[视频]'
    if mime.startswith('audio'):
        return '[语音]'
    return '[图片]'


def build_title(kind, body=None, *, first_media_mime=None, album_name=None,
                comment_text=None, answer_text=None) -> str:
    """按 kind 造标题。body 为 clean_body 之后的实际结构。"""
    b = body if isinstance(body, dict) else {}
    title = plain(b.get('title'))
    content = plain(b.get('content'))
    song = b.get('song') if isinstance(b.get('song'), dict) else {}
    song_title = plain(song.get('title'))

    if kind == 'period':
        # 红线：生理期只报类型，绝不带任何内容字段
        return '对方添加了一条生理期记录'

    if kind == 'post':
        # 传照片专属动态（album_only）：报张数，能定位相册就带上相册名
        if b.get('album_only') is True:
            n = len(b.get('media') or [])
            if n:
                word = f'对方往相册传了 {n} 张照片'
                return word + (f'到「{album_name}」' if album_name else '')
            return '对方往相册传了照片'
        text = excerpt(b.get('content'))
        if text:
            return f'对方发布了一条时光：{text}'
        if b.get('media') or song:
            return '对方发布了一条时光：' + media_word(first_media_mime, bool(song))
        return '对方发布了一条时光'

    if kind == 'mood':
        text = excerpt(b.get('content'))
        if text:
            return f'对方记录了心情：{text}'
        emoji = plain(b.get('emoji'))
        if emoji:
            return f'对方记录了心情：{emoji}'
        return '对方记录了今日心情'

    if kind == 'note':
        text = excerpt(b.get('content'))
        return f'对方留了一条留言：{text}' if text else '对方留了一条留言'

    if kind == 'album':
        return f'对方新建了相册「{title}」' if title else '对方新建了一个相册'

    if kind == 'anniversary':
        return f'对方添加了纪念日「{title}」' if title else '对方添加了一个纪念日'

    if kind == 'wish':
        return f'对方添加了一个共同愿望：{title}' if title else '对方添加了一个共同愿望'

    if kind == 'question':
        text = excerpt(b.get('title'))
        return f'对方发布了情侣问答：{text}' if text else '对方发布了情侣问答'

    if kind == 'habit':
        return f'对方新建了打卡目标「{title}」' if title else '对方新建了打卡目标'

    if kind == 'music':
        name = song_title or title
        return f'对方添加了一首歌：{name}' if name else '对方添加了一首歌'

    if kind == 'ledger':
        text = excerpt(b.get('content'))
        return f'对方记了一笔：{text}' if text else '对方记了一笔'

    if kind == 'comment':
        text = excerpt(comment_text)
        return f'对方评论了你的记录：{text}' if text else '对方评论了你的记录'

    if kind == 'like':
        return '对方喜欢了你的记录'

    if kind == 'answer':
        text = excerpt(answer_text)
        return f'对方回答了情侣问答：{text}' if text else '对方回答了情侣问答'

    if kind == 'check':
        return f'对方完成了打卡「{title}」' if title else '对方完成了一次打卡'

    # 未列 kind 的兜底：不许再回退成泛化文案
    return f'对方发布了一条新记录（{KIND_NAMES.get(kind, kind)}）'
