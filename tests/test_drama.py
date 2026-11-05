"""在线片源：组件清单、服务增删、列表/详情/流代理，以及 watch 状态里的来源字段。

上游是 NAS 上的 happy-capy 那类「组件聚合器」（:8788），一台服务代理十几个内容源。
测试里用 httpx.MockTransport 顶替它，不碰真实网络 —— CI 上没有那个服务。
"""
import re
from urllib.parse import quote, unquote

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
], 'page': 1, 'pageCount': 1413, 'total': 56496}

DETAIL = {'title': '和离后我带女儿横扫魔域', 'posterUrl': 'http://p/1.jpg',
          'description': '简介', 'seasons': [{'seasonNumber': 1, 'episodes': [
              {'id': 'ep-1', 'episodeNumber': 1, 'title': '第1集', 'streamUrl': 'http://u/api/v1/stream/1'},
              {'id': 'ep-2', 'episodeNumber': 2, 'title': '第2集', 'streamUrl': 'http://u/api/v1/stream/2'},
          ]}]}


@pytest.fixture(autouse=True)
def clean_state():
    """每个用例从「没配过任何片源」的干净状态起步（会话共用一个库）。"""
    with connect() as c:
        c.execute("DELETE FROM settings WHERE key IN "
                  "('drama_sources', 'drama_overlay', 'watch')")
    dramas._core.clear()
    dramas._providers.clear()
    dramas._list_cache.clear()
    dramas._health.clear()
    dramas._stream_probe.clear()
    dramas._part_key_cache = None
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


@pytest.mark.parametrize('bad', ['../admin', '1/2', '..', 'a b', 'a%2Fb', 'x' * 161])
def test_bad_drama_id_rejected(client_a, upstream, bad):
    """内容 id 会拼进上游 URL：不许斜杠、空格、.. 和百分号，也不许长到离谱。"""
    r = client_a.put('/api/watch', headers=HEADERS,
                     json={'drama_id': bad, 'drama_ep': 1})
    # 超长那条会被 Pydantic 的 max_length 先拦成 422，同样算「拒绝」
    assert r.status_code in (400, 422)


@pytest.mark.parametrize('good', ['miab-678', 'video@@fc2-ppv-5003075@@missav',
                                  '05bc37555886f920'])
def test_non_numeric_ids_are_accepted(client_a, upstream, good):
    """Jable / 蜜桃 / LissAV 的 id 都不是纯数字，以前一律 400 打不开。"""
    r = client_a.put('/api/watch', headers=HEADERS,
                     json={'drama_id': good, 'drama_ep': 1})
    assert r.status_code == 200, r.text
    # 拼进路径前要编码，@ 不能被当成路径的一部分
    r = client_a.get(f'{BASE}/{good}', headers=HEADERS)
    assert r.status_code == 200, r.text


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


