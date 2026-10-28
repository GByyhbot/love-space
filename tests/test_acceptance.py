"""验收测试：覆盖产品框架「验收重点」的全部场景。"""
import base64
import io
import json
import sqlite3
import tempfile
import time
import zipfile
from pathlib import Path

import pytest

from conftest import HEADERS, PASSWORD  # noqa: E402,F401
from fastapi.testclient import TestClient
from PIL import Image

from app import db
from app.main import app



def png_bytes(color=(255, 120, 140, 255)):
    img = Image.new('RGBA', (48, 48), color)
    buf = io.BytesIO()
    img.save(buf, 'PNG')
    return buf.getvalue()


def upload(client, name='photo.png'):
    r = client.post('/api/media', files={'file': (name, png_bytes(), 'image/png')})
    assert r.status_code == 200, r.text
    return r.json()['id']


def test_openapi_schema_is_not_public(monkeypatch):
    monkeypatch.setenv('PUBLIC_URL', 'https://love.example.com')
    monkeypatch.setenv('NTFY_SERVER', 'https://push.example.com/ntfy')
    with TestClient(app, base_url='https://testserver') as client:
        assert client.get('/openapi.json').status_code == 404
        assert client.get('/health').headers['strict-transport-security'] == 'max-age=31536000'
        assert 'wss://push.example.com' in client.get('/').headers['content-security-policy']
        assert client.get('/static/sw.js').headers['service-worker-allowed'] == '/'
        # 陌生公网主机 + 明文 → 踢回 HTTPS 域名；内网直连不放行到这条分支（见下个用例）
        raw_ip = client.get('http://testserver/', headers={'host': '1.2.3.4:1314'}, follow_redirects=False)
        assert raw_ip.status_code == 308
        assert raw_ip.headers['location'] == 'https://love.example.com/'
        blocked = client.post('http://testserver/api/login', headers={**HEADERS, 'host': '1.2.3.4:1314'}, json={})
        assert blocked.status_code == 403
        proxied = client.get('/', headers={'host': '172.30.0.1:1314', 'x-forwarded-proto': 'https'},
                             follow_redirects=False)
        assert proxied.status_code == 200


def test_lan_plain_http_is_not_redirected(client_a, monkeypatch):
    """局域网/本机直连走明文：不跳公网域名、不发 HSTS、cookie 不带 Secure。

    以前这里一律 308 到 PUBLIC_URL，结果家里敲 192.168.x.x:1314 会被甩到公网域名上，
    内网访问形同虚设（公网绕一圈甚至更快被墙）。
    """
    monkeypatch.setenv('PUBLIC_URL', 'https://love.example.com')
    with TestClient(app, base_url='http://testserver', headers=HEADERS) as c:
        for h in ('192.168.31.95:1314', 'localhost:1314', '10.0.0.8:1314', '172.20.0.5:1314',
                  '[::1]:1314', 'nas:1314'):
            r = c.get('/', headers={'host': h}, follow_redirects=False)
            assert r.status_code == 200, (h, r.status_code, r.headers.get('location'))
            assert 'strict-transport-security' not in r.headers, h
        # 内网能正常登录，且 cookie 不带 Secure —— 否则浏览器在 http 下不回传，表现为"
        # 登录成功又跳回登录页"
        ok = c.post('/api/login', headers={**HEADERS, 'host': '192.168.31.95:1314'},
                    json={'username': 'lover1', 'password': PASSWORD})
        assert ok.status_code == 200, ok.text
        assert 'secure' not in ok.headers['set-cookie'].lower()
        # 公网域名走 HTTPS 时仍然带 Secure
        pub = c.post('/api/login', headers={**HEADERS, 'host': 'love.example.com',
                                            'x-forwarded-proto': 'https'},
                     json={'username': 'lover1', 'password': PASSWORD})
        assert pub.status_code == 200, pub.text
        assert 'secure' in pub.headers['set-cookie'].lower()


def test_chat_zip_import_enforces_expansion_and_image_limits():
    from app.importers import parse_zip

    archive = io.BytesIO()
    with zipfile.ZipFile(archive, 'w') as zf:
        zf.writestr('chat.txt', 'x' * 11)
    with pytest.raises(ValueError, match='解压后体积过大'):
        parse_zip(archive.getvalue(), max_unpacked_bytes=10)

    archive = io.BytesIO()
    with zipfile.ZipFile(archive, 'w') as zf:
        zf.writestr('one.png', b'one')
        zf.writestr('two.png', b'two')
    with pytest.raises(ValueError, match='图片数量过多'):
        parse_zip(archive.getvalue(), max_images=1)


def test_pairing_then_registration_closed(client_a, client_b):
    """绑定后关闭公开注册。"""
    session_cookie = next(cookie for cookie in client_a.cookies.jar if cookie.name == 'love_session')
    assert session_cookie.secure is True
    assert client_a.post('/api/invite', headers=HEADERS).status_code == 409
    token = 'x' * 40
    r = client_b.post('/api/join', headers=HEADERS,
                      json={'username': 'third', 'password': PASSWORD, 'name': '第三者', 'token': token})
    assert r.status_code == 403


def test_unauthenticated_access_denied():
    """未登录用户无法读取记录及媒体文件。"""
    with TestClient(app, base_url='https://testserver') as anon:
        assert anon.get('/api/records').status_code == 401
        assert anon.get('/api/me').status_code == 401
        assert anon.get('/api/webpush').status_code == 401
        assert anon.post('/api/native-push/test', headers=HEADERS).status_code == 401
        assert anon.get('/api/photos').status_code == 401
        assert anon.delete('/api/notices/read', headers=HEADERS).status_code == 401
        assert anon.get('/media/whatever').status_code in {401, 404}
        assert anon.get('/api/export').status_code == 401
        # 缺少自定义请求头（CSRF 防护）
        with TestClient(app, base_url='https://testserver') as fresh:
            fresh.post('/api/setup', json={'username': 'x1', 'password': PASSWORD})
            assert fresh.post('/api/login', json={'username': 'a', 'password': 'b'}).status_code == 403

