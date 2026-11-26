"""2.8.0 定位守护一期 · 后端 peer 模块（计划稿 docs/location-guard-plan.md 拍板定案）。

四张独立小表（不动既有契约）：
- peer_location_latest：每人一行最新状态（经纬度/精度/速度/电量/充电/网络/Wi-Fi/更新时间）
- peer_location_points：轨迹点（含补传标记 backfill），保留期 15 天滚动删除（拍板口径）
- peer_places：围栏点（一期建表，二期围栏管理用）
- peer_events：报备事件流（动态流与推送同源；pushed: 0=入流 1=已推送）
- peer_usage_daily：使用报告日汇总（一期建表，三期接入）

接口全集（Cookie 鉴权 + X-Love-Space 写门禁，沿既有通道）：
- POST /api/peer/location  批量轨迹点（≤50/批）+ 可选最新状态；SSE peer_location 下发
- POST /api/peer/events    批量报备事件（≤100/批）；关键类型按开关写通知中心
- POST /api/peer/sos       紧急事件（强推送口径，pushed=2）
- GET  /api/peer/status    双方最新状态 + 四类共享开关 + 对方关闭态明示
- GET  /api/peer/track?date=    按日双方轨迹
- GET  /api/peer/events?date=   按日双方事件流
- GET/PUT /api/peer/settings    四类共享开关（location/track/events/usage）

对等口径（计划稿 3.5）：任一方关闭某类共享，对方端 status 明确返回关闭态
（closed_off=true），不许显示空白或假故障。
"""

import datetime as dt
import json
import time
import uuid
from zoneinfo import ZoneInfo

from . import db

# 保留期（拍板：轨迹 15 天滚动删除；事件流同口径统一，设置页可见）
POINT_RETENTION_DAYS = 15
EVENT_RETENTION_DAYS = 15
LOCATION_BATCH_MAX = 50
EVENTS_BATCH_MAX = 100

# 四类共享开关键（缺省全开）
SHARE_KEYS = ('location', 'track', 'events', 'usage')

# 关键报备类型（推送层默认勾选集；逐项可调，此处为缺省）
DEFAULT_PUSH_TYPES = ('arrive_place', 'leave_place', 'sos', 'location_off', 'battery_low')

# ── 自动报备第二阶段（2.8.7）：设备状态事件 ─────────────────────────
# 四类状态事件一并走 POST /api/peer/report 的 client_id 幂等通道（不新开通道）。
# 命名统一 state.* 前缀，与 manual_report / sos / arrive_place 并列不冲突，
# 并为下一段「分档策略」留命名空间。
STATE_KINDS = ('state.battery', 'state.net', 'state.unlock', 'state.screen')
NET_KINDS = ('wifi', 'cell', 'none')
# payload 内两个分档扩展键：服务端**不解析、只透传**（红线：本段不做分档，
# 但 schema 必须留位，下一段加分档不改表结构）。
STATE_PASSTHROUGH_KEYS = ('tier', 'policy')
STATE_TIER_MAX = 16


def settings_key(user_id):
    return f'peer_settings:{user_id}'


def load_settings(c, user_id):
    """读某人的四类共享开关（缺省全开）。"""
    raw = c.execute('SELECT value FROM app_state WHERE key=?',
                    (settings_key(user_id),)).fetchone()
    saved = json.loads(raw['value']) if raw else {}
    return {k: bool(saved.get(k, True)) for k in SHARE_KEYS}


def save_settings(c, user_id, data):
    saved = {k: bool(data.get(k, True)) for k in SHARE_KEYS}
    c.execute('INSERT INTO app_state(key,value) VALUES (?,?) '
              'ON CONFLICT(key) DO UPDATE SET value=excluded.value',
              (settings_key(user_id), json.dumps(saved)))
    return saved


def peer_partner(c, user_id):
    """两人空间的对方 id（空间恒两人）。"""
    return c.execute('SELECT id FROM users WHERE id<>?', (user_id,)).fetchone()['id']


