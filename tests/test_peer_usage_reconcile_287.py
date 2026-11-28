"""2.8.7 傍晚批 1-2：使用时长「一套账」回归测试。

复现她 2026-11-28 真机病态场景：
  亮屏 3 段共 17 分钟（最长 5 分钟）
  + 跨灭屏的未闭合 usage.now（微信，since 68 分钟前）
  + 零星短 usage.session（合计 <3 分钟）
  + 超过 5 个应用（原写侧 [:5] 截断缺陷）
  + peer_location_latest 有 wifi/CMCC-p3j5，但当日无 state.net
"""
import datetime as dt

import pytest

from app import db, peer, peer_agg

HEADERS = {'X-Love-Space': '1'}
DAY = '2026-11-28'


@pytest.fixture(autouse=True)
def _clean():
    yield
    with db.connect() as c:
        c.execute('DELETE FROM peer_events')
        c.execute('DELETE FROM peer_location_latest')
        c.execute('DELETE FROM peer_usage_daily')


def _ts(hh, mm, ss=0):
    base = dt.datetime(2026, 11, 28, hh, mm, ss, tzinfo=dt.timezone(dt.timedelta(hours=8)))
    return base.timestamp()


def _ev(c, uid, kind, ts, **payload):
    import uuid
    c.execute(
        'INSERT INTO peer_events (id,user,type,ts,summary,created,payload) '
        'VALUES (?,?,?,?,?,?,?)',
        (uuid.uuid4().hex, uid, kind, ts, kind, ts, db.dumps(payload)),
    )


def _seed(c, uid):
    # 亮屏三段：10:00-10:05 / 12:00-12:07 / 15:00-15:05（合计 17 分钟，最长 5 分钟）
    _ev(c, uid, 'state.screen', _ts(10, 5), on=False, session_sec=300)
    _ev(c, uid, 'state.screen', _ts(12, 7), on=False, session_sec=420)
    _ev(c, uid, 'state.screen', _ts(15, 5), on=False, session_sec=300)
    # 零星短会话（合计 <3 分钟），横跨 6 个应用（触达写侧 [:5] 缺陷）
    for i, app in enumerate(['微信', '小红书', '相册', '相机', '地图', '音乐']):
        s = _ts(10, 0) + i * 40
        _ev(c, uid, 'usage.session', s + 25, app=app, start=s, end=s + 25, dur=25, masked=False)
    # 跨灭屏的未闭合 usage.now：since 68 分钟前（视频/微信长会话），ts 在熄屏之后
    _ev(c, uid, 'usage.now', _ts(15, 5, 10), app='微信', since=_ts(13, 57), masked=False)
    # 最新位置快照有网络，但当日没有 state.net（异常③）
    c.execute('INSERT OR REPLACE INTO peer_location_latest '
              '(user,lat,lng,net,wifi,updated,state_updated) VALUES (?,?,?,?,?,?,?)',
              (uid, 36.66, 101.52, 'wifi', 'CMCC-p3j5', _ts(15, 6), _ts(15, 6)))


def test_no_ghost_current_app_after_screen_off(client_a):
    uid = client_a.get('/api/me', headers=HEADERS).json()['user']['id']
    with db.connect() as c:
        _seed(c, uid)
        policy = {'usage_level': 'full', 'app_level': 'stream', 'network_level': 'ssid'}
        now = _ts(15, 40)
        led = peer_agg.reconcile_usage_day(c, uid, DAY, policy, now=now)
        # 熄屏后心跳重发旧 since → 不得造出 1h8m 幽灵会话
        assert led['current_app'] is None
        # 总量/最长按亮屏窗派生
        assert led['screen_sec'] == 1020
        assert led['longest_session_sec'] == 420
        # Top5 ≤ 总量，且六应用里能算到时长（写侧不再被 [:5] 清零）
        top_sum = sum(i['sec'] for i in led['top_apps'])
        assert top_sum <= led['screen_sec']
        assert len(led['top_apps']) == 5


