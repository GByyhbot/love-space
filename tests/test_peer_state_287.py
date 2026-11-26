"""2.8.7 自动报备第二段 · 后端护栏（设备状态事件）。

钉住六件事：
1. `ReportIn` 的 kind 入口与 payload 形状校验（level 0–100 / net 枚举 /
   unlock count≥1 / screen session_sec≥0），非法一律 422；
2. 状态事件落 `type='state.*'` + `source='auto'`，**不污染** manual_report 的
   scene/note/place_name 语义（主动报备带 payload/kind 空时行为不变）；
3. client_id 幂等：重复上报不重复入库、**也不重复累加日汇总**；
4. 快照补缝：state.battery / state.net 顺手 UPDATE
   `peer_location_latest` 的 battery/charging/net/wifi + `state_updated`，
   **不动 lat/lng/updated**（那是定位的字段）；
5. 日汇总：screen/unlock 累加进 `peer_usage_daily.screen_sec / unlocks`，
   **top_apps 一律不写、usage 开关不读**（围栏见 test_no_usage_fence_*）；
6. `GET /api/peer/state-daily` 的口径与 events 按日查询一致（空间时区切日、
   对方 events 关闭 → closed_off 明示且数值归 0）。
"""

import json
import time
import uuid

import pytest
from fastapi.testclient import TestClient

from app import db, peer
from app.main import app

HEADERS = {'X-Love-Space': '1'}


@pytest.fixture
def nologin():
    with TestClient(app, base_url='https://testserver') as client:
        yield client


def _uid(client):
    return client.get('/api/me').json()['user']['id']


def _cid(tag):
    return f't287-{tag}-{uuid.uuid4().hex[:8]}'


def _state(client, kind, payload, *, cid=None, ts=None):
    body = {'kind': kind, 'payload': payload, 'client_id': cid or _cid(kind)}
    if ts is not None:
        body['ts'] = ts
    return client.post('/api/peer/report', json=body)


@pytest.fixture(autouse=True)
def _clean_and_restore():
    """本文件所有用例：开跑前确保 events 全开、跑完清掉自己造的行。"""
    db.init()  # 单元跑单条用例时可能还没建库（session client 未初始化）
    with db.connect() as c:
        row = c.execute('SELECT id FROM users ORDER BY created LIMIT 1').fetchone()
        if row is None:
            yield
            return
        u1 = row['id']
        u2 = c.execute('SELECT id FROM users WHERE id<>? ORDER BY created LIMIT 1',
                       (u1,)).fetchone()
        saved = {u: peer.load_settings(c, u) for u in (u1, u2['id'] if u2 else u1)}
        for u, st in saved.items():
            peer.save_settings(c, u, {**st, 'events': True})
    yield
    with db.connect() as c:
        for u, st in saved.items():
            peer.save_settings(c, u, st)
        c.execute("DELETE FROM peer_events WHERE client_id LIKE 't287-%'")
        c.execute("DELETE FROM peer_usage_daily WHERE day>=?",
                  (time.strftime('%Y-%m-%d', time.localtime(time.time() - 86400)),))


# ── 1. 形状校验 ─────────────────────────────────────────────────

def test_battery_accepts_and_writes_state_type(client_a):
    cid = _cid('bat')
    r = _state(client_a, 'state.battery', {'level': 42, 'charging': True}, cid=cid)
    assert r.status_code == 200, r.text
    ev = r.json()['event']
    assert ev['type'] == 'state.battery'
    assert ev['source'] == 'auto'
    assert ev['payload'] == {'level': 42, 'charging': True}
    # 主动报备的三个语义字段必须为空（不污染）
    assert ev['scene'] == '' and ev['note'] == '' and ev['place_name'] == ''
    assert ev['pushed'] == 0


