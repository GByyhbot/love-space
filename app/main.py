import asyncio
import contextlib
import datetime as dt
import io
import ipaddress
import json
import logging
import os
import re
import secrets
import shutil
import socket
import threading
import time
import zipfile
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import quote, urlparse
from zoneinfo import ZoneInfo

import httpx

from fastapi import Depends, FastAPI, File, Form, HTTPException, Request, Response, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from PIL import Image
from pydantic import BaseModel, Field
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.middleware.gzip import GZipMiddleware

from . import db
from . import importers
from . import period
from .config import APK_VERSION, BUILD_ID, WEB_VERSION, SPACE_ROUTES, route_origins
from .serializers import serialize, serialize_many
from . import webpush as webpush_service
from .db import connect, dumps, now, uid
from .security import PURPOSE_CHANNEL_CONFIG, PURPOSE_POSE_AI, cipher, current_user, digest_token, login_session, open_sealed, password_hash, password_ok, personal_wish_decrypt, personal_wish_encrypt, rate_limit, seal_for_owner


@asynccontextmanager
async def lifespan(app):
    db.init()
    cipher()
    try:
        moved = db.migrate_media_layout()
        if moved:
            logging.getLogger('love').info('媒体目录归位：%d 个文件迁移到分类子目录', moved)
    except Exception:
        # 迁移失败不该让整个应用起不来，但要留下原因——否则磁盘满/权限错会以
        # "附件莫名 404" 的形式出现，排查时一点线索都没有
        logging.getLogger('love').exception('媒体目录迁移失败，旧布局的附件可能不可访问')
    # 生理期独立库：建表 + 把主库里遗留的 period 行搬过去（幂等，搬完就没有可搬的了）
    try:
        period.init()
        moved = period.migrate_from_main()
        if moved:
            logging.getLogger('love').info('生理期已迁入独立库 period.db：%d 条', moved)
    except Exception:
        # 迁不动就退回到主库读取（接口两头都查），不能因为搬库失败让健康数据"消失"
        logging.getLogger('love').exception('生理期迁库失败，暂时仍从主库读取')
    stop = threading.Event()
    from .worker import run
    worker = None
    if os.getenv('RUN_WORKER', 'true') == 'true':
        worker = threading.Thread(target=run, args=(stop,), daemon=True)
        worker.start()
    yield
    stop.set()
    if worker:
        await asyncio.to_thread(worker.join, 15)


