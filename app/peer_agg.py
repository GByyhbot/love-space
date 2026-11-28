"""2.8.7 全量施工令 · 聚合读侧（轨迹 / 应用使用）。

两条聚合都在读时按**属主 policy** 裁剪，绝不下发越档字段：

- `track_for()`：读侧滤波 → 距离 → 停留聚类（80m / 5min）→ `peer_places`
  命名 → 速度分段概要。street 档不返回点列与折线，只给网格化停留点与
  街区级最新位置；off 档由调用方按既有 `closed_off` 明示。
- `usage_daily_for()`：亮屏/解锁复用 `peer_usage_daily`（与 state-daily
  同源同数，不造第二套口径）+ 由 `state.screen` 事件算 24 小时分布与最长
  会话 + 当日 Top5 + 会话流 + 网络记录 + 较昨日差值。

🔴 地名只许来自 `peer_places`：匹配不上就是空名（端上显示「停留点」），
**不许编地名、不许调外部逆地理**（红线 4）。
"""

import datetime as dt
import json
import math
import time
from zoneinfo import ZoneInfo

from . import db

# 轨迹滤波（既定参数，令文 §3）
MAX_ACC_M = 50.0
MAX_IMPLIED_SPEED = 45.0  # m/s ≈ 162 km/h
# 停留聚类
STAY_RADIUS_M = 80.0
STAY_MIN_SEC = 300.0
# 网格化精度（≈500m）
GRID_STEP = 0.005
# 速度分段阈值（m/s）
STILL_MAX = 0.5
WALK_MAX = 2.5

DAY_SEC = 86400.0


def space_tz(c):
    return ZoneInfo((db.setting(c, 'space') or {}).get('timezone', 'Asia/Shanghai'))


def day_bounds(c, day):
    """YYYY-MM-DD → [start, end) unix 秒（空间时区）。"""
    tz = space_tz(c)
    start = dt.datetime.strptime(day, '%Y-%m-%d').replace(tzinfo=tz).timestamp()
    return start, start + DAY_SEC


def prev_day(day):
    d = dt.datetime.strptime(day, '%Y-%m-%d').date() - dt.timedelta(days=1)
    return d.strftime('%Y-%m-%d')


def haversine_m(lat1, lng1, lat2, lng2):
    r = 6371000.0

    def rad(d):
        return d * math.pi / 180.0

    dlat = rad(lat2 - lat1)
    dlng = rad(lng2 - lng1)
    a = (math.sin(dlat / 2) ** 2
         + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dlng / 2) ** 2)
    return 2 * r * math.asin(min(1.0, math.sqrt(a)))


def grid_round(v):
    """坐标网格化到 GRID_STEP（0.005° ≈ 500m）；street 档唯一的坐标形态。"""
    return round(float(v) / GRID_STEP) * GRID_STEP


def _payload(row):
    raw = row['payload'] if 'payload' in row.keys() else ''
    if not raw:
        return {}
    try:
        val = json.loads(raw)
    except (ValueError, TypeError):
        return {}
    return val if isinstance(val, dict) else {}


# ── 轨迹 ────────────────────────────────────────────────────────────

def filter_points(rows):
    """读侧滤波：精度太差（acc>50m）丢弃；相邻点隐含速度 >45m/s 判漂移丢弃。

    返回按 ts 升序的新列表（不改入参）。
    """
    pts = []
    for r in rows:
        acc = r['acc']
        if acc is not None and float(acc) > MAX_ACC_M:
            continue
        pts.append({'ts': float(r['ts']), 'lat': float(r['lat']),
                    'lng': float(r['lng']),
                    'acc': float(acc) if acc is not None else None,
                    'speed': float(r['speed']) if r['speed'] is not None else None,
                    'place_name': (r.get('place_name') or '').strip()})
    pts.sort(key=lambda p: p['ts'])
    kept = []
    for p in pts:
        if kept:
            prev = kept[-1]
            dts = p['ts'] - prev['ts']
            if dts > 0:
                dist = haversine_m(prev['lat'], prev['lng'], p['lat'], p['lng'])
                if dist / dts > MAX_IMPLIED_SPEED:
                    continue  # 瞬移点：判漂移丢弃
        kept.append(p)
    return kept


