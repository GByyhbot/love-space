"""在线片源：把 NAS 上 happy-capy（:8788）这类 Capy Backend 的内容接进一起看。

那台服务本身是个**组件聚合器** —— `GET /api/v1/providers` 会列出它代理的全部内容源，
每个源都遵循同一套协议：

    /api/v1/providers/<源>/browse?category=…&page=1   → items[] + page/pageCount/total
    /api/v1/providers/<源>/search?q=…&page=1          → 同上
    /api/v1/providers/<源>/items/<id>                 → seasons[].episodes[].streamUrl
    /api/v1/stream/<签名>                              → video/mp4（红果）或 HLS（多数其它源）

所以这里不写死任何一家：服务地址由主人自己加，能用哪些源由主人自己勾。

**三层分工**（这是 2026-11 重构后的结构，别再把它们混回一坨）
  ① 契约层 `app/widgets.py`：上游字段 → 内部字段的归一化，纯函数、零状态。
     所有「猜字段」的规则只许写在那边，规范改别名时只改一处。
  ② 本文件：传输与编排 —— 请求、重试、缓存、健康度、签名分片代理。
  ③ 覆盖层 `drama_overlay`（settings 里另一张表）：本地改名/隐藏/排序/标签。
     上游负责「发现有哪些组件」，本地负责「怎么整理」，两者分开存才不会互冲。

上游 `hongguo.js` 之类只是 Capy 宿主的适配器（依赖 `Widget.*` 运行时），不是播放器，
前端完全不需要它 —— 只认本站的 `/api/dramas/…`。

**只有红果吐 mp4，其余多数是 HLS**。浏览器原生 <video> 播不了 m3u8（mpv 这类自带
解复用内核的才行），所以这层还要把播放列表里的分片/密钥/子列表 URI 改写成走本站的
签名代理，再交给前端的 hls.js 用 MSE 播。改写后的地址带 HMAC 签名，客户端无法伪造
成任意 URL —— 否则这个「分片代理」就成了一台人形 SSRF。

三个约束决定了这层必须留在服务端：

① **直链带签名且会过期**（token 里 `exp` 约 24 小时）。所以直链既不落库也不下发，
   只按「剧集号」现换现用 —— 客户端状态里只留服务、源、id 和集数。
② **服务只有内网入口**。手机在外网时连不到它，HTTPS 页面也不能直接播 http 视频。
   经本站转发后是同源，CSP 用 'self' 就够，也不必为它单独放开 media-src。
③ **服务地址是主人填的**。所以 base 要卡协议、卡长度、拒 userinfo，还要拦住回环地址，
   免得这个接口变成一台人形代理。
"""
import asyncio
import base64
import hashlib
import hmac
import ipaddress
import json
import logging
import os
import re
import threading
import time
from urllib.parse import quote, urljoin, urlsplit

import httpx

from . import db, widgets
from .security import secret_key

log = logging.getLogger('love.space')

DEFAULT_BASE = os.environ.get('CAPY_BASE', 'http://192.168.31.95:8788').rstrip('/')
DEFAULT_SERVICE_ID = 'capy'
DEFAULT_SERVICE_NAME = 'Capy'
# 没配置过的时候：只开红果一家，其余由主人自己在「管理组件」里勾
DEFAULT_ENABLED = [f'{DEFAULT_SERVICE_ID}:hongguo']

SETTING_KEY = 'drama_sources'
# 本地覆盖层：上游负责「发现有哪些组件」，这里负责「怎么整理」。两者分开存，
# 上游增删组件不会冲掉主人的改名/隐藏/排序。
SETTING_OVERLAY = 'drama_overlay'

# 标识与上限的唯一定义搬到了 widgets（契约层），这里只做转发，
# 免得 main.py 的 `dramas.ITEM_RE` 等引用要跟着改。
ITEM_RE = widgets.ITEM_RE
SID_RE = widgets.SID_RE
PROVIDER_RE = widgets.PROVIDER_RE
EPISODE_MAX = widgets.EPISODE_MAX

# 详情里带全部分集的直链，一集 300KB 起步：缓存五分钟，够一轮播放反复换集
DETAIL_TTL = 300
# 组件清单变得少，但探测一次要等上游，缓存长一点
PROVIDERS_TTL = 300
# 列表页缓存：上游对同一分类连拉两次要 4 秒，来回翻页时不该再等一遍
LIST_TTL = 60
# 上游的诊断快照缓存。这份数据本身是上游**上一次全量诊断**的结果，变化很慢，
# 缓存两分钟纯粹是为了别在每次打开组件列表时都去要一遍。
DIAG_TTL = 120
# 诊断快照只是读一份本地 JSON，理论上百毫秒级；给 3 秒是为了跟组件探测
# 共用同一个「最坏等多久」上限 —— 两者是并发的，总上限不该因此变长。
DIAG_TIMEOUT = 3.0
# 一台服务最多等这么久；主人加的地址可能是台关着的机器
PROBE_TIMEOUT = 3.0
# 分片代理的签名有效期：一集通常几分钟，留足余量又不至于永久有效
PART_TTL = 6 * 3600
PART_PATH = '/api/drama-part?t='
PURPOSE_HLS_PART = b'love-space:hls-part:v1'
# 有些 CDN 会看 UA / Referer，不给就是 403
HLS_UA = ('Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36')
MAX_PLAYLIST = 2 * 1024 * 1024