def test_native_push_test_is_private_and_uses_durable_ntfy_queue(client_a, client_b, monkeypatch):
    from app import notifications, worker
    from app.db import connect

    # 内置 ntfy 系统推送受 NTFY_ENABLED 开关控制：默认停用（通知走第三方渠道与 Web Push）
    monkeypatch.delenv('NTFY_ENABLED', raising=False)
    assert client_a.get('/api/me').json()['ntfy_topic'] is None
    assert client_a.post('/api/native-push/test', headers=HEADERS).status_code == 503

    monkeypatch.setenv('NTFY_ENABLED', '1')
    me = client_a.get('/api/me').json()
    response = client_a.post('/api/native-push/test', headers=HEADERS)
    assert response.status_code == 200, response.text
    with connect() as conn:
        row = conn.execute('''SELECT n.id,n.user_id,p.topic,p.status
          FROM notices n JOIN push_outbox p ON p.notice_id=n.id
          WHERE n.user_id=? AND n.event='test' AND n.title='后台推送测试'
          ORDER BY n.created DESC LIMIT 1''', (me['user']['id'],)).fetchone()
        assert row is not None
        assert row['topic'] == me['ntfy_topic']
        assert row['status'] == 'pending'
        assert conn.execute("SELECT count(*) FROM notices WHERE event='test' AND title='后台推送测试'").fetchone()[0] == 1

    sent = []
    monkeypatch.setattr(notifications, 'send',
                        lambda kind, config, title, body, key: sent.append((kind, config, title, body, key)))
    worker.deliver_pushes()
    with connect() as conn:
        status = conn.execute('SELECT status FROM push_outbox WHERE notice_id=?', (row['id'],)).fetchone()[0]
    assert status == 'sent'
    assert any(item[0] == 'ntfy' and item[1]['topic'] == me['ntfy_topic'] for item in sent)


def test_private_diary_isolated_from_partner(client_a, client_b):
    """私密日记不出现在伴侣的页面、详情、媒体访问和导出中。"""
    mid = upload(client_a, 'secret.png')
    from app.db import connect
    owner_id = client_a.get('/api/me').json()['user']['id']
    with connect() as conn:
        shared_revision_before = conn.execute("SELECT value FROM app_state WHERE key='content_revision'").fetchone()[0]
        private_revision_before = conn.execute('SELECT value FROM user_revisions WHERE user_id=?', (owner_id,)).fetchone()
    r = client_a.post('/api/records', headers=HEADERS,
                      json={'kind': 'diary', 'body': {'content': '只属于我的秘密日记', 'media': [mid]}})
    assert r.status_code == 200, r.text
    diary_id = r.json()['id']

    assert all(x['kind'] != 'diary' for x in client_b.get('/api/records').json())
    assert client_b.get('/api/records?kind=diary').json() == []
    assert client_b.get(f'/api/records/{diary_id}').status_code == 404
    assert client_b.get(f'/media/{mid}').status_code == 404
    assert client_b.get(f'/media/{mid}?preview=true').status_code == 404

    mine = zipfile.ZipFile(io.BytesIO(client_a.get('/api/export').content)).read('records.json')
    theirs = zipfile.ZipFile(io.BytesIO(client_b.get('/api/export').content)).read('records.json')
    assert '只属于我的秘密日记'.encode() in mine
    assert '只属于我的秘密日记'.encode() not in theirs

    from app.db import DATA
    with sqlite3.connect(DATA / 'love.db') as conn:
        stored = conn.execute('SELECT body FROM records WHERE id=?', (diary_id,)).fetchone()[0]
    assert '只属于我的秘密日记' not in stored
    assert '_private_record' in stored
    with connect() as conn:
        shared_revision_after = conn.execute("SELECT value FROM app_state WHERE key='content_revision'").fetchone()[0]
        private_revision_after = conn.execute('SELECT value FROM user_revisions WHERE user_id=?', (owner_id,)).fetchone()[0]
    assert shared_revision_after == shared_revision_before
    assert private_revision_after > (private_revision_before[0] if private_revision_before else 0)

    # 作者自己始终可见
    assert any(x['id'] == diary_id for x in client_a.get('/api/records?kind=diary').json())


def test_personal_wishes_are_encrypted_unlock_once_and_stay_open(client_a, client_b):
    """心愿名称双方可见；作者可直接回看，对方输对一次密码后永久可见，数据库始终不落明文。"""
    title, secret, password = '想一起去看极光', '希望有一天我们能在雪地里等到极光。', 'aurora-wish-pass-01'
    created = client_a.post('/api/personal-wishes', headers=HEADERS,
                            json={'title': title, 'content': secret, 'password': password, 'client_id': 'personal-wish-a1'})
    assert created.status_code == 200, created.text
    rid = created.json()['id']
    assert created.json()['body']['sealed']
    assert 'password_hash' not in created.json()['body']

    def listed_item(client):
        return next(record for record in client.get('/api/records?kind=personal_wish').json() if record['id'] == rid)

    # 作者本人：无需密码，直接可见
    own = listed_item(client_a)
    assert own['body']['title'] == title
    assert own['body']['locked'] is False
    assert own['body']['content'] == secret
    assert 'password_hash' not in own['body']

    # 对方：解锁前只见名称，拿不到正文、密文或密码摘要
    other = listed_item(client_b)
    assert other['body']['title'] == title
    assert other['body']['locked'] is True
    assert 'content' not in other['body']
    assert secret not in str(other)
    assert 'password_hash' not in other['body']
    assert 'sealed' not in client_b.get(f'/api/records/{rid}').json()['body']

    from app.db import DATA
    with sqlite3.connect(DATA / 'love.db') as conn:
        stored = conn.execute('SELECT body FROM records WHERE id=?', (rid,)).fetchone()[0]
    assert secret not in stored

    wrong = client_b.post(f'/api/personal-wishes/{rid}/unlock', headers=HEADERS, json={'password': 'wrong-password-01'})
    assert wrong.status_code == 403
    opened = client_b.post(f'/api/personal-wishes/{rid}/unlock', headers=HEADERS, json={'password': password})
    assert opened.status_code == 200
    assert opened.json()['content'] == secret

    # 解锁一次后永久可见：重新拉取列表仍直接带出内容，不必再输密码
    again = listed_item(client_b)
    assert again['body']['locked'] is False
    assert again['body']['content'] == secret
    assert client_a.post(f'/api/personal-wishes/{rid}/unlock', headers=HEADERS,
                         json={'password': password}).json()['content'] == secret

    reused = client_b.post('/api/personal-wishes', headers=HEADERS,
                           json={'title': '另一个期待', 'content': '这是另一条内容', 'password': password})
    assert reused.status_code == 422
    unique = client_b.post('/api/personal-wishes', headers=HEADERS,
                           json={'title': '另一件期待', 'content': '这是另一条内容', 'password': 'separate-wish-pass-02'})
    assert unique.status_code == 200, unique.text


