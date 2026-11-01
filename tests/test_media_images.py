"""选图面板的图片清单（/api/media/images）。

诉求来源：首页封面和聊天背景都要能「从相册里挑一张」。相册页只列记录引用过的照片，
聊天里发过/当过头像/合成台出的图都不在里面，所以这个端点直接扫 media 表。
护栏就一条：只能看见自己有权看的图 —— 另一半私密日记里的照片不能漏出来。
"""
import io

from fastapi.testclient import TestClient
from PIL import Image

from app.main import app

HEADERS = {'X-Love-Space': '1'}


def png(color=(200, 150, 180)):
    buf = io.BytesIO()
    Image.new('RGB', (24, 24), color).save(buf, 'PNG')
    return buf.getvalue()


def upload(client, name='a.png'):
    r = client.post('/api/media', headers=HEADERS, files={'file': (name, png(), 'image/png')})
    assert r.status_code == 200, r.text
    return r.json()['id']


def test_requires_login():
    with TestClient(app, base_url='https://testserver') as anon:
        assert anon.get('/api/media/images').status_code == 401


def test_lists_my_uploads_newest_first(client_a):
    first = upload(client_a, 'one.png')
    second = upload(client_a, 'two.png')
    ids = [m['id'] for m in client_a.get('/api/media/images', headers=HEADERS).json()]
    assert second in ids and first in ids
    assert ids.index(second) < ids.index(first), '最近上传的应该排在前面'


def test_limit_is_clamped_not_rejected(client_a):
    assert client_a.get('/api/media/images?limit=0', headers=HEADERS).status_code == 200
    assert client_a.get('/api/media/images?limit=99999', headers=HEADERS).status_code == 200
    assert len(client_a.get('/api/media/images?limit=1', headers=HEADERS).json()) <= 1


def test_partner_private_photo_is_not_listed(client_a, client_b):
    """另一半传进私密日记的图不该出现在我的选图面板里。"""
    mid = upload(client_b, 'private.png')
    r = client_b.post('/api/records', headers=HEADERS,
                      json={'kind': 'diary', 'body': {'content': '只给我自己看', 'date': '2026-11-01',
                                                      'media': [mid]}})
    assert r.status_code == 200, r.text
    mine = [m['id'] for m in client_a.get('/api/media/images', headers=HEADERS).json()]
    assert mid not in mine
    # 自己传的当然在
    assert upload(client_a, 'mine.png') in [m['id'] for m in
                                            client_a.get('/api/media/images', headers=HEADERS).json()]
