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

HEADERS = {'X-Love-Space': '1'}


def test_watch_starts_empty(client_a):
    st = client_a.get('/api/watch', headers=HEADERS).json()
    assert not st.get('title')
    assert not st.get('media')
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