# ── 情侣主动报备（P0，docs/couple-report-plan.md v2）────────────────

REPORT_PRESETS_KEY = 'peer_report_presets'

DEFAULT_REPORT_PRESETS = [
    {'scene': 'depart',      'label': '出门啦',   'emoji': '🚶', 'summary': '准备出门啦',       'push': True},
    {'scene': 'arrive_home', 'label': '到家了',   'emoji': '🏠', 'summary': '平安到家啦',       'push': True},
    {'scene': 'meal',        'label': '吃饭中',   'emoji': '🍚', 'summary': '正在干饭',         'push': False},
    {'scene': 'busy',        'label': '忙碌中',   'emoji': '💻', 'summary': '在忙，晚点回你',   'push': False},
    {'scene': 'sleep',       'label': '准备睡了', 'emoji': '🌙', 'summary': '准备睡觉啦，晚安', 'push': True},
    {'scene': 'miss',        'label': '想你了',   'emoji': '💗', 'summary': '突然好想你',       'push': True},
]


def load_report_presets(c):
    """读取双人共享的快捷报备模板（未配置时返回默认集）。"""
    raw = c.execute(
        'SELECT value FROM app_state WHERE key=?', (REPORT_PRESETS_KEY,)
    ).fetchone()
    if not raw:
        return list(DEFAULT_REPORT_PRESETS)
    try:
        items = json.loads(raw['value'])
        return items if isinstance(items, list) and items else list(DEFAULT_REPORT_PRESETS)
    except Exception:
        return list(DEFAULT_REPORT_PRESETS)


def save_report_presets(c, presets):
    cleaned = []
    for item in presets[:12]:
        scene = str(item.get('scene', '')).strip()[:32]
        label = str(item.get('label', '')).strip()[:16]
        if not scene or not label:
            continue
        cleaned.append({
            'scene': scene,
            'label': label,
            'emoji': str(item.get('emoji', '💬')).strip()[:8] or '💬',
            'summary': str(item.get('summary', label)).strip()[:80] or label,
            'push': bool(item.get('push', True)),
        })
    c.execute(
        'INSERT INTO app_state(key,value) VALUES (?,?) '
        'ON CONFLICT(key) DO UPDATE SET value=excluded.value',
        (REPORT_PRESETS_KEY, json.dumps(cleaned, ensure_ascii=False)),
    )
    return cleaned


def bump_peer_revision(c):
    """递增 app_state.peer_revision 并返回最新版本号（与现行 _bump_peer 口径一致）。"""
    c.execute(
        "UPDATE app_state SET value = CAST(value AS INTEGER) + 1 "
        "WHERE key='peer_revision'"
    )
    row = c.execute("SELECT value FROM app_state WHERE key='peer_revision'").fetchone()
    return int(row['value']) if row else 0


def _summary_for_row(row, keys):
    """summary 兜底：状态事件的历史行可能没有文案（早于 state_summary 落库）。

    只要 type 是 state.* 且 summary 为空，就按 payload 现算一句——
    绝不让事件流出现空白行。
    """
    raw = row['summary'] or ''
    if raw:
        return raw
    etype = row['type'] or ''
    if etype.startswith('state.'):
        return state_summary(etype, _payload_dict(row, keys))
    return ''


def _payload_dict(row, keys):
    """把 payload 列（JSON 字符串）还原成 dict；空/坏值一律给 {}，不抛。"""
    if 'payload' not in keys:
        return {}
    raw = row['payload'] or ''
    if not raw:
        return {}
    try:
        val = json.loads(raw)
    except (ValueError, TypeError):
        return {}
    return val if isinstance(val, dict) else {}