app = FastAPI(title='恋爱空间', lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


class SelectiveGZip(GZipMiddleware):
    """gzip 压缩，但放过 SSE 与已压缩的二进制流。

    GZipMiddleware 对没有 content-length 的响应是"边收边压"，这和 SSE 天然冲突：
    `data:` 帧会被攒在压缩缓冲区里（deflate 通常要几百字节到几 KB 才吐一次），
    心跳和实时提醒就全失去了意义。视频/图片本来就是压缩格式，再 gzip 只是白烧 CPU，
    而且压缩过的流不支持 Range，视频拖动进度条会直接坏掉。
    """

    PASSTHROUGH = ('/api/events', '/media/', '/api/export')

    async def __call__(self, scope, receive, send):
        if scope['type'] == 'http' and scope['path'].startswith(self.PASSTHROUGH):
            await self.app(scope, receive, send)
            return
        await super().__call__(scope, receive, send)


# 必须加在所有其它中间件之前注册？不需要：Starlette 里最后 add 的在最外层，
# 压缩在外层才能压到内层写完的响应体。
app.add_middleware(SelectiveGZip, minimum_size=1024)

log = logging.getLogger('love.space')


def nudge_worker():
    """唤醒后台投递循环。唤醒失败不影响请求本身，但要把原因留在日志里。"""
    try:
        from . import worker
        worker.nudge()
    except Exception:
        log.debug('唤醒后台投递循环失败', exc_info=True)


def ntfy_enabled():
    """内置 ntfy 系统推送总开关（默认关闭）。

    背景：手机端弹窗/锁屏推送已改由第三方渠道（企业微信等）+ 浏览器 Web Push 承担，
    db.notice() 不再写 push_outbox —— 也就是说服务端根本不往 ntfy 发消息，
    前端 WebSocket 与原生前台服务都成了空转（白占常驻通知与电量）。
    关闭后 /api/me 不再下发 topic，前端自然不连 WS、原生也不启动/立即停止服务。
    恢复：.env 里设 NTFY_ENABLED=1 并重建容器即可，代码与配置都在。
    """
    return os.getenv('NTFY_ENABLED', '0').strip().lower() in {'1', 'true', 'yes', 'on'}


def ntfy_server_url():
    configured = os.getenv('NTFY_SERVER', 'https://ntfy.350921.xyz').rstrip('/')
    parsed = urlparse(configured)
    try:
        if parsed.scheme == 'https' and parsed.hostname and not parsed.username and not parsed.password and parsed.port in (None, 443):
            return configured
    except ValueError:
        pass
    return 'https://ntfy.350921.xyz'


# 已下沉到 app/config.py（webpush 要用它，而 main 又 import 了 webpush）


# 多线路（不同域名）共用同一后端时，Origin 常被中间层（节点小宝等反代）改写成内网地址；
# 以 Host / X-Forwarded-Host 命中的「已知线路域名」判定来源即可。写操作另有 X-Love-Space
# 头把关（跨站表单/请求无法携带自定义头），故这里放宽到一组可信域名是安全的。
_BUILTIN_TRUSTED_HOSTS = {
    'love.yangyuhui.xyz', 'love-space.iepose.cn', 'love.350921.xyz',
    'love-space.yangyuhui.xyz', 'fn.350921.xyz', 'yangyuhui86.top',
}


def _trusted_hosts() -> set:
    hosts = {h.lower() for h in _BUILTIN_TRUSTED_HOSTS}
    pu = os.getenv('PUBLIC_URL', '').rstrip('/')
    if pu:
        h = urlparse(pu).hostname
        if h:
            hosts.add(h.lower())
    for h in os.getenv('ALLOWED_HOSTS', '').split(','):
        h = h.strip().lower()
        if h:
            hosts.add(h)
    return hosts


def origin_allowed(origin: str, request: Request) -> bool:
    trusted = _trusted_hosts()
    forwarded = request.headers.get('x-forwarded-host') or request.headers.get('host', '')
    req_host = urlparse('//' + forwarded.split(',')[0].strip()).hostname
    host_hdr = request.headers.get('host', '')
    host_name = urlparse('//' + host_hdr.split(',')[0].strip()).hostname
    # 请求经已知线路域名进来（Host / X-Forwarded-Host 命中）→ 放行，不再死磕被改写的 Origin
    if req_host and req_host.lower() in trusted:
        return True
    if host_name and host_name.lower() in trusted:
        return True
    if not origin:
        return True
    origin_host = urlparse(origin).hostname
    if not origin_host:
        return True
    if origin_host.lower() in trusted:
        return True
    if req_host and origin_host.lower() == req_host.lower():
        return True
    if host_name and origin_host.lower() == host_name.lower():
        return True
    return False


def private_host(host: str | None) -> bool:
    """内网/本机直连判定：私有 IP、回环、链路本地、单段主机名、.local/.lan 等。

    局域网里敲 `http://192.168.31.95:1314` 或手机连同一个 WiFi 打开 nas 名字，
    属于主人明确要的用法：这类请求放行明文，既不跳公网域名，也不下发 HSTS
    （HSTS 一旦被浏览器记住，这个地址以后只能走 https，反而打不开）。
    """
    if not host:
        return False
    h = host.strip().strip('[]').lower()
    if h.startswith('::ffff:'):  # IPv4-mapped IPv6
        h = h[7:]
    if h in {'localhost', 'localhost.localdomain'} or h.endswith(('.local', '.lan', '.internal', '.home')):
        return True
    try:
        ip = ipaddress.ip_address(h)
    except ValueError:
        # 不带点的主机名（nas / fnos / love-space）当内网
        return '.' not in h
    return ip.is_private or ip.is_loopback or ip.is_link_local


@app.middleware('http')
async def protection(request, call_next):
    public_url = os.getenv('PUBLIC_URL', '').rstrip('/')
    forwarded_host = request.headers.get('x-forwarded-host') or request.headers.get('host', '')
    request_host = urlparse('//' + forwarded_host.split(',')[0].strip()).hostname
    forwarded_proto = request.headers.get('x-forwarded-proto', '').split(',')[0].strip().lower()
    is_https = forwarded_proto == 'https' or request.url.scheme == 'https'
    # 内网**明文**直连：不跳公网域名、不发 HSTS。判定看 Host，并在「Host 是域名（非 IP）
    # 且对端 IP 是内网」时也视为内网——用 DDNS/路由器域名从局域网访问时 Host 不像内网，
    # 但对端是内网，若不豁免会被 308 甩到公网穿透地址（穿透被封时直接打不开）。
    # 注意：Host 是纯 IP 时**不**走对端豁免，公网 IP 仍按原规则跳公网域名（见验收测试）。
    peer_host = request.client.host if request.client else ''
    peer_private = private_host(peer_host) if peer_host else False
    host_is_domain = bool(request_host)
    if host_is_domain:
        try:
            ipaddress.ip_address(request_host.strip().strip('[]'))
            host_is_domain = False
        except ValueError:
            pass
    local_access = (private_host(request_host) or (peer_private and host_is_domain)) and not is_https
    if public_url.startswith('https://') and request.url.path != '/health':
        public_host = urlparse(public_url).hostname
        origin = request.headers.get('origin', '')
        origin_host = urlparse(origin).hostname if origin else None
        trusted = _trusted_hosts()
        host_trusted = bool(
            (request_host and request_host.lower() in trusted)
            or (origin_host and origin_host.lower() in trusted))
        is_public_host = public_host and (
            host_trusted
            or any(host and host.lower() == public_host.lower() for host in (request_host, origin_host))
            or is_https)
        if public_host and not is_public_host and not local_access:
            if request.method in {'GET', 'HEAD'}:
                return RedirectResponse(public_url + request.url.path + (('?' + request.url.query) if request.url.query else ''), status_code=308)
            return JSONResponse({'detail': '请通过 HTTPS 域名访问恋爱空间'}, status_code=403)
    if request.method in {'POST', 'PUT', 'PATCH', 'DELETE'}:
        # /api/proxy 由内置图库的「AI 合成台」调用，那份第三方前端不认识我们自加的
        # X-Love-Space 头；该端点自身要求登录 + 公网目标校验（跨站 JSON POST 会先被
        # CORS 预检拦下，拿不到响应），所以这里不靠这个头给它做防护。
        if request.headers.get('X-Love-Space') != '1' and request.url.path != '/api/proxy':
            return JSONResponse({'detail': '请求校验失败，请刷新页面'}, status_code=403)
        origin = request.headers.get('origin')
        if origin and not origin_allowed(origin, request):
            logging.getLogger('love.space').warning(
                'origin rejected: origin=%s host=%s xfh=%s', origin,
                request.headers.get('host', ''), request.headers.get('x-forwarded-host', ''))
            return JSONResponse({'detail': '来源校验失败'}, status_code=403)
    result = await call_next(request)
    result.headers['X-Content-Type-Options'] = 'nosniff'
    result.headers['Referrer-Policy'] = 'same-origin'
    # HTML 外壳（唯一一个 index.html）必须每次回源校验：以前只有 ETag/Last-Modified，
    # 没有 Cache-Control，Android WebView 会按"启发式缓存"直接吃本地副本，可能连续几天
    # 用旧的 index.html 和旧的 ?v= 资源——正是「刚发完版 App 里还是老逻辑」的元凶。
    # 静态资源仍靠 ?v= 破缓存，离线由 Service Worker 兜底，所以这里 no-store 不会牺牲可用性。
    if request.url.path in ('/', '/index.html') or request.url.path.endswith('.html'):
        result.headers['Cache-Control'] = 'no-store'
    # /pose-gallery/ 是同源被本应用 iframe 嵌入的姿势参考站，必须允许同源框入；
    # 其余响应保持 DENY，避免被任意第三方框入（与 CSP frame-ancestors 'none' 双保险）。
    result.headers['X-Frame-Options'] = (
        'SAMEORIGIN' if request.url.path.startswith('/pose-gallery/') else 'DENY')
    if request.url.path == '/static/sw.js':
        result.headers['Service-Worker-Allowed'] = '/'
    push_origin = urlparse(ntfy_server_url())
    push_host = push_origin.hostname or 'ntfy.350921.xyz'
    if ':' in push_host and not push_host.startswith('['):
        push_host = '[' + push_host + ']'
    push_port = f':{push_origin.port}' if push_origin.port and push_origin.port != 443 else ''
    # connect-src 除了推送服务器，还要放通四条线路自身的 origin：
    # 「链路检测」页在浏览器里用 fetch 跨域打点，CSP 少一个 origin 就等于
    # 那条线路直接被判死（报错在控制台，页面上只显示「不可达」）。
    route_src = ' '.join(route_origins())
    connect_src = (
        f"connect-src 'self' https://{push_host}{push_port} wss://{push_host}{push_port}"
        + (f' {route_src}' if route_src else '')
    )
    # 姿势参考图库（/pose-gallery/）已同源托管在本地（原外链 ai-pose-gallery.anhao.app 退役）：
    # 它是我们自己静态目录里的开源静态站，允许其内联脚本/样式运行（原生 JS 画廊常含内联脚本，
    # 严格 CSP 会把它整页拦成空白）；该路径与主体接口隔离，放宽不波及其余请求。
    if request.url.path.startswith('/pose-gallery/'):
        # img-src 放开 https：AI 合成台在 response_format=url 时直接引用各家 CDN 的
        # 出图地址（*.byteimg.com / *.volces.com 等，域名不固定，无法逐个列出）。
        result.headers['Content-Security-Policy'] = (
            "default-src 'self'; img-src 'self' data: blob: https:; media-src 'self' blob: https:; "
            "style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; "
            "frame-src 'self'; connect-src 'self'; base-uri 'self'; form-action 'self'"
        )
    else:
        # frame-src 仅 'self'：figure 页的姿势参考 iframe 现为同源 /pose-gallery/
        result.headers['Content-Security-Policy'] = f"default-src 'self'; img-src 'self' blob: data:; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; script-src 'self'; frame-src 'self'; {connect_src}; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
    if public_url.startswith('https://') and not local_access:
        result.headers['Strict-Transport-Security'] = 'max-age=31536000'
    if request.url.path.startswith('/media/') and request.query_params.get('role') == 'cover':
        # 首页封面单独放行缓存。三个约束缺一不可：
        #   ① 不能是 no-store —— Cache API 的 put() 会直接拒绝带 no-store 的响应，
        #      Service Worker 那条 cache-first 就永远存不进去；
        #   ② 必须 private —— 这是两个人的照片，绝不能进 Cloudflare 之类的共享缓存；
        #   ③ max-age=0 + must-revalidate —— SW 没接管时（首次访问/旧 WebView）退化成 304，
        #      靠 ETag 校验，不会重传整张图。
        # 只有封面走这条路，相册/聊天里的图仍然 no-store：它们量太大，也不该长期躺在设备上。
        result.headers['Cache-Control'] = 'private, max-age=0, must-revalidate'
    elif request.url.path.startswith(('/api/', '/media/')):
        result.headers['Cache-Control'] = 'no-store'
    elif request.url.path.startswith('/static/stickers/'):
        # 贴纸文件内容不变，按内容寻址永久缓存，二次加载走本地缓存
        result.headers['Cache-Control'] = 'public, max-age=31536000, immutable'
    return result


class Credentials(BaseModel):
    username: str = Field(min_length=3, max_length=40, pattern=r'^[a-zA-Z0-9_.@-]+$')
    password: str = Field(min_length=10, max_length=128)
    name: str = Field(default='亲爱的', min_length=1, max_length=30)
    token: str = Field(default='', max_length=200)


def public_user(row):
    return {k: row[k] for k in ('id', 'username', 'name', 'admin', 'avatar')}


# ---- APK 分发：站内静态副本优先，GitHub Release 兜底 -------------------------
# 本仓是私有的 → Release 资产对匿名请求一律 404，免认证的加速代理
# （ghfast.top / ghproxy 系、含 GitHub 原始地址）同样取不到，实测全挂。
# 所以默认改为下发站内副本 static/lovespace.apk：它随镜像发布、本来就在
# Cloudflare 隧道后面，手机点开即下，不依赖任何第三方代理。
# ?direct=1 仍指回 GitHub 原始地址，给自己留一个走 Release 页的口子。
APK_REPO = (os.getenv('APK_GITHUB_REPO') or 'GByyhbot/love-space').strip()
APK_PROXY = (os.getenv('APK_PROXY_PREFIX') or '').strip()  # 仓库公开后填代理前缀才有意义
_APK_STATIC_FILE = Path(__file__).resolve().parent.parent / 'static' / 'lovespace.apk'


def _apk_github_url(ver=None):
    ver = ver or APK_VERSION
    return f'https://github.com/{APK_REPO}/releases/download/v{ver}/app-release.apk'


def _apk_local_url():
    """站内副本地址。带 ?v= 版本号，规避 WebView / 浏览器对同名文件的旧缓存。"""
    return f'/static/lovespace.apk?v={APK_VERSION}'


_APK_NOTES_FILE = Path(__file__).resolve().parent.parent / 'static' / 'apk-notes.txt'


def _apk_notes():
    """本次更新的说明文字（维护在 static/apk-notes.txt，随发版手改即可）。"""
    try:
        return _APK_NOTES_FILE.read_text(encoding='utf-8').strip()[:800]
    except Exception:
        return ''


@app.get('/apk/download')
def apk_download(direct: int = 0):
    # 同源 302：WebView/Capacitor 只看到 /apk/download，不会拦外链导航
    if not direct and _APK_STATIC_FILE.exists():
        return RedirectResponse(_apk_local_url(), status_code=302)
    url = _apk_github_url()
    if not direct and APK_PROXY:
        url = APK_PROXY.rstrip('/') + '/' + url
    return RedirectResponse(url, status_code=302)


@app.get('/api/status')
def status():
    with connect() as c:
        count = c.execute('SELECT count(*) FROM users').fetchone()[0]
    return {'initialized': count > 0, 'paired': count == 2, 'setup_token_required': bool(os.getenv('SETUP_TOKEN')),
            'version': WEB_VERSION, 'build': BUILD_ID,
            'apk_version': APK_VERSION,
            'apk_url': '/apk/download',
            'apk_mirror': _apk_local_url(),
            'apk_has_local': _APK_STATIC_FILE.exists(),
            'apk_url_direct': _apk_github_url(),
            'apk_proxy': APK_PROXY,
            'apk_notes': _apk_notes()}


@app.get('/health')
def health():
    with connect() as c:
        c.execute('SELECT 1')
    return {'status': 'ok'}


@app.get('/api/routes')
def routes():
    """可选线路清单（前端「链路检测」用它渲染，不再自己硬编码一份）。

    不涉密：这些域名本来就是公开入口，谁访问都能看到首页。
    """
    return {'routes': [{'name': name, 'url': url} for name, url in SPACE_ROUTES]}


# ---- AI 合成台同源转发（/pose-gallery 里「AI 合成台」的出图通道） --------------
# 内置图库前端默认 useProxy=true：它把出图请求 POST 到**同源** /api/proxy，真实目标
# 地址放在 x-target-url 头里。本服务没有这个端点时，前端拿到的是
# {"detail":"Not Found"}（HTTP 404），界面上就表现为「配好豆包/千问却生成失败」。
# 这里补上转发：API Key 仍由浏览器随请求带来（只存在各自浏览器里），但由服务端
# 代为出网——既绕开浏览器 CORS，也不必为了各家 API 放开 CSP 的 connect-src。
# 出网代理用 AI_PROXY（可选，例：http://192.168.31.95:7890）；不设则直连，
# 豆包/千问等国内端点直连即可，gemini/openai 需要境外出口时才配。
_AI_PROXY_MAX_BODY = 24 * 1024 * 1024
_AI_PROXY_PASS_HEADERS = ('content-type', 'authorization', 'x-goog-api-key', 'accept')


def _ai_proxy_target(raw: str) -> str:
    """校验并返回可转发的目标 URL。只放行 http/https 公网地址（挡 SSRF）。"""
    raw = (raw or '').strip()
    if not raw:
        raise HTTPException(400, '缺少 x-target-url')
    try:
        parts = urlparse(raw)
        port = parts.port  # 非法端口在这里抛 ValueError
    except ValueError:
        raise HTTPException(400, '目标地址无效')
    if parts.scheme not in ('http', 'https') or not parts.hostname:
        raise HTTPException(400, '目标地址无效')
    allow = [h.strip().lower() for h in os.getenv('AI_PROXY_ALLOW_HOSTS', '').split(',') if h.strip()]
    if allow and parts.hostname.lower() not in allow:
        raise HTTPException(403, '目标地址不在允许列表内')
    try:
        infos = socket.getaddrinfo(parts.hostname, port or (443 if parts.scheme == 'https' else 80),
                                   proto=socket.IPPROTO_TCP)
    except OSError:
        raise HTTPException(400, '目标地址无法解析')
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast:
            raise HTTPException(403, '目标地址指向内网，已拒绝')
    return raw


@app.post('/api/proxy')
async def ai_proxy(request: Request, user=Depends(current_user)):
    target = _ai_proxy_target(request.headers.get('x-target-url', ''))
    body = await request.body()
    if len(body) > _AI_PROXY_MAX_BODY:
        raise HTTPException(413, '参考图过大，请减少张数或压缩后再试')
    headers = {k: request.headers[k] for k in _AI_PROXY_PASS_HEADERS if request.headers.get(k)}
    proxy = os.getenv('AI_PROXY', '').strip() or None
    started = time.monotonic()
    try:
        async with httpx.AsyncClient(
                timeout=httpx.Timeout(300.0, connect=15.0), follow_redirects=False,
                trust_env=False, proxy=proxy) as client:
            upstream = await client.post(target, content=body, headers=headers)
    except httpx.HTTPError as exc:
        logging.getLogger('love.space').warning('ai proxy failed: %s %s', target, exc.__class__.__name__)
        return JSONResponse(
            {'error': {'message': f'上游不可达（{exc.__class__.__name__}），请检查网络或 AI_PROXY 设置'}},
            status_code=502)
    # 出图是长请求，503/504 到底是「账号没开通」还是「中间层超时」只能靠这条日志区分：
    # 成功与失败都用 warning 级别打，是因为 uvicorn 只把 WARNING 以上送到容器 stdout。
    elapsed = time.monotonic() - started
    host = urlparse(target).hostname or ''
    log = logging.getLogger('love.space')
    if upstream.status_code >= 400:
        try:
            detail = ((upstream.json() or {}).get('error') or {}).get('message', '')
        except Exception:
            detail = upstream.text[:240]
        log.warning('ai proxy 失败 %s %s %.1fs %s', upstream.status_code, host, elapsed, (detail or '')[:240])
    else:
        log.warning('ai proxy 成功 %s %s %.1fs %dB', upstream.status_code, host, elapsed, len(upstream.content))
    media = (upstream.headers.get('content-type') or 'application/json').split(';')[0].strip()
    return Response(content=upstream.content, status_code=upstream.status_code, media_type=media)


# ---- AI 合成台配置落库（图库前端只在 localStorage 存一份，换设备就得重填 Key）----
# 上游把整份 provider 配置（含各家 API Key）放在 localStorage 的
# pose_atlas_api_config_v3 里，清缓存/换手机就没了。这里存一份到 settings 表，
# 按用途单独加密；图库外壳页会注入脚本做双向同步（见 _POSE_AI_BOOT）。
# Key 明文只出现在「浏览器 ↔ 本服务」这一段，落盘是密文，不进日志。
_POSE_AI_KEY = 'pose_ai_config'
_POSE_AI_MAX = 16 * 1024


class PoseAiConfig(BaseModel):
    config: dict


@app.get('/api/pose-ai/config')
def pose_ai_config_get(user=Depends(current_user)):
    with connect() as c:
        row = c.execute('SELECT value FROM settings WHERE key=?', (_POSE_AI_KEY,)).fetchone()
    if not row:
        return {'config': None, 'saved': 0}
    try:
        stored = json.loads(cipher(PURPOSE_POSE_AI).decrypt(row['value'].encode()).decode())
    except Exception:
        logging.getLogger('love.space').warning('pose-ai 配置解不开，按空处理')
        return {'config': None, 'saved': 0}
    return {'config': stored.get('config'), 'saved': stored.get('saved', 0)}


@app.put('/api/pose-ai/config')
def pose_ai_config_put(body: PoseAiConfig, user=Depends(current_user)):
    payload = json.dumps(body.config, ensure_ascii=False)
    if len(payload.encode()) > _POSE_AI_MAX:
        raise HTTPException(413, '配置过大，请检查是否选错了字段')
    with connect() as c:
        row = c.execute('SELECT value FROM settings WHERE key=?', (_POSE_AI_KEY,)).fetchone()
        if row:
            # 内容没变就别写库：图库每次打开都会回写一次，若无条件更新 saved 时间戳，
            # 下次加载又会被判成「NAS 上有更新的版本」→ 覆盖本地 → 再回写，无限抖动。
            try:
                old = json.loads(cipher(PURPOSE_POSE_AI).decrypt(row['value'].encode()).decode())
                if old.get('config') == body.config:
                    return {'ok': True, 'saved': old.get('saved', 0), 'unchanged': True}
            except Exception:
                pass
        stored = {'config': body.config, 'saved': int(now() * 1000)}
        sealed = cipher(PURPOSE_POSE_AI).encrypt(json.dumps(stored, ensure_ascii=False).encode()).decode()
        c.execute('INSERT INTO settings(key,value) VALUES(?,?) '
                  'ON CONFLICT(key) DO UPDATE SET value=excluded.value', (_POSE_AI_KEY, sealed))
    return {'ok': True, 'saved': stored['saved']}


# ---- AI 合成台的「生成记录」落库 ----
# 上游把记录写进 IndexedDB，而记录里的 imageUrl 常常是 data:image/png;base64 的一整张图
# （1–4MB/张，Gemini、通义、OpenAI 的 b64 分支都是），30 条就是上百 MB —— IndexedDB 一旦
# 写不进配额，下次打开就只剩个空列表，表现就是「生成的记录不能保留」。
# 所以这里只收「瘦记录」：图由注入脚本先转存到本站 /media 换成短 URL；data: 一律丢弃
# （截断的 base64 渲染出来是坏图，不如不给）。
_POSE_AI_HIS_KEY = 'pose_ai_history'
_POSE_AI_MEDIA_KEY = 'pose_ai_media'
_POSE_AI_HIS_MAX = 256 * 1024
_POSE_AI_HIS_ITEMS = 30
_HIS_FIELDS = ('id', 'createdAt', 'provider', 'model', 'prompt', 'recipeSummary')


def _clean_history(raw) -> list:
    out = []
    for it in raw if isinstance(raw, list) else []:
        if not isinstance(it, dict):
            continue
        row = {}
        for key in _HIS_FIELDS:
            val = it.get(key)
            if isinstance(val, str) and key != 'createdAt':
                row[key] = val[:2000] if key != 'prompt' else val[:4000]
            elif isinstance(val, (int, float)) and not isinstance(val, bool):
                row[key] = val
        if not (row.get('id') or row.get('createdAt')):
            continue
        img = it.get('imageUrl')
        if isinstance(img, str) and img and not img.startswith('data:'):
            row['imageUrl'] = img[:1000]
        out.append(row)
        if len(out) >= _POSE_AI_HIS_ITEMS:
            break
    return out


class PoseAiHistory(BaseModel):
    items: list


@app.get('/api/pose-ai/history')
def pose_ai_history_get(user=Depends(current_user)):
    with connect() as c:
        row = c.execute('SELECT value FROM settings WHERE key=?', (_POSE_AI_HIS_KEY,)).fetchone()
    if not row:
        return {'items': [], 'saved': 0}
    try:
        stored = json.loads(cipher(PURPOSE_POSE_AI).decrypt(row['value'].encode()).decode())
    except Exception:
        logging.getLogger('love.space').warning('pose-ai 历史解不开，按空处理')
        return {'items': [], 'saved': 0}
    return {'items': _clean_history(stored.get('items')), 'saved': stored.get('saved', 0)}


@app.put('/api/pose-ai/history')
def pose_ai_history_put(body: PoseAiHistory, user=Depends(current_user)):
    items = _clean_history(body.items)
    if len(json.dumps(items, ensure_ascii=False).encode()) > _POSE_AI_HIS_MAX:
        raise HTTPException(413, '记录过大')
    # 记录里引用的图要单独登记：这些图不挂记录，另一半按常规规则判不到可见
    mids = []
    for it in items:
        url = it.get('imageUrl') or ''
        if url.startswith('/media/'):
            mid = url[len('/media/'):].split('?')[0]
            if mid:
                mids.append(mid)
    with connect() as c:
        c.execute('INSERT INTO settings(key,value) VALUES(?,?) '
                  'ON CONFLICT(key) DO UPDATE SET value=excluded.value',
                  (_POSE_AI_MEDIA_KEY, json.dumps(sorted(set(mids)))))
        row = c.execute('SELECT value FROM settings WHERE key=?', (_POSE_AI_HIS_KEY,)).fetchone()
        if row:
            # 同配置一样：内容没变就别刷时间戳，否则每次打开都判成「NAS 更新了」→ 覆盖本地
            try:
                old = json.loads(cipher(PURPOSE_POSE_AI).decrypt(row['value'].encode()).decode())
                if _clean_history(old.get('items')) == items:
                    return {'ok': True, 'saved': old.get('saved', 0), 'unchanged': True,
                            'count': len(items)}
            except Exception:
                pass
        stored = {'items': items, 'saved': int(now() * 1000)}
        sealed = cipher(PURPOSE_POSE_AI).encrypt(json.dumps(stored, ensure_ascii=False).encode()).decode()
        c.execute('INSERT INTO settings(key,value) VALUES(?,?) '
                  'ON CONFLICT(key) DO UPDATE SET value=excluded.value', (_POSE_AI_HIS_KEY, sealed))
    return {'ok': True, 'saved': stored['saved'], 'count': len(items)}


@app.post('/api/setup')
def setup(body: Credentials, request: Request, response: Response):
    rate_limit(request, 'setup')
    required = os.getenv('SETUP_TOKEN', '')
    if required and not secrets.compare_digest(required, body.token):
        raise HTTPException(403, '初始化口令不正确')
    if not required and request.client.host not in {'127.0.0.1', '::1', 'testclient'}:
        raise HTTPException(403, '请在服务器设置 SETUP_TOKEN 后初始化')
    hashed = password_hash(body.password)
    with connect() as c:
        c.execute('BEGIN IMMEDIATE')
        if c.execute('SELECT count(*) FROM users').fetchone()[0]:
            raise HTTPException(409, '空间已经初始化')
        user_id = uid()
        c.execute('INSERT INTO users(id,username,name,password,admin,created) VALUES (?,?,?,?,1,?)',
                  (user_id, body.username.lower(), body.name.strip(), hashed, now()))
        login_session(c, user_id, response, request)
    return {'ok': True}


@app.post('/api/login')
def login(body: Credentials, request: Request, response: Response):
    rate_limit(request, 'login')
    with connect() as c:
        row = c.execute('SELECT * FROM users WHERE username=?', (body.username.lower(),)).fetchone()
        if not row or not password_ok(body.password, row['password']):
            raise HTTPException(401, '账号或密码不正确')
        login_session(c, row['id'], response, request)
    return {'ok': True}


@app.post('/api/logout')
def logout(request: Request, response: Response, user=Depends(current_user)):
    with connect() as c:
        c.execute('DELETE FROM sessions WHERE token=?', (digest_token(request.cookies.get('love_session', '')),))
    response.delete_cookie('love_session')
    return {'ok': True}


@app.post('/api/invite')
def invite(user=Depends(current_user)):
    with connect() as c:
        if c.execute('SELECT count(*) FROM users').fetchone()[0] >= 2:
            raise HTTPException(409, '你们已经绑定了')
        token = secrets.token_urlsafe(24)
        c.execute('DELETE FROM invites')
        c.execute('INSERT INTO invites VALUES (?,?,0)', (digest_token(token), now() + 86400))
    return {'token': token, 'expires_in': 86400}


@app.post('/api/join')
def join(body: Credentials, request: Request, response: Response):
    rate_limit(request, 'join')
    hashed = password_hash(body.password)
    with connect() as c:
        c.execute('BEGIN IMMEDIATE')
        invitation = c.execute('SELECT * FROM invites WHERE token=? AND used=0 AND expires>?',
                               (digest_token(body.token), now())).fetchone()
        if not invitation or c.execute('SELECT count(*) FROM users').fetchone()[0] != 1:
            raise HTTPException(403, '邀请已失效或空间已满')
        if c.execute('SELECT 1 FROM users WHERE username=?', (body.username.lower(),)).fetchone():
            raise HTTPException(409, '这个账号已经存在')
        user_id = uid()
        c.execute('INSERT INTO users(id,username,name,password,created) VALUES (?,?,?,?,?)',
                  (user_id, body.username.lower(), body.name.strip(), hashed, now()))
        c.execute('UPDATE invites SET used=1')
        login_session(c, user_id, response, request)
        db.notice(c, 'system', '你们的双人空间已开启', actor=user_id)
    return {'ok': True}


@app.get('/api/me')
def me(user=Depends(current_user)):
    with connect() as c:
        # 每个账号使用独立且不可预测的推送 topic，避免通知发给错误账号。
        # NTFY_ENABLED=0（默认）时不下发 topic：前端不连 WS、原生不启动前台服务。
        topic = db.ensure_push_topic(c, user['id']) if ntfy_enabled() else None
        return {'user': public_user(user), 'users': [public_user(u) for u in c.execute('SELECT * FROM users')],
                'space': db.setting(c, 'space'), 'unread': c.execute('SELECT count(*) FROM notices WHERE user_id=? AND seen=0', (user['id'],)).fetchone()[0],
                'chat_unread': c.execute("SELECT count(*) FROM notices WHERE user_id=? AND seen=0 AND event='chat'", (user['id'],)).fetchone()[0],
                'ntfy_topic': topic, 'ntfy_server': ntfy_server_url() if topic else None}


class Profile(BaseModel):
    name: str = Field(min_length=1, max_length=30)
    avatar: str = ''
    old_password: str = ''
    new_password: str = ''


@app.put('/api/profile')
def profile(body: Profile, user=Depends(current_user)):
    with connect() as c:
        validate_owned_image(c, body.avatar, user['id'])
        c.execute('UPDATE users SET name=?,avatar=? WHERE id=?', (body.name, body.avatar, user['id']))
        if body.new_password:
            if not password_ok(body.old_password, user['password']):
                raise HTTPException(403, '原密码不正确')
            c.execute('UPDATE users SET password=? WHERE id=?', (password_hash(body.new_password), user['id']))
            c.execute('DELETE FROM sessions WHERE user_id=?', (user['id'],))
    return {'ok': True, 'login_required': bool(body.new_password)}


def validate_owned_image(c, mid, user_id):
    if mid:
        row = c.execute('SELECT * FROM media WHERE id=? AND owner=?', (mid, user_id)).fetchone()
        if not row or not row['mime'].startswith('image/'):
            raise HTTPException(422, '请选择自己上传的照片')
        db.mark_attached(c, [mid])


# 首页封面（hero 卡）的显示区域：x/y 是 object-position 的百分比，z 是放大倍数。
# 存在 space 里而不是把图裁好再存：原图不损失、随时可反悔，两个人在不同尺寸的屏幕上看到的是同一套构图。
COVER_POS_DEFAULT = {'x': 50.0, 'y': 50.0, 'z': 1.0}


def clean_cover_pos(raw):
    """把裁剪参数规范成 {x, y, z}。非法值一律回落到默认值——
    一个坏字段不该把首页打成空白，所以这里只夹紧不报错。"""
    if not isinstance(raw, dict):
        return dict(COVER_POS_DEFAULT)
    out = {}
    for key, lo, hi, dflt in (('x', 0.0, 100.0, 50.0), ('y', 0.0, 100.0, 50.0), ('z', 1.0, 3.0, 1.0)):
        try:
            val = float(raw.get(key, dflt))
        except (TypeError, ValueError):
            val = dflt
        if val != val or val in (float('inf'), float('-inf')):   # NaN / inf
            val = dflt
        out[key] = round(min(hi, max(lo, val)), 2)
    return out


class Space(BaseModel):
    name: str = Field(min_length=1, max_length=60)
    since: str = ''
    cover: str = ''
    # 封面在 hero 卡里的构图。None = 客户端没带这个字段（旧前端/旧 APK），沿用库里的原值
    cover_pos: dict | None = None
    theme: str = 'rose'
    custom_color: str = Field(default='', max_length=7)
    motion: bool = True
    timezone: str = 'Asia/Shanghai'
    # 聊天壁纸。None 表示"客户端没带这个字段"（旧版前端/旧 APK 保存空间设置时），
    # 此时沿用库里的原值——否则旧客户端一保存就把壁纸清空了。
    # 空间级那三个字段是「没单独设置的人」用的共同默认值。
    chat_bg: str | None = Field(default=None, max_length=20)
    chat_bg_media: str | None = Field(default=None, max_length=64)
    chat_bg_dim: int | None = None
    # 每人一份的聊天背景：{用户 id: {bg, media, dim}}。谁都能替对方设（这是两个人的空间）。
    chat_bg_users: dict[str, dict] | None = None
    # 这次要改谁的背景；留空表示改共同默认值（旧客户端的行为）
    chat_bg_target: str | None = Field(default=None, max_length=64)


# 内置壁纸预设（前端 CSS 里同名实现）；'photo' 表示用自己上传的照片，'' 表示默认无壁纸
CHAT_BG_PRESETS = {'sakura', 'night', 'cream', 'mint', 'stars'}
CHAT_BG_DEFAULT_DIM = 35


@app.put('/api/space')
def space(body: Space, user=Depends(current_user)):
    try:
        ZoneInfo(body.timezone)
        if body.since:
            dt.date.fromisoformat(body.since)
        if body.theme not in {'rose', 'peach', 'lavender', 'custom'}:
            raise ValueError()
        if body.theme == 'custom' and not re.fullmatch(r'#[0-9a-fA-F]{6}', body.custom_color):
            raise ValueError()
        if body.theme != 'custom':
            body.custom_color = ''
        if body.chat_bg is not None and body.chat_bg not in CHAT_BG_PRESETS | {'', 'photo'}:
            raise ValueError()
        if body.chat_bg_dim is not None and not 0 <= body.chat_bg_dim <= 80:
            raise ValueError()
    except Exception:
        raise HTTPException(422, '请检查日期、时区、主题和聊天背景')
    with connect() as c:
        old = db.setting(c, 'space') or {}
        data = body.model_dump()
        # ── 聊天背景：每人一份，谁都能替对方设 ──
        # 带 chat_bg_target 表示"改某个人那份"，此时不动空间级那三个字段（它们是共同默认值）。
        target = data.pop('chat_bg_target', None)
        if target:
            members = [r['id'] for r in c.execute('SELECT id FROM users').fetchall()]
            if target not in members:
                raise HTTPException(422, '找不到要设置背景的人')
            bg = data['chat_bg'] or ''
            media = data['chat_bg_media'] or ''
            dim = data['chat_bg_dim'] if data['chat_bg_dim'] is not None else CHAT_BG_DEFAULT_DIM
            if bg not in CHAT_BG_PRESETS | {'', 'photo'} or not 0 <= dim <= 80:
                raise HTTPException(422, '聊天背景参数不正确')
            # 切回预设时清掉照片引用，否则这张图会一直被判定为"正在使用"而无法清理
            if bg != 'photo':
                media = ''
            elif not media:
                raise HTTPException(422, '请先选择一张照片作为聊天背景')
            elif media != (old.get('chat_bg_users') or {}).get(target, {}).get('media'):
                validate_owned_image(c, media, user['id'])
            bg_users = dict(old.get('chat_bg_users') or {})
            bg_users[target] = {'bg': bg, 'media': media, 'dim': dim}
            data['chat_bg_users'] = bg_users
            # 个人背景的改动不落到共同默认值上，否则两个人会互相顶掉对方的默认
            for key, default in (('chat_bg', ''), ('chat_bg_media', ''), ('chat_bg_dim', CHAT_BG_DEFAULT_DIM)):
                data[key] = old.get(key, default)
        else:
            # 旧客户端没带壁纸字段时保留原值，别把对方设好的背景抹掉
            fallback = {'chat_bg': '', 'chat_bg_media': '', 'chat_bg_dim': CHAT_BG_DEFAULT_DIM}
            for key in fallback:
                if data.get(key) is None:
                    data[key] = old.get(key, fallback[key])
            # 切回预设时清掉照片引用，否则这张图会一直被判定为"正在使用"而无法清理
            if data['chat_bg'] != 'photo':
                data['chat_bg_media'] = ''
            elif not data['chat_bg_media']:
                raise HTTPException(422, '请先选择一张照片作为聊天背景')
            elif data['chat_bg_media'] != old.get('chat_bg_media'):
                validate_owned_image(c, data['chat_bg_media'], user['id'])
        if data.get('chat_bg_users') is None:
            data['chat_bg_users'] = old.get('chat_bg_users') or {}
        # 旧客户端保存空间设置时不会带 cover_pos，此时保留主人已经调好的构图
        data['cover_pos'] = clean_cover_pos(
            body.cover_pos if body.cover_pos is not None else old.get('cover_pos'))
        if body.cover != old.get('cover'):
            validate_owned_image(c, body.cover, user['id'])
        db.set_setting(c, 'space', data)
    return {'ok': True}


class RecordInput(BaseModel):
    kind: str
    body: dict
    client_id: str | None = Field(default=None, max_length=100)


class PersonalWishInput(BaseModel):
    title: str = Field(min_length=1, max_length=100)
    content: str = Field(min_length=1, max_length=20000)
    password: str = Field(min_length=6, max_length=128)
    client_id: str | None = Field(default=None, max_length=100)


class PersonalWishUnlockInput(BaseModel):
    password: str = Field(min_length=1, max_length=128)


def clean_body(c, kind, data, user_id, previous=None):
    if kind not in db.KINDS:
        raise HTTPException(422, '未知记录类型')
    if kind == 'personal_wish':
        raise HTTPException(422, '个人心愿请使用专属加密接口保存')
    permitted = {'title', 'content', 'date', 'media', 'album', 'publish_at', 'annual', 'remind_days',
                 'category', 'done', 'emoji', 'target', 'completion_post', 'sticker', 'amount',
                 'start', 'cycle', 'length', 'flow', 'symptoms',
                 'color', 'pain', 'sex', 'mood', 'weight', 'discharge', 'temp',
                 'reply_to', 'pinned'}
    body = {k: v for k, v in data.items() if k in permitted}
    if 'sticker' in body and (not isinstance(body['sticker'], str)
                              or not re.fullmatch(r'/static/stickers/[a-z0-9]+/\d+\.(webm|webp)', body['sticker'])):
        raise HTTPException(422, '表情格式不正确')
    for key in ('title', 'content', 'date', 'album', 'category', 'emoji', 'target', 'completion_post'):
        if key in body and (not isinstance(body[key], str) or len(body[key]) > (20000 if key == 'content' else 200)):
            raise HTTPException(422, '文字长度或格式不正确')
    for key in ('annual', 'done'):
        if key not in body:
            continue
        if not isinstance(body[key], (bool, str)):
            raise HTTPException(422, '状态格式不正确')
        if key == 'annual' and isinstance(body[key], str) and body[key] != 'lunar':
            raise HTTPException(422, '重复方式仅支持 每年公历 / 每年农历 / 一次')
    if 'remind_days' in body and (type(body['remind_days']) is not int or not 0 <= body['remind_days'] <= 365):
        raise HTTPException(422, '提前提醒天数需在 0–365 之间')
    if 'amount' in body:
        # 账本金额：只接受数字，落库前统一成两位小数；上限 1 亿，挡住误输的长串数字
        try:
            amount = round(float(body['amount']), 2)
        except (TypeError, ValueError):
            raise HTTPException(422, '金额格式不正确')
        if not 0 <= amount <= 100000000:
            raise HTTPException(422, '金额需在 0–1 亿之间')
        body['amount'] = amount
    if kind == 'period':
        # 生理期只有一种 kind，靠字段分两类行：
        #   · 经期行：有 start，记这次从哪天来、来几天，参与周期推算
        #   · 日记录行：有 date、没有 start，记那一天的量/色/痛感/心情/体重/体温
        # cycle/length 允许用户手工改（默认由历史自动推算），但必须落在生理上说得通的区间，
        # 否则日历和预测会画出不可能的格子。
        for key in ('cycle', 'length'):
            if body.get(key) in (None, ''):
                body.pop(key, None)
                continue
            if type(body[key]) is not int or not (15 <= body[key] <= 60 if key == 'cycle' else 1 <= body[key] <= 15):
                raise HTTPException(422, '周期需在 15–60 天、经期需在 1–15 天之间')
        # flow 从「少/中/多」扩成 1–5 档，旧数据里的中文档位继续认，不至于打不开老记录
        flow = body.get('flow')
        if flow in (None, ''):
            body.pop('flow', None)
        elif not (flow in ('少', '中', '多') or (type(flow) is int and 1 <= flow <= 5)):
            raise HTTPException(422, '经量只能是 1–5 档')
        # 档位字段统一按 1..N 编号落库：文案和图标只活在前端，加选项不用改后端
        for key, top, name in (('color', 5, '颜色'), ('pain', 5, '痛感'),
                               ('discharge', 5, '白带'), ('mood', 20, '心情')):
            if key not in body:
                continue
            value = body[key]
            if value in (None, ''):
                body.pop(key)
                continue
            if type(value) is not int or not 1 <= value <= top:
                raise HTTPException(422, f'{name}的档位不正确')
        sex = body.get('sex')
        if sex is not None:
            # 一天可以有好几次，每次单独记措施（w）和时间（t）。两种形状都收：
            #   [2, 4]                      —— 早期版本只记了措施编号
            #   [{'t': '16:14', 'w': [2]}]  —— 现在的一次记录
            # 落库前统一成后者，前端只处理一种形状。
            if not isinstance(sex, list) or len(sex) > 8:
                raise HTTPException(422, '最多记八次')
            entries = []
            for item in sex:
                if type(item) is int:
                    if not 1 <= item <= 10:
                        raise HTTPException(422, '避孕方式的选项不正确')
                    entries.append({'t': '', 'w': [item]})
                    continue
                if not isinstance(item, dict):
                    raise HTTPException(422, '避孕方式的选项不正确')
                ways = item.get('w') or []
                if not isinstance(ways, list) or len(ways) > 10 \
                        or any(type(w) is not int or not 1 <= w <= 10 for w in ways):
                    raise HTTPException(422, '避孕方式的选项不正确')
                when = item.get('t') or ''
                if when:
                    if not isinstance(when, str) or not re.fullmatch(r'([01]\d|2[0-3]):[0-5]\d', when):
                        raise HTTPException(422, '时间格式不正确')
                entries.append({'t': when, 'w': list(dict.fromkeys(ways))})
            body['sex'] = entries
        for key, low, high, name in (('weight', 20.0, 300.0, '体重'), ('temp', 30.0, 45.0, '体温')):
            if key not in body:
                continue
            try:
                value = round(float(body[key]), 1)
            except (TypeError, ValueError):
                body.pop(key)
                continue
            if not low <= value <= high:
                raise HTTPException(422, f'{name}需在 {low:g}–{high:g} 之间')
            body[key] = value
        symptoms = body.get('symptoms')
        if symptoms is not None:
            if not isinstance(symptoms, list) or len(symptoms) > 20 \
                    or any(not isinstance(s, str) or not s.strip() or len(s) > 16 for s in symptoms):
                raise HTTPException(422, '症状最多二十项，每项不超过十六个字')
            body['symptoms'] = list(dict.fromkeys(s.strip() for s in symptoms if s.strip()))
    for key in ('date', 'target', 'start'):
        if body.get(key):
            try:
                dt.date.fromisoformat(body[key])
            except ValueError:
                raise HTTPException(422, '日期格式不正确')
    if kind != 'chat':
        # 引用/置顶只对聊天消息有意义，别的类型带进来一律丢掉，不留脏字段
        body.pop('reply_to', None)
        body.pop('pinned', None)
    if 'reply_to' in body:
        # 只存「引用了哪条 + 当时那句话的摘要」：原消息之后被撤回或改掉，引用条也还看得懂
        quote = body['reply_to']
        if quote in (None, '', {}):
            body.pop('reply_to')
        elif not isinstance(quote, dict):
            raise HTTPException(422, '引用的消息格式不正确')
        else:
            rid = str(quote.get('id') or '').strip()
            if not rid or len(rid) > 64:
                raise HTTPException(422, '引用的消息格式不正确')
            text = quote.get('text') or ''
            body['reply_to'] = {'id': rid, 'text': str(text)[:80]}
    if 'pinned' in body and not isinstance(body['pinned'], bool):
        raise HTTPException(422, '置顶状态不正确')
    if kind == 'anniversary' and not body.get('date'):
        raise HTTPException(422, '请选择纪念日日期')
    if kind == 'period' and not (body.get('start') or body.get('date')):
        raise HTTPException(422, '请选择这次经期开始的日期')
    mids = body.get('media', [])
    if not isinstance(mids, list) or len(mids) > 30 or any(not isinstance(m, str) for m in mids):
        raise HTTPException(422, '每条记录最多添加三十个附件')
    body['media'] = list(dict.fromkeys(mids))
    if kind in {'album', 'anniversary', 'wish', 'habit', 'question', 'music'} and not body.get('title', '').strip():
        raise HTTPException(422, '请填写标题')
    if kind in {'post', 'diary', 'surprise', 'note', 'chat'} and not (body.get('content', '').strip() or mids or body.get('sticker')):
        raise HTTPException(422, '写点什么或添加一个附件吧')
    if kind == 'question' and mids:
        raise HTTPException(422, '问答暂不支持附件')
    for mid in mids:
        row = c.execute('SELECT * FROM media WHERE id=?', (mid,)).fetchone()
        # 上一行的 media_visible 已经涵盖"能被引用"的判断；原来后面还跟着一条
        # 完全等价的重复校验，等于每张图多付一次全表扫描的代价
        if not row or not db.media_visible(c, mid, user_id):
            raise HTTPException(403, '附件不可访问')
    if mids:
        # 附件随记录保存，脱离"未使用"状态，不再被孤儿清理
        # （原来靠 AFTER UPDATE ON media 触发器顺带推进共享 revision，已改为显式调用）
        db.mark_attached(c, mids)
    if body.get('album'):
        album = c.execute('SELECT * FROM records WHERE id=? AND kind=\'album\' AND deleted IS NULL', (body['album'],)).fetchone()
        if not album:
            raise HTTPException(422, '相册不存在')
    if kind == 'surprise':
        value = body.get('publish_at')
        if not isinstance(value, (int, float)) or not now() < value < now() + 50 * 366 * 86400:
            raise HTTPException(422, '请选择未来的公开时间')
    else:
        body.pop('publish_at', None)
    return body


def serialize_many(c, rows, user_id):
    """Serialize a result page with bounded queries instead of per-row lookups."""
    related = {'likes': {}, 'comments': {}, 'answers': {}, 'checks': {}, 'media': {}}
    rows = list(rows)
    for start in range(0, len(rows), 300):
        chunk = rows[start:start + 300]
        ids = [row['id'] for row in chunk]
        if not ids:
            continue
        marks = ','.join('?' for _ in ids)
        for row in c.execute(f'SELECT record_id,user_id FROM likes WHERE record_id IN ({marks})', ids):
            related['likes'].setdefault(row['record_id'], []).append(row['user_id'])
        for row in c.execute(f'SELECT * FROM comments WHERE record_id IN ({marks}) ORDER BY created', ids):
            related['comments'].setdefault(row['record_id'], []).append(dict(row))
        for row in c.execute(f'SELECT * FROM answers WHERE record_id IN ({marks})', ids):
            related['answers'].setdefault(row['record_id'], []).append(dict(row))
        for row in c.execute(f'SELECT * FROM checks WHERE record_id IN ({marks}) ORDER BY day DESC', ids):
            related['checks'].setdefault(row['record_id'], []).append(dict(row))
        media_ids = list(dict.fromkeys(mid for record in chunk for mid in db.body_decode(record).get('media', [])))
        for media_start in range(0, len(media_ids), 300):
            mids = media_ids[media_start:media_start + 300]
            media_marks = ','.join('?' for _ in mids)
            for row in c.execute(f'SELECT id,name,mime,size,status,preview FROM media WHERE id IN ({media_marks})', mids):
                related['media'][row['id']] = dict(row)
    return [serialize(c, row, user_id, related) for row in rows]


@app.get('/api/records')
def records(kind: str = '', q: str = '', author: str = '', date: str = '', media_type: str = '',
            trash: bool = False, limit: int = 0, before: float = 0, before_id: str = '',
            exclude: str = '', user=Depends(current_user)):
    with connect() as c:
        # 上限 1000：首屏要把「除聊天外」的记录一次拿全（纪念日、清单、账本这些增长很慢），
        # 聊天自己有独立的 200 条窗口。原来卡在 200，聊天一多就把老纪念日挤出窗口。
        limit = min(max(limit, 0), 1000)
        clauses, params = [], []
        if trash:
            clauses.extend(['author=?', 'deleted IS NOT NULL'])
            params.append(user['id'])
        else:
            clauses.append('deleted IS NULL')
            if not kind:
                clauses.append("kind NOT IN ('diary','draft','surprise')")
        kinds = [value for value in kind.split(',') if value]
        if kinds:
            clauses.append('kind IN (' + ','.join('?' for _ in kinds) + ')')
            params.extend(kinds)
        # 独立的排除列表：比让前端把十几个类型名拼进 kind 更好读，也不会漏
        excluded = [value for value in exclude.split(',') if value]
        # 生理期在独立的 period.db 里：列表要把它并进来，前端不必知道换了库。
        # 只有 period 一种类型时直接查分库，别白跑一遍主库。
        only_period = kinds == ['period']
        merge_period = (not only_period and (not kinds or 'period' in kinds)
                        and 'period' not in excluded and not media_type)
        # 还有没搬完的旧行（迁移失败/正在迁移）时，让主库查询照旧兜住它，别返回空列表
        if only_period and not period.pending_count():
            return period.rows_for(user['id'], author=author, date=date, q=q, trash=trash,
                                   before=before, before_id=before_id, limit=limit)
        if excluded:
            clauses.append('kind NOT IN (' + ','.join('?' for _ in excluded) + ')')
            params.extend(excluded)
        if author:
            clauses.append('author=?')
            params.append(author)
        date_in_python = bool(date and (trash or any(value in db.PRIVATE for value in kinds)))
        if date and not date_in_python:
            clauses.append("json_extract(body,'$.date')=?")
            params.append(date)
        result, cursor_time, cursor_id = [], before, before_id
        while True:
            page_clauses, page_params = list(clauses), list(params)
            if cursor_time:
                page_clauses.append('(created<? OR (created=? AND id<?))')
                page_params.extend([cursor_time, cursor_time, cursor_id])
            sql = 'SELECT * FROM records WHERE ' + ' AND '.join(page_clauses) + ' ORDER BY created DESC,id DESC LIMIT ?'
            batch_size = 500 if not limit else min(500, max(100, (limit + 1 - len(result)) * 4))
            rows = c.execute(sql, (*page_params, batch_size)).fetchall()
            if not rows:
                break
            cursor_time, cursor_id = rows[-1]['created'], rows[-1]['id']
            candidates = []
            for row in rows:
                if not trash and not db.visible(row, user['id']):
                    continue
                body = db.body_decode(row)
                if date_in_python and body.get('date') != date:
                    continue
                if q.lower() not in (body.get('content', '') + body.get('title', '')).lower():
                    continue
                candidates.append(row)
            items = serialize_many(c, candidates, user['id'])
            if media_type:
                items = [item for item in items if any(m['mime'].startswith(media_type + '/') for m in item['media'])]
            result.extend(items)
            if limit and len(result) > limit:
                break
            if len(rows) < batch_size:
                break
        if limit:
            result = result[:limit]
        if merge_period:
            # 分库的记录并进同一个倒序列表——前端 recordsOf('period') 照旧能拿到
            result.extend(period.rows_for(user['id'], author=author, date=date, q=q, trash=trash,
                                          before=before, before_id=before_id, limit=limit))
            result.sort(key=lambda item: (item['created'], item['id']), reverse=True)
            if limit:
                result = result[:limit]
    return result


# ── 生理期：独立库的读写入口 ────────────────────────────────────────
# 生理期在你们两个人之间没有"共享/私密"之分：谁都能记、谁都能改，
# 页面看到的也是同一份周期。这里只管"写哪个库"以及跨库副作用的顺序：
# 先提交分库，再回主库推 revision / 发通知。

def _period_touch():
    """分库写完之后回主库推进版本号：两边都要刷新。"""
    with connect() as c:
        c.execute('BEGIN IMMEDIATE')
        db.bump_shared(c)


def create_period_record(body, user):
    with connect() as c:
        existing = period.find_by_client(user['id'], body.client_id)
        if existing:
            return period.serialize(existing, user['id'])
        cleaned = clean_body(c, 'period', body.body, user['id'])
    rid = uid()
    period.insert(rid, user['id'], cleaned, body.client_id)
    with connect() as c:
        c.execute('BEGIN IMMEDIATE')
        db.bump_shared(c)
        db.notice(c, 'activity', '你们的空间有了新记录', rid, user['id'])
    nudge_worker()
    return period.serialize(period.get(rid), user['id'])


def update_period_record(rid, body, row, user):
    if body.kind != 'period':
        raise HTTPException(422, '已发布内容不能改变可见范围，请另建记录')
    with connect() as c:
        old_body = db.body_decode(row)
        cleaned = clean_body(c, 'period', body.body, user['id'], old_body)
    period.update(rid, cleaned)
    _period_touch()
    return period.serialize(period.get(rid), user['id'])


def delete_period_record(rid, row, user):
    # period 在 SHARED_EDIT 里：谁都能删，恢复只有本人能做（回收站是按人分的）
    period.soft_delete(rid)
    _period_touch()
    return {'ok': True}


def restore_period_record(rid, row, user):
    if row['author'] != user['id']:
        raise HTTPException(404, '记录不存在')
    period.restore(rid)
    _period_touch()
    return {'ok': True}


@app.post('/api/records')
def create_record(body: RecordInput, user=Depends(current_user)):
    if body.kind == 'period':
        return create_period_record(body, user)
    with connect() as c:
        c.execute('BEGIN IMMEDIATE')
        author_id = user['id']
        if body.client_id:
            existing = c.execute('SELECT * FROM records WHERE author=? AND client_id=?', (author_id, body.client_id)).fetchone()
            if existing:
                return serialize(c, existing, user['id'])
        cleaned = clean_body(c, body.kind, body.body, user['id'])
        rid = uid()
        timestamp = now()
        c.execute('INSERT INTO records VALUES (?,?,?,?,?,?,NULL,?,?)',
                  (rid, body.kind, author_id, db.body_encode(body.kind, rid, cleaned), timestamp, timestamp,
                   timestamp if body.kind not in db.PRIVATE else None, body.client_id))
        if body.kind not in db.PRIVATE:
            event = 'chat' if body.kind == 'chat' else ('note' if body.kind == 'note' else 'activity')
            title = '收到一条新消息' if body.kind == 'chat' else '你们的空间有了新记录'
            db.notice(c, event, title, rid, user['id'])
            # 新通知已入队：立即唤醒后台投递循环，推送不再等下一个轮询周期
            nudge_worker()
        return serialize(c, c.execute('SELECT * FROM records WHERE id=?', (rid,)).fetchone(), user['id'])


@app.post('/api/personal-wishes')
def create_personal_wish(body: PersonalWishInput, user=Depends(current_user)):
    title, content = body.title.strip(), body.content.strip()
    if not title or not content or not body.password.strip():
        raise HTTPException(422, '请填写心愿名称、具体内容和独立密码')
    with connect() as c:
        if body.client_id:
            existing = c.execute('SELECT * FROM records WHERE author=? AND client_id=?',
                                 (user['id'], body.client_id)).fetchone()
            if existing:
                if existing['kind'] != 'personal_wish':
                    raise HTTPException(409, '请求标识已被其他记录使用，请重新提交')
                return serialize(c, existing, user['id'])
        # Each wish in the shared space must have its own password, including the partner's wishes.
        for row in c.execute("SELECT body FROM records WHERE kind='personal_wish'").fetchall():
            existing = json.loads(row['body']).get('password_hash')
            if existing and password_ok(body.password, existing):
                raise HTTPException(422, '这个密码已经用于另一条个人心愿，请为每条心愿设置不同密码')
        encoded_password = password_hash(body.password, 6)
        rid, timestamp = uid(), now()
        # sealed：凭密码解密（对方凭密码首次解锁用）；owner_sealed：服务端主密钥封存的副本，作者回看不必再输密码
        stored = {'title': title, 'sealed': personal_wish_encrypt(body.password, content),
                  'owner_sealed': seal_for_owner(content), 'password_hash': encoded_password}
        c.execute('INSERT INTO records VALUES (?,?,?,?,?,?,NULL,?,?)',
                  (rid, 'personal_wish', user['id'], dumps(stored), timestamp, timestamp, timestamp, body.client_id))
        db.notice(c, 'activity', '对方许下了一份个人心愿', rid, user['id'])
        return serialize(c, c.execute('SELECT * FROM records WHERE id=?', (rid,)).fetchone(), user['id'])


@app.post('/api/personal-wishes/{rid}/unlock')
def unlock_personal_wish(rid: str, body: PersonalWishUnlockInput, request: Request, user=Depends(current_user)):
    with connect() as c:
        row = get_record(c, rid, user)
        if row['kind'] != 'personal_wish':
            raise HTTPException(404, '心愿不存在')
        stored = json.loads(row['body'])
        author = row['author'] == user['id']
        readers = stored.get('readers_sealed') or {}
        # 作者本人、以及已经解锁过的一方，都不必再输密码
        if author and stored.get('owner_sealed'):
            return {'content': open_sealed(stored['owner_sealed'])}
        if user['id'] in readers:
            return {'content': open_sealed(readers[user['id']])}
        # 只有密码错误才计入限流；正确密码不该被拦截。key 带上用户，避免两人共用出口 IP 时挤占同一配额
        if not password_ok(body.password, stored.get('password_hash', '')):
            rate_limit(request, 'personal-wish-unlock:%s:%s' % (rid, user['id']))
            raise HTTPException(403, '密码不正确，请向心愿本人确认')
        content = personal_wish_decrypt(body.password, stored.get('sealed', {}))
        # 解锁一次后永久可见：为这一方留一份主密钥封存的副本（旧心愿由作者凭密码补一份，之后同样免密）
        if author:
            stored['owner_sealed'] = seal_for_owner(content)
        else:
            readers[user['id']] = seal_for_owner(content)
            stored['readers_sealed'] = readers
            unlocked_by = stored.get('unlocked_by') or []
            if user['id'] not in unlocked_by:
                unlocked_by.append(user['id'])
            stored['unlocked_by'] = unlocked_by
        c.execute('UPDATE records SET body=? WHERE id=?', (dumps(stored), rid))
        return {'content': content}


def get_record(c, rid, user, editable=False, include_deleted=False):
    row = c.execute('SELECT * FROM records WHERE id=?', (rid,)).fetchone()
    if not row or (not include_deleted and not db.visible(row, user['id'])):
        raise HTTPException(404, '记录不存在')
    if include_deleted and row['author'] != user['id']:
        raise HTTPException(404, '记录不存在')
    if editable and row['author'] != user['id'] and row['kind'] not in db.SHARED_EDIT:
        raise HTTPException(403, '只有作者可以修改这条记录')
    return row


@app.get('/api/records/{rid}')
def record_detail(rid: str, user=Depends(current_user)):
    with connect() as c:
        if c.execute('SELECT 1 FROM records WHERE id=?', (rid,)).fetchone():
            return serialize(c, get_record(c, rid, user), user['id'])
    prow = period.get(rid)
    if not prow:
        raise HTTPException(404, '记录不存在')
    return period.serialize(prow, user['id'])


@app.put('/api/records/{rid}')
def update_record(rid: str, body: RecordInput, user=Depends(current_user)):
    prow = period.get(rid)
    if prow:
        return update_period_record(rid, body, prow, user)
    with connect() as c:
        # 先读后写（读记录 → 读其他记录判断附件引用 → 写）：不先拿写锁，
        # 锁升级时会直接 SQLITE_BUSY 而不是等待
        c.execute('BEGIN IMMEDIATE')
        row = get_record(c, rid, user, True)
        if body.kind != row['kind'] and not (row['kind'] == 'draft' and body.kind in {'post', 'diary', 'surprise'}):
            raise HTTPException(422, '已发布内容不能改变可见范围，请另建记录')
        old_body = db.body_decode(row)
        cleaned = clean_body(c, body.kind, body.body, user['id'], old_body)
        if body.kind == 'period' and row['author'] != user['id']:
            # 另一半可以帮忙改内容（她说难受的时候你替她补一条症状），
            # 但「共享给 TA」是隐私开关，只能由记录本人改。
            cleaned['shared'] = old_body.get('shared', True)
        publish = now() if row['kind'] == 'draft' and body.kind == 'post' else row['published']
        c.execute('UPDATE records SET kind=?,body=?,updated=?,published=? WHERE id=?',
                  (body.kind, db.body_encode(body.kind, rid, cleaned), now(), publish, rid))
        # 编辑后失去引用的附件回到"未使用"状态，交由孤儿清理及时回收
        for mid in old_body.get('media', []):
            if mid in cleaned.get('media', []):
                continue
            still_used = any(mid in db.body_decode(other).get('media', [])
                             for other in c.execute('SELECT id,kind,body FROM records WHERE id<>?', (rid,)))
            if not still_used:
                c.execute('UPDATE media SET attached=0 WHERE id=?', (mid,))
        if row['kind'] == 'draft' and body.kind == 'post':
            db.notice(c, 'activity', '你们的空间有了新记录', rid, user['id'])
        return serialize(c, c.execute('SELECT * FROM records WHERE id=?', (rid,)).fetchone(), user['id'])


@app.delete('/api/records/{rid}')
def delete_record(rid: str, user=Depends(current_user)):
    prow = period.get(rid)
    if prow:
        return delete_period_record(rid, prow, user)
    with connect() as c:
        c.execute('BEGIN IMMEDIATE')  # 先读后写，见 update_record 注释
        row = get_record(c, rid, user, True)
        c.execute('UPDATE records SET deleted=?,updated=? WHERE id=?', (now(), now(), rid))
        if row['kind'] == 'album':
            for item in c.execute("SELECT id,kind,body FROM records WHERE kind NOT IN ('diary','draft','surprise')").fetchall():
                data = db.body_decode(item)
                if data.get('album') == rid:
                    data['album'] = ''
                    c.execute('UPDATE records SET body=? WHERE id=?',
                              (db.body_encode(item['kind'], item['id'], data), item['id']))
    return {'ok': True}


@app.post('/api/records/{rid}/restore')
def restore_record(rid: str, user=Depends(current_user)):
    prow = period.get(rid, include_deleted=True)
    if prow:
        return restore_period_record(rid, prow, user)
    with connect() as c:
        get_record(c, rid, user, include_deleted=True)
        c.execute('UPDATE records SET deleted=NULL,updated=? WHERE id=?', (now(), rid))
    return {'ok': True}


@app.post('/api/records/{rid}/recall')
def recall_record(rid: str, user=Depends(current_user)):
    """撤回聊天消息：仅作者本人、2 分钟内；内容与附件清空，保留一条系统提示供双方渲染。"""
    with connect() as c:
        c.execute('BEGIN IMMEDIATE')  # 先读后写，见 update_record 注释
        row = get_record(c, rid, user, True)
        if row['kind'] != 'chat':
            raise HTTPException(400, '只有悄悄话可以撤回')
        if now() - row['created'] > 120:
            raise HTTPException(400, '超过两分钟的消息不能撤回啦')
        data = db.body_decode(row)
        if data.get('recalled'):
            return {'ok': True}
        old_media = data.pop('media', [])
        data['recalled'] = True
        data['content'] = ''
        c.execute('UPDATE records SET body=?,updated=? WHERE id=?', (db.body_encode(row['kind'], rid, data), now(), rid))
        # 被撤回消息的附件回到"未使用"状态，交由孤儿清理回收
        # （media id 为 32 位十六进制，直接全文匹配即可命中数组任意位置；
        #   旧模式只匹配首位元素，非首位引用会被误判为无引用）
        for mid in old_media:
            still_used = c.execute("SELECT 1 FROM records WHERE body LIKE ? LIMIT 1", (f'%{mid}%',)).fetchone()
            if not still_used:
                c.execute('UPDATE media SET attached=0 WHERE id=?', (mid,))
    return {'ok': True}


@app.post('/api/records/{rid}/pin')
def pin_record(rid: str, user=Depends(current_user)):
    """置顶 / 取消置顶一条聊天消息。

    单独开一个端点而不是走整体 PUT：PUT 会经过 clean_body 的白名单，
    `recalled` 这类只由服务端写入的字段会被洗掉——等于顺手把撤回的消息又翻出来了。
    置顶不区分作者：两个人谁都能置顶哪条，这是"我们俩都该看到"的事。
    """
    with connect() as c:
        c.execute('BEGIN IMMEDIATE')
        row = get_record(c, rid, user, True)
        if row['kind'] != 'chat':
            raise HTTPException(400, '只有聊天消息可以置顶')
        data = db.body_decode(row)
        pinned = not data.get('pinned')
        data['pinned'] = pinned
        c.execute('UPDATE records SET body=?,updated=? WHERE id=?',
                  (db.body_encode(row['kind'], rid, data), now(), rid))
    return {'ok': True, 'pinned': pinned}


@app.post('/api/records/{rid}/like')
def like(rid: str, user=Depends(current_user)):
    with connect() as c:
        row = get_record(c, rid, user)
        if c.execute('SELECT 1 FROM likes WHERE record_id=? AND user_id=?', (rid, user['id'])).fetchone():
            c.execute('DELETE FROM likes WHERE record_id=? AND user_id=?', (rid, user['id']))
        else:
            c.execute('INSERT INTO likes VALUES (?,?)', (rid, user['id']))
            if row['kind'] not in db.PRIVATE:
                # 同一条记录的点赞只提醒一次：反复点赞/取消不再刷屏（dedupe 全局唯一）
                db.notice(c, 'comment', '有人喜欢了你的记录', rid, user['id'], recipient=row['author'],
                          dedupe=f'like:{rid}')
    return {'ok': True}


class TextInput(BaseModel):
    content: str = Field(min_length=1, max_length=5000)


@app.post('/api/records/{rid}/comments')
def comment(rid: str, body: TextInput, user=Depends(current_user)):
    with connect() as c:
        row = get_record(c, rid, user)
        cid = uid()
        c.execute('INSERT INTO comments VALUES (?,?,?,?,?)', (cid, rid, user['id'], body.content, now()))
        if row['kind'] not in db.PRIVATE:
            db.notice(c, 'comment', '收到一条新回复', rid, user['id'])
    return {'id': cid}


@app.delete('/api/comments/{cid}')
def delete_comment(cid: str, user=Depends(current_user)):
    with connect() as c:
        if not c.execute('DELETE FROM comments WHERE id=? AND author=?', (cid, user['id'])).rowcount:
            raise HTTPException(404, '评论不存在或不是你发布的')
    return {'ok': True}


@app.post('/api/records/{rid}/answer')
def answer(rid: str, body: TextInput, user=Depends(current_user)):
    with connect() as c:
        row = get_record(c, rid, user)
        if row['kind'] != 'question':
            raise HTTPException(422, '这不是问答')
        c.execute('INSERT INTO answers VALUES (?,?,?) ON CONFLICT(record_id,author) DO UPDATE SET content=excluded.content',
                  (rid, user['id'], body.content))
    return {'ok': True}


@app.post('/api/records/{rid}/check')
def check(rid: str, user=Depends(current_user)):
    with connect() as c:
        row = get_record(c, rid, user)
        if row['kind'] != 'habit':
            raise HTTPException(422, '这不是打卡目标')
        day = dt.datetime.now(ZoneInfo(db.setting(c, 'space')['timezone'])).date().isoformat()
        c.execute('INSERT OR IGNORE INTO checks VALUES (?,?,?)', (rid, user['id'], day))
    return {'ok': True}


MIME_EXT = {'image/jpeg': '.jpg', 'image/png': '.png', 'image/webp': '.webp', 'image/gif': '.gif',
            'image/heic': '.heic', 'image/heif': '.heif', 'video/mp4': '.mp4', 'video/quicktime': '.mov',
            'video/webm': '.webm', 'audio/webm': '.webm', 'audio/ogg': '.ogg', 'audio/mp4': '.m4a',
            'audio/mpeg': '.mp3', 'audio/wav': '.wav', 'audio/x-wav': '.wav', 'audio/aac': '.aac'}

# 音视频魔数嗅探：MP4/MOV 是 `....ftyp`，WebM/Matroska 是 EBML，MP3 常带 ID3（也可能裸帧），
# WAV 是 RIFF....WAVE，OGG 是 OggS，AAC 通常是 ADTS（12 位同步字 0xFFF）
_MEDIA_SNIFF = {
    'video/mp4': lambda b: b[4:8] == b'ftyp',
    'video/quicktime': lambda b: b[4:8] == b'ftyp' or b[4:8] == b'moov' or b[4:8] == b'wide',
    'video/webm': lambda b: b[:4] == b'\x1a\x45\xdf\xa3',
    'audio/webm': lambda b: b[:4] == b'\x1a\x45\xdf\xa3',
    'audio/ogg': lambda b: b[:4] == b'OggS',
    'audio/wav': lambda b: b[:4] == b'RIFF' and b[8:12] == b'WAVE',
    'audio/x-wav': lambda b: b[:4] == b'RIFF' and b[8:12] == b'WAVE',
    'audio/mpeg': lambda b: b[:3] == b'ID3' or (len(b) > 1 and b[0] == 0xFF and (b[1] & 0xE0) == 0xE0),
    'audio/aac': lambda b: len(b) > 1 and b[0] == 0xFF and (b[1] & 0xF0) == 0xF0,
    'audio/mp4': lambda b: b[4:8] == b'ftyp',
}


def sniff_media(path, mime):
    """校验文件真实类型。没有嗅探规则的类型（如 images 已由 PIL 校验）一律放过。

    只对已知魔数的格式做判断——宁可对陌生容器宽松，也不要因为容器变体把正常文件拒掉。
    """
    check = _MEDIA_SNIFF.get(mime)
    if not check:
        return True
    try:
        with path.open('rb') as f:
            return check(f.read(32))
    except OSError:
        return False


@app.post('/api/media')
def upload(request: Request, file: UploadFile = File(...), user=Depends(current_user)):
    # 上传是最容易误触循环、也最容易撑爆磁盘的操作，单独一个宽松的桶（不防人，防手滑）
    rate_limit(request, 'upload', 30, 300)
    mime = (file.content_type or '').split(';')[0].lower()
    if mime not in MIME_EXT:
        raise HTTPException(422, '暂不支持这种文件，请使用照片、音频或视频')
    mid = uid()
    ext = MIME_EXT[mime]
    folder = db.media_dir(mime, now())
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / (mid + ext)
    size = 0
    try:
        with path.open('wb') as f:
            while chunk := file.file.read(1024 * 1024):
                size += len(chunk)
                if size > int(os.getenv('MAX_UPLOAD_MB', '250')) * 1024 * 1024:
                    raise HTTPException(413, '文件超过允许大小')
                f.write(chunk)
        if size == 0:
            raise HTTPException(422, '文件为空')
        if mime.startswith('image/'):
            try:
                with Image.open(path) as im:
                    im.verify()
            except Exception:
                # HEIC 在无 pillow-heif 时 verify 失败，但仍保留原文件交由 worker 处理
                if mime not in {'image/heic', 'image/heif'}:
                    raise HTTPException(422, '图片文件损坏，请重新选择')
        else:
            # 音视频以前完全信任客户端声明的 Content-Type：任意字节只要声明成
            # video/mp4 就能入库回显。按图片 verify 的先例，嗅探魔数。
            if not sniff_media(path, mime):
                raise HTTPException(422, '文件内容与声明的类型不符，请重新选择')
        with connect() as c:
            c.execute('INSERT INTO media(id,owner,name,mime,size,ext,created) VALUES (?,?,?,?,?,?,?)',
                      (mid, user['id'], Path(file.filename or '记录').name[:200], mime, size, ext, now()))
    except Exception as e:
        path.unlink(missing_ok=True)
        if isinstance(e, HTTPException):
            raise
        raise HTTPException(422, '文件无法读取，请重新选择')
    return {'id': mid, 'mime': mime, 'name': file.filename, 'status': 'pending'}


@app.get('/media/{mid}')
def media(mid: str, preview: bool = False, poster: bool = False, download: bool = False, user=Depends(current_user)):
    with connect() as c:
        if not db.media_visible(c, mid, user['id']):
            raise HTTPException(404, '附件不存在')
        row = c.execute('SELECT * FROM media WHERE id=?', (mid,)).fetchone()
    if poster:
        # 视频封面：转码时抽出的首帧图；旧视频可能没有，404 由前端黑底兜底
        filename = mid + '.preview.jpg'
    else:
        filename = row['preview'] if preview and row['preview'] else mid + row['ext']
    path = db.media_dir(row['mime'], row['created']) / filename
    if not path.is_file():
        raise HTTPException(404, '附件文件不存在，请检查存储')
    if filename.endswith('.preview.jpg'):
        mime_type = 'image/jpeg'
    elif filename.endswith('.preview.mp4'):
        mime_type = 'video/mp4'
    elif filename.endswith('.preview.m4a'):
        mime_type = 'audio/mp4'
    else:
        mime_type = row['mime']
    return FileResponse(path, media_type=mime_type,
                        filename=row['name'] if download else None,
                        content_disposition_type='attachment' if download else 'inline')


@app.get('/api/photos')
def photos(album: str = '', user=Depends(current_user)):
    """相册汇总：先收集记录里的媒体引用，再批量取媒体，消除逐张查询的 N+1。"""
    with connect() as c:
        refs = []  # [(mid, record_id, date, caption)]，按记录时间倒序，同一媒体只留首次出现
        seen = set()
        for row in c.execute("SELECT id,body FROM records WHERE kind='post' AND deleted IS NULL ORDER BY created DESC"):
            body = json.loads(row['body'])
            if album and body.get('album') != album:
                continue
            for mid in body.get('media', []):
                if mid in seen:
                    continue
                seen.add(mid)
                refs.append((mid, row['id'], body.get('date', ''), body.get('content', '')))
        if not refs:
            return []
        # SQLite 默认变量上限 999，按 500 分块批量查
        media_map = {}
        ids = [ref[0] for ref in refs]
        for start in range(0, len(ids), 500):
            chunk = ids[start:start + 500]
            placeholders = ','.join('?' for _ in chunk)
            for m in c.execute(
                    f"SELECT id,name,mime,owner,status,preview FROM media "
                    f"WHERE id IN ({placeholders}) AND mime LIKE 'image/%'", chunk):
                media_map[m['id']] = dict(m)
        result = []
        for mid, record_id, date, caption in refs:
            media = media_map.get(mid)
            if media:
                result.append({**media, 'record_id': record_id, 'date': date, 'caption': caption})
    return result


@app.get('/api/media/images')
def media_images(limit: int = 200, user=Depends(current_user)):
    """选图面板用：我能看见的图片，最近上传的排在前面。

    首页封面和聊天背景都想「从相册里挑一张」，但相册页只列记录引用过的图——聊天里
    发过、当过头像、合成台出的图都不在里面。这里直接扫 media 表，再用 media_visible
    兜可见性（另一半私密日记里的图不会漏出来）。
    """
    limit = max(1, min(400, limit))
    with connect() as c:
        rows = c.execute(
            "SELECT id,name,owner,created FROM media WHERE mime LIKE 'image/%' "
            "ORDER BY created DESC LIMIT ?", (limit * 4,)).fetchall()
        out = []
        for row in rows:
            if row['owner'] == user['id'] or db.media_visible(c, row['id'], user['id']):
                out.append({'id': row['id'], 'name': row['name'], 'created': row['created']})
                if len(out) >= limit:
                    break
    return out


@app.get('/api/notices')
def notices(user=Depends(current_user)):
    with connect() as c:
        return [dict(r) for r in c.execute('SELECT * FROM notices WHERE user_id=? ORDER BY created DESC LIMIT 200', (user['id'],))]


@app.post('/api/notices/read')
def mark_read(record_id: str = '', event: str = '', user=Depends(current_user)):
    with connect() as c:
        if record_id:
            # 打开过详情的单条通知即视为已读
            c.execute('UPDATE notices SET seen=1 WHERE user_id=? AND record_id=?', (user['id'], record_id))
        elif event:
            # 按事件类型批量已读（进入私聊页时清空聊天未读红点）
            c.execute('UPDATE notices SET seen=1 WHERE user_id=? AND event=?', (user['id'], event))
        else:
            c.execute('UPDATE notices SET seen=1 WHERE user_id=?', (user['id'],))
    return {'ok': True}


@app.delete('/api/notices/read')
def delete_read_notices(user=Depends(current_user)):
    """删除当前账号通知中心里的已读提醒；聊天记录与未读提醒不受影响。"""
    with connect() as c:
        deleted = c.execute(
            "DELETE FROM notices WHERE user_id=? AND seen=1 AND event!='chat'",
            (user['id'],),
        ).rowcount
    return {'ok': True, 'deleted': deleted}


def _sse_probe(token: str, user_id: str, check_session: bool):
    """SSE 心跳探针：同步 sqlite 查询，必须放到线程里执行。

    返回 (revision, private_revision, unread)；会话失效返回 None。
    """
    with connect() as c:
        # session 校验不必每轮都做：这个流只推"该刷新了"，不含任何数据，
        # 晚 45s 发现登出没有代价，却能省掉每连接每 5s 一次查询
        if check_session and not c.execute(
                'SELECT 1 FROM sessions WHERE token=? AND expires>?', (token, now())).fetchone():
            return None
        # 一次查询拿三样东西。revision 由触发器维护，是 O(1)，
        # 与库里有多少年的记录无关。
        row = c.execute(
            "SELECT (SELECT value FROM app_state WHERE key='content_revision'),"
            "       (SELECT value FROM user_revisions WHERE user_id=:u),"
            "       (SELECT count(*) FROM notices WHERE user_id=:u AND seen=0)",
            {'u': user_id}).fetchone()
        return (row[0], row[1] or 0, row[2])


@app.get('/api/events')
async def events(request: Request, user=Depends(current_user)):
    async def stream():
        # retry: 浏览器断线后 3s 自动重连（默认值因浏览器而异，显式指定）
        yield 'retry: 3000\n\n'
        previous = None
        token = digest_token(request.cookies.get('love_session', ''))
        rounds = 0
        # 长连接循环：靠 is_disconnected（客户端断开）与 session 失效退出；5s 心跳防止代理空闲超时
        while True:
            if await request.is_disconnected():
                break
            # 同步 sqlite 查询一律丢进线程池：busy_timeout=30s，一旦遇到写锁，
            # 在事件循环里直接查库会把整个进程（单 uvicorn worker）卡死。
            probe = await asyncio.to_thread(_sse_probe, token, user['id'], rounds % 10 == 0)
            if probe is None:
                break
            revision, private_revision, unread = probe
            signature = f'{revision}:{private_revision}:{unread}'
            if previous is None:
                # 首轮只建立基线，不推 data：EventSource 断线重连很常见（代理空闲超时、
                # 切前后台），每建一次连接就推一条，客户端会当成「数据变了」整页重绘，
                # 图库页那个 iframe 于是被反复销毁重建——用户看到的就是页面自己在刷新。
                # 真正的首次加载本来就走 refreshData()，不需要这条推送。
                previous = signature
                yield ': ready\n\n'
            elif signature != previous:
                # 带上 revision：客户端据此判断"数据到底变没变"，避免每次心跳都整页重渲染
                yield 'data: ' + dumps({'refresh': True, 'unread': unread, 'rev': signature}) + '\n\n'
                previous = signature
            else:
                yield ': heartbeat\n\n'
            rounds += 1
            await asyncio.sleep(5)
    return StreamingResponse(stream(), media_type='text/event-stream', headers={'X-Accel-Buffering': 'no', 'Cache-Control': 'no-cache'})


@app.get('/api/dashboard')
def dashboard(user=Depends(current_user)):
    """两个人的数据看板：记录、心情、互动与近一年趋势。只统计当前用户可见的内容。"""
    vis = "deleted IS NULL AND (kind NOT IN ('diary','draft','surprise') OR author=?)"
    with connect() as c:
        total = c.execute(f'SELECT count(*) FROM records WHERE {vis}', (user['id'],)).fetchone()[0]
        by_kind = {r['kind']: r['n'] for r in c.execute(
            f'SELECT kind, count(*) n FROM records WHERE {vis} GROUP BY kind', (user['id'],))}
        months = [{'month': r['m'], 'count': r['n']} for r in c.execute(
            f"SELECT strftime('%Y-%m', created, 'unixepoch') m, count(*) n FROM records "
            f"WHERE {vis} GROUP BY m ORDER BY m DESC LIMIT 12", (user['id'],))]
        months.reverse()
        moods = {r['e']: r['n'] for r in c.execute(
            f"SELECT json_extract(body,'$.emoji') e, count(*) n FROM records "
            f"WHERE {vis} AND kind='mood' AND json_extract(body,'$.emoji') IS NOT NULL GROUP BY e",
            (user['id'],))}
        likes = c.execute(
            "SELECT count(*) FROM likes l JOIN records r ON r.id=l.record_id "
            "WHERE r.deleted IS NULL AND (r.kind NOT IN ('diary','draft','surprise') OR r.author=?)",
            (user['id'],)).fetchone()[0]
        comments = c.execute(
            "SELECT count(*) FROM comments cm JOIN records r ON r.id=cm.record_id "
            "WHERE r.deleted IS NULL AND (r.kind NOT IN ('diary','draft','surprise') OR r.author=?)",
            (user['id'],)).fetchone()[0]
        photos = c.execute(
            "SELECT count(DISTINCT j.value) FROM records r, json_each(r.body,'$.media') j "
            "WHERE r.deleted IS NULL AND r.kind='post'").fetchone()[0]
        wishes_done = c.execute(
            f"SELECT count(*) FROM records WHERE {vis} AND kind='wish' AND json_extract(body,'$.done')=1",
            (user['id'],)).fetchone()[0]
        space = db.setting(c, 'space') or {}
    days = None
    since = (space.get('since') or '')[:10]
    if since:
        try:
            tz = ZoneInfo(space.get('timezone', 'Asia/Shanghai'))
            days = max(0, (dt.datetime.now(tz).date() - dt.date.fromisoformat(since)).days + 1)
        except ValueError:
            days = None
    return {'total': total, 'by_kind': by_kind, 'months': months, 'moods': moods,
            'likes': likes, 'comments': comments, 'photos': photos,
            'days_together': days, 'wishes_total': by_kind.get('wish', 0), 'wishes_done': wishes_done}


@app.get('/api/weekly')
def weekly(offset: int = 0, user=Depends(current_user)):
    """回忆周报：最近一周（或往前第 N 周）的回忆小结。只统计当前用户可见的内容。"""
    if offset > 0 or offset < -52:
        raise HTTPException(422, '只能查看最近一年的周报')
    with connect() as c:
        space = db.setting(c, 'space') or {}
    try:
        tz = ZoneInfo(space.get('timezone') or 'Asia/Shanghai')
    except Exception:
        tz = ZoneInfo('Asia/Shanghai')
    today = dt.datetime.now(tz).date()
    monday = today - dt.timedelta(days=today.weekday()) + dt.timedelta(weeks=offset)
    sunday = monday + dt.timedelta(days=6)

    def stamp(day):
        return int(dt.datetime.combine(day, dt.time.min, tzinfo=tz).timestamp())

    start, end = stamp(monday), stamp(sunday + dt.timedelta(days=1))
    vis = "deleted IS NULL AND (kind NOT IN ('diary','draft','surprise') OR author=?)"
    with connect() as c:
        rows = c.execute(f'SELECT * FROM records WHERE {vis} AND created>=? AND created<? ORDER BY created',
                         (user['id'], start, end)).fetchall()
        prev_total = c.execute(f'SELECT count(*) FROM records WHERE {vis} AND created>=? AND created<?',
                               (user['id'], start - 7 * 86400, start)).fetchone()[0]
        ids = [row['id'] for row in rows]
        likes, comments = {}, {}
        for pos in range(0, len(ids), 500):
            chunk = ids[pos:pos + 500]
            marks = ','.join('?' for _ in chunk)
            for row in c.execute(f'SELECT record_id, count(*) n FROM likes WHERE record_id IN ({marks}) GROUP BY record_id', chunk):
                likes[row['record_id']] = row['n']
            for row in c.execute(f'SELECT record_id, count(*) n FROM comments WHERE record_id IN ({marks}) GROUP BY record_id', chunk):
                comments[row['record_id']] = row['n']
        bodies = {row['id']: db.body_decode(row) for row in rows}
        media_ids = []
        for row in rows:
            for mid in bodies[row['id']].get('media') or []:
                if mid not in media_ids:
                    media_ids.append(mid)
        photos = 0
        for pos in range(0, len(media_ids), 500):
            chunk = media_ids[pos:pos + 500]
            marks = ','.join('?' for _ in chunk)
            photos += c.execute(f"SELECT count(*) FROM media WHERE id IN ({marks}) AND mime LIKE 'image/%'",
                                chunk).fetchone()[0]
        by_kind, moods, days = {}, {}, set()
        for row in rows:
            by_kind[row['kind']] = by_kind.get(row['kind'], 0) + 1
            days.add(dt.datetime.fromtimestamp(row['created'], tz).date())
            if row['kind'] == 'mood':
                emoji = bodies[row['id']].get('emoji')
                if emoji:
                    moods[emoji] = moods.get(emoji, 0) + 1
        # 挑最有内容的几条做"本周精选"：有图优先，再看互动
        def weight(row):
            return ((2 if bodies[row['id']].get('media') else 0)
                    + 2 * likes.get(row['id'], 0) + comments.get(row['id'], 0))

        picked = sorted(sorted(rows, key=weight, reverse=True)[:4], key=lambda row: row['created'])
        highlights = serialize_many(c, picked, user['id'])

    # streak：从今天往前数连续有记录的天数（上限 365 天，够用即可）
    streak = 0
    last_record_days_ago = None
    cutoff = stamp(today)
    with connect() as c:
        # 取最近一年所有可见记录的日期（去重），按天倒序
        day_rows = c.execute(
            f'SELECT DISTINCT created FROM records WHERE {vis} AND created>=? ORDER BY created DESC',
            (user['id'], cutoff - 365 * 86400)).fetchall()
    active_days = set()
    for r in day_rows:
        active_days.add(dt.datetime.fromtimestamp(r['created'], tz).date())
    d = today
    while d in active_days and streak < 365:
        streak += 1
        d -= dt.timedelta(days=1)
    # 若今天没记录，则从昨天开始往回找"最近一次记录是几天前"
    if streak == 0:
        for r in day_rows:
            day = dt.datetime.fromtimestamp(r['created'], tz).date()
            diff = (today - day).days
            if diff >= 0:
                last_record_days_ago = diff
                break

    total = len(rows)
    label = '这一周' if offset == 0 else ('上一周' if offset == -1 else f'{-offset} 周前')
    if total:
        message = f'{label}，你们一起写下了 {total} 段回忆'
        if photos:
            message += f'、{photos} 张照片'
        if days:
            message += f'，有 {len(days)} 天留下了痕迹'
        message += '。'
    else:
        message = f'{label}还没有记录，一起去写一点吧。'
    top_mood = max(moods.items(), key=lambda kv: kv[1])[0] if moods else None
    return {'offset': offset, 'label': label,
            'start': monday.isoformat(), 'end': sunday.isoformat(),
            'total': total, 'prev_total': prev_total, 'delta': total - prev_total,
            'days_active': len(days), 'photos': photos,
            'by_kind': by_kind, 'moods': moods, 'top_mood': top_mood,
            'likes': sum(likes.values()), 'comments': sum(comments.values()),
            'streak': streak, 'last_record_days_ago': last_record_days_ago,
            'highlights': highlights, 'message': message}


_WORD_STOP = set('''我们 你们 他们 她们 它们 自己 这个 那个 什么 怎么 就是 还是 因为 所以 但是 然后 如果
这样 那样 可以 已经 没有 真的 其实 不是 这就 是那 都很 也很 不会 觉得 时候 现在 今天 昨天 明天
一下 一点 一些 有点 好多 一直 知道 看到 感觉 心里 开心 喜欢 一个 两个 咱们 大家 东西 事情
还是 就会 就是 可是 而且 或者 虽然 不过 只是 有点 一样 也是 都是'''.split())


def _year_words(texts, limit=8):
    """年度关键词：中文按 2-gram 切词统计，配停用表过滤。

    不引第三方分词库——两个人一年的记录量级上，2-gram + 停用表已经够看出
    "这一年反复在写什么"，而多一个依赖就多一份装不上/升不动的风险。
    """
    counter = {}
    for text in texts:
        for seg in re.findall(r'[\u4e00-\u9fa5]{2,}', str(text or '')[:2000]):
            for i in range(len(seg) - 1):
                word = seg[i:i + 2]
                if word in _WORD_STOP or word[0] == word[1]:
                    continue
                counter[word] = counter.get(word, 0) + 1
    ranked = sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))
    return [{'w': w, 'n': n} for w, n in ranked[:limit] if n >= 2]


