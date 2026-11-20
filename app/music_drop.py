"""投放文件夹自动入库（2.4.12 条目四）。

主人把音频文件丢进 data/music-drop/（容器内 /data/music-drop/），本模块自动：
· 只扫顶层文件，子目录忽略并记日志；
· 最近 2 分钟内修改的文件跳过（防拷一半的半成品）；
· 白名单 + 魔数嗅探校验，sha256 查防重清单；
· 建媒体行（zone=music）→ 文件搬移 → 建 kind='music' 记录 → 挂载；
· 防重清单 data/music-drop-imported.json：命中且媒体仍在 → 删投放副本（已入库副本不留双份）；
· 失败文件留在投放夹、记清单原因，文件没变化不热重试。

不 import app.main（避免循环依赖），音频嗅探与 MIME_EXT 在本模块内独立实现。
"""
import hashlib
import json
import logging
import shutil
import subprocess
from pathlib import Path

from . import db
from .db import connect, dumps, now

log = logging.getLogger('love.music-drop')

DROP_DIR = db.DATA / 'music-drop'
IMPORTED = db.DATA / 'music-drop-imported.json'
FRESH_SECONDS = 120          # 2 分钟内修改的视为半成品
AUDIO_EXT = {'.mp3': 'audio/mpeg', '.m4a': 'audio/mp4', '.aac': 'audio/aac',
             '.ogg': 'audio/ogg', '.opus': 'audio/ogg', '.wav': 'audio/wav',
             '.webm': 'audio/webm'}
_SNIFF = {
    'audio/mpeg': lambda b: b[:3] == b'ID3' or (len(b) > 1 and b[0] == 0xFF and (b[1] & 0xE0) == 0xE0),
    'audio/mp4': lambda b: b[4:8] == b'ftyp',
    'audio/aac': lambda b: len(b) > 1 and b[0] == 0xFF and (b[1] & 0xF0) == 0xF0,
    'audio/ogg': lambda b: b[:4] == b'OggS',
    'audio/wav': lambda b: b[:4] == b'RIFF' and b[8:12] == b'WAVE',
    'audio/webm': lambda b: b[:4] == b'\x1a\x45\xdf\xa3',
}


def _sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def _load_imported():
    if not IMPORTED.is_file():
        return {}
    try:
        data = json.loads(IMPORTED.read_text(encoding='utf-8'))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _save_imported(entries):
    IMPORTED.write_text(dumps(entries), encoding='utf-8')


def _probe(path):
    """ffprobe 取时长 + ID3/Vorbis 标签（ Debian ffmpeg 包含 ffprobe；不新增依赖）。

    返回 (dur_sec, title, artist)。失败返回 (0, '', '')。
    """
    try:
        out = subprocess.run(
            ['ffprobe', '-v', 'error', '-show_format', '-of', 'json', str(path)],
            capture_output=True, text=True, timeout=30, check=False)
        if out.returncode != 0:
            return (0, '', '')
        fmt = json.loads(out.stdout).get('format', {})
        dur = 0
        try:
            dur = max(0, min(86400, int(float(fmt.get('duration') or 0))))
        except (TypeError, ValueError):
            pass
        tags = fmt.get('tags') or {}
        lower = {str(k).lower(): str(v).strip() for k, v in tags.items()}
        title = lower.get('title', '')
        artist = lower.get('artist') or lower.get('album_artist', '') or lower.get('performer', '')
        return (dur, title[:120], artist[:200])
    except (OSError, ValueError, subprocess.SubprocessError):
        return (0, '', '')


def _first_owner(c):
    """空间第一个用户 = /api/setup 建的 admin=1 用户。"""
    row = c.execute('SELECT id FROM users WHERE admin=1 ORDER BY created LIMIT 1').fetchone()
    if not row:
        row = c.execute('SELECT id FROM users ORDER BY created LIMIT 1').fetchone()
    return row['id'] if row else None


def scan_once():
    """扫一轮投放夹。返回 {'imported': n, 'skipped': m, 'failed': k}。"""
    DROP_DIR.mkdir(parents=True, exist_ok=True)
    imported = _load_imported()
    stats = {'imported': 0, 'skipped': 0, 'failed': 0}
    owner = None
    with connect() as c:
        owner = _first_owner(c)
    if not owner:
        log.warning('投放夹有文件但空间还没有用户，跳过本轮')
        return stats
    for path in sorted(DROP_DIR.iterdir()):
        if path.is_dir():
            log.info('投放夹子目录忽略：%s', path.name)
            stats['skipped'] += 1
            continue
        if not path.is_file():
            continue
        try:
            age = now() - path.stat().st_mtime
        except OSError:
            continue
        if age < FRESH_SECONDS:
            stats['skipped'] += 1
            continue
        suffix = path.suffix.lower()
        mime = AUDIO_EXT.get(suffix)
        if not mime:
            stats['skipped'] += 1
            log.info('投放文件非支持音频，跳过：%s', path.name)
            continue
        try:
            head = path.open('rb').read(32)
        except OSError:
            continue
        check = _SNIFF.get(mime)
        if check and not check(head):
            stats['failed'] += 1
            imported[_sha256(path)] = {'reason': '魔数校验不过', 'name': path.name, 'at': now()}
            _save_imported(imported)
            log.warning('投放文件魔数校验不过，留在投放夹：%s', path.name)
            continue
        digest = _sha256(path)
        entry = imported.get(digest)
        # 防重判定：清单命中 + 媒体行在 + 对应 music 记录仍在（删歌→清单失效→可重投）
        with connect() as c:
            dup = bool(entry and entry.get('mid') and
                       c.execute('SELECT 1 FROM media WHERE id=?', (entry['mid'],)).fetchone() and
                       entry.get('rid') and
                       c.execute("SELECT 1 FROM records WHERE id=? AND kind='music'",
                                 (entry['rid'],)).fetchone())
        if dup:
            # 已入库且媒体仍在：删投放副本（哈希与清单一致才删，宁可留着不误删）
            try:
                path.unlink(missing_ok=True)
                stats['skipped'] += 1
            except OSError:
                stats['skipped'] += 1
            continue
        dur, tag_title, tag_artist = _probe(path)
        title = tag_title or path.stem[:120]
        artist = tag_artist or ''
        ts = now()
        mid = db.uid()
        rid = db.uid()
        folder = db.media_dir('music', mime, ts)
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / (mid + suffix)
        try:
            shutil.move(str(path), str(target))   # 搬移不是复制
            with connect() as c:
                c.execute('BEGIN IMMEDIATE')
                c.execute('INSERT INTO media(id,owner,name,mime,size,ext,created,attached,zone)'
                          ' VALUES (?,?,?,?,?,?,?,?,?)',
                          (mid, owner, path.name[:200], mime, target.stat().st_size,
                           suffix, ts, 1, 'music'))
                body = {'title': title, 'content': artist,
                        'media': [mid], 'dur': dur}
                c.execute('INSERT INTO records(id,kind,author,body,created,updated,deleted,published)'
                          ' VALUES (?,?,?,?,?,?,NULL,?)',
                          (rid, 'music', owner, dumps(body), ts, ts, ts))
                db.bump_shared(c)
            imported[digest] = {'mid': mid, 'rid': rid, 'at': ts, 'name': path.name}
            _save_imported(imported)
            stats['imported'] += 1
            log.info('投放入库成功：%s → music 记录 %s', path.name, rid)
        except Exception:
            log.exception('投放入库失败，文件保留在投放夹：%s', path.name)
            imported[digest] = {'reason': '入库失败', 'name': path.name, 'at': now()}
            _save_imported(imported)
            stats['failed'] += 1
    return stats
