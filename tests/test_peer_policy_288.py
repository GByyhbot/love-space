"""2.8.7 全量施工令 · 步 A 后端护栏（策略 / 裁剪 / 审计 / 聚合 / 轨迹 / 拒收）。

覆盖令文 §六 的后端六条：
1. 裁剪矩阵：档位 × 读接口逐格断言（street 无点列 / type_only 无 SSID /
   top5 无 sessions / screen_only 无分布与排行 / halted 无敏感字段）；
2. 迁移映射：老四开关 16 种组合 → 默认 policy；PUT 全量覆盖语义；
3. 审计：每次变更落一行且双方可读、无删除路径；
4. 聚合：跨小时/跨天切分、最长会话、Top5（masked 并入）、较昨日差值；
5. 轨迹：滤波（精度/漂移）、距离、停留聚类边界、地点命名命中与未命中；
6. 写侧拒收：越档 kind 422、halted 遥测拒收而手动报备照常、低电量只提醒一次。
"""

import datetime as dt
import json
import time
import uuid
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from app import db, peer, peer_agg
from app.main import app

HEADERS = {'X-Love-Space': '1'}
TZ = ZoneInfo('Asia/Shanghai')


# ── 夹具与助手 ──────────────────────────────────────────────────────

def _uid(client):
    return client.get('/api/me', headers=HEADERS).json()['user']['id']


def _cid(tag):
    return f't288-{tag}-{uuid.uuid4().hex[:8]}'


def _telemetry(client, kind, payload, *, cid=None, ts=None):
    body = {'kind': kind, 'payload': payload, 'client_id': cid or _cid(kind)}
    if ts is not None:
        body['ts'] = ts
    return client.post('/api/peer/report', headers=HEADERS, json=body)


def _set_policy(client, patch, **switches):
    body = {'policy': patch, **switches}
    r = client.put('/api/peer/settings', headers=HEADERS, json=body)
    assert r.status_code == 200, r.text
    return r.json()


def _reset_policy(client):
    _set_policy(client, {
        'global_off': False, 'paused_until': None,
        'location_level': 'exact', 'usage_level': 'full',
        'app_level': 'stream', 'network_level': 'ssid',
        'battery': True, 'battery_alert': True, 'fold_short': True,
        'sensitive_pkgs': [],
    }, events=True)


def _today():
    return dt.datetime.now(TZ).strftime('%Y-%m-%d')


def _day_start(day=None):
    day = day or _today()
    return dt.datetime.strptime(day, '%Y-%m-%d').replace(tzinfo=TZ).timestamp()


@pytest.fixture(autouse=True)
def _clean_and_restore():
    """开跑前确保双方全开；跑完还原设置并清掉本文件造的行。"""
    db.init()
    with db.connect() as c:
        row = c.execute('SELECT id FROM users ORDER BY created LIMIT 1').fetchone()
        if row is None:
            yield
            return
        u1 = row['id']
        u2row = c.execute(
            'SELECT id FROM users WHERE id<>? ORDER BY created LIMIT 1', (u1,)
        ).fetchone()
        u2 = u2row['id'] if u2row else u1
        saved = {u: (peer.load_settings(c, u), peer.load_policy(c, u))
                 for u in {u1, u2}}
        for u, (sw, pol) in saved.items():
            peer.save_settings(c, u, {**sw, 'policy': pol})
        c.execute("DELETE FROM peer_policy_audit WHERE ts>0")
        c.execute("DELETE FROM app_state WHERE key LIKE 'peer_batt_armed:%'")
    yield
    with db.connect() as c:
        for u, (sw, pol) in saved.items():
            peer.save_settings(c, u, {**sw, 'policy': pol})
        c.execute("DELETE FROM peer_events WHERE client_id LIKE 't288-%'")
        c.execute("DELETE FROM peer_policy_audit")
        c.execute("DELETE FROM app_state WHERE key LIKE 'peer_batt_armed:%'")
        c.execute("DELETE FROM peer_usage_daily WHERE day>=?",
                  ((dt.datetime.now(TZ) - dt.timedelta(days=2)).strftime('%Y-%m-%d'),))
        c.execute('DELETE FROM peer_location_points')
        c.execute("DELETE FROM peer_location_latest")
        c.execute('DELETE FROM peer_places')


