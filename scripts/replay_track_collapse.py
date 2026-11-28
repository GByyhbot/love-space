"""只读回放与对比图生成脚本（定位波动二修令验收项 6–8）。

严格只读：连接线上只读副本或测试 SQLite 时使用 `file:<path>?mode=ro`（uri=True），
绝不修改任何数据行。若本地无真实库，可用 `--synthetic-demo` 生成对比演示图验证脚本链路。
"""
import argparse
import datetime as dt
import math
import os
import random
import sqlite3
import sys
from pathlib import Path
from zoneinfo import ZoneInfo

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app import db, peer_agg  # noqa: E402


def _offset(lat, lng, north_m, east_m):
    return (
        lat + north_m / 111_320.0,
        lng + east_m / (111_320.0 * math.cos(math.radians(lat))),
    )


def _quantile(vals, q):
    if not vals:
        return 0.0
    s = sorted(vals)
    idx = (len(s) - 1) * q
    lo = int(math.floor(idx))
    hi = int(math.ceil(idx))
    if lo == hi:
        return s[lo]
    return s[lo] + (s[hi] - s[lo]) * (idx - lo)


def _parse_hhmm_window(day_str, window_str, tz):
    start_s, end_s = window_str.split('-', 1)
    base = dt.datetime.strptime(day_str, '%Y-%m-%d').replace(tzinfo=tz)
    sh, sm = (int(x) for x in start_s.split(':'))
    eh, em = (int(x) for x in end_s.split(':'))
    return (
        (base + dt.timedelta(hours=sh, minutes=sm)).timestamp(),
        (base + dt.timedelta(hours=eh, minutes=em)).timestamp(),
    )


def _load_user_day_ro(conn, user_id, day_str, tz):
    start = dt.datetime.strptime(day_str, '%Y-%m-%d').replace(tzinfo=tz).timestamp()
    end = start + peer_agg.DAY_SEC
    raw = conn.execute(
        'SELECT ts,lat,lng,acc,speed,place_name FROM peer_location_points '
        'WHERE user=? AND ((ts>=? AND ts<?) OR (ts>=? AND ts<?)) ORDER BY ts',
        (user_id, start, end, start * 1000.0, end * 1000.0),
    ).fetchall()
    return [
        {
            'ts': db.ts_to_sec(r['ts']),
            'lat': float(r['lat']),
            'lng': float(r['lng']),
            'acc': r['acc'],
            'speed': r['speed'],
            'place_name': (r['place_name'] or '').strip(),
        }
        for r in raw
    ]


def _resolve_user(conn, query):
    users = conn.execute('SELECT id,username,name FROM users').fetchall()
    q = (query or '').strip().lower()
    for u in users:
        if q in ((u['id'] or '').lower(), (u['username'] or '').lower(), (u['name'] or '').lower()):
            return u['id'], (u['name'] or u['username'] or u['id'])
    for u in users:
        if q and (q in (u['username'] or '').lower() or q in (u['name'] or '').lower()):
            return u['id'], (u['name'] or u['username'] or u['id'])
    raise SystemExit(f'未找到匹配用户 {query!r}，库内用户：{[dict(u) for u in users]}')


