"""聊天气泡皮肤：字段校验、旧客户端兜底、素材清单与取图。

背景：聊天界面可以换一套"微信风格"的气泡图。素材是用户自己整理的 128×112 的
整图，两千多张，放在数据卷 `bubbles/<包>/<文件名>.png`（不进镜像），前端靠 CSS
border-image 切九宫格拉伸渲染，自己那侧用服务器预先水平翻转的 `-r.png` 镜像。

服务端只负责三件事：
① space 里存一个 `包/文件名.png` 的引用（两个人共用一份）和字色；
② 按包分组吐清单（只回名字，两千多张不可能一次全发预览图）；
③ 把某一张图原样吐出来，并做到一年强缓存。
"""
import struct
import zlib

from fastapi.testclient import TestClient

from app import db
from app.main import app

HEADERS = {'X-Love-Space': '1'}


def space_of(client):
    return client.get('/api/me', headers=HEADERS).json()['space']


def save_space(client, **patch):
    return client.put('/api/space', headers=HEADERS, json={**space_of(client), **patch})


def tiny_png():
    """1×1 的合法 PNG：只是要让 FileResponse 有个真文件可读。"""
    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))
    ihdr = struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0)
    raw = b'\x00\x00\x00\x00\x00'
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def write_pack(pack, names):
    folder = db.DATA / 'bubbles' / pack
    folder.mkdir(parents=True, exist_ok=True)
    for name in names:
        (folder / name).write_bytes(tiny_png())
    return folder


def test_default_is_no_skin(client_a):
    space = space_of(client_a)
    # 建空间时还没保存过设置，库里可能没有这两个键；有就必须是"不用皮肤 + 深色字"
    assert space.get('chat_bubble') in (None, '')
    assert space.get('chat_bubble_fg') in (None, '', 'dark')


def test_roundtrip(client_a):
    assert save_space(client_a, chat_bubble='p1/1000.png', chat_bubble_fg='light').status_code == 200
    space = space_of(client_a)
    assert space['chat_bubble'] == 'p1/1000.png'
    assert space['chat_bubble_fg'] == 'light'
    assert save_space(client_a, chat_bubble='', chat_bubble_fg='dark').status_code == 200
    assert space_of(client_a)['chat_bubble'] == ''


def test_old_client_keeps_skin(client_a):
    """旧版 APK 保存空间设置时不带这两个字段，不能把对方挑好的皮肤清掉。"""
    assert save_space(client_a, chat_bubble='p2/7.png', chat_bubble_fg='light').status_code == 200
    space = space_of(client_a)
    for key in ('chat_bubble', 'chat_bubble_fg'):
        space.pop(key, None)          # 冒充"没带这个字段"的旧客户端
    assert client_a.put('/api/space', headers=HEADERS, json=space).status_code == 200
    space = space_of(client_a)
    assert space['chat_bubble'] == 'p2/7.png'
    assert space['chat_bubble_fg'] == 'light'


def test_bad_paths_rejected(client_a):
    bad = [
        'p1/../../etc/passwd',        # 想爬出目录
        '../p1/1000.png',
        'p1/1000.jpg',                # 只收 png
        'p1/1000.PNG',
        'p1/sub/1000.png',            # 只允许一层
        '/1000.png',
        'p1/',                        # 没有文件名
        'p 1/1000.png',               # 空格
        'p1/' + 'a' * 60 + '.png',    # 文件名过长
    ]
    for value in bad:
        r = save_space(client_a, chat_bubble=value)
        assert r.status_code == 422, f'{value} 应该被拒绝，实际 {r.status_code}'
    # 坏值被拒之后，库里原来的值不能被写坏
    assert save_space(client_a, chat_bubble='p1/1000.png').status_code == 200
    assert space_of(client_a)['chat_bubble'] == 'p1/1000.png'


def test_bad_fg_rejected(client_a):
    assert save_space(client_a, chat_bubble_fg='blue').status_code == 422
    # 空串是"没选过"的意思，前端按 dark 处理，不必报错（老数据里就有空串）
    assert save_space(client_a, chat_bubble_fg='').status_code == 200