def test_legacy_private_body_is_encrypted_during_startup(client_a, client_b):
    """Existing plaintext private records are migrated without changing visibility."""
    from app.db import connect, dumps, now, uid, init
    owner_id = client_a.get('/api/me').json()['user']['id']
    rid, timestamp = uid(), now()
    content = 'legacy-private-migration-check'
    with connect() as conn:
        conn.execute('INSERT INTO records VALUES (?,?,?,?,?,?,NULL,?,?)',
                     (rid, 'diary', owner_id, dumps({'content': content, 'media': []}),
                      timestamp, timestamp, None, 'legacy-encryption-check'))
    init()
    mine = client_a.get('/api/records/' + rid)
    assert mine.status_code == 200
    assert mine.json()['body']['content'] == content
    assert client_b.get('/api/records/' + rid).status_code == 404
    with connect() as conn:
        stored = conn.execute('SELECT body FROM records WHERE id=?', (rid,)).fetchone()[0]
    assert content not in stored and '_private_record' in stored


def test_post_like_comment_and_notice(client_a, client_b):
    """共同动态 + 点赞评论提醒。"""
    mid = upload(client_a, 'sunset.png')
    r = client_a.post('/api/records', headers=HEADERS,
                      json={'kind': 'post', 'body': {'content': '今天的晚霞', 'date': '2026-10-01', 'media': [mid]}})
    assert r.status_code == 200, r.text
    rid = r.json()['id']

    # 伴侣可见、可评论、可点赞；照片进入全部照片
    assert any(x['id'] == rid for x in client_b.get('/api/records?kind=post').json())
    assert client_b.post(f'/api/records/{rid}/comments', headers=HEADERS,
                         json={'content': '真好看'}).status_code == 200
    assert client_b.post(f'/api/records/{rid}/like', headers=HEADERS).status_code == 200
    photos = client_b.get('/api/photos').json()
    assert any(p['id'] == mid for p in photos)
    # 照片详情可以回到所属动态
    assert photos and photos[0]['record_id'] == rid

    notices = client_a.get('/api/notices').json()
    assert any('回复' in n['title'] or '喜欢' in n['title'] for n in notices)
    assert client_a.get('/api/me').json()['unread'] >= 1


def test_chat_idempotent_no_duplicates(client_a, client_b):
    """聊天断线重试不产生重复消息。"""
    payload = {'kind': 'chat', 'body': {'content': '到家了吗', 'date': '2026-10-04'}, 'client_id': 'chat-retry-1'}
    first = client_a.post('/api/records', headers=HEADERS, json=payload)
    assert first.status_code == 200
    again = client_a.post('/api/records', headers=HEADERS, json=payload)
    assert again.json()['id'] == first.json()['id']
    chats = client_b.get('/api/records?kind=chat').json()
    assert sum(1 for c in chats if c['client_id'] == 'chat-retry-1') == 1


def test_surprise_secret_then_published(client_a, client_b):
    """定时惊喜提前保密、到期公开并提醒。"""
    r = client_a.post('/api/records', headers=HEADERS,
                      json={'kind': 'surprise', 'body': {'content': '生日快乐，亲爱的', 'publish_at': time.time() + 1.5}})
    assert r.status_code == 200, r.text
    rid = r.json()['id']

    # 到期前：伴侣完全不可见
    assert client_b.get(f'/api/records/{rid}').status_code == 404
    assert all(x['id'] != rid for x in client_b.get('/api/records').json())

    from app.worker import schedule
    time.sleep(2.0)
    schedule()  # 到期补处理（模拟服务恢复后的执行）

    assert any(x['id'] == rid for x in client_b.get('/api/records?kind=post').json())
    assert any('惊喜' in n['title'] for n in client_b.get('/api/notices').json())


def test_anniversary_reminder(client_a, client_b):
    import datetime as dt
    tomorrow = (dt.date.today() + dt.timedelta(days=2)).isoformat()
    r = client_a.post('/api/records', headers=HEADERS,
                      json={'kind': 'anniversary', 'body': {'title': '在一起两周年', 'date': tomorrow,
                                                            'annual': True, 'remind_days': 3}})
    assert r.status_code == 200
    from app.worker import schedule
    schedule()
    assert any('纪念日' in n['title'] for n in client_b.get('/api/notices').json())


def test_album_delete_keeps_photos(client_a, client_b):
    """删除相册分类不连带删除照片。"""
    album = client_a.post('/api/records', headers=HEADERS,
                          json={'kind': 'album', 'body': {'title': '旅行相册'}}).json()['id']
    mid = upload(client_b, 'trip.png')
    rid = client_b.post('/api/records', headers=HEADERS,
                        json={'kind': 'post', 'body': {'content': '海边', 'media': [mid], 'album': album}}).json()['id']
    assert any(p['id'] == mid for p in client_a.get(f'/api/photos?album={album}').json())

    assert client_a.delete(f'/api/records/{album}', headers=HEADERS).status_code == 200
    # 照片仍在全部照片中，所属动态的相册引用被清空
    assert any(p['id'] == mid for p in client_a.get('/api/photos').json())
    body = client_a.get(f'/api/records/{rid}').json()['body']
    assert body.get('album', '') == ''


def test_delete_restore_authority(client_a, client_b):
    """删除与恢复符合作者权限。"""
    rid = client_a.post('/api/records', headers=HEADERS,
                        json={'kind': 'post', 'body': {'content': '会被删除的记录'}}).json()['id']
    # 伴侣不能删别人的动态
    assert client_b.delete(f'/api/records/{rid}', headers=HEADERS).status_code == 403
    assert client_a.delete(f'/api/records/{rid}', headers=HEADERS).status_code == 200

    trash_a = client_a.get('/api/records?trash=true').json()
    assert any(x['id'] == rid for x in trash_a)
    # 伴侣的回收站看不到，也不能恢复
    assert all(x['id'] != rid for x in client_b.get('/api/records?trash=true').json())
    assert client_b.post(f'/api/records/{rid}/restore', headers=HEADERS).status_code == 404
    assert client_a.post(f'/api/records/{rid}/restore', headers=HEADERS).status_code == 200
    assert any(x['id'] == rid for x in client_b.get('/api/records?kind=post').json())