# ── 1. 迁移映射 ─────────────────────────────────────────────────────

@pytest.mark.parametrize('sw,expect', [
    # 全开 → 全最高档
    ({'location': True, 'track': True, 'events': True, 'usage': True},
     ('exact', 'full', 'stream', 'ssid')),
    # 全部关闭 → 全 off
    ({'location': False, 'track': False, 'events': False, 'usage': False},
     ('off', 'off', 'off', 'off')),
    # 只关 usage：位置仍精确，应用/使用全 off
    ({'location': True, 'track': True, 'events': True, 'usage': False},
     ('exact', 'off', 'off', 'ssid')),
    # 只关 location：位置 off，使用照旧
    ({'location': False, 'track': True, 'events': True, 'usage': True},
     ('off', 'full', 'stream', 'ssid')),
    # 只关 events：网络档随之 off，其它不变
    ({'location': True, 'track': True, 'events': False, 'usage': True},
     ('exact', 'full', 'stream', 'off')),
])
def test_migration_from_switch_combo(client_a, sw, expect):
    """老四开关 → 默认 policy（**不全开兜底**，按现状生成）。"""
    r = client_a.put('/api/peer/settings', headers=HEADERS, json=sw).json()
    pol = r['policy']
    assert (pol['location_level'], pol['usage_level'],
            pol['app_level'], pol['network_level']) == expect


def test_migration_keeps_unmapped_fields(client_a):
    """迁移只动映射键，battery / 敏感清单 / fold_short 这些保持原值。"""
    _set_policy(client_a, {'battery': False, 'fold_short': False,
                           'sensitive_pkgs': ['com.x.secret']})
    # 只带四开关（老客户端）→ 不得把 battery/sensitive 重置
    r = client_a.put('/api/peer/settings', headers=HEADERS,
                     json={'location': True, 'track': True,
                           'events': True, 'usage': True}).json()
    assert r['policy']['battery'] is False
    assert r['policy']['fold_short'] is False
    assert r['policy']['sensitive_pkgs'] == ['com.x.secret']
    _reset_policy(client_a)


def test_policy_put_does_not_reset_events(client_a):
    """只带 policy 的 PUT 不许把 events 开关顺手改成默认值。"""
    client_a.put('/api/peer/settings', headers=HEADERS,
                 json={'events': False})
    r = _set_policy(client_a, {'app_level': 'top5'})
    assert r['events'] is False, 'events 是独立键，policy 写入不该动它'
    client_a.put('/api/peer/settings', headers=HEADERS, json={'events': True})


# ── 2. 裁剪矩阵 ─────────────────────────────────────────────────────

def _publish_location(client, *, lat=39.9087, lng=116.3975, ts=None):
    day_start = _day_start()
    body = {'points': [{'id': _cid('pt'), 'ts': ts or day_start + 3600,
                        'lat': lat, 'lng': lng, 'acc': 5}],
            'latest': {'lat': lat, 'lng': lng, 'acc': 5, 'battery': 70,
                       'charging': 0, 'net': 'wifi', 'wifi': 'home'}}
    r = client.post('/api/peer/location', headers=HEADERS, json=body)
    assert r.status_code == 200, r.text


def test_street_hides_points_and_grids_stays(client_a, client_b):
    _publish_location(client_a)
    _set_policy(client_a, {'location_level': 'street'})
    j = client_b.get('/api/peer/track', headers=HEADERS).json()['peer']
    assert j['level'] == 'street'
    assert j['points'] == [], '仅街区档绝不下发原始点列'
    assert j['distance_m'] is None
    # 最新位置必须落在 0.005° 网格上
    assert abs(j['latest']['lat'] / 0.005 - round(j['latest']['lat'] / 0.005)) < 1e-6
    _reset_policy(client_a)


