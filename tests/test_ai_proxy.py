"""AI 合成台同源转发（/api/proxy）的边界测试。

内置图库前端默认 useProxy=true，把出图请求发到同源 /api/proxy 并用 x-target-url
头带真实地址；这个端点既不能被当成开放代理（SSRF），也不能把同一套 CSRF 头校验
强加给那份第三方前端。下面几条守的就是这三点。
"""
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app import main
from app.main import _ai_proxy_target, app

TARGET = 'https://ark.cn-beijing.volces.com/api/v3/images/generations'


def _fake_dns(*a, **kw):
    """把任意域名解析成一个公网 IPv4，避免测试依赖真实 DNS。"""
    return [(2, 1, 6, '', ('93.184.216.34', 443))]


def test_missing_target_is_rejected():
    with pytest.raises(HTTPException) as exc:
        _ai_proxy_target('')
    assert exc.value.status_code == 400


def test_non_http_scheme_is_rejected():
    with pytest.raises(HTTPException) as exc:
        _ai_proxy_target('file:///etc/passwd')
    assert exc.value.status_code == 400


def test_private_target_is_rejected():
    # 内网/回环一律拒绝，否则登录用户可以把本服务当跳板打内网（SSRF）
    for url in ('http://127.0.0.1:8188/prompt', 'http://192.168.31.95:1314/api/status',
                'http://[::1]/', 'http://169.254.169.254/latest/meta-data/'):
        with pytest.raises(HTTPException) as exc:
            _ai_proxy_target(url)
        assert exc.value.status_code == 403


def test_public_target_passes(monkeypatch):
    monkeypatch.setattr(main.socket, 'getaddrinfo', _fake_dns)
    assert _ai_proxy_target(TARGET) == TARGET


def test_proxy_requires_login():
    # 不带会话 Cookie：鉴权先拦住，不该真的出网
    with TestClient(app, base_url='https://testserver') as anon:
        r = anon.post('/api/proxy', headers={'x-target-url': TARGET}, json={'model': 'x'})
    assert r.status_code == 401


def test_proxy_does_not_need_csrf_header(client_a):
    # 图库里的第三方前端不会带 X-Love-Space，仍要能进来（被内网校验挡在 403 而不是头校验）
    r = client_a.post('/api/proxy', headers={'x-target-url': 'http://127.0.0.1:8188/prompt'},
                      json={'model': 'x'})
    assert r.status_code == 403
    assert '内网' in r.text


def test_other_posts_still_require_csrf_header(client_a):
    # 豁免必须只对 /api/proxy 生效
    r = client_a.post('/api/proxy-x', json={})
    assert r.status_code in (403, 404)
    r2 = client_a.put('/api/space', json={'name': '家'})
    assert r2.status_code == 200  # 带默认头的客户端照常可用
    with TestClient(app, base_url='https://testserver') as anon:
        r3 = anon.put('/api/space', cookies=client_a.cookies, json={'name': '家'})
    assert r3.status_code == 403


def test_proxy_forwards_and_returns_upstream(client_a, monkeypatch):
    monkeypatch.setattr(main.socket, 'getaddrinfo', _fake_dns)
    seen = {}

    class _Resp:
        status_code = 200
        headers = {'content-type': 'application/json; charset=utf-8'}
        content = b'{"data":[{"b64_json":"AAA"}]}'

    class _Client:
        def __init__(self, *a, **kw):
            seen['kwargs'] = kw

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

        async def post(self, url, content=None, headers=None):
            seen.update(url=url, content=content, headers=headers or {})
            return _Resp()

    monkeypatch.setattr(main.httpx, 'AsyncClient', _Client)
    payload = {'model': 'doubao-seedream-5-0-260128', 'prompt': '换装'}
    r = client_a.post('/api/proxy', headers={'x-target-url': TARGET,
                                             'authorization': 'Bearer ark-test'},
                      json=payload)
    assert r.status_code == 200
    assert r.json()['data'][0]['b64_json'] == 'AAA'
    assert seen['url'] == TARGET
    # Key 由浏览器带来、服务端只做透传，不落库
    assert seen['headers']['authorization'] == 'Bearer ark-test'
    assert b'doubao-seedream' in seen['content']
    # 不允许跟上游重定向到内网，也不读宿主机的 http_proxy
    assert seen['kwargs']['follow_redirects'] is False
    assert seen['kwargs']['trust_env'] is False