def analyze_day(rows, window_bounds=None, places=None):
    pts = peer_agg.filter_points(rows)
    stays, ranges = peer_agg.cluster_stays_with_ranges(pts)
    if places:
        for s in stays:
            best = None
            for p in places:
                r = float(p['radius'] or 150)
                d = peer_agg.haversine_m(s['lat'], s['lng'], p['lat'], p['lng'])
                if d <= r and (best is None or d < best[0]):
                    best = (d, p['name'])
            s['place_name'] = best[1] if best else ''
    display_pts = peer_agg.build_display_points(pts, stays, ranges)

    if window_bounds:
        ws, we = window_bounds
        pts_win = [p for p in pts if ws <= p['ts'] <= we]
        disp_win = [p for p in display_pts if ws <= p['ts'] <= we]
    else:
        pts_win = pts
        disp_win = display_pts

    pair_dists = [
        peer_agg.haversine_m(a['lat'], a['lng'], b['lat'], b['lng'])
        for a, b in zip(pts_win, pts_win[1:])
    ]
    speeds = [
        peer_agg.haversine_m(a['lat'], a['lng'], b['lat'], b['lng']) / (b['ts'] - a['ts'])
        for a, b in zip(pts_win, pts_win[1:])
        if b['ts'] > a['ts']
    ]
    accs = [float(p['acc']) for p in pts_win if p['acc'] is not None]
    return {
        'raw_count': len(rows),
        'filtered': pts,
        'filtered_win': pts_win,
        'display': display_pts,
        'display_win': disp_win,
        'stays': stays,
        'old_distance_m': round(peer_agg.total_distance_m(pts_win), 1),
        'new_distance_m': round(peer_agg.total_distance_m(disp_win), 1),
        'old_full_distance_m': round(peer_agg.total_distance_m(pts), 1),
        'new_full_distance_m': round(peer_agg.total_distance_m(display_pts), 1),
        'pair_dists': pair_dists,
        'speeds': speeds,
        'accs': accs,
    }


def render_compare_png(title, old_pts, new_pts, stays, old_dist, new_dist, out_path):
    w, h = 1120, 560
    img = Image.new('RGB', (w, h), (248, 249, 251))
    draw = ImageDraw.Draw(img)

    all_pts = old_pts + new_pts + stays
    if not all_pts:
        draw.text((40, 40), f'{title}: no points', fill=(40, 40, 40))
        img.save(out_path)
        return

    lats = [p['lat'] for p in all_pts]
    lngs = [p['lng'] for p in all_pts]
    min_lat, max_lat = min(lats), max(lats)
    min_lng, max_lng = min(lngs), max(lngs)
    c_lat = (min_lat + max_lat) / 2.0
    cos_lat = max(0.2, min(1.0, math.cos(math.radians(c_lat))))
    span_lat = max(max_lat - min_lat, 1e-3)
    span_lng = max((max_lng - min_lng) * cos_lat, 1e-3)
    c_lng = (min_lng + max_lng) / 2.0
    min_lat = c_lat - span_lat / 2.0
    min_lng = c_lng - (span_lng / cos_lat) / 2.0

    # Header bar
    draw.rectangle([0, 0, w, 54], fill=(24, 28, 36))
    draw.text((20, 18), f'{title}  |  Old: {old_dist:.1f} m  ->  New display: {new_dist:.1f} m  |  Stays: {len(stays)}', fill=(245, 247, 250))

    panels = [
        ('BEFORE (raw filtered points)', old_pts, (220, 68, 55), (20, 74, 540, 536)),
        ('AFTER (collapsed display_points)', new_pts, (30, 136, 92), (580, 74, 1100, 536)),
    ]
    for label, pts, color, box in panels:
        x0, y0, x1, y1 = box
        draw.rectangle(box, fill=(255, 255, 255), outline=(210, 215, 224), width=2)
        pad = 36
        pw = (x1 - x0) - 2 * pad
        ph = (y1 - y0) - 2 * pad
        scale = min(pw / span_lng, ph / span_lat)
        dx = x0 + pad + (pw - span_lng * scale) / 2.0
        dy = y0 + pad + (ph - span_lat * scale) / 2.0

        # Grid
        for g in range(1, 4):
            gx = x0 + (x1 - x0) * g // 4
            gy = y0 + (y1 - y0) * g // 4
            draw.line([(gx, y0 + 28), (gx, y1)], fill=(238, 241, 246), width=1)
            draw.line([(x0, gy), (x1, gy)], fill=(238, 241, 246), width=1)

        def to_px(lat, lng):
            px = dx + (lng - min_lng) * cos_lat * scale
            py = dy + (min_lat + span_lat - lat) * scale
            return (px, py)

        if len(pts) >= 2:
            coords = [to_px(p['lat'], p['lng']) for p in pts]
            draw.line(coords, fill=color, width=3)
            for px, py in coords:
                draw.ellipse([px - 2, py - 2, px + 2, py + 2], fill=color)
        elif len(pts) == 1:
            px, py = to_px(pts[0]['lat'], pts[0]['lng'])
            draw.ellipse([px - 5, py - 5, px + 5, py + 5], fill=color)

        for s in stays:
            sx, sy = to_px(s['lat'], s['lng'])
            draw.ellipse([sx - 8, sy - 8, sx + 8, sy + 8], fill=(255, 255, 255), outline=(35, 102, 210), width=3)
            draw.ellipse([sx - 3, sy - 3, sx + 3, sy + 3], fill=(35, 102, 210))

        draw.text((x0 + 14, y0 + 10), f'{label}  ({len(pts)} pts)', fill=(45, 52, 64))

    out_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path)