@app.get('/api/yearbook')
def yearbook(year: int = 0, user=Depends(current_user)):
    """小年报：指定年份的统计聚合，默认取当前年。

    除了基础计数，还给几项"留得住人"的：连续记录天数、最活跃的月份与星期、
    最常记的类型、心情 Top、年度关键词、这一年收到的赞与评论。
    """
    with connect() as c:
        space = db.setting(c, 'space')
    tz = ZoneInfo((space or {}).get('timezone', 'Asia/Shanghai'))
    current_year = dt.datetime.now(tz).year
    y = year or current_year
    with connect() as c:
        rows = [serialize(c, r, user['id']) for r in c.execute('SELECT * FROM records ORDER BY created')
                if db.visible(r, user['id']) and r['kind'] not in {'chat', 'album'}]
        like_count = dict(c.execute('SELECT record_id, count(*) FROM likes GROUP BY record_id').fetchall())
        comment_count = dict(c.execute('SELECT record_id, count(*) FROM comments GROUP BY record_id').fetchall())

    # 按"这条记录属于哪天"归年：优先 body.date（用户填的事发日），没有就用创建时间
    in_year = []
    for r in rows:
        day = (r['body'].get('date') or '')[:10]
        if not day:
            try:
                day = dt.datetime.fromtimestamp(r['created'], tz).strftime('%Y-%m-%d')
            except (TypeError, ValueError, OSError):
                day = ''
        if day[:4] == str(y):
            r['_day'] = day
            in_year.append(r)

    by_kind, by_month, by_weekday, moods = {}, {}, {}, {}
    photos = 0
    for r in in_year:
        by_kind[r['kind']] = by_kind.get(r['kind'], 0) + 1
        by_month[r['_day'][5:7]] = by_month.get(r['_day'][5:7], 0) + 1
        try:
            weekday = dt.date.fromisoformat(r['_day']).weekday()
        except ValueError:
            weekday = None
        if weekday is not None:
            by_weekday[weekday] = by_weekday.get(weekday, 0) + 1
        if r['kind'] == 'mood':
            emoji = r['body'].get('emoji') or '☀️'
            moods[emoji] = moods.get(emoji, 0) + 1
        photos += len([m for m in r.get('media', []) if (m.get('mime') or '').startswith('image/')])

    days = sorted({r['_day'] for r in in_year if r['_day']})
    streak = run = 0
    prev = None
    for day in days:
        try:
            run = run + 1 if prev and (dt.date.fromisoformat(day) - dt.date.fromisoformat(prev)).days == 1 else 1
        except ValueError:
            run = 1
        streak = max(streak, run)
        prev = day

    def top(counter, limit=1):
        return sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))[:limit]

    best_month = top(by_month)
    best_weekday = top(by_weekday)
    top_kind = top(by_kind)
    return {'year': y, 'is_current': y == current_year,
            'total': len(in_year), 'by_kind': by_kind, 'photos': photos,
            'moods': sum(1 for r in in_year if r['kind'] == 'mood'),
            'wishes_done': sum(1 for r in in_year if r['kind'] == 'wish' and r['body'].get('done')),
            'anniversaries': sum(1 for r in in_year if r['kind'] == 'anniversary'),
            'active_days': len(days), 'streak': streak,
            'best_month': {'month': int(best_month[0][0]), 'count': best_month[0][1]} if best_month else None,
            'best_weekday': {'weekday': best_weekday[0][0], 'count': best_weekday[0][1]} if best_weekday else None,
            'top_kind': {'kind': top_kind[0][0], 'count': top_kind[0][1]} if top_kind else None,
            'mood_top': [{'emoji': e, 'n': n} for e, n in top(moods, 3)],
            'words': _year_words([(r['body'].get('title') or '') + ' ' + (r['body'].get('content') or '')
                                  for r in in_year]),
            'interactions': sum(like_count.get(r['id'], 0) + comment_count.get(r['id'], 0) for r in in_year)}


