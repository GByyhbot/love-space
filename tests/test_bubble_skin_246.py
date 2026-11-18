"""2.4.6 气泡各发各的（按人皮肤）：真实 HTTP 形状用例。

口径（yang 2026-11-18 定案 + AskUserQuestion 拍板「按人三键」）：
· users 表按人三键 bubble_skin/bubble_fg/bubble_swap，下发走 /api/me 的
  user+users（public_user），与头像/昵称同一份载荷；
· 写入走 PUT /api/profile 扩展（无 id 字段=只能改自己，额外字段被 pydantic
  丢弃）；皮肤 id 必须在 /api/bubbles 目录内，不存在 422；
· bubble_skin='' 清空=三键整体回未设置；bubble_swap 的独立清空无入口
 （NULL=未设置，渲染回退空间级）；
· 空间级 chat_bubble* 三键与 PUT /api/space 原样保留（Web 数据源+回退基底）。
"""
import pytest

from app import db


def _make_bubble_file(pack='sk1', name='1000.png'):
    """在测试数据目录造一张真实气泡图（validate_bubble_skin 要查目录）。"""
    d = db.DATA / 'bubbles' / pack
    d.mkdir(parents=True, exist_ok=True)
    f = d / name
    f.write_bytes(b'\x89PNG fake')
    return f'{pack}/{name}'


def _me(client):
    return client.get('/api/me', headers={'X-Love-Space': '1'}).json()


def _user_of(me_json, username):
    for u in me_json['users']:
        if u['username'] == username:
            return u
    raise AssertionError(f'{username} 不在成员载荷里')


def _profile(client, **kw):
    """name/avatar 缺省取当前用户现值（Profile 模型必填），只动气泡键；
    不得覆盖对方名字——habit 等测试按 name 找人。"""
    me = _me(client)['user']
    body = {'name': kw.pop('name', me['name']), 'avatar': kw.pop('avatar', me['avatar']), **kw}
    return client.put('/api/profile', headers={'X-Love-Space': '1'}, json=body)


def test_per_user_bubble_set_and_payload(client_a, client_b):
    """A 设置后成员载荷里 A 带三键、B 仍为空；双方各看各的载荷一致。"""
    skin = _make_bubble_file()
    r = _profile(client_a, bubble_skin=skin, bubble_fg='light', bubble_swap=False)
    assert r.status_code == 200, r.text

    for me in (_me(client_a), _me(client_b)):
        a = _user_of(me, 'lover1')
        b = _user_of(me, 'lover2')
        assert a['bubble_skin'] == skin
        assert a['bubble_fg'] == 'light'
        assert a['bubble_swap'] is False
        assert b['bubble_skin'] == ''
        assert b['bubble_fg'] == ''
        assert b['bubble_swap'] is None


def test_cannot_write_others_bubble(client_a, client_b):
    """B 改不到 A 的：profile 无 id 字段，带别人的 id 一律被丢弃。"""
    _profile(client_a, bubble_skin='')  # 前序用例给 A 设过皮肤，先清空归零
    skin = _make_bubble_file('sk9', '7.png')
    r = _profile(client_b, bubble_skin=skin, user_id='lover1-id-unknown')
    assert r.status_code == 200, r.text
    a = _user_of(_me(client_a), 'lover1')
    b = _user_of(_me(client_b), 'lover2')
    assert a['bubble_skin'] == ''          # A 丝毫未动
    assert b['bubble_skin'] == skin        # 改的是 B 自己


def test_invalid_skin_rejected(client_a):
    """非法皮肤 id 一律 422 透传文案：不存在/镜像图/非法字符/坏字色。"""
    _profile(client_a, bubble_skin='')  # 前序用例给 A 设过皮肤，先清空归零
    for bad in ('p1/404.png', 'p1/1000-r.png', '../etc/passwd', 'p1/x.png'):
        r = _profile(client_a, bubble_skin=bad)
        assert r.status_code == 422, (bad, r.text)
        assert '没有这张气泡' in r.text or '字色' in r.text
    r = _profile(client_a, bubble_skin=_make_bubble_file('sk2', '3.png'), bubble_fg='blue')
    assert r.status_code == 422
    assert '字色' in r.text
    # 校验失败不留脏数据
    a = _user_of(_me(client_a), 'lover1')
    assert a['bubble_skin'] == ''


def test_clear_resets_all_three(client_a):
    """bubble_skin='' 清空=三键整体回未设置。"""
    skin = _make_bubble_file('sk3', '9.png')
    assert _profile(client_a, bubble_skin=skin, bubble_fg='dark', bubble_swap=True).status_code == 200
    assert _user_of(_me(client_a), 'lover1')['bubble_skin'] == skin
    r = _profile(client_a, bubble_skin='')
    assert r.status_code == 200, r.text
    a = _user_of(_me(client_a), 'lover1')
    assert a['bubble_skin'] == ''
    assert a['bubble_fg'] == ''
    assert a['bubble_swap'] is None


def test_space_chat_bubble_path_unaffected(client_a):
    """空间级 chat_bubble* 写入路径（PUT /api/space）原样保留。"""
    space = _me(client_a)['space']
    r = client_a.put('/api/space', headers={'X-Love-Space': '1'},
                     json={**space, 'chat_bubble': 'p1/1000.png', 'chat_bubble_fg': 'light'})
    assert r.status_code == 200, r.text
    space2 = _me(client_a)['space']
    assert space2['chat_bubble'] == 'p1/1000.png'
    assert space2['chat_bubble_fg'] == 'light'
    # 按人键不进空间对象（禁止存空间字段冒充）
    assert 'bubble_skin' not in space2
    # 收尾恢复空间字段为空：后续模块（test_chat_bubble::test_default_is_no_skin）
    # 对空间 chat_bubble 的初始态有断言，会话级 DATA 目录共享不能留脏值
    client_a.put('/api/space', headers={'X-Love-Space': '1'},
                 json={**space2, 'chat_bubble': '', 'chat_bubble_fg': ''})


def test_fg_swap_update_without_skin(client_a):
    """只调字色/互换不动皮肤：允许，且不影响已设皮肤。"""
    skin = _make_bubble_file('sk4', '5.png')
    assert _profile(client_a, bubble_skin=skin, bubble_fg='dark', bubble_swap=True).status_code == 200
    assert _profile(client_a, bubble_fg='light', bubble_swap=False).status_code == 200
    a = _user_of(_me(client_a), 'lover1')
    assert a['bubble_skin'] == skin
    assert a['bubble_fg'] == 'light'
    assert a['bubble_swap'] is False


def test_revision_bumps_on_bubble_change(client_a):
    """改皮肤推进 content_revision（revision_users_update 触发器）→ 对方 SSE 感知。"""
    from app.main import connect
    with connect() as c:
        before = int(c.execute("SELECT value FROM app_state WHERE key='content_revision'").fetchone()[0])
    assert _profile(client_a, bubble_skin=_make_bubble_file('sk5', '1.png')).status_code == 200
    with connect() as c:
        after = int(c.execute("SELECT value FROM app_state WHERE key='content_revision'").fetchone()[0])
    assert after > before


def teardown_module(module):
    """收尾清掉本模块造的假气泡素材，不让后续模块的 /api/bubbles
    清单断言（test_chat_bubble 的 p1/p2 组）看到我们的 sk* 组。"""
    import shutil
    shutil.rmtree(db.DATA / 'bubbles', ignore_errors=True)