_core = {}          # (base, provider, item_id) -> (expire_ts, detail)
_providers = {}     # base -> (expire_ts, [provider])
_list_cache = {}    # (base, provider, category, page, q, rank) -> (expire_ts, payload)
_stream_probe = {}  # (base, provider, item_id, ep) -> (expire_ts, url, is_hls)
# 组件健康度：(base, provider) -> {'ok','error','at','ms'}。只记最近一次结果，
# 不落库 —— 上游本来就是「说挂就挂、过会儿又好了」，历史留着没有意义。
_health = {}
# 上游诊断快照：(base) -> (expire_ts, {provider_id: net})。见 `diagnostics()`。
_diagnostics = {}
_lock = threading.Lock()
_transport = None   # 测试注入 httpx.MockTransport
_part_key_cache = None


class DramaError(Exception):
    """上游不可用或返回了看不懂的东西；status 给调用方转成 HTTP 状态码。"""

    def __init__(self, message, status=502):
        super().__init__(message)
        self.status = status


def _client(**kw):
    kw.setdefault('timeout', httpx.Timeout(15.0, connect=8.0))
    return httpx.AsyncClient(trust_env=False, follow_redirects=True,
                             transport=_transport, **kw)


def _note_health(base, provider, ok, message='', started=0.0):
    """记下某个组件最近一次请求的结果，给管理界面显示「这个源现在什么状态」。

    只留最后一次：上游的可用性是分钟级的，历史数据只会误导人。
    """
    if not provider:
        return
    with _lock:
        _health[(base, provider)] = {
            'ok': bool(ok),
            'error': '' if ok else str(message)[:120],
            'at': int(time.time()),
            'ms': int((time.time() - started) * 1000) if started else 0,
        }


def health_of(base, provider):
    with _lock:
        return dict(_health.get((base, provider)) or {})


async def _get_json(base, path, provider=None):
    """取一份 JSON。失败重试一次。

    上游是个爬虫聚合器，同一分类连拉两次，一次 4.5 秒一次 504 是常态。而这些都是
    GET、幂等、失败无副作用，所以「失败等 250ms 再试一次」的收益远大于成本：
    实测能把偶发 504 挡在用户看不到的地方。仍失败才向上抛。
    """
    started = time.time()
    last = None
    for attempt in (0, 1):
        try:
            async with _client() as c:
                r = await c.get(base + path)
        except Exception as exc:                  # 上游没起来 / 网络不通
            last = ('连不上', exc)
            log.warning('drama upstream failed: %s%s (try %s) %s',
                        base, path, attempt + 1, exc)
        else:
            if r.status_code < 400:
                try:
                    payload = r.json()
                except Exception:
                    _note_health(base, provider, False, '返回了非 JSON', started)
                    raise DramaError('片源服务返回了非 JSON 内容')
                _note_health(base, provider, True, started=started)
                return payload
            last = (f'HTTP {r.status_code}', r)
            log.warning('drama upstream %s%s -> %s', base, path, r.status_code)
            # 4xx 是「这条路本来就不通」，重试没有意义；5xx 才值得再敲一次
            if r.status_code < 500:
                _note_health(base, provider, False, f'HTTP {r.status_code}', started)
                raise DramaError('片源服务返回异常', 404)
        if attempt == 0:
            await asyncio.sleep(0.25)
    _note_health(base, provider, False, last[0] if last else '连不上', started)
    if last and isinstance(last[1], httpx.Response):
        raise DramaError('片源服务返回异常', 502)
    raise DramaError('片源服务暂时连不上')


async def _get_abs_json(url):
    """resolveUrl 给的是绝对地址（不在 base/path 这套里），单独走一次。"""
    try:
        async with _client() as c:
            r = await c.get(url)
    except Exception as exc:
        log.warning('drama resolve failed: %s %s', urlsplit(url).path, exc)
        raise DramaError('片源地址解析不出来')
    if r.status_code >= 400:
        raise DramaError('片源地址解析不出来')
    try:
        return r.json()
    except Exception:
        raise DramaError('片源地址返回了非 JSON 内容')