def serialize_peer_event(row):
    """完整事件序列化（保留原有核心字段并增量附加主动报备与 ack 字段）。"""
    keys = set(row.keys())
    ack_at = row['ack_at'] if 'ack_at' in keys else None
    return {
        'id': row['id'],
        'user': row['user'] if 'user' in keys else '',
        'type': row['type'],
        'ts': row['ts'],
        'summary': _summary_for_row(row, keys),
        'pushed': row['pushed'],
        'created': row['created'] if 'created' in keys else row['ts'],
        'source': row['source'] if 'source' in keys else 'auto',
        'scene': row['scene'] if 'scene' in keys else '',
        'note': row['note'] if 'note' in keys else '',
        'place_name': row['place_name'] if 'place_name' in keys else '',
        'client_id': row['client_id'] if 'client_id' in keys else '',
        # 2.8.7 自动报备：状态事件的结构化载荷。旧行（无该列/空串）给空 dict，
        # 客户端按缺省容错——不许拿 summary 反向解析。
        'payload': _payload_dict(row, keys),
        'ack': (
            {
                'by': row['ack_by'],
                'emoji': row['ack_emoji'],
                'at': ack_at,
            }
            if ack_at is not None
            else None
        ),
    }


def create_manual_report(
    c,
    user_id,
    *,
    scene='custom',
    summary='',
    note='',
    place_name='',
    push=True,
    client_id='',
    ts=None,
):
    """创建一条主动情侣报备（支持 client_id 幂等防重）。"""
    now = time.time()
    event_ts = float(ts) if ts is not None else now
    clean_client_id = (client_id or '').strip()[:64]

    if clean_client_id:
        existing = c.execute(
            'SELECT * FROM peer_events WHERE user=? AND client_id=?',
            (user_id, clean_client_id),
        ).fetchone()
        if existing:
            return serialize_peer_event(existing), False, None

    event_id = uuid.uuid4().hex
    clean_scene = (scene or 'custom').strip()[:32] or 'custom'
    clean_summary = (summary or '').strip()[:120]
    clean_note = (note or '').strip()[:500]
    clean_place = (place_name or '').strip()[:80]

    if not clean_summary:
        presets = {p['scene']: p for p in load_report_presets(c)}
        clean_summary = presets.get(clean_scene, {}).get('summary') or '发起了一条报备'

    pushed = 1 if push else 0
    c.execute(
        '''
        INSERT INTO peer_events(
            id, user, type, ts, summary, pushed, created,
            source, scene, note, place_name, client_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 'manual', ?, ?, ?, ?)
        ''',
        (
            event_id, user_id, 'manual_report', event_ts, clean_summary, pushed, now,
            clean_scene, clean_note, clean_place, clean_client_id,
        ),
    )
    rev = bump_peer_revision(c)
    row = c.execute('SELECT * FROM peer_events WHERE id=?', (event_id,)).fetchone()
    return serialize_peer_event(row), True, rev


def state_summary(kind, payload):
    """状态事件的中文一句话（落库进 summary，供事件流直接显示）。

    🔴 为什么服务端也要生成：客户端渲染文案是后加的，老包只认 `summary`。
    如果 summary 留空，事件流里就是一行**空白**（2026-11-26 真机就是这么空的：
    前端拿到 payload={} + summary='' → 无字可渲染）。所以这里按同一口径
    落一份中文，任何版本的客户端至少都有一行字。
    """
    p = payload if isinstance(payload, dict) else {}
    if kind == 'state.battery':
        level = p.get('level')
        if level is None:
            return '电量发生变化'
        return f'电量 {int(level)}%，充电中' if p.get('charging') else f'电量 {int(level)}%'
    if kind == 'state.net':
        net = p.get('net') or ''
        ssid = p.get('ssid') or ''
        if net == 'wifi':
            return f'连上 Wi-Fi（{ssid}）' if ssid else '连上 Wi-Fi'
        if net == 'cell':
            return '切到移动数据'
        if net == 'none':
            return '断开网络'
        return '网络发生变化'
    if kind == 'state.unlock':
        n = p.get('count')
        return f'解锁 {int(n)} 次' if n is not None else '有解锁'
    if kind == 'state.screen':
        sec = p.get('session_sec')
        if sec is None:
            return '亮屏'
        sec = int(sec)
        if sec < 60:
            return '亮屏不足 1 分钟'
        m = sec // 60
        return f'亮屏 {m} 分钟' if m < 60 else f'亮屏 {m // 60} 小时 {m % 60} 分钟' if m % 60 else f'亮屏 {m // 60} 小时'
    return ''


