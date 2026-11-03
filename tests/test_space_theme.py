"""空间设置里的主题配色：七套都要存得进去，未知值要明确报错。

背景：1.7.13 把主题从三套扩到七套，前端色卡、CSS 色板、JS 白名单都改了，
唯独 `PUT /api/space` 里还留着 `{'rose','peach','lavender','custom'}` 这四项目名单。
结果是选「海盐汽水」保存必失败，而兜底文案是「请检查日期、时区、主题和聊天背景」——
日期时区都没错，用户对着这句话完全不知道该改哪里。

这里守两件事：
① 后端白名单必须跟前端 `THEME_IDS` 对齐（含以后新增的主题）；
② 每项校验失败时给的是中文、能定位的提示，不是那句笼统话。
"""
from fastapi.testclient import TestClient

HEADERS = {'X-Love-Space': '1'}

# 与 static/app.js 的 THEME_IDS 保持一致。新增主题时这里也要加一行，
# 漏了就会被本测试拦下来，而不是等用户保存失败。
THEME_IDS = ['rose', 'peach', 'lemon', 'mint', 'sky', 'lavender', 'cocoa']


def space_of(client):
    return client.get('/api/me', headers=HEADERS).json()['space']


def save_space(client, **patch):
    return client.put('/api/space', headers=HEADERS, json={**space_of(client), **patch})


def test_every_builtin_theme_saves(client_a):
    for theme in THEME_IDS:
        r = save_space(client_a, theme=theme)
        assert r.status_code == 200, f'{theme} 保存失败：{r.text}'
        assert space_of(client_a)['theme'] == theme


def test_custom_theme_saves_color(client_a):
    r = save_space(client_a, theme='custom', custom_color='#3A826D')
    assert r.status_code == 200, r.text
    space = space_of(client_a)
    assert space['theme'] == 'custom'
    assert space['custom_color'] == '#3A826D'


def test_switch_back_to_builtin_clears_custom_color(client_a):
    save_space(client_a, theme='custom', custom_color='#3A826D')
    assert save_space(client_a, theme='mint').status_code == 200
    assert space_of(client_a)['custom_color'] == ''


def test_unknown_theme_is_rejected_with_readable_message(client_a):
    r = save_space(client_a, theme='neon')
    assert r.status_code == 422
    assert '主题' in r.json()['detail']


def test_custom_theme_needs_hex_color(client_a):
    r = save_space(client_a, theme='custom', custom_color='tomato')
    assert r.status_code == 422
    assert '#RRGGBB' in r.json()['detail']


def test_bad_since_date_is_named(client_a):
    r = save_space(client_a, since='2026/11/04')
    assert r.status_code == 422
    # 不能只回那句"请检查日期、时区、主题和聊天背景"，得让人知道是日期的问题
    assert '日期' in r.json()['detail']


def test_bad_timezone_still_falls_back_to_generic_hint(client_a):
    r = save_space(client_a, timezone='Mars/Olympus')
    assert r.status_code == 422
    assert r.json()['detail']  # 至少不是空串