@app.get('/api/calendar')
def calendar(month: str = '', user=Depends(current_user)):
    """共同年历：某月每天的心情/纪念日/打卡/动态聚合。"""
    if not re.fullmatch(r'\d{4}-\d{2}', month):
        with connect() as c:
            space = db.setting(c, 'space')
        month = dt.datetime.now(ZoneInfo((space or {}).get('timezone', 'Asia/Shanghai'))).strftime('%Y-%m')
    year, mon = int(month[:4]), int(month[5:7])
    first, last = dt.date(year, mon, 1), (dt.date(year, mon + 1, 1) if mon < 12 else dt.date(year + 1, 1, 1))
    days = {}
    with connect() as c:
        rows = [serialize(c, r, user['id']) for r in c.execute('SELECT * FROM records')
                if db.visible(r, user['id'])]
    for r in rows:
        if r['kind'] == 'mood' and (r['body'].get('date') or '').startswith(month):
            days.setdefault(r['body']['date'][8:10], {}).setdefault('moods', []).append(
                {'author': r['author'], 'emoji': r['body'].get('emoji', '☀️')})
        elif r['kind'] == 'post' and (r['body'].get('date') or '').startswith(month):
            days.setdefault(r['body']['date'][8:10], {}).setdefault('posts', []).append(
                {'id': r['id'], 'title': r['body'].get('title') or (r['body'].get('content') or '')[:40]})
        elif r['kind'] == 'anniversary':
            due = None
            body = r['body']
            if body.get('annual') == 'lunar':
                try:
                    from lunardate import LunarDate
                    base = dt.date.fromisoformat(body['date'])
                    lunar = LunarDate.fromSolarDate(base.year, base.month, base.day)
                    for y in (year, year + 1):
                        try:
                            candidate = LunarDate(y, lunar.month, lunar.day, False).toSolarDate()
                            if first <= candidate <= last:
                                due = candidate
                                break
                        except ValueError:
                            continue
                except Exception:
                    due = None
            elif body.get('annual', True):
                try:
                    candidate = dt.date.fromisoformat(body['date']).replace(year=year)
                    due = candidate if candidate >= first else candidate.replace(year=year + 1)
                except ValueError:
                    due = None
            else:
                due = dt.date.fromisoformat(body['date']) if body.get('date') else None
            if due and first <= due <= last:
                days.setdefault(f'{due.day:02d}', {}).setdefault('anniversaries', []).append(
                    {'id': r['id'], 'title': body.get('title', '纪念日')})
    for r in rows:
        if r['kind'] == 'habit':
            for check in r.get('checks', []):
                if check['day'].startswith(month):
                    days.setdefault(check['day'][8:10], {}).setdefault('checks', []).append({'author': check['author']})
    return {'month': month, 'days': {k: v for k, v in sorted(days.items())}}


