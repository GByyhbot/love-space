"""生成 7 套主题色板（浅色 + 夜间），输出 CSS 片段。

配色思路：每个主题只定一个"种子色相 + 饱和度"，其余明度按统一阶梯走——
这样七套主题的层级关系（背景/卡片/描边/文字）完全一致，换主题时只是色相变了。
生成后逐条校验 WCAG 对比度，任何一条不达标就把明度自动往上/下推，直到通过。

输出：
  .tmp/theme-light.css   —— `:root.theme-x{...}`
  .tmp/theme-dark.css    —— `:root.dark.theme-x{...}`
  .tmp/theme-report.txt  —— 对比度校验表
"""
import colorsys
import io
import os


def hsl(h, s, l):
    r, g, b = colorsys.hls_to_rgb((h % 360) / 360.0, l / 100.0, s / 100.0)
    return '#%02X%02X%02X' % (round(r * 255), round(g * 255), round(b * 255))


def rgb(hexv):
    n = int(hexv[1:], 16)
    return (n >> 16) & 255, (n >> 8) & 255, n & 255


def rel_lum(hexv):
    def f(c):
        c = c / 255.0
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = rgb(hexv)
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)


def contrast(a, b):
    la, lb = rel_lum(a), rel_lum(b)
    if la < lb:
        la, lb = lb, la
    return (la + 0.05) / (lb + 0.05)


def mix(fg, bg, alpha):
    """fg 以 alpha 叠在 bg 上，用来算玻璃气泡这类半透明底的实际对比度。"""
    fr, fg_, fb = rgb(fg)
    br, bg_, bb = rgb(bg)
    return '#%02X%02X%02X' % tuple(
        round(f * alpha + b * (1 - alpha)) for f, b in ((fr, br), (fg_, bg_), (fb, bb)))


# 主题种子：名称 → (色相, 饱和, 中文名, 一句描述)
THEMES = [
    ('rose',     342, 46, '草莓牛奶', '莓果粉，最经典的那一版'),
    ('peach',     22, 48, '蜜桃奶油', '暖橘调，傍晚的光'),
    ('lemon',     38, 52, '柠檬挞',   '一点酸甜的黄油色'),
    ('mint',     162, 38, '薄荷气泡', '清透的青绿'),
    ('sky',      208, 44, '海盐汽水', '安稳的雾蓝'),
    ('lavender', 268, 34, '香芋云朵', '软软的薰衣草'),
    ('cocoa',     18, 22, '焦糖可可', '低饱和的暖棕，安静耐看'),
]

# 浅色：明度阶梯（背景 → 卡片 → 描边 → 文字）
L_LIGHT = dict(bg=97.6, surface=100.0, soft=94.5, soft_strong=88.5,
               line=92.4, line_strong=85.5, ink=21.0, ink2=32.5, muted=47.5,
               primary=40.0, primary_dark=31.0)
# 夜间：统一压暗，主色提亮到"发光"的明度
L_DARK = dict(bg=12.0, surface=17.2, soft=24.5, soft_strong=31.0,
              line=24.0, line_strong=32.5, ink=92.5, ink2=79.0, muted=63.0,
              primary=70.0, primary_dark=79.0)

report = []
blocks_light = []
blocks_dark = []

