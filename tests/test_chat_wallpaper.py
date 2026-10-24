"""聊天壁纸：预设、照片壁纸的权限与"旧客户端不能抹掉壁纸"的兼容性。

背景：`PUT /api/space` 是整体替换（body 里的字段直接覆盖库里那份 JSON）。
新增壁纸字段后，旧版前端/旧 APK 保存空间设置时不带 chat_bg，如果按"缺省即空"
处理，对方刚设好的壁纸就会被无声清掉。所以字段用 None 表示"没带"，服务端沿用原值——
下面 test_legacy_client_keeps_wallpaper 就是钉这条。
"""
import io

from PIL import Image

HEADERS = {'X-Love-Space': '1'}


def png_bytes(color=(180, 120, 200)):
    buf = io.BytesIO()
    Image.new('RGB', (48, 48), color).save(buf, 'PNG')
    return buf.getvalue()


def post_media(client, filename='bg.png'):
    return client.post('/api/media', headers=HEADERS,
                       files={'file': (filename, png_bytes(), 'image/png')})


def space_of(client):
    return client.get('/api/me', headers=HEADERS).json()['space']


def save_space(client, **patch):
    return client.put('/api/space', headers=HEADERS, json={**space_of(client), **patch})


def test_defaults_have_no_wallpaper(client_a):
    space = space_of(client_a)
    assert space.get('chat_bg') == ''
    assert space.get('chat_bg_media') == ''
    assert space.get('chat_bg_dim') == 35


def test_set_preset_wallpaper(client_a):
    r = save_space(client_a, chat_bg='sakura', chat_bg_dim=20)
    assert r.status_code == 200, r.text
    space = space_of(client_a)
    assert space['chat_bg'] == 'sakura'
    assert space['chat_bg_dim'] == 20
    assert space['chat_bg_media'] == ''
    # 复原，避免影响其它用例对空间设置的假设
    assert save_space(client_a, chat_bg='').status_code == 200


def test_rejects_unknown_preset_and_out_of_range_dim(client_a):
    assert save_space(client_a, chat_bg='../../etc/passwd').status_code == 422
    assert save_space(client_a, chat_bg='sakura', chat_bg_dim=999).status_code == 422
    assert save_space(client_a, chat_bg='sakura', chat_bg_dim=-1).status_code == 422


def test_photo_wallpaper_requires_a_photo(client_a):
    r = save_space(client_a, chat_bg='photo', chat_bg_media='')
    assert r.status_code == 422
    assert '照片' in r.json()['detail']


def test_photo_wallpaper_visible_to_both(client_a, client_b):
    mid = post_media(client_a, 'wallpaper.png').json()['id']
    r = save_space(client_a, chat_bg='photo', chat_bg_media=mid, chat_bg_dim=40)
    assert r.status_code == 200, r.text
    # 壁纸是空间级设置，另一半必须能取到这张图（新增的 media_visible 分支）
    assert client_a.get(f'/media/{mid}').status_code == 200
    assert client_b.get(f'/media/{mid}').status_code == 200
    assert client_b.get('/api/me', headers=HEADERS).json()['space']['chat_bg_media'] == mid


def test_switch_back_to_preset_clears_photo(client_a):
    mid = post_media(client_a, 'wallpaper2.png').json()['id']
    assert save_space(client_a, chat_bg='photo', chat_bg_media=mid).status_code == 200
    assert save_space(client_a, chat_bg='night').status_code == 200
    space = space_of(client_a)
    assert space['chat_bg'] == 'night'
    # 切回预设必须清掉照片引用，否则这张图会一直被判定为"在用"，永远清不掉
    assert space['chat_bg_media'] == ''


def test_legacy_client_keeps_wallpaper(client_a):
    """旧客户端（请求体里没有 chat_bg 字段）保存空间设置，不能把壁纸抹掉。"""
    mid = post_media(client_a, 'wallpaper3.png').json()['id']
    assert save_space(client_a, chat_bg='photo', chat_bg_media=mid, chat_bg_dim=55).status_code == 200

    legacy = {k: v for k, v in space_of(client_a).items()
              if k not in ('chat_bg', 'chat_bg_media', 'chat_bg_dim')}
    legacy['name'] = '改了个名字'
    r = client_a.put('/api/space', headers=HEADERS, json=legacy)
    assert r.status_code == 200, r.text

    space = space_of(client_a)
    assert space['name'] == '改了个名字'
    assert space['chat_bg'] == 'photo'
    assert space['chat_bg_media'] == mid
    assert space['chat_bg_dim'] == 55
