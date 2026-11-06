"""版本号一致性守卫。

这是踩过两次的坑：sw.js 的 CACHE 版本号和 index.html 里 style.css / app.js 的
?v= 必须同号。sw.js 对 CSS 是 cache-first，一旦脱钩，用户拿到的就是
「新 JS + 旧 CSS」，表现为样式莫名其妙错乱，而服务端怎么看都是对的。

sw.js 内部已经用 VERSION 常量把 CACHE 和 CORE 绑在一起了，但 index.html 是
另一个文件——这层跨文件的一致性只能靠断言钉住。
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SW = ROOT / 'static' / 'sw.js'
INDEX = ROOT / 'static' / 'index.html'


def sw_version():
    m = re.search(r'^const VERSION = (\d+);', SW.read_text(encoding='utf-8'), re.M)
    assert m, 'sw.js 里找不到 `const VERSION = <数字>;`，版本号常量被改掉了？'
    return int(m.group(1))


def test_sw_cache_matches_version_constant():
    """CACHE 必须由 VERSION 拼出来，不能再写死成 'love-space-vXX'。"""
    text = SW.read_text(encoding='utf-8')
    assert 'love-space-v${VERSION}' in text, \
        'sw.js 的 CACHE 应写成模板字符串 `love-space-v${VERSION}`，写死会再次脱钩'
    assert re.search(r"^const CACHE = 'love-space-v\d+';", text, re.M) is None


def test_index_html_matches_sw_version():
    """index.html 的两处 ?v= 必须与 sw.js 的 VERSION 同号。"""
    version = sw_version()
    html = INDEX.read_text(encoding='utf-8')
    found = re.findall(r'\?v=(\d+)', html)
    assert found, 'index.html 里没有 ?v= 版本号'
    assert found == [str(version)] * len(found), \
        f'index.html 的 ?v= 是 {found}，但 sw.js VERSION 是 {version}；两处必须同号'


def test_sw_core_uses_version():
    """预热清单 CORE 里的 style.css / JS bundle 也必须带当前版本号。"""
    version = sw_version()
    text = SW.read_text(encoding='utf-8')
    assert '/static/style.css?v=${VERSION}' in text
    # 自有 bundle 统一由 BUNDLES.map 拼 ?v=，不再逐个硬编码——
    # 硬编码正是当年 CACHE 到 v67、CORE 还停在 v55 的原因。
    assert '...BUNDLES.map((p) => `${p}?v=${VERSION}`)' in text, \
        'CORE 里的 JS 必须由 BUNDLES 拼版本号，别退回逐个写死'
    assert f'v={version - 1}' not in text, 'CORE 里还残留着上一个版本号'


# 本站 JS 全部要预热，没有第三方库例外（hls.min.js 随「一起看」一并移除）。


def index_scripts():
    """index.html 实际加载的本站 JS。"""
    html = INDEX.read_text(encoding='utf-8')
    return re.findall(r'<script src="(/static/[^"?]+\.js)', html)


def sw_bundles():
    text = SW.read_text(encoding='utf-8')
    m = re.search(r'^const BUNDLES = \[(.*?)\];', text, re.M | re.S)
    assert m, 'sw.js 里找不到 `const BUNDLES = [...]`'
    return set(re.findall(r"'(/static/[^']+)'", m.group(1)))


def test_every_local_bundle_is_precached():
    """index.html 加载的每个本站 JS 都必须在 sw.js 的 BUNDLES 里。

    这条是给「拆文件」准备的：以后再把 app.js 拆成几个，只改 index.html
    而忘了 sw.js，旧 worker 就永远拿不到新文件——表现是某块功能点了没反应，
    而且刷新也不一定好，因为文件被 network-first 之外的规则从缓存喂了旧版本。
    """
    scripts = set(index_scripts())
    bundles = sw_bundles()
    missing = sorted(p for p in scripts if p not in bundles)
    assert not missing, f'index.html 加载了 {missing}，但 sw.js 的 BUNDLES 里没有'
    stale = sorted(bundles - scripts)
    assert not stale, f'sw.js 的 BUNDLES 里有 {stale}，但 index.html 已经不再加载它'
