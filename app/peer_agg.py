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
                    'speed': float(r['speed']) if r['speed'] is not None else None})
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


def cluster_stays(points, *, radius=STAY_RADIUS_M, min_sec=STAY_MIN_SEC):
    """停留聚类：连续点在 radius 内累计 ≥min_sec 即一个停留点。

    重心取簇内均值；`left_at` 取簇后第一个点的时刻，**当天最后一簇给 null**
    （表示「仍在此处」，与令文一致）。
    """
    stays = []
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
            left_at = points[j + 1]['ts'] if j + 1 < n else None
            stays.append({
                'lat': c_lat, 'lng': c_lng,
                'arrived_at': points[i]['ts'],
                'left_at': left_at,
                'duration_sec': int(span),
                'points': len(members),
            })
        i = j + 1
    return stays


def name_stays(c, stays):
    """用 `peer_places` 给停留点命名；匹配不上就留空名（端上写「停留点」）。"""
    places = c.execute('SELECT name,lat,lng,radius FROM peer_places').fetchall()
    for s in stays:
        best = None
        for p in places:
            r = float(p['radius'] or 150)
            d = haversine_m(s['lat'], s['lng'], p['lat'], p['lng'])
            if d <= r and (best is None or d < best[0]):
                best = (d, p['name'])
        s['place_name'] = best[1] if best else ''
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
            'distance_m': 0.0, 'latest': None}


def track_for(c, user_id, day, policy):
    """某人的当日轨迹（已按 policy 裁剪）。返回 dict（供调用方包 closed_off）。

    · exact：点列 + 距离 + 停留点 + 分段；
    · street：**无点列**，只有网格化停留点与街区级最新位置；
    · off：由调用方按既有 `closed_off` 明示（这里返回空壳）。
    """
    level = policy.get('location_level', 'exact')
    start, end = day_bounds(c, day)
    rows = c.execute(
        'SELECT ts,lat,lng,acc,speed FROM peer_location_points '
        'WHERE user=? AND ts>=? AND ts<? ORDER BY ts',
        (user_id, start, end)).fetchall()
    if level == 'off':
        return {'level': 'off', 'points': [], 'stays': [], 'segments': [],
                'distance_m': 0.0, 'latest': None}

    if level == 'street':
        pts = filter_points(rows)
        stays = name_stays(c, cluster_stays(pts))
        for s in stays:
            s['lat'] = grid_round(s['lat'])
            s['lng'] = grid_round(s['lng'])
        latest = c.execute(
            'SELECT lat,lng,updated FROM peer_location_latest WHERE user=?',
            (user_id,)).fetchone()
        return {
            'level': 'street',
            'points': [],  # 街道档绝不下发原始点列
            'stays': stays,
            'segments': [],
            'distance_m': None,  # 不足 500m 的精度不提供，端上不显示距离
            'latest': ({'lat': grid_round(latest['lat']),
                        'lng': grid_round(latest['lng']),
                        'updated': latest['updated']} if latest else None),
        }

    pts = filter_points(rows)
    stays = name_stays(c, cluster_stays(pts))
    latest = c.execute(
        'SELECT lat,lng,updated FROM peer_location_latest WHERE user=?',
        (user_id,)).fetchone()
    return {
        'level': 'exact',
        'points': pts,
        'stays': stays,
        'segments': speed_segments(pts),
        'distance_m': round(total_distance_m(pts), 1),
        'latest': ({'lat': latest['lat'], 'lng': latest['lng'],
                    'updated': latest['updated']} if latest else None),
    }


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
    level = policy.get('network_level', 'ssid')
    if level == 'off':
        return []
    rows = c.execute(
        "SELECT ts,payload FROM peer_events WHERE user=? AND type='state.net' "
        'AND ts>=? AND ts<? ORDER BY ts DESC', (user_id, start, end)).fetchall()
    out = []
    for r in rows:
        p = _payload(r)
        out.append({'ts': r['ts'], 'net': p.get('net') or '',
                    'ssid': (p.get('ssid') or '') if level == 'ssid' else ''})
    return out


def usage_daily_for(c, user_id, day, policy):
    """某人的当日使用汇总（已按 policy 裁剪）。返回 (body, closed_off)。"""
    usage_level = policy.get('usage_level', 'full')
    app_level = policy.get('app_level', 'full')
    if usage_level == 'off':
        return {}, True

    start, end = day_bounds(c, day)
    row = c.execute(
        'SELECT screen_sec,unlocks,top_apps FROM peer_usage_daily '
        'WHERE user=? AND day=?', (user_id, day)).fetchone()
    yrow = c.execute(
        'SELECT screen_sec FROM peer_usage_daily WHERE user=? AND day=?',
        (user_id, prev_day(day))).fetchone()

    events = _screen_events(c, user_id, start, end)
    screen_sec = int(row['screen_sec']) if row else int(sum(e['sec'] for e in events))
    unlocks = int(row['unlocks']) if row else 0
    longest = max((e['sec'] for e in events), default=0)

    body = {
        'screen_sec': screen_sec,
        'unlocks': unlocks,
        'longest_session_sec': longest,
        'yesterday_screen_sec': int(yrow['screen_sec']) if yrow else 0,
    }
    # screen_only 档：只留亮屏与解锁两数，分布/应用全裁
    if usage_level == 'full':
        body['hourly'] = hourly_screen(events, start, end)
    if app_level != 'off' and usage_level == 'full':
        top = []
        if row and row['top_apps']:
            try:
                parsed = json.loads(row['top_apps'])
                if isinstance(parsed, list):
                    top = [{'app': str(it.get('app')), 'sec': int(it.get('sec') or 0)}
                           for it in parsed if isinstance(it, dict) and it.get('app')][:5]
            except (ValueError, TypeError):
                top = []
        body['top_apps'] = top
    if app_level == 'stream' and usage_level == 'full':
        body['sessions'] = usage_sessions(c, user_id, start, end, policy)
        body['folded_count'] = folded_count(c, user_id, start, end, policy)
    body['network_events'] = network_events(c, user_id, start, end, policy)
    return body, False


def current_app(c, user_id, policy):
    """「正在使用 X」：最新一条 usage.now 事件（stream 档才给）。

    用事件日志而不是快照列：一条 usage.now 就是一次可追溯的声明，
    历史完整、无需迁移新列。
    """
    if policy.get('app_level') != 'stream' or policy.get('usage_level') == 'off':
        return None
    row = c.execute(
        "SELECT ts,payload FROM peer_events WHERE user=? AND type='usage.now' "
        'ORDER BY ts DESC LIMIT 1', (user_id,)).fetchone()
    if not row:
        return None
    p = _payload(row)
    app = str(p.get('app') or '').strip()
    if not app:
        return None
    return {'app': app, 'masked': p.get('masked') is True,
            'since': p.get('since') or row['ts'], 'ts': row['ts']}