@app.get('/api/on-this-day')
def on_this_day(user=Depends(current_user)):
    """历史上的今天：返回今天月-日匹配的所有可见记录，按年份分组。"""
    with connect() as c:
        space = db.setting(c, 'space')
    tz_name = (space or {}).get('timezone', 'Asia/Shanghai')
    now_local = dt.datetime.now(ZoneInfo(tz_name))
    today_md = now_local.strftime('-%m-%d')
    today_year = now_local.year
    with connect() as c:
        rows = [serialize(c, r, user['id']) for r in c.execute('SELECT * FROM records ORDER BY created')
                if db.visible(r, user['id']) and r['kind'] not in {'chat', 'album'}]
    groups = {}
    for r in rows:
        date = (r['body'].get('date') or '')[:10]
        if date.endswith(today_md):
            groups.setdefault(int(date[:4]), []).append(r)
    return [{'year': y, 'is_today': y == today_year, 'items': groups[y]}
            for y in sorted(groups.keys(), reverse=True)]


class BrowserPushInput(BaseModel):
    endpoint: str = Field(min_length=1, max_length=4096)
    keys: dict[str, str]


class BrowserPushEndpoint(BaseModel):
    endpoint: str = Field(min_length=1, max_length=4096)


@app.post('/api/native-push/test')
def test_native_push(user=Depends(current_user)):
    if not ntfy_enabled():
        raise HTTPException(503, '内置 ntfy 系统推送已停用，通知由第三方渠道与浏览器 Web Push 承担')
    with connect() as c:
        topic = db.ensure_push_topic(c, user['id'])
        nid = uid()
        timestamp = now()
        c.execute('INSERT INTO notices VALUES (?,?,?,?,?,?,0,?)',
                  (nid, user['id'], 'test', '后台推送测试', None, timestamp, None))
        c.execute('INSERT INTO push_outbox(id,notice_id,user_id,topic,title,next_at) VALUES (?,?,?,?,?,?)',
                  (uid(), nid, user['id'], topic, '后台推送测试', timestamp))
    nudge_worker()
    return {'ok': True}