def _build_synthetic_days(tz):
    base_lat, base_lng = 31.2304, 121.4737
    rng = random.Random(286)

    # Synthetic 11-28 stationary day (00:35 - 10:36) with ~491m raw jitter inside 75m stay radius
    day28 = dt.datetime(2026, 11, 28, tzinfo=tz).timestamp()
    t0 = day28 + 35 * 60
    still_rows = []
    for i in range(18):
        if i in (4, 9, 13):
            dn, de, acc = rng.uniform(-55, 55), rng.uniform(-55, 55), 32.0
        else:
            dn, de, acc = rng.uniform(-12, 12), rng.uniform(-12, 12), 14.0
        la, ln = _offset(base_lat, base_lng, dn, de)
        still_rows.append({'ts': t0 + i * 2000.0, 'lat': la, 'lng': ln, 'acc': acc, 'speed': 0.0, 'place_name': '矿区宿舍'})

    # Synthetic 11-27 travel day (~6.3 km + 2 stays)
    day27 = dt.datetime(2026, 11, 27, tzinfo=tz).timestamp()
    travel_rows = []
    for i in range(6):
        la, ln = _offset(base_lat, base_lng, rng.uniform(-15, 15), rng.uniform(-15, 15))
        travel_rows.append({'ts': day27 + 7 * 3600 + i * 300, 'lat': la, 'lng': ln, 'acc': 12.0, 'speed': 0.0, 'place_name': '家'})
    for k in range(1, 22):
        la, ln = _offset(base_lat, base_lng, rng.uniform(-6, 6), k * 295.0)
        travel_rows.append({'ts': day27 + 9 * 3600 + k * 45, 'lat': la, 'lng': ln, 'acc': 10.0, 'speed': 6.5, 'place_name': ''})
    for i in range(8):
        la, ln = _offset(base_lat, base_lng, rng.uniform(-20, 20), 6300.0 + rng.uniform(-20, 20))
        travel_rows.append({'ts': day27 + 9 * 3600 + 21 * 45 + 300 + i * 900, 'lat': la, 'lng': ln, 'acc': 15.0, 'speed': 0.0, 'place_name': '矿区'})
    return still_rows, travel_rows


def _print_summary(label, res):
    dists = res['pair_dists']
    accs = res['accs']
    speeds = res['speeds']
    over40 = sum(1 for d in dists if d > 40.0)
    print(f'=== {label} ===')
    print(f'  raw_points={res["raw_count"]}, filtered={len(res["filtered_win"])}, display={len(res["display_win"])}')
    print(f'  old_distance_m={res["old_distance_m"]} m  ->  new_display_distance_m={res["new_distance_m"]} m')
    if dists:
        print(f'  pairwise_dist_m: med={_quantile(dists, 0.5):.1f}, p90={_quantile(dists, 0.9):.1f}, max={max(dists):.1f}, >40m={over40}/{len(dists)}')
    if accs:
        print(f'  acc_m: min={min(accs):.1f}, med={_quantile(accs, 0.5):.1f}, p90={_quantile(accs, 0.9):.1f}, max={max(accs):.1f}')
    if speeds:
        print(f'  implied_speed_mps: med={_quantile(speeds, 0.5):.2f}, max={max(speeds):.2f} (<45m/s gate)')
    print(f'  stays={len(res["stays"])}: ' + ', '.join(f'{s.get("place_name") or "停留点"}({s["duration_sec"]}s, {s["points"]}pts)' for s in res['stays']))


