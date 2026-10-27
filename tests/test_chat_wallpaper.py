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


# ── 每人一份的聊天背景：各看各的，但谁都能替对方设 ──


def user_id(client):
    return client.get('/api/me', headers=HEADERS).json()['user']['id']


def save_bg(client, target, **patch):
    return client.put('/api/space', headers=HEADERS,
                      json={**space_of(client), 'chat_bg_target': target, **patch})


def bg_of(client, uid):
    return space_of(client).get('chat_bg_users', {}).get(uid, {})


def reset_bg(client):
    """空间设置是两个人共用的一份 JSON，前面的用例会留下状态——
    个人背景这组用例必须先归零，否则断言就变成了"依赖执行顺序"。"""
    space = space_of(client)
    space.update({'chat_bg': '', 'chat_bg_media': '', 'chat_bg_dim': 35, 'chat_bg_users': {}})
    r = client.put('/api/space', headers=HEADERS, json=space)
    assert r.status_code == 200, r.text


def test_each_side_has_its_own_background(client_a, client_b):
    reset_bg(client_a)
    a, b = user_id(client_a), user_id(client_b)
    mid_a = post_media(client_a, 'mine.png').json()['id']
    mid_b = post_media(client_b, 'hers.png').json()['id']
    assert save_bg(client_a, a, chat_bg='photo', chat_bg_media=mid_a, chat_bg_dim=20).status_code == 200
    assert save_bg(client_b, b, chat_bg='photo', chat_bg_media=mid_b, chat_bg_dim=60).status_code == 200
    # 各自的条目互不干扰
    assert bg_of(client_a, a) == {'bg': 'photo', 'media': mid_a, 'dim': 20}
    assert bg_of(client_a, b) == {'bg': 'photo', 'media': mid_b, 'dim': 60}
    # 个人设置不该动到共同默认值（否则两个人会互相顶掉对方的默认）
    assert space_of(client_a)['chat_bg'] == ''


def test_partner_can_set_background_for_the_other(client_a, client_b):
    reset_bg(client_a)
    """我替她换一张：她那边就变成我选的图。"""
    a, b = user_id(client_a), user_id(client_b)
    mid = post_media(client_a, 'for-her.png').json()['id']
    r = save_bg(client_a, b, chat_bg='photo', chat_bg_media=mid, chat_bg_dim=45)
    assert r.status_code == 200, r.text
    # 她自己看到的，是她那份
    assert bg_of(client_b, b)['media'] == mid
    # 我的那份没被波及
    assert bg_of(client_a, a) == {}


def test_background_media_is_readable_by_the_partner(client_a, client_b):
    reset_bg(client_a)
    """对方替我设的图是他的，我这边必须能取到，否则就是一张裂图。"""
    a, b = user_id(client_a), user_id(client_b)
    mid = post_media(client_a, 'cross.png').json()['id']
    assert save_bg(client_a, b, chat_bg='photo', chat_bg_media=mid).status_code == 200
    assert client_b.get(f'/media/{mid}').status_code == 200
    assert client_a.get(f'/media/{mid}').status_code == 200


def test_switch_to_preset_clears_that_persons_photo(client_a):
    reset_bg(client_a)
    a = user_id(client_a)
    mid = post_media(client_a, 'tmp.png').json()['id']
    assert save_bg(client_a, a, chat_bg='photo', chat_bg_media=mid).status_code == 200
    assert save_bg(client_a, a, chat_bg='night', chat_bg_media=mid, chat_bg_dim=35).status_code == 200
    # 切回预设必须清掉引用，否则这张图永远被判定为"在用"，回收不了
    assert bg_of(client_a, a) == {'bg': 'night', 'media': '', 'dim': 35}


def test_rejects_unknown_bg_target(client_a):
    reset_bg(client_a)
    assert save_bg(client_a, 'not-a-user', chat_bg='sakura').status_code == 422
    assert save_bg(client_a, user_id(client_a), chat_bg='sakura', chat_bg_dim=999).status_code == 422


def test_legacy_client_keeps_per_user_backgrounds(client_a, client_b):
    reset_bg(client_a)
    """旧客户端保存空间设置（不带 chat_bg_target），不能把各自的背景抹掉。"""
    a, b = user_id(client_a), user_id(client_b)
    mid_a = post_media(client_a, 'keep-a.png').json()['id']
    assert save_bg(client_a, a, chat_bg='photo', chat_bg_media=mid_a, chat_bg_dim=25).status_code == 200
    legacy = {k: v for k, v in space_of(client_a).items() if k != 'chat_bg_users'}
    legacy['name'] = '改了个名字'
    r = client_a.put('/api/space', headers=HEADERS, json=legacy)
    assert r.status_code == 200, r.text
    assert bg_of(client_a, a)['media'] == mid_a
