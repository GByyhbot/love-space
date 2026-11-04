"""首页封面构图（cover_pos）：范围夹紧 + 旧客户端不抹掉主人已经调好的构图。

背景：首页那张 hero 卡的背景是「原图 + 三个参数（x/y 百分比、z 缩放）」渲染出来的，
不预先把图裁死。所以这三个数必须永远合法——坏一个就把首页打成空白或糊成一片。
服务端只夹紧、不报错：旧版 APK 传了怪值也让它保存成功，图照样能显示。
"""
HEADERS = {'X-Love-Space': '1'}


def space_of(client):
    return client.get('/api/me', headers=HEADERS).json()['space']


def save_space(client, **patch):
    return client.put('/api/space', headers=HEADERS, json={**space_of(client), **patch})


def test_default_cover_pos_is_absent_or_centered(client_a):
    pos = space_of(client_a).get('cover_pos')
    # 建空间时还没保存过空间设置，库里可能没有这个键；有就必须是正中的默认值
    assert pos in (None, {}) or pos == {'x': 50.0, 'y': 50.0, 'z': 1.0}


def test_roundtrip(client_a):
    r = save_space(client_a, cover_pos={'x': 12.5, 'y': 80, 'z': 2.4})
    assert r.status_code == 200, r.text
    pos = space_of(client_a)['cover_pos']
    assert pos == {'x': 12.5, 'y': 80.0, 'z': 2.4}
    assert save_space(client_a, cover_pos={'x': 50, 'y': 50, 'z': 1}).status_code == 200


def test_out_of_range_is_clamped_not_rejected(client_a):
    assert save_space(client_a, cover_pos={'x': -50, 'y': 999, 'z': 99}).status_code == 200
    pos = space_of(client_a)['cover_pos']
    assert pos == {'x': 0.0, 'y': 100.0, 'z': 3.0}
    # 往反方向越界也一样，别只夹一头
    assert save_space(client_a, cover_pos={'x': 1e9, 'y': -1e9, 'z': 0}).status_code == 200
    assert space_of(client_a)['cover_pos'] == {'x': 100.0, 'y': 0.0, 'z': 1.0}


def test_garbage_falls_back_to_center(client_a):
    assert save_space(client_a, cover_pos={'x': 'abc', 'y': None, 'z': []}).status_code == 200
    assert space_of(client_a)['cover_pos'] == {'x': 50.0, 'y': 50.0, 'z': 1.0}
    # 根本不是对象：由 pydantic 直接挡掉（422），但也绝不能 500
    assert save_space(client_a, cover_pos=[1, 2, 3]).status_code == 422
    assert space_of(client_a)['cover_pos'] == {'x': 50.0, 'y': 50.0, 'z': 1.0}


def test_legacy_client_without_field_keeps_crop(client_a):
    """旧版前端/旧 APK 保存空间设置时不带 cover_pos，不能把构图清回正中。"""
    assert save_space(client_a, cover_pos={'x': 30, 'y': 70, 'z': 1.8}).status_code == 200
    r = client_a.put('/api/space', headers=HEADERS, json={'name': '家'})
    assert r.status_code == 200, r.text
    assert space_of(client_a)['cover_pos'] == {'x': 30.0, 'y': 70.0, 'z': 1.8}
    assert save_space(client_a, cover_pos={'x': 50, 'y': 50, 'z': 1}).status_code == 200


def png_bytes(color=(180, 120, 200)):
    import io
    from PIL import Image
    buf = io.BytesIO()
    Image.new('RGB', (48, 48), color).save(buf, 'PNG')
    return buf.getvalue()


def test_media_is_cacheable_but_never_shared(client_a):
    """附件要能被缓存，但只能是 private 且立刻过期。

    Cache API 的 put() 会直接拒绝 Cache-Control: no-store 的响应——首页封面那条
    cache-first 之所以能生效，全靠服务端放行成 private。
    普通相册/聊天附件以前是 no-store，结果每重绘一次聊天就把整屏图重下一遍；
    现在统一成 private, max-age=0, must-revalidate：存得下、每次靠 ETag 换 304，
    既省流量又不会给共享缓存留副本、也不会在设备上长期躺一份。
    """
    r = client_a.post('/api/media', headers=HEADERS,
                      files={'file': ('cover.png', png_bytes(), 'image/png')})
    mid = r.json()['id']
    assert save_space(client_a, cover=mid).status_code == 200

    cover = client_a.get(f'/media/{mid}?preview=true&role=cover', headers=HEADERS)
    assert cover.status_code == 200, cover.text
    cc = cover.headers.get('cache-control', '')
    assert 'no-store' not in cc, f'封面一旦 no-store，SW 就永远存不进缓存：{cc}'
    assert 'private' in cc, f'封面是私密照片，绝不能进共享缓存：{cc}'

    plain = client_a.get(f'/media/{mid}?preview=true', headers=HEADERS)
    assert plain.status_code == 200
    plain_cc = plain.headers.get('cache-control', '')
    assert 'no-store' not in plain_cc, f'普通附件也不能 no-store，否则每次重绘都重下整屏图：{plain_cc}'
    assert 'private' in plain_cc, f'两个人的照片绝不能进共享缓存：{plain_cc}'
    assert 'max-age=0' in plain_cc, f'不能给长期副本，必须每次校验：{plain_cc}'
