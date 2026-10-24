"""聊天记录导入解析器。

支持来源：
- 微信：「留痕 / WeChatMsg」等工具导出的 TXT、CSV、ZIP（含图片目录）
- QQ：消息管理器导出的 TXT（含 GBK 编码）
- 抖音：第三方工具导出的 CSV / JSON
- 通用：任意 JSON 数组（字段名自动识别常见中英文别名）

解析产物统一为 [{sender, content, kind, sent_at, media?}]，时间戳可为 None。
"""
import contextlib
import csv
import datetime as dt
import io
import json
import re
import zipfile
from pathlib import Path, PurePosixPath

MAX_MESSAGES = 200_000
IMAGE_EXTS = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'}
MAX_ZIP_ENTRIES = 5000
MAX_ZIP_UNPACKED_BYTES = 100 * 1024 * 1024
MAX_ZIP_MEMBER_BYTES = 30 * 1024 * 1024

_TS = r'\d{4}[-/年.]\d{1,2}[-/月.]\d{1,2}[日号]?(?:[ T]\d{1,2}:\d{1,2}(?::\d{1,2})?)?'
# 消息头两种形态：「时间 昵称」与「昵称 时间」
_HEAD_TS_FIRST = re.compile(rf'^\[?(?P<ts>{_TS})\]?\s+(?P<who>\S.*?)\s*$')
_HEAD_WHO_FIRST = re.compile(rf'^(?P<who>\S.*?)\s+\[?(?P<ts>{_TS})\]?\s*$')

KIND_MARKS = [
    (re.compile(r'\[(图片|照片|图像)\]'), 'image'),
    (re.compile(r'\[(语音|语音消息)\]'), 'voice'),
    (re.compile(r'\[(视频|视频消息)\]'), 'video'),
    (re.compile(r'\[(表情|动画表情|贴纸|sticker)\]', re.I), 'sticker'),
    (re.compile(r'\[(语音通话|视频通话|红包|转账|链接|文件|位置|名片|小程序|撤回了一条消息)\]'), 'system'),
    (re.compile(r'\.(jpg|jpeg|png|gif|webp|heic|bmp)$', re.I), 'image'),
    (re.compile(r'\.(mp4|mov|webm|mkv|avi)$', re.I), 'video'),
    (re.compile(r'\.(amr|mp3|wav|m4a|aac|silk|ogg)$', re.I), 'voice'),
]

COLUMN_ALIASES = {
    'time': {'时间', 'time', 'date', 'send_time', 'msg_time', 'msgtime', '发送时间', '日期时间', 'strtime'},
    'sender': {'发送人', '发送者', '发言人', 'sender', 'from', 'nickname', 'name', '昵称', 'talker', 'author', '发送方', 'talkername'},
    'content': {'内容', '消息', 'content', 'message', 'msg', 'text', '消息内容', '消息文本', 'strcontent'},
    'kind': {'类型', 'type', 'msgtype', 'content_type', '消息类型', 'localtype'},
}

KIND_TABLE = {'1': 'text', 'text': 'text', '文本': 'text', '文字': 'text', '0': 'text',
              '3': 'image', 'image': 'image', '图片': 'image', '照片': 'image', 'pic': 'image',
              '34': 'voice', 'voice': 'voice', '语音': 'voice', 'audio': 'voice', '声音': 'voice',
              '43': 'video', 'video': 'video', '视频': 'video',
              '47': 'sticker', 'sticker': 'sticker', '表情': 'sticker', 'emoji': 'sticker',
              'system': 'system', '系统': 'system', '通知': 'system', '10000': 'system'}


def decode_bytes(raw: bytes) -> str:
    for enc in ('utf-8-sig', 'utf-8', 'gb18030'):
        with contextlib.suppress(UnicodeDecodeError):
            return raw.decode(enc)
    return raw.decode('gb18030', errors='replace')


def parse_ts(text):
    if not text:
        return None
    text = re.sub(r'[年月./]', '-', str(text).strip())
    text = re.sub(r'[日号]', '', text).replace('T', ' ')
    text = re.sub(r'\s+', ' ', text).strip()
    for fmt in ('%Y-%m-%d %H:%M:%S', '%Y-%m-%d %H:%M', '%Y-%m-%d'):
        with contextlib.suppress(ValueError):
            return dt.datetime.strptime(text, fmt).timestamp()
    if re.fullmatch(r'\d{9,13}', text):
        value = int(text)
        return value / 1000 if len(text) > 10 else float(value)
    return None


def detect_kind(content):
    for pattern, kind in KIND_MARKS:
        if pattern.search(content):
            return kind
    return 'text'


def map_kind(raw):
    return KIND_TABLE.get(str(raw).strip().lower(), 'text')


def parse_text(text):
    """逐行文本格式：消息头独占一行（时间+昵称），其后行为消息内容，多行自动合并。"""
    messages, current, title_hint = [], None, None
    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        stripped = line.strip()
        if not stripped or stripped.startswith('=') or re.fullmatch(r'-{5,}', stripped):
            continue
        match = re.match(r'^消息对象[:：]\s*(.+)$', stripped)
        if match:
            title_hint = match.group(1).strip()
            continue
        head = _HEAD_TS_FIRST.match(stripped) or _HEAD_WHO_FIRST.match(stripped)
        if head and parse_ts(head.group('ts')) is not None:
            if current:
                messages.append(current)
            current = {'sender': head.group('who').strip()[:50], 'content': '',
                       'sent_at': parse_ts(head.group('ts')), 'kind': None}
            continue
        if current is not None:
            current['content'] += ('\n' if current['content'] else '') + line
    if current:
        messages.append(current)
    return messages, title_hint


