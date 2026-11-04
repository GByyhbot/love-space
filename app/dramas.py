"""红果短剧：把 NAS 上 Capy Backend（:8788）的内容接进一起看。

它不是播放器，也不认任何宿主组件（那边的 `hongguo.js` 是 Capy 宿主的适配器，
依赖 `Widget.*` 运行时），真正能用的是它背后的 HTTP 接口：

    /api/v1/providers/hongguo/browse?category=short|comic|rank&page=1
    /api/v1/providers/hongguo/search?q=…&page=1
    /api/v1/providers/hongguo/items/<id>      → seasons[].episodes[].streamUrl
    /api/v1/stream/<签名>                      → 206 + video/mp4，支持 Range

两个关键约束，决定了这层必须放在服务端：

① **直链带签名且会过期**（token 里 `exp` 约 24 小时）。所以直链既不落库也不下发，
   只按「剧集号」现换现用 —— 客户端状态里只留 id 和集数。
② **8788 只有内网入口**。手机在外网时既连不到它，HTTPS 页面也不能直接播 http 视频。
   经本站转发后是同源，CSP 用 'self' 就够，也不必为它单独放开 media-src。
"""
import logging
import os
import re
import threading
import time
from urllib.parse import quote

import httpx

log = logging.getLogger('love.space')

BASE = os.environ.get('CAPY_BASE', 'http://192.168.31.95:8788').rstrip('/')
# 上游是用 id 拼路径的，必须卡死成纯数字，否则「../」能拐到别的接口去
ITEM_RE = re.compile(r'^\d{1,32}$')
EPISODE_MAX = 2000
# 详情里带全部分集的直链，一集 300KB 起步：缓存五分钟，够一轮播放反复换集
DETAIL_TTL = 300

_core = {}          # item_id -> (expire_ts, {'title','poster','description','episodes':[(n,title,url)]})
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


async def _get_json(path):
    try:
        async with _client() as c:
            r = await c.get(BASE + path)
    except Exception as exc:                      # 上游没起来 / 网络不通
        log.warning('drama upstream failed: %s %s', path, exc)
        raise DramaError('短剧服务暂时连不上')
    if r.status_code >= 400:
        log.warning('drama upstream %s -> %s', path, r.status_code)
        raise DramaError('短剧服务返回异常', 502 if r.status_code >= 500 else 404)
    try:
        return r.json()
    except Exception:
        raise DramaError('短剧服务返回了非 JSON 内容')


def _clean_item(item):
    return {
        'id': str(item.get('id') or ''),
        'title': (item.get('title') or item.get('name') or '').strip(),
        'poster': item.get('posterUrl') or item.get('poster') or '',
        'remark': item.get('remark') or '',
        'desc': (item.get('description') or '').strip(),
    }


async def list_items(category='short', page=1, keyword='', rank=''):
    """统一的列表入口：有关键词就搜索，有 rank 就查榜，否则按分类浏览。"""
    try:
        page = max(1, min(int(page or 1), 100))
    except (TypeError, ValueError):
        page = 1
    if (keyword or '').strip():
        path = f'/api/v1/providers/hongguo/search?q={quote(keyword.strip(), safe="")}&page={page}'
    else:
        query = f'category={quote(str(category or "short"), safe="")}&page={page}'
        if rank:
            query += f'&rank={quote(str(rank), safe="")}'
        path = '/api/v1/providers/hongguo/browse?' + query
    payload = await _get_json(path)
    items = [_clean_item(x) for x in (payload.get('items') or [])]
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
        raise DramaError('这部剧还没有可播的剧集', 404)
    return {
        'id': item_id,
        'title': (payload.get('title') or '').strip() or '未命名短剧',
        'poster': payload.get('posterUrl') or '',
        'description': (payload.get('description') or '').strip(),
        'episodes': episodes,
    }


async def _detail(item_id):
    if not ITEM_RE.match(str(item_id or '')):
        raise DramaError('剧集编号不对', 400)
    now = time.time()
    with _lock:
        hit = _core.get(item_id)
    if hit and hit[0] > now:
        return hit[1]
    payload = await _get_json(f'/api/v1/providers/hongguo/items/{item_id}')
    data = _parse_detail(item_id, payload)
    with _lock:
        _core[item_id] = (now + DETAIL_TTL, data)
        # 顺手清理过期条目，避免换剧多了无限涨
        for key in [k for k, v in _core.items() if v[0] <= now]:
            _core.pop(key, None)
    return data


async def detail(item_id):
    """给前端的详情：**不含直链**，只有集号与集名。"""
    data = await _detail(item_id)
    return {
        'id': data['id'],
        'title': data['title'],
        'poster': data['poster'],
        'description': data['description'],
        'episodes': [{'n': e['n'], 'title': e['title']} for e in data['episodes']],
    }


async def stream_url(item_id, episode):
    """按剧集号换一条当次有效的直链；过期了就自然命中缓存刷新。"""
    data = await _detail(item_id)
    episode = int(episode or 1)
    for ep in data['episodes']:
        if ep['n'] == episode:
            return ep['url']
    # 集号对不上（比如上游改过编号）时退到第一集，总比整页报错强
    if 1 <= episode <= len(data['episodes']):
        log.warning('drama %s episode %s not found, fallback #%s', item_id, episode, episode)
        return data['episodes'][episode - 1]['url']
    raise DramaError('没有这一集', 404)


async def proxy(item_id, episode, range_header=''):
    """把上游的字节原样吐给浏览器，转发 Range 以保住拖动进度。

    返回 (upstream_response, client)，调用方负责关掉它们。
    """
    url = await stream_url(item_id, episode)
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
        log.warning('drama stream failed: %s %s', item_id, exc)
        raise DramaError('这一集暂时播不了')
    if upstream.status_code >= 400 and upstream.status_code != 416:
        await upstream.aclose()
        await client.aclose()
        raise DramaError('这一集暂时播不了')
    return upstream, client
