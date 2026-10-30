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
from datetime import date


import pytest

from conftest import HEADERS, PASSWORD
from app import db, period


def dt_date(value):
    """测试里日期都写成字符串，转一下，省得数月份。"""
    return date.fromisoformat(value)


def clear_period():
    """清掉库里已有的经期行：这几个测试要断言完整的统计结果，不能被样例数据干扰。"""
    with period.connect() as c:
        c.execute('DELETE FROM period')


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
    # 老的纯编号写法会被归一成"一次记录"的形状，前端只处理一种
    assert body['sex'] == [{'t': '', 'w': [2]}, {'t': '', 'w': [4]}]
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


def test_period_sex_entries_keep_time_and_count(client_a):
    """爱爱一天可以好几次：每次带自己的措施和时间，落库后原样能读回来。"""
    r = client_a.post('/api/records', headers=HEADERS, json={'kind': 'period', 'body': {
        'date': '2026-10-30',
        'sex': [{'t': '16:14', 'w': [2]}, {'t': '23:05', 'w': [1, 10]}, {'t': '', 'w': []}]}})
    assert r.status_code == 200, r.text
    assert r.json()['body']['sex'] == [
        {'t': '16:14', 'w': [2]},
        {'t': '23:05', 'w': [1, 10]},
        {'t': '', 'w': []},
    ]


def test_period_sex_rejects_bad_time(client_a):
    """时间必须是 HH:MM，乱写不许落库。"""
    for when in ('25:00', '12:60', '9:5', 'abc', 1614):
        r = client_a.post('/api/records', headers=HEADERS, json={'kind': 'period', 'body': {
            'date': '2026-10-30', 'sex': [{'t': when, 'w': [2]}]}})
        assert r.status_code == 422, (when, r.text)


def test_period_episodes_merge_adjacent_fragments(client_a):
    """一次月经被拆成两行（隔天又「月经又来了」）时，统计上必须合成一段。

    不合并的话：平均经期被腰斩、周期天数直接变成 3 天，后台提醒日期也会跟着错。
    """
    clear_period()
    make_period(client_a, '2026-05-27', length=3)
    make_period(client_a, '2026-05-30', length=1)
    make_period(client_a, '2026-06-21', length=4)
    assert [(s.isoformat(), e.isoformat()) for s, e in period.episodes()] == [
        ('2026-05-27', '2026-05-30'),
        ('2026-06-21', '2026-06-24'),
    ]
    stats = period.cycle_stats(today=dt_date('2026-06-25'))
    assert stats['episodes'] == 2
    assert stats['gaps'] == [25]
    assert stats['cycle'] == 25
    assert stats['length'] == 4          # (4 + 4) / 2，不是被碎片拉成 2
    assert stats['next_start'].isoformat() == '2026-07-16'
    assert stats['in_period'] is False   # 这一段是 06-21~06-24，06-25 已经结束了
    assert period.cycle_stats(today=dt_date('2026-06-23'))['in_period'] is True
    assert stats['last_length'] == 4


def test_period_reminder_windows(client_a):
    """只发三种：提前 N 天、当天、推迟 3 天以上；其他时候静默。"""
    clear_period()
    make_period(client_a, '2026-05-01', length=4)
    make_period(client_a, '2026-05-26', length=4)      # 间隔 25 → 下次 06-20
    stats = period.cycle_stats(today=dt_date('2026-06-01'))
    assert stats['next_start'].isoformat() == '2026-06-20'

    assert period.reminder(stats, dt_date('2026-06-10')) is None
    title, key = period.reminder(stats, dt_date('2026-06-18'))
    assert '2 天后' in title and key == 'period-soon:2026-06-20'
    title, key = period.reminder(stats, dt_date('2026-06-20'))
    assert '今天' in title and key == 'period-today:2026-06-20'
    # 推迟到第 3 天才开始催，前两天大概率只是算得不准
    assert period.reminder(stats, dt_date('2026-06-22')) is None
    title, key = period.reminder(stats, dt_date('2026-06-23'))
    assert '推迟 3 天' in title and key == 'period-late:2026-06-20'


def test_period_reminder_ignores_empty_and_short_samples(client_a):
    clear_period()
    assert period.cycle_stats() is None
    assert period.reminder(None, dt_date('2026-06-01')) is None
    make_period(client_a, '2026-06-01', length=4)
    stats = period.cycle_stats(today=dt_date('2026-06-02'))
    # 只有一段时没有间隔样本，按 28 天估算，别在当天就催
    assert stats['gaps'] == []
    assert stats['cycle'] == 28
    assert period.reminder(stats, dt_date('2026-06-02')) is None