@pytest.mark.parametrize('payload', [
    {'level': 101, 'charging': False},   # 上界
    {'level': -1, 'charging': False},    # 下界
    {'level': '50', 'charging': False},  # 类型
    {'level': 50},                       # 缺 charging
])
def test_battery_payload_invalid_422(client_a, payload):
    r = _state(client_a, 'state.battery', payload)
    assert r.status_code == 422, r.text


def test_net_enum_reject_and_ssid_optional(client_a):
    assert _state(client_a, 'state.net', {'net': '4g'}).status_code == 422

    r = _state(client_a, 'state.net', {'net': 'cell'})
    assert r.status_code == 200, r.text
    # 取不到 SSID 就降级 type-only：给空串，绝不伪造
    assert r.json()['event']['payload'] == {'net': 'cell', 'ssid': ''}


def test_unlock_count_must_be_positive(client_a):
    assert _state(client_a, 'state.unlock', {'count': 0, 'window_sec': 600}).status_code == 422
    r = _state(client_a, 'state.unlock', {'count': 3, 'window_sec': 600})
    assert r.status_code == 200, r.text
    assert r.json()['event']['payload']['count'] == 3


def test_screen_session_sec_non_negative(client_a):
    assert _state(client_a, 'state.screen', {'session_sec': -5}).status_code == 422
    r = _state(client_a, 'state.screen', {'session_sec': 90})
    assert r.status_code == 200, r.text


def test_unknown_kind_rejected(client_a):
    assert _state(client_a, 'state.foo', {}).status_code == 422
    assert _state(client_a, 'manual_report', {}).status_code == 422


def test_payload_passthrough_tier_policy(client_a):
    """下一段分档的扩展位：服务端原样透传、不解析、不拒收。"""
    r = _state(client_a, 'state.battery',
               {'level': 88, 'charging': False, 'tier': 'day', 'policy': 'p1'})
    assert r.status_code == 200, r.text
    p = r.json()['event']['payload']
    assert p['tier'] == 'day' and p['policy'] == 'p1'


# ── 2. 开关拒收 ─────────────────────────────────────────────────

def test_events_closed_rejects_state_event(client_a):
    uid = _uid(client_a)
    with db.connect() as c:
        peer.save_settings(c, uid, {**peer.load_settings(c, uid), 'events': False})
    try:
        r = _state(client_a, 'state.battery', {'level': 50, 'charging': False})
        assert r.status_code == 422
        assert '关闭' in r.json()['detail']
    finally:
        with db.connect() as c:
            peer.save_settings(c, uid, {**peer.load_settings(c, uid), 'events': True})


# ── 3. 幂等 ─────────────────────────────────────────────────────

def test_client_id_idempotent_no_double_count(client_a):
    uid = _uid(client_a)
    cid = _cid('unlock-idem')

    def daily():
        with db.connect() as c:
            r = c.execute('SELECT unlocks FROM peer_usage_daily WHERE user=? AND day=?',
                          (uid, time.strftime('%Y-%m-%d'))).fetchone()
            return int(r['unlocks']) if r else 0

    before = daily()
    r1 = _state(client_a, 'state.unlock', {'count': 4, 'window_sec': 600}, cid=cid)
    assert r1.status_code == 200 and r1.json()['created'] is True
    mid = daily()
    assert mid == before + 4, '首次上报应累加'

    r2 = _state(client_a, 'state.unlock', {'count': 4, 'window_sec': 600}, cid=cid)
    assert r2.status_code == 200 and r2.json()['created'] is False
    assert daily() == mid, '幂等命中不许重复累加日汇总'


# ── 4. 快照补缝 ─────────────────────────────────────────────────

def _seed_latest(client):
    return client.post('/api/peer/location', json={
        'points': [{'id': _cid('pt'), 'ts': time.time(), 'lat': 31.2, 'lng': 121.4}],
        'latest': {'lat': 31.2, 'lng': 121.4, 'acc': 12.0, 'speed': 0.0,
                   'battery': 90, 'charging': 0, 'net': 'wifi', 'wifi': 'home'},
    })


