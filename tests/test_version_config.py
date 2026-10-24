"""版本号一致性。

以前 `/api/status` 里的版本是写死在 main.py 的三段字符串，而 build.gradle 和
git tag 各写各的——发版时容易只改一处。现在改为构建期注入（Dockerfile
build-arg → 环境变量 → app/config.py），这里守住三件事：

1. 没注入时要有能用的默认值，且空字符串不能被当成有效值；
2. `main.py` 真的用了 config 里的值，而不是又写死一份；
3. `/api/status` 报的 APK 版本和 android-app 里真正打包用的 versionName 同号。
"""
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