def validate_state_payload(kind, payload):
    """校验并规范化状态事件 payload（令文：非法一律 422，服务端不猜）。

    返回可 JSON 化的 dict；非法抛 ValueError（调用方转 422）。
    tier/policy 两键**原样透传不解析**——本段不做分档，但不许拒收未来字段。
    """
    if kind not in STATE_KINDS:
        raise ValueError(f'未知状态事件类型：{kind}')
    if not isinstance(payload, dict):
        raise ValueError('payload 必须是对象')

    def _int(name, lo=None, hi=None):
        v = payload.get(name)
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            raise ValueError(f'{name} 必须是数字')
        iv = int(v)
        if lo is not None and iv < lo:
            raise ValueError(f'{name} 不能小于 {lo}')
        if hi is not None and iv > hi:
            raise ValueError(f'{name} 不能大于 {hi}')
        return iv

    out = {}
    if kind == 'state.battery':
        out['level'] = _int('level', 0, 100)  # clamp 口径由下界/上界校验承担
        charging = payload.get('charging')
        if not isinstance(charging, bool):
            raise ValueError('charging 必须是布尔')
        out['charging'] = charging
    elif kind == 'state.net':
        net = payload.get('net')
        if net not in NET_KINDS:
            raise ValueError(f'net 必须是 {"/".join(NET_KINDS)} 之一')
        out['net'] = net
        ssid = payload.get('ssid')
        # 取不到 SSID 时降级为 type-only：允许缺省或空串，绝不伪造
        out['ssid'] = str(ssid)[:64] if isinstance(ssid, str) else ''
    elif kind == 'state.unlock':
        out['count'] = _int('count', 1)
        out['window_sec'] = _int('window_sec', 0)
    else:  # state.screen
        out['session_sec'] = _int('session_sec', 0)
        on = payload.get('on')
        out['on'] = bool(on) if on is not None else False

    for k in STATE_PASSTHROUGH_KEYS:
        v = payload.get(k)
        if isinstance(v, str) and v.strip():
            out[k] = v.strip()[:STATE_TIER_MAX]
    return out


def _space_day(c, ts):
    """把 unix 秒按空间时区折算成 YYYY-MM-DD（与 events/track 按日查询同口径）。"""
    tz = ZoneInfo((db.setting(c, 'space') or {}).get('timezone', 'Asia/Shanghai'))
    return dt.datetime.fromtimestamp(float(ts), tz).strftime('%Y-%m-%d')


def _apply_state_side_effects(c, user_id, kind, payload, event_ts):
    """状态事件的库内副作用（失败不阻断事件入库，但绝不静默写错列）。

    1) battery/net → 顺手更新最新状态快照的对应列（只碰 battery/charging/net/wifi
       + state_updated，**不动 lat/lng/updated 语义**：那是定位的字段）；
    2) screen/unlock → peer_usage_daily 的 screen_sec / unlocks 两列累加。
       🔴 围栏：top_apps 一律不写、usage 开关一律不读（本阶段明令）。
    """
    if kind in ('state.battery', 'state.net'):
        now_ts = time.time()
        if kind == 'state.battery':
            c.execute(
                'UPDATE peer_location_latest SET battery=?, charging=?, state_updated=? '
                'WHERE user=?',
                (payload['level'], 1 if payload['charging'] else 0, now_ts, user_id))
        else:
            c.execute(
                'UPDATE peer_location_latest SET net=?, wifi=?, state_updated=? '
                'WHERE user=?',
                (payload['net'], payload.get('ssid', ''), now_ts, user_id))
        # 行不存在（从未上报过定位）→ UPDATE 影响 0 行，正常跳过：没有经纬度
        # 就无法凭空造快照，客户端各自兜底「最后活跃来自定位」。
    elif kind == 'state.screen':
        day = _space_day(c, event_ts)
        sec = int(payload['session_sec'])
        c.execute(
            'INSERT INTO peer_usage_daily(user,day,screen_sec,unlocks,updated) '
            'VALUES (?,?,?,0,?) '
            'ON CONFLICT(user,day) DO UPDATE SET '
            'screen_sec=screen_sec+excluded.screen_sec, updated=excluded.updated',
            (user_id, day, sec, time.time()))
    elif kind == 'state.unlock':
        day = _space_day(c, event_ts)
        cnt = int(payload['count'])
        c.execute(
            'INSERT INTO peer_usage_daily(user,day,screen_sec,unlocks,updated) '
            'VALUES (?,?,0,?,?) '
            'ON CONFLICT(user,day) DO UPDATE SET '
            'unlocks=unlocks+excluded.unlocks, updated=excluded.updated',
            (user_id, day, cnt, time.time()))