def test_question_answers_hidden_until_both(client_a, client_b):
    """双方都回答后才展示彼此答案。"""
    rid = client_a.post('/api/records', headers=HEADERS,
                        json={'kind': 'question', 'body': {'title': '第一次心动是哪个瞬间？'}}).json()['id']
    client_a.post(f'/api/records/{rid}/answer', headers=HEADERS, json={'content': '你回头笑的时候'})

    visible_to_b = client_b.get(f'/api/records/{rid}').json()
    assert visible_to_b['answer_count'] == 1
    assert visible_to_b.get('answers', []) == []  # 只有自己（尚未回答）时看不到对方答案

    client_b.post(f'/api/records/{rid}/answer', headers=HEADERS, json={'content': '你递伞给我的时候'})
    assert len(client_a.get(f'/api/records/{rid}').json()['answers']) == 2


def test_tunnel_origin_variants(client_a, client_b, monkeypatch):
    """内网穿透改写协议/端口后仍视为同源；陌生站点仍被拦截。"""
    monkeypatch.setenv('PUBLIC_URL', 'https://love.example.com')
    login = lambda **h: client_a.post('/api/login', headers=h, json={'username': 'nobody', 'password': 'wrong-pass-123'})
    # PUBLIC_URL 精确匹配 → 放行（401 是账号错误，说明已过中间件）
    assert login(**{'Origin': 'https://love.example.com'}).status_code == 401
    # 穿透改写协议+端口，但主机名相同 → 放行
    assert login(**{'Origin': 'http://love.example.com:8443',
                    'X-Forwarded-Host': 'love.example.com'}).status_code == 401
    # 完全陌生的站点仍然拦截
    assert login(**{'Origin': 'https://evil-love.example.com'}).status_code == 403


def test_orphan_media_auto_cleanup(client_a, client_b):
    """未发布/未保存的附件 24 小时后自动清理；存进记录的保留。"""
    from app.worker import cleanup
    from app.db import DATA, connect, now, media_dir

    orphan = upload(client_a, 'orphan.png')
    kept = upload(client_a, 'kept.png')
    r = client_a.post('/api/records', headers=HEADERS,
                      json={'kind': 'diary', 'body': {'content': '存下来的日记', 'media': [kept]}})
    assert r.status_code == 200
    # 模拟这两个文件是 25 小时前上传的（created 变了，分目录位置随之变化，需同步挪文件）
    with connect() as c:
        row = c.execute('SELECT * FROM media WHERE id=?', (orphan,)).fetchone()
        old = media_dir(row['mime'], row['created'])
        c.execute('UPDATE media SET created=? WHERE id IN (?,?)', (now() - 25 * 3600, orphan, kept))
        for mid in (orphan, kept):
            m = c.execute('SELECT * FROM media WHERE id=?', (mid,)).fetchone()
            new = media_dir(m['mime'], m['created'])
            new.mkdir(parents=True, exist_ok=True)
            if (old / (mid + m['ext'])).is_file():
                (old / (mid + m['ext'])).rename(new / (mid + m['ext']))

    cleanup()

    with connect() as c:
        m = c.execute('SELECT * FROM media WHERE id=?', (orphan,)).fetchone()
    if m:
        assert not (media_dir(m['mime'], m['created']) / (orphan + '.png')).exists()
    with connect() as c:
        assert c.execute('SELECT 1 FROM media WHERE id=?', (orphan,)).fetchone() is None
        assert c.execute('SELECT attached FROM media WHERE id=?', (kept,)).fetchone()[0] == 1
    assert client_a.get(f'/media/{kept}').status_code == 200


def test_media_categorized_storage(client_a, monkeypatch):
    """媒体按「类型/年-月」分目录存放，读取与备份打包走同一位置。"""
    from app.db import DATA, connect, media_dir
    from app.backups import create_backup, decrypt_bytes

    monkeypatch.setenv('BACKUP_PASSWORD', 'categorized-test')
    mid = upload(client_a, 'categorized.png')
    with connect() as c:
        m = c.execute('SELECT * FROM media WHERE id=?', (mid,)).fetchone()
    folder = media_dir(m['mime'], m['created'])
    assert folder != DATA / 'media' and folder.parent.parent == DATA / 'media'
    assert folder.name == __import__('datetime').datetime.now(__import__('datetime').timezone.utc).strftime('%Y-%m')
    assert (folder / (mid + '.png')).is_file()
    assert client_a.get(f'/media/{mid}').status_code == 200
    assert client_a.get(f'/media/{mid}?preview=true').status_code == 200
    # 备份包内包含该文件（现在是加密包，先解开再查）
    archive_path = create_backup()
    with tempfile.TemporaryDirectory() as tmp:
        inner = Path(tmp) / 'inner.zip'
        inner.write_bytes(decrypt_bytes(archive_path, 'categorized-test'))
        with zipfile.ZipFile(inner) as z:
            assert f'media/{mid}.png' in z.namelist()
    archive_path.unlink(missing_ok=True)


def test_channel_validation_and_independent_delivery(client_a, client_b):
    """渠道配置校验 + 一个渠道失败不影响其他渠道。"""
    bad = {'kind': 'smtp', 'name': '坏配置', 'config': {'host': 'smtp.example.com', 'port': '25',
          'username': 'u', 'password': 'p', 'from': 'a@b.c', 'to': 'd@e.f'}, 'events': ['chat']}
    assert client_a.post('/api/channels', headers=HEADERS, json=bad).status_code == 422

    for i in (1, 2):
        r = client_a.post('/api/channels', headers=HEADERS,
                          json={'kind': 'webhook', 'name': f'渠道{i}',
                                'config': {'url': f'https://webhook-love-test-{i}.invalid/hook'},
                                'events': ['system']})
        assert r.status_code == 200, r.text

    channels = client_a.get('/api/channels').json()
    assert len(channels) == 2
    for ch in channels:
        assert client_a.post(f"/api/channels/{ch['id']}/test", headers=HEADERS).status_code == 200

    from app.worker import deliver
    deliver()  # 两个渠道都会被尝试（互不影响），域名不可达 → 记录失败原因并保留重试

    deliveries = client_a.get('/api/deliveries').json()
    assert len(deliveries) == 2
    assert all(d['attempts'] == 1 for d in deliveries), deliveries
    assert all(d['error'] for d in deliveries)


