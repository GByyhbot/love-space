import asyncio
import contextlib
import datetime as dt
import io
import json
import logging
import os
import re
import secrets
import shutil
import threading
import zipfile
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import urlparse
from zoneinfo import ZoneInfo

from fastapi import Depends, FastAPI, File, Form, HTTPException, Request, Response, UploadFile
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from PIL import Image
from pydantic import BaseModel, Field
from starlette.middleware.gzip import GZipMiddleware

from . import db
from . import importers
from .config import APK_VERSION, BUILD_ID, WEB_VERSION
from .serializers import serialize, serialize_many
from . import webpush as webpush_service
from .db import connect, dumps, now, uid
from .security import PURPOSE_CHANNEL_CONFIG, cipher, current_user, digest_token, login_session, open_sealed, password_hash, password_ok, personal_wish_decrypt, personal_wish_encrypt, rate_limit, seal_for_owner


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


def origin_allowed(origin: str, request: Request) -> bool:
    allowed = os.getenv('PUBLIC_URL', '').rstrip('/')
    public_host = urlparse(allowed).hostname if allowed else None
    forwarded = request.headers.get('x-forwarded-host') or request.headers.get('host', '')
    req_host = urlparse('//' + forwarded.split(',')[0].strip()).hostname
    # 内网穿透/反代（节点小宝）会改写 Origin；只要请求本身是经公网域名进来的
    #（Host / X-Forwarded-Host 命中公网主机），即视为同源，不再死磕被改写的 Origin
    if public_host and req_host and req_host.lower() == public_host.lower():
        return True
    if not origin:
        return True
    origin_host = urlparse(origin).hostname
    if public_host and origin_host and origin_host.lower() == public_host.lower():
        return True
    if req_host and origin_host and origin_host.lower() == req_host.lower():
        return True
    return False


@app.middleware('http')
async def protection(request, call_next):
    public_url = os.getenv('PUBLIC_URL', '').rstrip('/')
    if public_url.startswith('https://') and request.url.path != '/health':
        public_host = urlparse(public_url).hostname
        forwarded_host = request.headers.get('x-forwarded-host') or request.headers.get('host', '')
        request_host = urlparse('//' + forwarded_host.split(',')[0].strip()).hostname
        origin = request.headers.get('origin', '')
        origin_host = urlparse(origin).hostname if origin else None
        forwarded_proto = request.headers.get('x-forwarded-proto', '').split(',')[0].strip().lower()
        is_public_host = public_host and (
            any(host and host.lower() == public_host.lower() for host in (request_host, origin_host))
            or forwarded_proto == 'https' or request.url.scheme == 'https')
        if public_host and not is_public_host:
            if request.method in {'GET', 'HEAD'}:
                return RedirectResponse(public_url + request.url.path + (('?' + request.url.query) if request.url.query else ''), status_code=308)
            return JSONResponse({'detail': '请通过 HTTPS 域名访问恋爱空间'}, status_code=403)
    if request.method in {'POST', 'PUT', 'PATCH', 'DELETE'}:
        if request.headers.get('X-Love-Space') != '1':
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
    result.headers['X-Frame-Options'] = 'DENY'
    if request.url.path == '/static/sw.js':
        result.headers['Service-Worker-Allowed'] = '/'
    push_origin = urlparse(ntfy_server_url())
    push_host = push_origin.hostname or 'ntfy.350921.xyz'
    if ':' in push_host and not push_host.startswith('['):
        push_host = '[' + push_host + ']'
    push_port = f':{push_origin.port}' if push_origin.port and push_origin.port != 443 else ''
    connect_src = f"connect-src 'self' https://{push_host}{push_port} wss://{push_host}{push_port}"
    result.headers['Content-Security-Policy'] = f"default-src 'self'; img-src 'self' blob: data:; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; script-src 'self'; {connect_src}; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
    if public_url.startswith('https://'):
        result.headers['Strict-Transport-Security'] = 'max-age=31536000'
    if request.url.path.startswith(('/api/', '/media/')):
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


@app.get('/api/status')
def status():
    with connect() as c:
        count = c.execute('SELECT count(*) FROM users').fetchone()[0]
    return {'initialized': count > 0, 'paired': count == 2, 'setup_token_required': bool(os.getenv('SETUP_TOKEN')),
            'version': WEB_VERSION, 'build': BUILD_ID,
            'apk_version': APK_VERSION, 'apk_url': '/static/lovespace.apk'}


