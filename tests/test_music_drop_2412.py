"""2.4.12 投放文件夹自动入库 + 顶层 dur 白名单。

锁死：
1. 合法音频（带标签/无标签）入库：music 记录 + 文件落 music/<月>/<id><ext> + attached=1；
2. 对方账号可见可播（非私密 music 记录 + body.media 引用）；
3. 非音频跳过且文件保留；新鲜文件（<2min）跳过；
4. 重复哈希：清单命中且媒体+记录仍在 → 删投放副本；
5. 歌单删歌后清单失效 → 重投可再入库；
6. 失败文件留投放夹、不热重试；
7. 顶层 dur 白名单：非负落库、非法丢弃。
"""
import json
import shutil
import time
from pathlib import Path

import pytest

from app import db, music_drop
from app.db import connect, now


@pytest.fixture
def drop_env(tmp_path, monkeypatch):
    """把投放夹/清单隔离到 tmp_path，owner 用现有第一个用户。"""
    drop = tmp_path / 'music-drop'
    drop.mkdir()
    imported = tmp_path / 'music-drop-imported.json'
    monkeypatch.setattr(music_drop, 'DROP_DIR', drop)
    monkeypatch.setattr(music_drop, 'IMPORTED', imported)
    monkeypatch.setattr(music_drop, '_probe', lambda p: (125, '测试歌曲', '测试歌手'))
    with connect() as c:
        row = c.execute('SELECT id FROM users WHERE admin=1 ORDER BY created LIMIT 1').fetchone()
        if not row:
            row = c.execute('SELECT id FROM users ORDER BY created LIMIT 1').fetchone()
        owner = row['id'] if row else None
        before = {r['id'] for r in c.execute("SELECT id FROM records WHERE kind='music'")}
        media_before = {r['id'] for r in c.execute('SELECT id FROM media')}
    yield drop, imported, owner
    # 清理本测试产生的 music 记录/媒体，避免污染共享库的年鉴 bigram 统计
    with connect() as c:
        created = [r['id'] for r in c.execute("SELECT id FROM records WHERE kind='music'") if r['id'] not in before]
        for rid in created:
            c.execute('DELETE FROM records WHERE id=?', (rid,))
        mids = [r['id'] for r in c.execute('SELECT id FROM media') if r['id'] not in media_before]
        for mid in mids:
            c.execute('DELETE FROM media WHERE id=?', (mid,))


@pytest.fixture(scope='module', autouse=True)
def _cleanup_2412():
    '''本文件全部用例跑完后清掉带 2412 标记的测试记录，避免污染年鉴 bigram 统计。'''
    yield
    with connect() as c:
        for r in c.execute("SELECT id FROM records WHERE client_id LIKE '%2412-cleanup%'").fetchall():
            c.execute('DELETE FROM records WHERE id=?', (r['id'],))


def _mp3(drop, name='song.mp3', age=3600):
    p = drop / name
    p.write_bytes(b'ID3' + b'\x00' * 100)   # 魔数过 audio/mpeg
    old = time.time() - age
    import os
    os.utime(p, (old, old))
    return p


def test_import_tagged_and_visible_to_partner(drop_env, client_a, client_b):
    drop, imported, owner = drop_env
    assert owner, '需要空间用户'
    src = _mp3(drop)
    stats = music_drop.scan_once()
    assert stats['imported'] == 1, stats
    assert not src.exists(), '投放副本必须搬走不是复制'
    with connect() as c:
        rec = c.execute("SELECT * FROM records WHERE kind='music' ORDER BY created DESC LIMIT 1").fetchone()
        body = json.loads(rec['body'])
        assert body['title'] == '测试歌曲'
        assert body['content'] == '测试歌手'
        assert body['dur'] == 125
        mid = body['media'][0]
        media = c.execute('SELECT * FROM media WHERE id=?', (mid,)).fetchone()
        assert media['zone'] == 'music' and media['attached'] == 1
        assert media['owner'] == owner
    folder = db.media_dir('music', 'audio/mpeg', media['created'])
    assert (folder / (mid + '.mp3')).is_file(), '文件落 music/<月>/<id><ext>'
    # 对方可见可播（music 非私密 + body.media 引用）
    resp = client_b.get('/media/' + mid)
    assert resp.status_code == 200, resp.text
    # 清单落 sha256
    entries = json.loads(imported.read_text(encoding='utf-8'))
    assert any(v.get('mid') == mid for v in entries.values())