def total_distance_m(points):
    total = 0.0
    for a, b in zip(points, points[1:]):
        total += haversine_m(a['lat'], a['lng'], b['lat'], b['lng'])
    return total


def _safe_acc(pt):
    acc = pt.get('acc')
    if acc is None:
        return 50.0
    try:
        v = float(acc)
        return max(v, 1.0) if v > 0 else 50.0
    except (TypeError, ValueError):
        return 50.0


def select_real_anchor(members):
    """在停留簇真实采样点中，选离 1/acc^2 加权中心最近的那一条（与端侧同口径）。

    绝不用算出来的质心冒充采样点。
    """
    if not members:
        raise ValueError('members must not be empty')
    if len(members) == 1:
        return members[0]
    sum_w = 0.0
    sum_lat = 0.0
    sum_lng = 0.0
    for m in members:
        acc_safe = _safe_acc(m)
        w = 1.0 / (acc_safe * acc_safe)
        sum_w += w
        sum_lat += w * float(m['lat'])
        sum_lng += w * float(m['lng'])
    c_lat = sum_lat / sum_w
    c_lng = sum_lng / sum_w

    best = members[0]
    best_acc = _safe_acc(best)
    best_dist = haversine_m(float(best['lat']), float(best['lng']), c_lat, c_lng)
    for cand in members[1:]:
        cand_acc = _safe_acc(cand)
        d = haversine_m(float(cand['lat']), float(cand['lng']), c_lat, c_lng)
        if d < best_dist - 1e-6 or (abs(d - best_dist) <= 1e-6 and cand_acc < best_acc):
            best = cand
            best_acc = cand_acc
            best_dist = d
    return best


def cluster_stays_with_ranges(points, *, radius=STAY_RADIUS_M, min_sec=STAY_MIN_SEC):
    """停留聚类：连续点在 radius 内累计 ≥min_sec 即一个停留点。

    锚点取簇内真实采样点中离 1/acc^2 加权中心最近的那个；
    `left_at` 取簇后第一个点的时刻，**当天最后一簇给 null**。
    返回 `(stays, ranges)`，其中 `ranges` 为 `[(start_idx, end_idx, anchor_pt), ...]`。
    """
    stays = []
    ranges = []
    n = len(points)
    i = 0
    while i < n:
        members = [points[i]]
        j = i
        c_lat, c_lng = points[i]['lat'], points[i]['lng']
        while j + 1 < n:
            nxt = points[j + 1]
            if haversine_m(c_lat, c_lng, nxt['lat'], nxt['lng']) > radius:
                break
            j += 1
            members.append(nxt)
            c_lat = sum(m['lat'] for m in members) / len(members)
            c_lng = sum(m['lng'] for m in members) / len(members)
        span = points[j]['ts'] - points[i]['ts']
        if span >= min_sec and len(members) >= 2:
            anchor = select_real_anchor(members)
            left_at = points[j + 1]['ts'] if j + 1 < n else None
            stays.append({
                'lat': float(anchor['lat']),
                'lng': float(anchor['lng']),
                'arrived_at': points[i]['ts'],
                'left_at': left_at,
                'duration_sec': int(span),
                'points': len(members),
            })
            ranges.append((i, j, anchor))
        i = j + 1
    return stays, ranges


def cluster_stays(points, *, radius=STAY_RADIUS_M, min_sec=STAY_MIN_SEC):
    """停留聚类：返回 stays 列表（锚点与展示线共用同一真实采样点）。"""
    stays, _ = cluster_stays_with_ranges(points, radius=radius, min_sec=min_sec)
    return stays


def build_display_points(points, stays, ranges):
    """生成展示线点列：停留窗内的点整体塌缩为该停留锚点，移动段保留原有点列。

    - 停留起止保留两个锚点端点（`ts = points[i]['ts']` 与 `points[j]['ts']`），
      使停留段距离 = 0、且时间轴回放在停留窗内停在锚点处不动；
    - 展示线锚点坐标严格等于 `stays[k]` 的 `(lat, lng)`，绝不两套坐标打架；
    - 原始 `points` 列表不改不删。
    """
    if not points:
        return []
    if not ranges:
        return [dict(p) for p in points]

    display = []
    cursor = 0
    for idx, (start_i, end_i, anchor) in enumerate(ranges):
        while cursor < start_i:
            display.append(dict(points[cursor]))
            cursor += 1
        stay = stays[idx]
        lat = float(stay['lat'])
        lng = float(stay['lng'])
        pn = (stay.get('place_name') or anchor.get('place_name') or '').strip()
        acc = anchor.get('acc')
        display.append({
            'ts': float(points[start_i]['ts']),
            'lat': lat,
            'lng': lng,
            'acc': acc,
            'speed': 0.0,
            'place_name': pn,
        })
        if end_i > start_i:
            display.append({
                'ts': float(points[end_i]['ts']),
                'lat': lat,
                'lng': lng,
                'acc': acc,
                'speed': 0.0,
                'place_name': pn,
            })
        cursor = end_i + 1
    while cursor < len(points):
        display.append(dict(points[cursor]))
        cursor += 1
    return display


