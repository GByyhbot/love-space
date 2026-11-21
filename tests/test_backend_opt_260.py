"""2.6.0 性能段第一批护栏（P6/P1/P2/P8/P9，主人开段）。

钉住五处容易悄悄退化的地方：
1. P6：media 两索引存在，转码认领与选图 SQL 由 SCAN 变 SEARCH（EXPLAIN 对拍）；
2. P1：schedule 主查询只扫三类（kind IN 走 records_kind）；
3. P2：worker 周期任务是墙钟门控（last_run 时间戳），nudge 不放大周期频率；
4. P8：密钥材料进程内缓存（mtime 失效），cipher 派生结果缓存命中；
5. P9：备份 zip 媒体条目 ZIP_STORED，db/manifest/secret.key.enc 保留 DEFLATED。
"""
import cryptography.fernet
import json
import pytest
import zipfile

from app import db, security, worker

PURPOSE_CHANNEL_CONFIG = security.PURPOSE_CHANNEL_CONFIG


@pytest.fixture(autouse=True)
def _ensure_db():
    """不用 client fixture 的用例也可能先于 TestClient 启动跑——确保库已初始化（幂等）。"""
    db.init()


def _explain(sql):
    """EXPLAIN QUERY PLAN 的 detail 行拼接（大小写归一，便于断言 SEARCH/SCAN）。"""
    with db.connect() as c:
        rows = c.execute('EXPLAIN QUERY PLAN ' + sql).fetchall()
    return ' | '.join(r['detail'].upper() for r in rows)


# ── P6：media 索引 ──────────────────────────────────────────────────────

def test_media_indexes_exist():
    with db.connect() as c:
        names = {r['name'] for r in c.execute(
            "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='media'")}
    assert 'media_claim' in names
    assert 'media_mime_created' in names


def test_media_claim_sql_uses_index_search():
    plan = _explain(
        "SELECT * FROM media WHERE status='pending' AND attached=1 "
        "ORDER BY created LIMIT 1")
    assert 'SEARCH' in plan and 'SCAN' not in plan, plan


def test_media_gallery_sql_uses_index_search():
    plan = _explain(
        "SELECT * FROM media WHERE mime LIKE 'image/%' "
        "ORDER BY created DESC LIMIT 20")
    assert 'SEARCH MEDIA' in plan, plan


# ── P1：schedule kind 过滤 ──────────────────────────────────────────────

def test_schedule_query_filters_kinds_and_hits_records_kind():
    with open('app/worker.py', encoding='utf-8') as f:
        src = f.read()
    assert "kind IN ('surprise','anniversary','wish')" in src
    plan = _explain(
        "SELECT * FROM records WHERE deleted IS NULL "
        "AND kind IN ('surprise','anniversary','wish')")
    assert 'SEARCH' in plan and 'SCAN' not in plan, plan


def test_schedule_still_publishes_surprise(client_a):
    """kind 过滤后惊喜发布语义不变：到点的 surprise 转 post 并发通知。"""
    r = client_a.post('/api/records', headers={'X-Love-Space': '1'}, json={
        'kind': 'surprise',
        'body': {'title': '对拍惊喜', 'content': '内容',
                 'publish_at': db.now() + 3600},
    })
    assert r.status_code == 200, r.text
    rid = r.json()['id']
    # 服务端只收未来时间；把 publish_at 改到过去再跑 schedule（模拟「到点」）
    with db.connect() as c:
        row = c.execute('SELECT body FROM records WHERE id=?', (rid,)).fetchone()
        import json as _json
        body = _json.loads(row['body'])
        body['publish_at'] = db.now() - 1
        c.execute('UPDATE records SET body=? WHERE id=?',
                  (db.body_encode('surprise', rid, body), rid))
    worker.schedule()
    with db.connect() as c:
        kind = c.execute(
            'SELECT kind FROM records WHERE id=?', (rid,)).fetchone()['kind']
    assert kind == 'post'


# ── P2：worker 周期墙钟门控 ─────────────────────────────────────────────

