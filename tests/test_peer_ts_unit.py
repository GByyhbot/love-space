"""轨迹时间戳单位修复令 · 回归护栏。

钉住：peer 轨迹点 ts 一律按 **unix 秒** 落库与读取——
1. 旧客户端发毫秒 → 写侧归一为秒落库，`/api/peer/track` 当日可查；
2. 新客户端发秒 → 原样落库，不被二次除；
3. 存量迁移（MIGRATIONS[4]）只改毫秒行、先备份、可重复执行（秒级数据零误伤）；
4. 读侧兜底：库里残留毫秒行（迁移漏网/老备份恢复）track 仍能按当日查到；
5. peer_events.ts 是秒，迁移不碰。
"""
import datetime as dt
import time

import pytest

from app import db, peer

HEADERS = {'X-Love-Space': '1'}


def _uid(client):
    return client.get('/api/me', headers=HEADERS).json()['user']['id']


def _today_noon():
    """空间时区「今天」12:00 的 unix 秒（避开跨午夜的日界抖动）。"""
    with db.connect() as c:
        day = peer._space_day(c, time.time())
        tz = peer.ZoneInfo((db.setting(c, 'space') or {}).get('timezone', 'Asia/Shanghai'))
    noon = dt.datetime.strptime(day, '%Y-%m-%d').replace(hour=12, tzinfo=tz).timestamp()
    return day, noon


@pytest.fixture(autouse=True)
def _clean(client_a, client_b):
    """轨迹接口要求空间两人齐（peer_partner），故依赖双方夹具。"""
    yield
    with db.connect() as c:
        c.execute('DELETE FROM peer_location_points')
        c.execute('DELETE FROM peer_location_latest')
        c.execute("DELETE FROM peer_events WHERE id LIKE 'tsu-%'")
        c.execute("DELETE FROM app_state WHERE key LIKE 'peer_settings:%'")
        c.execute("DELETE FROM app_state WHERE key='peer_ts_ms_migrated'")
        c.execute(f'DROP TABLE IF EXISTS {db.PEER_TS_BACKUP_TABLE}')


def _post(client, pts):
    r = client.post('/api/peer/location', headers=HEADERS, json={'points': pts})
    assert r.status_code == 200, r.text
    return r.json()


def _point(pid, ts, i=0):
    return {'id': pid, 'ts': ts, 'lat': 31.2304 + i * 1e-5, 'lng': 121.4737,
            'acc': 10.0, 'speed': 1.0}


def test_ts_to_sec_threshold():
    assert db.ts_to_sec(1795747933) == 1795747933.0
    assert db.ts_to_sec(1795747933537) == pytest.approx(1795747933.537)
    assert db.ts_to_sec(db.ts_to_sec(1795747933537)) == pytest.approx(1795747933.537)
    assert db.ts_to_sec('1795747933') == 1795747933.0


def test_old_client_millis_stored_as_seconds_and_track_visible(client_a):
    day, noon = _today_noon()
    pts = [_point(f'tsu-ms-{i}', int((noon + i * 30) * 1000), i) for i in range(3)]
    assert _post(client_a, pts)['accepted'] == 3
    with db.connect() as c:
        rows = c.execute("SELECT ts FROM peer_location_points WHERE id LIKE 'tsu-ms-%' "
                         'ORDER BY ts').fetchall()
    assert [r['ts'] for r in rows] == pytest.approx([noon, noon + 30, noon + 60])
    assert all(r['ts'] < db.TS_MS_THRESHOLD for r in rows)
    mine = client_a.get(f'/api/peer/track?date={day}', headers=HEADERS).json()['mine']
    assert len(mine['points']) == 3
    assert mine['points'][0]['ts'] == pytest.approx(noon)


def test_new_client_seconds_not_divided_again(client_a):
    day, noon = _today_noon()
    pts = [_point(f'tsu-s-{i}', noon + i * 30, i) for i in range(2)]
    assert _post(client_a, pts)['accepted'] == 2
    with db.connect() as c:
        rows = c.execute("SELECT ts FROM peer_location_points WHERE id LIKE 'tsu-s-%' "
                         'ORDER BY ts').fetchall()
    assert [r['ts'] for r in rows] == pytest.approx([noon, noon + 30])
    mine = client_a.get(f'/api/peer/track?date={day}', headers=HEADERS).json()['mine']
    assert len(mine['points']) == 2


