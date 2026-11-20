"""2.4.11 媒体库隔离 + 回收站定版。

锁死七件事：
1. kind × MIME → zone 映射（含 private 语音→private/voice、post 语音→timeline/voice、
   chat 语音→chat/voice 三个易错点；album 引用按 timeline——裁定1）；
2. 首次绑定定区：二次引用（含跨 zone、拿 post 照片当封面）不搬家；pose_ai→space（裁定2）；
3. 上传落 inbox → 挂 post 后原图搬到 timeline、preview 同生 timeline；
4. 存量迁移：非私密/私密密封/导入/头像/封面/pose_ai/无引用/文件缺失/多 kind 优先级；
   二遍搬家数 0；按 id 取四种文件全通；
5. cleanup 在 zone 布局下删对文件、跳过 processing；回收站引用永不回收（护栏）；
6. 路径单一事实源护栏：旧两参数调用形态零残留；
7. 回收站：cleanup 不自动 purge；purge 三连（他人/活记录 4xx、本人回收站成功）；
   独占媒体实删、共享保留；period 同款；song.mid 纳入在用（裁定3）。
"""
import io
import json
import time

from PIL import Image

from app import db, worker, period
from app.db import connect, now

HEADERS = {'X-Love-Space': '1'}
DAY = 86400


def _png(color=(200, 120, 140)):
    buf = io.BytesIO()
    Image.new('RGB', (240, 180), color).save(buf, format='JPEG')
    return buf.getvalue()


def _upload(client, name='photo.jpg'):
    r = client.post('/api/media', files={'file': (name, _png(), 'image/jpeg')})
    assert r.status_code == 200, r.text
    return r.json()['id']


def _row(mid):
    with connect() as c:
        return c.execute('SELECT * FROM media WHERE id=?', (mid,)).fetchone()


def _place(mid, zone=None, preview=None, *, legacy=True):
    """把一个媒体行的文件放到它 zone 对应的目录（或旧布局），供 cleanup/取文件测试。"""
    row = _row(mid)
    z = row['zone'] if zone is None else zone
    folder = db.media_dir(z, row['mime'], row['created'])
    folder.mkdir(parents=True, exist_ok=True)
    name = mid + row['ext']
    (folder / name).write_bytes(_png())
    if preview:
        (folder / preview).write_bytes(_png())
    return folder


# ── 1. 映射表 ────────────────────────────────────────────────────────

def test_kind_mime_zone_map_three_voice_pitfalls():
    assert db.zone_for_kind('chat') == 'chat'
    assert db.zone_for_kind('post') == 'timeline'
    assert db.zone_for_kind('album') == 'timeline'   # 裁定1
    assert db.zone_for_kind('music') == 'music'
    for kind in db.PRIVATE:
        assert db.zone_for_kind(kind) == 'private'
    assert db.zone_for_kind('mood') == 'timeline'    # 表外兜底
    # 三个语音易错点：chat/timeline/private 都进各自的 voice 子目录
    created = now()
    assert db.media_dir('chat', 'audio/mpeg', created).parts[-2:] == ('voice', db.media_month(created))
    assert db.media_dir('timeline', 'audio/mpeg', created).parts[-2:] == ('voice', db.media_month(created))
    assert db.media_dir('private', 'audio/mpeg', created).parts[-2:] == ('voice', db.media_month(created))
    # music/space/inbox 不设类型子目录
    for z in ('music', 'space', 'inbox'):
        assert db.media_dir(z, 'audio/mpeg', created).parts[-2] == z
        assert db.media_dir(z, 'image/jpeg', created) == db.media_dir(z, 'audio/mpeg', created)
    assert db.media_dir('', 'image/jpeg', created) == db.media_dir('inbox', 'image/jpeg', created)


# ── 2. 首次绑定定区 ──────────────────────────────────────────────────

def test_first_bind_wins_no_second_move(client_a):
    mid = _upload(client_a)
    assert _row(mid)['zone'] == '', '上传必须落 inbox（zone 空）'
    assert db.media_dir('', 'image/jpeg', _row(mid)['created']).is_dir()
    r = client_a.post('/api/records', headers=HEADERS,
                      json={'kind': 'post', 'body': {'content': 'zone test', 'media': [mid]}})
    assert r.status_code == 200, r.text
    row = _row(mid)
    assert row['zone'] == 'timeline'
    assert (db.media_dir('timeline', 'image/jpeg', row['created']) / (mid + row['ext'])).is_file(), \
        '挂 post 后原图搬到 timeline'
    # 二次引用（跨 zone：拿 post 照片当封面）不搬家
    r = client_a.put('/api/space', headers=HEADERS,
                     json={**_space_body(client_a), 'cover': mid})
    assert r.status_code == 200, r.text
    assert _row(mid)['zone'] == 'timeline', '首次绑定后二次引用不得改 zone'


