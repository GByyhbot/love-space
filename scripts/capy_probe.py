#!/usr/bin/env python3
"""Capy 组件契约探针：把上游「现在长什么样」抓成一份可 diff 的快照。

为什么需要它
────────────
happy-capy（`cs920/happy-capy`）没有任何文档，CapyPlayer 官方规范只描述**沙箱组件**
（`var WidgetMetadata` + 全局函数），不描述这层 REST 壳。也就是说：

    「上游会给我们哪些字段」这件事，没有权威来源，只能靠观测。

所以这里把观测结果固化下来：跑一遍 → 写 `docs/capy-contract.json` → 提交。
下次上游改版，`--diff` 会直接告诉你「新增了哪些字段、消失了哪些字段」，
不用等用户在真机上发现某页变空。

用法
────
    # 抓一份快照（默认打到 CAPY_BASE 或 192.168.31.95:8788）
    python scripts/capy_probe.py

    # 只看有什么变了（不发请求，纯比文件）
    python scripts/capy_probe.py --diff

    # 抓新的并和旧快照对比
    python scripts/capy_probe.py --write --diff

    # 换一台服务
    python scripts/capy_probe.py --base http://192.168.1.9:8788

    # 让上游先跑一遍全量诊断，再抓快照（网络模式只有诊断里才有）
    python scripts/capy_probe.py --diag --write --diff

刻意只用标准库：这个脚本要能在 NAS 上、在没装依赖的机器上直接跑。
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_BASE = os.environ.get('CAPY_BASE', 'http://192.168.31.95:8788').rstrip('/')
SNAPSHOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        'docs', 'capy-contract.json')
TIMEOUT = 30
TRIES = 3
# 上游全量诊断是串行跑的（本机 9 个组件 8 秒，带超时的源更久），留足余量
DIAG_WAIT = 240

UA = 'love-space-probe/1'


def get(base, path):
    """带重试的 GET。上游 504 是常态，探针不该被一次抖动打断。"""
    last = None
    for i in range(TRIES):
        url = base + path
        try:
            req = urllib.request.Request(url, headers={'User-Agent': UA})
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                raw = r.read()
                try:
                    return json.loads(raw.decode('utf-8', 'ignore'))
                except ValueError:
                    return {'__non_json__': raw[:200].decode('utf-8', 'ignore')}
        except urllib.error.HTTPError as exc:
            last = 'HTTP %s' % exc.code
        except Exception as exc:                       # 连不上、超时
            last = type(exc).__name__
        time.sleep(1.0 * (i + 1))
    raise SystemExit('取不到 %s（%s）' % (path, last))


def post(base, path, payload):
    """POST 一份 JSON。只在 `--diag` 里用，用来触发上游的全量诊断。"""
    body = json.dumps(payload).encode()
    req = urllib.request.Request(base + path, data=body, method='POST',
                                 headers={'User-Agent': UA,
                                          'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        raw = r.read()
    try:
        return json.loads(raw.decode('utf-8', 'ignore'))
    except ValueError:
        return {'__non_json__': raw[:200].decode('utf-8', 'ignore')}


def run_diagnostics(base, wait=DIAG_WAIT):
    """触发一次全量诊断并等它跑完。

    ⚠️ 这一步**有副作用**：上游会真的去访问每个源站，几十秒到几分钟。
    所以它必须是一次显式动作（`--diag`），绝不能挂在普通的 GET 路径上 ——
    否则「打开组件列表」就变成「对十几个源站发一轮探测」。
    """
    before = task_state(get(base, '/api/v1/diagnostics'))
    print('触发全量诊断…（上游会逐个访问源站，可能要一分钟以上）')
    try:
        post(base, '/api/v1/diagnostics', {'target': 'all'})
    except Exception as exc:
        raise SystemExit('触发诊断失败：%s' % exc)
    deadline = time.time() + wait
    while time.time() < deadline:
        time.sleep(2.0)
        try:
            now = get(base, '/api/v1/diagnostics')
        except SystemExit as exc:
            print('  轮询失败，用上一份快照：%s' % exc)
            break
        task = task_state(now)
        print('  %s %s/%s %s' % (task['state'], task['index'], task['total'], task['message']))
        if task['state'] == 'finished' and task['finished_at'] != before['finished_at']:
            return now
    print('  等太久，改用现有快照')
    return get(base, '/api/v1/diagnostics')


def task_state(payload):
    task = payload.get('task') if isinstance(payload, dict) else None
    task = task if isinstance(task, dict) else {}
    return {'state': str(task.get('state') or ''),
            'index': task.get('current_index', 0),
            'total': task.get('total', 0),
            'message': str(task.get('message') or ''),
            'finished_at': str(task.get('finished_at') or '')}


def keys_of(obj):
    return sorted(obj.keys()) if isinstance(obj, dict) else []


def union_keys(rows):
    """一组 dict 的字段并集 —— 单条样本会漏掉只在部分条目上出现的字段。"""
    out = set()
    for row in rows or []:
        if isinstance(row, dict):
            out |= set(row.keys())
    return sorted(out)


def first_episode(detail):
    """把详情里能放剧集的地方都翻一遍，返回第一条的字段。"""
    seasons = detail.get('seasons') or detail.get('seasonItems') or []
    if isinstance(seasons, list):
        for season in seasons:
            if not isinstance(season, dict):
                continue
            eps = season.get('episodes') or season.get('episodeItems') or []
            if eps and isinstance(eps[0], dict):
                return eps[0]
    for key in ('episodeItems', 'episodes'):
        eps = detail.get(key)
        if isinstance(eps, list) and eps and isinstance(eps[0], dict):
            return eps[0]
    return {}


def probe_one(base, provider):
    """一个组件：清单 → 第一个分类的第一页 → 首条的详情。"""
    row = {'id': provider.get('id'), 'title': provider.get('title'),
           'ok': False, 'error': '', 'categories': len(provider.get('categories') or [])}
    cats = provider.get('categories') or []
    cat = (cats[0] or {}).get('id', '') if cats else ''
    try:
        page = get(base, '/api/v1/providers/%s/browse?category=%s&page=1'
                   % (provider.get('id'), urllib.parse.quote(str(cat), safe='')))
    except SystemExit as exc:
        row['error'] = str(exc)
        return row
    items = page.get('items') if isinstance(page, dict) else None
    items = items or []
    row['page_fields'] = keys_of(page)
    row['item_fields'] = union_keys(items)
    row['items'] = len(items)
    if not items:
        row['ok'] = True
        row['error'] = '这个分类是空的'
        return row
    try:
        detail = get(base, '/api/v1/providers/%s/items/%s'
                     % (provider.get('id'), urllib.parse.quote(str(items[0].get('id')), safe='')))
    except SystemExit as exc:
        row['error'] = str(exc)
        return row
    row['detail_fields'] = keys_of(detail)
    row['episode_fields'] = union_keys([first_episode(detail)])
    row['ok'] = True
    return row


def diag_shape(payload):
    """诊断快照 → 只留**形状与枚举值**，不留任何文案。

    网络模式只有这里才有（`/api/v1/providers` 不提供），所以要观测它。
    但这份快照是要提交进仓库的，`diagnostic_text` / `impact_hint` 里会出现
    源站域名和连接细节 —— 存进仓库不合适，也没必要：**我们只关心字段名和
    枚举值域**，那才是「上游改版了没有」的判断依据。
    """
    results = payload.get('results') if isinstance(payload, dict) else None
    results = results if isinstance(results, dict) else {}
    rows, check_fields = [], set()
    for pid, one in sorted(results.items()):
        if not isinstance(one, dict):
            continue
        checks = one.get('checks') if isinstance(one.get('checks'), dict) else {}
        check_fields |= set(checks.keys())
        rows.append({
            'id': pid,
            'network_mode': str(one.get('network_mode') or ''),
            'network_text': str(one.get('network_text') or ''),
            'status': str(one.get('status') or ''),
            'server_check_role': str(one.get('server_check_role') or ''),
            'checks': sorted(checks.keys()),
        })
    return {
        'covered': len(rows),
        'result_fields': union_keys(list(results.values())),
        'check_fields': sorted(check_fields),
        'network_modes': sorted({r['network_mode'] for r in rows}),
        'statuses': sorted({r['status'] for r in rows}),
        'roles': sorted({r['server_check_role'] for r in rows}),
        'rows': rows,
    }


def cap_kind(cap):
    """能力串归一成「种类」：`provider:hongguo@1` → `provider:*`。

    不归一的话，每装一个组件这组值就要多一项，全落在 `provider:` 上 ——
    那不是契约变更，只是装的东西变多了。真正要盯的是**出现新种类**。
    """
    head = str(cap or '').split('@')[0]
    return 'provider:*' if head.startswith('provider:') else head


def catalog_shape(payload):
    """组件目录 → 只留「谁装在这台机器上、它有没有通用契约」。

    两份清单的差集就是「装了却接不上」的那几个（bilibili / huangguo / missav）。
    契约变更里最容易被忽略的正是这一类：组件数从 17 涨到 20 时，
    `/providers` 完全没变，只看它永远发现不了。
    """
    rows = payload.get('components') if isinstance(payload, dict) else None
    rows = rows if isinstance(rows, list) else []
    out = []
    for one in rows:
        if not isinstance(one, dict) or not one.get('id'):
            continue
        caps = [str(c) for c in (one.get('backendCapabilities') or []) if c]
        out.append({
            'id': str(one.get('id')),
            'backend_type': str(one.get('backendType') or ''),
            'caps': caps,
            # 没有 provider:<id>@1 就是接不上的那一类，快照里直接标出来
            'provider': any(str(c).startswith('provider:') for c in caps),
        })
    out.sort(key=lambda r: r['id'])
    return {
        'count': len(out),
        'backend_types': sorted({r['backend_type'] for r in out}),
        # 能力串去掉 id 与版本再归一，否则每装一个组件这组值就要变一次
        'cap_kinds': sorted({cap_kind(c) for r in out for c in r['caps']}),
        'builtin': sorted(r['id'] for r in out if not r['provider']),
        'rows': out,
    }


def build(base, diag_payload=None):
    payload = get(base, '/api/v1/providers')
    providers = payload.get('providers') if isinstance(payload, dict) else None
    providers = providers or []
    rows = [probe_one(base, p) for p in providers]
    if diag_payload is None:
        try:
            diag_payload = get(base, '/api/v1/diagnostics')
        except SystemExit:
            diag_payload = {}
    try:
        catalog_payload = get(base, '/api/v1/components/catalog')
    except SystemExit:
        catalog_payload = {}
    return {
        'generated_at': time.strftime('%Y-%m-%d %H:%M:%S'),
        'base': base,
        'provider_count': len(providers),
        'provider_fields': union_keys(providers),
        'caps_values': sorted({c for p in providers
                               for c in (p.get('capabilities') or [])}),
        'page_fields': sorted({f for r in rows for f in (r.get('page_fields') or [])}),
        'item_fields': sorted({f for r in rows for f in (r.get('item_fields') or [])}),
        'detail_fields': sorted({f for r in rows for f in (r.get('detail_fields') or [])}),
        'episode_fields': sorted({f for r in rows for f in (r.get('episode_fields') or [])}),
        'providers': rows,
        'diagnostics': diag_shape(diag_payload),
        'catalog': catalog_shape(catalog_payload),
    }


def diff(old, new):
    """只比「形状」不比内容：字段增删才是契约变更，标题改了不是。"""
    lines = []
    for field in ('provider_fields', 'page_fields', 'item_fields',
                  'detail_fields', 'episode_fields', 'caps_values'):
        a, b = set(old.get(field) or []), set(new.get(field) or [])
        for name in sorted(b - a):
            lines.append('  + %s: %s' % (field, name))
        for name in sorted(a - b):
            lines.append('  - %s: %s' % (field, name))
    old_ids = {p.get('id') for p in old.get('providers') or []}
    new_ids = {p.get('id') for p in new.get('providers') or []}
    for name in sorted(new_ids - old_ids):
        lines.append('  + 新组件: %s' % name)
    for name in sorted(old_ids - new_ids):
        lines.append('  - 组件消失: %s' % name)
    # 诊断部分的枚举值域变了，等于「网络模式的含义变了」，必须报出来
    da, db = old.get('diagnostics') or {}, new.get('diagnostics') or {}
    for field in ('result_fields', 'check_fields', 'network_modes',
                  'statuses', 'roles'):
        a, b = set(da.get(field) or []), set(db.get(field) or [])
        for name in sorted(b - a):
            lines.append('  + diagnostics.%s: %s' % (field, name or '(空)'))
        for name in sorted(a - b):
            lines.append('  - diagnostics.%s: %s' % (field, name or '(空)'))
    # 组件目录：`/providers` 不动也可能「多装了东西」，只看前一份永远发现不了
    ca, cb = old.get('catalog') or {}, new.get('catalog') or {}
    for field in ('backend_types', 'cap_kinds'):
        a, b = set(ca.get(field) or []), set(cb.get(field) or [])
        for name in sorted(b - a):
            lines.append('  + catalog.%s: %s' % (field, name or '(空)'))
        for name in sorted(a - b):
            lines.append('  - catalog.%s: %s' % (field, name or '(空)'))
    if ca and cb and ca.get('count') != cb.get('count'):
        lines.append('  ~ catalog.count: %s → %s' % (ca.get('count'), cb.get('count')))
    a, b = set(ca.get('builtin') or []), set(cb.get('builtin') or [])
    for name in sorted(b - a):
        lines.append('  + 新内建组件（接不上）: %s' % name)
    for name in sorted(a - b):
        lines.append('  - 内建组件变可用/消失: %s' % name)
    return lines


def main():
    ap = argparse.ArgumentParser(description='Capy 组件契约探针')
    ap.add_argument('--base', default=DEFAULT_BASE, help='组件服务根地址')
    ap.add_argument('--write', action='store_true', help='把结果写回 docs/capy-contract.json')
    ap.add_argument('--diff', action='store_true', help='和已有快照对比字段增删')
    ap.add_argument('--diag', action='store_true',
                    help='先让上游跑一遍全量诊断（会真的访问各源站，慢），再抓快照')
    ap.add_argument('--out', default='', help='输出路径（默认 docs/capy-contract.json）')
    args = ap.parse_args()

    diag_payload = run_diagnostics(args.base) if args.diag else None

    if args.diff and not args.write:
        old = json.load(open(SNAPSHOT, encoding='utf-8'))
        lines = diff(old, build(args.base, diag_payload))
        print('\n'.join(lines) if lines else '契约没有变化。')
        return 0 if not lines else 1

    data = build(args.base, diag_payload)
    print('组件数 %s  基地址 %s' % (data['provider_count'], data['base']))
    for row in data['providers']:
        print('  %-18s %-6s 分类 %-3s 条目 %-3s 剧集字段 %s'
              % (row.get('id'), 'ok' if row.get('ok') else 'FAIL',
                 row.get('categories', 0), row.get('items', 0),
                 ','.join(row.get('episode_fields') or []) or '—'))
    diag = data['diagnostics']
    print('诊断覆盖 %s 个组件（总共 %s 个）' % (diag['covered'], data['provider_count']))
    for row in diag['rows']:
        print('  %-18s %-18s %-10s %-22s checks=%s'
              % (row['id'], row['network_mode'] or '(未标)', row['status'] or '—',
                 row['server_check_role'] or '—', ','.join(row['checks']) or '-'))
    cat = data['catalog']
    print('组件目录 %s 个（通用契约 %s 个，内建接不上 %s 个）'
          % (cat['count'], cat['count'] - len(cat['builtin']), len(cat['builtin'])))
    for pid in cat['builtin']:
        print('  内建 %s' % pid)
    if args.write:
        target = args.out or SNAPSHOT
        old = None
        if os.path.exists(target):
            old = json.load(open(target, encoding='utf-8'))
        with open(target, 'w', encoding='utf-8', newline='\n') as fh:
            json.dump(data, fh, ensure_ascii=False, indent=1, sort_keys=True)
            fh.write('\n')
        print('已写入 %s' % target)
        if args.diff and old:
            lines = diff(old, data)
            print('\n'.join(lines) if lines else '契约没有变化。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