@app.get('/api/webpush')
def webpush_status(user=Depends(current_user)):
    with connect() as c:
        count = c.execute('SELECT count(*) FROM webpush_subscriptions WHERE user_id=?', (user['id'],)).fetchone()[0]
    return {'public_key': webpush_service.public_key(), 'devices': count}


@app.put('/api/webpush/subscription')
def save_webpush_subscription(body: BrowserPushInput, user=Depends(current_user)):
    try:
        subscription = webpush_service.validate_subscription(body.model_dump())
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    endpoint_digest = webpush_service.endpoint_hash(subscription['endpoint'])
    sealed = webpush_service.seal_subscription(subscription)
    with connect() as c:
        old = c.execute('SELECT id,user_id FROM webpush_subscriptions WHERE endpoint_hash=?', (endpoint_digest,)).fetchone()
        if old and old['user_id'] != user['id']:
            # A browser endpoint belongs to one signed-in account at a time.
            c.execute('DELETE FROM webpush_subscriptions WHERE id=?', (old['id'],))
            old = None
        if old:
            c.execute('UPDATE webpush_subscriptions SET payload=?,updated=? WHERE id=?',
                      (sealed, now(), old['id']))
        else:
            c.execute('INSERT INTO webpush_subscriptions(id,user_id,endpoint_hash,payload,created,updated) VALUES (?,?,?,?,?,?)',
                      (uid(), user['id'], endpoint_digest, sealed, now(), now()))
        count = c.execute('SELECT count(*) FROM webpush_subscriptions WHERE user_id=?', (user['id'],)).fetchone()[0]
    return {'ok': True, 'devices': count}


