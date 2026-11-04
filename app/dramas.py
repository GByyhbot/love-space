"""在线片源：把 NAS 上 happy-capy（:8788）这类 Capy Backend 的内容接进一起看。

那台服务本身是个**组件聚合器** —— `GET /api/v1/providers` 会列出它代理的全部内容源，
每个源都遵循同一套协议：

    /api/v1/providers/<源>/browse?category=…&page=1
    /api/v1/providers/<源>/search?q=…&page=1
    /api/v1/providers/<源>/items/<id>      → seasons[].episodes[].streamUrl
    /api/v1/stream/<签名>                   → 206 + video/mp4，支持 Range

所以这里不写死任何一家：服务地址由主人自己加，能用哪些源由主人自己勾。
上游的 `hongguo.js` 之类只是 Capy 宿主的适配器（依赖 `Widget.*` 运行时），不是播放器，
前端完全不需要它 —— 只认本站的 `/api/dramas/…`。

三个约束决定了这层必须留在服务端：

① **直链带签名且会过期**（token 里 `exp` 约 24 小时）。所以直链既不落库也不下发，
   只按「剧集号」现换现用 —— 客户端状态里只留服务、源、id 和集数。
② **服务只有内网入口**。手机在外网时连不到它，HTTPS 页面也不能直接播 http 视频。
   经本站转发后是同源，CSP 用 'self' 就够，也不必为它单独放开 media-src。
③ **服务地址是主人填的**。所以 base 要卡协议、卡长度、拒 userinfo，还要拦住回环地址，
   免得这个接口变成一台人形代理。
"""
import asyncio
import ipaddress
import logging
import os
import re
import threading
import time
from urllib.parse import quote, urlsplit

import httpx

from . import db

log = logging.getLogger('love.space')

DEFAULT_BASE = os.environ.get('CAPY_BASE', 'http://192.168.31.95:8788').rstrip('/')
DEFAULT_SERVICE_ID = 'capy'
DEFAULT_SERVICE_NAME = 'Capy'
# 没配置过的时候：只开红果一家，其余由主人自己在「管理组件」里勾
DEFAULT_ENABLED = [f'{DEFAULT_SERVICE_ID}:hongguo']

SETTING_KEY = 'drama_sources'

# 上游是拿 id 拼路径的，几个标识都必须卡死，否则「../」能拐到别的接口去
ITEM_RE = re.compile(r'^\d{1,32}$')
SID_RE = re.compile(r'^[a-z0-9]{1,16}$')
PROVIDER_RE = re.compile(r'^[A-Za-z0-9_-]{1,32}$')
EPISODE_MAX = 2000

# 详情里带全部分集的直链，一集 300KB 起步：缓存五分钟，够一轮播放反复换集
DETAIL_TTL = 300
# 组件清单变得少，但探测一次要等上游，缓存长一点
PROVIDERS_TTL = 300
# 一台服务最多等这么久；主人加的地址可能是台关着的机器
PROBE_TIMEOUT = 3.0

_core = {}          # (base, provider, item_id) -> (expire_ts, detail)
_providers = {}     # base -> (expire_ts, [provider])
_lock = threading.Lock()
_transport = None   # 测试注入 httpx.MockTransport


class DramaError(Exception):
    """上游不可用或返回了看不懂的东西；status 给调用方转成 HTTP 状态码。"""

    def __init__(self, message, status=502):
        super().__init__(message)
        self.status = status


def _client(**kw):
    kw.setdefault('timeout', httpx.Timeout(15.0, connect=8.0))
    return httpx.AsyncClient(trust_env=False, follow_redirects=True,
                             transport=_transport, **kw)


async def _get_json(base, path):
    try:
        async with _client() as c:
            r = await c.get(base + path)
    except Exception as exc:                      # 上游没起来 / 网络不通
        log.warning('drama upstream failed: %s%s %s', base, path, exc)
        raise DramaError('片源服务暂时连不上')
    if r.status_code >= 400:
        log.warning('drama upstream %s%s -> %s', base, path, r.status_code)
        raise DramaError('片源服务返回异常', 502 if r.status_code >= 500 else 404)
    try:
        return r.json()
    except Exception:
        raise DramaError('片源服务返回了非 JSON 内容')


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
def _clean_group(raw):
    out = []
    for cat in raw or []:
        if not isinstance(cat, dict):
            continue
        cid = str(cat.get('id') or '').strip()
        if not cid or len(cid) > 40:
            continue
        out.append({'id': cid, 'title': str(cat.get('title') or cid).strip()[:20]})
    return out


async def providers(base, refresh=False):
    now = time.time()
    if not refresh:
        with _lock:
            hit = _providers.get(base)
        if hit and hit[0] > now:
            return hit[1]
    payload = await _get_json(base, '/api/v1/providers')
    out = []
    for item in payload.get('providers') or []:
        if not isinstance(item, dict):
            continue
        pid = str(item.get('id') or '').strip()
        if not PROVIDER_RE.match(pid):
            continue
        out.append({
            'id': pid,
            'title': str(item.get('title') or pid).strip()[:24],
            'categories': _clean_group(item.get('categories')),
            'caps': [str(x) for x in (item.get('capabilities') or [])],
        })
    with _lock:
        _providers[base] = (now + PROVIDERS_TTL, out)
    return out