def test_type_only_blank_ssid_everywhere(client_a, client_b):
    _publish_location(client_a)
    _telemetry(client_a, 'state.net', {'net': 'wifi', 'ssid': 'home'})
    _set_policy(client_a, {'network_level': 'type_only'})
    st = client_b.get('/api/peer/status', headers=HEADERS).json()['peer']
    assert st['location']['wifi'] is None, '快照里的 SSID 必须清空'
    assert st['location']['net'] == 'wifi', '类型要留'
    ev = client_b.get('/api/peer/events', headers=HEADERS).json()['peer']['events']
    nets = [e for e in ev if e['type'] == 'state.net']
    assert nets and nets[0]['payload']['ssid'] == ''
    assert 'home' not in nets[0]['summary'], '文案里也不许留 SSID'
    _reset_policy(client_a)


def test_network_off_drops_events_and_columns(client_a, client_b):
    _publish_location(client_a)
    _telemetry(client_a, 'state.net', {'net': 'wifi', 'ssid': 'home'})
    _set_policy(client_a, {'network_level': 'off'})
    st = client_b.get('/api/peer/status', headers=HEADERS).json()['peer']
    assert st['location']['net'] is None and st['location']['wifi'] is None
    ev = client_b.get('/api/peer/events', headers=HEADERS).json()['peer']['events']
    assert [e for e in ev if e['type'] == 'state.net'] == []
    usage = client_b.get('/api/peer/usage-daily', headers=HEADERS).json()['peer']
    assert usage['network_events'] == []
    _reset_policy(client_a)


def test_top5_hides_sessions_keeps_ranking(client_a, client_b):
    _telemetry(client_a, 'usage.session', {
        'pkg': 'com.tencent.mm', 'app': '微信',
        'start': _day_start() + 100, 'end': _day_start() + 700, 'dur': 600})
    _telemetry(client_a, 'usage.session', {
        'pkg': 'com.taobao', 'app': '淘宝',
        'start': _day_start() + 800, 'end': _day_start() + 1100, 'dur': 300})
    _set_policy(client_a, {'app_level': 'top5'})
    j = client_b.get('/api/peer/usage-daily', headers=HEADERS).json()['peer']
    assert 'sessions' not in j, '仅 Top5 档不许给时间流'
    assert [it['app'] for it in j['top_apps']] == ['微信', '淘宝']
    assert j['top_apps'][0]['sec'] == 600
    _reset_policy(client_a)


def test_app_off_hides_all_app_fields(client_a, client_b):
    _telemetry(client_a, 'usage.session', {
        'pkg': 'com.tencent.mm', 'app': '微信',
        'start': _day_start() + 100, 'end': _day_start() + 700, 'dur': 600})
    _set_policy(client_a, {'app_level': 'off'})
    j = client_b.get('/api/peer/usage-daily', headers=HEADERS).json()['peer']
    assert 'top_apps' not in j and 'sessions' not in j
    assert j['screen_sec'] >= 0, '统计照常（关闭的只是应用两节）'
    _reset_policy(client_a)


def test_screen_only_keeps_two_numbers(client_a, client_b):
    _telemetry(client_a, 'state.screen', {'session_sec': 600, 'on': False})
    _set_policy(client_a, {'usage_level': 'screen_only'})
    j = client_b.get('/api/peer/usage-daily', headers=HEADERS).json()['peer']
    assert set(j) >= {'screen_sec', 'unlocks'}
    assert 'hourly' not in j and 'top_apps' not in j and 'sessions' not in j
    _reset_policy(client_a)


def test_usage_off_marks_closed_off(client_a, client_b):
    _telemetry(client_a, 'state.screen', {'session_sec': 600, 'on': False})
    _set_policy(client_a, {'usage_level': 'off'})
    usage = client_b.get('/api/peer/usage-daily', headers=HEADERS).json()['peer']
    assert usage['closed_off'] is True
    assert 'screen_sec' not in usage, '关闭态不许给假 0'
    daily = client_b.get('/api/peer/state-daily', headers=HEADERS).json()['peer']
    assert daily['closed_off'] is True
    _reset_policy(client_a)