def name_stays(c, stays, points=None):
    """用 `peer_places` 给停留点命名；未命中围栏再取停留窗内点位 `place_name`，
    都没有就留空名（历史点不追溯编造，端上兜底写「停留点」）。"""
    places = c.execute('SELECT name,lat,lng,radius FROM peer_places').fetchall()
    pts = points or []
    for s in stays:
        best = None
        for p in places:
            r = float(p['radius'] or 150)
            d = haversine_m(s['lat'], s['lng'], p['lat'], p['lng'])
            if d <= r and (best is None or d < best[0]):
                best = (d, p['name'])
        if best:
            s['place_name'] = best[1]
            continue
        arrived = float(s['arrived_at'])
        left = s.get('left_at')
        counts = {}
        latest_ts = {}
        for pt in pts:
            ts = float(pt['ts'])
            if ts < arrived:
                continue
            if left is not None and ts >= float(left):
                continue
            pn = (pt.get('place_name') or '').strip()
            if not pn:
                continue
            counts[pn] = counts.get(pn, 0) + 1
            if ts >= latest_ts.get(pn, -1.0):
                latest_ts[pn] = ts
        if counts:
            s['place_name'] = max(counts, key=lambda k: (counts[k], latest_ts[k]))
        else:
            s['place_name'] = ''
    return stays


def speed_segments(points):
    """按相邻点速度分段（still/walk/drive），供端上折线着色。

    口径（本令最终裁定）：服务端只给分段区间（起止 ts + 类型 + 距离），
    不给逐点类型——端上按 ts 落在哪段决定实线/虚线，避免逐点下发。
    """
    segs = []
    for a, b in zip(points, points[1:]):
        dts = b['ts'] - a['ts']
        if dts <= 0:
            continue
        dist = haversine_m(a['lat'], a['lng'], b['lat'], b['lng'])
        v = dist / dts
        kind = 'still' if v < STILL_MAX else ('walk' if v <= WALK_MAX else 'drive')
        if segs and segs[-1]['type'] == kind:
            segs[-1]['end_ts'] = b['ts']
            segs[-1]['distance_m'] += dist
        else:
            segs.append({'type': kind, 'start_ts': a['ts'], 'end_ts': b['ts'],
                         'distance_m': dist})
    for s in segs:
        s['distance_m'] = round(s['distance_m'], 1)
    return segs


def empty_track():
    """关闭/停用时的空壳轨迹（**字段齐、值为空**，端上不用判 key 是否存在）。"""
    return {'level': 'off', 'points': [], 'stays': [], 'segments': [],
            'distance_m': 0.0, 'display_points': [], 'display_segments': [],
            'display_distance_m': 0.0, 'latest': None}


