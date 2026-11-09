# -*- coding: utf-8 -*-
"""中文化 @anuradev/capacitor-background-mode 的前台服务通知（幂等，可在 npm install 后重复执行）。

背景：插件的默认渠道名是英文 "anuradev-capacitor-background-mode"，且 MainActivity
原生启动服务时使用插件默认 settings（不走 JS 传参），故必须改源码默认值。

适配版本：8.1.0 —— 默认值改成了 BackgroundModeSettings 里的 `public static final
String DEFAULT_*` 常量（7.x 是字段初始化），渠道 ID 升到静态常量 `-id-v3`。
渠道 ID 本身不用再换：默认渠道名来自 settings（已被改成中文），新建渠道即是中文名；
这里只负责把历史版本遗留的渠道（-id / -id-v2 / lovespace-keepalive-v3）删掉。

用法：python patches/apply_background_mode_patch.py
"""
import io
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, 'node_modules', '@anuradev', 'capacitor-background-mode',
                   'android', 'src', 'main', 'java', 'ar', 'com', 'anura', 'plugins', 'backgroundmode')


def patch(path, pairs):
    full = os.path.join(PKG, path)
    with io.open(full, encoding='utf-8') as f:
        src = f.read()
    changed = 0
    for old, new in pairs:
        if new in src:
            continue  # 已应用（幂等）
        if old not in src:
            raise SystemExit(f'[patch] 未找到目标文本: {path}: {old[:60]}...')
        src = src.replace(old, new)
        changed += 1
    with io.open(full, 'w', encoding='utf-8') as f:
        f.write(src)
    print(f'[patch] {path}: {changed} 处修改')


patch('BackgroundModeSettings.java', [
    ('public static final String DEFAULT_TITLE = "App is on background mode";',
     'public static final String DEFAULT_TITLE = "恋爱空间";'),
    ('public static final String DEFAULT_TEXT = "App will start faster";',
     'public static final String DEFAULT_TEXT = "正在守护你们的小空间…";'),
    ('public static final String DEFAULT_CHANNEL_NAME = "anuradev-capacitor-background-mode";',
     'public static final String DEFAULT_CHANNEL_NAME = "恋爱空间运行中";'),
    ('public static final String DEFAULT_CHANNEL_DESCRIPTION = "Anuradev Capacitor background mode notification";',
     'public static final String DEFAULT_CHANNEL_DESCRIPTION = "保持后台连接，让消息提醒及时送达";'),
])

patch('BackgroundModeService.java', [
    # 7.0.2 时代（旧补丁把渠道 ID 改成了 lovespace-keepalive-v3）与更早版本的遗留渠道，
    # 升级后不会再被使用，删掉避免设置页里堆一排死渠道
    ('notificationManager.deleteNotificationChannel(OLD_CHANNEL_ID);',
     '''notificationManager.deleteNotificationChannel(OLD_CHANNEL_ID);
        notificationManager.deleteNotificationChannel("anuradev-capacitor-background-mode-id-v2");
        notificationManager.deleteNotificationChannel("lovespace-keepalive-v3");'''),
])

print('[patch] 全部完成')