@app.post('/api/webpush/unsubscribe')
def remove_webpush_subscription(body: BrowserPushEndpoint, user=Depends(current_user)):
    endpoint_digest = webpush_service.endpoint_hash(body.endpoint)
    with connect() as c:
        c.execute('DELETE FROM webpush_subscriptions WHERE user_id=? AND endpoint_hash=?',
                  (user['id'], endpoint_digest))
        count = c.execute('SELECT count(*) FROM webpush_subscriptions WHERE user_id=?', (user['id'],)).fetchone()[0]
    return {'ok': True, 'devices': count}


@app.post('/api/webpush/test')
def test_webpush(user=Depends(current_user)):
    with connect() as c:
        subscriptions = c.execute('SELECT id FROM webpush_subscriptions WHERE user_id=?', (user['id'],)).fetchall()
        if not subscriptions:
            raise HTTPException(409, '请先在当前设备开启浏览器通知')
        nid = uid()
        c.execute('INSERT INTO notices VALUES (?,?,?,?,?,?,0,?)',
                  (nid, user['id'], 'test', '恋爱空间测试通知', None, now(), None))
        for subscription in subscriptions:
            c.execute('INSERT INTO webpush_outbox(id,notice_id,subscription_id,user_id,next_at) VALUES (?,?,?,?,?)',
                      (uid(), nid, subscription['id'], user['id'], now()))
    nudge_worker()
    return {'ok': True}


CHANNEL_KINDS = {'smtp', 'bark', 'serverchan', 'pushplus', 'wecom', 'webhook', 'telegram', 'dingtalk', 'feishu', 'ntfy'}
EVENTS = {'chat', 'comment', 'note', 'activity', 'anniversary', 'wish', 'surprise', 'habit', 'backup', 'storage', 'system', 'period'}


class ChannelInput(BaseModel):
    kind: str
    name: str = Field(min_length=1, max_length=60)
    config: dict = Field(default_factory=dict)
    events: list[str] = Field(default_factory=lambda: ['chat', 'comment', 'anniversary', 'surprise'])
    enabled: bool = True
    quiet_start: int = Field(default=22, ge=0, le=23)
    quiet_end: int = Field(default=8, ge=0, le=23)
    interval: int = Field(default=300, ge=0, le=86400)


@app.get('/api/channels')
def channels(user=Depends(current_user)):
    with connect() as c:
        result = []
        for row in c.execute('SELECT * FROM channels WHERE owner=?', (user['id'],)):
            item = dict(row)
            item.pop('config')
            item['events'] = json.loads(item['events'])
            result.append(item)
    return result


@app.post('/api/channels')
def add_channel(body: ChannelInput, user=Depends(current_user)):
    from .notifications import validate_config
    if body.kind not in CHANNEL_KINDS or not set(body.events).issubset(EVENTS):
        raise HTTPException(422, '通知类型不正确')
    try:
        validate_config(body.kind, body.config)
    except ValueError as e:
        raise HTTPException(422, str(e))
    with connect() as c:
        cid = uid()
        c.execute('INSERT INTO channels VALUES (?,?,?,?,?,?,?,?,?,?)',
                  (cid, user['id'], body.kind, body.name, cipher(PURPOSE_CHANNEL_CONFIG).encrypt(dumps(body.config).encode()).decode(),
                   dumps(body.events), body.enabled, body.quiet_start, body.quiet_end, body.interval))
    return {'id': cid}


@app.delete('/api/channels/{cid}')
def delete_channel(cid: str, user=Depends(current_user)):
    with connect() as c:
        c.execute('DELETE FROM channels WHERE id=? AND owner=?', (cid, user['id']))
    return {'ok': True}


@app.post('/api/channels/{cid}/test')
def test_channel(cid: str, user=Depends(current_user)):
    with connect() as c:
        channel = c.execute('SELECT * FROM channels WHERE id=? AND owner=?', (cid, user['id'])).fetchone()
        if not channel:
            raise HTTPException(404, '渠道不存在')
        nid = uid()
        c.execute('INSERT INTO notices VALUES (?,?,?,?,?,?,0,?)', (nid, user['id'], 'test', '恋爱空间测试通知', None, now(), None))
        c.execute('INSERT INTO deliveries(id,notice_id,channel_id,next_at) VALUES (?,?,?,?)', (uid(), nid, cid, now()))
    nudge_worker()
    return {'ok': True}


@app.get('/api/deliveries')
def deliveries(user=Depends(current_user)):
    with connect() as c:
        return [dict(r) for r in c.execute('''SELECT d.id,d.status,d.attempts,d.error,d.sent_at,n.title,c.name
          FROM deliveries d JOIN channels c ON c.id=d.channel_id JOIN notices n ON n.id=d.notice_id
          WHERE c.owner=? ORDER BY n.created DESC LIMIT 100''', (user['id'],))]


@app.post('/api/deliveries/{did}/retry')
def retry_delivery(did: str, user=Depends(current_user)):
    with connect() as c:
        c.execute("UPDATE deliveries SET status='pending',attempts=0,next_at=?,error=NULL WHERE id=? AND status='failed' AND channel_id IN (SELECT id FROM channels WHERE owner=?)", (now(), did, user['id']))
    return {'ok': True}


@app.get('/api/export')
def export(request: Request, user=Depends(current_user)):
    # 导出要打包全部可见记录与附件，比普通请求重得多，别让它被当成廉价接口反复打
    rate_limit(request, 'export', 10, 300)
    from .backups import user_export
    path = user_export(user['id'])
    from starlette.background import BackgroundTask
    return FileResponse(path, filename='我们的回忆.zip', media_type='application/zip', background=BackgroundTask(path.unlink, missing_ok=True))


@app.get('/api/export/markdown')
def export_markdown(request: Request, user=Depends(current_user)):
    """导出 Markdown 知识库（"恋爱第二大脑"）。与 JSON 导出共用限流档位。"""
    rate_limit(request, 'export', 10, 300)
    from .markdown_export import build_markdown_archive
    path = build_markdown_archive(user['id'])
    from starlette.background import BackgroundTask
    stamp = __import__('datetime').datetime.now().strftime('%Y%m%d')
    return FileResponse(path, filename=f'恋爱空间-第二大脑-{stamp}.zip',
                        media_type='application/zip', background=BackgroundTask(path.unlink, missing_ok=True))


@app.get('/api/export/ics')
def export_ics(user=Depends(current_user)):
    """导出日历（.ics）：纪念日按年循环、愿望与清单带上计划日。

    放进手机自带日历是这类记录最自然的下游——纪念日不再靠 App 提醒，
    提醒也能用系统自带的（比站内推送可靠）。农历纪念日没法用 RRULE 表达，
    这里只写今年这一次的那天，明年再看一次导出。
    """
    with connect() as c:
        space = db.setting(c, 'space')
        rows = [serialize(c, r, user['id']) for r in c.execute('SELECT * FROM records ORDER BY created')
                if db.visible(r, user['id'])]
    tz = ZoneInfo((space or {}).get('timezone', 'Asia/Shanghai'))
    this_year = dt.datetime.now(tz).year

    def esc(value):
        return (str(value or '').replace('\\', '\\\\').replace(';', '\\;')
                .replace(',', '\\,').replace('\n', '\\n'))

    def lunar_due(day, year):
        try:
            from lunardate import LunarDate
            base = dt.date.fromisoformat(day)
            lunar = LunarDate.fromSolarDate(base.year, base.month, base.day)
            return LunarDate(year, lunar.month, lunar.day, False).toSolarDate()
        except Exception:
            return None

    lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Love Space//CN', 'CALSCALE:GREGORIAN',
             'METHOD:PUBLISH', 'X-WR-CALNAME:我们的纪念日']
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    made = 0
    for r in rows:
        body, kind = r['body'], r['kind']
        day, title, yearly, note = '', '', False, ''
        if kind == 'anniversary' and body.get('date'):
            day, title, note = body['date'][:10], body.get('title') or '纪念日', body.get('content') or ''
            yearly = body.get('annual') in (True, 'lunar')
            if body.get('annual') == 'lunar':
                due = lunar_due(day, this_year) or lunar_due(day, this_year + 1)
                if not due:
                    continue
                day, yearly = due.isoformat(), False
        elif kind in {'wish', 'quest'} and body.get('date') and body.get('done') is not True:
            day, title = body['date'][:10], body.get('title') or ('想做的事' if kind == 'wish' else '清单')
            note = body.get('content') or ''
        if not day or not title:
            continue
        try:
            dt.date.fromisoformat(day)
        except ValueError:
            continue
        made += 1
        lines += ['BEGIN:VEVENT', f'UID:{r["id"]}@love-space', f'DTSTAMP:{stamp}',
                  f'DTSTART;VALUE=DATE:{day.replace("-", "")}']
        if yearly:
            lines.append('RRULE:FREQ=YEARLY')
        lines.append(f'SUMMARY:{esc(title)}')
        if note:
            lines.append(f'DESCRIPTION:{esc(note[:400])}')
        lines.append('TRANSP:TRANSPARENT')
        lines.append('END:VEVENT')
    lines.append('END:VCALENDAR')
    if not made:
        raise HTTPException(404, '还没有可导出的纪念日或计划')
    stamp_name = dt.datetime.now(tz).strftime('%Y%m%d')
    return Response('\r\n'.join(lines) + '\r\n', media_type='text/calendar; charset=utf-8',
                    headers={'Content-Disposition':
                             f"attachment; filename=love-space-{stamp_name}.ics; "
                             f"filename*=UTF-8''{quote(f'我们的纪念日-{stamp_name}.ics')}"})


@app.post('/api/backups')
def backup(request: Request, user=Depends(current_user)):
    if not user['admin']:
        raise HTTPException(403, '完整备份由服务器管理员操作；个人记录可在导出中下载')
    rate_limit(request, 'backup', 5, 300)
    from .backups import BackupRefused, create_backup
    try:
        path = create_backup()
    except BackupRefused:
        raise HTTPException(503, '服务器未配置备份密码，已拒绝生成明文备份；请联系管理员设置 BACKUP_PASSWORD')
    except Exception as exc:
        # 真实原因可能是磁盘满、目录权限、密钥损坏……只进日志，用户只看到一句人话
        log.exception('手动备份失败')
        raise HTTPException(500, '备份失败（%s），请检查存储空间和备份目录权限' % type(exc).__name__)
    return {'name': path.name}


@app.get('/api/storage')
def storage_usage(user=Depends(current_user)):
    """存储占用：媒体按类型/月份分桶，数据库与备份总大小，磁盘剩余。"""
    if not user['admin']:
        raise HTTPException(403, '需要管理员账号')
    usage = shutil.disk_usage(db.DATA)
    media_root = db.DATA / 'media'
    by_kind = {'image': 0, 'video': 0, 'audio': 0}
    by_month = {}
    if media_root.is_dir():
        for path in media_root.rglob('*'):
            if path.is_file():
                size = path.stat().st_size
                kind = path.parent.parent.name if path.parent.parent.name in by_kind else 'other'
                if kind in by_kind:
                    by_kind[kind] += size
                month = path.parent.name
                by_month[month] = by_month.get(month, 0) + size
    db_size = (db.DATA / 'love.db').stat().st_size if (db.DATA / 'love.db').is_file() else 0
    wal_size = (db.DATA / 'love.db-wal').stat().st_size if (db.DATA / 'love.db-wal').is_file() else 0
    # 生理期是独立文件，磁盘占用和记录条数都要算进来，否则看板上的数字对不上
    pdb_size = period.db_path().stat().st_size if period.db_path().is_file() else 0
    pwal_size = period.db_path().with_name('period.db-wal').stat().st_size if period.db_path().with_name('period.db-wal').is_file() else 0
    backups_size = sum(p.stat().st_size for p in (db.DATA / 'backups').glob('*.zip')) if (db.DATA / 'backups').is_dir() else 0
    with connect() as c:
        record_count = c.execute('SELECT count(*) FROM records WHERE deleted IS NULL').fetchone()[0] + period.count_active()
        media_count = c.execute('SELECT count(*) FROM media').fetchone()[0]
    return {'total': sum(by_kind.values()) + db_size + wal_size + pdb_size + pwal_size + backups_size,
            'media_by_kind': by_kind, 'media_by_month': dict(sorted(by_month.items())[-12:]),
            'db': db_size + wal_size + pdb_size + pwal_size, 'backups': backups_size,
            'disk_free': usage.free, 'disk_total': usage.total,
            'record_count': record_count, 'media_count': media_count}


@app.get('/api/backups')
def backups(user=Depends(current_user)):
    if not user['admin']:
        raise HTTPException(403, '需要管理员账号')
    return [{'name': p.name, 'size': p.stat().st_size, 'created': p.stat().st_mtime,
             'encrypted': p.suffix == '.enc'}
            for p in sorted((db.DATA / 'backups').glob('backup-*'), reverse=True)]


@app.get('/api/backups/{name}')
def download_backup(name: str, user=Depends(current_user)):
    if not user['admin'] or not re.fullmatch(r'backup-[\w-]+\.zip(\.enc)?', name):
        raise HTTPException(403, '无权访问')
    path = db.DATA / 'backups' / name
    if not path.is_file():
        raise HTTPException(404, '备份不存在')
    return FileResponse(path, filename=name, media_type='application/zip')


# ── 聊天记录导入（微信 / QQ / 抖音）──────────────────────────

IMPORT_PLATFORMS = {'auto', 'wechat', 'qq', 'douyin'}


def read_import_file(file: UploadFile) -> bytes:
    limit = int(os.getenv('MAX_IMPORT_MB', '50')) * 1024 * 1024
    raw = file.file.read(limit + 1)
    if not raw:
        raise HTTPException(422, '文件为空')
    if len(raw) > limit:
        raise HTTPException(413, f'文件超过 {limit // 1024 // 1024}MB，请拆分后导入')
    return raw


def parse_import_file(filename, raw):
    """统一入口：zip 走带媒体解析，其余走文本解析。返回 (messages, title_hint)。"""
    if (filename or '').lower().endswith('.zip'):
        return importers.parse_zip(raw)
    return importers.parse_file(filename, raw)


def parse_import_or_fail(filename, raw):
    """解析导入文件：已知的约束违规直接给用户可操作提示，其余记录日志后给通用提示。

    不要在这里用  except Exception: 一律吞掉  ——  那样用户永远只能看到一句
    「无法识别」，而真实原因（ZIP 损坏 / 条目超限 / 编码异常）只存在于服务器的记忆里。
    """
    generic = '无法识别这个文件，请确认是微信、QQ 或抖音导出的 txt / csv / json / zip'
    try:
        return parse_import_file(filename, raw)
    except HTTPException:
        raise
    except ValueError as exc:
        message = str(exc).strip()
        if message.startswith('ZIP '):
            raise HTTPException(422, message + '，请拆分或压缩后再导入')
        raise HTTPException(422, generic)
    except zipfile.BadZipFile:
        raise HTTPException(422, 'ZIP 文件已损坏，或实际上不是压缩包，请重新导出后再试')
    except Exception:
        logging.getLogger('love.space').exception('聊天记录解析失败：%s', filename)
        raise HTTPException(422, generic)


def save_import_media(user_id, name, data: bytes):
    """把导入 zip 里的图片保存为正式媒体文件（attached=1，避免被孤儿清理）。"""
    suffix = Path(name).suffix.lower()
    mime_map = {'.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
                '.gif': 'image/gif', '.webp': 'image/webp', '.bmp': 'image/bmp'}
    mime = mime_map.get(suffix)
    if not mime:
        return None
    from PIL import Image as PILImage
    try:
        with PILImage.open(io.BytesIO(data)) as im:
            im.verify()
    except Exception:
        return None
    mid = uid()
    folder = db.media_dir(mime, now())
    folder.mkdir(parents=True, exist_ok=True)
    (folder / (mid + suffix)).write_bytes(data)
    with connect() as c:
        c.execute('INSERT INTO media(id,owner,name,mime,size,ext,created,attached) VALUES (?,?,?,?,?,?,?,1)',
                  (mid, user_id, Path(name).name[:200], mime, len(data), suffix, now()))
        # 共享 revision 不用在这里推：imports 的 INSERT 触发器已经推过了
        # （见 db.py 的 revision_imports_insert），对端会收到 refresh 并拉到这些图
    return mid


@app.post('/api/imports/preview')
def import_preview(request: Request, file: UploadFile = File(...), user=Depends(current_user)):
    rate_limit(request, 'import', 30, 300)
    raw = read_import_file(file)
    messages, title_hint = parse_import_or_fail(file.filename, raw)
    if not messages:
        raise HTTPException(422, '没有解析到聊天记录，请确认文件里是微信、QQ 或抖音导出的对话内容')
    summary = importers.summarize(messages)
    media_count = sum(1 for m in messages if m.get('media_bytes'))
    sample = [{k: v for k, v in m.items() if not k.endswith('_bytes')} for m in messages[:5]]
    return {**summary, 'title_hint': title_hint, 'sample': sample, 'media_count': media_count}


