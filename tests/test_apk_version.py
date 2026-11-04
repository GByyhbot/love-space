"""APK 版本校验脚本的判定逻辑。

这里只测纯逻辑（compare_versions / gradle 解析 / UA 一致性）——读 APK 的
versionCode 要 aapt2，CI 的 test job 没有 Android SDK。真正读包的路径由
android.yml 在发版时实跑，那是它该待的地方。

被守护的事故：versionCode 只能升不能降。装过 20261113 之后，任何更小的包
都会被安卓拒绝，用户看到的现象是「点了检查更新，下载完却装不上」。
"""
import importlib.util
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / 'scripts' / 'check_apk_version.py'


@pytest.fixture(scope='module')
def checker():
    spec = importlib.util.spec_from_file_location('check_apk_version', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ---------- 升级合法性 ----------

@pytest.mark.parametrize('base_code,base_name,code,name', [
    (20261113, '1.6.10', 20261114, '1.6.11'),   # 正常升级
    (20261113, '1.6.10', 20261120, '1.7.0'),    # 跨小版本
    (20261113, '1.6.10', 20261114, '1.6.10'),   # 同版本重打包，code 变大
])
def test_valid_upgrade(checker, base_code, base_name, code, name):
    level, _ = checker.compare_versions(base_code, base_name, code, name)
    assert level in ('ok', 'warn'), f'{base_name}({base_code}) → {name}({code}) 应被判为合法'


def test_version_name_changed_but_code_same_is_rejected(checker):
    """改了版本名却忘了递增 versionCode——历史事故的原形。"""
    level, message = checker.compare_versions(20261113, '1.6.10', 20261113, '1.6.11')
    assert level == 'fail'
    assert 'versionCode 没动' in message
    assert 'build.gradle' in message, '报错要告诉人具体改哪个文件'


def test_version_code_regressed_is_rejected(checker):
    """CI 曾用 date +%Y%m%d 生成，比本地手工值小，就是这条。"""
    level, message = checker.compare_versions(20261113, '1.6.10', 20261103, '1.6.11')
    assert level == 'fail'
    assert '拒绝降级' in message


def test_same_version_smaller_code_is_rejected(checker):
    level, _ = checker.compare_versions(20261113, '1.6.10', 20261101, '1.6.10')
    assert level == 'fail'


def test_same_version_same_code_warns_not_fails(checker):
    """同版本重打包是合法操作（例如只改了原生壳配置），只提醒不拦。"""
    level, message = checker.compare_versions(20261113, '1.6.10', 20261113, '1.6.10')
    assert level == 'warn'
    assert '重打包' in message


# ---------- build.gradle 解析 ----------

def test_gradle_version_parses_real_file(checker):
    code, name = checker.gradle_version()
    assert code > 0
    assert name and name[0].isdigit()


def test_gradle_version_survives_comments_and_spacing(checker, tmp_path):
    """真实 build.gradle 里这两个字段前后都有注释，正则不能被注释带偏。"""
    fake = tmp_path / 'build.gradle'
    fake.write_text(
        'android {\n'
        '    defaultConfig {\n'
        '        // versionCode 20260101 这是注释里的旧值\n'
        "        versionCode   20261231\n"
        '        versionName "9.9.9"\n'
        '    }\n'
        '}\n', encoding='utf-8')
    assert checker.gradle_version(fake) == (20261231, '9.9.9')


def test_gradle_version_raises_when_missing(checker, tmp_path):
    fake = tmp_path / 'build.gradle'
    fake.write_text('android { }', encoding='utf-8')
    with pytest.raises(SystemExit):
        checker.gradle_version(fake)


# ---------- 三处同号 ----------
# versionName ↔ UA 同号已由 tests/test_version_config.py 守着（对着仓库里的配置文
# 件断言），这里不重复。下面这条补的是它够不到的地方：**APK 内部的** UA。

def test_baseline_apk_internal_ua_matches_its_version(checker):
    """站内分发包内部的 UA 要和它自己的 versionName 同号。

    /api/status 的 apk_version 是运行时从这个包里扫出来的，
    不同号会让前端把「已经是新版」误判成「还有更新」。
    """
    apk = checker.BASELINE
    if not apk.is_file():
        pytest.skip('仓库里没有站内基线包')
    ua = checker.apk_user_agent(apk)
    if ua is None:
        pytest.skip('基线包里没有 assets/capacitor.config.json')
    aapt2 = checker.find_aapt2()
    if not aapt2:
        pytest.skip('没有 aapt2，读不了基线包版本')
    _, name = checker.apk_version(aapt2, apk)
    assert ua == f'LoveSpaceApp/{name}', f'包内 UA {ua} 与 versionName {name} 不一致'
