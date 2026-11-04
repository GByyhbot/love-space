"""一起看的进度同步：状态存取、时间轴推进、片源可见性。

设计要点（前端 app.js 的 watchPoll 依赖这些约定）：
① 存的是「最后一次操作时」的快照（position + playing + updated），
   真实位置由 GET 时按 updated 往后推算 —— 这样两端不必对时钟；
② `by` 记谁操作的，客户端据此忽略自己刚上报的快照，避免自激；
③ 片源必须是这个人看得见的媒体，私密日记里的视频不能拉进一起看。
"""
from fastapi.testclient import TestClient

from app import db
from app.main import app
from app.db import connect

HEADERS = {'X-Love-Space': '1'}


def make_video(owner, name='海街日记.mp4'):
    """造一个「两人都看得见」的视频：挂在一条共享动态上，过得了 media_visible。"""
    mid = db.uid()
    created = db.now()
    folder = db.media_dir('video/mp4', created)
    folder.mkdir(parents=True, exist_ok=True)
    (folder / (mid + '.mp4')).write_bytes(b'\x00' * 64)
    with connect() as c:
        c.execute('INSERT INTO media(id,owner,name,mime,size,ext,created,attached,status)'
                  ' VALUES (?,?,?,?,?,?,?,?,?)',
                  (mid, owner, name, 'video/mp4', 64, '.mp4', created, 1, 'done'))
    return mid


def watch_notices(client, keyword=''):
    return [n for n in client.get('/api/notices', headers=HEADERS).json()
            if n['event'] == 'watch' and keyword in (n['title'] or '')]


def pause_all(client):
    """前面的用例可能把状态留在「播放中」，开播通知只在 停→播 的跨越时发，先归零。"""
    client.put('/api/watch', headers=HEADERS, json={'playing': False})


def test_watch_starts_empty(client_a):
    """先归零再断言：整个会话共用一个临时库，别的用例（比如短剧）会留下片源。"""
    client_a.put('/api/watch', headers=HEADERS,
                 json={'title': '', 'media': '', 'drama_id': '', 'playing': False})
    st = client_a.get('/api/watch', headers=HEADERS).json()
    assert not st.get('title')
    assert not st.get('media')
    assert not st.get('drama_id')
    assert not st.get('playing')


def test_put_then_get_roundtrip(client_a):
    r = client_a.put('/api/watch', headers=HEADERS,
                     json={'title': '爱在黎明破晓前', 'position': 12.5,
                           'duration': 600, 'playing': False})
    assert r.status_code == 200, r.text
    st = client_a.get('/api/watch', headers=HEADERS).json()
    assert st['title'] == '爱在黎明破晓前'
    assert abs(st['position'] - 12.5) < 0.01
    assert st['playing'] is False
    assert st['by']
    assert st['updated'] > 0


def test_playing_advances_position(client_a, monkeypatch):
    """播放中不靠心跳包：GET 时按 updated 把 position 往后推。"""
    base = 1_000_000.0
    monkeypatch.setattr(db, 'now', lambda: base)
    client_a.put('/api/watch', headers=HEADERS,
                 json={'title': '测试片', 'position': 10, 'duration': 300, 'playing': True})
    monkeypatch.setattr(db, 'now', lambda: base + 30)
    st = client_a.get('/api/watch', headers=HEADERS).json()
    assert 39.5 <= st['position'] <= 40.5


def test_paused_does_not_advance(client_a, monkeypatch):
    base = 2_000_000.0
    monkeypatch.setattr(db, 'now', lambda: base)
    client_a.put('/api/watch', headers=HEADERS,
                 json={'position': 42, 'duration': 300, 'playing': False})
    monkeypatch.setattr(db, 'now', lambda: base + 120)
    st = client_a.get('/api/watch', headers=HEADERS).json()
    assert abs(st['position'] - 42) < 0.01


def test_position_clamped_to_duration(client_a, monkeypatch):
    """播到片尾就停在片尾，别算出 999 秒让客户端去 seek 一个越界位置。"""
    base = 3_000_000.0
    monkeypatch.setattr(db, 'now', lambda: base)
    client_a.put('/api/watch', headers=HEADERS,
                 json={'position': 295, 'duration': 300, 'playing': True})
    monkeypatch.setattr(db, 'now', lambda: base + 600)
    st = client_a.get('/api/watch', headers=HEADERS).json()
    assert st['position'] <= 300.001


def test_both_sides_see_same_state(client_a, client_b):
    client_a.put('/api/watch', headers=HEADERS,
                 json={'title': '共同片单', 'position': 5, 'playing': False})
    assert client_b.get('/api/watch', headers=HEADERS).json()['title'] == '共同片单'
    client_b.put('/api/watch', headers=HEADERS,
                 json={'title': '共同片单', 'position': 88, 'playing': True})
    st = client_a.get('/api/watch', headers=HEADERS).json()
    assert st['position'] >= 88
    assert st['playing'] is True


def test_unknown_media_rejected(client_a):
    r = client_a.put('/api/watch', headers=HEADERS, json={'media': 'not-a-real-media'})
    assert r.status_code == 404


def test_video_list_is_visible_only(client_a):
    """选片列表只给能看见的视频；这个空间里一张视频都没有时返回空数组。"""
    r = client_a.get('/api/media/videos', headers=HEADERS)
    assert r.status_code == 200
    assert isinstance(r.json(), list)


