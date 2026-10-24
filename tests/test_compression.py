"""gzip 压缩的边界。

两个不能错的地方：
- 大响应（app.js/style.css/JSON）要真的被压；
- SSE（/api/events）和媒体流（/media/、导出 zip）必须原样直出——SSE 被 gzip 会
  攒帧，视频被 gzip 就没法 Range 拖进度条。

这里直接对着 ASGI 层测中间件，不去跑真接口：SSE 是真无限流，走 TestClient 会挂住。
"""
import asyncio

from app.main import SelectiveGZip


async def _echo(scope, receive, send):
    await send({'type': 'http.response.start', 'status': 200,
                'headers': [(b'content-type', b'application/json')]})
    await send({'type': 'http.response.body', 'body': b'{"x":"' + b'a' * 4096 + b'"}'})


def _call(path, accept='gzip'):
    messages = []

    async def send(message):
        messages.append(message)

    middleware = SelectiveGZip(_echo, minimum_size=1024)
    scope = {'type': 'http', 'http_version': '1.1', 'method': 'GET', 'path': path,
             'raw_path': path.encode(), 'query_string': b'', 'scheme': 'https',
             'headers': [(b'accept-encoding', accept.encode())]}
    asyncio.run(middleware(scope, None, send))
    return messages


def _encoded(messages):
    start = messages[0]
    for key, value in start['headers']:
        if key.lower() == b'content-encoding':
            return value.decode()
    return None


def test_compresses_normal_response():
    assert _encoded(_call('/api/records')) == 'gzip'


def test_skips_sse():
    assert _encoded(_call('/api/events')) is None


def test_skips_media_and_export():
    assert _encoded(_call('/media/2026/10/abc.mp4')) is None
    assert _encoded(_call('/api/export')) is None


def test_respects_accept_encoding():
    assert _encoded(_call('/api/records', accept='identity')) is None