def test_global_off_hides_everything(client_a, client_b):
    _publish_location(client_a)
    _telemetry(client_a, 'state.battery', {'level': 50, 'charging': False})
    _set_policy(client_a, {'global_off': True})
    st = client_b.get('/api/peer/status', headers=HEADERS).json()['peer']
    assert st['halted']['halted'] is True and st['halted']['reason'] == 'off'
    assert st['location'] is None, '停用期间不返回任何历史敏感字段'
    ev = client_b.get('/api/peer/events', headers=HEADERS).json()['peer']
    assert ev['closed_off'] is True and ev['events'] == []
    tr = client_b.get('/api/peer/track', headers=HEADERS).json()['peer']
    assert tr['halted']['halted'] is True and tr['points'] == []
    _reset_policy(client_a)


def test_paused_until_reports_reason(client_a, client_b):
    _set_policy(client_a, {'paused_until': time.time() + 3600})
    st = client_b.get('/api/peer/status', headers=HEADERS).json()['peer']
    assert st['halted'] == {'halted': True, 'reason': 'paused',
                            'until': st['halted']['until']}
    assert st['halted']['until'] > time.time()
    _reset_policy(client_a)


# ── 3. 审计 ─────────────────────────────────────────────────────────

def test_policy_change_writes_audit_and_event(client_a, client_b):
    _reset_policy(client_a)
    _set_policy(client_a, {'app_level': 'top5'})
    j = client_b.get('/api/peer/policy-audit', headers=HEADERS).json()
    assert j['items'], '变更必须留审计'
    top = j['items'][0]
    assert top['detail'] == '把软件打开记录调为仅 Top5'
    assert top['mine'] is False, '对方看到的是「TA 的动作」'
    # 自己看同一行是 mine=True
    mine = client_a.get('/api/peer/policy-audit', headers=HEADERS).json()['items']
    assert mine[0]['mine'] is True
    # 同时进对方动态流
    ev = client_b.get('/api/peer/events', headers=HEADERS).json()['peer']['events']
    pol = [e for e in ev if e['type'] == 'policy.change']
    assert pol and '仅 Top5' in pol[0]['summary']
    _reset_policy(client_a)


def test_no_change_no_audit_row(client_a):
    _reset_policy(client_a)
    before = len(client_a.get('/api/peer/policy-audit',
                              headers=HEADERS).json()['items'])
    _set_policy(client_a, {})  # 原样再写一遍
    after = len(client_a.get('/api/peer/policy-audit',
                             headers=HEADERS).json()['items'])
    assert after == before, '没变化就不该刷审计'


def test_audit_is_read_only(client_a):
    assert client_a.delete('/api/peer/policy-audit',
                           headers=HEADERS).status_code == 405


# ── 4. 聚合 ─────────────────────────────────────────────────────────

def test_hourly_split_across_hours(client_a, client_b):
    start = _day_start()
    # 02:30 结束、时长 2 小时 → 00:30–02:30 跨三个小时
    _telemetry(client_a, 'state.screen',
               {'session_sec': 7200, 'on': False}, ts=start + 9000)
    j = client_b.get('/api/peer/usage-daily', headers=HEADERS).json()['peer']
    assert j['hourly'][0] == 1800
    assert j['hourly'][1] == 3600
    assert j['hourly'][2] == 1800
    assert j['longest_session_sec'] == 7200


def test_cross_midnight_clipped(client_a, client_b):
    start = _day_start()
    # 今天 00:30 结束、时长 1 小时 → 昨天 23:30 那段不算今天
    _telemetry(client_a, 'state.screen',
               {'session_sec': 3600, 'on': False}, ts=start + 1800)
    j = client_b.get('/api/peer/usage-daily', headers=HEADERS).json()['peer']
    assert j['hourly'][0] == 1800, '00:00 之前的部分必须切掉'


