"""生理期独立库（period.db）：真的搬出去了，而不是只换个接口名。

覆盖四件事：
1. 写入只落在 period.db，主库 records 里查不到；
2. 两个人共用同一条周期：谁记的对方都看得见、都能改（没有共享/私密开关）；
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


def test_period_shared_between_both(client_a, client_b):
    """生理期没有共享/私密之分：谁记的对方都看得见，列表和详情同一口径。"""
    rec = make_period(client_a, '2026-07-01', shared=False, content='不想让她担心')
    other = client_b.get('/api/records?kind=period&limit=1000').json()
    assert any(item['id'] == rec['id'] for item in other)
    detail = client_b.get(f'/api/records/{rec["id"]}')
    assert detail.status_code == 200
    assert detail.json()['body']['content'] == '不想让她担心'
    # 老记录里残留的 shared 字段不再生效，也不会被再写回去
    assert 'shared' not in detail.json()['body']


def test_period_edit_and_recycle(client_a, client_b):
    rec = make_period(client_a, '2026-05-01')
    # 谁都能改：没有「替谁记」的边界，两个人维护同一条周期
    edited = client_b.put(f'/api/records/{rec["id"]}', headers=HEADERS,
                          json={'kind': 'period', 'body': {'start': '2026-05-01', 'length': 6,
                                                           'content': '一起补一句'}})
    assert edited.status_code == 200, edited.text
    assert edited.json()['body']['content'] == '一起补一句'
    assert edited.json()['body']['length'] == 6
    # 谁都能删；回收站按人分，只有作者自己能恢复
    assert client_b.delete(f'/api/records/{rec["id"]}').status_code == 200
    assert period_row(rec['id'])['deleted'] is not None
    listed = {item['id'] for item in client_a.get('/api/records?kind=period&limit=1000').json()}
    assert rec['id'] not in listed
    assert client_b.post(f'/api/records/{rec["id"]}/restore', headers=HEADERS).status_code == 404
    assert client_a.post(f'/api/records/{rec["id"]}/restore', headers=HEADERS).status_code == 200
    assert period_row(rec['id'])['deleted'] is None
    # 旧的「整体共享 / 收回」接口已经下线
    assert client_a.post('/api/period/share', headers=HEADERS,
                         json={'shared': True}).status_code in (404, 405)


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


def make_day_log(client, date='2026-10-30', **body):
    r = client.post('/api/records', headers=HEADERS,
                    json={'kind': 'period', 'body': {'date': date, **body}})
    assert r.status_code == 200, r.text
    return r.json()


def test_period_day_log_shared_and_editable(client_a, client_b):
    """按天记的身体细节：同一种 kind，靠「有 date 没 start」区分，双方都能看能改。"""
    rec = make_day_log(client_a, flow=4, color=3, pain=2, mood=12, sex=[2, 4],
                       symptoms=['腹痛', '腰酸'], weight=52.4, temp=36.6,
                       discharge=3, content='今天腰很酸')
    body = rec['body']
    assert 'start' not in body
    assert (body['flow'], body['color'], body['pain'], body['mood']) == (4, 3, 2, 12)
    assert body['sex'] == [2, 4]
    assert body['weight'] == 52.4 and body['temp'] == 36.6
    other = client_b.get('/api/records?kind=period&limit=1000').json()
    assert any(item['id'] == rec['id'] for item in other)
    updated = client_b.put(f'/api/records/{rec["id"]}', headers=HEADERS,
                           json={'kind': 'period', 'body': {**body, 'pain': 5}})
    assert updated.status_code == 200, updated.text
    assert updated.json()['body']['pain'] == 5


def test_period_day_log_rejects_bad_levels(client_a):
    """档位越界一律 422：这些字段是给人点的按钮，不该出现 9 档经量这种数据。"""
    for patch in ({'flow': 9}, {'flow': '很多'}, {'color': 6}, {'pain': 0},
                  {'mood': 21}, {'discharge': 6}, {'sex': [11]}, {'sex': ['避孕套']},
                  {'weight': 500}, {'weight': 10}, {'temp': 20}, {'temp': 50}):
        r = client_a.post('/api/records', headers=HEADERS,
                          json={'kind': 'period', 'body': {'date': '2026-10-30', **patch}})
        assert r.status_code == 422, (patch, r.text)


def test_period_needs_start_or_date(client_a):
    """既没有 start 也没有 date 的 period 行没有意义，直接拦掉。"""
    r = client_a.post('/api/records', headers=HEADERS,
                      json={'kind': 'period', 'body': {'flow': 3}})
    assert r.status_code == 422