def test_identities_hold(client_a):
    uid = client_a.get('/api/me', headers=HEADERS).json()['user']['id']
    with db.connect() as c:
        _seed(c, uid)
        policy = {'usage_level': 'full', 'app_level': 'stream', 'network_level': 'ssid'}
        led = peer_agg.reconcile_usage_day(c, uid, DAY, policy, now=_ts(15, 40))
        assert led['longest_session_sec'] <= led['screen_sec']
        assert sum(i['sec'] for i in led['top_apps']) <= led['screen_sec']
        assert all(s['sec'] <= led['longest_session_sec'] for s in led['sessions'])
        assert sum(led['hourly']) == led['screen_sec']


def test_live_session_kept_when_really_using(client_a):
    uid = client_a.get('/api/me', headers=HEADERS).json()['user']['id']
    with db.connect() as c:
        _seed(c, uid)
        # 熄屏后再亮屏（16:00 起），17 分钟后仍在用：since 晚于熄屏，应保留且受总量约束
        _ev(c, uid, 'usage.now', _ts(16, 17), app='微信', since=_ts(16, 0), masked=False)
        policy = {'usage_level': 'full', 'app_level': 'stream', 'network_level': 'ssid'}
        led = peer_agg.reconcile_usage_day(c, uid, DAY, policy, now=_ts(16, 17))
        assert led['current_app'] is not None
        assert led['current_app']['app'] == '微信'
        assert led['current_app']['sec'] <= led['longest_session_sec'] or led['current_app']['sec'] <= 1800


def test_network_same_source(client_a):
    uid = client_a.get('/api/me', headers=HEADERS).json()['user']['id']
    with db.connect() as c:
        _seed(c, uid)
        policy = {'usage_level': 'full', 'app_level': 'stream', 'network_level': 'ssid'}
        net = peer_agg.current_network_for(c, uid, policy)
        # 当日无 state.net，也要能从 latest 快照读到（异常③）
        assert net and net['net'] == 'wifi' and net['ssid'] == 'CMCC-p3j5'


def test_cross_off_screen_session_is_split(client_a):
    uid = client_a.get('/api/me', headers=HEADERS).json()['user']['id']
    with db.connect() as c:
        # 一个 10:00-11:00 的长会话，中间 10:05-10:50 是熄屏（用亮屏窗表示）
        _ev(c, uid, 'state.screen', _ts(10, 5), on=False, session_sec=300)
        _ev(c, uid, 'state.screen', _ts(11, 0), on=False, session_sec=600)
        _ev(c, uid, 'usage.session', _ts(11, 0), app='微信',
            start=_ts(10, 0), end=_ts(11, 0), dur=3600, masked=False)
        policy = {'usage_level': 'full', 'app_level': 'stream', 'network_level': 'ssid'}
        led = peer_agg.reconcile_usage_day(c, uid, DAY, policy, now=_ts(11, 30))
        mine = [s for s in led['sessions'] if s['app'] == '微信']
        assert len(mine) >= 2, '跨灭屏的会话必须被切分'
        for s in mine:
            assert s['sec'] <= led['longest_session_sec']


def test_status_state_daily_usage_daily_agree(client_a, client_b):
    uid = client_a.get('/api/me', headers=HEADERS).json()['user']['id']
    with db.connect() as c:
        _seed(c, uid)
        c.execute("INSERT OR REPLACE INTO app_state(key,value) VALUES (?,?)",
                  (f'peer_policy:{uid}',
                   db.dumps({'usage_level': 'full', 'app_level': 'stream',
                             'network_level': 'ssid', 'events': True})))
    st = client_a.get('/api/peer/status', headers=HEADERS).json()
    sd = client_a.get(f'/api/peer/state-daily?date={DAY}', headers=HEADERS).json()
    ud = client_a.get(f'/api/peer/usage-daily?date={DAY}', headers=HEADERS).json()
    assert st['mine']['current_app'] is None
    assert sd['mine']['screen_sec'] == ud['mine']['screen_sec']
    assert ud['mine']['current_app'] is None