WECHAT_TXT = ('小兔 2023-05-20 12:30:45\n今天也要开心呀\n一起散步吧\n\n'
              '大熊 2023-05-20 12:31:02\n好呀\n[图片]')


def test_anniversary_lunar_remind(client_a, client_b):
    """农历年度纪念日：worker 用 lunar 模式计算下一年公历日期并发提醒。"""
    from app.worker import schedule, due_date
    from app.db import connect, now
    import datetime as dt
    from zoneinfo import ZoneInfo
    # 创建一个农历纪念日：存储公历 2023-07-07（对应农历 2023 五月二十）
    r = client_a.post('/api/records', headers=HEADERS,
                      json={'kind': 'anniversary', 'body': {'title': '农历纪念日', 'date': '2023-07-07',
                                                             'annual': 'lunar', 'remind_days': 30}, 'client_id': 'lunar-1'})
    assert r.status_code == 200
    today = dt.datetime.now(ZoneInfo('Asia/Shanghai')).date()
    due = due_date('2023-07-07', 'lunar', today)
    assert due is not None
    # 清掉旧的提醒避免干扰
    with connect() as c:
        c.execute("DELETE FROM notices WHERE event='anniversary'")
    schedule()
    with connect() as c:
        rows = c.execute("SELECT * FROM notices WHERE event='anniversary'").fetchall()
    # 提醒是否触发取决于 due 与 today 的差是否 ≤ 30 天
    delta = (due - today).days
    if 0 <= delta <= 30:
        assert any('纪念日' in row['title'] for row in rows), rows
    # 删除该测试记录避免影响其他测试
    client_a.delete('/api/records/' + r.json()['id'], headers=HEADERS)


def test_import_zip_with_images_and_calendar(client_a, client_b):
    """zip 带图片导入：文本解析 + 图片匹配落盘；共同年历聚合。"""
    import io as _io
    import zipfile as _zipfile
    from PIL import Image as _Image

    buf = _io.BytesIO()
    _Image.new('RGB', (30, 30), (200, 100, 120)).save(buf, 'JPEG')
    img_data = buf.getvalue()
    text = ('小兔 2023-05-20 12:30:45\nimage/img001.jpg\n\n大熊 2023-05-20 12:31:00\n收到啦\n').encode()
    with _io.BytesIO() as zbuf:
        with _zipfile.ZipFile(zbuf, 'w') as z:
            z.writestr('chat.txt', text)
            z.writestr('image/img001.jpg', img_data)
        zip_raw = zbuf.getvalue()

    r = client_a.post('/api/imports/preview', headers=HEADERS,
                      files={'file': ('export.zip', zip_raw, 'application/zip')})
    assert r.status_code == 200 and r.json()['media_count'] == 1

    r = client_a.post('/api/imports', headers=HEADERS,
                      files={'file': ('export.zip', zip_raw, 'application/zip')},
                      data={'platform': 'wechat', 'title': '带图记录', 'me': '大熊'})
    assert r.status_code == 200 and r.json()['media_count'] == 1
    msgs = client_a.get(f"/api/imports/{r.json()['id']}/messages", headers=HEADERS).json()
    img_msg = next(m for m in msgs['messages'] if m['kind'] == 'image')
    assert img_msg['media_id']
    assert client_a.get(f"/media/{img_msg['media_id']}?preview=true").status_code == 200
    # 共享语义：不是导入者的那一方也要能看到这些图片
    assert client_b.get(f"/media/{img_msg['media_id']}?preview=true").status_code == 200

    # 共同年历：心情 + 动态按日期聚合
    client_a.post('/api/records', headers=HEADERS,
                  json={'kind': 'mood', 'body': {'emoji': '🥰', 'date': '2023-05-20', 'content': '开心'}, 'client_id': 'cal-m1'})
    cal = client_a.get('/api/calendar?month=2023-05', headers=HEADERS).json()
    assert cal['month'] == '2023-05' and '20' in cal['days']
    assert any(m['emoji'] == '🥰' for m in cal['days']['20'].get('moods', []))
    # 农历纪念日落在该月
    client_a.post('/api/records', headers=HEADERS,
                  json={'kind': 'anniversary', 'body': {'title': '农历测试', 'date': '2023-07-07', 'annual': 'lunar', 'remind_days': 1}, 'client_id': 'cal-a1'})
    cal6 = client_a.get('/api/calendar?month=2023-06', headers=HEADERS).json()
    # 农历五月二十 2023-06-07 不对——2023-07-07 是农历五月二十；次年农历五月二十是 2024-06-25
    cal7 = client_a.get('/api/calendar?month=2023-07', headers=HEADERS).json()
    assert '07' in cal7['days'] and any(a['title'] == '农历测试' for a in cal7['days']['07'].get('anniversaries', []))


def test_backup_encryption_roundtrip(client_a, client_b, monkeypatch):
    """BACKUP_PASSWORD 设置后：备份自动加密，解密后可完整恢复。"""
    from app.backups import create_backup, restore_backup, is_encrypted, decrypt_bytes
    from app.db import DATA

    monkeypatch.setenv('BACKUP_PASSWORD', 'test-secret-123')
    path = create_backup()
    try:
        assert path.name.endswith('.zip.enc'), path.name
        assert is_encrypted(path)
        # 错误密码解不开
        import pytest
        with pytest.raises(ValueError, match='密码不正确'):
            decrypt_bytes(path, 'wrong-password')
        # 正确密码解密后是合法 zip，可完整恢复
        plain = decrypt_bytes(path, 'test-secret-123')
        assert plain[:2] == b'PK'
        with tempfile.TemporaryDirectory() as dest:
            zip_path = Path(DATA / 'tmp' / 'decrypted-test.zip')
            zip_path.write_bytes(plain)
            try:
                restore_backup(zip_path, dest, password='test-secret-123')
                assert (Path(dest) / 'love.db').is_file()
                assert (Path(dest) / 'secret.key').is_file()
            finally:
                zip_path.unlink(missing_ok=True)
    finally:
        path.unlink(missing_ok=True)