def track_for(c, user_id, day, policy):
    """某人的当日轨迹（已按 policy 裁剪）。返回 dict（供调用方包 closed_off）。

    · exact：原始点列（兼容旧版）+ 展示线（停留窗塌缩为锚点，移动段保留）+ 距离 + 停留点 + 分段；
    · street：**无点列**（含展示线空），只有网格化停留点与街区级最新位置；
    · off：由调用方按既有 `closed_off` 明示（这里返回空壳）。
    """
    level = policy.get('location_level', 'exact')
    start, end = day_bounds(c, day)
    # 🔴 读侧防御常驻（轨迹时间戳单位修复令，不许以后顺手删）：写侧已归一为秒、
    # 存量已迁移，但仍把同一天的**毫秒区间**一并捞出并按 ts>1e11 → /1000 换算——
    # 防迁移漏网、老备份恢复、或绕过写侧的老数据让轨迹页再次「这一天没有轨迹记录」。
    raw = c.execute(
        'SELECT ts,lat,lng,acc,speed,place_name FROM peer_location_points '
        'WHERE user=? AND ((ts>=? AND ts<?) OR (ts>=? AND ts<?)) ORDER BY ts',
        (user_id, start, end, start * 1000.0, end * 1000.0)).fetchall()
    rows = [{'ts': db.ts_to_sec(r['ts']), 'lat': r['lat'], 'lng': r['lng'],
             'acc': r['acc'], 'speed': r['speed'],
             'place_name': (r['place_name'] or '').strip()} for r in raw]
    if level == 'off':
        return empty_track()

    if level == 'street':
        pts = filter_points(rows)
        stays = name_stays(c, cluster_stays(pts), pts)
        for s in stays:
            s['lat'] = grid_round(s['lat'])
            s['lng'] = grid_round(s['lng'])
        latest = c.execute(
            'SELECT lat,lng,place_name,updated FROM peer_location_latest WHERE user=?',
            (user_id,)).fetchone()
        return {
            'level': 'street',
            'points': [],  # 街道档绝不下发原始点列
            'stays': stays,
            'segments': [],
            'distance_m': None,  # 不足 500m 的精度不提供，端上不显示距离
            'display_points': [],
            'display_segments': [],
            'display_distance_m': None,
            'latest': ({'lat': grid_round(latest['lat']),
                        'lng': grid_round(latest['lng']),
                        'place_name': (latest['place_name'] or '').strip(),
                        'updated': db.ts_to_sec(latest['updated'])} if latest else None),
        }

    pts = filter_points(rows)
    stays, stay_ranges = cluster_stays_with_ranges(pts)
    stays = name_stays(c, stays, pts)
    display_pts = build_display_points(pts, stays, stay_ranges)
    latest = c.execute(
        'SELECT lat,lng,place_name,updated FROM peer_location_latest WHERE user=?',
        (user_id,)).fetchone()
    return {
        'level': 'exact',
        'points': pts,
        'stays': stays,
        'segments': speed_segments(pts),
        'distance_m': round(total_distance_m(pts), 1),
        'display_points': display_pts,
        'display_segments': speed_segments(display_pts),
        'display_distance_m': round(total_distance_m(display_pts), 1),
        'latest': ({'lat': latest['lat'], 'lng': latest['lng'],
                    'place_name': (latest['place_name'] or '').strip(),
                    'updated': db.ts_to_sec(latest['updated'])} if latest else None),
    }


# ── 一套账：区间工具 + 统一对账派生（2.8.7 傍晚批 1-2）─────────────
# 全部 5 个口径（总量/最长/会话流/Top5/正在使用）都由 reconcile_usage_day
# 的单一份账派生，从构造上锁死恒等式：
#   正在使用 ≤ 最长连续 ≤ 总量；Top5 合计 ≤ 全部应用合计 ≤ 总量

def _merge_intervals(intervals, gap=1.0):
    """合并重叠或间隙 ≤gap 的区间，返回有序互斥列表 [(s, e), ...]。"""
    items = sorted((float(a), float(b)) for a, b in intervals if float(b) > float(a))
    out = []
    for s, e in items:
        if out and s <= out[-1][1] + gap:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [(a, b) for a, b in out]


def _intersect_intervals(interval, windows):
    s, e = float(interval[0]), float(interval[1])
    out = []
    for ws, we in windows:
        a, b = max(s, ws), min(e, we)
        if b > a:
            out.append((a, b))
    return out


def _subtract_intervals(intervals, mask):
    """intervals - mask（都按区间对处理）。"""
    out = []
    for s, e in intervals:
        cur = [(float(s), float(e))]
        for ms, me in mask:
            nxt = []
            for a, b in cur:
                if me <= a or ms >= b:
                    nxt.append((a, b))
                    continue
                if a < ms:
                    nxt.append((a, ms))
                if me < b:
                    nxt.append((me, b))
            cur = nxt
            if not cur:
                break
        out.extend(cur)
    return [(a, b) for a, b in out if b - a > 0]


