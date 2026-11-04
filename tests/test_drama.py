"""红果短剧：列表/详情/流代理，以及 watch 状态里的剧集字段。

上游是 NAS 上的 Capy Backend（:8788）。测试里用 httpx.MockTransport 顶替它，
不碰真实网络 —— CI 上没有那个服务。
"""
import pytest
import httpx

from app import dramas
from app.main import app

HEADERS = {'X-Love-Space': '1'}

ITEM_ID = '7698294694886788121'

BROWSE = {'items': [
    {'id': ITEM_ID, 'title': '和离后我带女儿横扫魔域', 'posterUrl': 'http://p/1.jpg',
     'remark': '全60集', 'description': '一个很长的简介'},
    {'id': '', 'title': '没有 id 的脏数据'},
    {'id': '123', 'title': ''},
]}

DETAIL = {'title': '和离后我带女儿横扫魔域', 'posterUrl': 'http://p/1.jpg',
          'description': '简介', 'seasons': [{'seasonNumber': 1, 'episodes': [
              {'id': 'ep-1', 'episodeNumber': 1, 'title': '第1集', 'streamUrl': 'http://u/api/v1/stream/1'},
              {'id': 'ep-2', 'episodeNumber': 2, 'title': '第2集', 'streamUrl': 'http://u/api/v1/stream/2'},
          ]}]}


@pytest.fixture
def upstream(monkeypatch):
    """按路径分发的假上游；返回一个可改写的 dict 方便单条用例调行为。"""
    state = {'range': '', 'hits': []}

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        state['hits'].append(path)
        if path.endswith('/browse'):
            return httpx.Response(200, json=BROWSE)
        if path.endswith('/search'):
            return httpx.Response(200, json=BROWSE)
        if '/items/' in path:
            return httpx.Response(200, json=DETAIL)
        if path.startswith('/api/v1/stream/'):
            state['range'] = request.headers.get('range', '')
            return httpx.Response(206, content=b'x' * 64,
                                  headers={'content-type': 'video/mp4',
                                           'content-range': 'bytes 0-63/1024',
                                           'accept-ranges': 'bytes'})
        return httpx.Response(404, json={'detail': 'nope'})

    monkeypatch.setattr(dramas, '_transport', httpx.MockTransport(handler))
    monkeypatch.setattr(dramas, '_core', {})
    return state


def test_browse_is_normalized_and_dirty_rows_dropped(client_a, upstream):
    r = client_a.get('/api/dramas?category=short&page=1', headers=HEADERS)
    assert r.status_code == 200, r.text
    items = r.json()['items']
    # 空 id / 空标题的行不该出现在列表里
    assert [x['id'] for x in items] == [ITEM_ID]
    assert items[0]['title'] == '和离后我带女儿横扫魔域'
    assert items[0]['remark'] == '全60集'


def test_search_passes_keyword_through(client_a, upstream):
    r = client_a.get('/api/dramas?q=少夫人', headers=HEADERS)
    assert r.status_code == 200
    assert any('/search' in p for p in upstream['hits'])


def test_detail_never_leaks_stream_urls(client_a, upstream):
    """直链带签名、约 24 小时过期，下发给前端只会变成一张隔天打不开的地址。"""
    r = client_a.get(f'/api/dramas/{ITEM_ID}', headers=HEADERS)
    assert r.status_code == 200, r.text
    body = r.json()
    assert [e['n'] for e in body['episodes']] == [1, 2]
    assert '/api/v1/stream/1' not in r.text
    assert 'streamUrl' not in r.text


def test_stream_forwards_range_and_status(client_a, upstream):
    r = client_a.get(f'/api/dramas/{ITEM_ID}/stream/2',
                     headers={**HEADERS, 'Range': 'bytes=0-63'})
    assert r.status_code == 206, r.text
    assert r.headers['content-range'] == 'bytes 0-63/1024'
    assert r.headers['accept-ranges'] == 'bytes'
    assert r.headers['content-type'].startswith('video/mp4')
    assert r.content == b'x' * 64
    assert upstream['range'] == 'bytes=0-63'


def test_stream_requires_login():
    from fastapi.testclient import TestClient
    with TestClient(app, base_url='https://testserver', headers=HEADERS) as anon:
        assert anon.get(f'/api/dramas/{ITEM_ID}/stream/1').status_code == 401
        assert anon.get('/api/dramas').status_code == 401


def test_watch_stores_drama_and_clears_media(client_a, upstream):
    r = client_a.put('/api/watch', headers=HEADERS, json={
        'drama_id': ITEM_ID, 'drama_ep': 3, 'media': '',
        'title': '和离后我带女儿横扫魔域', 'position': 0, 'playing': False})
    assert r.status_code == 200, r.text
    st = client_a.get('/api/watch', headers=HEADERS).json()
    assert st['drama_id'] == ITEM_ID
    assert st['drama_ep'] == 3
    assert not st.get('media')


def _make_video(owner):
    """造一条能过 media_visible 的视频媒体（用来验「换回相册片源会清掉短剧」）。"""
    from app import db
    from app.db import connect
    mid = db.uid()
    created = db.now()
    folder = db.media_dir('video/mp4', created)
    folder.mkdir(parents=True, exist_ok=True)
    (folder / (mid + '.mp4')).write_bytes(b'\x00' * 32)
    with connect() as c:
        c.execute('INSERT INTO media(id,owner,name,mime,size,ext,created,attached,status)'
                  ' VALUES (?,?,?,?,?,?,?,?,?)',
                  (mid, owner, 'clip.mp4', 'video/mp4', 32, '.mp4', created, 1, 'done'))
    return mid


def test_switching_back_to_album_clears_drama(client_a, upstream):
    """两条来源必须互斥：都留着的话两端播放器会各播各的。"""
    me = client_a.get('/api/me', headers=HEADERS).json()
    mid = _make_video(me['user']['id'])
    client_a.put('/api/watch', headers=HEADERS, json={
        'drama_id': ITEM_ID, 'drama_ep': 2, 'title': '剧', 'playing': False})
    r = client_a.put('/api/watch', headers=HEADERS, json={'media': mid, 'title': '片'})
    assert r.status_code == 200, r.text
    st = client_a.get('/api/watch', headers=HEADERS).json()
    assert st['media'] == mid
    assert not st.get('drama_id')


@pytest.mark.parametrize('bad', ['abc', '../admin', '1/2', ''])
def test_bad_drama_id_rejected(client_a, upstream, bad):
    """剧 id 会拼进上游 URL，必须是纯数字，否则能拐到别的接口去。"""
    r = client_a.put('/api/watch', headers=HEADERS,
                     json={'drama_id': bad, 'drama_ep': 1})
    if bad == '':
        # 空串等于「清掉短剧来源」，是合法请求
        assert r.status_code == 200
    else:
        assert r.status_code == 400


def test_episode_out_of_range(client_a, upstream):
    r = client_a.put('/api/watch', headers=HEADERS,
                     json={'drama_id': ITEM_ID, 'drama_ep': 99999})
    assert r.status_code == 400


def test_upstream_down_gives_502(client_a, monkeypatch):
    def handler(request):
        raise httpx.ConnectError('boom')

    monkeypatch.setattr(dramas, '_transport', httpx.MockTransport(handler))
    monkeypatch.setattr(dramas, '_core', {})
    r = client_a.get('/api/dramas?category=short', headers=HEADERS)
    assert r.status_code == 502
    assert '连不上' in r.text