def main():
    ap = argparse.ArgumentParser(description='Read-only replay comparison for track display collapse')
    ap.add_argument('--db', help='Path to read-only SQLite copy of love.db')
    ap.add_argument('--user', default='yang', help='Target user id / username / display name')
    ap.add_argument('--still-day', default='2026-11-28')
    ap.add_argument('--still-window', default='00:35-10:36')
    ap.add_argument('--travel-day', default='2026-11-27')
    ap.add_argument('--out', default=str(ROOT / 'output' / 'track-collapse-demo'))
    ap.add_argument('--synthetic-demo', action='store_true', help='Run on synthetic 11-28/11-27 demo dataset')
    args = ap.parse_args()

    out_dir = Path(args.out)
    tz = ZoneInfo('Asia/Shanghai')

    if args.synthetic_demo:
        still_rows, travel_rows = _build_synthetic_days(tz)
        wb = _parse_hhmm_window(args.still_day, args.still_window, tz)
        still_res = analyze_day(still_rows, window_bounds=wb)
        travel_res = analyze_day(travel_rows)
        _print_summary(f'SYNTHETIC {args.still_day} ({args.still_window})', still_res)
        _print_summary(f'SYNTHETIC {args.travel_day} (travel)', travel_res)
        render_compare_png(
            f'SYNTHETIC {args.still_day} {args.still_window}',
            still_res['filtered_win'], still_res['display_win'], still_res['stays'],
            still_res['old_distance_m'], still_res['new_distance_m'],
            out_dir / 'compare_still.png',
        )
        render_compare_png(
            f'SYNTHETIC {args.travel_day} travel',
            travel_res['filtered_win'], travel_res['display_win'], travel_res['stays'],
            travel_res['old_distance_m'], travel_res['new_distance_m'],
            out_dir / 'compare_travel.png',
        )
        print(f'Saved comparison images to {out_dir}')
        return 0

    if not args.db:
        raise SystemExit('请指定 --db <只读副本路径> 或使用 --synthetic-demo')
    conn = sqlite3.connect(f'file:{args.db}?mode=ro', uri=True)
    conn.row_factory = sqlite3.Row
    try:
        tz = peer_agg.space_tz(conn)
        uid, uname = _resolve_user(conn, args.user)
        places = conn.execute('SELECT name,lat,lng,radius FROM peer_places').fetchall()
        still_rows = _load_user_day_ro(conn, uid, args.still_day, tz)
        travel_rows = _load_user_day_ro(conn, uid, args.travel_day, tz)
    finally:
        conn.close()

    wb = _parse_hhmm_window(args.still_day, args.still_window, tz)
    still_res = analyze_day(still_rows, window_bounds=wb, places=places)
    travel_res = analyze_day(travel_rows, places=places)
    _print_summary(f'{uname} {args.still_day} ({args.still_window})', still_res)
    _print_summary(f'{uname} {args.travel_day} (travel)', travel_res)

    render_compare_png(
        f'{uname} {args.still_day} {args.still_window}',
        still_res['filtered_win'], still_res['display_win'], still_res['stays'],
        still_res['old_distance_m'], still_res['new_distance_m'],
        out_dir / 'compare_still.png',
    )
    render_compare_png(
        f'{uname} {args.travel_day} travel',
        travel_res['filtered_win'], travel_res['display_win'], travel_res['stays'],
        travel_res['old_distance_m'], travel_res['new_distance_m'],
        out_dir / 'compare_travel.png',
    )
    print(f'Saved real-DB comparison images to {out_dir}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
