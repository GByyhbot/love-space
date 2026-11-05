"""CapyPlayer 组件的契约层：只做字段归一化与能力判定，不碰网络、不留状态。

为什么需要这一层
────────────────
上游 happy-capy（`cs920/happy-capy`）把 CapyPlayer 的沙箱组件转成了 HTTP：
组件本体是「`var WidgetMetadata` + 一堆全局 async 函数」，被宿主在沙箱里调用；
happy-capy 替我们跑沙箱，把调用结果摊成 `/api/v1/providers/<id>/…` 的 JSON。
它本身**没有任何文档**（镜像页没有 wiki），唯一可靠的依据是 CapyPlayer 的公开
组件规范：https://capyplayer.feifeiduck.cn/zh/dev/widget/widgetdev

所以这份文件就是**规范的本地副本**。规范里那些「优先读 A，回退 B、C、D」的
字段表，在这里落成一行行 `pick(...)`；上层只认归一化后的键名，不再猜字段。
上游换了一家组件、或 CapyPlayer 规范改了别名，改这里一处就够，别处不用动。

两条纪律
  1. 所有函数**纯**：给定输入必得同一输出，不读环境、不写全局、不发请求。
     这样每种形态都能在 tests/test_widgets.py 里用一段字面量 JSON 钉住。
  2. 脏数据一律**丢弃**而不是修：id 拿不出、标题拿不出的条目直接不要，
     免得它在列表里变成一个点不动的空卡。
"""
import re

# 上游是拿 id 拼路径的，几个标识都必须卡死，否则「../」能拐到别的接口去。
# 内容 id 各家花式不同：红果是纯数字，Jable 是 miab-678，蜜桃是 video@@…@@missav。
ITEM_RE = re.compile(r'^[A-Za-z0-9_@.:-]{1,160}$')
PROVIDER_RE = re.compile(r'^[A-Za-z0-9_-]{1,32}$')
SID_RE = re.compile(r'^[a-z0-9]{1,16}$')

# 一集 300KB 起步，两千集已经是几十万条的上游；再多就是异常数据
EPISODE_MAX = 2000

# CapyPlayer 规范里没有 `capabilities` 字段 —— 能力是由「有哪些模块 / 有没有
# loadDetail」隐含表达的。happy-capy 自己补了这个字段，属于**未文档化的扩展**，
# 所以只能当提示用（决定界面上要不要显示搜索入口），不能当权限用。
KNOWN_CAPS = ('browse', 'home', 'search', 'detail', 'playback')


def text(value, limit=0, default=''):
    """转成去空白的字符串；limit>0 时截断。非标量一律当空。"""
    if value is None or isinstance(value, (dict, list, tuple, set)):
        return default
    out = str(value).strip()
    if not out:
        return default
    return out[:limit] if limit > 0 else out


def integer(value, default=None):
    """宽松取整：'12' → 12，'12.0' → 12，'abc' → default。"""
    if isinstance(value, bool):
        return default
    if isinstance(value, int):
        return value
    try:
        return int(float(str(value).strip()))
    except (TypeError, ValueError):
        return default


def pick(src, *keys, limit=0, default=''):
    """按优先级取第一个非空文本值。

    这正是规范第 5 节那几张「字段映射优先级」表的实现方式：调用处把候选键
    按规范顺序写出来，可读性就是文档本身。
    """
    if not isinstance(src, dict):
        return default
    for key in keys:
        if key in src:
            got = text(src.get(key), limit=limit)
            if got:
                return got
    return default


# ── 组件（provider）─────────────────────────────────────────────────────
def norm_caps(raw):
    """能力列表：只留认识的，保序去重。空的表示「上游没写」。"""
    if not isinstance(raw, (list, tuple, set)):
        return []
    out, seen = [], set()
    for item in raw:
        cap = text(item, limit=24).lower()
        if cap and cap in KNOWN_CAPS and cap not in seen:
            seen.add(cap)
            out.append(cap)
    return out