def _map_columns(fieldnames):
    mapping = {}
    for field in fieldnames:
        key = (field or '').strip().lower()
        for canonical, aliases in COLUMN_ALIASES.items():
            if key in aliases and canonical not in mapping:
                mapping[canonical] = field
    return mapping


def parse_csv_text(text):
    sample = text[:4096]
    with contextlib.suppress(csv.Error):
        dialect = csv.Sniffer().sniff(sample, delimiters=',\t;')
        reader = csv.DictReader(io.StringIO(text), dialect=dialect)
        return _csv_rows(reader)
    return [], None


def _csv_rows(reader):
    if not reader.fieldnames:
        return [], None
    mapping = _map_columns(reader.fieldnames)
    if 'content' not in mapping:
        return [], None
    messages = []
    for row in reader:
        content = (row.get(mapping['content']) or '').strip()
        if not content:
            continue
        sender = (row.get(mapping.get('sender') or '', '') or '').strip()
        sent_at = parse_ts(row.get(mapping.get('time') or '', '')) if mapping.get('time') else None
        kind = map_kind(row.get(mapping['kind'], '')) if mapping.get('kind') else None
        messages.append({'sender': (sender or '对方')[:50], 'content': content, 'sent_at': sent_at, 'kind': kind})
    return messages, None


def parse_json_text(text):
    data = json.loads(text)
    if isinstance(data, dict):
        data = data.get('messages') or data.get('data') or data.get('records') or data.get('list') or []
    messages = []
    for item in data if isinstance(data, list) else []:
        if not isinstance(item, dict):
            continue
        lower = {str(k).strip().lower(): v for k, v in item.items()}

        def pick(canonical):
            for alias in COLUMN_ALIASES[canonical]:
                if lower.get(alias) is not None:
                    return lower[alias]
        content = pick('content')
        if content is None or not str(content).strip():
            continue
        messages.append({'sender': str(pick('sender') or '对方')[:50], 'content': str(content).strip(),
                         'sent_at': parse_ts(str(pick('time') or '')),
                         'kind': map_kind(pick('kind')) if pick('kind') else None})
    return messages, None


def parse_zip(raw: bytes, max_images: int = 2000, max_unpacked_bytes: int = MAX_ZIP_UNPACKED_BYTES,
              max_entries: int = MAX_ZIP_ENTRIES):
    """带媒体的 zip 导出（如留痕）：取最大的 txt/csv 解析文本，图片按文件名与消息内容匹配。

    返回与 parse_file 相同的 (messages, title_hint) 签名；图片数据通过
    message['media_bytes'] / message['media_name'] 附加在匹配的消息上。
    """
    images = {}
    texts = []
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        entries = archive.infolist()
        if len(entries) > max_entries:
            raise ValueError('ZIP 文件包含过多条目')
        if sum(info.file_size for info in entries if not info.is_dir()) > max_unpacked_bytes:
            raise ValueError('ZIP 文件解压后体积过大')
        image_count = 0
        for info in entries:
            if info.is_dir():
                continue
            if info.file_size > MAX_ZIP_MEMBER_BYTES:
                raise ValueError('ZIP 中的单个文件体积过大')
            name = PurePosixPath(info.filename)
            if '..' in name.parts or name.is_absolute():
                continue  # 防 zip slip
            suffix = name.suffix.lower()
            if suffix in IMAGE_EXTS:
                image_count += 1
                if image_count > max_images:
                    raise ValueError('ZIP 中的图片数量过多')
                images[name.name.lower()] = archive.read(info)
            elif suffix in {'.txt', '.csv', '.json'}:
                texts.append((info.file_size, info.filename, archive.read(info)))
    if not texts:
        return [], None
    texts.sort(reverse=True)
    messages, title_hint = parse_file(texts[0][1], texts[0][2])
    for message in messages:
        content = message['content']
        if message['kind'] in {'text', 'image'}:
            lower = content.lower()
            matched = next((fname for fname in images if fname in lower or fname.replace('_', '') in lower.replace('_', '')), None)
            if matched:
                message['media_bytes'] = images.pop(matched)
                message['media_name'] = matched
                message['kind'] = 'image'
    return messages, title_hint


def parse_file(filename, raw: bytes, platform='auto'):
    """入口：按扩展名/内容特征选择解析器，返回 (messages, title_hint)。"""
    text = decode_bytes(raw)
    name = (filename or '').lower()
    first = text.lstrip()[:1]
    messages, title_hint = [], None
    if name.endswith('.json') or first in '[{':
        with contextlib.suppress(json.JSONDecodeError):
            messages, title_hint = parse_json_text(text)
    if not messages and (name.endswith('.csv') or name.endswith('.tsv')):
        messages, title_hint = parse_csv_text(text)
    if not messages:
        messages, title_hint = parse_text(text)
    if not messages and first not in '[{':
        messages, title_hint = parse_csv_text(text)
    for message in messages:
        if not message.get('kind'):
            message['kind'] = detect_kind(message['content'])
    if len(messages) > MAX_MESSAGES:
        messages = messages[:MAX_MESSAGES]
    return messages, title_hint


def summarize(messages):
    participants = sorted({m['sender'] for m in messages if m['sender'] and m['sender'] != '对方'})
    times = [m['sent_at'] for m in messages if m['sent_at']]
    return {'count': len(messages), 'participants': participants,
            'start_at': min(times) if times else None, 'end_at': max(times) if times else None}
