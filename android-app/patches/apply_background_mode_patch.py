# -*- coding: utf-8 -*-
"""中文化 @anuradev/capacitor-background-mode 的前台服务通知（幂等，可在 npm install 后重复执行）。

背景：插件的默认渠道名是英文 "anuradev-capacitor-background-mode"，且 MainActivity
原生启动服务时使用插件默认 settings（不走 JS 传参），故必须改源码默认值。
同时 Android 渠道名创建后不可改，需换新渠道 ID 并删除旧渠道。

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
    ('private String title = "App is on background mode";', 'private String title = "恋爱空间";'),
    ('private String text = "App will start faster";', 'private String text = "正在守护你们的小空间…";'),
    ('private String channelName = "anuradev-capacitor-background-mode";', 'private String channelName = "恋爱空间运行中";'),
    ('private String channelDescription = "Anuradev Capacitor background mode notification";',
     'private String channelDescription = "保持后台连接，让消息提醒及时送达";'),
    ('private String closeTitle = "Close";', 'private String closeTitle = "关闭";'),
])

patch('BackgroundModeService.java', [
    ('''        String OLD_CHANNEL_ID = "anuradev-capacitor-background-mode-id";
        String CHANNEL_ID = "anuradev-capacitor-background-mode-id-v2";''',
     '''        String OLD_CHANNEL_ID = "anuradev-capacitor-background-mode-id";
        String OLD_CHANNEL_ID_V2 = "anuradev-capacitor-background-mode-id-v2";
        String CHANNEL_ID = "lovespace-keepalive-v3";'''),
    ('notificationManager.deleteNotificationChannel(OLD_CHANNEL_ID);',
     '''notificationManager.deleteNotificationChannel(OLD_CHANNEL_ID);
        notificationManager.deleteNotificationChannel(OLD_CHANNEL_ID_V2);'''),
])

print('[patch] 全部完成')
