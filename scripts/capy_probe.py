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


def get(base, path):
    """带重试的 GET。上游 504 是常态，探针不该被一次抖动打断。"""
    last = None
    for i in range(TRIES):
        url = base + path
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'love-space-probe/1'})
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


def build(base):
    payload = get(base, '/api/v1/providers')
    providers = payload.get('providers') if isinstance(payload, dict) else None
    providers = providers or []
    rows = [probe_one(base, p) for p in providers]
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
    return lines


def main():
    ap = argparse.ArgumentParser(description='Capy 组件契约探针')
    ap.add_argument('--base', default=DEFAULT_BASE, help='组件服务根地址')
    ap.add_argument('--write', action='store_true', help='把结果写回 docs/capy-contract.json')
    ap.add_argument('--diff', action='store_true', help='和已有快照对比字段增删')
    args = ap.parse_args()

    if args.diff and not args.write:
        old = json.load(open(SNAPSHOT, encoding='utf-8'))
        lines = diff(old, build(args.base))
        print('\n'.join(lines) if lines else '契约没有变化。')
        return 0 if not lines else 1

    data = build(args.base)
    print('组件数 %s  基地址 %s' % (data['provider_count'], data['base']))
    for row in data['providers']:
        print('  %-18s %-6s 分类 %-3s 条目 %-3s 剧集字段 %s'
              % (row.get('id'), 'ok' if row.get('ok') else 'FAIL',
                 row.get('categories', 0), row.get('items', 0),
                 ','.join(row.get('episode_fields') or []) or '—'))
    if args.write:
        old = None
        if os.path.exists(SNAPSHOT):
            old = json.load(open(SNAPSHOT, encoding='utf-8'))
        with open(SNAPSHOT, 'w', encoding='utf-8', newline='\n') as fh:
            json.dump(data, fh, ensure_ascii=False, indent=1, sort_keys=True)
            fh.write('\n')
        print('已写入 %s' % SNAPSHOT)
        if args.diff and old:
            lines = diff(old, data)
            print('\n'.join(lines) if lines else '契约没有变化。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
