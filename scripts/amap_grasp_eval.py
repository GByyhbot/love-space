"""2-1 道路吸附效果评估（只读副本；纠偏走高德 v4/grasproad/driving）。

要点
  · 取数：只读副本 + 读侧过滤口径（peer_agg.filter_points），停留段用已上线塌缩（track_for 的 stays）
  · 吸附只对**移动段**做（停留窗内不纠偏）
  · Key 只从环境变量 AMAP_WEB_KEY 读，绝不打印、绝不落盘
  · 接口：POST https://restapi.amap.com/v4/grasproad/driving?key=...  body=JSON 数组，≤500 点
    x=经度 y=纬度（GCJ-02，库内已是 GCJ 无需转换）tm=首点 unix 秒/其余为差值 sp=km/h ag=方位角
    errcode 30001 = 抓路失败（点数少/稀疏/ag 不合理时高发）
用法
  python scripts/amap_grasp_eval.py --db /tmp/love.db --user 20010625 --day 2026-11-28 --out /out
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, '/srv' if Path('/srv/app').exists() else str(Path(__file__).resolve().parent.parent))

from app import peer_agg  # noqa: E402

MAX_POINTS = 500          # 官方上限
WALK_MAX = 2.5            # m/s
BIKE_MAX = 7.0            # m/s
POLICY = {'location_level': 'exact', 'network_level': 'ssid', 'battery': True,
          'usage_level': 'full', 'events': True}


def hav(a, b, c, d):
    r = 6371000.0
    p1, p2 = math.radians(a), math.radians(c)
    dp = p2 - p1
    dl = math.radians(d - b)
    x = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(x))


def bearing(a, b, c, d):
    p1, p2 = math.radians(a), math.radians(c)
    dl = math.radians(d - b)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


def dist(pts):
    return sum(hav(pts[i - 1]['lat'], pts[i - 1]['lng'], pts[i]['lat'], pts[i]['lng'])
               for i in range(1, len(pts)))


def build_payload(seg):
    """段内点 → 官方 body 数组。ag 用相邻点方位角（末点沿用前值，避免 ag=0 触发抓路失败）。"""
    out = []
    t0 = int(seg[0]['ts'])
    for i, p in enumerate(seg):
        if i + 1 < len(seg):
            ag = bearing(p['lat'], p['lng'], seg[i + 1]['lat'], seg[i + 1]['lng'])
        elif i > 0:
            ag = bearing(seg[i - 1]['lat'], seg[i - 1]['lng'], p['lat'], p['lng'])
        else:
            ag = 0.0
        if i + 1 < len(seg):
            dts = max(1.0, float(seg[i + 1]['ts']) - float(p['ts']))
            sp = hav(p['lat'], p['lng'], seg[i + 1]['lat'], seg[i + 1]['lng']) / dts * 3.6
        else:
            sp = out[-1]['sp'] if out else 0.0
        out.append({
            'x': round(float(p['lng']), 6),
            'y': round(float(p['lat']), 6),
            'ag': round(ag, 1),
            'tm': 0 if i == 0 else int(float(p['ts'])) - t0,
            'sp': round(min(sp, 200.0), 1),
        })
    return out


def chunk(payload, size=MAX_POINTS):
    """按 500 切片，相邻片重叠 1 点以保连续。"""
    if len(payload) <= size:
        return [payload]
    out, i = [], 0
    while i < len(payload):
        out.append(payload[i:i + size])
        if i + size >= len(payload):
            break
        i += size - 1
    return out


def snap(payload, key, timeout=20):
    import httpx
    r = httpx.post('https://restapi.amap.com/v4/grasproad/driving',
                   params={'key': key}, json=payload, timeout=timeout)
    r.raise_for_status()
    j = r.json()
    if j.get('errcode') not in (0, '0'):
        return None, f"errcode={j.get('errcode')} {j.get('errmsg') or ''}".strip()
    pts = ((j.get('data') or {}).get('points')) or []
    return pts, None


def transport_of(seg):
    sp = [hav(seg[i - 1]['lat'], seg[i - 1]['lng'], seg[i]['lat'], seg[i]['lng']) /
          max(1.0, float(seg[i]['ts']) - float(seg[i - 1]['ts']))
          for i in range(1, len(seg))]
    if not sp:
        return 'walk', 0.0
    sp.sort()
    med = sp[len(sp) // 2]
    if med < WALK_MAX:
        return 'walk', med
    if med <= BIKE_MAX:
        return 'bike', med
    return 'car', med


def segments(points, stays):
    spans = []
    for s in stays or []:
        a = float(s['arrived_at'])
        b = float(s.get('left_at') or (points[-1]['ts'] if points else a))
        spans.append((min(a, b), max(a, b)))
    spans.sort()

    def inside(t):
        return any(a <= t <= b for a, b in spans)

    segs, cur = [], []
    for p in points:
        if inside(float(p['ts'])):
            if len(cur) >= 2:
                segs.append(cur)
            cur = []
        else:
            cur.append(p)
    if len(cur) >= 2:
        segs.append(cur)
    return segs


def _lonlat_to_px(lat, lng, z):
    n = 2.0 ** z
    x = (lng + 180.0) / 360.0 * n
    y = (1.0 - math.log(math.tan(math.radians(lat)) + 1 / math.cos(math.radians(lat))) / math.pi) / 2.0 * n
    return x, y


def _tile_basemap(lat0, lat1, lng0, lng1, W, H, zoom=None):
    """高德栅格瓦片（GCJ-02 对齐）拼底图；失败返回 None。"""
    import io

    import httpx
    from PIL import Image

    z = 14
    if zoom:
        z = zoom
    else:
        for cand in range(17, 10, -1):
            x0, y0 = _lonlat_to_px(lat1, lng0, cand)
            x1, y1 = _lonlat_to_px(lat0, lng1, cand)
            if (x1 - x0) <= 3.2 and (y1 - y0) <= 3.2:
                z = cand
                break
    xs0, ys0 = _lonlat_to_px(lat1, lng0, z)
    xs1, ys1 = _lonlat_to_px(lat0, lng1, z)
    tx0, ty0 = int(xs0), int(ys0)
    tx1, ty1 = int(xs1), int(ys1)
    cols, rows = tx1 - tx0 + 1, ty1 - ty0 + 1
    if cols * rows > 64:
        return None
    img = Image.new('RGB', (cols * 256, rows * 256), (245, 245, 243))
    cli = httpx.Client(timeout=15, headers={'User-Agent': 'Mozilla/5.0'})
    try:
        for i in range(cols):
            for j in range(rows):
                url = (f'https://webst0{1 + (i + j) % 4}.is.autonavi.com/appmaptile'
                       f'?style=7&x={tx0 + i}&y={ty0 + j}&z={z}')
                try:
                    r = cli.get(url)
                    if r.status_code == 200:
                        img.paste(Image.open(io.BytesIO(r.content)).convert('RGB'),
                                  (i * 256, j * 256))
                except Exception:
                    pass
    finally:
        cli.close()
    return img, z, tx0, ty0


def render(raw, snapped_by_seg, out_png, title, colors, tiles=True):
    try:
        from PIL import Image, ImageDraw
    except Exception as e:                                    # 无 PIL 时跳过出图
        print(f'  [warn] 无 PIL，跳过出图：{e}')
        return
    all_pts = [p for seg in raw for p in seg]
    for item in snapped_by_seg:
        all_pts += list(item[0] if isinstance(item, tuple) else item)
    if not all_pts:
        return
    lats = [p['lat'] for p in all_pts]
    lngs = [p['lng'] for p in all_pts]
    pad = 0.004
    la0, la1, ln0, ln1 = min(lats) - pad, max(lats) + pad, min(lngs) - pad, max(lngs) + pad
    W, H, M = 900, 900, 40

    base = _tile_basemap(la0, la1, ln0, ln1, W, H) if tiles else None
    if base:
        bimg, z, tx0, ty0 = base
        img = Image.new('RGB', (W, H + 40), (250, 250, 248))
        img.paste(bimg, (0, 0))

        def xy(lat, lng):
            px, py = _lonlat_to_px(lat, lng, z)
            return ((px - tx0) * 256, (py - ty0) * 256)
    else:
        img = Image.new('RGB', (W, H + 40), (250, 250, 248))

        def xy(lat, lng):
            return (M + (lng - ln0) / (ln1 - ln0) * (W - 2 * M),
                    H - M - (lat - la0) / (la1 - la0) * (H - 2 * M))

    d = ImageDraw.Draw(img)
    for seg in raw:
        d.line([xy(p['lat'], p['lng']) for p in seg], fill=(120, 120, 120), width=3)
    for idx, item in enumerate(snapped_by_seg):
        seg, kind = item if isinstance(item, tuple) else (item, '')
        if len(seg) < 2:
            continue
        col = colors.get(kind, colors['walk']) if isinstance(colors, dict) else colors[idx % len(colors)]
        d.line([xy(p['lat'], p['lng']) for p in seg], fill=col, width=3)
        if kind:
            mid = seg[len(seg) // 2]
            d.text(xy(mid['lat'], mid['lng']), kind.upper(), fill=col)
    d.text((M, H + 12), title + ('  [basemap=amap]' if base else '  [no basemap]'),
           fill=(30, 30, 30))
    img.save(out_png)
    print(f'  图: {out_png}' + (f'（底图 z={base[1]}）' if base else '（无底图）'))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', required=True)
    ap.add_argument('--user', required=True)
    ap.add_argument('--day', required=True)
    ap.add_argument('--out', default='/out')
    args = ap.parse_args()

    key = os.environ.get('AMAP_WEB_KEY', '').strip()
    c = sqlite3.connect(f'file:{args.db}?mode=ro', uri=True)
    c.row_factory = sqlite3.Row
    uid = c.execute('SELECT id FROM users WHERE username=? OR name=? OR id=?',
                    (args.user, args.user, args.user)).fetchone()['id']
    tr = peer_agg.track_for(c, uid, args.day, POLICY)
    pts = sorted(tr.get('points') or [], key=lambda p: p['ts'])
    stays = tr.get('stays') or []
    segs = segments(pts, stays)

    print(f'== {args.user} {args.day} ==')
    print(f'  店内点 {len(pts)} | 停留 {len(stays)} | 移动段 {len(segs)} '
          f'| 移动段点数 {sum(len(s) for s in segs)}')
    print(f'  原始移动里程 {sum(dist(s) for s in segs):.1f} m')

    if not key:
        print('  KEY_MISSING：未提供 AMAP_WEB_KEY，先出基线（未纠偏）')
        Path(args.out).mkdir(parents=True, exist_ok=True)
        render(segs, [], os.path.join(args.out, f'baseline_{args.day}.png'),
               f'{args.day} raw moving segments (no snap)', [(30, 120, 220)])
        for i, s in enumerate(segs):
            kind, med = transport_of(s)
            print(f'   seg{i+1}: {len(s)} 点 {dist(s):.0f} m 中位速度 {med:.2f} m/s → {kind}')
        return 0

    Path(args.out).mkdir(parents=True, exist_ok=True)
    snapped, failed, sent = [], 0, 0
    colors = {'walk': (34, 160, 90), 'bike': (230, 150, 30), 'car': (200, 60, 60)}
    for i, seg in enumerate(segs):
        pl = build_payload(seg)
        got, err = [], None
        for piece in chunk(pl):
            sent += len(piece)
            part, e = snap(piece, key)
            if e:
                err = e
                break
            got.extend(part)
        kind, med = transport_of(seg)
        if err:
            failed += 1
            print(f'   seg{i+1}: 纠偏失败（{err}）→ 原样使用 {len(seg)} 点')
            snapped.append((seg, kind))
        else:
            sp = [{'lat': float(p['y']), 'lng': float(p['x'])} for p in got]
            snapped.append((sp, kind))
            print(f'   seg{i+1}: {len(seg)}→{len(sp)} 点 | 原 {dist(seg):.0f} m → 吸附 {dist(sp):.0f} m '
                  f'| 中位速度 {med:.2f} m/s → {kind}')
    raw_m = sum(dist(s) for s in segs)
    snp_m = sum(dist(s[0] if isinstance(s, tuple) else s) for s in snapped)
    print(f'  合计：原始 {raw_m:.1f} m → 吸附 {snp_m:.1f} m'
          f' | 纠偏送出点数 {sent} | 失败段 {failed}/{len(segs)}')
    render(segs, snapped, os.path.join(args.out, f'snap_{args.day}.png'),
           f'{args.day} raw(grey) vs snapped(colored by transport)', [(30, 120, 220)])
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