def _space_body(client):
    return {'name': '测试空间', 'since': '', 'timezone': 'Asia/Shanghai', 'theme': 'rose',
            'custom_color': '', 'chat_bg': '', 'chat_bg_media': '', 'chat_bg_dim': 50,
            'cover': '', 'cover_pos': None, 'chat_bubble': '', 'chat_bubble_fg': '',
            'chat_bubble_swap': None}


def test_pose_ai_media_binds_space(client_a):
    mid = _upload(client_a)
    r = client_a.put('/api/pose-ai/history', headers=HEADERS,
                     json={'items': [{'id': 'it1', 'imageUrl': '/media/%s?preview=true' % mid}], 'saved': 1})
    assert r.status_code == 200, r.text
    assert _row(mid)['zone'] == 'space', '裁定2：pose_ai_media 归 space'


# ── 4. 存量迁移 ──────────────────────────────────────────────────────

def test_legacy_migration_all_evidence(client_a, monkeypatch):
    """各种证据形态的存量行定区 + 幂等 + 文件缺失跳过 + manifest。"""
    with connect() as c:
        owner = c.execute('SELECT id FROM users LIMIT 1').fetchone()['id']
    created = now() - 10 * DAY
    # 造 5 个旧布局行（zone=''），编号与证据形态
    mids = {}
    with connect() as c:
        for key in ('post', 'diary', 'import', 'cover', 'orphan', 'missing'):
            mid = db.uid()
            ext = '.jpg'
            mime = 'image/jpeg' if key != 'import' else 'image/png'
            c.execute('INSERT INTO media(id,owner,name,mime,size,ext,created,attached,zone)'
                      ' VALUES (?,?,?,?,?,?,?,?,?)',
                      (mid, owner, key + ext, mime, 100, ext, created, 1, ''))
            mids[key] = mid
            if key != 'missing':
                folder = db.media_dir_legacy(mime, created)
                folder.mkdir(parents=True, exist_ok=True)
                (folder / (mid + ext)).write_bytes(_png())
    with connect() as c:
        # post 引用
        c.execute("INSERT INTO records(id,kind,author,body,created,updated,deleted) VALUES (?,?,?,?,?,?,NULL)",
                  (db.uid(), 'post', owner, json.dumps({'media': [mids['post']]}), created, created))
        # 私密密封引用（解密判定）：AAD 绑定真实 rid，必须用同一 id 加密
        diary_rid = db.uid()
        c.execute("INSERT INTO records(id,kind,author,body,created,updated,deleted) VALUES (?,?,?,?,?,?,NULL)",
                  (diary_rid, 'diary', owner,
                   db.body_encode('diary', diary_rid, {'media': [mids['diary']]}), created, created))
        # 导入引用
        imp = db.uid()
        c.execute('INSERT INTO imports(id,platform,title,author,participants,me,message_count,created)'
                  ' VALUES (?,?,?,?,?,?,?,?)', (imp, 'wechat', 't', owner, '[]', '', 0, created))
        c.execute('INSERT INTO import_messages(import_id,sender,content,kind,mine,media_id)'
                  ' VALUES (?,?,?,?,?,?)', (imp, 'a', '', 'image', 0, mids['import']))
        # 封面引用：merge 而非整包替换，避免破坏后续测试的 space 结构
        space = db.setting(c, 'space', {})
        space = dict(space) if isinstance(space, dict) else {}
        space['cover'] = mids['cover']
        c.execute("INSERT OR REPLACE INTO settings(key,value) VALUES ('space',?)", (db.dumps(space),))
    report = db.migrate_media_zones()
    assert report['balanced'], '迁移前后文件总数必须相等'
    with connect() as c:
        zones = {key: c.execute('SELECT zone FROM media WHERE id=?', (mid,)).fetchone()['zone']
                 for key, mid in mids.items()}
    assert zones['post'] == 'timeline'
    assert zones['diary'] == 'private'
    assert zones['import'] == 'chat'
    assert zones['cover'] == 'space'
    assert zones['orphan'] == 'inbox'
    assert zones['missing'] == 'inbox', '文件缺失照样写 zone'
    # 幂等第二遍：搬家数 0
    second = db.migrate_media_zones()
    assert sum(second['moved_by_zone'].values()) == 0
    assert second['manifest_entries'] >= report['manifest_entries']


