import base64
import binascii
import hashlib
import hmac
import os
import secrets

from cryptography.exceptions import InvalidTag
from cryptography.fernet import Fernet, InvalidToken
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.hashes import SHA256
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from fastapi import HTTPException, Request
from .db import DATA, connect, now


def secret_key():
    path = DATA / 'secret.key'
    if not path.exists():
        try:
            with path.open('xb') as f:
                f.write(Fernet.generate_key())
            path.chmod(0o600)
        except FileExistsError:
            pass
    return path.read_bytes()


# ── 密钥用途分离 ────────────────────────────────────────────────
# 以前 cipher() 直接拿主密钥，三类密文共用一把钥匙：个人心愿的服务端副本、
# Web Push 订阅、通知渠道配置。任何一类密文出问题，另外两类跟着遭殃。
# 现在按用途各派生一把子密钥（私密记录与 VAPID 原本就已经这么做了）。
PURPOSE_OWNER_SEALED = b'love-space:owner-sealed:v1'
PURPOSE_WEBPUSH_SUB = b'love-space:webpush-subscription:v1'
PURPOSE_CHANNEL_CONFIG = b'love-space:channel-config:v1'
# 图库「AI 合成台」的 provider 配置（含各家的 API Key）：本来是纯 localStorage，
# 换设备/清缓存就得重填，用户要求存到 NAS 上，所以落 settings 表并按用途加密。
PURPOSE_POSE_AI = b'love-space:pose-ai-config:v1'


def cipher(purpose=None):
    """Fernet 加密器。

    purpose 非空 → 按用途派生独立子密钥；purpose 为空 → 直接用主密钥，
    **仅用于解用途分离之前落库的存量密文**，新的加密一律要带 purpose。
    """
    if purpose is None:
        return Fernet(secret_key())
    material = HKDF(algorithm=SHA256(), length=32, salt=None,
                    info=purpose).derive(base64.urlsafe_b64decode(secret_key()))
    return Fernet(base64.urlsafe_b64encode(material))


def decrypt_with_fallback(purpose, sealed: bytes):
    """先按新用途解，解不开再退回主密钥。

    用途分离之前写的密文是用主密钥直接加密的。没有这个回退，升级完成的那一刻
    所有历史密文都会变成永久打不开的死数据——这条路线的最大风险就在这里。
    代价：主密钥仍然是根（回退用得到它），所以这是纵深防御，不是彻底隔离。
    """
    try:
        return cipher(purpose).decrypt(sealed)
    except InvalidToken:
        return cipher().decrypt(sealed)


def password_hash(password, min_length=10):
    """账号密码默认 10 位起；个人心愿密码允许 6 位（含纯数字）以方便口头告知对方。"""
    if not isinstance(password, str) or not min_length <= len(password) <= 128:
        raise HTTPException(422, f'密码需要 {min_length}–128 个字符')
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1)
    return salt.hex() + ':' + digest.hex()


def password_ok(password, encoded):
    if not isinstance(password, str) or len(password) > 128:
        return False
    salt, digest = encoded.split(':')
    check = hashlib.scrypt(password.encode(), salt=bytes.fromhex(salt), n=16384, r=8, p=1).hex()
    return hmac.compare_digest(check, digest)


def personal_wish_encrypt(password, content):
    salt = secrets.token_bytes(16)
    nonce = secrets.token_bytes(12)
    key = PBKDF2HMAC(algorithm=SHA256(), length=32, salt=salt, iterations=600_000).derive(password.encode())
    ciphertext = AESGCM(key).encrypt(nonce, content.encode(), b'love-space:personal-wish:v1')
    encode = lambda value: base64.urlsafe_b64encode(value).decode('ascii')
    return {'salt': encode(salt), 'nonce': encode(nonce), 'ciphertext': encode(ciphertext)}


def personal_wish_decrypt(password, sealed):
    try:
        decode = lambda value: base64.urlsafe_b64decode(value.encode('ascii'))
        salt, nonce, ciphertext = decode(sealed['salt']), decode(sealed['nonce']), decode(sealed['ciphertext'])
        key = PBKDF2HMAC(algorithm=SHA256(), length=32, salt=salt, iterations=600_000).derive(password.encode())
        return AESGCM(key).decrypt(nonce, ciphertext, b'love-space:personal-wish:v1').decode()
    except (InvalidTag, KeyError, TypeError, ValueError, UnicodeDecodeError, binascii.Error):
        raise HTTPException(403, '密码不正确，请向心愿本人确认')