def test_no_tag_uses_filename(drop_env, monkeypatch):
    drop, _, _ = drop_env
    monkeypatch.setattr(music_drop, '_probe', lambda p: (0, '', ''))
    _mp3(drop, '我的无名曲.mp3')
    assert music_drop.scan_once()['imported'] == 1
    with connect() as c:
        rec = c.execute("SELECT body FROM records WHERE kind='music' ORDER BY created DESC LIMIT 1").fetchone()
        body = json.loads(rec['body'])
    assert body['title'] == '我的无名曲'
    assert body['dur'] == 0


def test_non_audio_and_fresh_skipped(drop_env):
    drop, _, _ = drop_env
    other = drop / 'notes.txt'
    other.write_text('x')
    fresh = _mp3(drop, 'fresh.mp3', age=10)
    stats = music_drop.scan_once()
    assert stats['imported'] == 0
    assert other.exists() and fresh.exists(), '跳过文件不删'
    assert stats['skipped'] >= 2


def test_duplicate_hash_removes_copy(drop_env):
    drop, _, _ = drop_env
    src = _mp3(drop)
    music_drop.scan_once()
    src2 = _mp3(drop, 'same.mp3')   # 同内容同哈希
    stats = music_drop.scan_once()
    assert stats['imported'] == 0 and stats['skipped'] >= 1
    assert not src2.exists(), '已入库副本删掉不留双份'


def test_deleted_song_allows_reimport(drop_env):
    drop, _, _ = drop_env
    _mp3(drop)
    music_drop.scan_once()
    with connect() as c:
        rec = c.execute("SELECT id FROM records WHERE kind='music' ORDER BY created DESC LIMIT 1").fetchone()
        c.execute('DELETE FROM records WHERE id=?', (rec['id'],))
    _mp3(drop, 'again.mp3')
    assert music_drop.scan_once()['imported'] == 1, '歌删了清单失效，重投可再入库'


def test_bad_magic_stays_no_hot_retry(drop_env, monkeypatch):
    drop, imported, _ = drop_env
    bad = drop / 'fake.mp3'
    bad.write_bytes(b'not audio at all')
    old = time.time() - 3600
    import os
    os.utime(bad, (old, old))
    calls = []
    monkeypatch.setattr(music_drop, '_probe', lambda p: calls.append(p) or (0, '', ''))
    first = music_drop.scan_once()
    assert first['failed'] == 1 and bad.exists()
    second = music_drop.scan_once()
    assert second['failed'] == 1 and bad.exists()
    assert not calls, '校验不过不读标签、不反复重试'
    entries = json.loads(imported.read_text(encoding='utf-8'))
    assert any(v.get('reason') for v in entries.values())


def test_top_level_dur_whitelist(client_a):
    """裁定1：顶层 dur 非负落库、非法丢弃（不 4xx 毁整条记录）。"""
    r = client_a.post('/api/records', headers={'X-Love-Space': '1'},
                      json={'kind': 'music', 'body': {'title': '韵律甲', 'dur': 321},
                            'client_id': 'dur-ok-2412-cleanup'})
    assert r.status_code == 200, r.text
    rid = r.json()['id']
    with connect() as c:
        row = c.execute('SELECT body FROM records WHERE id=?', (rid,)).fetchone()
        assert json.loads(row['body']).get('dur') == 321
    for i, bad in enumerate((-1, 'abc', None)):
        r = client_a.post('/api/records', headers={'X-Love-Space': '1'},
                          json={'kind': 'music', 'body': {'title': '韵律乙', 'dur': bad},
                                'client_id': 'dur-bad-2412-cleanup-%d' % i})
        assert r.status_code == 200, r.text
        with connect() as c:
            row = c.execute('SELECT body FROM records WHERE id=?', (r.json()['id'],)).fetchone()
            assert 'dur' not in json.loads(row['body']), bad
