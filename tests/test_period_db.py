"""生理期独立库（period.db）：真的搬出去了，而不是只换个接口名。

覆盖四件事：
1. 写入只落在 period.db，主库 records 里查不到；
2. 共享/私密的可见性语义没变（对方看不到私密那条，列表也不返回）；
3. 老数据迁移幂等，迁完主库不留 period 行；
4. 备份包里有 period.db，导出内容里有生理期。
"""
import io
import json
import zipfile

import pytest

from conftest import HEADERS, PASSWORD
from app import db, period


def make_period(client, start='2026-09-02', **body):
    r = client.post('/api/records', headers=HEADERS,
                    json={'kind': 'period', 'body': {'start': start, **body}})
    assert r.status_code == 200, r.text
    return r.json()


def me_id(client):
    return client.get('/api/me').json()['user']['id']


def main_rows(rid):
    with db.connect() as c:
        return c.execute('SELECT 1 FROM records WHERE id=?', (rid,)).fetchone()


def period_row(rid):
    return period.get(rid, include_deleted=True)


def test_period_lives_only_in_its_own_file(client_a):
    rec = make_period(client_a, '2026-08-11', content='这次腰很酸', flow='中', symptoms=['腰酸'])
    assert rec['kind'] == 'period'
    # 主库不该再有这一行
    assert main_rows(rec['id']) is None
    # 分库里有，而且是密文
    row = period_row(rec['id'])
    assert row is not None and row['kind'] == 'period'
    assert '_private_record' in json.loads(row['body'])
    # 明文不该出现在文件里
    raw = period.db_path().read_bytes()
    assert '这次腰很酸'.encode() not in raw
    # 列表接口照旧能取到（前端 recordsOf('period') 不用改）
    listed = client_a.get('/api/records?kind=period&limit=1000').json()
    assert any(item['id'] == rec['id'] for item in listed)
    # 详情也能取
    assert client_a.get(f'/api/records/{rec["id"]}').json()['body']['content'] == '这次腰很酸'


def test_period_privacy_still_works(client_a, client_b):
    private = make_period(client_a, '2026-07-01', shared=False, content='不想让她担心')
    shared = make_period(client_a, '2026-06-01', shared=True, content='这次还行')
    # 对方：私密那条列表里不出现、详情 404
    other = client_b.get('/api/records?kind=period&limit=1000').json()
    ids = {item['id'] for item in other}
    assert private['id'] not in ids
    assert shared['id'] in ids
    assert client_b.get(f'/api/records/{private["id"]}').status_code == 404
    # 本人两条都在
    mine = {item['id'] for item in client_a.get('/api/records?kind=period&limit=1000').json()}
    assert {private['id'], shared['id']} <= mine


def test_period_toggle_share_edits_and_recycle(client_a, client_b):
    rec = make_period(client_a, '2026-05-01', shared=True)
    # 批量收回
    out = client_a.post('/api/period/share', headers=HEADERS, json={'shared': False}).json()
    assert out['shared'] is False and out['total'] >= 1
    assert client_b.get(f'/api/records/{rec["id"]}').status_code == 404
    # 再放出来
    client_a.post('/api/period/share', headers=HEADERS, json={'shared': True})
    assert client_b.get(f'/api/records/{rec["id"]}').status_code == 200
    # 对方可以帮忙改内容，但拨不动隐私开关
    edited = client_b.put(f'/api/records/{rec["id"]}', headers=HEADERS,
                          json={'kind': 'period', 'body': {'start': '2026-05-01', 'shared': False,
                                                           'content': '替她补一句'}})
    assert edited.status_code == 200, edited.text
    assert edited.json()['body']['shared'] is True          # 开关仍是作者说了算
    assert edited.json()['body']['content'] == '替她补一句'
    # 删除 → 本人能在回收站看到 → 恢复
    assert client_a.delete(f'/api/records/{rec["id"]}').status_code == 200
    assert period_row(rec['id'])['deleted'] is not None
    trash = client_a.get('/api/records?trash=true&kind=period&limit=1000').json()
    assert any(item['id'] == rec['id'] for item in trash)
    assert client_a.post(f'/api/records/{rec["id"]}/restore', headers=HEADERS).status_code == 200
    assert period_row(rec['id'])['deleted'] is None


def test_legacy_period_rows_migrate_once(client_a):
    """模拟老库：主库里还躺着 period 行 → 启动迁移搬到分库，重复跑不再搬。"""
    rid = db.uid()
    ts = db.now()
    body = {'start': '2026-04-01', 'shared': True, 'content': '迁移前的旧记录'}
    with db.connect() as c:
        c.execute('INSERT INTO records VALUES (?,?,?,?,?,?,NULL,?,?)',
                  (rid, 'period', me_id(client_a),
                   db.body_encode('period', rid, body), ts, ts, ts, None))
    assert main_rows(rid) is not None

    assert period.migrate_from_main() >= 1
    assert main_rows(rid) is None                      # 主库已清干净
    moved = period_row(rid)
    assert moved is not None and db.body_decode(moved)['content'] == '迁移前的旧记录'
    assert period.migrate_from_main() == 0             # 幂等：没东西可搬了
    # 迁移前的 Safety copy 不该长期占着目录
    for junk in db.DATA.glob('love.db.before-period-split-*'):
        junk.unlink()
    # 迁过来的记录照常能读
    assert client_a.get(f'/api/records/{rid}').json()['body']['start'] == '2026-04-01'


def test_backup_contains_period_db(client_a, monkeypatch):
    monkeypatch.setenv('BACKUP_PASSWORD', 'backup-pass-123')
    from app.backups import create_backup
    make_period(client_a, '2026-03-01', content='备份要带上我')
    from app.backups import decrypt_bytes
    path = create_backup()
    # 产物是整包加密的 .zip.enc，先解开再看清单
    with zipfile.ZipFile(io.BytesIO(decrypt_bytes(path, 'backup-pass-123'))) as archive:
        names = set(archive.namelist())
    assert 'love.db' in names
    assert 'period.db' in names


def test_export_contains_period_records(client_a):
    make_period(client_a, '2026-02-01', content='导出也要有')
    from app.backups import user_export
    path = user_export(me_id(client_a))
    with zipfile.ZipFile(path) as archive:
        data = json.loads(archive.read('records.json'))
    assert any(item['kind'] == 'period' for item in data['records'])
