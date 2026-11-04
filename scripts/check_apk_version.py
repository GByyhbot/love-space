"""APK 版本校验：把 versionCode / versionName / UA 三处同号这件事变成断言。

## 为什么需要这个脚本

安卓的 versionCode 只能升不能降：装过 20261113 之后，任何 versionCode 更小的包
都会被系统直接拒绝，用户看到的现象是「点了检查更新，下载完却装不上」。
这个项目历史上就吃过一次亏——CI 用 `date +%Y%m%d` 生成 versionCode，经常比本地
手工出的包小，于是同一个 tag 下站内 APK 能装、Release 资产装不上。

版本号在本项目里有三个落点，任何一个脱钩都会出问题：
  1. android-app/android/app/build.gradle —— 构建真正读的源
  2. android-app/capacitor.config.json    —— UA 里的 LoveSpaceApp/<版本>，
     远程加载模式下 Capacitor 桥常不注入，前端只能靠它认版本
  3. static/lovespace.apk（站内分发包）    —— 用户实际装到的那个包，/api/status
     的 apk_version 是从它的 assets 里扫出来的

## 检查项

A. build.gradle 的 versionName 与 capacitor 配置里的 UA 同号
B. 站内基线包（static/lovespace.apk）内部的 UA 与它自己的 versionName 同号
   —— 抓「sync_apk 传错包 / UA 忘了同步」
C. build.gradle 相对基线包是合法的升级：
     versionName 变了 → versionCode 必须严格变大
     versionName 没变 → versionCode 允许相等（同版本重打包），但不许变小
D. 给了 --apk 时，产物里的版本必须与 build.gradle 完全一致
   —— 防 gradle 缓存 / sed 没生效导致「源码写 1.6.11、装出来还是 1.6.10」

## 用法

    # 构建前：只比 build.gradle 与站内基线（不需要产物）
    python scripts/check_apk_version.py

    # 构建后：再校验产物
    python scripts/check_apk_version.py --apk android-app/android/app/build/outputs/apk/release/app-release.apk

    # 首次发版、站内还没有基线包时
    python scripts/check_apk_version.py --skip-baseline

读 APK 的 versionCode 需要 aapt2（Android SDK build-tools 里自带），
脚本会自动从 ANDROID_HOME / ANDROID_SDK_ROOT / PATH 里找最新的那份。
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GRADLE = ROOT / 'android-app' / 'android' / 'app' / 'build.gradle'
CAP_CONFIG = ROOT / 'android-app' / 'capacitor.config.json'
BASELINE = ROOT / 'static' / 'lovespace.apk'

_failures = []
_warnings = []


def fail(msg):
    _failures.append(msg)
    print(f'  ✗ {msg}')


def warn(msg):
    _warnings.append(msg)
    print(f'  ! {msg}')


def info(msg):
    print(f'    {msg}')


def _version_key(name):
    """把 36.0.0 这样的目录名变成可比较的元组，避免字符串排序把 9 排到 10 后面。"""
    parts = []
    for piece in re.split(r'[.\-]', name):
        parts.append(int(piece) if piece.isdigit() else -1)
    return tuple(parts)


def find_aapt2():
    """按 build-tools 版本从高到低找 aapt2，找不到就返回 None。"""
    for env in ('ANDROID_HOME', 'ANDROID_SDK_ROOT'):
        sdk = os.getenv(env)
        if not sdk:
            continue
        tools = Path(sdk) / 'build-tools'
        if not tools.is_dir():
            continue
        for candidate in sorted(tools.iterdir(), key=lambda p: _version_key(p.name), reverse=True):
            for exe in ('aapt2', 'aapt2.exe'):
                path = candidate / exe
                if path.is_file():
                    return path
    for exe in ('aapt2', 'aapt2.exe'):
        found = shutil.which(exe)
        if found:
            return Path(found)
    return None


def gradle_version(path=None):
    """从 build.gradle 读 versionCode / versionName。

    必须行首锚定（re.M）：这两行前后常有注释，像 `// versionCode 20260101 旧值`
    这种注释里的数字会被 `\\bversionCode` 直接匹配上，读出来的版本号是错的
    ——而且错得毫不起眼，直到发版才炸。
    """
    text = Path(path or GRADLE).read_text(encoding='utf-8')
    code = re.search(r'^[ \t]*versionCode[ \t]+(\d+)', text, re.M)
    name = re.search(r'^[ \t]*versionName[ \t]+"([^"]+)"', text, re.M)
    if not code or not name:
        raise SystemExit(f'在 {path or GRADLE} 里找不到 versionCode / versionName')
    return int(code.group(1)), name.group(1)


def compare_versions(base_code, base_name, code, name):
    """判断「新版本相对站内基线包」是不是一次合法的升级。

    返回 (level, message)，level ∈ {'ok', 'warn', 'fail'}。
    单独抽出来是因为它是整个脚本唯一真正有判断逻辑的地方，而读 APK 需要 aapt2
    ——CI 的 test job 没装 Android SDK，只有把这些判定变成纯函数才能被测到。
    """
    if name != base_name:
        if code > base_code:
            return 'ok', f'版本升级合法：{base_name}({base_code}) → {name}({code})'
        if code == base_code:
            return 'fail', (
                f'版本名变了（{base_name} → {name}）但 versionCode 没动，都是 {code}。'
                f'发新版必须同时递增 android-app/android/app/build.gradle 里的 versionCode，'
                f'否则同号不同版会让「检查更新」和升级安装都变得不可预期')
        return 'fail', (
            f'versionCode 倒退了：{base_code} → {code}。'
            f'安卓会拒绝降级安装，用户表现为「点了检查更新，下完却装不上」')
    if code < base_code:
        return 'fail', f'同版本号 {name} 的 versionCode 反而变小了：{base_code} → {code}'
    if code == base_code:
        return 'warn', (f'versionName 与 versionCode 都没变（{name}/{code}），'
                        f'确认这是同版本重打包；正式发新功能请同时递增两者')
    return 'ok', f'同版本重打包：{name} 的 versionCode {base_code} → {code}'


def apk_version(aapt2, apk):
    """用 aapt2 dump badging 读 APK 的 versionCode / versionName。"""
    out = subprocess.run([str(aapt2), 'dump', 'badging', str(apk)],
                         capture_output=True, text=True, encoding='utf-8', errors='replace')
    if out.returncode != 0:
        raise SystemExit(f'aapt2 读不了 {apk}：{(out.stderr or out.stdout).strip()[:200]}')
    line = next((ln for ln in out.stdout.splitlines() if ln.startswith('package:')), '')
    code = re.search(r"versionCode='(\d+)'", line)
    name = re.search(r"versionName='([^']*)'", line)
    if not code or not name:
        raise SystemExit(f'{apk} 的 badging 里没有版本信息：{line[:160]}')
    return int(code.group(1)), name.group(1)


def apk_user_agent(apk):
    """从 APK 里掏出 assets/capacitor.config.json 的 appendUserAgent。

    这正是 app/config.py 里 _scan_apk_version() 运行时干的事：
    /api/status 报的 apk_version 就是从这里解出来的。所以它必须和包自己的
    versionName 同号，否则前端「检查更新」会一直以为有新版本。
    """
    try:
        with zipfile.ZipFile(apk) as zf:
            raw = zf.read('assets/capacitor.config.json')
    except (KeyError, zipfile.BadZipFile):
        return None
    try:
        return (json.loads(raw.decode('utf-8')).get('appendUserAgent') or '')
    except (ValueError, AttributeError):
        return None


def check_current():
    """A 项：build.gradle 与 capacitor 源配置同号。"""
    print('\n[1] build.gradle ↔ capacitor UA')
    code, name = gradle_version()
    info(f'build.gradle: versionCode={code} versionName={name}')
    expected = f'LoveSpaceApp/{name}'
    try:
        ua = json.loads(CAP_CONFIG.read_text(encoding='utf-8')).get('appendUserAgent', '')
    except (OSError, ValueError) as exc:
        fail(f'读不了 {CAP_CONFIG}：{exc}')
        return code, name
    info(f'capacitor.config.json: {ua or "(空)"}')
    if ua != expected:
        fail(f'UA 与版本号脱钩：期望 {expected}，实际 {ua or "(空)"}')
    else:
        print('  ✓ UA 与 versionName 同号')
    return code, name


def check_baseline(code, name, strict=False):
    """B + C 项：站内基线包的内部一致性，以及相对它的升级合法性。"""
    print('\n[2] 站内基线包 static/lovespace.apk')
    if not BASELINE.is_file():
        warn('站内还没有基线包，跳过升级合法性检查（首次发版属正常）')
        return
    aapt2 = find_aapt2()
    if not aapt2:
        # 发版流水线里必须严格：找不到 aapt2 就等于整段校验被静默跳过，
        # 而这一段的全部意义就是拦住降级安装。宁可让 job 红，也不能假装通过。
        message = '找不到 aapt2，无法读取基线包版本（设置 ANDROID_HOME 或把它加进 PATH）'
        fail(message) if strict else warn(message)
        return
    base_code, base_name = apk_version(aapt2, BASELINE)
    info(f'基线: versionCode={base_code} versionName={base_name}')

    # B 项：基线包内部的 UA 必须与它自己的版本同号
    ua = apk_user_agent(BASELINE)
    if ua is None:
        warn('基线包里没有 assets/capacitor.config.json，跳过 UA 自检')
    elif ua != f'LoveSpaceApp/{base_name}':
        fail(f'基线包内部 UA 与它自己的 versionName 脱钩：包内 {ua}，versionName {base_name}'
             f'（/api/status 的 apk_version 会一直报错版本）')
    else:
        print('  ✓ 基线包内部 UA 自洽')

    # C 项：升级合法性（判定逻辑在 compare_versions，这里只负责报告）
    level, message = compare_versions(base_code, base_name, code, name)
    if level == 'fail':
        fail(message)
    elif level == 'warn':
        warn(message)
    else:
        print(f'  ✓ {message}')


def check_artifact(path):
    """D 项：构建产物必须与 build.gradle 完全一致。"""
    print(f'\n[3] 构建产物 {path}')
    if not Path(path).is_file():
        fail(f'产物不存在：{path}')
        return
    aapt2 = find_aapt2()
    if not aapt2:
        fail('找不到 aapt2，无法校验产物（设置 ANDROID_HOME 或把它加进 PATH）')
        return
    try:
        got_code, got_name = apk_version(aapt2, path)
    except SystemExit as exc:
        fail(str(exc))
        return
    want_code, want_name = gradle_version()
    info(f'产物: versionCode={got_code} versionName={got_name}')
    info(f'源码: versionCode={want_code} versionName={want_name}')
    if (got_code, got_name) != (want_code, want_name):
        fail('产物版本与 build.gradle 不一致——gradle 缓存或按 tag 覆盖没生效，'
             '装出来的还是旧版本')
    else:
        print('  ✓ 产物与源码同号')

    ua = apk_user_agent(path)
    if ua and ua != f'LoveSpaceApp/{got_name}':
        fail(f'产物内部 UA 与 versionName 脱钩：包内 {ua}，versionName {got_name}')
    elif ua:
        print('  ✓ 产物内部 UA 自洽')


def main():
    parser = argparse.ArgumentParser(description='APK versionCode / versionName / UA 一致性校验')
    parser.add_argument('--apk', help='构建产物路径；给了就额外校验产物与源码同号')
    parser.add_argument('--skip-baseline', action='store_true',
                        help='跳过站内基线包比较（首次发版、基线还没建立时用）')
    parser.add_argument('--strict', action='store_true',
                        help='缺少 aapt2 时直接失败，而不是降级成告警（发版流水线用）')
    args = parser.parse_args()

    print('APK 版本校验')
    code, name = check_current()
    if not args.skip_baseline:
        check_baseline(code, name, strict=args.strict)
    if args.apk:
        check_artifact(args.apk)

    print()
    if _failures:
        print(f'失败 {len(_failures)} 项：')
        for msg in _failures:
            print(f'  - {msg}')
        return 1
    if _warnings:
        print(f'通过，但有 {len(_warnings)} 条提醒')
    else:
        print('全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