def supports(provider, cap):
    """这个组件声不声称支持某项能力。

    ⚠️ 未知（上游没给 capabilities）一律返回 True —— 宁可多显示一个搜索框，
    也不要因为上游漏填字段就把功能藏起来。真实失败由请求层报错兜住。
    """
    caps = (provider or {}).get('caps') or []
    return True if not caps else cap in caps


def category(raw):
    """分类：id 必须稳（要拼进上游 URL），标题可以缺。"""
    if not isinstance(raw, dict):
        return None
    cid = text(raw.get('id'), limit=40)
    if not cid:
        return None
    return {'id': cid, 'title': text(raw.get('title') or raw.get('name'), limit=20, default=cid)}


def categories(raw):
    out, seen = [], set()
    for item in raw or []:
        cat = category(item)
        if cat and cat['id'] not in seen:
            seen.add(cat['id'])
            out.append(cat)
    return out


def provider(raw):
    """一个组件。id 不合法直接丢（它会拼进上游路径）。"""
    if not isinstance(raw, dict):
        return None
    pid = text(raw.get('id'), limit=32)
    if not pid or not PROVIDER_RE.match(pid):
        return None
    return {
        'id': pid,
        'title': text(raw.get('title') or raw.get('name'), limit=24, default=pid),
        'version': text(raw.get('version'), limit=16),
        'desc': text(raw.get('description') or raw.get('desc'), limit=80),
        'icon': text(raw.get('icon') or raw.get('iconUrl'), limit=300),
        'caps': norm_caps(raw.get('capabilities') or raw.get('caps')),
        'categories': categories(raw.get('categories')),
    }


def providers(payload):
    """`GET /api/v1/providers` 的载荷 → 归一化列表，保持上游顺序。

    顺序是有意义的：上游按它的推荐度排，本地要改顺序走覆盖层的 order，
    不要在这里擅自排序，否则「新增组件后位置乱跳」会很费解。
    """
    if not isinstance(payload, dict):
        return []
    out, seen = [], set()
    for item in payload.get('providers') or []:
        one = provider(item)
        if one and one['id'] not in seen:
            seen.add(one['id'])
            out.append(one)
    return out


# ── 网络模式（diagnostics）───────────────────────────────────────────────
# 上游还有一套 `GET /api/v1/diagnostics`，`results[<id>]` 里说明「这个组件由谁
# 去连源站」：
#
#   direct            服务器直连        容器自己访问源站，无需代理
#   mobile            手机端直连        播放器手机客户端直接拉流，不占服务器流量
#   proxy_suggested   建议海外代理      源站按地区限制，建议为它挂局部代理
#   proxy_configured  海外代理已配置    已经配了代理
#
# 这正是 CapyPlayer 首页卡片上展示的那四种说法。我们**照搬原文**，主人在两个
# 界面看到的话术才一致；自己另起一套名字只会让人以为是两件事。
#
# 🔴 上半游这套接口里还有一个 `diagnostic_text`，是含「问题定位」的多行报告，
# 里面会出现源站域名、连接失败的具体细节。那个字段**一个字节都不许下发** ——
# 主人要看的是「什么状态」，不是「上游在哪台机器上撞了什么墙」。
NETWORK_MODES = {
    'direct': '服务器直连',
    'mobile': '手机端直连',
    'proxy_suggested': '建议海外代理',
    'proxy_configured': '海外代理已配置',
}
# 组件卡只有半屏宽，全称放不下；短版只用于卡片徽章，详情里仍给全称
NETWORK_SHORT = {
    'direct': '直连',
    'mobile': '手机直连',
    'proxy_suggested': '需代理',
    'proxy_configured': '已配代理',
}
# 服务端那次检查是「必须过」还是「仅供参考」：
#   required_metadata        服务端取不到内容 = 列表和详情都是空的，真的坏了
#   reference_connectivity   只是参考，手机用自己的网络照样能看
NETWORK_ROLES = {
    'required_metadata': '服务端必须取到内容',
    'reference_connectivity': '服务端仅作参考',
}
CHECK_KEYS = ('basic', 'server', 'client', 'playback')
CHECK_STATES = ('passed', 'warning', 'failed', 'not_checked')
NETWORK_STATUSES = ('passed', 'warning', 'failed')

