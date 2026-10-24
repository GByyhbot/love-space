"""生成 capacitor-assets 源图：assets/icon.png 1024 + splash.png 2732（粉底居中 logo）。"""
import os
from playwright.sync_api import sync_playwright

EXE = r'C:/Users/Administrator/.agent-browser/browsers/chrome-154.0.8037.92/chrome.exe'
ROOT = r'D:/android-build/lovespace-apk'
SVG = open(r'D:/恋爱空间/static/icon.svg', encoding='utf-8').read()
BG = '#FCF8F9'

JOBS = [
    ('assets/icon.png', 1024, 1024),      # 全幅 logo
    ('assets/splash.png', 2732, 640),     # 粉底 + 居中 640px logo
]

with sync_playwright() as p:
    browser = p.chromium.launch(executable_path=EXE, headless=True)
    for rel, size, logo in JOBS:
        html = (f'<body style="margin:0;background:{BG};width:{size}px;height:{size}px;'
                f'display:flex;align-items:center;justify-content:center">'
                f'<div style="width:{logo}px;height:{logo}px">{SVG}</div>')
        page = browser.new_page(viewport={'width': size, 'height': size}, device_scale_factor=1)
        page.set_content(html)
        page.wait_for_timeout(200)
        out = os.path.join(ROOT, rel)
        page.screenshot(path=out)
        page.close()
        print('生成', rel, f'{size}x{size}')
    browser.close()

# 副本：icon-only.png、splash-dark.png（防暗色模式黑底启动图）
import shutil
shutil.copy(os.path.join(ROOT, 'assets/icon.png'), os.path.join(ROOT, 'assets/icon-only.png'))
shutil.copy(os.path.join(ROOT, 'assets/splash.png'), os.path.join(ROOT, 'assets/splash-dark.png'))
print('副本完成: icon-only.png, splash-dark.png')
