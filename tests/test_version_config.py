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
GRADLE = ROOT / 'android-app' / 'android' / 'app' / 'build.gradle'


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


@pytest.mark.skipif(not GRADLE.is_file(), reason='android-app 不在当前工作副本里')
def test_apk_version_matches_gradle():
    text = GRADLE.read_text(encoding='utf-8')
    found = re.search(r'versionName\s+"([^"]+)"', text)
    assert found, 'build.gradle 里没找到 versionName'
    assert found.group(1) == config.APK_VERSION, (
        f'android-app 打出来的 APK 是 {found.group(1)}，但 /api/status 报的是 '
        f'{config.APK_VERSION}（app/config.py 的默认值或 LOVE_APK_VERSION）——'
        '两者不同号，客户端"检查更新"会一直提示有新版本'
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


# ---- UA 标记必须和 APK 版本同号 -------------------------------------------
# APK 是远程加载模式，Capacitor 的桥接脚本不保证注入，网页端靠 UA 里的
# `LoveSpaceApp/<版本>` 判断「我在 App 里」并读出版本号。这条标记写死在
# capacitor.config.json 里，忘了跟着 versionName 一起改，App 就会误判
# 自己是不是最新版（正是「装 1.2.9 却说已是最新」那个 bug 的来源之一）。

CAP_CONFIGS = [
    ROOT / 'android-app' / 'capacitor.config.json',
    ROOT / 'android-app' / 'android' / 'app' / 'src' / 'main' / 'assets' / 'capacitor.config.json',
]


@pytest.mark.parametrize('path', CAP_CONFIGS)
def test_append_user_agent_matches_apk_version(path):
    if not path.is_file():
        pytest.skip(f'{path.name} 不在当前工作副本里')
    cfg = json.loads(path.read_text(encoding='utf-8'))
    ua = cfg.get('appendUserAgent') or ''
    assert ua == f'LoveSpaceApp/{config.APK_VERSION}', (
        f'{path.parent.name}/{path.name} 里 appendUserAgent 是 {ua!r}，'
        f'但 APK 版本是 {config.APK_VERSION}——两者不同号，App 内「检查更新」会误判版本'
    )