# 脱敏用的。上游的说明文字是按「给你自己看」写的，理论上会带上代理地址；
# 我们这张卡片是要给主人看的，所以形似地址 / 账号的片段整段换掉 ——
# 宁可文案变得含糊，也不让一个代理 IP 或密码出现在界面上。
_SECRET_RE = re.compile(
    r'[a-zA-Z][a-zA-Z0-9+.\-]*://\S+'             # scheme://host:port/path
    r'|\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b'      # 1.2.3.4[:7890]
    r'|\b(?:[a-z0-9\-]+\.)+[a-z]{2,6}\b'          # 源站域名
    r'|\b[\w.%+\-]+@[\w.\-]+\.\w{2,}\b'           # user@host
    r'|\b(?:password|passwd|pwd|token|secret|auth|proxy)\s*[=:]\s*\S+',
    re.IGNORECASE)


def scrub(value, limit=120):
    """去掉说明文字里可能存在的地址与账号，再截断。"""
    out = text(value, limit=0)
    if not out:
        return ''
    out = _SECRET_RE.sub('***', out)
    # 换掉之后可能留下连续的空白和「*** ***」，收一下
    out = re.sub(r'\s{2,}', ' ', out).strip()
    return out[:limit] if limit > 0 else out


def network(raw):
    """`diagnostics.results[<id>]` → 卡片要显示的那点东西。取不到就返回 `{}`。

    只取白名单字段：模式、四项检测的**状态**、服务端检查的角色、处置建议。
    检测项的 `label`/`text` 文案不要 —— 那些是上游的措辞，我们本地另有话说，
    而且文字越多越容易夹带地址。
    """
    if not isinstance(raw, dict):
        return {}
    mode = text(raw.get('network_mode'), limit=32).lower()
    known = mode in NETWORK_MODES

    checks = {}
    raw_checks = raw.get('checks')
    if isinstance(raw_checks, dict):
        for key in CHECK_KEYS:
            one = raw_checks.get(key)
            state = text(one.get('status') if isinstance(one, dict) else one, limit=16).lower()
            if state in CHECK_STATES:            # 不认识的状态直接丢，别猜
                checks[key] = state

    role = text(raw.get('server_check_role'), limit=32).lower()
    status = text(raw.get('status'), limit=16).lower()
    out = {
        # mode 为空 = 上游没标（内建源就是这样），界面上就不显示徽章
        'mode': mode if known else '',
        'label': NETWORK_MODES.get(mode) or scrub(raw.get('network_text'), 16),
        'short': NETWORK_SHORT.get(mode) or '',
        # 上游给了个我们不认识的模式：原文留着给排障，但绝不冒充已知模式
        'unknown': '' if known or not mode else scrub(mode, 24),
        'status': status if status in NETWORK_STATUSES else '',
        'role': role if role in NETWORK_ROLES else '',
        'checks': checks,
        'hint': scrub(raw.get('impact_hint'), 120),
        # historical = 上游这份结果是从缓存里拿的（超过它的 600 秒窗口）
        'stale': bool(raw.get('historical')),
    }
    if not (out['label'] or out['checks'] or out['status'] or out['unknown']):
        return {}
    return out


def nets(payload):
    """`GET /api/v1/diagnostics` 的载荷 → {组件 id: 网络模式}。

    缺项是常态：上游只诊断它自己排的那一批（本机 17 个组件里只覆盖 9 个），
    所以调用方必须按「取不到就没有」来处理，不能当成「这个组件不通」。
    """
    if not isinstance(payload, dict):
        return {}
    results = payload.get('results')
    if not isinstance(results, dict):
        return {}
    out = {}
    for pid, raw in results.items():
        pid = text(pid, limit=32)
        if not pid or not PROVIDER_RE.match(pid):
            continue
        one = network(raw)
        if one:
            out[pid] = one
    return out