@app.get('/health')
def health():
    with connect() as c:
        c.execute('SELECT 1')
    return {'status': 'ok'}


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
        login_session(c, user_id, response)
    return {'ok': True}


@app.post('/api/login')
def login(body: Credentials, request: Request, response: Response):
    rate_limit(request, 'login')
    with connect() as c:
        row = c.execute('SELECT * FROM users WHERE username=?', (body.username.lower(),)).fetchone()
        if not row or not password_ok(body.password, row['password']):
            raise HTTPException(401, '账号或密码不正确')
        login_session(c, row['id'], response)
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
        login_session(c, user_id, response)
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


class Space(BaseModel):
    name: str = Field(min_length=1, max_length=60)
    since: str = ''
    cover: str = ''
    theme: str = 'rose'
    custom_color: str = Field(default='', max_length=7)
    motion: bool = True
    timezone: str = 'Asia/Shanghai'
    # 聊天壁纸。None 表示"客户端没带这个字段"（旧版前端/旧 APK 保存空间设置时），
    # 此时沿用库里的原值——否则旧客户端一保存就把壁纸清空了。
    chat_bg: str | None = Field(default=None, max_length=20)
    chat_bg_media: str | None = Field(default=None, max_length=64)
    chat_bg_dim: int | None = None


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
                 'start', 'cycle', 'length', 'flow', 'symptoms', 'shared'}
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
        # 生理期只收窄口字段：一天一条，start 是这次经期的第一天。
        # cycle/length 允许用户手工改（默认由历史自动推算），但必须落在生理上说得通的区间，
        # 否则日历和预测会画出不可能的格子。
        for key in ('cycle', 'length'):
            if body.get(key) in (None, ''):
                body.pop(key, None)
                continue
            if type(body[key]) is not int or not (15 <= body[key] <= 60 if key == 'cycle' else 1 <= body[key] <= 15):
                raise HTTPException(422, '周期需在 15–60 天、经期需在 1–15 天之间')
        if 'shared' in body and not isinstance(body['shared'], bool):
            raise HTTPException(422, '共享状态格式不正确')
        # 生理期默认双人公开可见：另一半提前知道，才谈得上照顾。
        # 想留私密就在表单里取消勾选（传 shared:false），或用 /api/period/share 一次性收回。
        body.setdefault('shared', True)
        if 'flow' in body and body['flow'] not in ('少', '中', '多'):
            raise HTTPException(422, '经量只能选 少 / 中 / 多')
        symptoms = body.get('symptoms')
        if symptoms is not None:
            if not isinstance(symptoms, list) or len(symptoms) > 12 \
                    or any(not isinstance(s, str) or not s.strip() or len(s) > 16 for s in symptoms):
                raise HTTPException(422, '症状最多十二项，每项不超过十六个字')
            body['symptoms'] = list(dict.fromkeys(s.strip() for s in symptoms if s.strip()))
    for key in ('date', 'target', 'start'):
        if body.get(key):
            try:
                dt.date.fromisoformat(body[key])
            except ValueError:
                raise HTTPException(422, '日期格式不正确')
    if kind == 'anniversary' and not body.get('date'):
        raise HTTPException(422, '请选择纪念日日期')
    if kind == 'period' and not body.get('start'):
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
    return result