# ── HLS：播放列表改写、签名分片、类型探测 ────────────────────────────────
# 只有红果吐 mp4，别的源大多是 m3u8。分片里有绝对 CDN 地址、相对路径、
# AES-128 密钥，三种都必须换成经本站的签名地址，浏览器才不会 404/跨域/403。
HLS_PLAYLIST_URL = 'http://u/api/v1/stream/hls'
HLS_TEXT = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-KEY:METHOD=AES-128,URI="https://cdn/key.bin"
#EXTINF:10.0,
https://cdn/seg0.ts
#EXTINF:10.0,
/relative/seg1.ts
#EXT-X-ENDLIST
'''


@pytest.fixture
def hls_upstream(monkeypatch):
    state = {'hits': []}

    def handler(request):
        path = request.url.path
        state['hits'].append(str(request.url))
        if path == '/api/v1/providers':
            return httpx.Response(200, json=PROVIDERS)
        if '/items/' in path:
            return httpx.Response(200, json={'title': 'HLS片', 'seasons': [{'episodes': [
                {'episodeNumber': 1, 'title': '第1集', 'streamUrl': HLS_PLAYLIST_URL}]}]})
        if path == '/api/v1/stream/hls':
            return httpx.Response(200, content=HLS_TEXT.encode(),
                                  headers={'content-type': 'application/vnd.apple.mpegurl'})
        if path.endswith('.ts') or path.endswith('.bin'):
            return httpx.Response(206, content=b'TS' * 16,
                                  headers={'content-type': 'video/mp2t',
                                           'content-range': 'bytes 0-31/32'})
        return httpx.Response(404, json={'detail': 'nope'})

    monkeypatch.setattr(dramas, '_transport', httpx.MockTransport(handler))
    return state


def _tokens(line):
    return [dramas.verify_part(unquote(m)) for m in
            re.findall(r'/api/drama-part\?t=([^"\s]+)', line)]


def test_rewrite_playlist_sends_every_uri_through_signed_proxy():
    lines = dramas.rewrite_playlist(HLS_TEXT, HLS_PLAYLIST_URL).splitlines()
    assert lines[0] == '#EXTM3U'
    # KEY 属性里的 URI 也要改写，否则 AES 密钥直连 CDN 会跨域失败
    key = next(l for l in lines if 'EXT-X-KEY' in l)
    assert _tokens(key) == [('https://cdn/key.bin', 'http://u/')]
    segs = [l for l in lines if l.startswith('/api/drama-part')]
    assert len(segs) == 2
    assert [t[0] for t in _tokens(' '.join(segs))] == [
        'https://cdn/seg0.ts', 'http://u/relative/seg1.ts']
    # 原始直链一条都不能漏给浏览器
    assert 'https://cdn/seg0.ts' not in '\n'.join(lines)


def test_relative_uris_resolve_against_redirected_source():
    """Capy 会 302 到源站 m3u8；enc.key / a0.ts 这类相对 URI 得按源站目录补全，
       按 Capy 的内网转发地址算会全部指到 /api/v1/stream/ 下，密钥和分片直接 401。"""
    text = ('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="enc.key"\n'
            '#EXTINF:10,\na0.ts\n#EXT-X-ENDLIST\n')
    out = dramas.rewrite_playlist(text, 'https://cdn.example/play/index.m3u8')
    found = _tokens(out)
    assert [u for u, _ in found] == [
        'https://cdn.example/play/enc.key', 'https://cdn.example/play/a0.ts']
    assert all(ref == 'https://cdn.example/' for _, ref in found)


def test_stream_follows_redirect_before_rewriting(client_a, monkeypatch):
    def handler(request):
        path = request.url.path
        if '/items/' in path:
            return httpx.Response(200, json={'title': '重定向片', 'seasons': [{'episodes': [
                {'episodeNumber': 1, 'title': '第1集',
                 'streamUrl': HLS_PLAYLIST_URL}]}]})
        if path == '/api/v1/stream/hls':
            return httpx.Response(302, headers={'location': 'https://cdn.example/play/index.m3u8'})
        if path == '/play/index.m3u8':
            return httpx.Response(200, content=b'#EXTM3U\n#EXTINF:10,\na0.ts\n#EXT-X-ENDLIST\n',
                                  headers={'content-type': 'application/vnd.apple.mpegurl'})
        return httpx.Response(404, json={'detail': 'nope'})

    monkeypatch.setattr(dramas, '_transport', httpx.MockTransport(handler))
    r = client_a.get(f'{BASE}/{ITEM_ID}/stream/1', headers=HEADERS)
    assert r.status_code == 200, r.text
    assert _tokens(r.text)[0] == ('https://cdn.example/play/a0.ts', 'https://cdn.example/')


def test_part_token_cannot_be_forged_or_reused_forever(monkeypatch):
    token = dramas.sign_part('http://u/a.ts', 'http://u/')
    assert dramas.verify_part(token) == ('http://u/a.ts', 'http://u/')
    assert dramas.verify_part(token + 'x') is None
    assert dramas.verify_part('') is None
    assert dramas.verify_part(dramas.sign_part('file:///etc/passwd')) is None
    real_time = dramas.time.time()
    monkeypatch.setattr(dramas.time, 'time', lambda: real_time + dramas.PART_TTL + 10)
    assert dramas.verify_part(token) is None


def test_source_reports_hls(client_a, hls_upstream):
    r = client_a.get(f'{BASE}/{ITEM_ID}/source/1', headers=HEADERS)
    assert r.status_code == 200, r.text
    assert r.json() == {'type': 'hls'}


def test_source_reports_mp4(client_a, upstream):
    r = client_a.get(f'{BASE}/{ITEM_ID}/source/2', headers=HEADERS)
    assert r.status_code == 200, r.text
    assert r.json() == {'type': 'mp4'}


def test_stream_returns_rewritten_playlist(client_a, hls_upstream):
    r = client_a.get(f'{BASE}/{ITEM_ID}/stream/1', headers=HEADERS)
    assert r.status_code == 200, r.text
    assert r.headers['x-love-stream'] == 'hls'
    assert r.headers['content-type'].startswith('application/vnd.apple.mpegurl')
    assert '/api/drama-part?t=' in r.text
    assert 'https://cdn/seg0.ts' not in r.text


def test_part_proxies_segment_and_rejects_bad_token(client_a, hls_upstream):
    token = dramas.sign_part('https://cdn/seg0.ts', 'http://u/')
    r = client_a.get('/api/drama-part?t=' + quote(token, safe=''), headers=HEADERS)
    assert r.status_code == 206, r.text
    assert r.content == b'TS' * 16
    assert client_a.get('/api/drama-part?t=garbage', headers=HEADERS).status_code == 403
    assert client_a.get('/api/drama-part', headers=HEADERS).status_code == 403


def test_part_requires_login():
    from fastapi.testclient import TestClient
    with TestClient(app, base_url='https://testserver', headers=HEADERS) as anon:
        assert anon.get('/api/drama-part?t=whatever').status_code == 401
        assert anon.get(f'{BASE}/{ITEM_ID}/source/1').status_code == 401


@pytest.fixture
def resolve_only_upstream(monkeypatch):
    """剧果那类：剧集里没有 streamUrl，只有 resolveUrl（解析后才给 videoUrl）。"""

    def handler(request):
        path = request.url.path
        if '/items/' in path:
            return httpx.Response(200, json={'title': '剧果片', 'seasons': [{'episodes': [
                {'episodeNumber': 1, 'title': '第1集',
                 'resolveUrl': 'http://u/api/v1/playback/r'}]}]})
        if path == '/api/v1/playback/r':
            return httpx.Response(200, json={'videoUrl': HLS_PLAYLIST_URL})
        if path == '/api/v1/stream/hls':
            return httpx.Response(200, content=HLS_TEXT.encode(),
                                  headers={'content-type': 'application/vnd.apple.mpegurl'})
        return httpx.Response(404, json={'detail': 'nope'})

    monkeypatch.setattr(dramas, '_transport', httpx.MockTransport(handler))


def test_resolve_only_episode_is_listed_and_playable(client_a, resolve_only_upstream):
    r = client_a.get(f'{BASE}/{ITEM_ID}', headers=HEADERS)
    assert r.status_code == 200, r.text
    assert [e['n'] for e in r.json()['episodes']] == [1]
    assert 'playback' not in r.text          # 直链依旧不下发
    r = client_a.get(f'{BASE}/{ITEM_ID}/source/1', headers=HEADERS)
    assert r.status_code == 200, r.text
    assert r.json() == {'type': 'hls'}


def test_media_url_episode_is_not_dropped(client_a, resolve_only_upstream, monkeypatch):
    """只有 mediaUrl、没有 resolveUrl 时也要能列出剧集，不能再报「没有可播的剧集」。"""
    def handler(request):
        if '/items/' in request.url.path:
            return httpx.Response(200, json={'title': '剧果片', 'seasons': [{'episodes': [
                {'episodeNumber': 1, 'title': '第1集',
                 'mediaUrl': HLS_PLAYLIST_URL}]}]})
        return httpx.Response(200, content=HLS_TEXT.encode(),
                              headers={'content-type': 'application/vnd.apple.mpegurl'})

    monkeypatch.setattr(dramas, '_transport', httpx.MockTransport(handler))
    r = client_a.get(f'{BASE}/{ITEM_ID}', headers=HEADERS)
    assert r.status_code == 200, r.text
    assert [e['n'] for e in r.json()['episodes']] == [1]


# ── 分页信息：别再让前端靠「这页满没满」猜 ──────────────────────────────
def test_list_passes_upstream_page_meta(client_a, monkeypatch):
    """pageCount/total 以前被丢掉，前端只能靠「这页满没满」猜有没有下一页。"""
    seen = {'page': ''}

    def handler(request):
        if request.url.path == '/api/v1/providers':
            return httpx.Response(200, json=PROVIDERS)
        seen['page'] = request.url.params.get('page', '')
        return httpx.Response(200, json={'items': [
            {'id': ITEM_ID, 'title': '一条'}], 'page': 2, 'pageCount': 1413, 'total': 56496})

    monkeypatch.setattr(dramas, '_transport', httpx.MockTransport(handler))
    body = client_a.get(BASE + '?category=short&page=2', headers=HEADERS).json()
    assert seen['page'] == '2'              # 请求确实带上了页码
    assert body['page'] == 2                # 以上游回的为准
    assert body['pageCount'] == 1413
    assert body['total'] == 56496


def test_list_without_meta_defaults_to_zero_not_error(client_a, monkeypatch):
    def handler(request):
        if request.url.path == '/api/v1/providers':
            return httpx.Response(200, json=PROVIDERS)
        return httpx.Response(200, json={'items': [
            {'id': '1', 'title': '只有条目没有分页'}]})

    monkeypatch.setattr(dramas, '_transport', httpx.MockTransport(handler))
    body = client_a.get(BASE + '?category=short', headers=HEADERS).json()
    assert body['items'] and body['pageCount'] == 0 and body['total'] == 0


# ── 上游抖动：5xx 值得再敲一次，4xx 不值得 ──────────────────────────────
def test_transient_5xx_is_retried_once(client_a, monkeypatch):
    calls = {'n': 0}

    def handler(request):
        path = request.url.path
        if path == '/api/v1/providers':
            return httpx.Response(200, json=PROVIDERS)
        if path.endswith('/browse'):
            calls['n'] += 1
            if calls['n'] == 1:
                return httpx.Response(504, json={'detail': 'gateway timeout'})
            return httpx.Response(200, json=BROWSE)
        return httpx.Response(404)

    monkeypatch.setattr(dramas, '_transport', httpx.MockTransport(handler))
    r = client_a.get(BASE + '?category=short', headers=HEADERS)
    assert r.status_code == 200, r.text          # 第二次成功，主人看不到这个 504
    assert calls['n'] == 2


def test_client_error_is_not_retried(client_a, monkeypatch):
    calls = {'n': 0}

    def handler(request):
        if request.url.path == '/api/v1/providers':
            return httpx.Response(200, json=PROVIDERS)
        calls['n'] += 1
        return httpx.Response(404, json={'detail': 'nope'})

    monkeypatch.setattr(dramas, '_transport', httpx.MockTransport(handler))
    assert client_a.get(BASE + '?category=x', headers=HEADERS).status_code == 404
    assert calls['n'] == 1


def test_health_is_recorded_and_exposed(client_a, monkeypatch):
    """组件挂了要在管理界面看得见，而不是等主人点进片源才发现是空的。"""
    def handler(request):
        if request.url.path == '/api/v1/providers':
            return httpx.Response(200, json=PROVIDERS)
        return httpx.Response(502, json={'detail': 'upstream down'})

    monkeypatch.setattr(dramas, '_transport', httpx.MockTransport(handler))
    assert client_a.get(BASE + '?category=short', headers=HEADERS).status_code == 502
    provs = client_a.get('/api/drama-sources', headers=HEADERS).json()['services'][0]['providers']
    hit = [p for p in provs if p['id'] == 'hongguo'][0]
    assert hit['health']['ok'] is False
    assert '502' in hit['health']['error']


# ── 覆盖层：上游负责发现，本地负责整理 ──────────────────────────────────
def test_overlay_aliases_and_tags_a_provider(client_a, upstream):
    key = 'capy:hongguo'
    r = client_a.put('/api/drama-sources/overlay', headers=HEADERS,
                     json={'key': key, 'alias': '红果', 'tag': '短剧', 'order': 5})
    assert r.status_code == 200, r.text
    prov = client_a.get('/api/drama-sources', headers=HEADERS).json()['services'][0]['providers'][0]
    assert prov['alias'] == '红果'
    assert prov['name'] == '红果'                 # 界面用 name，别名优先
    assert prov['title'] == '红果短剧'            # 上游原名留着，不覆盖
    assert prov['tag'] == '短剧' and prov['order'] == 5


def test_overlay_hidden_only_affects_local_view(client_a, upstream):
    client_a.put('/api/drama-sources/overlay', headers=HEADERS,
                 json={'key': 'capy:huangju', 'hidden': True})
    provs = client_a.get('/api/drama-sources', headers=HEADERS).json()['services'][0]['providers']
    assert [p['hidden'] for p in provs] == [False, True]
    # 隐藏只是「选择器里不显示」，接口本身不能因此拒绝服务
    assert client_a.get('/api/dramas/capy/huangju', headers=HEADERS).status_code in (200, 403)


def test_overlay_can_be_cleared(client_a, upstream):
    client_a.put('/api/drama-sources/overlay', headers=HEADERS,
                 json={'key': 'capy:hongguo', 'alias': '红果'})
    client_a.put('/api/drama-sources/overlay', headers=HEADERS,
                 json={'key': 'capy:hongguo', 'alias': ''})
    prov = client_a.get('/api/drama-sources', headers=HEADERS).json()['services'][0]['providers'][0]
    assert prov['alias'] == '' and prov['name'] == '红果短剧'


def test_overlay_rejects_unknown_service(client_a, upstream):
    r = client_a.put('/api/drama-sources/overlay', headers=HEADERS,
                     json={'key': 'ghost:hongguo', 'alias': 'x'})
    assert r.status_code == 404


def test_overlay_rejects_malformed_key(client_a, upstream):
    for key in ('hongguo', 'capy:bad id', ':hongguo'):
        r = client_a.put('/api/drama-sources/overlay', headers=HEADERS,
                         json={'key': key, 'alias': 'x'})
        assert r.status_code == 400, key


def test_overlay_survives_upstream_rename(client_a, monkeypatch):
    """上游把标题改了，主人的改名不该被冲掉 —— 这正是分两张表的意义。"""
    client_a.put('/api/drama-sources/overlay', headers=HEADERS,
                 json={'key': 'capy:hongguo', 'alias': '红果'})
    renamed = {'providers': [
        {'id': 'hongguo', 'title': '红果短剧（新名字）', 'capabilities': ['browse']}]}

    def handler(request):
        return httpx.Response(200, json=renamed)

    monkeypatch.setattr(dramas, '_transport', httpx.MockTransport(handler))
    prov = client_a.get('/api/drama-sources?refresh=1', headers=HEADERS)\
        .json()['services'][0]['providers'][0]
    assert prov['name'] == '红果' and prov['title'] == '红果短剧（新名字）'


# ── 详情形态：电影单直链 / 多线路 ───────────────────────────────────────
def test_movie_with_only_top_level_url_is_playable(client_a, monkeypatch):
    """movie 详情只有顶层 videoUrl，以前会被当成「没有可播的剧集」直接 404。"""
    def handler(request):
        if request.url.path == '/api/v1/providers':
            return httpx.Response(200, json=PROVIDERS)
        if '/items/' in request.url.path:
            return httpx.Response(200, json={'title': '某部电影', 'mediaType': 'movie',
                                             'videoUrl': 'http://u/api/v1/stream/m1'})
        return httpx.Response(200, json={'items': []})

    monkeypatch.setattr(dramas, '_transport', httpx.MockTransport(handler))
    r = client_a.get(f'{BASE}/{ITEM_ID}', headers=HEADERS)
    assert r.status_code == 200, r.text
    assert [e['n'] for e in r.json()['episodes']] == [1]
    assert r.json()['mediaType'] == 'movie'


def test_play_sources_are_understood(client_a, monkeypatch):
    def handler(request):
        if request.url.path == '/api/v1/providers':
            return httpx.Response(200, json=PROVIDERS)
        if '/items/' in request.url.path:
            return httpx.Response(200, json={'title': '多线路', 'mediaType': 'tv', 'episodes': [
                {'episodeNumber': 1, 'playSources': [
                    {'videoUrl': 'http://v/a.m3u8'},
                    {'videoUrl': 'http://v/b.m3u8', 'isDefault': True}]}]})
        return httpx.Response(200, json={'items': []})

    monkeypatch.setattr(dramas, '_transport', httpx.MockTransport(handler))
    r = client_a.get(f'{BASE}/{ITEM_ID}', headers=HEADERS)
    assert r.status_code == 200, r.text
    assert [e['n'] for e in r.json()['episodes']] == [1]


# ── 体检报告 ────────────────────────────────────────────────────────────
def test_diagnostics_without_probe_only_reports_清单(client_a, upstream):
    r = client_a.get('/api/drama-sources/diagnostics', headers=HEADERS)
    assert r.status_code == 200, r.text
    svc = r.json()['services'][0]
    assert svc['online'] is True
    assert [p['id'] for p in svc['providers']] == ['hongguo', 'huangju']
    assert 'browse' not in svc['providers'][0]        # 没 probe 就不去打上游


def test_diagnostics_with_probe_checks_playability(client_a, upstream):
    r = client_a.get('/api/drama-sources/diagnostics?probe=1', headers=HEADERS)
    assert r.status_code == 200, r.text
    row = [p for p in r.json()['services'][0]['providers'] if p['id'] == 'hongguo'][0]
    assert row['browse'] == 'ok'
    assert row['playable'] is True
    assert row['episodes'] == 2
    assert row['ok'] is True


def test_diagnostics_requires_login():
    from fastapi.testclient import TestClient
    with TestClient(app, base_url='https://testserver', headers=HEADERS) as anon:
        assert anon.get('/api/drama-sources/diagnostics').status_code == 401
        assert anon.put('/api/drama-sources/overlay', json={'key': 'capy:hongguo'}).status_code == 401
