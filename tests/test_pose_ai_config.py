"""AI 合成台配置落库（/api/pose-ai/config）与外壳页注入的测试。

诉求来源：图库只把 provider 配置（含 API Key）放 localStorage，换设备就要重填。
这里是「存 NAS」的服务端一半，另加一条护栏——落盘必须是密文，不能明文躺在库里。
"""
import json

from fastapi.testclient import TestClient

from app import db
from app.main import _inject_pose_ai_boot, _POSE_AI_BOOT, app

CONFIG = {
    'activeProvider': 'doubao',
    'useProxy': True,
    'providers': {
        'doubao': {'baseUrl': 'https://ark.cn-beijing.volces.com',
                   'apiKey': 'ark-bf63d04b-test-key', 'model': 'doubao-seedream-5-0-260128'},
    },
    'doubaoParams': {'size': '2K', 'responseFormat': 'b64_json'},
}


def test_requires_login():
    with TestClient(app, base_url='https://testserver') as anon:
        assert anon.get('/api/pose-ai/config').status_code == 401
        # 匿名 PUT 先撞中间件的 X-Love-Space 校验（403），不带头就够不着端点；戴头则 401
        assert anon.put('/api/pose-ai/config', json={'config': CONFIG}).status_code == 403
        assert anon.put('/api/pose-ai/config', json={'config': CONFIG},
                        headers={'X-Love-Space': '1'}).status_code == 401


def test_roundtrip_and_encrypted_at_rest(client_a):
    r = client_a.put('/api/pose-ai/config', json={'config': CONFIG})
    assert r.status_code == 200, r.text
    first = r.json()['saved']
    assert first > 0

    got = client_a.get('/api/pose-ai/config').json()
    assert got['config'] == CONFIG
    assert got['saved'] == first

    # 落盘必须是密文：settings.value 里不能出现 Key 明文
    with db.connect() as c:
        raw = c.execute("SELECT value FROM settings WHERE key='pose_ai_config'").fetchone()[0]
    assert 'ark-bf63d04b-test-key' not in raw
    assert 'doubao' not in raw

    # 再存一次要覆盖，而不是追加
    updated = json.loads(json.dumps(CONFIG))
    updated['providers']['doubao']['apiKey'] = 'ark-new-key-000'
    r2 = client_a.put('/api/pose-ai/config', json={'config': updated})
    assert r2.status_code == 200
    assert r2.json()['saved'] >= first
    assert client_a.get('/api/pose-ai/config').json()['config']['providers']['doubao']['apiKey'] == 'ark-new-key-000'
    with db.connect() as c:
        rows = c.execute("SELECT count(*) FROM settings WHERE key='pose_ai_config'").fetchone()[0]
    assert rows == 1


def test_oversized_config_is_rejected(client_a):
    big = {'blob': 'x' * (17 * 1024)}
    r = client_a.put('/api/pose-ai/config', json={'config': big})
    assert r.status_code == 413


def test_identical_config_does_not_write(client_a):
    """同样的配置重复回写不该刷新 saved 时间戳——图库每次打开都会回写一次，
    时间戳一路前进会让「NAS 上有更新版本」的判断永远成立，客户端跟着反复覆盖本地。"""
    client_a.put('/api/pose-ai/config', json={'config': CONFIG})
    first = client_a.get('/api/pose-ai/config').json()['saved']
    again = client_a.put('/api/pose-ai/config', json={'config': CONFIG})
    assert again.status_code == 200
    assert again.json().get('unchanged') is True
    assert again.json()['saved'] == first
    assert client_a.get('/api/pose-ai/config').json()['saved'] == first


def test_boot_script_goes_before_head_close():
    html = '<html><head><link rel="stylesheet" href="/a.css"></head><body><div id="root"></div></body></html>'
    out = _inject_pose_ai_boot(html)
    assert _POSE_AI_BOOT in out
    assert out.index(_POSE_AI_BOOT) < out.index('</head>')
    # 外壳页原内容一点不能少
    assert '<link rel="stylesheet" href="/a.css">' in out
    assert '<div id="root"></div>' in out


def test_boot_script_survives_html_without_head():
    out = _inject_pose_ai_boot('<body>裸片段</body>')
    assert out.startswith('<script>')
    assert '<body>裸片段</body>' in out


def test_boot_script_only_touches_its_own_key():
    # 注入脚本必须只认 pose_atlas_api_config_v3，别把上游其它 localStorage 键也拦下来
    assert "k === KEY" in _POSE_AI_BOOT
    assert 'pose_atlas_api_config_v3' in _POSE_AI_BOOT
    assert 'xhr.open' in _POSE_AI_BOOT and 'false' in _POSE_AI_BOOT
