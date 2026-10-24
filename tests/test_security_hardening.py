"""上传校验与限流的回归测试（路线图 ⑬⑭）。

⑭ 以前只验图片，音视频完全信任客户端声明的 Content-Type——任意字节声明成
video/mp4 就能入库并被回显。⑬ 上传/导入/导出此前没有任何限流。
"""
import io

import pytest
from PIL import Image
from starlette.requests import Request

from app import db
from app.db import connect
from app.security import client_ip, rate_limit


@pytest.fixture(scope='module', autouse=True)
def _schema():
    db.init()


def png_bytes():
    buf = io.BytesIO()
    Image.new('RGB', (32, 32), (255, 128, 128)).save(buf, 'PNG')
    return buf.getvalue()


def post_media(client, payload, content_type, filename='x.bin'):
    return client.post('/api/media', headers={'X-Love-Space': '1'},
                       files={'file': (filename, payload, content_type)})


def test_upload_rejects_video_claim_with_text_payload(client_a):
    """声明 video/mp4 但内容是纯文本 → 422，不能靠客户端一句话就入库。"""
    r = post_media(client_a, b'this is definitely not a video', 'video/mp4', 'fake.mp4')
    assert r.status_code == 422, r.text
    assert '类型不符' in r.json()['detail']


def test_upload_accepts_real_mp4_container(client_a):
    """带 ftyp 魔数的文件要能通过——嗅探不能误伤正常文件。"""
    payload = b'\x00\x00\x00\x20ftypisom\x00\x00\x02\x00isomiso2' + b'\x00' * 64
    r = post_media(client_a, payload, 'video/mp4', 'real.mp4')
    assert r.status_code == 200, r.text


def test_upload_still_accepts_images(client_a):
    r = post_media(client_a, png_bytes(), 'image/png', 'ok.png')
    assert r.status_code == 200, r.text


def make_request(headers=None, client_host='10.0.0.1'):
    scope = {
        'type': 'http', 'method': 'POST', 'path': '/', 'scheme': 'https',
        'headers': [(k.lower().encode(), v.encode()) for k, v in (headers or {}).items()],
        'client': (client_host, 1234), 'server': ('testserver', 443),
        'query_string': b'', 'root_path': '',
    }
    return Request(scope)


def test_client_ip_prefers_x_real_ip():
    """X-Real-IP 由 nginx 覆盖写入，伪造的 X-Forwarded-For 不该盖过它。"""
    req = make_request({'X-Real-IP': '203.0.113.9', 'X-Forwarded-For': '1.1.1.1, 2.2.2.2'})
    assert client_ip(req) == '203.0.113.9'


def test_client_ip_falls_back_to_forwarded_last_hop():
    req = make_request({'X-Forwarded-For': '1.1.1.1, 203.0.113.9'})
    assert client_ip(req) == '203.0.113.9'


def test_client_ip_falls_back_to_socket():
    assert client_ip(make_request()) == '10.0.0.1'


def test_key_separation_uses_distinct_subkeys():
    """三类密文各用一把子密钥：拿错用途解不开。"""
    from cryptography.fernet import InvalidToken

    import pytest as _pytest
    from app.security import (PURPOSE_CHANNEL_CONFIG, PURPOSE_OWNER_SEALED,
                              PURPOSE_WEBPUSH_SUB, cipher)

    sealed = cipher(PURPOSE_OWNER_SEALED).encrypt(b'secret wish')
    assert cipher(PURPOSE_OWNER_SEALED).decrypt(sealed) == b'secret wish'
    for other in (PURPOSE_WEBPUSH_SUB, PURPOSE_CHANNEL_CONFIG):
        with _pytest.raises(InvalidToken):
            cipher(other).decrypt(sealed)


def test_legacy_master_key_ciphertext_still_opens():
    """用途分离之前落库的密文（用主密钥直接加密）必须仍然能解开。

    这是整条改动里唯一会造成不可逆损失的地方：少了回退，升级完成那一刻
    所有历史密文就都成了死数据。
    """
    from app.security import (PURPOSE_CHANNEL_CONFIG, PURPOSE_OWNER_SEALED,
                              cipher, decrypt_with_fallback, open_sealed,
                              seal_for_owner)

    legacy_owner = cipher().encrypt('旧的心愿内容'.encode()).decode()
    assert open_sealed(legacy_owner) == '旧的心愿内容'

    legacy_config = cipher().encrypt(b'{"token":"old"}')
    assert decrypt_with_fallback(PURPOSE_CHANNEL_CONFIG, legacy_config) == b'{"token":"old"}'

    # 新写的密文走子密钥，回退路径不会被误触发
    fresh = seal_for_owner('新的心愿内容')
    assert open_sealed(fresh) == '新的心愿内容'
    assert fresh != legacy_owner


def _post_record(client, kind, body):
    return client.post('/api/records', headers={'X-Love-Space': '1'},
                       json={'kind': kind, 'body': body, 'client_id': db.uid()})


def test_media_visible_paths(client_a, client_b):
    """钉住 media_visible 改写后的四条路径：私密日记图 / 共享图 / 封面 / 头像。

    改写把「全表逐条解密」换成了 SQL 下推 + 小集合回退，语义必须完全等价：
    该看到的还能看到，不该看到的一个都不能多。
    """
    # 共享记录里的图：双方都可见
    shared = post_media(client_a, png_bytes(), 'image/png', 'shared.png').json()['id']
    assert _post_record(client_a, 'post', {'content': '一起看', 'media': [shared]}).status_code == 200
    assert client_a.get(f'/media/{shared}').status_code == 200
    assert client_b.get(f'/media/{shared}').status_code == 200

    # 私密日记里的图：只有作者能看到
    mine = post_media(client_a, png_bytes(), 'image/png', 'mine.png').json()['id']
    assert _post_record(client_a, 'diary', {'content': '只属于我的秘密日记', 'media': [mine]}).status_code == 200
    assert client_a.get(f'/media/{mine}').status_code == 200
    assert client_b.get(f'/media/{mine}').status_code == 404

    # 空间封面：双方都可见
    cover = post_media(client_a, png_bytes(), 'image/png', 'cover.png').json()['id']
    space = client_a.get('/api/me', headers={'X-Love-Space': '1'}).json()['space']
    r = client_a.put('/api/space', headers={'X-Love-Space': '1'},
                      json={**space, 'cover': cover})
    assert r.status_code == 200, r.text
    assert client_a.get(f'/media/{cover}').status_code == 200
    assert client_b.get(f'/media/{cover}').status_code == 200

    # 头像：双方都可见
    avatar = post_media(client_a, png_bytes(), 'image/png', 'avatar.png').json()['id']
    r = client_a.put('/api/profile', headers={'X-Love-Space': '1'}, json={'name': '小兔', 'avatar': avatar})
    assert r.status_code == 200, r.text
    assert client_b.get(f'/media/{avatar}').status_code == 200


def test_rate_limit_window_and_limit_are_configurable():
    """限流参数化后，上传/导出才能用比登录更宽松的桶。"""
    from fastapi import HTTPException

    req = make_request({'X-Real-IP': '198.51.100.7'})
    with connect() as c:
        c.execute('DELETE FROM auth_attempts WHERE key LIKE ?', ('param-test%',))
    for _ in range(3):
        rate_limit(req, 'param-test', limit=3, window=60)
    with pytest.raises(HTTPException) as exc:
        rate_limit(req, 'param-test', limit=3, window=60)
    assert exc.value.status_code == 429
    assert '1 分钟' in exc.value.detail
    with connect() as c:
        c.execute('DELETE FROM auth_attempts WHERE key LIKE ?', ('param-test%',))