def test_top5_caps_and_merges_masked(client_a, client_b):
    start = _day_start()
    for i, (pkg, app, dur) in enumerate([
            ('com.a', '应用A', 100), ('com.b', '应用B', 200),
            ('com.secret', '真实敏感名', 300)]):
        _telemetry(client_a, 'usage.session', {
            'pkg': 'masked.other' if pkg == 'com.secret' else pkg,
            'app': app, 'masked': pkg == 'com.secret',
            'start': start + i * 10, 'end': start + i * 10 + dur, 'dur': dur})
    with db.connect() as c:
        row = c.execute('SELECT top_apps FROM peer_usage_daily WHERE user=? AND day=?',
                        (_uid(client_a), _today())).fetchone()
    apps = json.loads(row['top_apps'])
    names = [a['app'] for a in apps]
    assert '其他应用' in names, 'masked 会话并入「其他应用」'
    assert '真实敏感名' not in names, '真实应用名不许进聚合'
    assert apps[0]['app'] == '其他应用' and apps[0]['sec'] == 300


def test_top5_keeps_only_five(client_a, client_b):
    """2.8.7 一套账：写侧不再 [:5] 截断（否则第 6 名起时长被反复清零），
    改为存侧留 50、读侧严格取 5。两边都要断言。"""
    start = _day_start()
    for i in range(7):
        _telemetry(client_a, 'usage.session', {
            'pkg': f'com.p{i}', 'app': f'应用{i}',
            'start': start + i, 'end': start + i + i + 1, 'dur': i + 1})
    with db.connect() as c:
        row = c.execute('SELECT top_apps FROM peer_usage_daily WHERE user=? AND day=?',
                        (_uid(client_a), _today())).fetchone()
    stored = json.loads(row['top_apps'])
    assert 5 < len(stored) <= 50, '存侧保留长尾（≤50），不得再截成 5'
    assert [a['app'] for a in stored[:2]] == ['应用6', '应用5'], '存侧仍按秒数倒序'
    j = client_b.get('/api/peer/usage-daily', headers=HEADERS).json()['peer']
    top = j['top_apps']
    assert len(top) == 5, '读侧仍严格只给 5 条'
    secs = [a['sec'] for a in top]
    assert secs == sorted(secs, reverse=True), '读侧按秒数倒序'
    assert all(a['app'].startswith('应用') for a in top), '只含本患者应用'
    # 一套账口径：Top5 合计不得超过当日亮屏总量
    assert sum(secs) <= j['screen_sec']


def test_yesterday_delta(client_a, client_b):
    today = _today()
    yday = peer_agg.prev_day(today)
    with db.connect() as c:
        c.execute(
            'INSERT INTO peer_usage_daily(user,day,screen_sec,unlocks,updated) '
            'VALUES (?,?,?,0,?) ON CONFLICT(user,day) DO UPDATE SET screen_sec=?',
            (_uid(client_a), yday, 1000, time.time(), 1000))
    j = client_b.get('/api/peer/usage-daily', headers=HEADERS).json()['peer']
    assert j['yesterday_screen_sec'] == 1000


# ── 5. 轨迹：滤波 / 距离 / 停留 / 命名 ─────────────────────────────

def test_filter_drops_bad_accuracy_and_drift():
    rows = [
        {'ts': 1000.0, 'lat': 39.90, 'lng': 116.40, 'acc': 5, 'speed': 0},
        {'ts': 1010.0, 'lat': 39.91, 'lng': 116.40, 'acc': 99, 'speed': 0},  # 精度差
        {'ts': 1020.0, 'lat': 40.90, 'lng': 117.40, 'acc': 5, 'speed': 0},   # 瞬移
        {'ts': 1030.0, 'lat': 39.9005, 'lng': 116.4002, 'acc': 5, 'speed': 0},
    ]
    kept = peer_agg.filter_points(rows)
    assert len(kept) == 2, 'acc>50 与速度>45m/s 的点都要丢'
    assert kept[1]['lat'] == 39.9005


def test_distance_sums_haversine():
    pts = [{'ts': 1, 'lat': 39.9087, 'lng': 116.3975},
           {'ts': 2, 'lat': 39.9163, 'lng': 116.3972}]
    d = peer_agg.total_distance_m(pts)
    assert 800 < d < 900