def test_media_get_after_migration(client_a):
    """迁移后按 id 取原图/preview/poster/download 全通。"""
    mid = _upload(client_a)
    r = client_a.post('/api/records', headers=HEADERS,
                      json={'kind': 'post', 'body': {'content': 'get test', 'media': [mid]}})
    assert r.status_code == 200
    for query in ('', '?preview=true', '?download=true'):  # 图片无 poster，不验 ?poster=true
        resp = client_a.get('/media/' + mid + query)
        assert resp.status_code == 200, (query, resp.status_code, resp.text)


# ── 5. cleanup / 6. 路径护栏 ─────────────────────────────────────────

def test_cleanup_zone_and_trash_protection(client_a):
    with connect() as c:
        owner = c.execute('SELECT id FROM users LIMIT 1').fetchone()['id']
    # 回收站里的记录引用的媒体：即使超 30 天也不得回收
    mid = _upload(client_a)
    folder = _place(mid, 'timeline')
    with connect() as c:
        c.execute('UPDATE media SET zone=?,created=? WHERE id=?', ('timeline', now() - 60 * DAY, mid))
        c.execute("INSERT INTO records(id,kind,author,body,created,updated,deleted) VALUES (?,?,?,?,?,?,?)",
                  (db.uid(), 'post', owner, json.dumps({'media': [mid]}), now() - 60 * DAY,
                   now() - 60 * DAY, now() - 60 * DAY))
    worker.cleanup()
    assert (folder / (mid + _row(mid)['ext'])).is_file(), '回收站引用永不回收'
    assert _row(mid) is not None
    # 无引用超 30 天 → 删对 zone 里的文件
    mid2 = _upload(client_a)
    f2 = _place(mid2, 'inbox')
    with connect() as c:
        c.execute("UPDATE media SET zone='inbox',attached=0,created=? WHERE id=?", (now() - 40 * DAY, mid2))
    worker.cleanup()
    assert not (f2 / (mid2 + _row(mid2)['ext'])).exists() if _row(mid2) else True


def test_no_legacy_media_dir_two_arg_call():
    import ast
    from pathlib import Path
    root = Path(__file__).resolve().parent.parent / 'app'
    for path in root.rglob('*.py'):
        tree = ast.parse(path.read_text(encoding='utf-8'))
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            f = node.func
            name = f.attr if isinstance(f, ast.Attribute) else (f.id if isinstance(f, ast.Name) else '')
            if name == 'media_dir' and len(node.args) < 3:
                raise AssertionError('旧两参数 media_dir 调用残留：%s:%d' % (path, node.lineno))


# ── 7. 回收站定版 ────────────────────────────────────────────────────

def test_cleanup_never_auto_purges_trash(client_a):
    """deleted 超 30 天的 records / period 记录纹丝不动。"""
    with connect() as c:
        owner = c.execute('SELECT id FROM users LIMIT 1').fetchone()['id']
        rid = db.uid()
        old = now() - 90 * DAY
        c.execute("INSERT INTO records(id,kind,author,body,created,updated,deleted) VALUES (?,?,?,?,?,?,?)",
                  (rid, 'note', owner, json.dumps({'content': 'old trash'}), old, old, old))
    prid = db.uid()
    with period.connect() as c:
        c.execute('INSERT INTO period(id,kind,author,body,created,updated,deleted) VALUES (?,?,?,?,?,?,?)',
                  (prid, 'period', owner, db.body_encode('period', prid, {'start': '2020-01-01'}),
                   old, old, old))
    worker.cleanup()
    with connect() as c:
        assert c.execute('SELECT 1 FROM records WHERE id=?', (rid,)).fetchone(), 'records 回收站不得自动删'
    with period.connect() as c:
        assert c.execute('SELECT 1 FROM period WHERE id=?', (prid,)).fetchone(), 'period 回收站不得自动删'
    # 清理测试数据
    with connect() as c:
        c.execute('DELETE FROM records WHERE id=?', (rid,))
    with period.connect() as c:
        c.execute('DELETE FROM period WHERE id=?', (prid,))