async def _get_text(url, limit=MAX_PLAYLIST):
    """播放列表是文本，整段取回（有上限，别让上游塞个 GB 进来）。

    返回 (文本, 最终地址)：Capy 的 /api/v1/stream/<签名> 会重定向到源站真正的
    m3u8。相对分片（enc.key / a0.ts / video0.jpeg）必须以**重定向后**的地址
    为基准补全，按 Capy 的地址算会全部指到内网去，密钥和分片直接 401/404。
    """
    client = _client(timeout=httpx.Timeout(20.0, connect=8.0),
                     headers={'User-Agent': HLS_UA})
    try:
        r = await client.get(url)
        if r.status_code >= 400:
            raise DramaError('播放列表取不到')
        return r.content[:limit].decode('utf-8', 'ignore'), str(r.url)
    except DramaError:
        raise
    except Exception as exc:
        log.warning('drama playlist failed: %s %s', urlsplit(url).path, exc)
        raise DramaError('播放列表取不到')
    finally:
        await client.aclose()


# ── HLS 分片代理 ────────────────────────────────────────────────────────
def _part_key():
    """按用途派生一把签名钥匙；每次分片都去读 secret.key 太浪费，缓存住。"""
    global _part_key_cache
    if _part_key_cache is None:
        _part_key_cache = hmac.new(secret_key(), PURPOSE_HLS_PART,
                                   hashlib.sha256).digest()
    return _part_key_cache


def _b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b'=').decode()


def _unb64(text):
    return base64.urlsafe_b64decode(text + '=' * (-len(text) % 4))


def sign_part(url, referer=''):
    """把一条分片地址签成短 token；客户端改不动，也不能自己造新地址。

    这里不做「任意 URL 代理」：token 只能由服务端从上游播放列表里读出来后签发，
    攻击者拿不到密钥就拼不出合法 token，SSRF 的口子才算真的堵上。
    """
    body = json.dumps({'u': url, 'r': referer,
                       'x': int(time.time()) + PART_TTL},
                      separators=(',', ':')).encode()
    payload = _b64(body)
    sig = _b64(hmac.new(_part_key(), payload.encode(), hashlib.sha256).digest()[:12])
    return payload + '.' + sig


def verify_part(token):
    try:
        payload, sig = str(token or '').split('.', 1)
        want = hmac.new(_part_key(), payload.encode(), hashlib.sha256).digest()[:12]
        if not hmac.compare_digest(want, _unb64(sig)):
            return None
        data = json.loads(_unb64(payload))
        if int(data['x']) < int(time.time()):
            return None
        url = str(data['u'])
        parts = urlsplit(url)
        # 再兜一层：只放行 http(s)、不带账号密码、有主机名
        if parts.scheme not in ('http', 'https') or not parts.hostname or parts.username:
            return None
        return url, str(data.get('r') or '')
    except Exception:
        return None


_URI_ATTR = re.compile(r'(URI=")([^"]+)(")', re.IGNORECASE)


def _origin(url):
    parts = urlsplit(url)
    return f'{parts.scheme}://{parts.netloc}/' if parts.scheme and parts.netloc else ''


def _part_link(uri, playlist_url, referer):
    """相对 URI 按播放列表地址补全，再换成经本站的签名地址。"""
    absolute = urljoin(playlist_url, uri)
    parts = urlsplit(absolute)
    if parts.scheme not in ('http', 'https') or not parts.hostname or parts.username:
        raise DramaError('播放列表里有不认识的地址')
    return PART_PATH + quote(sign_part(absolute, referer), safe='')


def rewrite_playlist(text, playlist_url):
    """逐行改写 m3u8：分片行、子列表行，以及 KEY/MAP 等属性里的 URI="…"。"""
    referer = _origin(playlist_url)
    out = []
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith('#'):
            if 'URI="' in line or 'uri="' in line:
                line = _URI_ATTR.sub(
                    lambda m: m.group(1) + _part_link(m.group(2), playlist_url, referer) + m.group(3),
                    line)
            out.append(line)
        elif line:
            out.append(_part_link(line, playlist_url, referer))
        else:
            out.append('')
    return '\n'.join(out) + '\n'


async def part_proxy(token, range_header=''):
    """按签名取一片。返回 (upstream, client)，调用方负责关。"""
    info = verify_part(token)
    if not info:
        raise DramaError('播放地址已失效，重新选一次集', 403)
    url, referer = info
    headers = {'User-Agent': HLS_UA}
    if referer:
        headers['Referer'] = referer
    if range_header:
        headers['Range'] = range_header
    client = _client(timeout=httpx.Timeout(60.0, connect=10.0), headers=headers)
    try:
        request = client.build_request('GET', url)
        upstream = await client.send(request, stream=True)
    except Exception as exc:
        await client.aclose()
        log.warning('drama part failed: %s %s', urlsplit(url).netloc, exc)
        raise DramaError('这一片暂时取不到')
    if upstream.status_code >= 400 and upstream.status_code != 416:
        await upstream.aclose()
        await client.aclose()
        raise DramaError('这一片暂时取不到')
    return upstream, client