# ── 条目（MediaItem）────────────────────────────────────────────────────
def item(raw):
    """一条内容。规范：id 与 title/name 是唯一必填，其余全可缺。"""
    if not isinstance(raw, dict):
        return None
    iid = pick(raw, 'id', 'mediaId', limit=160)
    if not iid or '..' in iid or not ITEM_RE.match(iid):
        return None
    title = pick(raw, 'title', 'name', limit=120)
    if not title:
        return None
    media_type = pick(raw, 'mediaType', 'media_type', limit=16).lower()
    if media_type not in ('movie', 'tv', 'series', 'show'):
        media_type = ''
    return {
        'id': iid,
        'title': title,
        # 规范的图字段优先级：posterUrl → poster_url → poster → posterPath → coverUrl
        'poster': pick(raw, 'posterUrl', 'poster_url', 'poster', 'posterPath', 'coverUrl', limit=600),
        'remark': pick(raw, 'remark', 'note', limit=16),
        'desc': pick(raw, 'description', 'overview', 'desc', limit=400),
        'mediaType': media_type,
        'year': pick(raw, 'year', limit=4),
        'rating': raw.get('rating') if isinstance(raw.get('rating'), (int, float)) else None,
    }


def items(raw_list):
    out = []
    for raw in raw_list or []:
        one = item(raw)
        if one:
            out.append(one)
    return out


def page_meta(payload, fallback_page=1):
    """列表分页信息。上游给 pageCount/total，别再让前端靠「有没有 40 条」猜。"""
    payload = payload if isinstance(payload, dict) else {}
    page = integer(payload.get('page'), fallback_page) or fallback_page
    return {
        'page': page,
        'pageCount': max(0, integer(payload.get('pageCount'), 0) or 0),
        'total': max(0, integer(payload.get('total'), 0) or 0),
    }


# ── 剧集（detail）────────────────────────────────────────────────────────
# 播放地址的候选键：happy-capy 直出 streamUrl，CapyPlayer 规范用 videoUrl，
# 剧果那种要二次解析的给 mediaUrl + resolveUrl。顺序 = 越靠前越可能是真直链。
_URL_KEYS = ('streamUrl', 'videoUrl', 'video_url', 'url', 'path', 'link', 'mediaUrl')
_RESOLVE_KEYS = ('resolveUrl', 'resolve_url', 'resolve')
_NUM_KEYS = ('episodeNumber', 'episode_number', 'episode', 'ep')
_TITLE_KEYS = ('title', 'name')


def _play_source_url(raw):
    """`playSources` 是规范里多线路的写法；取默认线路，没标默认就取第一条。"""
    sources = raw.get('playSources') or raw.get('play_sources')
    if not isinstance(sources, list):
        return ''
    best = ''
    for one in sources:
        if not isinstance(one, dict):
            continue
        url = pick(one, 'videoUrl', 'video_url', 'url', 'path', 'link', limit=1200)
        if not url:
            continue
        if one.get('isDefault') or one.get('is_default'):
            return url
        best = best or url
    return best


def episode(raw, ordinal=1, season=1):
    """一集。没有可播地址的直接丢 —— 它在选集页上就是个死按钮。"""
    if not isinstance(raw, dict):
        return None
    url = pick(raw, *_URL_KEYS, limit=1200) or _play_source_url(raw)
    resolve = pick(raw, *_RESOLVE_KEYS, limit=1200)
    if not url and not resolve:
        return None
    number = integer(pick(raw, *_NUM_KEYS), ordinal)
    if number is None or number < 1 or number > EPISODE_MAX:
        number = ordinal
    return {
        'n': number,
        'title': pick(raw, *_TITLE_KEYS, limit=40, default=f'第{number}集'),
        'url': url,
        'resolve': resolve,
        'season': season,
    }


def _season_list(raw):
    """季结构：规范用 seasons → seasonItems，每季里 episodes → episodeItems。"""
    for key in ('seasons', 'seasonItems', 'season_items'):
        got = raw.get(key)
        if isinstance(got, list):
            return got, key
    return [], ''