def create_state_event(c, user_id, *, kind, payload, client_id='', ts=None):
    """创建一条设备状态事件（client_id 幂等，与主动报备同口径）。

    与 manual_report 的区别：type=state.*、source='auto'、scene/note/place_name
    全空（**不污染主动报备的三个语义字段**）、payload 落 payload 列、不写通知中心。
    幂等命中时**不重复累加日汇总**（副作用只在 created 分支执行）。
    """
    now_ts = time.time()
    event_ts = float(ts) if ts is not None else now_ts
    clean_client_id = (client_id or '').strip()[:64]

    if clean_client_id:
        existing = c.execute(
            'SELECT * FROM peer_events WHERE user=? AND client_id=?',
            (user_id, clean_client_id)).fetchone()
        if existing:
            return serialize_peer_event(existing), False, None

    event_id = uuid.uuid4().hex
    c.execute(
        """
        INSERT INTO peer_events(
            id, user, type, ts, summary, pushed, created,
            source, scene, note, place_name, client_id, payload
        ) VALUES (?, ?, ?, ?, ?, 0, ?, 'auto', '', '', '', ?, ?)
        """,
        (event_id, user_id, kind, event_ts, state_summary(kind, payload), now_ts,
         clean_client_id,
         json.dumps(payload, ensure_ascii=False, separators=(',', ':'))),
    )
    _apply_state_side_effects(c, user_id, kind, payload, event_ts)
    rev = bump_peer_revision(c)
    row = c.execute('SELECT * FROM peer_events WHERE id=?', (event_id,)).fetchone()
    return serialize_peer_event(row), True, rev


def ack_peer_event(c, user_id, event_id, emoji='❤️'):
    """伴侣一键回应某条报备（禁止自己回应自己）。"""
    row = c.execute('SELECT * FROM peer_events WHERE id=?', (event_id,)).fetchone()
    if not row:
        return None, 'not_found', None
    if row['user'] == user_id:
        return None, 'cannot_ack_own', None

    clean_emoji = (emoji or '❤️').strip()[:8] or '❤️'
    now = time.time()
    c.execute(
        'UPDATE peer_events SET ack_by=?, ack_emoji=?, ack_at=? WHERE id=?',
        (user_id, clean_emoji, now, event_id),
    )
    rev = bump_peer_revision(c)
    updated = c.execute('SELECT * FROM peer_events WHERE id=?', (event_id,)).fetchone()
    return serialize_peer_event(updated), 'ok', rev


def cleanup_expired(c, now):
    """保留期滚动删除：仅清理自动轨迹与自动守护事件，保留手动情侣报备。"""
    point_cut = now - POINT_RETENTION_DAYS * 86400
    event_cut = now - EVENT_RETENTION_DAYS * 86400
    c.execute('DELETE FROM peer_location_points WHERE created<?', (point_cut,))
    c.execute(
        "DELETE FROM peer_events WHERE source='auto' AND created<?",
        (event_cut,),
    )