def _kind_rows(c, user_id, kind, lo, hi):
    """按类型取事件行；带毫秒防御（ts 可能是 ms）。ts 归一为秒。"""
    # 上界取 hi+1 做闭区间（`ts=?` 的边界事件——如正好落在 now 的那条 usage.now——
    # 不能被排掉，否则「正在使用」永判无）
    rows = c.execute(
        "SELECT ts,payload FROM peer_events WHERE user=? AND type=? AND "
        '((ts>=? AND ts<?) OR (ts>=? AND ts<?)) ORDER BY ts',
        (user_id, kind, lo, hi + 1.0, lo * 1000.0, (hi + 1.0) * 1000.0)).fetchall()
    out = []
    for r in rows:
        ts = db.ts_to_sec(r['ts'])
        if lo - 1 <= ts <= hi + 1:
            out.append({'ts': ts, 'p': _payload(r)})
    return out


def _hourly_from_windows(windows, start, end):
    hourly = [0] * 24
    for s, e in windows:
        cur = float(s)
        while cur < e:
            idx = int((cur - start) // 3600)
            if idx < 0 or idx > 23:
                break
            chunk_end = min(float(e), start + (idx + 1) * 3600)
            hourly[idx] += int(round(chunk_end - cur))
            cur = chunk_end
    return hourly


def reconcile_usage_day(c, user_id, day, policy, now=None):
    """当日使用「一套账」：唯一事实源，5 个口径全部由此派生。

    只读；不写 peer_usage_daily；全无明细时才回退汇总列（且 top 合计 ≤ 总量）。
    policy 的档位裁剪仍由 usage_daily_for 负责（这里出全量账本）。
    """
    start, end = day_bounds(c, day)
    now_ts = float(now if now is not None else time.time())
    day_cap = min(float(end), now_ts)
    is_today = start <= now_ts < end
    lo, hi = float(start) - 6 * 3600, float(end) + 6 * 3600

    # ── 步骤 1：明细归一 ──
    closed_windows = []
    last_off = None
    for r in _kind_rows(c, user_id, 'state.screen', lo, hi):
        sec, ts, p = r['p'].get('session_sec'), r['ts'], r['p']
        if ts <= day_cap and (p.get('on') is False or
                              (isinstance(sec, (int, float)) and sec > 0)):
            last_off = max(last_off or 0.0, ts)
        if isinstance(sec, (int, float)) and sec > 0:
            s0, e0 = max(float(start), ts - float(sec)), min(day_cap, ts)
            if e0 > s0:
                closed_windows.append((s0, e0))
    closed_screen_windows = _merge_intervals(closed_windows)

    raw_sessions = []
    for r in _kind_rows(c, user_id, 'usage.session', lo, hi):
        p, ts = r['p'], r['ts']
        if p.get('start') is not None:
            s0 = db.ts_to_sec(p['start'])
        else:
            s0 = ts - float(p.get('dur') or 0)
        e0 = db.ts_to_sec(p['end']) if p.get('end') is not None else ts
        a, b = max(float(start), float(s0)), min(day_cap, float(e0))
        if b <= a:
            continue
        raw_sessions.append({
            'app': str(p.get('app') or '').strip() or '某个应用',
            'masked': p.get('masked') is True,
            'start': a, 'end': b, 'ts': ts,
        })

    now_events = []
    for r in _kind_rows(c, user_id, 'usage.now', lo, day_cap):
        p, ts = r['p'], r['ts']
        app = str(p.get('app') or '').strip()
        if not app:
            continue
        since = db.ts_to_sec(p['since']) if p.get('since') is not None else ts
        now_events.append({'app': app, 'masked': p.get('masked') is True,
                           'since': float(since), 'ts': ts})

    # ── 步骤 2：正在使用（live_session）校验 ──
    live = None
    latest = now_events[-1] if now_events else None
    if is_today and latest:
        dead = False
        if last_off is not None:
            if latest['ts'] <= last_off + 5.0:
                dead = True
            elif latest['since'] < last_off:
                dead = True
        if not dead:
            for s_ in raw_sessions:
                if s_['end'] >= latest['since'] and (
                        s_['end'] >= latest['ts'] - 2.0 or s_['start'] > latest['since']):
                    dead = True
                    break
        if not dead and now_ts - latest['ts'] > 600:
            dead = True
        if not dead:
            live_start = max(float(start), latest['since'], last_off or float(start))
            if day_cap - live_start >= 1.0:
                live = {'app': latest['app'], 'masked': latest['masked'],
                        'start': live_start, 'end': day_cap,
                        'ts': latest['ts'],
                        'sec': int(round(day_cap - live_start))}

    # ── 步骤 3：权威亮屏窗口 ──
    # 🔴 真库口径修正（2.8.7 傍晚批 1-2 施工中发现）：`state.screen` 并不总是
    # 全天的（实测她 11-28 只有 22 条、集中在上午），若严格只用亮屏窗，下午
    # 的 usage.session 会被整段裁掉（Top5 直接归零、与总量脱节）。
    # 因此只把「整段落在所有亮屏窗之外」的孤立会话补进 active_windows
    # （与窗相交的会话照旧被窗裁剪，跨灭屏切断语义不破）；恒等式仍由构造保证。
    # 🔴 口径已定稿（Muse 2026-11-28 批准）：不许按原规格「只用亮屏窗」改回去。
    if closed_screen_windows:
        active = closed_screen_windows
        # 只补「落在所有亮屏窗之外」的孤立会话（亮屏事件缺失造成的洞）；
        # 与窗口相交的会话照旧被窗裁剪 —— 「跨灭屏必须切断」的语义不破。
        orphans = [(s_['start'], s_['end']) for s_ in raw_sessions
                   if not _intersect_intervals((s_['start'], s_['end']), active)]
        if orphans:
            active = _merge_intervals(list(active) + orphans)
        if live:
            active = _merge_intervals(list(active) + [(live['start'], live['end'])])
    elif raw_sessions or live:
        base = [(s_['start'], s_['end']) for s_ in raw_sessions]
        if live:
            base.append((live['start'], live['end']))
        active = _merge_intervals(base)
    else:
        active = []

    # ── 步骤 4：裁剪 + 去重 + 回收 usage.now 亮屏段 ──
    claimed = []
    canonical = []
    for s_ in sorted(raw_sessions, key=lambda x: (x['ts'], x['end']), reverse=True):
        for a, b in _intersect_intervals((s_['start'], s_['end']), active):
            for a2, b2 in _subtract_intervals([(a, b)], claimed):
                if b2 - a2 >= 1.0:
                    canonical.append({'app': s_['app'], 'masked': s_['masked'],
                                      'start': a2, 'end': b2, 'ts': s_['ts'],
                                      'sec': int(round(b2 - a2))})
                    claimed.append((a2, b2))
        claimed = _merge_intervals(claimed)

    runs = {}
    for ev in now_events:
        key = (ev['app'], int(round(ev['since'])))
        cur = runs.get(key)
        if cur is None:
            runs[key] = {'app': ev['app'], 'masked': ev['masked'],
                         'start': ev['since'], 'end': ev['ts'], 'last_ts': ev['ts']}
        else:
            cur['end'] = max(cur['end'], ev['ts'])
            cur['last_ts'] = max(cur['last_ts'], ev['ts'])
    if live:
        cur = runs.get((live['app'], int(round(live['start']))))
        if cur is not None:
            cur['end'] = max(cur['end'], live['end'])

    other_starts = sorted({s_['start'] for s_ in raw_sessions} |
                          {ev['since'] for ev in now_events})
    for run in runs.values():
        run_end = run['end']
        later = [x for x in other_starts if x > run['start'] + 1.0]
        if later:
            run_end = min(run_end, later[0])
        for a, b in _intersect_intervals((run['start'], run_end), active):
            for a2, b2 in _subtract_intervals([(a, b)], claimed):
                if b2 - a2 >= 1.0:
                    canonical.append({'app': run['app'], 'masked': run['masked'],
                                      'start': a2, 'end': b2,
                                      'ts': run['last_ts'],
                                      'sec': int(round(b2 - a2))})
                    claimed.append((a2, b2))
        claimed = _merge_intervals(claimed)

    # ── 步骤 5：派生 5 个口径 ──
    fallback = None
    if active:
        screen_sec = sum(int(round(e - s_)) for s_, e in active)
        longest = max((int(round(e - s_)) for s_, e in active), default=0)
        hourly = _hourly_from_windows(active, start, end)
        unlocks = 0
        row = c.execute('SELECT unlocks FROM peer_usage_daily WHERE user=? AND day=?',
                        (user_id, day)).fetchone()
        if row:
            unlocks = int(row['unlocks'] or 0)
    else:
        fallback = c.execute(
            'SELECT screen_sec,unlocks,top_apps FROM peer_usage_daily '
            'WHERE user=? AND day=?', (user_id, day)).fetchone()
        screen_sec = int(fallback['screen_sec']) if fallback else 0
        unlocks = int(fallback['unlocks']) if fallback else 0
        hourly = [0] * 24
        longest = 0

    canonical.sort(key=lambda x: (x['end'], x['start']), reverse=True)
    sessions = [{'app': s_['app'], 'sec': s_['sec'], 'start': s_['start'],
                 'end': s_['end'], 'ts': s_['ts'], 'masked': s_['masked'],
                 'folded': False} for s_ in canonical if s_['sec'] > 0]
    folded = sum(1 for s_ in canonical if 0 < s_['sec'] < 10)

    agg = {}
    for s_ in canonical:
        if s_['sec'] > 0:
            agg[s_['app']] = agg.get(s_['app'], 0) + s_['sec']
    all_apps_sec = sum(agg.values())
    top5 = [{'app': a, 'sec': v}
            for a, v in sorted(agg.items(), key=lambda kv: (-kv[1], kv[0]))[:5]]
    if not top5 and fallback and fallback['top_apps']:
        try:
            parsed = json.loads(fallback['top_apps'])
            top5 = [{'app': str(it.get('app')), 'sec': int(it.get('sec') or 0)}
                    for it in parsed if isinstance(it, dict) and it.get('app')][:5]
        except (ValueError, TypeError):
            top5 = []
    # 兜底口径也必须守住 Top5 ≤ 总量
    if screen_sec > 0:
        kept, acc = [], 0
        for it in top5:
            take = min(it['sec'], max(0, screen_sec - acc))
            if take > 0:
                kept.append({'app': it['app'], 'sec': take})
                acc += take
        top5 = kept
        all_apps_sec = max(all_apps_sec, acc) if not agg else all_apps_sec

    return {
        'screen_sec': screen_sec,
        'unlocks': unlocks,
        'longest_session_sec': longest,
        'hourly': hourly,
        'canonical_sessions': canonical,
        'sessions': sessions,
        'folded_count': folded,
        'top_apps': top5,
        'all_apps_sec': all_apps_sec,
        'current_app': live,
        'active_windows': active,
    }


def current_network_for(c, user_id, policy, fallback_events=None):
    """当前网络：与今日状态卡同源（peer_location_latest）；事件流仅兜底。"""
    level = policy.get('network_level', 'ssid')
    if level == 'off':
        return None
    row = c.execute(
        'SELECT net, wifi, state_updated, updated FROM peer_location_latest '
        'WHERE user=?', (user_id,)).fetchone()
    if row is not None and (row['net'] or ''):
        ts = row['state_updated'] if row['state_updated'] is not None else row['updated']
        return {'ts': db.ts_to_sec(ts) if ts is not None else 0,
                'net': row['net'],
                'ssid': (row['wifi'] or '') if level == 'ssid' else ''}
    if fallback_events:
        return fallback_events[0]
    return None

# ── 应用使用 ────────────────────────────────────────────────────────

def _screen_events(c, user_id, start, end):
    rows = c.execute(
        "SELECT ts,payload FROM peer_events WHERE user=? AND type='state.screen' "
        'AND ts>=? AND ts<? ORDER BY ts', (user_id, start, end)).fetchall()
    out = []
    for r in rows:
        p = _payload(r)
        sec = p.get('session_sec')
        if not isinstance(sec, (int, float)):
            continue
        out.append({'ts': float(r['ts']), 'sec': int(sec)})
    return out


def hourly_screen(events, start, end):
    """亮屏秒数按小时切分：会话区间 [ts-sec, ts]，跨小时/跨天都在 00:00 切。"""
    hourly = [0] * 24
    for ev in events:
        s = max(start, ev['ts'] - ev['sec'])
        e = min(end, ev['ts'])
        while s < e:
            idx = int((s - start) // 3600)
            if idx < 0 or idx > 23:
                break
            hour_end = start + (idx + 1) * 3600
            chunk_end = min(e, hour_end)
            hourly[idx] += int(round(chunk_end - s))
            s = chunk_end
    return hourly


def usage_sessions(c, user_id, start, end, policy):
    """当日应用会话流（stream 档才返回；其余档由调用方裁掉）。"""
    rows = c.execute(
        "SELECT ts,payload FROM peer_events WHERE user=? AND type='usage.session' "
        'AND ts>=? AND ts<? ORDER BY ts DESC', (user_id, start, end)).fetchall()
    fold = policy.get('fold_short', True)
    out = []
    for r in rows:
        p = _payload(r)
        dur = int(p.get('dur') or 0)
        app = str(p.get('app') or '').strip() or '某个应用'
        masked = p.get('masked') is True
        folded = bool(fold and dur < 10)
        if folded:
            continue  # 端侧已丢；历史数据在这里也不给（fold_short 开 = 折叠）
        out.append({'app': app, 'sec': dur, 'start': p.get('start'),
                    'end': p.get('end'), 'ts': r['ts'],
                    'masked': masked, 'folded': False})
    return out


def folded_count(c, user_id, start, end, policy):
    """被折叠的 <10 秒切换次数（关档时才有意义；端上报了就数得到）。"""
    rows = c.execute(
        "SELECT payload FROM peer_events WHERE user=? AND type='usage.session' "
        'AND ts>=? AND ts<?', (user_id, start, end)).fetchall()
    n = 0
    for r in rows:
        dur = int(_payload(r).get('dur') or 0)
        if 0 <= dur < 10:
            n += 1
    return n


def network_events(c, user_id, start, end, policy):
    """当日网络切换流水（读侧带毫秒防御，ts 归一为秒）。"""
    level = policy.get('network_level', 'ssid')
    if level == 'off':
        return []
    rows = _kind_rows(c, user_id, 'state.net', float(start), float(end))
    out = []
    for r in sorted(rows, key=lambda x: x['ts'], reverse=True):
        p = r['p']
        out.append({'ts': r['ts'], 'net': p.get('net') or '',
                    'ssid': (p.get('ssid') or '') if level == 'ssid' else ''})
    return out


def usage_daily_for(c, user_id, day, policy, now=None):
    """某人的当日使用汇总（已按 policy 裁剪）。返回 (body, closed_off)。

    2.8.7 一套账：总量/最长/24h/会话流/Top5/正在使用全部来自
    `reconcile_usage_day` 的单一份账，恒等式由构造保证（不再读可能被
    `[:5]` 截断污染的 `peer_usage_daily.top_apps` 作主口径）。
    """
    usage_level = policy.get('usage_level', 'full')
    app_level = policy.get('app_level', 'full')
    if usage_level == 'off':
        return {}, True

    led = reconcile_usage_day(c, user_id, day, policy, now=now)
    y_led = reconcile_usage_day(c, user_id, prev_day(day), policy, now=now)
    net_ev = network_events(c, user_id, *day_bounds(c, day), policy)

    body = {
        'screen_sec': int(led['screen_sec']),
        'unlocks': int(led['unlocks']),
        'longest_session_sec': int(led['longest_session_sec']),
        'yesterday_screen_sec': int(y_led['screen_sec']),
    }
    # screen_only 档：只留亮屏与解锁两数，分布/应用全裁
    if usage_level == 'full':
        body['hourly'] = led['hourly']
    if app_level != 'off' and usage_level == 'full':
        body['top_apps'] = led['top_apps']
    if app_level == 'stream' and usage_level == 'full':
        fold = policy.get('fold_short') is not False
        body['folded_count'] = int(led['folded_count'])
        body['sessions'] = [s_ for s_ in led['sessions']
                            if (s_['sec'] >= 10 if fold else True)]
    body['network_events'] = net_ev
    body['current_network'] = current_network_for(
        c, user_id, policy, fallback_events=net_ev)
    return body, False


def current_app(c, user_id, policy, now=None):
    """「正在使用 X」：与 usage-daily 100% 同源（同一份对账账本）。

    关键：熄屏后心跳重发旧 `since` 不再造幽灵会话——由
    `reconcile_usage_day` 的 live_session 校验统一裁定。
    """
    if policy.get('app_level') != 'stream' or policy.get('usage_level') == 'off':
        return None
    day = dt.datetime.now(space_tz(c)).strftime('%Y-%m-%d')
    led = reconcile_usage_day(c, user_id, day, policy, now=now)
    return led['current_app']