def episodes(payload):
    """详情载荷 → 扁平剧集列表。

    兼容三种真实形态（都实测过）：
      ① seasons[].episodes[]            红果 / 蜜桃 / 剧果
      ② 顶层 episodeItems / episodes[]  规范里的扁平写法
      ③ 顶层 videoUrl / playUrl / url   movie 类只有一个播放地址
    第 ③ 种以前会被当成「没有可播的剧集」直接 404，是本次补上的关键缺口。
    """
    if not isinstance(payload, dict):
        return []
    out, seen = [], set()

    def take(raw, ordinal, season):
        one = episode(raw, ordinal, season)
        if not one:
            return
        key = (one['season'], one['n'])
        if key in seen:                     # 同季同集号重复：留先到的
            return
        seen.add(key)
        out.append(one)

    seasons, _ = _season_list(payload)
    for index, season in enumerate(seasons, start=1):
        if not isinstance(season, dict):
            continue
        number = integer(pick(season, 'seasonNumber', 'season_number', 'season'), index) or index
        eps = None
        for key in ('episodes', 'episodeItems', 'episode_items'):
            if isinstance(season.get(key), list):
                eps = season[key]
                break
        for ordinal, raw in enumerate(eps or [], start=1):
            take(raw, ordinal, number)

    if not out:
        for key in ('episodeItems', 'episode_items', 'episodes'):
            flat = payload.get(key)
            if isinstance(flat, list) and flat:
                for ordinal, raw in enumerate(flat, start=1):
                    season = 1
                    if isinstance(raw, dict):
                        season = integer(pick(raw, 'seasonNumber', 'season_number', 'season'), 1) or 1
                    take(raw, ordinal, season)
                break

    if not out:
        # movie：整部片子就一个地址。playSources 也算（规范的单集多线路写法）。
        url = pick(payload, 'videoUrl', 'video_url', 'playUrl', 'play_url',
                   'url', 'streamUrl', 'mediaUrl', limit=1200) or _play_source_url(payload)
        resolve = pick(payload, *_RESOLVE_KEYS, limit=1200)
        if url or resolve:
            number = integer(pick(payload, *_NUM_KEYS), 1) or 1
            out.append({
                'n': max(1, min(number, EPISODE_MAX)),
                'title': pick(payload, 'currentEpisodeName', 'episodeTitle', limit=40,
                              default='正片'),
                'url': url,
                'resolve': resolve,
                'season': integer(pick(payload, 'currentSeason', 'current_season'), 1) or 1,
            })

    out.sort(key=lambda e: (e['season'], e['n']))
    return out[:EPISODE_MAX]


def detail(item_id, payload):
    """详情归一化。拿不到任何一集就当 404 交给上层，别吐出空壳。

    返回的 `episodes` **含直链**，只供服务端内部用；对外的 `detail()` 会剥掉。
    """
    payload = payload if isinstance(payload, dict) else {}
    eps = episodes(payload)
    if not eps:
        return None
    media_type = pick(payload, 'mediaType', 'media_type', limit=16).lower() or 'tv'
    return {
        'id': text(item_id, limit=160),
        'title': pick(payload, 'title', 'name', limit=120, default='未命名'),
        'poster': pick(payload, 'posterUrl', 'poster_url', 'poster', 'posterPath',
                       'coverUrl', limit=600),
        'description': pick(payload, 'description', 'overview', limit=600),
        'mediaType': media_type,
        'episodes': eps,
    }


def public_detail(data):
    """对前端下发用：**不含直链**（签名约 24 小时过期，下发只会变成隔天打不开的地址）。"""
    return {
        'id': data['id'],
        'title': data['title'],
        'poster': data['poster'],
        'description': data['description'],
        'mediaType': data.get('mediaType') or 'tv',
        'episodes': [{'n': e['n'], 'title': e['title']} for e in data['episodes']],
    }