# ── 配置：服务实例 + 启用哪些组件 ────────────────────────────────────────
def clean_base(raw):
    """主人手填的地址：只收 http(s)，不许塞账号密码，不许指向本机。"""
    base = str(raw or '').strip().rstrip('/')
    if not base:
        raise DramaError('地址不能为空', 400)
    if len(base) > 200:
        raise DramaError('地址太长了', 400)
    if '@' in base:
        raise DramaError('地址里不要带账号密码', 400)
    parts = urlsplit(base)
    if parts.scheme not in ('http', 'https'):
        raise DramaError('地址要以 http:// 或 https:// 开头', 400)
    if not parts.hostname or ' ' in base:
        raise DramaError('地址格式不对', 400)
    # 拦住回环与未指定地址，否则这个接口能被拿来打自己
    host = parts.hostname.lower()
    if host in ('localhost', '::1', '0.0.0.0'):
        raise DramaError('这个地址填不了', 400)
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        if ip.is_loopback or ip.is_unspecified:
            raise DramaError('这个地址填不了', 400)
    return base


def _slug(name, base, taken):
    raw = re.sub(r'[^a-z0-9]', '', (name or '').lower())[:10]
    if not raw:
        raw = re.sub(r'[^a-z0-9]', '', urlsplit(base).hostname or '')[:10] or 'src'
    sid, i = raw, 2
    while sid in taken:
        sid = f'{raw}{i}'[:16]
        i += 1
    return sid


def load_config(c):
    raw = db.setting(c, SETTING_KEY, None)
    if not isinstance(raw, dict):
        raw = {}
    services = []
    for item in raw.get('services') or []:
        if not isinstance(item, dict):
            continue
        sid = str(item.get('id') or '').strip()
        base = str(item.get('base') or '').strip().rstrip('/')
        if not SID_RE.match(sid) or not base:
            continue
        services.append({'id': sid, 'name': str(item.get('name') or sid)[:24], 'base': base})
    if not services:                       # 没配过 / 全被删光：回到内置那台
        services = [{'id': DEFAULT_SERVICE_ID, 'name': DEFAULT_SERVICE_NAME, 'base': DEFAULT_BASE}]
    known = {s['id'] for s in services}
    if raw.get('enabled') is None:
        enabled = [x for x in DEFAULT_ENABLED if x.split(':', 1)[0] in known]
    else:
        enabled = [str(x) for x in (raw.get('enabled') or [])
                   if isinstance(x, str) and x.count(':') == 1]
    # 服务删了，它底下勾过的组件要跟着消失，否则会留下点不动的悬空项
    enabled = [x for x in enabled if x.split(':', 1)[0] in known]
    return {'services': services, 'enabled': enabled}


def save_config(c, cfg):
    db.set_setting(c, SETTING_KEY, {
        'services': cfg['services'],
        'enabled': cfg['enabled'],
    })


# ── 本地覆盖层：上游负责发现，本地负责整理 ──────────────────────────────
# 为什么单独一张表：组件清单是上游给的，随时会变（新增/改名/消失）。如果主人的
# 「改名、隐藏、排序、标签」也塞进 drama_sources，上游一改名就会连带被覆盖掉。
# 所以本地只存**差异**，键是 `服务id:组件id`，读的时候再叠加上去。
OVERLAY_FIELDS = ('alias', 'hidden', 'order', 'tag')


def _overlay_key_ok(key):
    key = str(key or '')
    if key.count(':') != 1:
        return ''
    sid, pid = key.split(':', 1)
    if not SID_RE.match(sid) or not PROVIDER_RE.match(pid):
        return ''
    return key


def load_overlay(c):
    """{ "capy:hongguo": {"alias": "红果", "hidden": false, "order": 3, "tag": "短剧"} }"""
    raw = db.setting(c, SETTING_OVERLAY, None)
    if not isinstance(raw, dict):
        raw = {}
    out = {}
    for key, value in raw.items():
        clean_key = _overlay_key_ok(key)
        if not clean_key or not isinstance(value, dict):
            continue
        entry = {}
        alias = str(value.get('alias') or '').strip()[:24]
        if alias:
            entry['alias'] = alias
        tag = str(value.get('tag') or '').strip()[:12]
        if tag:
            entry['tag'] = tag
        order = value.get('order')
        if isinstance(order, int) and not isinstance(order, bool):
            entry['order'] = max(0, min(order, 9999))
        if value.get('hidden'):
            entry['hidden'] = True
        if entry:
            out[clean_key] = entry
    return out


