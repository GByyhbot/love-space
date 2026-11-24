"""版本号一致性。

以前 `/api/status` 里的版本是写死在 main.py 的三段字符串，而 build.gradle 和
git tag 各写各的——发版时容易只改一处。现在改为构建期注入（Dockerfile
build-arg → 环境变量 → app/config.py），这里守住三件事：

1. 没注入时要有能用的默认值，且空字符串不能被当成有效值；
2. `main.py` 真的用了 config 里的值，而不是又写死一份；
3. `/api/status` 报的 APK 版本和 android-app 里真正打包用的 versionName 同号。
"""
import json
import re
from pathlib import Path

import pytest

from app import config, main

ROOT = Path(__file__).resolve().parents[1]


def test_defaults_when_env_missing(monkeypatch):
    for name in ('LOVE_VERSION', 'LOVE_BUILD', 'LOVE_APK_VERSION'):
        monkeypatch.delenv(name, raising=False)
    assert config._env('LOVE_VERSION', 'dev') == 'dev'
    assert config._env('LOVE_BUILD', 'local') == 'local'


def test_empty_env_falls_back(monkeypatch):
    """compose 里写 ${LOVE_VERSION:-} 会传空串进来，必须回落默认值。"""
    monkeypatch.setenv('LOVE_VERSION', '')
    monkeypatch.setenv('LOVE_BUILD', '   ')
    assert config._env('LOVE_VERSION', 'dev') == 'dev'
    assert config._env('LOVE_BUILD', 'local') == 'local'


def test_env_override(monkeypatch):
    monkeypatch.setenv('LOVE_VERSION', 'v9.9.9')
    monkeypatch.setenv('LOVE_BUILD', 'abc1234-20261024')
    assert config._env('LOVE_VERSION', 'dev') == 'v9.9.9'
    assert config._env('LOVE_BUILD', 'local') == 'abc1234-20261024'


def test_status_reads_config_not_literals(monkeypatch, client_a):
    monkeypatch.setattr(main, 'WEB_VERSION', 'v9.9.9')
    monkeypatch.setattr(main, 'BUILD_ID', 'sha-1234567')
    monkeypatch.setattr(main, 'APK_VERSION', '9.9.9')
    body = client_a.get('/api/status').json()
    assert body['version'] == 'v9.9.9'
    assert body['build'] == 'sha-1234567'
    assert body['apk_version'] == '9.9.9'


def test_no_static_apk_in_repo():
    """2.8.1 治本后的新契约：仓库里不再存放任何 APK。

    旧契约是「/api/status 的 apk_version 必须等于 android-app 里 Capacitor 壳
    打包用的 versionName」——而那条链路早已被 Flutter 取代：壳包 static/lovespace.apk
    长期不更新，把 apk_version 钉死在 1.7.4，/apk/download 一直发旧包。
    现在 APK 只走 GitHub Release（app-v<版本>，由 apk-release.yml 构建），
    apk_version 由构建期注入的 LOVE_APK_VERSION 决定（与 tag 同源，见
    tests/test_notice_281.py::test_apk_version_comes_from_env）。
    """
    assert not (ROOT / 'static' / 'lovespace.apk').exists(), (
        '仓库里又出现了 static/lovespace.apk——它会让 /api/status 的 apk_version '
        '与线上真实版本脱节，且 /apk/download 会绕过 Release 发旧包'
    )


# ---- 版本号必须是纯数字 ---------------------------------------------------
# 以前 CI 用 `git describe --tags --always`，main 上构建出来是 1.2.7-6-g3534f2f。
# 这个带字母后缀的串既上了关于页，又被 App 内"检查更新"拿去跟 APK 版本比对，
# 于是装 1.2.9 的用户会被判成"已是最新版本 v1.2.7-…"。现在一律纯版本号。

@pytest.mark.parametrize('raw,expected', [
    ('1.2.7-6-g3534f2f', '1.2.7'),
    ('v1.3.0', '1.3.0'),
    ('1.2.3-rc1', '1.2.3'),
    ('  1.3.0  ', '1.3.0'),
    ('1.3', '1.3'),
])
def test_clean_version_strips_suffix(raw, expected):
    assert config.clean_version(raw, 'dev') == expected


def test_clean_version_keeps_non_version_default():
    """本地没注入时的 dev / 空串不能被清成空，否则关于页会显示空白。"""
    assert config.clean_version('dev', 'dev') == 'dev'
    assert config.clean_version('', 'dev') == 'dev'
    assert config.clean_version('   ', 'dev') == 'dev'


def test_config_module_cleans_env():
    """即便环境变量还是旧格式（NAS 上的镜像/`.env` 可能是老的），也要吐纯版本号。"""
    assert config.clean_version('1.2.7-6-g3534f2f') == '1.2.7'
    assert config.clean_version('1.3.0+g4e99c90') == '1.3.0'


def test_apk_version_never_has_letters():
    assert re.fullmatch(r'\d+(?:\.\d+){1,2}', config.APK_VERSION), config.APK_VERSION


# ---- UA 标记随 Capacitor 壳一并退役（2.8.1）-----------------------------
# 旧断言是「capacitor.config.json 的 appendUserAgent 必须等于 APK 版本」。
# 那条链路已删除：Flutter 包用原生 UA（LoveSpaceApp/<版本>，见
# app-flutter 的 settings_state.dart），仓库里也不再发布 Capacitor 壳。
# 这里只在**壳配置仍存在于工作副本**时做自洽校验，不再与 APK 版本挂钩。
CAP_CONFIGS = [
    ROOT / 'android-app' / 'capacitor.config.json',
    ROOT / 'android-app' / 'android' / 'app' / 'src' / 'main' / 'assets' / 'capacitor.config.json',
]


@pytest.mark.parametrize('path', CAP_CONFIGS)
def test_capacitor_ua_self_consistent_if_present(path):
    """壳工程若还留着，其 UA 至少要与自身版本自洽；整个目录不在则跳过。"""
    if not path.is_file():
        pytest.skip(f'{path.name} 不在当前工作副本里')
    cfg = json.loads(path.read_text(encoding='utf-8'))
    ua = cfg.get('appendUserAgent') or ''
    assert ua.startswith('LoveSpaceApp/'), f'{path.name} 的 appendUserAgent 异常：{ua!r}'


# ---- HTML 外壳不能被 WebView 启发式缓存 ------------------------------------
# 只有 ETag/Last-Modified 而没有 Cache-Control 时，Android WebView 会按
# "距 Last-Modified 的 10%" 自行决定缓存多久，可能连续几天不回来校验，
# 于是发完版 App 里还在跑旧 index.html + 旧 ?v= 资源。这里钉死 no-store。

def test_html_shell_is_no_store(client_a):
    res = client_a.get('/')
    assert res.status_code == 200
    assert 'no-store' in res.headers.get('cache-control', ''), (
        'index.html 必须带 Cache-Control: no-store，否则 WebView 可能吃旧副本，'
        '刚发布的版本在 App 里看不到'
    )


def test_static_assets_keep_versioned_cache(client_a):
    """静态资源不能跟着变成 no-store，否则每次进页面都要重下 CSS/JS（靠 ?v= 破缓存即可）。"""
    res = client_a.get('/static/app.js')
    assert res.status_code == 200
    assert 'no-store' not in res.headers.get('cache-control', '')