def test_stay_cluster_boundary():
    base = 1_700_000_000.0
    # 5 分钟整 → 成一个停留点
    pts = [{'ts': base, 'lat': 39.9, 'lng': 116.4},
           {'ts': base + 150, 'lat': 39.9001, 'lng': 116.4001},
           {'ts': base + 300, 'lat': 39.9002, 'lng': 116.4002}]
    stays = peer_agg.cluster_stays(pts)
    assert len(stays) == 1 and stays[0]['duration_sec'] == 300
    # 差 1 秒不足 5 分钟 → 不成停留点
    pts2 = [{'ts': base, 'lat': 39.9, 'lng': 116.4},
            {'ts': base + 299, 'lat': 39.9001, 'lng': 116.4001}]
    assert peer_agg.cluster_stays(pts2) == []


def test_stay_named_by_place_or_left_blank(client_a):
    base = _day_start() + 3600
    with db.connect() as c:
        c.execute('INSERT INTO peer_places(id,name,lat,lng,radius,created) '
                  'VALUES (?,?,?,?,?,?)',
                  ('p1', '家', 39.9000, 116.4000, 150, time.time()))
    # 落在「家」附近的一簇（HTTP 请求要另开连接，不能占着上面那个 with）
    for i in range(3):
        _publish_location(client_a, lat=39.9001, lng=116.4001,
                          ts=base + i * 180)
    # 远处的一簇
    for i in range(3):
        _publish_location(client_a, lat=39.9500, lng=116.4500,
                          ts=base + 3600 + i * 180)
    with db.connect() as c:
        j = peer_agg.track_for(c, _uid(client_a), _today(),
                               peer.load_policy(c, _uid(client_a)))
    names = [s['place_name'] for s in j['stays']]
    assert '家' in names, '命中 peer_places 就给名字'
    assert '' in names, '匹配不上必须留空名（不许编地名）'


# ── 6. 写侧拒收 + 脱敏 + 低电量 ────────────────────────────────────

def test_reject_net_event_when_network_off(client_a):
    _set_policy(client_a, {'network_level': 'off'})
    r = _telemetry(client_a, 'state.net', {'net': 'wifi', 'ssid': 'x'})
    assert r.status_code == 422 and '网络' in r.json()['detail']
    _reset_policy(client_a)


def test_reject_usage_when_app_off(client_a):
    _set_policy(client_a, {'app_level': 'off'})
    r = _telemetry(client_a, 'usage.session', {
        'pkg': 'com.a', 'app': 'A', 'start': 1, 'end': 2, 'dur': 1})
    assert r.status_code == 422
    _reset_policy(client_a)


def test_top5_accepts_session_but_rejects_now(client_a):
    start = _day_start()
    _set_policy(client_a, {'app_level': 'top5'})
    ok = _telemetry(client_a, 'usage.session', {
        'pkg': 'com.a', 'app': 'A', 'start': start, 'end': start + 60, 'dur': 60})
    assert ok.status_code == 200, '仅 Top5 档仍要收会话（服务端靠它算排行）'
    bad = _telemetry(client_a, 'usage.now', {'app': 'A', 'pkg': 'com.a'})
    assert bad.status_code == 422, '「正在使用」属时间流级细节，top5 档不收'
    _reset_policy(client_a)


def test_halted_rejects_telemetry_but_allows_manual(client_a):
    _set_policy(client_a, {'paused_until': time.time() + 3600})
    r = _telemetry(client_a, 'state.battery', {'level': 30, 'charging': False})
    assert r.status_code == 422 and '暂停' in r.json()['detail']
    manual = client_a.post('/api/peer/report', headers=HEADERS,
                           json={'scene': 'miss', 'summary': '想你了',
                                 'client_id': _cid('manual')})
    assert manual.status_code == 200, '暂停期间手动报备照常'
    _reset_policy(client_a)


def test_masked_with_real_pkg_rejected(client_a):
    r = _telemetry(client_a, 'usage.session', {
        'pkg': 'com.wechat', 'app': '微信', 'masked': True,
        'start': 1, 'end': 61, 'dur': 60})
    assert r.status_code == 422 and '真实包名' in r.json()['detail']


def test_masked_session_summary_uses_mask_name(client_a, client_b):
    start = _day_start()
    r = _telemetry(client_a, 'usage.session', {
        'pkg': 'masked.other', 'app': '微信', 'masked': True,
        'start': start, 'end': start + 600, 'dur': 600})
    assert r.status_code == 200, r.text
    ev = r.json()['event']
    assert ev['summary'] == '其他应用 10 分钟'
    assert ev['payload']['pkg'] == 'masked.other'
    assert '微信' not in json.dumps(ev, ensure_ascii=False), '真实名不许出现在任何字段'


