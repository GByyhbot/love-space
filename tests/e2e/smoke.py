"""恋爱空间 · 前端冒烟（CI 用，不进 pytest 收集）

后端有 285 条 pytest 兜着，前端此前是零覆盖：app.js 里 40 万字符的任何一次改动，
只有人工点开页面才知道有没有炸。这个脚本补上那道保险，只测「最贵的那几条路」，
不追求覆盖率：

  1. 首屏能起来（外壳渲染 + 设计令牌加载 + 0 运行时错误）
  2. 七个 tab 逐个切换都不报错
  3. 真实输入框发一条消息（composer → POST → 重绘）
  4. 带图的聊天消息能渲染出 <img>（顺便给第 5 条造素材）
  5. 对方发消息 → SSE 触发刷新 → **只重拉聊天**（锁定「刷新分流」这个优化）
  6. 刷新后附件节点原地复用（DOM 身份不变，锁定 paintChat 的键控对账）

自包含：自己建两个账号、自己拿 cookie，不依赖任何本地文件或线上环境。

用法：
    python -m uvicorn app.main:app --port 8321 &
    python tests/e2e/smoke.py            # E2E_ORIGIN 可覆盖地址

为什么要单独起服务而不是用 TestClient：这里要验的是浏览器里的真实运行时
（Service Worker、SSE、DOM 复用），TestClient 没有浏览器，测不到这些。
"""
import os
import io
import sys
import time
import traceback
from pathlib import Path

import httpx
from PIL import Image

ORIGIN = os.getenv('E2E_ORIGIN', 'http://127.0.0.1:8321')
PASSWORD = 'love-space-e2e-123'
HEADERS = {'X-Love-Space': '1'}
OUT = Path('test-results')

_results = []


def ok(passed, label, detail=''):
    _results.append((passed, label))
    print(f"{'PASS' if passed else 'FAIL'}  {label}" + (f'  {detail}' if detail else ''), flush=True)


