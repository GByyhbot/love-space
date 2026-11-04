"""在线片源：组件清单、服务增删、列表/详情/流代理，以及 watch 状态里的来源字段。

上游是 NAS 上的 happy-capy 那类「组件聚合器」（:8788），一台服务代理十几个内容源。
测试里用 httpx.MockTransport 顶替它，不碰真实网络 —— CI 上没有那个服务。
"""
import pytest
import httpx

from app import db, dramas
from app.db import connect
from app.main import app

HEADERS = {'X-Love-Space': '1'}

ITEM_ID = '7698294694886788121'
BASE = '/api/dramas/capy/hongguo'

PROVIDERS = {'providers': [
    {'id': 'hongguo', 'title': '红果短剧', 'version': '0.1.0',
     'capabilities': ['browse', 'detail', 'search'],
     'categories': [{'id': 'short', 'title': '短剧'}, {'id': 'comic', 'title': '漫剧'}]},
    {'id': 'huangju', 'title': '剧果', 'capabilities': ['browse'],
     'categories': [{'id': 'film', 'title': '影视'}]},
    # id 会拼进上游 URL，这种脏数据必须被丢掉
    {'id': '../evil', 'title': '坏数据'},
]}

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


@pytest.fixture(autouse=True)
def clean_state():
    """每个用例从「没配过任何片源」的干净状态起步（会话共用一个库）。"""
    with connect() as c:
        c.execute("DELETE FROM settings WHERE key IN ('drama_sources', 'watch')")
    dramas._core.clear()
    dramas._providers.clear()
    yield


@pytest.fixture
def upstream(monkeypatch):
    """按路径分发的假上游；返回一个可改写的 dict 方便单条用例调行为。"""
    state = {'range': '', 'hits': [], 'bases': []}

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        state['hits'].append(path)
        state['bases'].append(str(request.url).rsplit(path, 1)[0])
        if path == '/api/v1/providers':
            return httpx.Response(200, json=PROVIDERS)
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
    return state


# ── 组件清单 ────────────────────────────────────────────────────────────
def test_catalog_lists_providers_and_marks_default_enabled(client_a, upstream):
    r = client_a.get('/api/drama-sources', headers=HEADERS)
    assert r.status_code == 200, r.text
    svc = r.json()['services'][0]
    assert svc['id'] == 'capy' and svc['online'] is True
    # 脏 id 被丢掉，顺序不变
    assert [p['id'] for p in svc['providers']] == ['hongguo', 'huangju']
    assert svc['providers'][0]['enabled'] is True
    assert svc['providers'][1]['enabled'] is False
    assert svc['providers'][0]['categories'][0]['title'] == '短剧'


def test_catalog_marks_service_offline_when_unreachable(client_a, monkeypatch):
    def handler(request):
        raise httpx.ConnectError('boom')

    monkeypatch.setattr(dramas, '_transport', httpx.MockTransport(handler))
    svc = client_a.get('/api/drama-sources', headers=HEADERS).json()['services'][0]
    assert svc['online'] is False
    assert '连不上' in svc['error']


# ── 内容 ────────────────────────────────────────────────────────────────
def test_browse_is_normalized_and_dirty_rows_dropped(client_a, upstream):
    r = client_a.get(BASE + '?category=short&page=1', headers=HEADERS)
    assert r.status_code == 200, r.text
    items = r.json()['items']
    # 空 id / 空标题的行不该出现在列表里
    assert [x['id'] for x in items] == [ITEM_ID]
    assert items[0]['title'] == '和离后我带女儿横扫魔域'
    assert items[0]['remark'] == '全60集'


def test_request_goes_to_the_provider_in_the_path(client_a, upstream):
    """路径里的组件必须原样落到上游 URL 上，否则所有源都会串成同一家。"""
    client_a.put('/api/drama-sources/enabled', headers=HEADERS,
                 json={'enabled': ['capy:hongguo', 'capy:huangju']})
    assert client_a.get('/api/dramas/capy/huangju', headers=HEADERS).status_code == 200
    assert any('/api/v1/providers/huangju/' in p for p in upstream['hits'])