@app.post('/api/records')
def create_record(body: RecordInput, user=Depends(current_user)):
    with connect() as c:
        c.execute('BEGIN IMMEDIATE')
        if body.client_id:
            existing = c.execute('SELECT * FROM records WHERE author=? AND client_id=?', (user['id'], body.client_id)).fetchone()
            if existing:
                return serialize(c, existing, user['id'])
        cleaned = clean_body(c, body.kind, body.body, user['id'])
        rid = uid()
        timestamp = now()
        c.execute('INSERT INTO records VALUES (?,?,?,?,?,?,NULL,?,?)',
                  (rid, body.kind, user['id'], db.body_encode(body.kind, rid, cleaned), timestamp, timestamp,
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
        return serialize(c, get_record(c, rid, user), user['id'])


@app.put('/api/records/{rid}')
def update_record(rid: str, body: RecordInput, user=Depends(current_user)):
    with connect() as c:
        # 先读后写（读记录 → 读其他记录判断附件引用 → 写）：不先拿写锁，
        # 锁升级时会直接 SQLITE_BUSY 而不是等待
        c.execute('BEGIN IMMEDIATE')
        row = get_record(c, rid, user, True)
        if body.kind != row['kind'] and not (row['kind'] == 'draft' and body.kind in {'post', 'diary', 'surprise'}):
            raise HTTPException(422, '已发布内容不能改变可见范围，请另建记录')
        old_body = db.body_decode(row)
        cleaned = clean_body(c, body.kind, body.body, user['id'], old_body)
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


class PeriodShareInput(BaseModel):
    shared: bool = True


@app.post('/api/period/share')
def period_share_all(body: PeriodShareInput, user=Depends(current_user)):
    """把自己所有生理期记录一次性设为「双人公开可见」或收回为「仅自己可见」。

    新建时默认就是共享（见 clean_body），这个接口处理两件事：
    一是把历史记录（早期版本默认私有）一次性补成公开，二是随时整体收回。
    只动 author=自己的记录；单条仍可在记录菜单里单独切换。
    """
    with connect() as c:
        c.execute('BEGIN IMMEDIATE')
        rows = c.execute("SELECT * FROM records WHERE kind='period' AND author=? AND deleted IS NULL",
                         (user['id'],)).fetchall()
        changed = 0
        for row in rows:
            data = db.body_decode(row)
            if bool(data.get('shared')) == body.shared:
                continue
            data['shared'] = body.shared
            # period 是 ENCRYPTED 类型，重新编码才会写回密文
            c.execute('UPDATE records SET body=?,updated=? WHERE id=?',
                      (db.body_encode('period', row['id'], data), now(), row['id']))
            changed += 1
        return {'ok': True, 'changed': changed, 'total': len(rows), 'shared': body.shared}


@app.delete('/api/records/{rid}')
def delete_record(rid: str, user=Depends(current_user)):
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
        previous = ''
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
            if signature != previous:
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
            'highlights': highlights, 'message': message}


@app.get('/api/yearbook')
def yearbook(year: int = 0, user=Depends(current_user)):
    """小年报：指定年份的统计聚合，默认取当前年。"""
    with connect() as c:
        space = db.setting(c, 'space')
    tz_name = (space or {}).get('timezone', 'Asia/Shanghai')
    current_year = dt.datetime.now(ZoneInfo(tz_name)).year
    y = year or current_year
    with connect() as c:
        rows = [serialize(c, r, user['id']) for r in c.execute('SELECT * FROM records ORDER BY created')
                if db.visible(r, user['id']) and r['kind'] not in {'chat', 'album'}]
    in_year = [r for r in rows if (r['body'].get('date') or '')[:4] == str(y)]
    by_kind = {}
    photos = 0
    for r in in_year:
        by_kind[r['kind']] = by_kind.get(r['kind'], 0) + 1
        photos += len([m for m in r.get('media', []) if m['mime'].startswith('image/')])
    # 最常互动、最长连续打卡等高级统计暂不做，先给基础数据
    return {'year': y, 'is_current': y == current_year,
            'total': len(in_year), 'by_kind': by_kind, 'photos': photos,
            'moods': sum(1 for r in in_year if r['kind'] == 'mood'),
            'wishes_done': sum(1 for r in in_year if r['kind'] == 'wish' and r['body'].get('done')),
            'anniversaries': sum(1 for r in in_year if r['kind'] == 'anniversary')}


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
EVENTS = {'chat', 'comment', 'note', 'activity', 'anniversary', 'wish', 'surprise', 'backup', 'storage', 'system'}


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
    backups_size = sum(p.stat().st_size for p in (db.DATA / 'backups').glob('*.zip')) if (db.DATA / 'backups').is_dir() else 0
    with connect() as c:
        record_count = c.execute('SELECT count(*) FROM records WHERE deleted IS NULL').fetchone()[0]
        media_count = c.execute('SELECT count(*) FROM media').fetchone()[0]
    return {'total': sum(by_kind.values()) + db_size + wal_size + backups_size,
            'media_by_kind': by_kind, 'media_by_month': dict(sorted(by_month.items())[-12:]),
            'db': db_size + wal_size, 'backups': backups_size,
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


@app.get('/')
def index():
    return FileResponse(db.ROOT / 'static' / 'index.html')


@app.get('/manifest.webmanifest')
def manifest():
    return FileResponse(db.ROOT / 'static' / 'manifest.webmanifest', media_type='application/manifest+json')
