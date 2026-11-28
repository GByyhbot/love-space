"""高德影子定位评估分析脚本（高德定位评估令 · 裁定表生成器）。

读取 `amap-shadow-eval.jsonl`（原生与高德同刻对齐采样、同为 GCJ-02 坐标系），
自动切分或按指定时段输出静止段对比表、出行段里程/分叉统计、与裁定结论。
"""
import argparse
import json
import math
from pathlib import Path


def haversine_m(lat1, lng1, lat2, lng2):
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(a)))


def quantile(vals, q):
    if not vals:
        return None
    s = sorted(vals)
    idx = (len(s) - 1) * q
    lo, hi = int(math.floor(idx)), int(math.ceil(idx))
    if lo == hi:
        return s[lo]
    return s[lo] + (s[hi] - s[lo]) * (idx - lo)


def scatter_stats(coords):
    """距离本源段中心的中位距离与 P90。"""
    if not coords:
        return None, None
    c_lat = sum(la for la, _ in coords) / len(coords)
    c_lng = sum(ln for _, ln in coords) / len(coords)
    dists = [haversine_m(la, ln, c_lat, c_lng) for la, ln in coords]
    return quantile(dists, 0.5), quantile(dists, 0.9)


def path_distance_m(coords):
    return sum(haversine_m(*a, *b) for a, b in zip(coords, coords[1:]))


def segment_rows(rows, min_stay_sec=4 * 3600, stay_radius_m=200.0):
    """按原生位置自动切分静止段（>=4h）与其余出行段。"""
    stationary_segs = []
    travel_rows = []
    n = len(rows)
    i = 0
    while i < n:
        c_lat = rows[i]['native_lat']
        c_lng = rows[i]['native_lng']
        j = i
        while j + 1 < n:
            nxt = rows[j + 1]
            if haversine_m(c_lat, c_lng, nxt['native_lat'], nxt['native_lng']) > stay_radius_m:
                break
            j += 1
            seg = rows[i:j + 1]
            c_lat = sum(r['native_lat'] for r in seg) / len(seg)
            c_lng = sum(r['native_lng'] for r in seg) / len(seg)
        span_sec = (rows[j]['native_ts_ms'] - rows[i]['native_ts_ms']) / 1000.0
        if span_sec >= min_stay_sec and (j - i + 1) >= 4:
            stationary_segs.append(rows[i:j + 1])
        else:
            travel_rows.extend(rows[i:j + 1])
        i = j + 1
    return stationary_segs, travel_rows


def summarize_stationary_segment(idx, seg):
    n_total = len(seg)
    nat_ok = [r for r in seg if r.get('native_acc') is not None and float(r['native_acc']) <= 50.0]
    amp_ok = [r for r in seg if r.get('amap_ok') is True and r.get('amap_lat') is not None]

    nat_coords = [(r['native_lat'], r['native_lng']) for r in seg]
    amp_coords = [(r['amap_lat'], r['amap_lng']) for r in amp_ok]

    nat_med, nat_p90 = scatter_stats(nat_coords)
    amp_med, amp_p90 = scatter_stats(amp_coords)

    nat_acc_med = quantile([float(r['native_acc']) for r in seg if r.get('native_acc') is not None], 0.5)
    amp_acc_med = quantile([float(r['amap_acc']) for r in amp_ok if r.get('amap_acc') is not None], 0.5)

    nat_rate = len(nat_ok) / n_total if n_total else 0.0
    amp_rate = len(amp_ok) / n_total if n_total else 0.0

    reduction = ((nat_med - amp_med) / nat_med) if (nat_med and amp_med is not None and nat_med > 0) else None
    ratio = (nat_med / amp_med) if (nat_med and amp_med and amp_med > 0) else None
    return {
        'idx': idx,
        'count': n_total,
        'span_h': (seg[-1]['native_ts_ms'] - seg[0]['native_ts_ms']) / 3_600_000.0,
        'nat_med': nat_med,
        'nat_p90': nat_p90,
        'amp_med': amp_med,
        'amp_p90': amp_p90,
        'nat_acc_med': nat_acc_med,
        'amp_acc_med': amp_acc_med,
        'nat_rate': nat_rate,
        'amp_rate': amp_rate,
        'reduction': reduction,
        'ratio': ratio,
    }


