"""AI 合成台「生成记录」落库（/api/pose-ai/history）的测试。

诉求来源：图库的生成记录只写 IndexedDB，而记录里的 imageUrl 常常是 data:base64 整张图，
30 条上百 MB，配额一崩下次打开就空了 —— 用户看到的就是「生成的记录不能保留」。

这里守住服务端这一半的规矩：
1. 只收瘦记录（data: 图片一律丢弃，不能把 base64 塞进 settings 表）
2. 条数跟上游一致（30 条），超了按顺序截断而不是报错
3. 内容没变不刷时间戳（否则客户端每次打开都判成「NAS 更新了」，来回覆盖）
4. 落盘是密文
"""
import json

from fastapi.testclient import TestClient

from app import db
from app.main import _POSE_AI_BOOT, app

HEADERS = {'X-Love-Space': '1'}


def item(n, image='/media/abc123?preview=true'):
    return {
        'id': f'17300000{n:05d}-abcd',
        'createdAt': 1730000000000 + n,
        'provider': 'doubao',
        'model': 'doubao-seedream-5-0-260128',
        'prompt': f'第 {n} 张合成提示词',
        'recipeSummary': '人像 + 服装 + 姿势',
        'imageUrl': image,
    }


def test_requires_login():
    with TestClient(app, base_url='https://testserver') as anon:
        assert anon.get('/api/pose-ai/history').status_code == 401
        assert anon.put('/api/pose-ai/history', json={'items': []}).status_code == 403
        assert anon.put('/api/pose-ai/history', json={'items': []},
                        headers=HEADERS).status_code == 401


def test_roundtrip_keeps_order_and_encrypts(client_a):
    items = [item(3), item(2), item(1)]
    r = client_a.put('/api/pose-ai/history', json={'items': items})
    assert r.status_code == 200, r.text
    assert r.json()['count'] == 3
    saved = r.json()['saved']

    got = client_a.get('/api/pose-ai/history').json()
    assert got['saved'] == saved
    assert [x['id'] for x in got['items']] == [x['id'] for x in items]
    assert got['items'][0]['imageUrl'] == '/media/abc123?preview=true'

    # 落盘密文：settings 里不能出现提示词明文
    with db.connect() as c:
        raw = c.execute("SELECT value FROM settings WHERE key='pose_ai_history'").fetchone()[0]
    assert '第 3 张合成提示词' not in raw
    with db.connect() as c:
        assert c.execute("SELECT count(*) FROM settings WHERE key='pose_ai_history'").fetchone()[0] == 1


def test_base64_image_is_dropped_instead_of_stored(client_a):
    """data: 图要么客户端转存成 /media 短链，要么丢图——绝不能把几 MB 的 base64 存进库。"""
    fat = item(9, image='data:image/png;base64,' + 'A' * 50000)
    r = client_a.put('/api/pose-ai/history', json={'items': [fat]})
    assert r.status_code == 200, r.text
    got = client_a.get('/api/pose-ai/history').json()['items']
    assert got[0]['id'] == fat['id']
    assert 'imageUrl' not in got[0]          # 记录留着，坏图不要
    assert len(json.dumps(got)) < 2000


def test_caps_at_thirty_items(client_a):
    items = [item(n) for n in range(45)]
    r = client_a.put('/api/pose-ai/history', json={'items': items})
    assert r.status_code == 200
    assert r.json()['count'] == 30
    assert len(client_a.get('/api/pose-ai/history').json()['items']) == 30


def test_identical_list_does_not_write(client_a):
    items = [item(1), item(2)]
    client_a.put('/api/pose-ai/history', json={'items': items})
    first = client_a.get('/api/pose-ai/history').json()['saved']
    again = client_a.put('/api/pose-ai/history', json={'items': items})
    assert again.status_code == 200
    assert again.json().get('unchanged') is True
    assert again.json()['saved'] == first
    assert client_a.get('/api/pose-ai/history').json()['saved'] == first


def test_empty_list_clears(client_a):
    client_a.put('/api/pose-ai/history', json={'items': [item(1)]})
    r = client_a.put('/api/pose-ai/history', json={'items': []})
    assert r.status_code == 200
    assert r.json()['count'] == 0
    assert client_a.get('/api/pose-ai/history').json()['items'] == []


def test_boot_script_syncs_history():
    # 两条链路缺一不可：同步 XHR 取回 NAS 那份 + hook 住 IndexedDB 的写入
    assert '/api/pose-ai/history' in _POSE_AI_BOOT
    assert 'pose_atlas_history_v3' in _POSE_AI_BOOT
    assert 'pose_atlas_studio_db' in _POSE_AI_BOOT
    assert 'IDBObjectStore.prototype.put' in _POSE_AI_BOOT
    assert '/api/media' in _POSE_AI_BOOT          # 图片转存
    assert 'xhr.open' in _POSE_AI_BOOT and 'false' in _POSE_AI_BOOT
