"""2.4.3 年报口径两处补齐（A3 对齐 + 天心情取数）。

- album_only 对齐：/api/yearbook 与 /api/on-this-day 同规则——传照片专属
  动态（post 且 body.album_only=true）不进 total/photos/by_kind（列表层
  GET /api/records 已过滤，但年报直查库必须显式跳过，不许把专属照片捞回
  任何新呈现）。
- mood_days：四格「天心情」= 今年有 mood 记录的去重天数。App 端 records
  列表拉取有 limit=1000 截断、无法证明拉全，口径单一事实源放服务端算
  （在既有归年循环里收集，与 active_days 同族）。
"""
import io

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.main import connect

HEADERS = {'X-Love-Space': '1'}


@pytest.fixture(autouse=True)
def _isolate_upload_rate_limit():
    """带真实上传的用例前后清 upload 限流计数（与 test_album_only 同因：
    计数存 auth_attempts 表按 client_ip 共享，不外溢给后续测试）。"""
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


def test_yearbook_excludes_album_only_from_stats(client_a):
    """传照片专属动态不进年报 total/photos/by_kind；普通动态照常计数。"""
    before = client_a.get('/api/yearbook').json()

    # 专属照片动态：一张图 + album_only 标记（无 date，按 created 兜底归年）
    r = client_a.post('/api/records', json={
        'kind': 'post',
        'body': {'media': [upload(client_a)], 'album_only': True}})
    assert r.status_code == 200, r.text
    # 普通动态：两张图（对照组：photos 应 +2）
    r = client_a.post('/api/records', json={
        'kind': 'post',
        'body': {'media': [upload(client_a), upload(client_a, 'b.png')],
                 'content': '普通动态'}})
    assert r.status_code == 200, r.text

    after = client_a.get('/api/yearbook').json()
    assert after['total'] == before['total'] + 1, (before['total'], after['total'])
    assert after['photos'] == before['photos'] + 2, (before['photos'], after['photos'])
    assert after['by_kind'].get('post', 0) == before['by_kind'].get('post', 0) + 1


def test_yearbook_mood_days_is_dedup_days(client_a):
    """mood_days = 今年有 mood 记录的去重天数（不是条数）：同一天两条
    只算 1 天，另一天再一条 → mood_days=2 且 moods=3。"""
    import datetime as dt
    today = dt.date.today().isoformat()
    yesterday = (dt.date.today() - dt.timedelta(days=1)).isoformat()
    for day, emoji in ((today, '😊'), (today, '🥰'), (yesterday, '🌤')):
        r = client_a.post('/api/records', json={
            'kind': 'mood', 'body': {'emoji': emoji, 'date': day}})
        assert r.status_code == 200, r.text
    data = client_a.get('/api/yearbook').json()
    assert data['mood_days'] == 2, data['mood_days']
    assert data['moods'] == 3, data['moods']