@app.post('/api/imports')
def import_create(request: Request, file: UploadFile = File(...), platform: str = Form('auto'),
                  title: str = Form(''), me: str = Form(''), user=Depends(current_user)):
    rate_limit(request, 'import', 30, 300)
    platform = platform.strip().lower()
    if platform not in IMPORT_PLATFORMS:
        raise HTTPException(422, '不支持的平台')
    raw = read_import_file(file)
    messages, title_hint = parse_import_or_fail(file.filename, raw)
    if not messages:
        raise HTTPException(422, '没有解析到聊天记录，请确认文件里是微信、QQ 或抖音导出的对话内容')
    media_count = 0
    for m in messages:
        data = m.pop('media_bytes', None)
        if data is None:
            continue
        mid = save_import_media(user['id'], m.get('media_name', 'image.jpg'), data)
        if mid:
            m['media_id'] = mid
            media_count += 1
    summary = importers.summarize(messages)
    if platform == 'auto':
        platform = 'wechat'  # 自动识别时按微信样式展示
    title = (title.strip() or title_hint or (file.filename or '聊天记录').rsplit('.', 1)[0])[:60]
    me = me.strip()[:50]
    iid = uid()
    with connect() as c:
        c.execute('BEGIN IMMEDIATE')
        # 消息按日分组须用空间时区：容器系统时区多为 UTC，直接 fromtimestamp 会把
        # 中国用户晚上 8 点前的消息归到前一天
        tz = ZoneInfo((db.setting(c, 'space') or {}).get('timezone', 'Asia/Shanghai'))
        c.execute('INSERT INTO imports VALUES (?,?,?,?,?,?,?,?,?,?)',
                  (iid, platform, title, user['id'], dumps(summary['participants']), me,
                   summary['count'], summary['start_at'], summary['end_at'], now()))
        c.executemany('INSERT INTO import_messages(import_id,sender,content,kind,sent_at,day,mine,media_id) VALUES (?,?,?,?,?,?,?,?)',
                      [(iid, m['sender'], m['content'], m['kind'], m['sent_at'],
                        dt.datetime.fromtimestamp(m['sent_at'], tz).date().isoformat() if m['sent_at'] else '',
                        1 if me and m['sender'] == me else 0, m.get('media_id', '')) for m in messages])
        # 对方可能正停在别的页面，靠 SSE 只能刷新出数据、说不清发生了什么，
        # 所以额外留一条提醒，让 TA 知道这份记录是谁放进去的
        db.notice(c, 'activity', f'对方导入了一份聊天记录：{title}', actor=user['id'])
    return {'id': iid, 'title': title, 'media_count': media_count, **summary}


def get_import(c, iid):
    """只校验存在性，不校验归属——聊天记录是两人共享的，另一半也必须能打开。

    author 字段保留下来只是用于在列表上显示「由谁导入」。
    """
    row = c.execute('SELECT * FROM imports WHERE id=?', (iid,)).fetchone()
    if not row:
        raise HTTPException(404, '聊天记录不存在')
    return row


@app.get('/api/imports')
def import_list(user=Depends(current_user)):
    """共享列表：不做 author 过滤，两人看到的是同一份。"""
    with connect() as c:
        return [{**dict(r),
                 'last': (c.execute('SELECT content FROM import_messages WHERE import_id=? ORDER BY id DESC LIMIT 1', (r['id'],)).fetchone() or [''])[0]}
                for r in c.execute('SELECT * FROM imports ORDER BY created DESC')]


@app.get('/api/imports/{iid}/messages')
def import_messages(iid: str, cursor: int = 0, direction: str = 'before', limit: int = 100,
                    q: str = '', day: str = '', user=Depends(current_user)):
    limit = min(max(limit, 1), 500)
    with connect() as c:
        get_import(c, iid)
        filters, params = ['import_id=?'], [iid]
        if q:
            filters.append('content LIKE ?')
            params.append(f'%{q[:100]}%')
        if day and re.fullmatch(r'\d{4}-\d{2}-\d{2}', day):
            filters.append('day=?')
            params.append(day)
        where = ' AND '.join(filters)
        if direction == 'after':
            rows = c.execute(f'SELECT * FROM import_messages WHERE {where} AND id>? ORDER BY id LIMIT ?',
                             (*params, cursor, limit + 1)).fetchall()
        elif cursor:
            rows = c.execute(f'SELECT * FROM import_messages WHERE {where} AND id<? ORDER BY id DESC LIMIT ?',
                             (*params, cursor, limit + 1)).fetchall()
            rows.reverse()
        else:
            rows = c.execute(f'SELECT * FROM import_messages WHERE {where} ORDER BY id DESC LIMIT ?',
                             (*params, limit + 1)).fetchall()
            rows.reverse()
        total = c.execute(f'SELECT count(*) FROM import_messages WHERE {where}', params).fetchone()[0]
    has_more = len(rows) > limit
    rows = rows[:limit]
    return {'messages': [dict(r) for r in rows], 'total': total, 'has_more': has_more,
            'earliest': rows[0]['id'] if rows else None, 'latest': rows[-1]['id'] if rows else None}


@app.delete('/api/imports/{iid}')
def import_delete(iid: str, user=Depends(current_user)):
    """两人共享同一份聊天记录，所以不区分是谁导入的——谁都能删。

    消息行靠 import_messages.import_id 的外键 ON DELETE CASCADE 一起清掉。
    zip 里带进来的图片会留着：它们在 media 表里是 attached=1，删掉会让对方
    刚看过的图突然 404，而孤儿清理任务也不会动它们，代价只是一点磁盘。
    """
    with connect() as c:
        get_import(c, iid)
        c.execute('DELETE FROM imports WHERE id=?', (iid,))
    return {'ok': True}


app.mount('/static', StaticFiles(directory=db.ROOT / 'static'), name='static')

# 情侣摆拍参考图库：同源托管在 /srv/pose-gallery，由 NAS 以 :ro 卷挂载进容器。
# 仅在目录存在时挂载——本地/CI 没有这个目录时不应因此启动失败（线上容器始终挂载）。
_POSE_GALLERY_DIR = os.getenv('POSE_GALLERY_DIR', '/srv/pose-gallery')


# 图库外壳页注入的「AI 合成台配置同步」脚本。上游把 provider 配置（含 API Key）只存
# localStorage，换设备/清缓存就得重填；这里在页面任何 bundle 之前跑一段：本地为空就用
# NAS 上那份灌回去，本地有改动就回写，两边按「最后写入者为准」收敛。
# 用同步 XHR 是刻意的——localStorage 是同步 API，异步拿回来时上游已经按空配置渲染了。
_POSE_AI_BOOT = """<script>
(function () {
  var CFG_KEY = 'pose_atlas_api_config_v3', CFG_API = '/api/pose-ai/config', CFG_STAMP = CFG_KEY + '_nas_saved';
  var HIS_KEY = 'pose_atlas_history_v3', HIS_API = '/api/pose-ai/history', HIS_STAMP = HIS_KEY + '_nas_saved';
  var DB_NAME = 'pose_atlas_studio_db', DB_STORE = 'kv_store', LIMIT = 30;
  var HEADERS = { 'Content-Type': 'application/json', 'X-Love-Space': '1' };

  function ls(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
  function lsSet(k, v) { try { localStorage.setItem(k, v); return true; } catch (e) { return false; } }
  function stamp(k) { return Number(ls(k)) || 0; }
  function getJSON(url) {
    try {
      var xhr = new XMLHttpRequest();
      xhr.open('GET', url, false);
      xhr.send(null);
      if (xhr.status === 200) return JSON.parse(xhr.responseText || '{}');
    } catch (e) {}
    return null;
  }
  function putP(url, body) {
    try {
      return fetch(url, { method: 'PUT', headers: HEADERS, body: JSON.stringify(body) });
    } catch (e) { return Promise.reject(e); }
  }

  /* ---------- 1. 合成台 provider 配置（含 API Key） ---------- */
  var remote = getJSON(CFG_API) || {}, cfgRemote = remote.config || null;
  var cfgSaved = Number(remote.saved) || 0, cfgLocal = null;
  try { cfgLocal = JSON.parse(ls(CFG_KEY) || 'null'); } catch (e) {}
  function pushConfig(cfg) {
    var at = Date.now();
    putP(CFG_API, { config: cfg }).then(function (r) {
      if (r && r.ok) lsSet(CFG_STAMP, String(at));
    }).catch(function () {});
  }
  if (cfgRemote && (!cfgLocal || cfgSaved > stamp(CFG_STAMP))) {
    if (lsSet(CFG_KEY, JSON.stringify(cfgRemote))) lsSet(CFG_STAMP, String(cfgSaved));
  } else if (cfgLocal) {
    pushConfig(cfgLocal);
  }

  /* ---------- 2. 生成记录 ----------
     上游把记录写 IndexedDB，imageUrl 常是 data:base64 的整张图（1-4MB/张），30 条上百 MB，
     配额一崩记录就没了。这里把图转存到本站 /media 换成短 URL，再整份同步到 NAS。 */
  var ours = false, slim = {}, tried = {};

  function keyOf(it) { return String((it && (it.id || it.createdAt)) || ''); }
  function isHosted(u) { return typeof u === 'string' && u.indexOf('/media/') === 0; }
  function sameDb(store) {
    try { return !!(store.transaction && store.transaction.db && store.transaction.db.name === DB_NAME); }
    catch (e) { return false; }
  }

  function openDb(cb) {
    try {
      var req = indexedDB.open(DB_NAME, 1);
      req.onupgradeneeded = function () {
        var db = req.result;
        if (db.objectStoreNames && !db.objectStoreNames.contains(DB_STORE)) db.createObjectStore(DB_STORE);
      };
      req.onsuccess = function () { cb(req.result); };
      req.onerror = function () { cb(null); };
      req.onblocked = function () { cb(null); };
    } catch (e) { cb(null); }
  }
  function dbPut(list) {
    openDb(function (db) {
      if (!db) return;
      try {
        ours = true;
        db.transaction(DB_STORE, 'readwrite').objectStore(DB_STORE).put(list, HIS_KEY);
      } catch (e) {}
      ours = false;
    });
  }

  function uploadOne(it) {
    var k = keyOf(it), url = it && it.imageUrl;
    if (!url || isHosted(url) || tried[k]) return Promise.resolve();
    tried[k] = 1;
    return fetch(url).then(function (r) {
      if (!r.ok && r.status !== 0) throw 0;
      return r.blob();
    }).then(function (blob) {
      if (!blob || !blob.size) throw 0;
      var fd = new FormData();
      fd.append('file', blob, 'pose-' + (it.id || 'x') + '.png');
      return fetch('/api/media', { method: 'POST', headers: { 'X-Love-Space': '1' }, body: fd });
    }).then(function (r) { return r.json(); }).then(function (j) {
      if (!j || !j.id) throw 0;
      var copy = {}, key;
      for (key in it) { if (Object.prototype.hasOwnProperty.call(it, key)) copy[key] = it[key]; }
      copy.imageUrl = '/media/' + j.id + '?preview=true';
      slim[k] = copy;
    }).catch(function () {});
  }

  var pending = null, running = false;
  function pushHistory(list) {
    pending = Array.isArray(list) ? list : [];
    if (!running) flush();
  }
  function flush() {
    if (!pending) { running = false; return; }
    var list = pending;
    pending = null;
    running = true;
    var seq = Promise.resolve(), i;
    for (i = 0; i < list.length; i++) {
      (function (it) { seq = seq.then(function () { return uploadOne(it); }); })(list[i]);
    }
    seq.then(function () {
      var out = [];
      for (var j = 0; j < list.length; j++) out.push(slim[keyOf(list[j])] || list[j]);
      return putP(HIS_API, { items: out }).then(function (r) {
        if (r && r.ok) {
          lsSet(HIS_STAMP, String(Date.now()));
          /* 顺手把本地那份换成瘦记录：base64 不进 localStorage / IndexedDB */
          var text = JSON.stringify(out);
          if (text.length < 4 * 1024 * 1024) { lsSet(HIS_KEY, text); dbPut(out); }
        }
      });
    }).catch(function () {}).then(flush);
  }

  var hisRemote = getJSON(HIS_API) || {};
  var remItems = Array.isArray(hisRemote.items) ? hisRemote.items : [];
  var remSaved = Number(hisRemote.saved) || 0, locItems = [];
  try { locItems = JSON.parse(ls(HIS_KEY) || '[]'); } catch (e) {}
  if (!Array.isArray(locItems)) locItems = [];

  var merged = [], i, it, k, seen = {}, cleared = false;
  if (remSaved > stamp(HIS_STAMP) && !remItems.length) {
    /* 空 + 时间戳更新 = 另一台设备清空过，本地跟着清，否则并集会把删掉的又拉回来 */
    cleared = true;
  } else {
    var all = locItems.concat(remItems);
    for (i = 0; i < all.length; i++) {
      it = all[i];
      if (!it || typeof it !== 'object') continue;
      k = keyOf(it);
      if (!k || seen[k]) continue;
      seen[k] = 1;
      merged.push(it);
    }
    merged.sort(function (a, b) { return (b.createdAt || 0) - (a.createdAt || 0); });
    merged = merged.slice(0, LIMIT);
  }
  var newText = JSON.stringify(merged);
  if (JSON.stringify(locItems) !== newText) lsSet(HIS_KEY, newText);
  /* 两个来源都空时（多半是 localStorage 曾经写爆）不要拿空数组去覆盖 IndexedDB，
     那可能是唯一还留着记录的地方；只有明确「别处清空过」才真清。 */
  if (merged.length || cleared) dbPut(merged);
  var remKeys = {}, needPush = false;
  for (i = 0; i < remItems.length; i++) remKeys[keyOf(remItems[i])] = 1;
  for (i = 0; i < merged.length; i++) {
    if (!remKeys[keyOf(merged[i])]) needPush = true;
    if (merged[i].imageUrl && !isHosted(merged[i].imageUrl)) needPush = true;
  }
  if (needPush) pushHistory(merged);

  /* ---------- 3. 把这个 App 自己的两个键接住 ---------- */
  var rawSet = Storage.prototype.setItem;
  Storage.prototype.setItem = function (k, v) {
    var out = rawSet.apply(this, arguments);
    if (this === localStorage && k === CFG_KEY) {
      try { pushConfig(JSON.parse(v)); } catch (e) {}
    }
    return out;
  };
  var rawDel = Storage.prototype.removeItem;
  Storage.prototype.removeItem = function (k) {
    var out = rawDel.apply(this, arguments);
    if (this === localStorage && k === HIS_KEY) pushHistory([]);
    return out;
  };
  try {
    var rawPut = IDBObjectStore.prototype.put;
    IDBObjectStore.prototype.put = function (value, key) {
      var args = arguments;
      try {
        if (!ours && args.length > 1 && key === HIS_KEY && this.name === DB_STORE &&
            sameDb(this) && Array.isArray(value)) {
          pushHistory(value);
          var out = [], swapped = false;
          for (var j = 0; j < value.length; j++) {
            var c = slim[keyOf(value[j])];
            if (c) swapped = true;
            out.push(c || value[j]);
          }
          return swapped ? rawPut.call(this, out, key) : rawPut.apply(this, args);
        }
      } catch (e) {}
      return rawPut.apply(this, args);
    };
  } catch (e) {}
})();
</script>"""



def _inject_pose_ai_boot(html: str) -> str:
    if '</head>' in html:
        return html.replace('</head>', _POSE_AI_BOOT + '</head>', 1)
    return _POSE_AI_BOOT + html


class _SpaStaticFiles(StaticFiles):
    """静态站 + 前端路由兜底 + 外壳页注入。

    上游 ai-pose-gallery-zh 2.x 是 TanStack Router 的 history 模式（不是 hash），
    /pose-gallery/poses 这种深链在纯 StaticFiles 下会 404。这里把"看起来像路由、
    又没有扩展名"的 404 兜回 index.html，前端路由自己解析。
    """

    async def get_response(self, path, scope):
        try:
            response = await super().get_response(path, scope)
        except StarletteHTTPException as exc:
            leaf = path.rsplit('/', 1)[-1]
            if exc.status_code == 404 and '.' not in leaf and path != 'index.html':
                return self._shell()
            raise
        if str(getattr(response, 'path', '')).endswith('index.html'):
            return self._shell()
        return response

    def _shell(self):
        """外壳页每次都要回源（注入脚本会变，且不能让浏览器缓存旧外壳）。"""
        html = (Path(self.directory) / 'index.html').read_text('utf-8')
        return HTMLResponse(_inject_pose_ai_boot(html), headers={'Cache-Control': 'no-store'})


if os.path.isdir(_POSE_GALLERY_DIR):
    app.mount('/pose-gallery', _SpaStaticFiles(directory=_POSE_GALLERY_DIR, html=True), name='pose-gallery')
    # 上游 2.x 前端把资源写成绝对路径（fetch('/data/pose-zh.json')、src={`/${原图}`}、
    # Vite 产物在 /assets/），放在子路径下必然 404。与其改它的源码（每次升级都要重打补丁），
    # 不如把这四个根路径让给它——本应用自己只用 /static /media /api /apk，不冲突。
    for _prefix in ('assets', 'data', 'img', 'thumbs'):
        app.mount(f'/{_prefix}',
                  StaticFiles(directory=f'{_POSE_GALLERY_DIR}/{_prefix}', check_dir=False),
                  name=f'pose-{_prefix}')


@app.get('/')
def index():
    return FileResponse(db.ROOT / 'static' / 'index.html')


@app.get('/manifest.webmanifest')
def manifest():
    return FileResponse(db.ROOT / 'static' / 'manifest.webmanifest', media_type='application/manifest+json')