def set_overlay(c, key, patch):
    """只改传进来的那几项；值为空/None 表示「恢复上游原样」。"""
    key = _overlay_key_ok(key)
    if not key:
        raise DramaError('组件编号不对', 400)
    cfg = load_config(c)
    if key.split(':', 1)[0] not in {s['id'] for s in cfg['services']}:
        raise DramaError('没有这个片源服务', 404)
    overlay = load_overlay(c)
    entry = dict(overlay.get(key) or {})
    if 'alias' in patch:
        alias = str(patch.get('alias') or '').strip()[:24]
        entry['alias'] = alias
    if 'tag' in patch:
        tag = str(patch.get('tag') or '').strip()[:12]
        entry['tag'] = tag
    if 'order' in patch:
        order = patch.get('order')
        entry['order'] = max(0, min(int(order), 9999)) if isinstance(order, int) else None
    if 'hidden' in patch:
        entry['hidden'] = bool(patch.get('hidden'))
    entry = {k: v for k, v in entry.items()
             if v is not None and v != '' and v is not False}
    overlay = {k: v for k, v in overlay.items() if k != key}
    if entry:
        overlay[key] = entry
    db.set_setting(c, SETTING_OVERLAY, overlay)
    return overlay


def _decorate(provider, entry):
    """把覆盖层叠到归一化后的组件上。上游字段一律不改，另开 *_own 字段。"""
    alias = (entry or {}).get('alias') or ''
    out = dict(provider)
    out['alias'] = alias
    out['name'] = alias or provider['title']
    out['tag'] = (entry or {}).get('tag') or ''
    out['hidden'] = bool((entry or {}).get('hidden'))
    out['order'] = (entry or {}).get('order')
    return out


def add_service(c, name, base):
    cfg = load_config(c)
    base = clean_base(base)
    if any(s['base'] == base for s in cfg['services']):
        raise DramaError('这个地址已经加过了', 409)
    sid = _slug(name or urlsplit(base).hostname or '', base, {s['id'] for s in cfg['services']})
    cfg['services'].append({'id': sid, 'name': (str(name or '').strip() or urlsplit(base).hostname or sid)[:24],
                            'base': base})
    save_config(c, cfg)
    return cfg


def remove_service(c, sid):
    cfg = load_config(c)
    left = [s for s in cfg['services'] if s['id'] != sid]
    if len(left) == len(cfg['services']):
        raise DramaError('没有这个服务', 404)
    cfg['services'] = left
    cfg['enabled'] = [x for x in cfg['enabled'] if x.split(':', 1)[0] != sid]
    save_config(c, cfg)
    return cfg


def set_enabled(c, keys):
    cfg = load_config(c)
    known = {s['id'] for s in cfg['services']}
    out, seen = [], set()
    for key in keys or []:
        key = str(key or '')
        if key.count(':') != 1 or key in seen:
            continue
        sid, pid = key.split(':', 1)
        if sid not in known or not PROVIDER_RE.match(pid):
            continue
        seen.add(key)
        out.append(key)
    cfg['enabled'] = out
    save_config(c, cfg)
    # 关掉的组件不必继续占缓存
    with _lock:
        for key in [k for k in _core if f'{k[0]}:{k[1]}' not in seen]:
            _core.pop(key, None)
        for key in [k for k in _list_cache if f'{k[0]}:{k[1]}' not in seen]:
            _list_cache.pop(key, None)
    return cfg


def resolve(c, sid, provider=None):
    """拿到服务；给了 provider 还要确认它被启用，避免绕过界面直接念接口。"""
    cfg = load_config(c)
    svc = next((s for s in cfg['services'] if s['id'] == sid), None)
    if not svc:
        raise DramaError('没有这个片源服务', 404)
    if provider is not None:
        if not PROVIDER_RE.match(str(provider or '')):
            raise DramaError('组件编号不对', 400)
        if f'{sid}:{provider}' not in cfg['enabled']:
            raise DramaError('这个组件还没启用', 403)
    return svc


def first_enabled(c):
    """存量数据迁移用：老状态里只有剧 id，没有服务/组件，回落到第一个启用的组合。"""
    cfg = load_config(c)
    if not cfg['enabled']:
        return DEFAULT_SERVICE_ID, ''
    sid, pid = cfg['enabled'][0].split(':', 1)
    return sid, pid


# ── 组件清单 ────────────────────────────────────────────────────────────
async def providers(base, refresh=False):
    now = time.time()
    if not refresh:
        with _lock:
            hit = _providers.get(base)
        if hit and hit[0] > now:
            return hit[1]
    payload = await _get_json(base, '/api/v1/providers')
    # 归一化与脏数据过滤都在契约层，这里只负责缓存与排序
    out = widgets.providers(payload)
    with _lock:
        _providers[base] = (now + PROVIDERS_TTL, out)
    return out


