"""2.8.0 定位守护一期后端护栏。

钉住：批量上报与幂等、最新状态、轨迹/事件按日、四类开关与对等关闭态明示、
SOS 强推送、保留期滚动清理、SSE 第 7 段 peer_revision、写门禁。
引擎无关（纯表 + 接口），不依赖真机。
"""
import json

import pytest
from fastapi.testclient import TestClient

from app import db, peer
from app.main import app


@pytest.fixture
def nologin():
    with TestClient(app, base_url='https://testserver') as client:
        yield client

HEADERS = {'X-Love-Space': '1'}


@pytest.fixture(autouse=True)
def _peer_reset():
    """同一 pytest run 内所有测试共享同一 DATA_DIR——peer 开关存 app_state
    全局键，不重置会跨用例泄漏（首跑即抓：rejected 用例关 A 的开关，
    后续用例的 location POST 全部 422）。"""
    yield
    with db.connect() as c:
        c.execute('DELETE FROM peer_location_points')
        c.execute('DELETE FROM peer_events')
        c.execute('DELETE FROM peer_location_latest')
        c.execute("DELETE FROM app_state WHERE key LIKE 'peer_settings:%'")


def _pts(client, n=3, offset=0.0, backfill=False):
    now_ts = db.now()
    return [{'id': f'pt-{i}-{offset}',
             'ts': now_ts - i * 30 + offset,
             'lat': 31.2304 + offset * 1e-5 + i * 1e-5,
             'lng': 121.4737,
             'acc': 12.0, 'speed': 1.5,
             **({'backfill': True} if backfill else {})}
            for i in range(n)]


def test_peer_location_batch_and_latest(client_a):
    r = client_a.post('/api/peer/location', headers=HEADERS, json={
        'points': _pts(client_a, 3),
        'latest': {'lat': 31.23, 'lng': 121.47, 'acc': 10, 'speed': 0,
                   'battery': 80, 'charging': False, 'net': 'wifi',
                   'wifi': 'Home-5G'},
    })
    assert r.status_code == 200, r.text
    assert r.json()['accepted'] == 3
    with db.connect() as c:
        n = c.execute('SELECT count(*) n FROM peer_location_points').fetchone()['n']
        assert n == 3
        latest = c.execute(
            "SELECT * FROM peer_location_latest WHERE battery=80").fetchone()
    assert latest is not None and latest['wifi'] == 'Home-5G'


def test_peer_location_client_id_dedup(client_a):
    pts = _pts(client_a, 2)
    for _ in range(2):
        r = client_a.post('/api/peer/location', headers=HEADERS,
                          json={'points': pts})
        assert r.status_code == 200
    assert r.json()['accepted'] == 0, '补传重发不落重复点（client_id 幂等）'
    with db.connect() as c:
        n = c.execute('SELECT count(*) n FROM peer_location_points').fetchone()['n']
    assert n == 2


def test_peer_location_rejected_when_share_off(client_a):
    with db.connect() as c:
        peer.save_settings(c, client_a.get('/api/me', headers=HEADERS)
                           .json()['user']['id'], {'location': False})
    r = client_a.post('/api/peer/location', headers=HEADERS,
                      json={'points': _pts(client_a, 1)})
    assert r.status_code == 422
    assert '已关闭' in r.json()['detail']


def test_peer_status_shows_closed_off_explicitly(client_a, client_b):
    """对等口径 3.5：任一方关闭共享，对方端 status 明确 closed_off=true。"""
    with db.connect() as c:
        peer.save_settings(c, client_b.get('/api/me', headers=HEADERS)
                           .json()['user']['id'], {'location': False})
    r = client_a.get('/api/peer/status', headers=HEADERS).json()
    assert r['peer']['closed_off'] is True, '对方关闭定位必须明示'
    assert r['peer']['location'] is None or 'lat' not in (r['peer']['location'] or {})
    # 关闭方的 B 视角：自己正常
    rb = client_b.get('/api/peer/status', headers=HEADERS).json()
    assert rb['mine']['enabled'] is False
    assert rb['peer']['closed_off'] is False


def test_peer_track_and_events_by_date(client_a, client_b):
    r = client_a.post('/api/peer/location', headers=HEADERS,
                      json={'points': _pts(client_a, 3), 'latest': None})
    assert r.status_code == 200
    # B 的轨迹可见性默认开 → A 的点出现在 B 的当日轨迹里
    rb = client_b.get('/api/peer/track', headers=HEADERS).json()
    assert len(rb['peer']['points']) == 3
    assert rb['peer']['closed_off'] is False
    # A 关闭 track → B 查询时 closed_off 明示、points 空
    with db.connect() as c:
        peer.save_settings(c, client_a.get('/api/me', headers=HEADERS)
                           .json()['user']['id'], {'track': False})
    rb = client_b.get('/api/peer/track', headers=HEADERS).json()
    assert rb['peer']['closed_off'] is True and rb['peer']['points'] == []


def test_peer_events_flow_and_push_types(client_a, client_b):
    events = [
        {'id': 'e1', 'type': 'arrive_place', 'ts': db.now(),
         'summary': '到家了'},
        {'id': 'e2', 'type': 'unlock', 'ts': db.now() - 60, 'summary': '解锁手机'},
        {'id': 'e3', 'type': 'battery_low', 'ts': db.now() - 120,
         'summary': '电量低于 20%'},
    ]
    r = client_a.post('/api/peer/events', headers=HEADERS, json={'events': events})
    assert r.status_code == 200 and r.json()['accepted'] == 3
    rb = client_b.get('/api/peer/events', headers=HEADERS).json()
    types = {e['type'] for e in rb['peer']['events']}
    assert {'arrive_place', 'unlock', 'battery_low'} <= types
    # 关键类型 pushed=1（通知中心），普通入流不推送
    pushed = {e['type']: e['pushed'] for e in rb['peer']['events']}
    assert pushed['arrive_place'] == 1 and pushed['battery_low'] == 1
    assert pushed['unlock'] == 0