def main():
    ap = argparse.ArgumentParser(description='Analyze amap-shadow-eval.jsonl paired location logs')
    ap.add_argument('jsonl', help='Path to amap-shadow-eval.jsonl')
    ap.add_argument('--min-stay-hours', type=float, default=4.0)
    ap.add_argument('--battery-delta-pct', type=float, default=None, help='Optional measured battery delta (%%)')
    args = ap.parse_args()

    rows = []
    for line in Path(args.jsonl).read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if obj.get('coord_sys') != 'GCJ-02':
            raise SystemExit(f'坐标系不一致：{obj.get("coord_sys")} != GCJ-02')
        rows.append(obj)

    if not rows:
        raise SystemExit('日志为空')

    rows.sort(key=lambda r: r['native_ts_ms'])
    stays, travel = segment_rows(rows, min_stay_sec=args.min_stay_hours * 3600.0)

    print(f'总配对样本: {len(rows)} 条 | 覆盖时长: {(rows[-1]["native_ts_ms"] - rows[0]["native_ts_ms"]) / 3600000:.2f} h | 坐标系: GCJ-02')
    print('\n=== 静止段逐段对比表 ===')
    all_pass_scatter = bool(stays)
    all_pass_rate = bool(stays)
    for idx, seg in enumerate(stays, 1):
        s = summarize_stationary_segment(idx, seg)
        red_str = f'{s["reduction"] * 100:.1f}%' if s['reduction'] is not None else 'N/A'
        ratio_str = f'{s["ratio"]:.2f}x' if s['ratio'] is not None else 'N/A'
        print(
            f'段#{s["idx"]} ({s["span_h"]:.1f}h, {s["count"]}条) | '
            f'原生 med/P90={s["nat_med"]:.1f}/{s["nat_p90"]:.1f}m acc中位={s["nat_acc_med"]:.1f}m 成功率={s["nat_rate"]*100:.1f}% | '
            f'高德 med/P90={s["amp_med"] or 0:.1f}/{s["amp_p90"] or 0:.1f}m acc中位={s["amp_acc_med"] or 0:.1f}m 成功率={s["amp_rate"]*100:.1f}% | '
            f'降幅={red_str} ({ratio_str})'
        )
        if s['reduction'] is None or s['reduction'] < 0.40:
            all_pass_scatter = False
        if s['amp_rate'] < s['nat_rate']:
            all_pass_rate = False

    print('\n=== 出行段对比 ===')
    if len(travel) >= 2:
        nat_travel_dist = path_distance_m([(r['native_lat'], r['native_lng']) for r in travel])
        amp_travel = [(r['amap_lat'], r['amap_lng']) for r in travel if r.get('amap_ok') and r.get('amap_lat') is not None]
        amp_travel_dist = path_distance_m(amp_travel)
        pair_dists = [r['pair_dist_m'] for r in travel if r.get('pair_dist_m') is not None]
        print(
            f'出行点数={len(travel)} (高德成功 {len(amp_travel)}) | '
            f'原生里程={nat_travel_dist:.1f}m | 高德里程={amp_travel_dist:.1f}m | '
            f'逐点偏差 med={quantile(pair_dists, 0.5) or 0:.1f}m P90={quantile(pair_dists, 0.9) or 0:.1f}m max={max(pair_dists) if pair_dists else 0:.1f}m'
        )
    else:
        print('暂无 ≥2 点的出行段')

    print('\n=== 裁定参考 ===')
    batt_ok = args.battery_delta_pct is not None and args.battery_delta_pct <= 2.0
    print(f'散布中位降幅 ≥40%: {all_pass_scatter} | 高德成功率 ≥ 原生: {all_pass_rate} | 电量增量 ≤2%: {batt_ok if args.battery_delta_pct is not None else "待填 --battery-delta-pct"}')
    print('日志样本(前3条):')
    for r in rows[:3]:
        print(' ', json.dumps(r, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