async def catalog(c, refresh=False):
    """给管理界面：每台服务在线情况 + 它代理的组件 + 勾选/整理状态。

    几台服务并发探测 —— 串行的话，一台连不上的机器会把后面全卡住，
    主人看到的就是「点了没反应」。诊断快照跟探测一起发出去，两者互不依赖。
    """
    cfg = load_config(c)
    enabled = set(cfg['enabled'])
    overlay = load_overlay(c)
    # 探测和诊断快照交错排：每台服务两个任务，最后按奇偶拆开。
    # 分两批 await 会让最坏耗时变成 3+3 秒，交错发就只有 3 秒。
    tasks = []
    for svc in cfg['services']:
        tasks.append(_probe(svc['base'], refresh))
        tasks.append(_nets_safe(svc['base'], refresh))
    ready = await asyncio.gather(*tasks, return_exceptions=True)
    probes, nets = ready[0::2], ready[1::2]
    services = []
    for svc, result, net_map in zip(cfg['services'], probes, nets):
        entry = {'id': svc['id'], 'name': svc['name'], 'base': svc['base'],
                 'online': False, 'error': '', 'providers': []}
        nets_of = net_map if isinstance(net_map, dict) else {}
        if isinstance(result, Exception):          # 超时、连不上、返回看不懂
            entry['error'] = str(result) or '这台服务连不上'
        else:
            entry['online'] = True
            for p in result:
                key = f"{svc['id']}:{p['id']}"
                one = _decorate(p, overlay.get(key))
                one['key'] = key
                one['enabled'] = key in enabled
                one['health'] = health_of(svc['base'], p['id'])
                # 网络模式与健康度并列，互不覆盖：健康度是「我们刚才请求成没成」，
                # 网络模式是上游说「这个源该由谁去连」。两者都会缺，缺了就是空。
                one['net'] = nets_of.get(p['id']) or {}
                entry['providers'].append(one)
        services.append(entry)
    return {'services': services}


async def diagnostics(base, refresh=False):
    """读上游的**诊断快照**，拿到每个组件的网络模式。

    为什么只 GET 不 POST：`POST /api/v1/diagnostics` 会让上游对每个组件跑一遍
    真实探测（本机实测 9 个组件 8 秒，带超时的源更久），而 `GET` 直接读上一次的
    结果。打开一次组件列表就有这种副作用是不可接受的，所以触发留给
    `scripts/capy_probe.py --diag`，这边只读。

    读不到就返回空表 —— 网络模式只是**附加信息**，上游这套接口没开、或者干脆
    是别的 Capy 实现时，组件列表本身必须照常能用。
    """
    now = time.time()
    if not refresh:
        with _lock:
            hit = _diagnostics.get(base)
        if hit and hit[0] > now:
            return hit[1]
    try:
        payload = await asyncio.wait_for(
            _get_json(base, '/api/v1/diagnostics'), DIAG_TIMEOUT)
    except (DramaError, asyncio.TimeoutError) as exc:
        log.info('drama diagnostics unavailable: %s %s', base, exc)
        out = {}
    else:
        out = widgets.nets(payload)
    with _lock:
        _diagnostics[base] = (now + DIAG_TTL, out)
    return out


async def _nets_safe(base, refresh):
    """`diagnostics()` 的兜底包装：任何异常都退回空表，绝不让组件列表跟着挂。"""
    try:
        return await diagnostics(base, refresh)
    except Exception as exc:                   # 不是 DramaError 也照兜
        log.warning('drama diagnostics failed: %s %s', base, exc)
        return {}


async def _probe(base, refresh):
    """单台服务的组件清单，最多等 PROBE_TIMEOUT 秒。"""
    try:
        return await asyncio.wait_for(providers(base, refresh), PROBE_TIMEOUT)
    except asyncio.TimeoutError:
        raise DramaError('这台服务没响应')