def test_search_passes_keyword_through(client_a, upstream):
    r = client_a.get(BASE + '?q=少夫人', headers=HEADERS)
    assert r.status_code == 200
    assert any('/search' in p for p in upstream['hits'])


def test_detail_never_leaks_stream_urls(client_a, upstream):
    """直链带签名、约 24 小时过期，下发给前端只会变成一张隔天打不开的地址。"""
    r = client_a.get(f'{BASE}/{ITEM_ID}', headers=HEADERS)
    assert r.status_code == 200, r.text
    body = r.json()
    assert [e['n'] for e in body['episodes']] == [1, 2]
    assert '/api/v1/stream/1' not in r.text
    assert 'streamUrl' not in r.text


def test_stream_forwards_range_and_status(client_a, upstream):
    r = client_a.get(f'{BASE}/{ITEM_ID}/stream/2',
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
        assert anon.get(f'{BASE}/{ITEM_ID}/stream/1').status_code == 401
        assert anon.get(BASE).status_code == 401
        assert anon.get('/api/drama-sources').status_code == 401


# ── 组件开关 / 服务增删 ─────────────────────────────────────────────────
def test_disabled_provider_is_not_reachable(client_a, upstream):
    """没勾的组件不能靠手念接口绕过界面。"""
    assert client_a.get('/api/dramas/capy/huangju', headers=HEADERS).status_code == 403


def test_unknown_service_is_404(client_a, upstream):
    assert client_a.get('/api/dramas/nope/hongguo', headers=HEADERS).status_code == 404


def test_bad_provider_id_rejected(client_a, upstream):
    """组件 id 会拼进上游 URL，格式不对直接 400，不给「../」机会。"""
    assert client_a.get('/api/dramas/capy/bad%20id', headers=HEADERS).status_code == 400


def test_enable_and_disable_takes_effect(client_a, upstream):
    r = client_a.put('/api/drama-sources/enabled', headers=HEADERS,
                     json={'enabled': ['capy:huangju']})
    assert r.status_code == 200, r.text
    assert client_a.get('/api/dramas/capy/huangju', headers=HEADERS).status_code == 200
    assert client_a.get(BASE, headers=HEADERS).status_code == 403


def test_enabled_rejects_unknown_service(client_a, upstream):
    """瞎写的服务前缀直接丢掉，别在配置里留一堆死键。"""
    client_a.put('/api/drama-sources/enabled', headers=HEADERS,
                 json={'enabled': ['ghost:hongguo', 'capy:hongguo']})
    svc = client_a.get('/api/drama-sources', headers=HEADERS).json()['services'][0]
    assert [p['enabled'] for p in svc['providers']] == [True, False]


def test_add_service_shows_up_online(client_a, upstream):
    r = client_a.post('/api/drama-sources', headers=HEADERS,
                      json={'name': '家里那台', 'base': 'http://192.168.1.9:8788/'})
    assert r.status_code == 200, r.text
    services = client_a.get('/api/drama-sources', headers=HEADERS).json()['services']
    added = [s for s in services if s['base'] == 'http://192.168.1.9:8788']
    assert added and added[0]['name'] == '家里那台'
    # 尾部斜杠被吃掉，不会出现同一台服务加两遍
    dup = client_a.post('/api/drama-sources', headers=HEADERS,
                        json={'name': '再来一台', 'base': 'http://192.168.1.9:8788'})
    assert dup.status_code == 409


@pytest.mark.parametrize('base', [
    '', '   ', 'ftp://192.168.1.9:8788', '192.168.1.9:8788',
    'http://user:pw@192.168.1.9:8788', 'http://localhost:8788',
    'http://127.0.0.1:8788', 'http://127.0.0.2:8788',
])
def test_add_service_rejects_bad_base(client_a, base):
    """地址是主人手填的：只收 http(s)、不许带账号密码、不许指向本机。"""
    r = client_a.post('/api/drama-sources', headers=HEADERS,
                      json={'name': '试试', 'base': base})
    assert r.status_code == 400, r.text


def test_delete_service_drops_its_enabled_keys(client_a, upstream):
    client_a.post('/api/drama-sources', headers=HEADERS,
                  json={'name': '二号机', 'base': 'http://192.168.1.9:8788'})
    services = client_a.get('/api/drama-sources', headers=HEADERS).json()['services']
    sid = next(s['id'] for s in services if s['base'] == 'http://192.168.1.9:8788')
    client_a.put('/api/drama-sources/enabled', headers=HEADERS,
                 json={'enabled': ['capy:hongguo', f'{sid}:hongguo']})
    assert client_a.delete(f'/api/drama-sources/{sid}', headers=HEADERS).status_code == 200
    with connect() as c:
        cfg = db.setting(c, 'drama_sources', {})
    assert cfg['enabled'] == ['capy:hongguo']
    assert client_a.get('/api/dramas/' + sid + '/hongguo', headers=HEADERS).status_code == 404


# ── watch 状态 ──────────────────────────────────────────────────────────
def test_watch_stores_source_and_clears_media(client_a, upstream):
    r = client_a.put('/api/watch', headers=HEADERS, json={
        'drama_src': 'capy', 'drama_provider': 'hongguo',
        'drama_id': ITEM_ID, 'drama_ep': 3, 'media': '',
        'title': '和离后我带女儿横扫魔域', 'position': 0, 'playing': False})
    assert r.status_code == 200, r.text
    st = client_a.get('/api/watch', headers=HEADERS).json()
    assert (st['drama_src'], st['drama_provider']) == ('capy', 'hongguo')
    assert st['drama_id'] == ITEM_ID
    assert st['drama_ep'] == 3
    assert not st.get('media')


def test_watch_fills_source_when_client_omits_it(client_a, upstream):
    """1.7.21 之前前端只传剧 id；缺来源时补成第一个启用的组合，别让老状态卡住。"""
    client_a.put('/api/watch', headers=HEADERS,
                 json={'drama_id': ITEM_ID, 'drama_ep': 2, 'title': '剧'})
    st = client_a.get('/api/watch', headers=HEADERS).json()
    assert (st['drama_src'], st['drama_provider']) == ('capy', 'hongguo')


def test_watch_rejects_disabled_provider(client_a, upstream):
    r = client_a.put('/api/watch', headers=HEADERS, json={
        'drama_src': 'capy', 'drama_provider': 'huangju', 'drama_id': ITEM_ID})
    assert r.status_code == 403


def _make_video(owner):
    """造一条能过 media_visible 的视频媒体（用来验「换回相册片源会清掉在线片源」）。"""
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
        'drama_src': 'capy', 'drama_provider': 'hongguo',
        'drama_id': ITEM_ID, 'drama_ep': 2, 'title': '剧', 'playing': False})
    r = client_a.put('/api/watch', headers=HEADERS, json={'media': mid, 'title': '片'})
    assert r.status_code == 200, r.text
    st = client_a.get('/api/watch', headers=HEADERS).json()
    assert st['media'] == mid
    assert not st.get('drama_id')
    assert not st.get('drama_provider')


@pytest.mark.parametrize('bad', ['abc', '../admin', '1/2'])
def test_bad_drama_id_rejected(client_a, upstream, bad):
    """内容 id 会拼进上游 URL，必须是纯数字，否则能拐到别的接口去。"""
    r = client_a.put('/api/watch', headers=HEADERS,
                     json={'drama_id': bad, 'drama_ep': 1})
    assert r.status_code == 400


def test_episode_out_of_range(client_a, upstream):
    r = client_a.put('/api/watch', headers=HEADERS,
                     json={'drama_id': ITEM_ID, 'drama_ep': 99999})
    assert r.status_code == 400


def test_upstream_down_gives_502(client_a, monkeypatch):
    def handler(request):
        raise httpx.ConnectError('boom')

    monkeypatch.setattr(dramas, '_transport', httpx.MockTransport(handler))
    r = client_a.get(BASE, headers=HEADERS)
    assert r.status_code == 502
    assert '连不上' in r.text
