"""使用时长「一套账」只读回放对账（2.8.7 傍晚批 1-2 验收工具）。

只读：`sqlite3.connect(f'file:{db}?mode=ro', uri=True)`，绝不写库。
输出四段：① 原始库表盘点 ② 修前五数（旧口径复现）③ 修后五数（一套账）
④ 三条恒等式断言（全 PASS 退出码 0，否则 1）。

用法：
  python scripts/reconcile_usage_replay.py --db /data/love.db --user <id|username|name> \
      --date 2026-11-28 [--now <epoch>]
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sqlite3
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, '/srv' if Path('/srv/app').exists() else str(ROOT))

from app import peer_agg  # noqa: E402


def _payload(raw):
    try:
        v = json.loads(raw or '{}')
        return v if isinstance(v, dict) else {}
    except (ValueError, TypeError):
        return {}


def _rows(c, uid, kind, lo, hi):
    rows = c.execute(
        "SELECT ts,payload FROM peer_events WHERE user=? AND type=? AND "
        '((ts>=? AND ts<?) OR (ts>=? AND ts<?)) ORDER BY ts',
        (uid, kind, lo, hi, lo * 1000.0, hi * 1000.0)).fetchall()
    return [{'ts': float(r['ts']) / (1000.0 if float(r['ts']) > 1e11 else 1.0), 'p': _payload(r['payload'])}
            for r in rows]


def fmt_sec(v):
    v = int(v or 0)
    return f'{v // 3600}h{(v % 3600) // 60:02d}m{v % 60:02d}s'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', required=True)
    ap.add_argument('--user', required=True)
    ap.add_argument('--date', required=True)
    ap.add_argument('--now', type=float, default=None)
    a = ap.parse_args()

    now = a.now if a.now is not None else time.time()
    c = sqlite3.connect(f'file:{a.db}?mode=ro', uri=True)
    c.row_factory = sqlite3.Row
    row = c.execute('SELECT id,username,name FROM users WHERE username=? OR name=? OR id=?',
                    (a.user, a.user, a.user)).fetchone()
    if not row:
        raise SystemExit(f'用户不存在: {a.user}')
    uid = row['id']
    start, end = peer_agg.day_bounds(c, a.date)
    policy = {'location_level': 'exact', 'network_level': 'ssid', 'battery': True,
              'usage_level': 'full', 'app_level': 'stream'}

    print(f'== 用户 {row["username"]} / {row["name"]} ({uid[:8]}) | 日期 {a.date} ==')
    print(f'   日边界 [{start:.0f}, {end:.0f}) | now={now:.0f}')

    # ① 原始盘点
    screen = _rows(c, uid, 'state.screen', start - 6 * 3600, end + 6 * 3600)
    sess = _rows(c, uid, 'usage.session', start - 6 * 3600, end + 6 * 3600)
    nows = _rows(c, uid, 'usage.now', start - 6 * 3600, end + 6 * 3600)
    nets = _rows(c, uid, 'state.net', start, end)
    daily = c.execute('SELECT screen_sec,unlocks,top_apps FROM peer_usage_daily '
                      'WHERE user=? AND day=?', (uid, a.date)).fetchone()
    latest = c.execute('SELECT net,wifi,state_updated,updated FROM peer_location_latest '
                       'WHERE user=?', (uid,)).fetchone()
    print('\n── ① 原始盘点 ──')
    print(f'   state.screen {len(screen)} 条, 会话秒和 {sum(int(e["p"].get("session_sec") or 0) for e in screen)}')
    print(f'   usage.session {len(sess)} 条, dur 和 {sum(int(e["p"].get("dur") or 0) for e in sess)}')
    if nows:
        last = nows[-1]
        print(f'   usage.now {len(nows)} 条, 最新 app={last["p"].get("app")} '
              f'since={last["p"].get("since")} ts={last["ts"]:.0f}')
    else:
        print('   usage.now 0 条')
    print(f'   state.net {len(nets)} 条' + (f'，样本 {nets[-1]["p"]}' if nets else ''))
    print(f'   peer_location_latest net={latest["net"] if latest else None} '
          f'wifi={latest["wifi"] if latest else None}')
    print(f'   peer_usage_daily screen_sec={daily["screen_sec"] if daily else None} '
          f'unlocks={daily["unlocks"] if daily else None} top_apps_len='
          f'{len(json.loads(daily["top_apps"])) if daily and daily["top_apps"] else 0}')

    # ② 修前五数（旧口径）
    old_screen = int(daily['screen_sec']) if daily else sum(
        int(e['p'].get('session_sec') or 0) for e in screen)
    old_longest = max((int(e['p'].get('session_sec') or 0) for e in screen), default=0)
    old_wechat = 0
    if nows:
        since = float(nows[-1]['p'].get('since') or nows[-1]['ts'])
        old_wechat = int(now - since)
    old_top = []
    if daily and daily['top_apps']:
        try:
            old_top = [{'app': str(i.get('app')), 'sec': int(i.get('sec') or 0)}
                       for i in json.loads(daily['top_apps']) if isinstance(i, dict)][:5]
        except (ValueError, TypeError):
            old_top = []
    old_top_sum = sum(i['sec'] for i in old_top)
    old_net = ''
    if latest and latest['net']:
        old_net = latest['net'] + (f'/{latest["wifi"]}' if latest['wifi'] else '')
    elif nets:
        p = nets[-1]['p']
        old_net = (p.get('net') or '') + (f'/{p.get("ssid")}' if p.get('ssid') else '')

    # ③ 修后五数（一套账）
    led = peer_agg.reconcile_usage_day(c, uid, a.date, policy, now=now)
    net_now = peer_agg.current_network_for(c, uid, policy, fallback_events=peer_agg.network_events(
        c, uid, start, end, policy))
    new_cur = led['current_app']
    new_wechat = int(new_cur['sec']) if new_cur else 0
    new_top = led['top_apps']
    new_top_sum = sum(i['sec'] for i in new_top)
    new_net = ''
    if net_now:
        new_net = (net_now.get('net') or '') + (f'/{net_now["ssid"]}' if net_now.get('ssid') else '')

    print('\n── ② 修前五数（旧口径）──')
    print(f'   总量 {old_screen}s ({fmt_sec(old_screen)}) | 最长 {old_longest}s | '
          f'「正在使用」{old_wechat}s | Top5 合计 {old_top_sum}s | 当前网络 {old_net or "—"}')
    print('\n── ③ 修后五数（一套账）──')
    print(f'   总量 {led["screen_sec"]}s ({fmt_sec(led["screen_sec"])}) | '
          f'最长 {led["longest_session_sec"]}s | 正在使用 {new_wechat}s'
          f'（{new_cur["app"] if new_cur else "无"}）| Top5 合计 {new_top_sum}s | 当前网络 {new_net or "—"}')
    print(f'   明细：亮屏窗 {len(led["active_windows"])} 段、canonical 会话 {len(led["canonical_sessions"])} 条、'
          f'全部应用合计 {led["all_apps_sec"]}s')
    print(f'   Top5：' + ('、'.join(f'{i["app"]}{i["sec"]}s' for i in new_top) or '（空）'))

    # ④ 恒等式
    checks = [
        ('正在使用 ≤ 最长连续', new_wechat <= led['longest_session_sec'] or new_wechat == 0),
        ('最长连续 ≤ 总量', led['longest_session_sec'] <= led['screen_sec']),
        ('Top5 合计 ≤ 总量', new_top_sum <= led['screen_sec']),
        ('会话单条 ≤ 最长连续',
         all(s['sec'] <= led['longest_session_sec'] for s in led['sessions']) or not led['sessions']),
    ]
    print('\n── ④ 恒等式断言 ──')
    ok = True
    for name, passed in checks:
        print(f'   {"PASS" if passed else "FAIL"}  {name}')
        ok = ok and passed
    print('\n结果:', 'ALL PASS' if ok else 'HAS FAILURE')
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
