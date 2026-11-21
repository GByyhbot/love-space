"""2.6.0 性能段第二批护栏（P3/P12：revision 键控缓存）。

钉住四条容易悄悄退化的地方：
1. 命中语义：同一请求第二次走缓存（计算体不重跑），且结果与首次逐项相等；
2. 失效链：任何内容写入（records/likes/period 分库 _period_touch）推
   content_revision → 缓存整体失配，stale 结果不可能出现；
3. 用户隔离：同 revision 下两个用户的键不同——私密记录不泄漏到对方聚合；
4. 「今天」键：dashboard 的 days_together 与 on-this-day 的 is_today 随天变，
   键必须含当天日期（源码级断言）。
对拍口径（主人裁定①）：筛选逻辑（album_only、可见性、body.date 优先）以既有
yearbook_243/dashboard 回归 + 本文件对拍共同覆盖。
"""
import json

from app import db, rev_cache

HEADERS = {'X-Love-Space': '1'}


def _reset_cache():
    rev_cache._rev_cache['rev'] = -1
    rev_cache._rev_cache['data'] = {}


def _upload(client, name='a.png'):
    from io import BytesIO
    from PIL import Image
    buf = BytesIO()
    Image.new('RGB', (4, 4), 'red').save(buf, format='PNG')
    buf.seek(0)
    r = client.post('/api/media', files={'file': (name, buf, 'image/png')},
                    headers=HEADERS)
    assert r.status_code == 200, r.text
    return r.json()['id']


def test_cache_hit_second_call_skips_compute(client_a):
    _reset_cache()
    r1 = client_a.get('/api/yearbook').json()
    n_after_first = len(rev_cache._rev_cache['data'])
    assert n_after_first >= 1, '首次调用必须落缓存'

    # 直接调计算体一次并改写返回对象的一个字段，再走端点——若第二次真的
    # 走了缓存，端点返回的是缓存里的对象（未被改写影响的那份引用）。
    # 更直接的证明：往缓存里塞一个哨兵值，端点必须原样返回它。
    key = ('yearbook', client_a.get('/api/me').json()['user']['id'],
           client_a.get('/api/yearbook').json()['year'])
    sentinel = {'__sentinel__': True}
    rev_cache._rev_cache['data'][key] = sentinel
    r2 = client_a.get('/api/yearbook').json()
    assert r2 is sentinel or r2.get('__sentinel__') is True, \
        '第二次调用必须命中缓存返回哨兵'


def test_write_invalidates_cache(client_a):
    _reset_cache()
    before = client_a.get('/api/yearbook').json()
    dash_before = client_a.get('/api/dashboard').json()
    r = client_a.post('/api/records', headers=HEADERS, json={
        'kind': 'note', 'body': {'title': '失效链对拍', 'content': '写后必须刷新'}})
    assert r.status_code == 200
    rid = r.json()['id']
    after = client_a.get('/api/yearbook').json()
    assert after['total'] == before['total'] + 1, '写入后缓存必须失效重算'
    # dashboard 同链（total 口径=全库可见含 chat，与 yearbook 不同，用自身前后对比）
    dash_after = client_a.get('/api/dashboard').json()
    assert dash_after['total'] == dash_before['total'] + 1
    client_a.delete(f'/api/records/{rid}', headers=HEADERS)


def test_period_touch_invalidates_cache(client_a):
    """口径②：period 分库写入走 _period_touch 推 content_revision——
    失效链必须覆盖到全部四个键控接口（stale 不可能出现）。"""
    _reset_cache()
    client_a.get('/api/yearbook')
    client_a.get('/api/dashboard')
    client_a.get('/api/on-this-day')
    client_a.get('/api/calendar')
    rev_before = rev_cache.current_revision()

    r = client_a.post('/api/records', headers=HEADERS, json={
        'kind': 'period',
        'body': {'date': '2026-11-21', 'flow': 3},
    })
    assert r.status_code == 200, r.text
    rev_after = rev_cache.current_revision()
    assert rev_after > rev_before, '_period_touch 必须推 content_revision'

    # revision 已变：端点再调时缓存整体失配（重算），绝不会返回 stale
    for path in ('/api/yearbook', '/api/dashboard', '/api/on-this-day',
                 '/api/calendar'):
        resp = client_a.get(path).json()
        assert resp is not None
    keys = list(rev_cache._rev_cache['data'].keys())
    assert len(keys) >= 1 and rev_cache._rev_cache['rev'] == rev_after