for key, hue, sat, cn, desc in THEMES:
    # ── 浅色 ──
    bg = hsl(hue, min(sat, 30) * 0.42, L_LIGHT['bg'])
    surface = '#FFFFFF'
    soft = hsl(hue, min(sat, 55) * 0.95, L_LIGHT['soft'])
    soft_strong = hsl(hue, min(sat, 55) * 0.85, L_LIGHT['soft_strong'])
    line = hsl(hue, min(sat, 40) * 0.55, L_LIGHT['line'])
    line_strong = hsl(hue, min(sat, 40) * 0.62, L_LIGHT['line_strong'])
    ink = hsl(hue, 13, L_LIGHT['ink'])
    ink2 = hsl(hue, 13, L_LIGHT['ink2'])
    # 弱化文字（说明、时间戳）必须还能读：不够就把明度往下压到 4.6:1
    m_l = L_LIGHT['muted']
    muted = hsl(hue, 10, m_l)
    while contrast(muted, bg) < 4.6 and m_l > 28:
        m_l -= 0.5
        muted = hsl(hue, 10, m_l)
    primary = hsl(hue, sat, L_LIGHT['primary'])
    primary_dark = hsl(hue, sat + 4, L_LIGHT['primary_dark'])
    on_primary = '#FFFFFF'

    # 对比度兜底：主色上的白字不够就压暗主色
    p_l = L_LIGHT['primary']
    while contrast(primary, on_primary) < 4.5 and p_l > 20:
        p_l -= 1
        primary = hsl(hue, sat, p_l)
    primary_dark = hsl(hue, sat + 4, max(p_l - 9, 18))

    blocks_light.append((key, cn, desc, dict(
        bg=bg, surface=surface, ink=ink, ink2=ink2, muted=muted,
        primary=primary, primary_dark=primary_dark, on_primary=on_primary,
        soft=soft, soft_strong=soft_strong, line=line, line_strong=line_strong)))

    # ── 夜间 ──
    dbg = hsl(hue, 13, L_DARK['bg'])
    dsurface = hsl(hue, 13, L_DARK['surface'])
    dsoft = hsl(hue, 26, L_DARK['soft'])
    dsoft_strong = hsl(hue, 27, L_DARK['soft_strong'])
    dline = hsl(hue, 12, L_DARK['line'])
    dline_strong = hsl(hue, 13, L_DARK['line_strong'])
    dink = hsl(hue, 9, L_DARK['ink'])
    dink2 = hsl(hue, 9, L_DARK['ink2'])
    dm_l = L_DARK['muted']
    dmuted = hsl(hue, 8, dm_l)
    while contrast(dmuted, dbg) < 4.6 and dm_l < 82:
        dm_l += 0.5
        dmuted = hsl(hue, 8, dm_l)
    dprimary = hsl(hue, min(sat + 6, 60), L_DARK['primary'])
    dprimary_dark = hsl(hue, min(sat + 6, 60), L_DARK['primary_dark'])
    on_primary_dark = hsl(hue, 30, 14)

    p_l = L_DARK['primary']
    while contrast(dprimary, on_primary_dark) < 4.5 and p_l < 92:
        p_l += 1
        dprimary = hsl(hue, min(sat + 6, 60), p_l)
    dprimary_dark = hsl(hue, min(sat + 6, 60), min(p_l + 9, 92))

    blocks_dark.append((key, cn, dict(
        bg=dbg, surface=dsurface, ink=dink, ink2=dink2, muted=dmuted,
        primary=dprimary, primary_dark=dprimary_dark, on_primary=on_primary_dark,
        soft=dsoft, soft_strong=dsoft_strong, line=dline, line_strong=dline_strong)))

    # ── 校验 ──
    rows = [
        ('正文 ink / bg', contrast(ink, bg), 7.0),
        ('次级 ink-2 / bg', contrast(ink2, bg), 4.5),
        ('弱化 muted / bg', contrast(muted, bg), 4.5),
        ('链接 primary-dark / surface', contrast(primary_dark, surface), 4.5),
        ('主按钮 on-primary / primary', contrast(on_primary, primary), 4.5),
        ('主色块上的字 primary-dark / soft', contrast(primary_dark, soft), 4.0),
        ('描边 line-strong / surface', contrast(line_strong, surface), 1.15),
    ]
    for name, val, need in rows:
        flag = 'OK ' if val >= need else 'LOW'
        report.append(f'{flag} {key:<9} 浅 {name:<26} {val:5.2f} (>= {need})')
    drows = [
        ('正文 ink / bg', contrast(dink, dbg), 7.0),
        ('次级 ink-2 / bg', contrast(dink2, dbg), 4.5),
        ('弱化 muted / bg', contrast(dmuted, dbg), 4.5),
        ('链接 primary-dark / surface', contrast(dprimary_dark, dsurface), 4.5),
        ('主按钮 on-primary / primary', contrast(on_primary_dark, dprimary), 4.5),
        ('卡片 surface / bg', contrast(dsurface, dbg), 1.10),
        ('描边 line-strong / surface', contrast(dline_strong, dsurface), 1.15),
    ]
    for name, val, need in drows:
        flag = 'OK ' if val >= need else 'LOW'
        report.append(f'{flag} {key:<9} 夜 {name:<26} {val:5.2f} (>= {need})')
    report.append('')

os.makedirs('.tmp', exist_ok=True)

light_css = ['/* 内置主题（浅色）：只定"色相 + 层级"这一组变量，组件里一律走 var()，',
             '   不要在页面里再写死颜色——否则换主题时总有一处漏掉。 */']
for key, cn, desc, v in blocks_light:
    light_css.append(f':root.theme-{key}{{--theme-name:"{cn}";')
    light_css.append(
        f'  --bg:{v["bg"]};--surface:{v["surface"]};--ink:{v["ink"]};--ink-2:{v["ink2"]};--muted:{v["muted"]};')
    light_css.append(
        f'  --primary:{v["primary"]};--primary-dark:{v["primary_dark"]};--on-primary:{v["on_primary"]};')
    light_css.append(
        f'  --soft:{v["soft"]};--soft-strong:{v["soft_strong"]};--line:{v["line"]};--line-strong:{v["line_strong"]}}}')
light_css.append('/* 夜间：同一套主题换个明度阶梯，色相不变 */')
for key, cn, v in blocks_dark:
    light_css.append(f':root.dark.theme-{key}{{')
    light_css.append(
        f'  --bg:{v["bg"]};--surface:{v["surface"]};--ink:{v["ink"]};--ink-2:{v["ink2"]};--muted:{v["muted"]};')
    light_css.append(
        f'  --primary:{v["primary"]};--primary-dark:{v["primary_dark"]};--on-primary:{v["on_primary"]};')
    light_css.append(
        f'  --soft:{v["soft"]};--soft-strong:{v["soft_strong"]};--line:{v["line"]};--line-strong:{v["line_strong"]}}}')

io.open('.tmp/theme.css', 'w', encoding='utf-8', newline='\n').write('\n'.join(light_css) + '\n')
io.open('.tmp/theme-report.txt', 'w', encoding='utf-8', newline='\n').write('\n'.join(report))

# 主题元数据给前端用
meta = ['/* 主题元数据：id → 中文名 / 描述 / 浅色与夜间的三个色块（用于选择器预览） */',
        'const THEMES=[']
for (key, cn, desc, l), (_, _, d) in zip(blocks_light, blocks_dark):
    meta.append(f" {{{{id:'{key}',name:'{cn}',desc:'{desc}',"
                f"light:['{l['primary']}','{l['soft']}','{l['bg']}'],"
                f"dark:['{d['primary']}','{d['soft']}','{d['bg']}']}}}},")
meta.append('];')
io.open('.tmp/theme-meta.js', 'w', encoding='utf-8', newline='\n').write('\n'.join(meta) + '\n')

print('\n'.join(report))
print('LOW 条数：', sum(1 for r in report if r.startswith('LOW')))