def _latest_row(uid):
    with db.connect() as c:
        return dict(c.execute('SELECT * FROM peer_location_latest WHERE user=?',
                              (uid,)).fetchone())


def test_battery_updates_snapshot_without_touching_location_columns(client_a):
    uid = _uid(client_a)
    assert _seed_latest(client_a).status_code == 200
    before = _latest_row(uid)

    assert _state(client_a, 'state.battery',
                  {'level': 18, 'charging': False}).status_code == 200
    after = _latest_row(uid)

    assert after['battery'] == 18 and after['charging'] == 0
    assert after['state_updated'] is not None and after['state_updated'] >= before['updated']
    # 定位字段必须原样：state 事件不许改经纬度/定位时间
    assert (after['lat'], after['lng']) == (before['lat'], before['lng'])
    assert after['updated'] == before['updated']


def test_net_updates_snapshot_wifi_column(client_a):
    uid = _uid(client_a)
    assert _seed_latest(client_a).status_code == 200
    assert _state(client_a, 'state.net',
                  {'net': 'wifi', 'ssid': 'cafe-5g'}).status_code == 200
    row = _latest_row(uid)
    assert row['net'] == 'wifi' and row['wifi'] == 'cafe-5g'


# ── 5. 日汇总与只读端点 ─────────────────────────────────────────

def test_screen_accumulates_daily(client_a):
    uid = _uid(client_a)
    today = time.strftime('%Y-%m-%d')
    with db.connect() as c:
        c.execute('DELETE FROM peer_usage_daily WHERE user=? AND day=?', (uid, today))
    _state(client_a, 'state.screen', {'session_sec': 60})
    _state(client_a, 'state.screen', {'session_sec': 120})
    with db.connect() as c:
        r = c.execute('SELECT screen_sec FROM peer_usage_daily WHERE user=? AND day=?',
                      (uid, today)).fetchone()
    assert int(r['screen_sec']) == 180


def test_state_daily_endpoint_shape(client_a, client_b):
    uid = _uid(client_a)
    _state(client_a, 'state.screen', {'session_sec': 30})
    r = client_a.get('/api/peer/state-daily')
    assert r.status_code == 200, r.text
    j = r.json()
    assert set(j) == {'date', 'mine', 'peer'}
    assert set(j['mine']) == {'screen_sec', 'unlocks'}
    # 2.8.7 全量：peer 多一个 halted（停用/暂停明示）
    assert set(j['peer']) == {'closed_off', 'screen_sec', 'unlocks', 'halted'}
    assert j['mine']['screen_sec'] >= 30


def test_state_daily_rejects_bad_date(client_a):
    assert client_a.get('/api/peer/state-daily?date=2026-1-1').status_code == 422


def test_state_daily_peer_closed_off(client_a, client_b):
    """对方 events 关闭 → closed_off 明示且数值归 0（对等口径，不给假 0）。

    视角是 client_b：它的「对方」是 client_a，所以关 a 的开关。
    """
    aid = _uid(client_a)
    with db.connect() as c:
        peer.save_settings(c, aid, {**peer.load_settings(c, aid), 'events': False})
    try:
        j = client_b.get('/api/peer/state-daily').json()
        assert j['peer']['closed_off'] is True
        assert j['peer']['screen_sec'] == 0 and j['peer']['unlocks'] == 0
    finally:
        with db.connect() as c:
            peer.save_settings(c, aid, {**peer.load_settings(c, aid), 'events': True})


# ── 5b. 事件流可见性（2026-11-26 真机空白事故的回归护栏）────────