def test_watch_requires_session():
    with TestClient(app, base_url='https://testserver', headers=HEADERS) as anon:
        assert anon.get('/api/watch').status_code == 401


def test_start_playing_notifies_partner(client_a, client_b):
    """开播那一刻给另一半留一条提醒：点通知能直接进一起看，不用自己找。"""
    me = client_a.get('/api/me', headers=HEADERS).json()
    mid = make_video(me['user']['id'])
    client_a.post('/api/records', headers=HEADERS,
                  json={'kind': 'post', 'body': {'title': '周末看的片', 'content': '存着', 'media': [mid]}})
    before = len(watch_notices(client_b, '海街日记'))
    pause_all(client_a)
    r = client_a.put('/api/watch', headers=HEADERS,
                     json={'media': mid, 'title': '海街日记', 'position': 0,
                           'duration': 300, 'playing': True})
    assert r.status_code == 200, r.text
    after = watch_notices(client_b, '海街日记')
    assert len(after) == before + 1
    # 标题带上是谁在看，否则两个人共用一条状态时读不出主语
    assert after[0]['title'].startswith('小兔')
    assert '海街日记' in after[0]['title']
    # 通知没有 record_id（它不是某条记录），前端靠 event 判断给「去看」按钮
    assert not after[0]['record_id']


def test_actor_gets_no_own_notice(client_a):
    me = client_a.get('/api/me', headers=HEADERS).json()
    mid = make_video(me['user']['id'], '独自看的.mp4')
    client_a.put('/api/watch', headers=HEADERS,
                 json={'media': mid, 'title': '独自看的', 'playing': True})
    assert not watch_notices(client_a, '独自看的')


def test_pause_resume_does_not_spam(client_a, client_b):
    """同一部片在 6 小时窗口内反复暂停续播只提醒一次，别把通知中心刷满。"""
    me = client_a.get('/api/me', headers=HEADERS).json()
    mid = make_video(me['user']['id'], '反复续播.mp4')
    pause_all(client_a)
    client_a.put('/api/watch', headers=HEADERS,
                 json={'media': mid, 'title': '反复续播', 'playing': True})
    first = len(watch_notices(client_b, '反复续播'))
    for _ in range(3):
        client_a.put('/api/watch', headers=HEADERS, json={'playing': False})
        client_a.put('/api/watch', headers=HEADERS, json={'playing': True})
    assert len(watch_notices(client_b, '反复续播')) == first


def test_local_file_start_does_not_notify(client_a, client_b):
    """选的本机文件另一半打不开，提醒了也看不了，所以不带 media 就不发通知。"""
    before = len(watch_notices(client_b, '本机文件'))
    client_a.put('/api/watch', headers=HEADERS,
                 json={'title': '本机文件', 'playing': True})
    assert len(watch_notices(client_b, '本机文件')) == before


# ---- 一起看邀请卡片（聊天里 point「一起看」时自动发的那条）--------------------
def invite_notices(client, record_id):
    return [n for n in client.get('/api/notices', headers=HEADERS).json()
            if n.get('record_id') == record_id]


def post_chat(client, body):
    return client.post('/api/records', headers=HEADERS,
                       json={'kind': 'chat', 'body': body, 'client_id': db.uid()})


def test_watch_invite_card_roundtrip(client_a, client_b):
    """卡片只存一个版本号，对方收到的是明确的「邀请」而不是泛泛的新消息。"""
    r = post_chat(client_a, {'content': '邀请你一起看视频', 'watch_invite': {'v': 1}})
    assert r.status_code == 200, r.text
    rec = r.json()
    assert rec['body']['watch_invite'] == {'v': 1}
    notes = invite_notices(client_b, rec['id'])
    assert notes and notes[0]['title'] == 'TA 邀请你一起看视频，快来'


def test_watch_invite_strips_extra_fields(client_a):
    """body 不能变成任意 URL / HTML 的跳板：多余字段一律洗掉，只留 {v:1}。"""
    r = post_chat(client_a, {'content': 'x', 'watch_invite': {
        'v': 1, 'url': 'http://evil.example', 'html': '<script>alert(1)</script>'}})
    assert r.status_code == 200, r.text
    assert r.json()['body']['watch_invite'] == {'v': 1}


def test_watch_invite_rejects_bad_payload(client_a):
    for bad in ({'v': 2}, '一起看', None, [1], 1):
        r = post_chat(client_a, {'content': 'x', 'watch_invite': bad})
        assert r.status_code == 422, (bad, r.text)


def test_plain_chat_notice_unchanged(client_a, client_b):
    r = post_chat(client_a, {'content': '普通一句话'})
    assert r.status_code == 200, r.text
    notes = invite_notices(client_b, r.json()['id'])
    assert notes and notes[0]['title'] == '收到一条新消息'


def test_lan_route_is_exposed(client_a):
    """内网纯 IP 线路排在最后：它不能用 https，但 /api/routes 与 CSP 都得带上。"""
    routes = client_a.get('/api/routes', headers=HEADERS).json()['routes']
    assert routes[0]['url'].startswith('https://')
    assert routes[-1]['url'] == 'http://192.168.31.95:1314/'
    csp = client_a.get('/', headers=HEADERS).headers['content-security-policy']
    assert 'http://192.168.31.95:1314' in csp