async def catalog(c, refresh=False):
    """给管理界面：每台服务在线情况 + 它代理的组件，以及哪些已经勾上。

    几台服务并发探测 —— 串行的话，一台连不上的机器会把后面全卡住，
    主人看到的就是「点了没反应」。
    """
    cfg = load_config(c)
    enabled = set(cfg['enabled'])
    ready = await asyncio.gather(
        *(_probe(s['base'], refresh) for s in cfg['services']),
        return_exceptions=True,
    )
    services = []
    for svc, result in zip(cfg['services'], ready):
        entry = {'id': svc['id'], 'name': svc['name'], 'base': svc['base'],
                 'online': False, 'error': '', 'providers': []}
        if isinstance(result, Exception):          # 超时、连不上、返回看不懂
            entry['error'] = str(result) or '这台服务连不上'
        else:
            entry['online'] = True
            for p in result:
                entry['providers'].append({
                    'id': p['id'],
                    'title': p['title'],
                    'categories': p['categories'],
                    'enabled': f"{svc['id']}:{p['id']}" in enabled,
                })
        services.append(entry)
    return {'services': services}


async def _probe(base, refresh):
    """单台服务的组件清单，最多等 PROBE_TIMEOUT 秒。"""
    try:
        return await asyncio.wait_for(providers(base, refresh), PROBE_TIMEOUT)
    except asyncio.TimeoutError:
        raise DramaError('这台服务没响应')


# ── 内容 ────────────────────────────────────────────────────────────────
def _clean_item(item):
    return {
        'id': str(item.get('id') or ''),
        'title': (item.get('title') or item.get('name') or '').strip(),
        'poster': item.get('posterUrl') or item.get('poster') or '',
        'remark': item.get('remark') or '',
        'desc': (item.get('description') or '').strip(),
    }


async def list_items(base, provider, category='', page=1, keyword='', rank=''):
    """统一列表入口：有关键词就搜索，有 rank 就查榜，否则按分类浏览。"""
    try:
        page = max(1, min(int(page or 1), 100))
    except (TypeError, ValueError):
        page = 1
    root = f'/api/v1/providers/{provider}'
    if (keyword or '').strip():
        path = f'{root}/search?q={quote(keyword.strip(), safe="")}&page={page}'
    else:
        query = f'page={page}'
        if category:
            query = f'category={quote(str(category), safe="")}&' + query
        if rank:
            query += f'&rank={quote(str(rank), safe="")}'
        path = f'{root}/browse?' + query
    payload = await _get_json(base, path)
    items = [_clean_item(x) for x in (payload.get('items') or []) if isinstance(x, dict)]
    return [x for x in items if x['id'] and x['title']]


def _parse_detail(item_id, payload):
    episodes = []
    for season in payload.get('seasons') or []:
        for ep in season.get('episodes') or []:
            url = ep.get('streamUrl') or ep.get('videoUrl') or ''
            number = int(ep.get('episodeNumber') or ep.get('episode') or len(episodes) + 1)
            if not url:
                continue
            episodes.append({
                'n': number,
                'title': (ep.get('title') or f'第{number}集').strip(),
                'url': url,
            })
    if not episodes:
        raise DramaError('这个内容还没有可播的剧集', 404)
    return {
        'id': item_id,
        'title': (payload.get('title') or '').strip() or '未命名',
        'poster': payload.get('posterUrl') or '',
        'description': (payload.get('description') or '').strip(),
        'episodes': episodes,
    }


async def _detail(base, provider, item_id):
    if not ITEM_RE.match(str(item_id or '')):
        raise DramaError('内容编号不对', 400)
    key = (base, provider, str(item_id))
    now = time.time()
    with _lock:
        hit = _core.get(key)
    if hit and hit[0] > now:
        return hit[1]
    payload = await _get_json(base, f'/api/v1/providers/{provider}/items/{item_id}')
    data = _parse_detail(item_id, payload)
    with _lock:
        _core[key] = (now + DETAIL_TTL, data)
        # 顺手清理过期条目，避免换片多了无限涨
        for stale in [k for k, v in _core.items() if v[0] <= now]:
            _core.pop(stale, None)
    return data


async def detail(base, provider, item_id):
    """给前端的详情：**不含直链**，只有集号与集名。"""
    data = await _detail(base, provider, item_id)
    return {
        'id': data['id'],
        'title': data['title'],
        'poster': data['poster'],
        'description': data['description'],
        'episodes': [{'n': e['n'], 'title': e['title']} for e in data['episodes']],
    }


async def stream_url(base, provider, item_id, episode):
    """按剧集号换一条当次有效的直链；过期了就自然命中缓存刷新。"""
    data = await _detail(base, provider, item_id)
    episode = int(episode or 1)
    for ep in data['episodes']:
        if ep['n'] == episode:
            return ep['url']
    # 集号对不上（比如上游改过编号）时退到按序号取，总比整页报错强
    if 1 <= episode <= len(data['episodes']):
        log.warning('drama %s/%s episode %s not found, fallback #%s',
                    provider, item_id, episode, episode)
        return data['episodes'][episode - 1]['url']
    raise DramaError('没有这一集', 404)


async def proxy(base, provider, item_id, episode, range_header=''):
    """把上游的字节原样吐给浏览器，转发 Range 以保住拖动进度。

    返回 (upstream_response, client)，调用方负责关掉它们。
    """
    url = await stream_url(base, provider, item_id, episode)
    client = _client(timeout=httpx.Timeout(60.0, connect=10.0),
                     headers={'User-Agent': 'LoveSpace/1.0'})
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