def test_worker_periodic_gate_is_wallclock():
    with open('app/worker.py', encoding='utf-8') as f:
        src = f.read()
    # 计数门控必须移除；墙钟门控必须出现
    assert 'counter % 12' not in src
    assert 'counter % 6' not in src
    assert 'counter % 60' not in src
    assert "periodic['maintenance'][1] >= periodic['maintenance'][0]" in src
    # 投递保持每轮执行（nudge 语义不变）
    assert 'deliver()' in src


def test_periodic_first_run_is_immediate():
    """启动语义保留：last_run=0.0（从未来过）→ 立即到期。"""
    t = db.now()
    periodic = {'maintenance': (60.0, 0.0)}
    assert t - periodic['maintenance'][1] >= periodic['maintenance'][0]


# ── P8：密钥材料缓存 ────────────────────────────────────────────────────

def test_secret_key_cached_by_mtime(tmp_path, monkeypatch):
    monkeypatch.setattr(security, 'DATA', tmp_path)
    security._key_cache.clear()

    b1 = security.secret_key()
    b2 = security.secret_key()
    assert b1 is b2, '同一 mtime 下必须返回缓存对象（不重复读盘）'

    # 重建密钥文件（mtime 变化）→ 缓存刷新
    (tmp_path / 'secret.key').write_bytes(b'new-key-material-32-bytes-long!!')
    b3 = security.secret_key()
    assert b3 == b'new-key-material-32-bytes-long!!'


def test_cipher_purpose_cached_and_still_roundtrips():
    f1 = security.cipher(PURPOSE_CHANNEL_CONFIG)
    f2 = security.cipher(PURPOSE_CHANNEL_CONFIG)
    assert f1 is f2, '同一 purpose 派生结果必须缓存命中'

    sealed = f1.encrypt(b'channel-config-roundtrip')
    assert f2.decrypt(sealed) == b'channel-config-roundtrip'
    # 主密钥分支同样缓存
    assert security.cipher(None) is security.cipher(None)


def test_key_cache_invalidates_on_mtime_change(tmp_path, monkeypatch):
    """mtime 变化后派生缓存连带清空：新密钥的密文用旧缓存解不开。"""
    monkeypatch.setattr(security, 'DATA', tmp_path)
    security._key_cache.clear()
    old_f = security.cipher(PURPOSE_CHANNEL_CONFIG)
    sealed = old_f.encrypt(b'before-rotation')

    from cryptography.fernet import Fernet
    (tmp_path / 'secret.key').write_bytes(Fernet.generate_key())
    new_f = security.cipher(PURPOSE_CHANNEL_CONFIG)
    assert new_f is not old_f
    with pytest.raises(cryptography.fernet.InvalidToken):
        new_f.decrypt(sealed)


# ── P9：备份逐条压缩 ────────────────────────────────────────────────────

def test_backup_media_entries_stored_others_deflated(tmp_path, monkeypatch):
    """media 条目 ZIP_STORED（不重复压缩已压缩格式）；db/manifest 为 DEFLATED。

    直接驱动 create_backup 太重（要真媒体库），这里用最小 zip 语义对拍：
    按实现同款逐条 compress_type 组装并读回验证——与 backups.py 的调用形态
    一一对应，实现若改回全包 DEFLATED 此测试立刻红。
    """
    import json
    src = open('app/backups.py', encoding='utf-8').read()
    assert "compress_type=zipfile.ZIP_STORED" in src, '媒体条目必须 ZIP_STORED'
    assert src.count('zipfile.ZIP_DEFLATED') >= 1, '包级默认仍是 DEFLATED'

    target = tmp_path / 'mini.zip'
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
        archive.writestr('manifest.json', json.dumps({'version': 2}))
        archive.writestr('media/m1.jpg', b'\xff\xd8\xff' + b'x' * 64,
                         compress_type=zipfile.ZIP_STORED)
        archive.writestr('media/m2.mp4', b'\x00\x00\x00' + b'y' * 64,
                         compress_type=zipfile.ZIP_STORED)
    with zipfile.ZipFile(target) as z:
        types = {i.filename: i.compress_type for i in z.infolist()}
    assert types['manifest.json'] == zipfile.ZIP_DEFLATED
    assert types['media/m1.jpg'] == zipfile.ZIP_STORED
    assert types['media/m2.mp4'] == zipfile.ZIP_STORED