def test_state_event_summary_is_non_empty(client_a):
    """状态事件必须自带中文 summary——老包只认 summary，空串会渲染成空白行。"""
    r = _state(client_a, 'state.battery', {'level': 33, 'charging': False})
    assert r.status_code == 200, r.text
    assert r.json()['event']['summary'] == '电量 33%'
    r2 = _state(client_a, 'state.net', {'net': 'wifi', 'ssid': 'home'})
    assert r2.json()['event']['summary'] == '连上 Wi-Fi（home）'


def test_events_list_returns_payload_and_summary(client_a):
    """`GET /api/peer/events` 必须带回 payload 与 summary。

    首版漏了 SELECT 里的 payload 列 → 客户端拿到 payload={} + summary=''
    → 事件流整行空白（真机复现）。这条钉住 SQL 列清单不许再漏。
    """
    uid = _uid(client_a)
    cid = _cid('visible')
    assert _state(client_a, 'state.battery',
                  {'level': 61, 'charging': True}, cid=cid).status_code == 200
    j = client_a.get('/api/peer/events').json()
    row = next((e for e in j['mine'] if e.get('client_id') == cid), None)
    assert row is not None, '刚上报的状态事件必须出现在当日事件流里'
    assert row['payload'] == {'level': 61, 'charging': True}
    assert row['summary'] == '电量 61%，充电中'


def test_hist_row_without_summary_backfilled(client_a):
    """历史空文案行（早于 state_summary 落库）序列化时按 payload 现算，不许空白。"""
    uid = _uid(client_a)
    cid = _cid('backfill')
    eid = 't287-hist-' + uuid.uuid4().hex[:8]
    with db.connect() as c:
        c.execute(
            "INSERT INTO peer_events(id,user,type,ts,summary,pushed,created,"
            "source,scene,note,place_name,client_id,payload) "
            "VALUES(?,?,?,?, '', 0, ?, 'auto','','','',?,?)",
            (eid, uid, 'state.unlock', time.time(), time.time(), cid,
             json.dumps({'count': 9, 'window_sec': 600})))
    j = client_a.get('/api/peer/events').json()
    row = next((e for e in j['mine'] if e['id'] == eid), None)
    assert row is not None
    assert row['summary'] == '解锁 9 次', '空文案的历史行必须被兜底补上'


# ── 6. 围栏与不污染 ─────────────────────────────────────────────

def test_manual_report_payload_ignored(client_a):
    """主动报备带 payload 字段也不许被状态分支劫持（kind 空 = 原语义）。"""
    r = client_a.post('/api/peer/report', json={
        'scene': 'arrive', 'summary': '到家了', 'client_id': _cid('manual'),
        'payload': {'level': 50, 'charging': True},
    })
    assert r.status_code == 200, r.text
    ev = r.json()['event']
    assert ev['type'] == 'manual_report' and ev['source'] == 'manual'
    assert ev['scene'] == 'arrive' and ev['summary'] == '到家了'
    assert ev['payload'] == {}, '主动报备不该带上状态载荷'


def test_usage_fence_replaced_by_masking_rule():
    """围栏替换（2026-11-27 机主令解除 usage 围栏，换成脱敏硬约束）。

    旧断言「后端不得消费 top_apps/usage」已被本令作废，这里改为**新红线**：
    ① 哨兵常量存在且服务端真在用（源码级）；
    ② 脱敏事件的 summary 只许出现「其他应用」，绝不出现真实包名（行为）。
    """
    import pathlib

    root = pathlib.Path(__file__).resolve().parents[1] / 'app'
    src = (root / 'peer.py').read_text(encoding='utf-8')
    assert peer.SENSITIVE_MASK_PKG == 'masked.other'
    assert peer.SENSITIVE_MASK_NAME == '其他应用'
    assert 'SENSITIVE_MASK_NAME' in src, 'summary 必须用哨兵名，不能用客户端传来的 app'
    # masked 时 pkg 必须被改写为哨兵（源码级：校验函数里显式赋值）
    assert "pkg = SENSITIVE_MASK_PKG" in src
    assert "app = SENSITIVE_MASK_NAME" in src
