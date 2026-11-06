"""缓存头的分级策略。

这套策略不是随手写的，每条都对应一个曾经踩过的坑：

- 外壳 index.html 必须 no-store：Android WebView 会对没有 Cache-Control 的 HTML
  做"启发式缓存"，结果发版后连着几天还是老外壳+老 ?v=。
- 带 ?v= 的 js/css 可以一年 immutable：URL 即内容，换版必换 v。这个前提由
  test_version_consistency.py 保证（index.html 的 ?v= 必须等于 sw.js VERSION），
  所以"忘了升版本导致永久钉死旧文件"不会发生。
- 裸 /static/app.js（没带 v）不许长缓存：这是绕过版本号的口子，一旦缓存住了
  下次发版用户还是旧逻辑。
- sw.js 无论带不带 v 都 no-cache：它是版本入口，必须每次回源。
- APK 例外：?v= 走的是 APK_VERSION，但 3.5MB 下载物同版本重打包是可能的，
  不能用 immutable。
- /api/ 一律 no-store：两个人的私有数据，不能进任何缓存。
- /media/ 相反：必须「可存 + 每次校验」。no-store 会让浏览器连存都不存，
  于是每次重绘聊天都把整屏图片重新下载一遍；改成 must-revalidate 后靠 ETag
  换 304，响应体从几 MB 降到几百字节。
"""
import base64

import pytest

from tests.conftest import HEADERS

LONG = 'public, max-age=31536000, immutable'
REVALIDATE = 'private, max-age=0, must-revalidate'

# 1x1 透明 PNG：够小，也不依赖 PIL
TINY_PNG = base64.b64decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
    'hQGAhKmMIQAAAABJRU5ErkJggg==')


def _cc(client, url):
    return client.head(url, headers=HEADERS).headers.get('cache-control')


@pytest.mark.parametrize('url', [
    '/static/app.js?v=999',
    '/static/style.css?v=999',
    '/static/music.js?v=999',
])
def test_versioned_static_is_immutable(client_a, url):
    assert _cc(client_a, url) == LONG


def test_sw_is_always_revalidated(client_a):
    # 带 v 和不带 v 都必须回源，否则新外壳会配到旧 SW
    assert _cc(client_a, '/static/sw.js') == 'no-cache'
    assert _cc(client_a, '/static/sw.js?v=999') == 'no-cache'


def test_apk_not_pinned_forever(client_a):
    # 同版本号重打包时 URL 不变，immutable 会把旧包钉死
    assert _cc(client_a, '/static/lovespace.apk?v=1.7.0') == 'no-cache'


def test_unversioned_static_not_cached_long(client_a):
    header = _cc(client_a, '/static/app.js')
    assert header != LONG


def test_shell_is_no_store(client_a):
    assert _cc(client_a, '/') == 'no-store'


def test_private_data_is_no_store(client_a):
    assert _cc(client_a, '/api/status') == 'no-store'
    assert _cc(client_a, '/api/records') == 'no-store'


def test_media_is_revalidatable_not_no_store(client_a):
    """附件不能 no-store：否则浏览器无法发条件请求，重绘一次聊天就重下全部图片。"""
    mid = client_a.post('/api/media', headers=HEADERS,
                        files={'file': ('c.png', TINY_PNG, 'image/png')}).json()['id']
    r = client_a.get(f'/media/{mid}', headers=HEADERS)
    assert r.status_code == 200
    assert r.headers['cache-control'] == REVALIDATE
    assert r.headers.get('etag'), 'FileResponse 应该带 ETag，否则换不到 304'


def test_media_returns_304_on_etag_match(client_a):
    """带 If-None-Match 回来必须 304 —— 这是「不重下原图」的全部收益所在。"""
    mid = client_a.post('/api/media', headers=HEADERS,
                        files={'file': ('d.png', TINY_PNG, 'image/png')}).json()['id']
    first = client_a.get(f'/media/{mid}', headers=HEADERS)
    etag = first.headers['etag']
    second = client_a.get(f'/media/{mid}', headers={**HEADERS, 'If-None-Match': etag})
    assert second.status_code == 304
    assert not second.content, '304 不能带响应体'
