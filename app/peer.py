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


def cleanup_expired(c, now):
    """保留期滚动删除（worker maintenance 周期调用；幂等、按 created 索引）。"""
    point_cut = now - POINT_RETENTION_DAYS * 86400
    event_cut = now - EVENT_RETENTION_DAYS * 86400
    c.execute('DELETE FROM peer_location_points WHERE created<?', (point_cut,))
    c.execute('DELETE FROM peer_events WHERE created<?', (event_cut,))