def wait_ready(timeout=60):
    """等 uvicorn 起来。CI 里服务是后台起的，不探活直接跑会连不上。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if httpx.get(ORIGIN + '/api/status', timeout=2).status_code == 200:
                return True
        except httpx.HTTPError:
            pass
        time.sleep(1)
    return False


def session_cookie(client, resp):
    value = resp.cookies.get('love_session') or client.cookies.get('love_session')
    if not value:
        raise RuntimeError('建号后没拿到 love_session cookie')
    return {'name': 'love_session', 'value': value, 'domain': '127.0.0.1', 'path': '/'}


def run():
    from playwright.sync_api import sync_playwright

    page_errors, console_errors = [], []

    with httpx.Client(base_url=ORIGIN, headers=HEADERS, timeout=30) as a:
        r = a.post('/api/setup', json={'username': 'e2e1', 'password': PASSWORD, 'name': '小兔'})
        if r.status_code != 200:
            raise RuntimeError(f'setup 失败 {r.status_code} {r.text}')
        cookie_a = session_cookie(a, r)
        invite = a.post('/api/invite').json()['token']

        with httpx.Client(base_url=ORIGIN, headers=HEADERS, timeout=30) as b:
            r = b.post('/api/join', json={'username': 'e2e2', 'password': PASSWORD,
                                          'name': '小熊', 'token': invite})
            if r.status_code != 200:
                raise RuntimeError(f'join 失败 {r.status_code} {r.text}')

            with sync_playwright() as pw:
                try:
                    browser = pw.chromium.launch()
                except Exception:
                    # 本地开发机往往只有系统浏览器、没装 Playwright 自带的 chromium；
                    # CI 里装了则走上面那条。两边都能跑，脚本不需要分叉。
                    browser = pw.chromium.launch(channel='msedge')
                try:
                    ctx = browser.new_context(viewport={'width': 420, 'height': 900})
                    ctx.add_cookies([cookie_a])
                    page = ctx.new_page()
                    page.on('pageerror', lambda e: page_errors.append(str(e)))

                    def on_console(msg):
                        if msg.type != 'error':
                            return
                        text = msg.text
                        # 资源 404 / favicon 之类不是前端逻辑错误，别让它们淹没真问题
                        if any(s in text for s in ('Failed to load resource', 'favicon', 'net::ERR_')):
                            return
                        console_errors.append(text)

                    page.on('console', on_console)

                    # ---- 1. 首屏 ----
                    page.goto(ORIGIN + '/', wait_until='domcontentloaded')
                    page.wait_for_function(
                        "() => typeof state !== 'undefined' && state.me", timeout=20000)
                    page.wait_for_timeout(800)
                    shell = page.evaluate("""() => ({
                        hasApp: !!document.querySelector('#app') && document.querySelector('#app').children.length > 0,
                        primary: getComputedStyle(document.documentElement).getPropertyValue('--primary').trim(),
                        me: state.me.user.name,
                    })""")
                    ok(shell['hasApp'], '首屏渲染出内容')
                    ok(bool(shell['primary']), '设计令牌已加载', f"--primary={shell['primary']}")
                    ok(shell['me'] == '小兔', '登录态生效', f"state.me={shell['me']}")

                    # ---- 2. 七个 tab ----
                    for name in ('home', 'timeline', 'albums', 'messages',
                                 'together', 'personal', 'settings'):
                        before = len(page_errors)
                        page.evaluate('(n) => navigate(n)', name)
                        page.wait_for_timeout(350)
                        rendered = page.evaluate(
                            "() => !!document.querySelector('#app') && document.querySelector('#app').children.length > 0")
                        ok(rendered and len(page_errors) == before, f'切换到 {name}')

                    # ---- 3. 真实输入框发消息 ----
                    page.evaluate("() => navigate('messages')")
                    page.wait_for_selector('#chat-text', timeout=15000)
                    stamp = f'e2e-{int(time.time() * 1000)}'
                    page.fill('#chat-text', stamp)
                    page.click('.compose-send')
                    page.wait_for_function(
                        '(s) => document.querySelector("#chat-log")?.textContent.includes(s)',
                        arg=stamp, timeout=15000)
                    ok(True, '输入框发消息成功')
                    ok(page.evaluate("() => document.querySelector('#chat-text').value === ''"),
                       '发送后输入框已清空')

                    # ---- 4. 发一条带图的聊天：后面要靠它验证附件节点复用 ----
                    # 干净库里没有任何媒体，不主动造一张的话「节点复用」那条检查会永远 SKIP，
                    # 而它正是 paintChat 那次改造的回归守卫。
                    buf = io.BytesIO()
                    Image.new('RGB', (64, 64), (220, 160, 180)).save(buf, 'PNG')
                    mid = a.post('/api/media', files={'file': ('e2e.png', buf.getvalue(), 'image/png')}).json()['id']
                    a.post('/api/records', json={'kind': 'chat', 'body': {'content': '看图', 'media': [mid]},
                                                 'client_id': f'img-{int(time.time() * 1000)}'})
                    page.evaluate('() => handleServerEvent()')
                    page.wait_for_selector('#chat-log img', timeout=20000)
                    ok(True, '带图消息渲染出 <img>')

                    # ---- 5. 记下附件节点，作为复用的基线 ----
                    baseline = page.evaluate(
                        "() => { window.__nodes = [...document.querySelectorAll('#chat-log img, #chat-log video')];"
                        "return window.__nodes.length; }")
                    ok(baseline > 0, '附件节点基线已记录', f'{baseline} 个')

                    # 先等过一轮 SSE 探针，把首屏残留的事件（建号、通知已读、上面这条带图消息）
                    # 消化掉，否则合并进来的一条 refresh 会让这轮走整站刷新，测不出分流
                    page.wait_for_timeout(6000)

                    # ---- 6. 对方发消息 → SSE 分流 ----
                    api_calls = []
                    page.on('request', lambda req: api_calls.append(req.url)
                            if '/api/' in req.url and '/api/events' not in req.url else None)

                    from_b = f'对方-{int(time.time() * 1000)}'
                    b.post('/api/records', json={'kind': 'chat', 'body': {'content': from_b},
                                                 'client_id': f'e2e-{int(time.time() * 1000)}'})

                    arrived = False
                    for _ in range(20):
                        page.wait_for_timeout(1000)
                        arrived = page.evaluate(
                            '(s) => document.querySelector("#chat-log")?.textContent.includes(s)', from_b)
                        if arrived:
                            break
                    ok(arrived, '对方发的消息经 SSE 到达并渲染')

                    pulled_other = any('exclude=chat' in u for u in api_calls)
                    pulled_photos = any('/api/photos' in u for u in api_calls)
                    detail = ' | '.join(u.split('/api/')[1][:40] for u in api_calls[:4]) if api_calls else ''
                    ok(not pulled_other and not pulled_photos,
                       '只重拉了聊天，没拖整站', detail)

                    reuse = page.evaluate("""() => {
                        const now = [...document.querySelectorAll('#chat-log img, #chat-log video')];
                        return { total: now.length, same: window.__nodes.filter(n => now.indexOf(n) !== -1).length };
                    }""")
                    ok(reuse['total'] == baseline and reuse['same'] == baseline,
                       '刷新后附件节点原地复用', f"{reuse['same']}/{baseline}（当前 {reuse['total']} 个）")

                    # ---- 7. 拆分后跨文件全局可见（app.js ↔ watch.js）----
                    # watch.js 是独立的 classic script，和 app.js 靠共享的全局词法作用域
                    # 交换那 77 个 watch* 函数。拆错不会在加载时报错——函数引用是调用时
                    # 才解析的——只会在用户点进「一起看」时 ReferenceError。所以这里
                    # 既验函数可达，也真的把页面走一遍。
                    nav = page.evaluate("""async () => {
                        try { await navigate('watch'); return 'ok'; }
                        catch (e) { return 'ERR ' + (e && e.message || e); }
                    }""")
                    ok(nav == 'ok', '能进「一起看」页面', nav)
                    page.wait_for_timeout(800)
                    globs = page.evaluate("""() => ({
                        pull: typeof watchPull, pick: typeof watchPick,
                        back: typeof wsBack, hls: typeof watchMountHls,
                        sofa: typeof WATCH_SOFA, cfg: typeof WATCH_PICK,
                        mounted: !!document.querySelector('.watch-page'),
                    })""")
                    ok(globs['mounted'], '一起看页面渲染出 .watch-page')
                    cross = ['pull', 'pick', 'back', 'hls', 'sofa']
                    ok(all(globs[k] != 'undefined' for k in cross) and globs['cfg'] == 'object',
                       'watch.js 的全局对 app.js 可见',
                       f"watchPull={globs['pull']} WATCH_PICK={globs['cfg']} WATCH_SOFA={globs['sofa']}")

                    # ---- 8. 生理期页（period.js 拆出后的可见性）----
                    # 同 watch 的理由：period.js 也是独立 classic script，函数引用在调用时
                    # 才解析，加载失败不会在首屏暴露，只会在点进「我们 → 生理期」时白屏。
                    per = page.evaluate("""async () => {
                        // navigate(page, tab) 会把 state.tab 重置成参数，所以 tab 必须当参数传，
                        // 先写 state.tab 再 navigate 是无效的。
                        try { await navigate('together', 'period'); }
                        catch (e) { return 'ERR ' + (e && e.message || e); }
                        return {
                            // 注意：不要断言 .cycle-hero —— 它只在「已有经期记录」时才渲染，
                            // 干净库里走的是「开始记录」那个分支。.period-top-card 是无条件的。
                            card: !!document.querySelector('.period-top-card'),
                            days: typeof periodData, grid: typeof periodMonthGrid,
                            save: typeof periodSaveDay, form: typeof periodForm,
                        };
                    }""")
                    ok(isinstance(per, dict) and per['card'],
                       '生理期页渲染出 .period-top-card（period.js 已生效）', str(per))
                    if isinstance(per, dict):
                        ok(all(per[k] != 'undefined' for k in ('days', 'grid', 'save', 'form')),
                           'period.js 的全局对 app.js 可见',
                           f"periodData={per['days']} periodSaveDay={per['save']}")

                    # ---- 9. 零运行时错误 ----
                    ok(not page_errors, '无 PAGEERROR', ' / '.join(page_errors[:3]))
                    ok(not console_errors, '无 console error', ' / '.join(console_errors[:3]))

                except Exception:
                    ok(False, '冒烟执行异常', traceback.format_exc().splitlines()[-1])
                    try:
                        page = ctx.pages[0]
                        OUT.mkdir(exist_ok=True)
                        page.screenshot(path=str(OUT / 'smoke-failure.png'), full_page=True)
                        print(f'失败截图：{OUT / "smoke-failure.png"}', flush=True)
                    except Exception:
                        pass
                finally:
                    browser.close()


def main():
    if not wait_ready():
        print(f'服务没起来：{ORIGIN}', flush=True)
        return 1
    try:
        run()
    except Exception:
        ok(False, '冒烟未完成', traceback.format_exc().splitlines()[-1])

    failed = [label for passed, label in _results if not passed]
    print(f"\n{len(_results) - len(failed)}/{len(_results)} 项通过", flush=True)
    if failed:
        print('失败项：' + '、'.join(failed), flush=True)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