def test_low_battery_alerts_once_per_crossing(client_a, client_b):
    _reset_policy(client_a)
    with db.connect() as c:
        notes_before = c.execute(
            "SELECT count(*) n FROM notices WHERE event='peer_battery_low'"
        ).fetchone()['n']
    _telemetry(client_a, 'state.battery', {'level': 19, 'charging': False})
    _telemetry(client_a, 'state.battery', {'level': 15, 'charging': False})
    _telemetry(client_a, 'state.battery', {'level': 12, 'charging': False})
    with db.connect() as c:
        n = c.execute("SELECT count(*) n FROM notices WHERE event='peer_battery_low'"
                      ).fetchone()['n']
    assert n - notes_before == 1, '同一段下跌只提醒一次'
    # 回升到 25% 以上重新武装 → 再跌破给第二次
    _telemetry(client_a, 'state.battery', {'level': 30, 'charging': False})
    _telemetry(client_a, 'state.battery', {'level': 18, 'charging': False})
    with db.connect() as c:
        n2 = c.execute("SELECT count(*) n FROM notices WHERE event='peer_battery_low'"
                       ).fetchone()['n']
    assert n2 - notes_before == 2


def test_low_battery_while_charging_silent(client_a):
    _reset_policy(client_a)
    with db.connect() as c:
        before = c.execute("SELECT count(*) n FROM notices "
                           "WHERE event='peer_battery_low'").fetchone()['n']
    _telemetry(client_a, 'state.battery', {'level': 8, 'charging': True})
    with db.connect() as c:
        after = c.execute("SELECT count(*) n FROM notices "
                          "WHERE event='peer_battery_low'").fetchone()['n']
    assert after == before, '充电中不算低电告警'


def test_low_battery_event_marked_low(client_a):
    _reset_policy(client_a)
    _telemetry(client_a, 'state.battery', {'level': 30, 'charging': False})
    r = _telemetry(client_a, 'state.battery', {'level': 15, 'charging': False})
    ev = r.json()['event']
    assert ev['payload']['low'] is True
    assert '电量偏低' in ev['summary']


# ── 7. 互动抽屉（戳/抱抱/提醒）：频控 + 通知标题 ──────────────────────

def _poke(client, scene, summary, cid=None):
    return client.post('/api/peer/report', headers=HEADERS, json={
        'scene': scene, 'summary': summary, 'client_id': cid or _cid(scene),
        'push': True})


def test_poke_three_kinds_land_as_manual_reports(client_a):
    for scene, text in (('poke', '戳了你一下'), ('hug', '抱了抱你'),
                        ('care', '早点睡呀')):
        r = _poke(client_a, scene, text)
        assert r.status_code == 200, r.text
        ev = r.json()['event']
        assert ev['type'] == 'manual_report'
        assert ev['scene'] == scene
        assert ev['summary'] == text


def test_poke_rate_limit_six_per_hour(client_a):
    for i in range(6):
        assert _poke(client_a, 'poke', f'戳了你一下{i}').status_code == 200
    r = _poke(client_a, 'poke', '第七次')
    assert r.status_code == 422
    assert '每小时最多 6 次' in r.json()['detail']
    # 别的类不受影响（各自独立计数）
    assert _poke(client_a, 'hug', '抱了抱你').status_code == 200


def test_poke_notice_title_is_plain(client_a, client_b):
    with db.connect() as c:
        before = {r['id'] for r in c.execute(
            "SELECT id FROM notices WHERE event='peer_report'")}
    _poke(client_a, 'poke', '戳了你一下')
    with db.connect() as c:
        rows = [r for r in c.execute(
            "SELECT id,title FROM notices WHERE event='peer_report'")
            if r['id'] not in before]
    assert rows, '互动类必须写通知中心'
    assert rows[-1]['title'] == 'TA 戳了你一下', '通知标题要明文「TA 戳了你一下」'