# ── 内容 ────────────────────────────────────────────────────────────────
async def list_items(base, provider, category='', page=1, keyword='', rank='', fresh=False):
    """统一列表入口：有关键词就搜索，否则按分类浏览。

    返回归一化后的条目 + 上游的分页信息。`pageCount/total` 以前被丢掉了，
    于是前端只能靠「这一页是不是满的」猜还有没有下一页 —— 红果一个分类就有
    1413 页 / 56496 条，猜不出来。

    `fresh=True` 绕过缓存，只给体检报告用；正常浏览走 60 秒缓存。
    """
    try:
        page = max(1, min(int(page or 1), 100))
    except (TypeError, ValueError):
        page = 1
    keyword = (keyword or '').strip()
    cache_key = (base, provider, category or '', page, keyword, rank or '')
    now = time.time()
    with _lock:
        hit = _list_cache.get(cache_key)
    if hit and hit[0] > now and not fresh:
        return hit[1]

    root = f'/api/v1/providers/{provider}'
    if keyword:
        path = f'{root}/search?q={quote(keyword, safe="")}&page={page}'
    else:
        query = f'page={page}'
        if category:
            query = f'category={quote(str(category), safe="")}&' + query
        if rank:
            query += f'&rank={quote(str(rank), safe="")}'
        path = f'{root}/browse?' + query
    payload = await _get_json(base, path, provider)
    result = {'items': widgets.items(payload.get('items') if isinstance(payload, dict) else None)}
    result.update(widgets.page_meta(payload, page))
    with _lock:
        _list_cache[cache_key] = (now + LIST_TTL, result)
        for stale in [k for k, v in _list_cache.items() if v[0] <= now]:
            _list_cache.pop(stale, None)
    return result


async def diagnose(base, provider):
    """给单个组件做一次最小可用性体检，带 `?probe=1` 时才会跑。

    四项都过才算「真能用」：清单读得到（调用方已确认）→ 第一个分类翻得动 →
    首条能取详情 → 详情里真有可播地址。上游没有状态页，这就是它的替代品。
    """
    started = time.time()
    out = {'ok': False, 'browse': '', 'detail': '', 'items': 0, 'total': 0,
           'episodes': 0, 'playable': False, 'needs_resolve': False,
           'sample': '', 'ms': 0}
    pid = provider.get('id') or ''
    cats = provider.get('categories') or []
    cat = (cats[0] or {}).get('id', '') if cats else ''
    try:
        res = await list_items(base, pid, cat, page=1, fresh=True)
    except DramaError as exc:
        out['browse'] = str(exc)
        out['ms'] = int((time.time() - started) * 1000)
        return out
    rows = res.get('items') or []
    out['browse'] = 'ok'
    out['items'] = len(rows)
    out['total'] = res.get('total', 0)
    if not rows:
        out['detail'] = '这个分类是空的'
        out['ms'] = int((time.time() - started) * 1000)
        return out
    out['sample'] = rows[0]['title']
    try:
        data = await _detail(base, pid, rows[0]['id'])
    except DramaError as exc:
        out['detail'] = str(exc)
        out['ms'] = int((time.time() - started) * 1000)
        return out
    eps = [e for e in (data.get('episodes') or []) if e.get('url') or e.get('resolve')]
    out['detail'] = 'ok'
    out['episodes'] = len(eps)
    out['playable'] = bool(eps)
    # 只有 resolveUrl 的组件每播一集都要多解析一次，出问题时的表现和别家不一样，
    # 体检报告里标出来，省得排查时又从头猜
    out['needs_resolve'] = any(not e.get('url') and e.get('resolve') for e in eps)
    out['ok'] = out['playable']
    out['ms'] = int((time.time() - started) * 1000)
    return out


async def diagnose_many(base, providers_list, limit=4):
    """批量体检：并发跑，但**卡住并发数**。

    17 个组件串行跑要一分多钟（上游一个分类 4 秒是常态），主人的手机会一直转圈；
    全放开并发又等于对着一台爬虫机器连开 17 个口子，上游会更慢。4 是实测的折中。
    返回与入参同序的结果列表，失败的组件也在列表里（`ok=False` + 原因）。
    """
    sem = asyncio.Semaphore(max(1, int(limit or 1)))

    async def one(provider):
        async with sem:
            try:
                return await diagnose(base, provider)
            except Exception as exc:           # 单个组件炸了不该拖垮整份报告
                log.warning('drama diagnose failed: %s/%s %s',
                            base, provider.get('id'), exc)
                return {'ok': False, 'browse': str(exc) or '体检失败', 'detail': '',
                        'items': 0, 'total': 0, 'episodes': 0, 'playable': False,
                        'needs_resolve': False, 'sample': '', 'ms': 0}

    return await asyncio.gather(*(one(p) for p in providers_list))


async def _detail(base, provider, item_id):
    item_id = str(item_id or '')
    if not ITEM_RE.match(item_id) or '..' in item_id:
        raise DramaError('内容编号不对', 400)
    key = (base, provider, item_id)
    now = time.time()
    with _lock:
        hit = _core.get(key)
    if hit and hit[0] > now:
        return hit[1]
    # id 里可能带 @ / : 之类，拼进路径前先编码
    payload = await _get_json(
        base, f'/api/v1/providers/{provider}/items/{quote(item_id, safe="")}', provider)
    data = widgets.detail(item_id, payload)
    if not data:
        raise DramaError('这个内容还没有可播的剧集', 404)
    with _lock:
        _core[key] = (now + DETAIL_TTL, data)
        # 顺手清理过期条目，避免换片多了无限涨
        for stale in [k for k, v in _core.items() if v[0] <= now]:
            _core.pop(stale, None)
    return data