def test_list_groups_skip_mirrors_and_junk(client_a):
    write_pack('p1', ['1000.png', '1000-r.png', '1001.png'])
    write_pack('p2', ['7.png'])
    folder = db.DATA / 'bubbles' / 'p2'
    (folder / 'notes.txt').write_bytes(b'x')          # 非 png 不算
    (folder / 'bad name.png').write_bytes(tiny_png())  # 名字不合法也不算
    groups = client_a.get('/api/bubbles', headers=HEADERS).json()['groups']
    by_id = {g['id']: g for g in groups}
    assert by_id['p1']['count'] == 2                   # 镜像图不重复出现在清单里
    assert by_id['p1']['items'] == ['1000.png', '1001.png']
    assert by_id['p2']['items'] == ['7.png']
    assert 'bad name.png' not in by_id['p2']['items']


def test_image_served_and_cached(client_a):
    write_pack('p1', ['1000.png', '1000-r.png'])
    r = client_a.get('/api/bubbles/p1/1000.png', headers=HEADERS)
    assert r.status_code == 200
    assert r.headers['content-type'] == 'image/png'
    # 图不会改：一年强缓存，来回切皮肤不重复打网络
    assert 'immutable' in r.headers.get('cache-control', '')
    assert client_a.get('/api/bubbles/p1/1000-r.png', headers=HEADERS).status_code == 200


def test_image_404(client_a):
    assert client_a.get('/api/bubbles/p1/nope.png', headers=HEADERS).status_code == 404
    assert client_a.get('/api/bubbles/nope/1000.png', headers=HEADERS).status_code == 404
    # 路径穿越、非法字符一律 404（路由本身也会先拦）
    assert client_a.get('/api/bubbles/p1/..%2F..%2Fapp%2Fmain.py', headers=HEADERS).status_code in (400, 404)
    assert client_a.get('/api/bubbles/p1/1000.txt', headers=HEADERS).status_code == 404


def test_bubbles_need_login(client_a):
    with TestClient(app, base_url='https://testserver') as anon:
        assert anon.get('/api/bubbles').status_code == 401
        assert anon.get('/api/bubbles/p1/1000.png').status_code == 401


def test_no_skin_dir_is_empty_not_error(client_a):
    """素材目录还不存在时清单返回空数组，前端据此显示"没有素材"，不该 500。"""
    for p in (db.DATA / 'bubbles').glob('*'):
        if p.is_dir():
            for f in p.iterdir():
                f.unlink()
            p.rmdir()
    assert client_a.get('/api/bubbles', headers=HEADERS).json()['groups'] == []


def test_swap_defaults_to_on(client_a):
    """左右互换：库里还没这个键时按"对调"起步。

    素材是网上收的整图，装饰画在左边还是右边全看作者（三个包并不统一），
    没法靠一张图自动判断，所以默认对调——大多数人下载到的都是右侧样式的气泡。
    """
    assert space_of(client_a).get('chat_bubble_swap') is not False


def test_swap_roundtrip(client_a):
    assert save_space(client_a, chat_bubble='p1/1000.png', chat_bubble_swap=False).status_code == 200
    assert space_of(client_a)['chat_bubble_swap'] is False
    assert save_space(client_a, chat_bubble_swap=True).status_code == 200
    assert space_of(client_a)['chat_bubble_swap'] is True


def test_old_client_keeps_swap(client_a):
    """旧版 APK 保存空间设置时不带这个字段，不能把对方调好的方向重置掉。"""
    save_space(client_a, chat_bubble_swap=False)
    space = space_of(client_a)
    space.pop('chat_bubble_swap', None)      # 模拟旧客户端：整个字段都不带
    r = client_a.put('/api/space', headers=HEADERS, json=space)
    assert r.status_code == 200, r.text
    assert space_of(client_a)['chat_bubble_swap'] is False