def private_record_encrypt(record_id, kind, value):
    """Encrypt a private record body with versioned, record-bound AES-GCM data."""
    key = HKDF(algorithm=SHA256(), length=32, salt=None,
               info=b'love-space:private-record:v1').derive(base64.urlsafe_b64decode(secret_key()))
    nonce = secrets.token_bytes(12)
    aad = f'love-space:private-record:v1:{kind}:{record_id}'.encode('utf-8')
    ciphertext = AESGCM(key).encrypt(nonce, value.encode('utf-8'), aad)
    encode = lambda item: base64.urlsafe_b64encode(item).decode('ascii')
    return {'version': 1, 'nonce': encode(nonce), 'ciphertext': encode(ciphertext)}


def private_record_decrypt(record_id, kind, sealed):
    try:
        key = HKDF(algorithm=SHA256(), length=32, salt=None,
                   info=b'love-space:private-record:v1').derive(base64.urlsafe_b64decode(secret_key()))
        decode = lambda item: base64.urlsafe_b64decode(item.encode('ascii'))
        aad = f'love-space:private-record:v1:{kind}:{record_id}'.encode('utf-8')
        return AESGCM(key).decrypt(decode(sealed['nonce']), decode(sealed['ciphertext']), aad).decode('utf-8')
    except Exception as exc:
        raise ValueError('私密记录密文无法验证；请检查服务端密钥与备份是否匹配') from exc


def seal_for_owner(content):
    """用「心愿副本」专用子密钥封存一份：作者回看自己的心愿不必再输密码，数据库仍不落明文。"""
    return cipher(PURPOSE_OWNER_SEALED).encrypt(content.encode()).decode()


def open_sealed(sealed_value):
    try:
        return decrypt_with_fallback(PURPOSE_OWNER_SEALED, str(sealed_value).encode()).decode()
    except Exception:
        raise HTTPException(422, '这份心愿的密文已失效，无法打开')


def digest_token(token):
    return hashlib.sha256(token.encode()).hexdigest()


def cookie_secure(request=None):
    """会话 cookie 的 Secure 标志按当前访问协议决定。

    公网 https → 带 Secure；局域网明文 http（192.168.x.x:1314）→ 不带。
    否则浏览器不会在 http 请求里回传 cookie，内网会表现成「登录成功了又跳回登录页」。
    SECURE_COOKIES=false 仍可整体关闭。
    """
    if os.getenv('SECURE_COOKIES', 'true').lower() != 'true':
        return False
    if request is None:
        return True
    proto = request.headers.get('x-forwarded-proto') or request.url.scheme
    return proto.split(',')[0].strip().lower() == 'https'


def login_session(c, user_id, response, request=None):
    token = secrets.token_urlsafe(32)
    c.execute('INSERT INTO sessions VALUES (?,?,?)', (digest_token(token), user_id, now() + 30 * 86400))
    response.set_cookie('love_session', token, httponly=True, samesite='strict',
                        secure=cookie_secure(request), max_age=30 * 86400)


def current_user(request: Request):
    token = request.cookies.get('love_session', '')
    with connect() as c:
        row = c.execute('SELECT u.* FROM users u JOIN sessions s ON s.user_id=u.id WHERE s.token=? AND s.expires>?',
                        (digest_token(token), now())).fetchone()
    if not row:
        raise HTTPException(401, '请先登录')
    return dict(row)


def client_ip(request):
    """真实来源 IP。

    优先级 X-Real-IP > X-Forwarded-For 末段 > request.client.host：
    - X-Real-IP 由 nginx 用 `$remote_addr` **覆盖**写入，客户端伪造的头会被丢掉，所以最可信。
      前提是 nginx 侧配了 `proxy_set_header X-Real-IP $remote_addr`（否则这个头不存在，自然走下一条）。
    - X-Forwarded-For 是逐层**追加**的，客户端可以自带一段假地址；只有在确认代理会覆盖
      而非透传时才可信。取末段是因为我们自己的代理只加这一段。
    - 部署在反向代理后面时 request.client.host 是网关地址，同住一套宽带的两人会共用一个限流桶。
    """
    real = request.headers.get('x-real-ip', '').strip()
    if real:
        return real
    forwarded = request.headers.get('x-forwarded-for', '')
    if forwarded:
        return forwarded.split(',')[-1].strip() or 'forwarded'
    return request.client.host if request.client else 'local'


def rate_limit(request, action, limit=20, window=900):
    key = action + ':' + client_ip(request)
    blocked = False
    with connect() as c:
        row = c.execute('SELECT * FROM auth_attempts WHERE key=?', (key,)).fetchone()
        if not row or now() - row['start'] > window:
            c.execute('INSERT OR REPLACE INTO auth_attempts VALUES (?,1,?)', (key, now()))
        elif row['count'] >= limit:
            blocked = True
        else:
            c.execute('UPDATE auth_attempts SET count=count+1 WHERE key=?', (key,))
    if blocked:
        minutes = max(1, window // 60)
        raise HTTPException(429, f'尝试过于频繁，请 {minutes} 分钟后再试')
