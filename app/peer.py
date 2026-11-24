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

import json
import time
import uuid

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


def serialize_peer_event(row):
    """完整事件序列化（保留原有核心字段并增量附加主动报备与 ack 字段）。"""
    keys = set(row.keys())
    ack_at = row['ack_at'] if 'ack_at' in keys else None
    return {
        'id': row['id'],
        'user': row['user'] if 'user' in keys else '',
        'type': row['type'],
        'ts': row['ts'],
        'summary': row['summary'],
        'pushed': row['pushed'],
        'created': row['created'] if 'created' in keys else row['ts'],
        'source': row['source'] if 'source' in keys else 'auto',
        'scene': row['scene'] if 'scene' in keys else '',
        'note': row['note'] if 'note' in keys else '',
        'place_name': row['place_name'] if 'place_name' in keys else '',
        'client_id': row['client_id'] if 'client_id' in keys else '',
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