def test_user_scoped_keys_no_private_leak(client_a, client_b):
    """同 revision 下两用户键不同：a 的私密日记不进 b 的聚合。"""
    _reset_cache()
    client_b.get('/api/yearbook')  # b 先跑，播种缓存
    r = client_a.post('/api/records', headers=HEADERS, json={
        'kind': 'diary', 'body': {'title': 'a的私密', 'content': '只有a可见'}})
    assert r.status_code == 200
    rid = r.json()['id']
    ya = client_a.get('/api/yearbook').json()
    yb = client_b.get('/api/yearbook').json()
    assert ya['total'] > yb['total'], \
        '私密日记只进作者侧聚合（可见性口径不被缓存破坏）'
    client_a.delete(f'/api/records/{rid}', headers=HEADERS)


def test_body_date_takes_priority_over_created(client_a):
    """body.date 优先：事发日在去年的记录不进当前年统计（对拍口径①）。"""
    _reset_cache()
    before = client_a.get('/api/yearbook').json()
    r = client_a.post('/api/records', headers=HEADERS, json={
        'kind': 'note',
        'body': {'title': '去年补记', 'content': 'date 优先',
                 'date': '2020-06-01'}})
    assert r.status_code == 200
    after = client_a.get('/api/yearbook').json()
    assert after['total'] == before['total'], 'body.date 在 2020 → 不进当前年'
    client_a.delete(f"/api/records/{r.json()['id']}", headers=HEADERS)


def test_album_only_post_excluded_from_yearbook_and_otd(client_a):
    """album_only 专照动态不进年报/历史上的今天（2.4.2 口径，缓存下仍成立）。"""
    _reset_cache()
    before = client_a.get('/api/yearbook').json()
    r = client_a.post('/api/records', headers=HEADERS, json={
        'kind': 'post',
        'body': {'media': [_upload(client_a)], 'album_only': True}})
    assert r.status_code == 200
    rid = r.json()['id']
    after = client_a.get('/api/yearbook').json()
    assert after['by_kind'].get('post', 0) == before['by_kind'].get('post', 0), \
        'album_only post 不进年报计数'
    otd = client_a.get('/api/on-this-day').json()
    flat = [it for g in otd for it in g['items']]
    assert all(it['id'] != rid for it in flat), 'album_only post 不进历史上的今天'
    client_a.delete(f'/api/records/{rid}', headers=HEADERS)


def test_today_scoped_keys_in_source():
    """「今天」键：dashboard 键含当天日期、on-this-day 键含今天月日+年。"""
    src = open('app/main.py', encoding='utf-8').read()
    assert "('dashboard', user['id'], today_iso)" in src
    assert "('on-this-day', user['id'], today_md, today_year)" in src
    assert "('yearbook', user['id'], y)" in src
    assert "('calendar', user['id'], month)" in src


def test_cache_clears_on_revision_change_internals():
    """rev 变化即整体清空：_rev_cache 的 rev 校验逻辑直测。"""
    _reset_cache()
    rev_cache._rev_cache['data'][('k',)] = {'x': 1}
    rev_cache._rev_cache['rev'] = 1
    # 模拟一次 cached() 调用（当前库的 revision 必然 != 1）
    called = []
    val = rev_cache.cached(('probe',), lambda: called.append(1) or {'ok': True})
    assert val == {'ok': True}
    assert ('k',) not in rev_cache._rev_cache['data'], 'rev 变化必须全清'
    assert rev_cache._rev_cache['rev'] == rev_cache.current_revision()