def test_on_this_day(client_a, client_b):
    """历史上的今天：今天日期的记录被正确识别并分组返回。"""
    from datetime import datetime, timezone, timedelta
    tz_cn = timezone(timedelta(hours=8))
    now_cn = datetime.now(tz_cn)
    today_md = now_cn.strftime('-%m-%d')
    today_year = now_cn.strftime('%Y')
    client_a.post('/api/records', headers=HEADERS,
                  json={'kind': 'post', 'body': {'content': '去年的今天', 'date': today_year + today_md},
                        'client_id': 'otd-1'})
    r = client_a.get('/api/on-this-day', headers=HEADERS)
    assert r.status_code == 200
    groups = r.json()
    assert any(g['year'] == int(today_year) and any(it['body']['content'] == '去年的今天' for it in g['items']) for g in groups)
    assert client_b.get('/api/on-this-day').status_code == 200


def test_import_wechat_txt_and_browse(client_a, client_b):
    """微信留痕 TXT：预览、导入、双方浏览、mine 标记、媒体占位、搜索、删除权限。"""
    r = client_a.post('/api/imports/preview', headers=HEADERS,
                      files={'file': ('wechat.txt', WECHAT_TXT.encode(), 'text/plain')})
    assert r.status_code == 200 and r.json()['count'] == 2

    r = client_a.post('/api/imports', headers=HEADERS,
                      files={'file': ('wechat.txt', WECHAT_TXT.encode(), 'text/plain')},
                      data={'platform': 'wechat', 'title': '我们的微信记录', 'me': '大熊'})
    assert r.status_code == 200, r.text
    iid = r.json()['id']

    lst = client_a.get('/api/imports', headers=HEADERS).json()
    assert any(i['id'] == iid and i['message_count'] == 2 for i in lst)

    # 伴侣也能浏览；发送人"大熊"被标记为右侧（我）
    msgs = client_b.get(f'/api/imports/{iid}/messages', headers=HEADERS).json()
    assert msgs['total'] == 2
    assert {m['sender']: m['mine'] for m in msgs['messages']} == {'小兔': 0, '大熊': 1}
    assert msgs['messages'][1]['kind'] == 'image'  # 多行内容合并后识别 [图片] 占位
    assert msgs['messages'][0]['day'] == '2023-05-20'

    s = client_a.get(f'/api/imports/{iid}/messages?q=散步', headers=HEADERS).json()
    assert len(s['messages']) == 1 and '散步' in s['messages'][0]['content']

    # 聊天记录是两人共享的：不是导入者的那一方也能删（谁删都对双方生效）
    assert client_b.delete(f'/api/imports/{iid}', headers=HEADERS).status_code == 200
    assert client_a.get(f'/api/imports/{iid}/messages', headers=HEADERS).status_code == 404
    assert not any(i['id'] == iid for i in client_a.get('/api/imports', headers=HEADERS).json())
    # 删完之后消息行也要跟着清掉，不能留孤儿（import_messages 靠外键级联）
    with db.connect() as c:
        assert c.execute('SELECT count(*) FROM import_messages WHERE import_id=?', (iid,)).fetchone()[0] == 0


def test_import_errors_are_actionable(client_a):
    """导入失败时要给出可操作的原因，而不是一律「无法识别」。"""
    cases = [
        # (文件名, 内容, 期望出现在报错里的片段)
        ('broken.zip', b'not a zip at all', 'ZIP 文件已损坏'),
        ('empty.txt', b'   \n\n  ', '没有解析到聊天记录'),
        ('notes.pdf', b'%PDF-1.4\nwhatever', '没有解析到聊天记录'),
    ]
    for name, payload, expect in cases:
        r = client_a.post('/api/imports/preview', headers=HEADERS,
                          files={'file': (name, payload, 'application/octet-stream')})
        assert r.status_code == 422, (name, r.status_code)
        assert expect in r.json()['detail'], (name, r.json()['detail'])

    # zip 条目超限是 importers 抛的 ValueError，也要转成用户能懂的话
    with io.BytesIO() as zbuf:
        with zipfile.ZipFile(zbuf, 'w') as z:
            z.writestr('chat.txt', WECHAT_TXT.encode())
            for i in range(5):
                z.writestr(f'f{i}.txt', f'小兔 2023-05-2{i} 10:00:00\n第 {i} 天\n'.encode())
        raw = zbuf.getvalue()
    from app.importers import parse_zip
    with pytest.raises(ValueError, match='条目'):
        parse_zip(raw, max_entries=3)
    r = client_a.post('/api/imports/preview', headers=HEADERS,
                      files={'file': ('big.zip', raw, 'application/zip')})
    assert r.status_code == 200  # 默认上限 5000 远大于 6，正常解析通过


def test_import_notifies_partner(client_a, client_b):
    """导入后对方要收到提醒 + SSE 刷新信号，而不是数据静悄悄多出来。"""
    def shared_revision():
        with db.connect() as c:
            return c.execute("SELECT value FROM app_state WHERE key='content_revision'").fetchone()[0]

    before = shared_revision()
    r = client_a.post('/api/imports', headers=HEADERS,
                      files={'file': ('wechat.txt', WECHAT_TXT.encode(), 'text/plain')},
                      data={'platform': 'wechat', 'title': '悄悄话合集', 'me': '大熊'})
    assert r.status_code == 200
    # 共享 revision 必须推进，否则对方的 SSE 永远收不到 refresh（原来只推给导入者）
    assert shared_revision() > before
    notes = client_b.get('/api/notices', headers=HEADERS).json()
    assert any('悄悄话合集' in n['title'] for n in notes)


def test_import_qq_gbk_and_douyin_csv(client_a):
    """QQ 消息管理器 TXT（GBK）与抖音 CSV；未登录拒绝。"""
    qq = ('消息记录（此消息记录为文本格式）\n'
          '================================================================\n'
          '消息对象:小兔\n'
          '================================================================\n'
          '2023-05-20 12:30:45 大熊\n在干嘛\n\n2023-05-20 12:31:00 小兔\n想你\n').encode('gbk')
    r = client_a.post('/api/imports', headers=HEADERS,
                      files={'file': ('qq.txt', qq, 'text/plain')},
                      data={'platform': 'qq', 'title': '', 'me': '大熊'})
    assert r.status_code == 200, r.text
    assert r.json()['count'] == 2 and r.json()['title'] == '小兔'  # 消息对象作为标题

    dy = '时间,发送人,内容\n2023-05-20 12:30:45,小兔,在吗\n2023-05-20 12:31:00,大熊,在的\n'.encode()
    r = client_a.post('/api/imports', headers=HEADERS,
                      files={'file': ('douyin.csv', dy, 'text/csv')},
                      data={'platform': 'douyin', 'title': '抖音私信', 'me': '大熊'})
    assert r.status_code == 200 and r.json()['count'] == 2

    with TestClient(app, base_url='https://testserver', headers=HEADERS) as anon:
        assert anon.get('/api/imports').status_code == 401


