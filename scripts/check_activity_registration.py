"""注册层守卫：把「MainActivity 真的被实例化、通道注册真的会执行」变成断言。

## 为什么需要这个脚本

2.8.0 第 0 步 fix0–fix4 四轮真机失败，根因全部落在注册层而不是采集核：
`PeerLocNative.register(...)` 写在 MainActivity 的 `configureFlutterEngine` 里，
而 AndroidManifest 的主 activity 自 2.4.5 起指向 audio_service 插件的
`com.ryanheise.audioservice.AudioServiceActivity` —— App 自己的 MainActivity
从未被实例化，注册代码是死代码，Dart 侧每次调用都拿到
`MissingPluginException: No implementation found for method toggle on channel
peer_loc/native`。

既有测试（peer_loc_verify / peer_toggle_visibility）全程 mock 了
`peer_loc/native` 通道，只能验证协议形状，**测不到接线**。本脚本补的正是
这个洞：三条断言全部落在「产物级事实」上，任何一条不过即退出码 1
（CI 里等于构建失败）。

## 三项断言

A. 源码 manifest：带 MAIN + LAUNCHER 的 activity 必须是本 App 的 MainActivity
B. 源码 MainActivity.kt：继承 AudioServiceActivity（保住 audio_service 的
   媒体前台服务/通知能力），且 `super.configureFlutterEngine(...)` 出现在
   `PeerLocNative.register(...)` 之前（不先调 super 会丢插件的 engine 钩子）
C. 产物 APK：`aapt dump xmltree` 读出的 launcher activity 实名与 A 一致
   —— 防「源码改了、合并清单或打包配置没生效」这类只在真机才暴露的偏差
D. 源码 manifest：fix6 两项权限（FOREGROUND_SERVICE_LOCATION /
   REQUEST_IGNORE_BATTERY_OPTIMIZATIONS）在位
E. 产物：合并清单里若存在 location 型前台服务（type 含 0x8），
   FOREGROUND_SERVICE_LOCATION 必须已声明（Android 14+ 硬要求）

## 用法

    # 构建前：只查源码（不需要 Android SDK）
    python scripts/check_activity_registration.py

    # 构建后：连产物一起查（本机与 CI 双跑）
    python scripts/check_activity_registration.py --apk app-flutter/build/app/outputs/flutter-apk/app-debug.apk

读产物需要 aapt（或 aapt2），从 ANDROID_HOME / ANDROID_SDK_ROOT / PATH
里找 build-tools 最新的一份；给了 --apk 却找不到工具时直接失败，不许静默跳过
——跳过等于把这条守卫变回装饰。
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FLUTTER = ROOT / 'app-flutter'
MANIFEST = FLUTTER / 'android' / 'app' / 'src' / 'main' / 'AndroidManifest.xml'
MAIN_ACTIVITY = (FLUTTER / 'android' / 'app' / 'src' / 'main' / 'kotlin' /
                 'cn' / 'iepose' / 'lovespace' / 'love_space' / 'MainActivity.kt')

EXPECTED_ACTIVITY = 'cn.iepose.lovespace.love_space.MainActivity'
PLUGIN_ACTIVITY = 'com.ryanheise.audioservice.AudioServiceActivity'
NS = '{http://schemas.android.com/apk/res/android}'

_failures = []


def fail(msg):
    _failures.append(msg)
    print(f'  ✗ {msg}')


def info(msg):
    print(f'    {msg}')


def _version_key(name):
    parts = []
    for piece in re.split(r'[.\-]', name):
        parts.append(int(piece) if piece.isdigit() else -1)
    return tuple(parts)


def find_android_tool(*names):
    """按 build-tools 版本从高到低找可执行文件，找不到再退回 PATH。"""
    for env in ('ANDROID_HOME', 'ANDROID_SDK_ROOT'):
        sdk = os.getenv(env)
        if not sdk:
            continue
        tools = Path(sdk) / 'build-tools'
        if not tools.is_dir():
            continue
        for candidate in sorted(tools.iterdir(), key=lambda p: _version_key(p.name),
                                reverse=True):
            for name in names:
                for exe in (name, f'{name}.exe'):
                    path = candidate / exe
                    if path.is_file():
                        return path
    for name in names:
        for exe in (name, f'{name}.exe'):
            found = shutil.which(exe)
            if found:
                return Path(found)
    return None


def launcher_activity_source():
    """A 项：源码 manifest 里 MAIN + LAUNCHER 的 activity 实名。"""
    try:
        tree = ET.parse(MANIFEST)
    except (OSError, ET.ParseError) as exc:
        fail(f'读不了 {MANIFEST}：{exc}')
        return None
    found = []
    for activity in tree.getroot().iter('activity'):
        actions, categories = set(), set()
        for intent in activity.findall('intent-filter'):
            for action in intent.findall('action'):
                actions.add(action.get(f'{NS}name'))
            for category in intent.findall('category'):
                categories.add(category.get(f'{NS}name'))
        if 'android.intent.action.MAIN' in actions and \
                'android.intent.category.LAUNCHER' in categories:
            found.append(activity.get(f'{NS}name'))
    if len(found) != 1:
        fail(f'源码 manifest 里 MAIN+LAUNCHER 的 activity 应恰好 1 个，实际 {len(found)} 个：{found}')
        return None
    return found[0]


def check_source():
    print('\n[A] 源码 manifest：launcher activity 实名')
    name = launcher_activity_source()
    if name is None:
        return
    info(f'launcher activity = {name}')
    if name != EXPECTED_ACTIVITY:
        if name == PLUGIN_ACTIVITY:
            fail(f'launcher 指向 audio_service 插件类（{PLUGIN_ACTIVITY}）——'
                 f'App 自己的 MainActivity 不被实例化，peer_loc/native 通道注册永不执行'
                 f'（fix0–fix4 真机 MissingPluginException 的根因）')
        else:
            fail(f'launcher activity 不是 {EXPECTED_ACTIVITY}：实际 {name}')
    else:
        print('  ✓ launcher 指向自有 MainActivity')

    print('\n[B] 源码 MainActivity.kt：继承 + super 顺序 + 注册调用')
    try:
        kt = MAIN_ACTIVITY.read_text(encoding='utf-8')
    except OSError as exc:
        fail(f'读不了 {MAIN_ACTIVITY}：{exc}')
        return
    if re.search(r'class\s+MainActivity\s*:\s*AudioServiceActivity\s*\(', kt):
        print('  ✓ 继承 AudioServiceActivity（audio_service 能力保留）')
    else:
        fail('MainActivity 未继承 AudioServiceActivity——改为普通 FlutterActivity '
             '会丢 audio_service 的 engine 钩子（媒体前台服务/通知回归）')
    # 必须按「调用」定位，不能按裸字符串：文件头注释里也出现
    # PeerLocNative.register 字样（说明历史根因），裸查找会把注释当成调用点。
    super_match = re.search(r'super\.configureFlutterEngine\s*\(', kt)
    register_match = re.search(r'PeerLocNative\.register\s*\(', kt)
    super_at = super_match.start() if super_match else -1
    register_at = register_match.start() if register_match else -1
    if register_at < 0:
        fail('MainActivity 内没有 PeerLocNative.register 调用——通道不会注册')
    elif super_at < 0:
        fail('MainActivity 未调用 super.configureFlutterEngine——插件的 engine 钩子丢失')
    elif super_at > register_at:
        fail('super.configureFlutterEngine 必须在 PeerLocNative.register 之前调用')
    else:
        print('  ✓ super 在前、PeerLocNative.register 在后')

    print('\n[D] 源码 manifest：fix6 两项权限声明')
    try:
        raw = MANIFEST.read_text(encoding='utf-8')
    except OSError as exc:
        fail(f'读不了 {MANIFEST}：{exc}')
        return
    for perm, why in (
            ('android.permission.FOREGROUND_SERVICE_LOCATION',
             'location 型前台服务（合并清单里的 GeolocatorLocationService）'
             '在 targetSdk 34+ 必须持有该权限'),
            ('android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
             '设置卡「忽略电池优化」入口发送系统意图的前提权限')):
        if perm in raw:
            print(f'  ✓ {perm}')
        else:
            fail(f'缺权限 {perm}——{why}')


def apk_launcher_activity(apk):
    """C 项：产物 APK 内 MAIN+LAUNCHER 的 activity 实名（aapt dump xmltree）。"""
    tool = find_android_tool('aapt', 'aapt2')
    if not tool:
        raise SystemExit('找不到 aapt / aapt2，无法校验产物（设置 ANDROID_HOME 或加入 PATH）')
    if tool.name.lower().startswith('aapt2'):
        cmd = [str(tool), 'dump', 'xmltree', '--file', 'AndroidManifest.xml', str(apk)]
    else:
        cmd = [str(tool), 'dump', 'xmltree', str(apk), 'AndroidManifest.xml']
    out = subprocess.run(cmd, capture_output=True, text=True,
                         encoding='utf-8', errors='replace')
    if out.returncode != 0:
        raise SystemExit(f'{tool.name} 读不了 {apk}：{(out.stderr or out.stdout).strip()[:200]}')
    return tool, out.stdout, _launcher_from_xmltree(out.stdout)


def _launcher_from_xmltree(text):
    """从 xmltree 文本里取 launcher activity 实名。

    activity 的属性行紧跟在 `E: activity` 之后，子节点（intent-filter 等）
    以更深一层的 `E:` 开头；MAIN/LAUNCHER 出现在子节点里，所以判定意图要扫
    整个块，取名字只看子节点之前的那几行。
    """
    blocks, cur = [], None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith('E: activity'):
            cur = []
            blocks.append(cur)
            continue
        if cur is not None:
            cur.append(stripped)
    launchers = []
    for block in blocks:
        name = None
        for ln in block:
            if ln.startswith('E: '):  # 进入子节点，activity 自身属性已读完
                break
            if name is None:
                m = re.search(r':name\(0x[0-9a-fA-F]+\)="([^"]+)"', ln) or \
                    re.search(r':name="([^"]+)"', ln)
                if m:
                    name = m.group(1)
        has_main = any('android.intent.action.MAIN' in ln for ln in block)
        has_launcher = any('android.intent.category.LAUNCHER' in ln for ln in block)
        if has_main and has_launcher:
            launchers.append(name)
    return launchers


def _attr_hex(text, attr):
    """从 `A: android:xxx(0x…)="…"` 或 `A: android:xxx(0x…)=(type 0x11)0x8` 取值。"""
    m = re.search(re.escape(attr) + r'\(0x[0-9a-fA-F]+\)=(?:\(type 0x[0-9a-fA-F]+\))?(.+?)\s*$',
                  text)
    if not m:
        return None
    raw = m.group(1).strip()
    if raw.startswith('"'):
        # 字符串属性行后面还跟 `(Raw: "…")`，只取第一个引号对的内容
        end = raw.find('"', 1)
        return raw[1:end] if end > 0 else raw.strip('"')
    try:
        return int(raw, 16) if raw.lower().startswith('0x') else int(raw)
    except ValueError:
        return None


def declared_permissions(xmltree):
    """从合并清单 xmltree 文本里取 uses-permission 的实名集合。"""
    perms, lines = set(), xmltree.splitlines()
    for i, line in enumerate(lines):
        s = line.strip()
        if not (s.startswith('E: uses-permission')):
            continue
        base = len(line) - len(line.lstrip())
        for follow in lines[i + 1:i + 4]:
            if not follow.strip().startswith('A: '):
                break
            if len(follow) - len(follow.lstrip()) <= base:
                break
            name = _attr_hex(follow.strip(), 'android:name')
            if isinstance(name, str) and name.startswith('android.permission.'):
                perms.add(name)
    return perms


def services_with_fgs_type(xmltree):
    """从合并清单 xmltree 取 (service 实名, foregroundServiceType 整数)。"""
    out, lines = [], xmltree.splitlines()
    for i, line in enumerate(lines):
        s = line.strip()
        if not s.startswith('E: service'):
            continue
        base = len(line) - len(line.lstrip())
        name, fgs = None, None
        for follow in lines[i + 1:i + 6]:
            fs = follow.strip()
            if not fs.startswith('A: '):
                break
            if len(follow) - len(follow.lstrip()) <= base:
                break
            if name is None:
                name = _attr_hex(fs, 'android:name')
            if 'foregroundServiceType' in fs:
                fgs = _attr_hex(fs, 'android:foregroundServiceType')
        out.append((name, fgs if isinstance(fgs, int) else 0))
    return out


def check_artifact(apk_path):
    print(f'\n[C] 产物 APK 内 launcher activity：{apk_path}')
    apk = Path(apk_path)
    if not apk.is_file():
        fail(f'产物不存在：{apk}')
        return
    try:
        tool, raw, launchers = apk_launcher_activity(apk)
    except SystemExit as exc:
        fail(str(exc))
        return
    info(f'工具：{tool}（build-tools {tool.parent.name}）')
    if len(launchers) != 1:
        fail(f'产物里 MAIN+LAUNCHER 的 activity 应恰好 1 个，实际 {len(launchers)} 个：{launchers}')
        return
    info(f'launcher activity（阅读值）= {launchers[0]}')
    if launchers[0] != EXPECTED_ACTIVITY:
        fail(f'产物 launcher activity 与源码不一致：期望 {EXPECTED_ACTIVITY}，实际 {launchers[0]}')
        return
    print('  ✓ 产物 launcher = 自有 MainActivity（通道注册会执行）')

    # 明文要点（回执取证用）：把 launcher 那一行原文打出来
    for line in raw.splitlines():
        if launchers[0] in line:
            info(f'xmltree 原文：{line.strip()}')
            break

    print('\n[E] 产物：location 型前台服务 ↔ FOREGROUND_SERVICE_LOCATION 权限')
    perms = declared_permissions(raw)
    services = services_with_fgs_type(raw)
    info('合并清单 FGS 服务：' + '；'.join(
        f'{name}(type={hex(t) if t else "未声明"})' for name, t in services))
    location_services = [name for name, t in services if t and (t & 0x8)]
    if location_services:
        info('location 型服务：' + '、'.join(str(n) for n in location_services))
        if 'android.permission.FOREGROUND_SERVICE_LOCATION' in perms:
            print('  ✓ 产物已声明 FOREGROUND_SERVICE_LOCATION')
        else:
            fail('产物里有 location 型前台服务，但未声明 '
                 'android.permission.FOREGROUND_SERVICE_LOCATION——'
                 'Android 14+ 启动该服务会抛 SecurityException')
    else:
        print('  ✓ 产物无 location 型前台服务（本轮无需该权限，声明仍在源码层钉住）')


def main():
    parser = argparse.ArgumentParser(
        description='注册层守卫：manifest 实名 + MainActivity 继承/注册 + 产物 aapt 复验')
    parser.add_argument('--apk', help='构建产物路径；给了就连产物一起校验')
    args = parser.parse_args()

    print('注册层守卫（2.8.0 第 0 步 fix5：通道未注册根因防回归）')
    check_source()
    if args.apk:
        check_artifact(args.apk)

    print()
    if _failures:
        print(f'失败 {len(_failures)} 项：')
        for msg in _failures:
            print(f'  - {msg}')
        return 1
    print('全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
