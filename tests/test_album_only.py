"""传照片专属动态标记 album_only（2.4.2）。

诉求：抽屉「传照片」上传的照片只进相册，绝不出现在时光（App 与 Web 都不出现）。
- clean_body 给 kind=post 白名单新增可选布尔 album_only（body 内显式标记，
  禁止用"正文为空"等特征猜测）；只有传照片 sheet 创建的记录带 true。
- GET /api/records（动态列表/搜索唯一收口）默认排除 album_only=true 的 post；
  回收站（trash=true）不过滤，删除/恢复链路照常。
- 明确保留面：/api/photos（含 ?album=）、GET /api/records/{id} 详情、
  /api/export 导出、月历之外的呈现链路照常；月历 /api/calendar、
  /api/on-this-day、/api/weekly（by_kind 计数与本周精选）不呈现。
- 编辑兜底：PUT 以原始 body 为底只盖改动键时未显式带标记 → 保留原标记，
  防止半截 body 的 PUT 把标记洗掉。
"""
import io

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.main import app, connect

HEADERS = {'X-Love-Space': '1'}


@pytest.fixture(autouse=True)
def _isolate_upload_rate_limit():
    """本模块每条用例都会真上传媒体（验证 /api/photos 与保留面需要真实媒体），
    upload 限流（30/300s）计数存在 auth_attempts 表且按 client_ip 共享——
    每条用例前后清掉 upload 计数，既保证自身不受前面测试挤兑，也不把
    已耗计数外溢给后面的测试（此前全量里把 pose_ai/security 的上传顶到 429）。"""
    from fastapi.testclient import TestClient as _T  # noqa: F401
    with connect() as c:
        c.execute("DELETE FROM auth_attempts WHERE key LIKE 'upload:%'")
    yield
    with connect() as c:
        c.execute("DELETE FROM auth_attempts WHERE key LIKE 'upload:%'")


def png(color=(200, 150, 180)):
    buf = io.BytesIO()
    Image.new('RGB', (24, 24), color).save(buf, 'PNG')
    return buf.getvalue()


def upload(client, name='a.png'):
    r = client.post('/api/media', headers=HEADERS, files={'file': (name, png(), 'image/png')})
    assert r.status_code == 200, r.text
    return r.json()['id']


# ── (a) 创建与详情 ────────────────────────────────────────────────────

def test_album_only_post_created_and_detail_readable(client_a):
    """(a) POST 一条带 album_only 的 post 成功且详情可读。"""
    r = client_a.post('/api/records', json={
        'kind': 'post', 'client_id': 'cid-album-only-1',
        'body': {'media': [upload(client_a)], 'album_only': True}})
    assert r.status_code == 200, r.text
    rid = r.json()['id']
    assert r.json()['body'].get('album_only') is True
    detail = client_a.get(f'/api/records/{rid}', headers=HEADERS)
    assert detail.status_code == 200
    assert detail.json()['body']['album_only'] is True


def test_album_only_rejects_non_bool(client_a):
    r = client_a.post('/api/records', json={
        'kind': 'post', 'body': {'content': 'x', 'album_only': 'yes'}})
    assert r.status_code == 422


def test_normal_post_has_no_flag(client_a):
    """正常发动态（哪怕纯图无字）绝不带标记：服务端不做任何自动打标。"""
    r = client_a.post('/api/records', json={
        'kind': 'post', 'client_id': 'cid-normal-img-1',
        'body': {'media': [upload(client_a, 'b.png')]}})
    assert r.status_code == 200
    assert 'album_only' not in r.json()['body']


# ── (b) 列表收口过滤（App 时光与 Web 时光的真实查询参数） ────────────

def _create_album_only(client_a, client_id='cid-album-only-list'):
    mid = upload(client_a, 'list.png')
    r = client_a.post('/api/records', json={
        'kind': 'post', 'client_id': client_id,
        'body': {'media': [mid], 'album_only': True}})
    assert r.status_code == 200
    return r.json()['id']


def test_timeline_queries_hide_album_only(client_a):
    """(b) App 时光（kind=post&limit=61）与 Web 首屏聚合（kind=...&exclude=chat
    &limit=1000）都查不到 album_only 记录；搜索 q= 同样查不到。"""
    rid = _create_album_only(client_a)
    # App 时光真实参数（buildTimelineQuery）
    app_query = client_a.get('/api/records', headers=HEADERS,
                             params={'kind': 'post', 'limit': 61})
    assert all(item['id'] != rid for item in app_query.json())
    # Web 时光真实参数（loadTimeline）
    web_query = client_a.get('/api/records', headers=HEADERS,
                             params={'kind': 'post', 'limit': '61'})
    assert all(item['id'] != rid for item in web_query.json())
    # Web 首屏聚合（app.js:270 全 kinds）
    agg = client_a.get('/api/records', headers=HEADERS,
                       params={'kind': 'post,album,anniversary,wish,habit,question,music,mood,note,ledger,quest',
                               'exclude': 'chat', 'limit': 1000})
    assert all(item['id'] != rid for item in agg.json())
    # 站内搜索（q 参数走同一收口）
    q = client_a.get('/api/records', headers=HEADERS, params={'kind': 'post', 'q': 'x'})
    assert all(item['id'] != rid for item in q.json())