def test_peer_sos_strong_push(client_a):
    r = client_a.post('/api/peer/sos', headers=HEADERS)
    assert r.status_code == 200
    with db.connect() as c:
        row = c.execute('SELECT pushed, type FROM peer_events').fetchone()
        assert row['type'] == 'sos' and row['pushed'] == 2, 'SOS 强推送口径'


def test_peer_settings_roundtrip(client_a):
    """四开关契约不回退；2.8.7 起响应多一个 policy（映射表逐条断言）。"""
    r = client_a.get('/api/peer/settings', headers=HEADERS).json()
    assert {k: r[k] for k in peer.SHARE_KEYS} == {
        'location': True, 'track': True, 'events': True,
        'usage': True}, '缺省全开'
    # 迁移口径：全开 → 最高档（不许反过来默认全开）
    assert r['policy']['location_level'] == 'exact'
    assert r['policy']['usage_level'] == 'full'
    assert r['policy']['app_level'] == 'stream'
    assert r['policy']['network_level'] == 'ssid'

    r = client_a.put('/api/peer/settings', headers=HEADERS,
                     json={'location': False, 'usage': False}).json()
    assert {k: r[k] for k in peer.SHARE_KEYS} == {
        'location': False, 'track': True,
        'events': True, 'usage': False}
    # 老客户端只带四开关 → 反推出档位（关了就 off）
    assert r['policy']['location_level'] == 'off'
    assert r['policy']['usage_level'] == 'off'
    assert r['policy']['app_level'] == 'off'
    assert r['policy']['network_level'] == 'ssid'
    r = client_a.get('/api/peer/settings', headers=HEADERS).json()
    assert r['location'] is False and r['usage'] is False


def test_peer_batch_limits(client_a):
    r = client_a.post('/api/peer/location', headers=HEADERS,
                      json={'points': _pts(client_a, 51)})
    assert r.status_code == 422
    r = client_a.post('/api/peer/events', headers=HEADERS,
                      json={'events': [{'id': f'e{i}', 'type': 'unlock',
                                        'ts': db.now(), 'summary': ''}
                                       for i in range(101)]})
    assert r.status_code == 422


def test_peer_retention_cleanup(client_a, monkeypatch):
    """15 天滚动删除（worker maintenance 调 peer.cleanup_expired）。"""
    r = client_a.post('/api/peer/location', headers=HEADERS,
                      json={'points': _pts(client_a, 1)})
    assert r.status_code == 200
    old_ts = db.now() - 16 * 86400
    with db.connect() as c:
        c.execute('INSERT INTO peer_location_points'
                  '(id,user,ts,lat,lng,acc,speed,backfill,created) '
                  'VALUES (?,?,?,?,?,?,?,?,?)',
                  ('old-pt', client_a.get('/api/me', headers=HEADERS)
                   .json()['user']['id'],
                   old_ts, 31.0, 121.0, 10, 0, 0, old_ts))
        c.execute('INSERT INTO peer_events'
                  '(id,user,type,ts,summary,pushed,created) '
                  'VALUES (?,?,?,?,?,?,?)',
                  ('old-ev', client_a.get('/api/me', headers=HEADERS)
                   .json()['user']['id'],
                   'unlock', old_ts, '旧事件', 0, old_ts))
        from app import worker
        peer.cleanup_expired(c, db.now())
        pts = c.execute('SELECT count(*) n FROM peer_location_points').fetchone()['n']
        evs = c.execute('SELECT count(*) n FROM peer_events').fetchone()['n']
    assert pts == 1, '15 天内新点保留'
    assert evs == 0, '超期事件滚动删除'


def test_peer_revision_bumps_without_content_revision(client_a):
    """SSE 第 7 段：peer 更新推 peer_revision，不惊动 content_revision
    （不触发整站刷新——计划稿「不改既有事件语义」）。"""
    r0 = client_a.post('/api/peer/location', headers=HEADERS,
                       json={'points': _pts(client_a, 1, offset=9.0)})
    assert r0.status_code == 200
    with db.connect() as c:
        peer_rev = int(c.execute(
            "SELECT value FROM app_state WHERE key='peer_revision'").fetchone()[0])
        content_rev = int(c.execute(
            "SELECT value FROM app_state WHERE key='content_revision'").fetchone()[0])
    assert peer_rev >= 1
    base = content_rev
    client_a.post('/api/peer/location', headers=HEADERS,
                  json={'points': _pts(client_a, 1, offset=99.0)})
    with db.connect() as c:
        peer_rev2 = int(c.execute(
            "SELECT value FROM app_state WHERE key='peer_revision'").fetchone()[0])
        content_rev2 = int(c.execute(
            "SELECT value FROM app_state WHERE key='content_revision'").fetchone()[0])
    assert peer_rev2 > peer_rev
    assert content_rev2 == base, 'peer 更新不得 bump content_revision'


def test_peer_write_guards(nologin, client_a):
    r = nologin.post('/api/peer/location', json={'points': []},
                     headers=HEADERS)
    assert r.status_code in (401, 403)
    # client_a 实例默认头自带 X-Love-Space:1——显式传非 1 值模拟缺头
    r = client_a.post('/api/peer/location', json={'points': []},
                      headers={'X-Love-Space': '0'})
    assert r.status_code in (401, 403)
