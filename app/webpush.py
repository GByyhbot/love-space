"""Browser Web Push helpers. The signing key is deterministically derived from
the backed-up application secret, so restores keep existing subscriptions valid.
"""
import base64
import hashlib
import json
from urllib.parse import urlparse

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from .security import PURPOSE_WEBPUSH_SUB, cipher, decrypt_with_fallback, secret_key

_P256_ORDER = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551


def _b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b'=').decode('ascii')


def _private_key():
    seed = HKDF(algorithm=hashes.SHA256(), length=32, salt=None,
                info=b'love-space:web-push-vapid:v1').derive(secret_key())
    scalar = int.from_bytes(seed, 'big') % (_P256_ORDER - 1) + 1
    return ec.derive_private_key(scalar, ec.SECP256R1())


def public_key():
    point = _private_key().public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return _b64url(point)


def private_key_encoded():
    der = _private_key().private_bytes(serialization.Encoding.DER,
                                        serialization.PrivateFormat.PKCS8,
                                        serialization.NoEncryption())
    return _b64url(der)


def endpoint_hash(endpoint):
    return hashlib.sha256(endpoint.encode('utf-8')).hexdigest()


def _decode_key(value, expected_lengths, label):
    if not isinstance(value, str) or len(value) > 256:
        raise ValueError(f'{label} 格式不正确')
    try:
        raw = base64.b64decode(value + '=' * (-len(value) % 4), altchars=b'-_', validate=True)
    except Exception as exc:
        raise ValueError(f'{label} 格式不正确') from exc
    if len(raw) not in expected_lengths or _b64url(raw) != value:
        raise ValueError(f'{label} 格式不正确')
    return value


def validate_subscription(value):
    if not isinstance(value, dict):
        raise ValueError('浏览器推送订阅格式不正确')
    endpoint = value.get('endpoint')
    parsed = urlparse(endpoint if isinstance(endpoint, str) else '')
    host = (parsed.hostname or '').lower().rstrip('.')
    trusted = (host == 'fcm.googleapis.com' or host.endswith('.push.services.mozilla.com')
               or host.endswith('.notify.windows.com') or host == 'web.push.apple.com'
               or host.endswith('.push.apple.com'))
    try:
        port_ok = parsed.port in (None, 443)
    except ValueError:
        port_ok = False
    if (not isinstance(endpoint, str) or len(endpoint) > 4096 or parsed.scheme != 'https'
            or not host or parsed.username or parsed.password or parsed.fragment or not port_ok
            or not trusted):
        raise ValueError('浏览器推送地址无效或不受支持')
    keys = value.get('keys')
    if not isinstance(keys, dict):
        raise ValueError('浏览器推送密钥缺失')
    p256dh = _decode_key(keys.get('p256dh'), {65}, '浏览器推送公钥')
    auth = _decode_key(keys.get('auth'), {16}, '浏览器推送认证密钥')
    decoded = base64.urlsafe_b64decode(p256dh + '=' * (-len(p256dh) % 4))
    try:
        ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), decoded)
    except ValueError as exc:
        raise ValueError('浏览器推送公钥格式不正确') from exc
    return {'endpoint': endpoint, 'keys': {'p256dh': p256dh, 'auth': auth}}


def seal_subscription(subscription):
    return cipher(PURPOSE_WEBPUSH_SUB).encrypt(json.dumps(subscription, separators=(',', ':')).encode()).decode('ascii')


def open_subscription(sealed):
    # 回退：用途分离之前存的订阅是用主密钥直接加密的
    return json.loads(decrypt_with_fallback(PURPOSE_WEBPUSH_SUB, sealed.encode('ascii')))


def send(subscription, payload):
    # Subscription endpoints are restricted to browser-vendor push services before
    # storage, preventing authenticated users from turning the server into an SSRF proxy.
    from pywebpush import webpush
    from .config import public_origin
    webpush(subscription_info=subscription,
            data=json.dumps(payload, ensure_ascii=False, separators=(',', ':')),
            vapid_private_key=private_key_encoded(),
            vapid_claims={'sub': public_origin() or 'mailto:love-space@example.invalid'},
            ttl=86400, timeout=10)