def test_normal_image_post_still_listed(client_a):
    """(d) 不带标记的普通纯图 post 仍正常出现在列表。"""
    r = client_a.post('/api/records', json={
        'kind': 'post', 'client_id': 'cid-normal-img-2',
        'body': {'media': [upload(client_a, 'c.png')]}})
    rid = r.json()['id']
    listing = client_a.get('/api/records', headers=HEADERS,
                           params={'kind': 'post', 'limit': 61})
    assert any(item['id'] == rid for item in listing.json())


# ── (c) 相册与照片保留面 ─────────────────────────────────────────────

def test_photos_and_album_keep_album_only(client_a):
    """(c) /api/photos（含 ?album=）照常返回；相册页数据源不受影响。"""
    # 建相册
    album = client_a.post('/api/records', json={
        'kind': 'album', 'body': {'title': '验证相册'}}).json()
    aid = album['id']
    mid = upload(client_a, 'album.png')
    r = client_a.post('/api/records', json={
        'kind': 'post', 'client_id': 'cid-album-only-photo',
        'body': {'media': [mid], 'album': aid, 'album_only': True}})
    assert r.status_code == 200
    rid = r.json()['id']
    # /api/photos?album= 查到它的照片
    photos = client_a.get('/api/photos', headers=HEADERS, params={'album': aid}).json()
    assert any(p['record_id'] == rid for p in photos)
    # 相册对象本身（GET /api/records/{id}）也在
    assert client_a.get(f'/api/records/{aid}', headers=HEADERS).status_code == 200


def test_detail_and_trash_and_export_keep(client_a):
    """保留面：详情可读；回收站可见（删除/恢复链路）；导出包含记录与媒体。"""
    rid = _create_album_only(client_a, 'cid-album-only-keep')
    assert client_a.get(f'/api/records/{rid}', headers=HEADERS).status_code == 200
    # 删除 → 回收站可见（trash 列表不过滤）→ 恢复后详情仍在
    assert client_a.delete(f'/api/records/{rid}', headers=HEADERS).status_code in (200, 204)
    trash = client_a.get('/api/records', headers=HEADERS,
                         params={'trash': 'true', 'kind': 'post'})
    assert any(item['id'] == rid for item in trash.json())
    assert client_a.post(f'/api/records/{rid}/restore', headers=HEADERS).status_code == 200
    assert client_a.get(f'/api/records/{rid}', headers=HEADERS).status_code == 200
    # 导出包含该记录（/api/export 是 zip 包，解开 records.json 检查）
    export = client_a.get('/api/export', headers=HEADERS)
    assert export.status_code == 200
    import zipfile
    with zipfile.ZipFile(io.BytesIO(export.content)) as zf:
        names = [n for n in zf.namelist() if n.endswith('records.json')]
        assert names, zf.namelist()
        assert rid in zf.read(names[0]).decode('utf-8', 'ignore')


def test_hidden_from_calendar_on_this_day_weekly(client_a):
    """月历 /api/calendar、历史上的今天、周报（by_kind 与本周精选）不呈现。"""
    rid = _create_album_only(client_a, 'cid-album-only-agg')
    cal = client_a.get('/api/calendar', headers=HEADERS).json()
    for day in cal.get('days', {}).values():
        assert all(p['id'] != rid for p in day.get('posts', []))
    otd = client_a.get('/api/on-this-day', headers=HEADERS).json()
    for group in otd:
        assert all(item['id'] != rid for item in group['items'])
    weekly = client_a.get('/api/weekly', headers=HEADERS).json()
    assert all(item['id'] != rid for item in weekly.get('highlights', []))


def test_edit_preserves_flag_without_explicit_key(client_a):
    """编辑兜底：PUT 不显式带标记（半截 body）→ 保留 album_only=true。"""
    rid = _create_album_only(client_a, 'cid-album-only-edit')
    # App 编辑范式：原始 body 为底只盖改动键——这里模拟未带 album_only
    r = client_a.put(f'/api/records/{rid}', headers=HEADERS,
                     json={'kind': 'post', 'body': {'content': '补一句'}})
    assert r.status_code == 200, r.text
    assert r.json()['body']['album_only'] is True
    # 显式取消标记（罕见但合法）：恢复为普通动态
    r2 = client_a.put(f'/api/records/{rid}', headers=HEADERS,
                      json={'kind': 'post', 'body': {'content': '补一句', 'album_only': False}})
    assert r2.status_code == 200
    assert r2.json()['body'].get('album_only') is not True
    listing = client_a.get('/api/records', headers=HEADERS, params={'kind': 'post', 'limit': 61})
    assert any(item['id'] == rid for item in listing.json())