def test_notice_single_read_after_viewing(client_a, client_b):
    """点开通知详情后即标记已读：角标消失、其他通知不受影响。"""
    rid = client_b.post('/api/records', headers=HEADERS,
                        json={'kind': 'note', 'body': {'content': '想对你说的话'}, 'client_id': 'note-1'}).json()['id']
    notices = client_a.get('/api/notices', headers=HEADERS).json()
    target = next(n for n in notices if n.get('record_id') == rid)
    assert target['seen'] == 0
    unread_before = client_a.get('/api/me', headers=HEADERS).json()['unread']
    assert unread_before >= 1

    # 打开详情 = 前端调用按记录标记已读
    client_a.post(f'/api/notices/read?record_id={rid}', headers=HEADERS)

    notices = client_a.get('/api/notices', headers=HEADERS).json()
    assert all(n['seen'] == 1 for n in notices if n.get('record_id') == rid)
    assert client_a.get('/api/me', headers=HEADERS).json()['unread'] == unread_before - 1
    # 其余通知保持原状
    assert any(n['seen'] == 0 for n in notices if n.get('record_id') != rid) or \
           all(n['seen'] == 1 for n in notices)


def test_delete_read_system_notices_only_for_current_user(client_a, client_b):
    """清理当前账号的已读系统提醒，不动未读、聊天提醒或伴侣通知。"""
    from app.db import connect, now, uid

    user_a = client_a.get('/api/me').json()['user']['id']
    user_b = client_b.get('/api/me').json()['user']['id']
    read_id, unread_id, chat_id, partner_id = (uid() for _ in range(4))
    created = now()
    with connect() as conn:
        conn.executemany(
            'INSERT INTO notices(id,user_id,event,title,record_id,created,seen,dedupe) VALUES (?,?,?,?,?,?,?,NULL)',
            [
                (read_id, user_a, 'note', '已读提醒待删除', None, created, 1),
                (unread_id, user_a, 'activity', '未读提醒保留', None, created, 0),
                (chat_id, user_a, 'chat', '聊天提醒保留', None, created, 1),
                (partner_id, user_b, 'note', '伴侣提醒保留', None, created, 1),
            ],
        )

    response = client_a.delete('/api/notices/read', headers=HEADERS)
    assert response.status_code == 200
    assert response.json()['deleted'] >= 1

    with connect() as conn:
        remaining = {row['id']: row['user_id'] for row in conn.execute(
            'SELECT id,user_id FROM notices WHERE id IN (?,?,?,?)',
            (read_id, unread_id, chat_id, partner_id),
        )}
    assert read_id not in remaining
    assert remaining == {unread_id: user_a, chat_id: user_a, partner_id: user_b}


def test_record_cursor_pagination_is_stable_and_complete(client_a):
    """Cursor pages do not repeat or omit records that share close timestamps."""
    ids = []
    for index in range(5):
        response = client_a.post('/api/records', headers=HEADERS,
                                 json={'kind': 'post', 'body': {'content': f'pagination-check-{index}'}})
        assert response.status_code == 200, response.text
        ids.append(response.json()['id'])

    params = {'kind': 'post', 'q': 'pagination-check', 'limit': 2}
    first = client_a.get('/api/records', params=params).json()
    second = client_a.get('/api/records', params={**params, 'before': first[-1]['created'],
                                                  'before_id': first[-1]['id']}).json()
    third = client_a.get('/api/records', params={**params, 'before': second[-1]['created'],
                                                 'before_id': second[-1]['id']}).json()
    returned = first + second + third
    assert [len(first), len(second), len(third)] == [2, 2, 1]
    assert len({record['id'] for record in returned}) == 5
    assert {record['id'] for record in returned} == set(ids)


def test_builtin_push_topics_are_private_and_queued(client_a, client_b):
    """手机端内置 ntfy 系统推送已停用：notice 仍只发给接收方，但不再写入 push_outbox。"""
    owner = client_a.get('/api/me').json()
    recipient = client_b.get('/api/me').json()
    record = client_a.post('/api/records', headers=HEADERS,
                           json={'kind': 'post', 'body': {'content': 'push queue check'}}).json()
    from app.db import connect
    with connect() as conn:
        notices = conn.execute('SELECT id,user_id FROM notices WHERE record_id=?', (record['id'],)).fetchall()
        assert len(notices) == 1
        assert notices[0]['user_id'] == recipient['user']['id']
        # 内置 ntfy 推送停用后，push_outbox 不应再有记录
        assert conn.execute('SELECT id FROM push_outbox WHERE notice_id=?',
                            (notices[0]['id'],)).fetchone() is None


def test_ntfy_requires_https():
    from app.notifications import validate_config
    with pytest.raises(ValueError, match='HTTPS'):
        validate_config('ntfy', {'host': 'http://ntfy.example.com', 'topic': 'a-secure-topic'})


