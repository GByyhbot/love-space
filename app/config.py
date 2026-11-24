"""与环境相关的纯函数。

单独开一个模块同样是为了打破循环导入：webpush.py 需要 public_origin，
而 main.py 又 import 了 webpush——以前靠函数内 `from .main import ...` 把环藏起来。
这里不 import 任何 app 内部模块，谁都能安全引用。
"""
import os
import re
from urllib.parse import urlparse


def _env(name, default):
    """读环境变量，空字符串视为未设置。

    compose 里写 `LOVE_VERSION: ${LOVE_VERSION:-}` 会传进来一个空串，
    这种"设置了但为空"必须回落到默认值，否则版本号会显示成空白。
    """
    return (os.getenv(name) or '').strip() or default


_VERSION_RE = re.compile(r'v?(\d+(?:\.\d+)*)')


def clean_version(raw, default='dev'):
    """只保留纯版本号：`v1.2.7-6-g3534f2f` → `1.2.7`。

    历史包袱：CI 曾用 `git describe --tags --always` 生成带后缀的版本串，
    关于页会显示成 `v1.2.7-6-g3534f2f`，App 内「检查更新」拿它跟 APK 版本
    比对也容易串味。现在版本号一律纯数字三段式，构建身份交给 BUILD_ID
    （sha-日期）表达；这里兜一道，即便环境变量还是旧格式也不会漏出去。
    """
    text = (raw or '').strip()
    match = _VERSION_RE.match(text)
    if match:
        return match.group(1)
    return text or default


# ---- 版本信息 ----------------------------------------------------------------
# 网页版本全部来自构建期注入（Docker build-arg / compose environment），默认值只在
# 本地 `uvicorn --reload` 这种没有注入的场景下出现。CI 打 tag 时用 git tag
# 填 LOVE_VERSION，/api/status 里的网页版本号就自动跟着走，不需要人手改代码。
WEB_VERSION = clean_version(_env('LOVE_VERSION', 'dev'), 'dev')
BUILD_ID = _env('LOVE_BUILD', 'local')


# APK 版本（2.8.1 治本，机主 2026-11-24 22:38 拍板）：
# **以构建期注入的 LOVE_APK_VERSION 为准**——它由 CI 按 git tag 注入，与
# /api/status 的 version 同源，天然不会停在旧值。
#
# 旧实现是运行时扫 static/*.apk 的 `assets/capacitor.config.json` 找
# `LoveSpaceApp/<ver>` 标记。Capacitor 壳早已被 Flutter 取代，Flutter 包里
# 根本没有这个文件 → 扫描恒失败，APK_VERSION 长期停在旧包残留的 1.7.4，
# 与线上真实版本脱节。/apk/download 也因此一直下发 43MB 的旧壳包。
# 该扫描逻辑已整体删除；本地开发没注入环境变量时给 '0.0.0'（明确表示未知，
# 不再假装是某个历史版本）。
def _apk_version():
    return clean_version(_env('LOVE_APK_VERSION', ''), '0.0.0')


APK_VERSION = _apk_version()


# 内外网可达的线路。以前这份清单分别硬编码在前端 app.js 和安卓
# MainActivity 里，改一条要改三处、还容易漏；现在服务端持有权威版本：
#   ① CSP 的 connect-src 直接由它生成 —— 少了任何一个 origin，浏览器
#      发起的跨域探测都会被 CSP 挡掉，页面就会显示「只有本网址可达」；
#   ② /api/routes 把它发给前端，前端不再自己抄一份。
# 顺序有意义：index 0 是安卓的默认入口，公网 HTTPS 必须排最前。
# 末尾的「内网直连」是明文纯 IP，只在家里局域网可用；浏览器从 HTTPS 页面
# 探测它会被 mixed-content 拦成不可达（正常），App 原生探测支持 http 才能测到。
SPACE_ROUTES = (
    ('Cloudflare 隧道', 'https://love.yangyuhui.xyz/'),
    ('节点小宝', 'https://love-space.iepose.cn/'),
    ('腾讯云 CloudBase', 'https://love.350921.xyz/'),
    ('Lucky 直连', 'https://love-space.yangyuhui.xyz:4019/'),
    ('内网直连', 'http://192.168.31.95:1314/'),
)


def route_origins():
    """线路清单里的全部 origin（去重、去尾斜杠），供 CSP connect-src 使用。"""
    seen = []
    for _name, url in SPACE_ROUTES:
        parsed = urlparse(url)
        origin = f'{parsed.scheme}://{parsed.netloc}'
        if parsed.scheme in ('http', 'https') and parsed.netloc and origin not in seen:
            seen.append(origin)
    return seen


def public_origin():
    """对外可访问的 origin，仅当配置了 HTTPS 的 PUBLIC_URL 才有值。

    Web Push 的 VAPID `sub` 必须是可联系的 HTTPS 地址；没有配就用占位邮箱，
    宁可让 push 服务用默认校验，也不要塞一个内网 http 地址进去。
    """
    value = urlparse(os.getenv('PUBLIC_URL', ''))
    return f'{value.scheme}://{value.netloc}' if value.scheme == 'https' and value.netloc else ''