async def detail(base, provider, item_id):
    """给前端的详情：**不含直链**，只有集号与集名。"""
    return widgets.public_detail(await _detail(base, provider, item_id))


async def stream_url(base, provider, item_id, episode):
    """按剧集号换一条当次有效的直链；过期了就自然命中缓存刷新。"""
    data = await _detail(base, provider, item_id)
    try:
        episode = int(episode or 1)
    except (TypeError, ValueError):
        raise DramaError('集数不对', 400)
    ep = next((e for e in data['episodes'] if e['n'] == episode), None)
    # 集号对不上（比如上游改过编号）时退到按序号取，总比整页报错强
    if ep is None and 1 <= episode <= len(data['episodes']):
        log.warning('drama %s/%s episode %s not found, fallback #%s',
                    provider, item_id, episode, episode)
        ep = data['episodes'][episode - 1]
    if ep is None:
        raise DramaError('没有这一集', 404)
    if ep['url']:
        return ep['url']
    if ep['resolve']:
        payload = await _get_abs_json(ep['resolve'])
        url = payload.get('videoUrl') or payload.get('url') or payload.get('streamUrl') or ''
        if not url:
            raise DramaError('这个片源解析不出播放地址')
        # 回填进详情缓存，同一集反复拖动/换回时不必再解析一次
        ep['url'] = str(url)
        return ep['url']
    raise DramaError('这一集没有播放地址', 404)


async def probe_stream(base, provider, item_id, episode):
    """只读开头几十字节判断这一集是 mp4 还是 HLS，别把整个视频拉进内存。"""
    url = await stream_url(base, provider, item_id, episode)
    key = (base, provider, str(item_id), int(episode))
    now = time.time()
    with _lock:
        hit = _stream_probe.get(key)
        if hit and hit[0] > now and hit[1] == url:
            return hit[2]
    client = _client(timeout=httpx.Timeout(12.0, connect=8.0),
                     headers={'User-Agent': HLS_UA, 'Range': 'bytes=0-64'})
    try:
        request = client.build_request('GET', url)
        upstream = await client.send(request, stream=True)
        head = b''
        async for chunk in upstream.aiter_bytes(128):
            head = chunk[:128]
            break
        if upstream.status_code >= 400:
            await upstream.aclose()
            raise DramaError('这一集暂时播不了')
        ct = (upstream.headers.get('content-type') or '').lower()
        is_hls = ('mpegurl' in ct or 'm3u8' in ct
                  or head.lstrip().startswith(b'#EXTM3U'))
        await upstream.aclose()
    except DramaError:
        raise
    except Exception as exc:
        log.warning('drama probe failed: %s/%s %s', provider, item_id, exc)
        raise DramaError('这一集暂时播不了')
    finally:
        await client.aclose()
    with _lock:
        _stream_probe[key] = (now + DETAIL_TTL, url, is_hls)
        for stale in [k for k, v in _stream_probe.items() if v[0] <= now]:
            _stream_probe.pop(stale, None)
    return is_hls


async def hls_playlist(base, provider, item_id, episode):
    """取回 m3u8 并把里面每条 URI 换成经本站的签名地址。

    不改写的话：相对路径会被浏览器解析到本站（404）、Capy 内网地址手机连不上、
    带防盗链的 CDN 直接 403 —— 三种都表现为「点了没反应」。
    """
    url = await stream_url(base, provider, item_id, episode)
    text, final_url = await _get_text(url)
    if not text.lstrip().startswith('#EXTM3U'):
        raise DramaError('这个片源返回的不是播放列表')
    # base 与 Referer 都用重定向后那个源站地址
    return rewrite_playlist(text, final_url)


async def proxy(base, provider, item_id, episode, range_header=''):
    """把上游的字节原样吐给浏览器，转发 Range 以保住拖动进度。

    返回 (upstream_response, client)，调用方负责关掉它们。
    """
    url = await stream_url(base, provider, item_id, episode)
    client = _client(timeout=httpx.Timeout(60.0, connect=10.0),
                     headers={'User-Agent': HLS_UA})
    headers = {}
    if range_header:
        headers['Range'] = range_header
    try:
        request = client.build_request('GET', url, headers=headers)
        upstream = await client.send(request, stream=True)
    except Exception as exc:
        await client.aclose()
        log.warning('drama stream failed: %s/%s %s', provider, item_id, exc)
        raise DramaError('这一集暂时播不了')
    if upstream.status_code >= 400 and upstream.status_code != 416:
        await upstream.aclose()
        await client.aclose()
        raise DramaError('这一集暂时播不了')
    return upstream, client