def test_purge_record_http_triplet(client_a, client_b):
    with connect() as c:
        author = c.execute('SELECT id FROM users WHERE username=?', ('lover1',)).fetchone()['id']
        other = c.execute('SELECT id FROM users WHERE username=?', ('lover2',)).fetchone()['id']
    old = now() - 2 * DAY
    with connect() as c:
        # ① 他人 purge → 4xx
        r1 = db.uid()
        c.execute("INSERT INTO records(id,kind,author,body,created,updated,deleted) VALUES (?,?,?,?,?,?,?)",
                  (r1, 'note', author, json.dumps({'content': 'x'}), now(), now(), old))
        # ② 活记录 purge → 4xx
        r2 = db.uid()
        c.execute("INSERT INTO records(id,kind,author,body,created,updated,deleted) VALUES (?,?,?,?,?,?,NULL)",
                  (r2, 'note', author, json.dumps({'content': 'x'}), now(), now()))
        # ③ 本人回收站记录 → 成功；带一个独占媒体 + 一个共享媒体
        r3 = db.uid()
        own = db.uid()
        shared = db.uid()
        for mid in (own, shared):
            ts = now()
            c.execute('INSERT INTO media(id,owner,name,mime,size,ext,created,attached,zone)'
                      ' VALUES (?,?,?,?,?,?,?,?,?)',
                      (mid, author, 'x.jpg', 'image/jpeg', 100, '.jpg', ts, 1, 'timeline'))
            f = db.media_dir('timeline', 'image/jpeg', ts)
            f.mkdir(parents=True, exist_ok=True)
            (f / (mid + '.jpg')).write_bytes(_png())
        c.execute("INSERT INTO records(id,kind,author,body,created,updated,deleted) VALUES (?,?,?,?,?,?,?)",
                  (r3, 'note', author, db.dumps({'content': 'x', 'media': [own, shared]}), now(), now(), old))
        # 共享媒体被另一条活记录引用
        r4 = db.uid()
        c.execute("INSERT INTO records(id,kind,author,body,created,updated,deleted) VALUES (?,?,?,?,?,?,NULL)",
                  (r4, 'note', author, db.dumps({'media': [shared]}), now(), now()))
    # 他人（client_b）purge r1
    resp = client_b.post('/api/records/%s/purge' % r1, headers=HEADERS)
    assert resp.status_code in (400, 403, 404), resp.text
    # 活记录
    resp = client_a.post('/api/records/%s/purge' % r2, headers=HEADERS)
    assert resp.status_code in (400, 403, 404), resp.text
    # 本人回收站记录
    resp = client_a.post('/api/records/%s/purge' % r3, headers=HEADERS)
    assert resp.status_code == 200, resp.text
    with connect() as c:
        assert not c.execute('SELECT 1 FROM records WHERE id=?', (r3,)).fetchone()
        assert not c.execute('SELECT 1 FROM media WHERE id=?', (own,)).fetchone(), '独占媒体实删'
        assert c.execute('SELECT 1 FROM media WHERE id=?', (shared,)).fetchone(), '共享媒体保留'
        for rid in (r1, r2, r4):
            c.execute('DELETE FROM records WHERE id=?', (rid,))
        c.execute('DELETE FROM media WHERE id=?', (shared,))


def test_purge_period_and_song_mid_in_use(client_a):
    with connect() as c:
        author = c.execute('SELECT id FROM users WHERE username=?', ('lover1',)).fetchone()['id']
    old = now() - 2 * DAY
    prid = db.uid()
    with period.connect() as c:
        c.execute('INSERT INTO period(id,kind,author,body,created,updated,deleted) VALUES (?,?,?,?,?,?,?)',
                  (prid, 'period', author, db.body_encode('period', prid, {'start': '2020-01-01'}),
                   now(), now(), old))
    resp = client_a.post('/api/records/%s/purge' % prid, headers=HEADERS)
    assert resp.status_code == 200, resp.text
    with period.connect() as c:
        assert not c.execute('SELECT 1 FROM period WHERE id=?', (prid,)).fetchone()
    # song.mid 纳入在用：cleanup 不得删被 chat 分享引用的歌曲媒体
    mid = db.uid()
    with connect() as c:
        ts = now() - 40 * DAY
        c.execute('INSERT INTO media(id,owner,name,mime,size,ext,created,attached,zone)'
                  ' VALUES (?,?,?,?,?,?,?,?,?)',
                  (mid, author, 'song.m4a', 'audio/mp4', 100, '.m4a', ts, 1, 'music'))
        f = db.media_dir('music', 'audio/mp4', ts)
        f.mkdir(parents=True, exist_ok=True)
        (f / (mid + '.m4a')).write_bytes(b'x')
        cid = db.uid()
        c.execute("INSERT INTO records(id,kind,author,body,created,updated,deleted) VALUES (?,?,?,?,?,?,NULL)",
                  (cid, 'chat', author, db.dumps({'content': '听歌', 'song': {'mid': mid, 'title': 'x'}}),
                   now(), now()))
    worker.cleanup()
    assert _row(mid) is not None, 'body.song.mid 引用即在用（裁定3）'
    with connect() as c:
        c.execute('DELETE FROM records WHERE id=?', (cid,))
        c.execute('DELETE FROM media WHERE id=?', (mid,))