def test_read_side_fallback_for_leftover_millis_rows(client_a):
    """绕过写侧直接塞毫秒行（模拟迁移漏网）→ track 读侧兜底仍可查，且 ts 以秒下发。"""
    day, noon = _today_noon()
    uid = _uid(client_a)
    with db.connect() as c:
        for i in range(2):
            c.execute('INSERT INTO peer_location_points(id,user,ts,lat,lng,acc,speed,backfill,created) '
                      'VALUES (?,?,?,?,?,?,?,0,?)',
                      (f'tsu-raw-{i}', uid, (noon + i * 30) * 1000.0, 31.23 + i * 1e-5,
                       121.47, 10.0, 1.0, db.now()))
    mine = client_a.get(f'/api/peer/track?date={day}', headers=HEADERS).json()['mine']
    assert [p['ts'] for p in mine['points']] == pytest.approx([noon, noon + 30])


def test_migration_converts_only_millis_backs_up_and_is_idempotent(client_a):
    _, noon = _today_noon()
    uid = _uid(client_a)
    with db.connect() as c:
        c.execute('INSERT INTO peer_location_points(id,user,ts,lat,lng,acc,speed,backfill,created) '
                  'VALUES (?,?,?,?,?,?,?,0,?)',
                  ('tsu-mig-ms', uid, noon * 1000.0, 31.23, 121.47, 10.0, 1.0, db.now()))
        c.execute('INSERT INTO peer_location_points(id,user,ts,lat,lng,acc,speed,backfill,created) '
                  'VALUES (?,?,?,?,?,?,?,0,?)',
                  ('tsu-mig-s', uid, noon, 31.23, 121.47, 10.0, 1.0, db.now()))
        c.execute('INSERT INTO peer_location_latest(user,lat,lng,updated,state_updated) '
                  'VALUES (?,?,?,?,?)', (uid, 31.23, 121.47, noon * 1000.0, noon))
        c.execute("INSERT INTO peer_events(id,user,type,ts,summary,pushed,created) "
                  "VALUES ('tsu-ev',?,'arrive',?,'x',0,?)", (uid, noon, db.now()))
        # 走真实迁移机制：把版本压回 3，init() 应只执行一次 MIGRATIONS[4]
        db.set_setting(c, 'schema_version', 3)
    db.init()
    with db.connect() as c:
        assert db.setting(c, 'schema_version') == max(db.MIGRATIONS)
        ts = {r['id']: r['ts'] for r in c.execute(
            "SELECT id,ts FROM peer_location_points WHERE id LIKE 'tsu-mig-%'")}
        assert ts == {'tsu-mig-ms': pytest.approx(noon), 'tsu-mig-s': pytest.approx(noon)}
        latest = c.execute('SELECT updated,state_updated FROM peer_location_latest WHERE user=?',
                           (uid,)).fetchone()
        assert latest['updated'] == pytest.approx(noon)
        assert latest['state_updated'] == pytest.approx(noon)
        bak = c.execute(f'SELECT id,ts FROM {db.PEER_TS_BACKUP_TABLE}').fetchall()
        assert [(r['id'], r['ts']) for r in bak] == [('tsu-mig-ms', noon * 1000.0)]
        assert c.execute("SELECT value FROM app_state WHERE key='peer_ts_ms_migrated'"
                         ).fetchone()[0] == 1
        ev = c.execute("SELECT ts FROM peer_events WHERE id='tsu-ev'").fetchone()['ts']
        assert ev == pytest.approx(noon), 'events.ts 本来是秒，迁移不许动'
        # 幂等：再跑一次迁移函数影响 0 行，秒级数据不被二次除
        again = db.migrate_peer_ts_to_sec(c)
        assert again == {'points': 0, 'latest_updated': 0, 'latest_state_updated': 0}
        ts2 = {r['id']: r['ts'] for r in c.execute(
            "SELECT id,ts FROM peer_location_points WHERE id LIKE 'tsu-mig-%'")}
        assert ts2 == ts
    # 重启（再 init）不重复执行
    db.init()
    with db.connect() as c:
        assert c.execute("SELECT value FROM app_state WHERE key='peer_ts_ms_migrated'"
                         ).fetchone()[0] == 1


def test_backup_rows_follow_point_retention(client_a):
    uid = _uid(client_a)
    old = db.now() - (peer.POINT_RETENTION_DAYS + 1) * 86400
    with db.connect() as c:
        c.execute('INSERT INTO peer_location_points(id,user,ts,lat,lng,acc,speed,backfill,created) '
                  'VALUES (?,?,?,?,?,?,?,0,?)',
                  ('tsu-ret', uid, old * 1000.0, 31.23, 121.47, 10.0, 1.0, old))
        db.migrate_peer_ts_to_sec(c)
        assert c.execute(f'SELECT count(*) FROM {db.PEER_TS_BACKUP_TABLE}').fetchone()[0] == 1
        peer.cleanup_expired(c, db.now())
        assert c.execute(f'SELECT count(*) FROM {db.PEER_TS_BACKUP_TABLE}').fetchone()[0] == 0
