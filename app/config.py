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
# 全部来自构建期注入（Docker build-arg / compose environment），默认值只在
# 本地 `uvicorn --reload` 这种没有注入的场景下出现。CI 打 tag 时用 git tag
# 填 LOVE_VERSION，/api/status 里的网页版本号就自动跟着走，不需要人手改代码。
#
# APK 版本单独一个变量：App 的发版节奏和网页解耦，但两处必须同号，
# tests/test_version_config.py 会拿这里的值和 android-app 的 build.gradle 对账。
WEB_VERSION = clean_version(_env('LOVE_VERSION', 'dev'), 'dev')
BUILD_ID = _env('LOVE_BUILD', 'local')
APK_VERSION = clean_version(_env('LOVE_APK_VERSION', '1.3.0'), '1.3.0')


def public_origin():
    """对外可访问的 origin，仅当配置了 HTTPS 的 PUBLIC_URL 才有值。

    Web Push 的 VAPID `sub` 必须是可联系的 HTTPS 地址；没有配就用占位邮箱，
    宁可让 push 服务用默认校验，也不要塞一个内网 http 地址进去。
    """
    value = urlparse(os.getenv('PUBLIC_URL', ''))
    return f'{value.scheme}://{value.netloc}' if value.scheme == 'https' and value.netloc else ''