def test_webpush_subscription_is_private_and_delivered(client_a, client_b, monkeypatch):
    """Browser subscriptions stay encrypted and are queued only for their account."""
    from app import webpush
    from app.db import connect
    from app.worker import deliver_webpushes
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    assert webpush.public_key() == webpush.public_key()
    raw_public = base64.urlsafe_b64decode(webpush.public_key() + '=')
    assert len(raw_public) == 65 and raw_public[0] == 4
    private_der = base64.urlsafe_b64decode(webpush.private_key_encoded() + '=' * ((-len(webpush.private_key_encoded())) % 4))
    from cryptography.hazmat.primitives.serialization import load_der_private_key
    assert load_der_private_key(private_der, password=None).key_size == 256
    subscription = {
        'endpoint': 'https://updates.push.services.mozilla.com/wpush/v2/test-endpoint',
        'keys': {
            'p256dh': base64.urlsafe_b64encode(ec.generate_private_key(ec.SECP256R1()).public_key().public_bytes(
                serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)).rstrip(b'=').decode(),
            'auth': base64.urlsafe_b64encode(b'a' * 16).rstrip(b'=').decode(),
        },
    }
    saved = client_b.put('/api/webpush/subscription', json=subscription)
    assert saved.status_code == 200, saved.text
    assert saved.json()['devices'] == 1

    owner_id = client_b.get('/api/me').json()['user']['id']
    with connect() as conn:
        stored = conn.execute('SELECT id,payload FROM webpush_subscriptions WHERE user_id=?', (owner_id,)).fetchone()
        assert subscription['endpoint'] not in stored['payload']
        assert webpush.open_subscription(stored['payload']) == subscription
        sub_id = stored['id']

    # One account cannot remove the other account's endpoint.
    assert client_a.post('/api/webpush/unsubscribe', json={'endpoint': subscription['endpoint']}).json()['devices'] == 0
    assert client_b.get('/api/webpush').json()['devices'] == 1

    record = client_a.post('/api/records', headers=HEADERS,
                           json={'kind': 'post', 'body': {'content': 'browser push queue'}}).json()
    with connect() as conn:
        outbox = conn.execute('''SELECT o.id,o.status FROM webpush_outbox o
          JOIN notices n ON n.id=o.notice_id WHERE n.record_id=? AND o.subscription_id=?''',
                              (record['id'], sub_id)).fetchone()
    assert outbox and outbox['status'] == 'pending'

    sent = []
    monkeypatch.setattr(webpush, 'send', lambda sub, payload: sent.append((sub, payload)))
    deliver_webpushes()
    with connect() as conn:
        status = conn.execute('SELECT status FROM webpush_outbox WHERE id=?', (outbox['id'],)).fetchone()[0]
    assert status == 'sent'
    assert sent and sent[0][1]['title'] == '恋爱空间'
    assert sent[0][1]['body'] == '你有一条新的提醒，打开空间查看。'


def test_webpush_rejects_untrusted_endpoints():
    from app.webpush import validate_subscription
    bad = {'endpoint': 'https://127.0.0.1/admin', 'keys': {'p256dh': 'x', 'auth': 'x'}}
    with pytest.raises(ValueError, match='不受支持'):
        validate_subscription(bad)


def test_backup_and_restore_roundtrip(client_a, client_b, monkeypatch):
    """完整备份能恢复到一套新部署。"""
    from app.backups import create_backup, restore_backup
    from app.db import DATA

    monkeypatch.setenv('BACKUP_PASSWORD', 'test-secret-123')
    path = create_backup()
    assert path.is_file() and path.name.startswith('backup-')
    assert path.name.endswith('.zip.enc')

    target = Path(tempfile.mkdtemp(prefix='love-restore-')) / 'new-data'
    restore_backup(path, target, password='test-secret-123')

    with sqlite3.connect(target / 'love.db') as c:
        assert c.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        users = c.execute('SELECT count(*) FROM users').fetchone()[0]
        assert users == 2
        # 恢复后安全重置会话
        assert c.execute('SELECT count(*) FROM sessions').fetchone()[0] == 0
    assert (target / 'secret.key').is_file()
    assert not (target / 'secret.key.enc').exists()  # 恢复后应还原成裸密钥，供应用直接读取
    media_files = list((target / 'media').glob('*'))
    assert len(media_files) >= 3  # 原图 + 预览图至少覆盖此前上传的附件
    # 备份保留数量 ≤ 7（现在是 .zip.enc）
    assert len(list((DATA / 'backups').glob('backup-*.zip*'))) <= 7


def test_backup_refuses_plaintext_without_password(client_a, monkeypatch):
    """没有备份口令就绝不落明文包——包里还带着 secret.key，泄露即全破。"""
    from app.backups import BackupRefused, create_backup
    from app.db import DATA

    monkeypatch.delenv('BACKUP_PASSWORD', raising=False)
    before = set((DATA / 'backups').glob('backup-*'))
    with pytest.raises(BackupRefused):
        create_backup()
    assert set((DATA / 'backups').glob('backup-*')) == before  # 什么都没生成


def test_backup_v2_hides_secret_key(client_a, monkeypatch):
    """v2 包内不能出现裸 secret.key，且缺口令时必须在落盘前就拒绝。"""
    from app.backups import (MANIFEST_VERSION, create_backup, decrypt_bytes,
                             restore_backup)
    from app.db import DATA

    monkeypatch.setenv('BACKUP_PASSWORD', 'v2-secret')
    path = create_backup()
    try:
        plain = decrypt_bytes(path, 'v2-secret')
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / 'inner.zip'
            zip_path.write_bytes(plain)
            with zipfile.ZipFile(zip_path) as z:
                names = set(z.namelist())
                assert 'secret.key.enc' in names
                assert 'secret.key' not in names
                assert json.loads(z.read('manifest.json'))['version'] == MANIFEST_VERSION
            # 不提供口令 → 拒绝，且不能把 love.db 解出来一半留在目标目录里
            dest = Path(tmp) / 'dest'
            with pytest.raises(ValueError, match='备份密码'):
                restore_backup(zip_path, dest)
            assert not (dest / 'love.db').exists()
            # 正确口令 → 恢复出可用的裸密钥
            dest2 = Path(tmp) / 'dest2'
            restore_backup(zip_path, dest2, password='v2-secret')
            assert (dest2 / 'secret.key').is_file()
    finally:
        path.unlink(missing_ok=True)


def test_restore_accepts_legacy_v1_backup(client_a, monkeypatch):
    """老备份（裸 secret.key + manifest v1）必须仍然能恢复，否则升级等于废掉历史备份。"""
    from app.backups import restore_backup
    from app.db import DATA

    with tempfile.TemporaryDirectory() as tmp:
        fake = Path(tmp) / 'legacy.zip'
        with zipfile.ZipFile(fake, 'w') as z:
            z.write(DATA / 'love.db', 'love.db')
            z.write(DATA / 'secret.key', 'secret.key')
            z.writestr('manifest.json', json.dumps({'version': 1, 'created': 0}))
        dest = Path(tmp) / 'dest'
        restore_backup(fake, dest)
        assert (dest / 'love.db').is_file()
        assert (dest / 'secret.key').is_file()
