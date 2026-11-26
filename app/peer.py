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

# ── 全量施工令（2.8.7 收尾）：分档策略 v2 ─────────────────────────────
# 单一事实源是 policy 对象；老四开关是它的**投影**（见 SWITCH_MAP_DOC）。
# 应用使用两类新 kind 与状态事件同走一条通道（client_id 幂等不变）。
USAGE_KINDS = ('usage.session', 'usage.now')
POLICY_EVENT = 'policy.change'
SENSITIVE_MASK_PKG = 'masked.other'
SENSITIVE_MASK_NAME = '其他应用'

# 档位枚举（顺序即 UI 顺序：从详细到关闭）
POLICY_LEVELS = {
    'location_level': ('exact', 'street', 'off'),
    'usage_level': ('full', 'screen_only', 'off'),
    'app_level': ('stream', 'top5', 'off'),
    'network_level': ('ssid', 'type_only', 'off'),
}

# 缺省 policy：**不默认全开**——首次读到老数据时由四开关现状生成（见
# policy_from_switches）；这里的缺省只服务「完全没有历史」的全新用户。
DEFAULT_POLICY = {
    'global_off': False,
    'paused_until': None,
    'location_level': 'exact',
    'usage_level': 'full',
    'app_level': 'stream',
    'network_level': 'ssid',
    'battery': True,
    'battery_alert': True,
    'sensitive_pkgs': [],
    'fold_short': True,
}

# 老四开关 ↔ policy 的映射（回执须附此表，测试逐条锁死）：
#   location     ←→ location_level != 'off'
#   track        ←→ location_level != 'off'（轨迹与位置同档，令文明确）
#   usage        ←→ usage_level  != 'off'（app_level 随 usage 同开同关）
#   events       ← 独立键（报备通道开关，不被 policy 反写）
SWITCH_MAP_DOC = {
    'location': 'location_level != off',
    'track': 'location_level != off',
    'usage': 'usage_level != off',
    'events': '(独立键，不参与映射)',
}

SENSITIVE_MAX = 200
AUDIT_LIMIT = 100


def settings_key(user_id):
    return f'peer_settings:{user_id}'


def _raw_settings(c, user_id):
    """读原始设置 dict（含 policy）；坏值给 {}，不抛。"""
    raw = c.execute('SELECT value FROM app_state WHERE key=?',
                    (settings_key(user_id),)).fetchone()
    if not raw:
        return {}
    try:
        val = json.loads(raw['value'])
    except (ValueError, TypeError):
        return {}
    return val if isinstance(val, dict) else {}


def load_settings(c, user_id):
    """读某人的四类共享开关（缺省全开）——老口径，投影自 policy。"""
    saved = _raw_settings(c, user_id)
    return {k: bool(saved.get(k, True)) for k in SHARE_KEYS}


def normalize_policy(raw):
    """把任意输入夹成合法 policy（**不抛**）：档位非法回落缺省、类型错误的丢弃。

    规矩：档位只认枚举值；`paused_until` 只认正数或 null；`sensitive_pkgs`
    去空去重截断；bool 键只认真 bool。宁可回落缺省，也不许把脏值透传给
    裁剪逻辑（裁剪错一次就是隐私事故）。
    """
    p = dict(DEFAULT_POLICY)
    if not isinstance(raw, dict):
        return p
    p['global_off'] = bool(raw.get('global_off', False))
    until = raw.get('paused_until')
    if isinstance(until, (int, float)) and not isinstance(until, bool) and until > 0:
        p['paused_until'] = float(until)
    for key, allowed in POLICY_LEVELS.items():
        v = raw.get(key)
        p[key] = v if v in allowed else DEFAULT_POLICY[key]
    for key in ('battery', 'battery_alert', 'fold_short'):
        v = raw.get(key)
        p[key] = v if isinstance(v, bool) else DEFAULT_POLICY[key]
    pkgs = raw.get('sensitive_pkgs')
    if isinstance(pkgs, list):
        seen, out = set(), []
        for item in pkgs:
            name = str(item or '').strip()[:128]
            if name and name not in seen:
                seen.add(name)
                out.append(name)
            if len(out) >= SENSITIVE_MAX:
                break
        p['sensitive_pkgs'] = out
    return p


def policy_from_switches(sw, base=None):
    """老四开关 → policy（迁移口径：**全开过什么就什么档，不许默认全开**）。

    base 非空时只覆盖映射键，其余（battery / sensitive_pkgs / fold_short /
    global_off / paused_until）保持原值。
    """
    p = dict(base) if isinstance(base, dict) else dict(DEFAULT_POLICY)
    p = normalize_policy(p)
    loc_on = bool(sw.get('location', True))
    usage_on = bool(sw.get('usage', True))
    events_on = bool(sw.get('events', True))
    p['location_level'] = 'exact' if loc_on else 'off'
    p['usage_level'] = 'full' if usage_on else 'off'
    p['app_level'] = 'stream' if usage_on else 'off'
    p['network_level'] = 'ssid' if events_on else 'off'
    return p


def switches_from_policy(policy, events=True, track=None):
    """policy → 三键投影（events 独立，按传入值原样）。

    `track` 显式传入时按传入值（老客户端可只关历史轨迹、保留实时位置）；
    不传则与位置同档（令文「track ↔ 同 location」）。
    """
    p = normalize_policy(policy)
    loc_on = p['location_level'] != 'off'
    return {
        'location': loc_on,
        'track': loc_on if track is None else bool(track),
        'usage': p['usage_level'] != 'off',
        'events': bool(events),
    }


def load_policy(c, user_id):
    """读 policy；**无 policy 的老数据 → 按四开关现状生成**（不落库，只读生成）。

    首次写回时才会落库——读路径不产生副作用（GET 不写库是本仓惯例）。
    """
    saved = _raw_settings(c, user_id)
    if isinstance(saved.get('policy'), dict):
        return normalize_policy(saved['policy'])
    return policy_from_switches(
        {k: saved.get(k, True) for k in SHARE_KEYS})


def save_settings(c, user_id, data):
    """写设置（v2）：policy 为单一事实源，四开关是它的投影。

    三种入参形态（老客户端 / 新客户端 / 两者都带）都要能吃：
    ① 只带四开关 → 按映射生成 policy（迁移口径）；
    ② 只带 policy → 三键由 policy 推导，events 保持原值；
    ③ 都带 → **policy 决定三键**，events 以显式传入者为准。
    审计由调用方（save_settings_with_audit）负责，本函数只落库。
    """
    data = data if isinstance(data, dict) else {}
    saved = _raw_settings(c, user_id)
    old_policy = load_policy(c, user_id)
    old_events = bool(saved.get('events', True))

    has_policy = isinstance(data.get('policy'), dict)
    has_switch = any(k in data for k in SHARE_KEYS)

    if has_policy:
        policy = normalize_policy({**old_policy, **data['policy']})
        events = bool(data['events']) if 'events' in data else old_events
        # track 显式带就尊重（老客户端可只关历史轨迹），否则与位置同档
        track = bool(data['track']) if 'track' in data else None
        out = switches_from_policy(policy, events=events, track=track)
    elif has_switch:
        # 老客户端/老脚本：四键照抄（缺省 True），policy 按其现状生成。
        # track 独立保留——既有契约里「实时位置」与「历史轨迹」是两个开关。
        out = {k: bool(data.get(k, True)) for k in SHARE_KEYS}
        policy = policy_from_switches(out, base=old_policy)
    else:
        policy = normalize_policy(old_policy)
        out = switches_from_policy(policy, events=old_events)

    out['policy'] = policy
    c.execute('INSERT INTO app_state(key,value) VALUES (?,?) '
              'ON CONFLICT(key) DO UPDATE SET value=excluded.value',
              (settings_key(user_id),
               json.dumps(out, ensure_ascii=False, separators=(',', ':'))))
    return out, old_policy


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


# ── 分档：停用判定 / 审计 / 裁剪 ────────────────────────────────────

def halt_state(policy, now=None):
    """按 policy 判「停没停」：全局关闭优先，其次定时暂停。

    返回 {'halted','reason','until'}；reason ∈ ('', 'off', 'paused')。
    """
    now = time.time() if now is None else now
    if policy.get('global_off'):
        return {'halted': True, 'reason': 'off', 'until': None}
    until = policy.get('paused_until')
    if isinstance(until, (int, float)) and until > now:
        return {'halted': True, 'reason': 'paused', 'until': float(until)}
    return {'halted': False, 'reason': '', 'until': None}


_LEVEL_LABEL = {
    'location_level': {'exact': '精确轨迹', 'street': '仅街区', 'off': '关闭'},
    'usage_level': {'full': '时长+分布', 'screen_only': '仅亮灭屏', 'off': '关闭'},
    'app_level': {'stream': '精确时间流', 'top5': '仅 Top5', 'off': '关闭'},
    'network_level': {'ssid': '显示 SSID', 'type_only': '仅网络类型', 'off': '关闭'},
}
_LEVEL_NAME = {
    'location_level': '位置与轨迹',
    'usage_level': '手机使用情况',
    'app_level': '软件打开记录',
    'network_level': '网络与 Wi-Fi',
}


def describe_policy_changes(old, new):
    """两版 policy 的差异 → [(action, 人话 detail)]；空差返回 []。

    detail 就是对方审计页看到的原文，必须是人话、不带内部键名。
    """
    changes = []
    if bool(old.get('global_off')) != bool(new.get('global_off')):
        on = bool(new.get('global_off'))
        changes.append(('global_off', '完全关闭了报备' if on else '恢复了报备'))
    old_until, new_until = old.get('paused_until'), new.get('paused_until')
    if (old_until or None) != (new_until or None):
        if new_until:
            changes.append(('pause', f'暂停报备至 {_fmt_ts(new_until)}'))
        else:
            changes.append(('resume', '结束了暂停，恢复报备'))
    for key, labels in _LEVEL_LABEL.items():
        if old.get(key) != new.get(key):
            changes.append(
                (key, f'把{_LEVEL_NAME[key]}调为{labels.get(new.get(key), new.get(key))}'))
    if bool(old.get('battery', True)) != bool(new.get('battery', True)):
        changes.append(('battery',
                        '开启了电量与充电上报' if new.get('battery') else '关闭了电量与充电上报'))
    if bool(old.get('battery_alert', True)) != bool(new.get('battery_alert', True)):
        changes.append(('battery_alert',
                        '开启了低电量提醒' if new.get('battery_alert') else '关闭了低电量提醒'))
    if bool(old.get('fold_short', True)) != bool(new.get('fold_short', True)):
        changes.append(('fold_short',
                        '开启了短暂切换折叠' if new.get('fold_short') else '关闭了短暂切换折叠'))
    old_pkgs = list(old.get('sensitive_pkgs') or [])
    new_pkgs = list(new.get('sensitive_pkgs') or [])
    if old_pkgs != new_pkgs:
        added = [p for p in new_pkgs if p not in old_pkgs]
        removed = [p for p in old_pkgs if p not in new_pkgs]
        parts = []
        if added:
            parts.append(f'新增 {len(added)} 个')
        if removed:
            parts.append(f'移除 {len(removed)} 个')
        changes.append(('sensitive_pkgs',
                        f'调整了敏感应用清单（{"、".join(parts)}）'))
    return changes


def _fmt_ts(ts):
    """unix 秒 → 空间时区的「今天 08:00」级人话（审计展示用）。"""
    try:
        t = dt.datetime.fromtimestamp(float(ts))
    except (TypeError, ValueError, OSError):
        return '稍后'
    return t.strftime('%m-%d %H:%M')


def record_policy_audit(c, user_id, action, detail, ts=None):
    c.execute(
        'INSERT INTO peer_policy_audit(id,user,ts,action,detail) VALUES (?,?,?,?,?)',
        (uuid.uuid4().hex, user_id, float(ts if ts is not None else time.time()),
         str(action)[:32], str(detail)[:200]))


def save_settings_with_audit(c, user_id, data):
    """写设置 + 逐项落审计 + **把变更写进对方动态流**（policy.change）。

    返回 (settings, changes, revision)。
    """
    saved, old_policy = save_settings(c, user_id, data)
    changes = describe_policy_changes(old_policy, saved['policy'])
    for action, detail in changes:
        record_policy_audit(c, user_id, action, detail)
    if changes:
        # 审计行同时进事件流：对方动态流里能看到「TA 关闭了软件记录共享」类文案
        c.execute(
            'INSERT INTO peer_events(id,user,type,ts,summary,pushed,created,'
            "source,scene,note,place_name,client_id,payload) "
            "VALUES (?,?,?,?,?,0,?,'auto','','','','',?)",
            (uuid.uuid4().hex, user_id, POLICY_EVENT, time.time(),
             '；'.join(d for _, d in changes)[:200], time.time(),
             json.dumps({'changes': [{'action': a, 'detail': d} for a, d in changes]},
                        ensure_ascii=False, separators=(',', ':'))))
        rev = bump_peer_revision(c)
    else:
        rev = None
    return saved, changes, rev


def list_policy_audit(c, limit=AUDIT_LIMIT):
    """双方 policy 变更流水（倒序，上限 100 条，只读不可删）。"""
    rows = c.execute(
        'SELECT id,user,ts,action,detail FROM peer_policy_audit '
        'ORDER BY ts DESC, id DESC LIMIT ?', (int(limit),)).fetchall()
    return [dict(r) for r in rows]


def trim_snapshot(row, policy):
    """按属主 policy 裁剪最新快照里的网络字段（SSID / 网络类型整列）。

    `row` 是 `peer_location_latest` 的 dict 副本，**返回新 dict**（不改入参）。
    network_level=off → net/wifi 一并清空（等于「没有网络数据」）；
    type_only → 只清 SSID。
    """
    if not row:
        return row
    out = dict(row)
    level = policy.get('network_level', 'ssid')
    if level == 'off':
        out['net'] = None
        out['wifi'] = None
    elif level == 'type_only':
        out['wifi'] = None
    if not policy.get('battery', True):
        out['battery'] = None
        out['charging'] = None
    return out


def event_visible(etype, policy):
    """该类型事件是否允许被对方读到（按属主 policy）。"""
    if etype == POLICY_EVENT:
        return True
    if etype == 'state.net':
        return policy.get('network_level') != 'off'
    if etype == 'state.battery':
        return bool(policy.get('battery', True))
    if etype in ('state.screen', 'state.unlock'):
        return policy.get('usage_level') != 'off'
    if etype.startswith('usage.'):
        # 应用会话不进动态流（在手机页）；即便进来也不许越档
        return False
    return True


def trim_event(item, policy):
    """事件裁剪：按类型丢弃 / 清 SSID。返回 None 表示对方不该看到这条。"""
    etype = item.get('type') or ''
    if not event_visible(etype, policy):
        return None
    out = dict(item)
    if etype == 'state.net':
        level = policy.get('network_level', 'ssid')
        payload = dict(out.get('payload') or {})
        if level == 'type_only':
            payload['ssid'] = ''
        out['payload'] = payload
        # 文案同步：SSID 清掉后 summary 里不许还留着名字
        out['summary'] = state_summary('state.net', payload)
    if etype == 'state.battery' and not policy.get('battery', True):
        return None
    return out


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
        base = f'电量 {int(level)}%，充电中' if p.get('charging') else f'电量 {int(level)}%'
        return f'{base}（电量偏低）' if p.get('low') else base
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
    if kind == 'usage.session':
        app = str(p.get('app') or '').strip()
        if not app:
            app = SENSITIVE_MASK_NAME if p.get('masked') else '某个应用'
        dur = p.get('dur')
        if not isinstance(dur, (int, float)):
            return f'使用了{app}'
        return f'{app} {_duration_zh(int(dur))}'
    if kind == 'usage.now':
        app = str(p.get('app') or '').strip()
        if not app:
            app = SENSITIVE_MASK_NAME if p.get('masked') else '某个应用'
        return f'正在使用{app}'
    if kind == POLICY_EVENT:
        return '调整了报备共享设置'
    if kind == 'poke':
        return '戳了你一下'
    if kind == 'hug':
        return '抱了抱你'
    if kind == 'care':
        return str(p.get('text') or '').strip()[:60] or '惦记着你'
    return ''


def _duration_zh(sec):
    """秒 → 人话时长（与客户端 durationTextZh 同口径，服务端 summary 用）。"""
    sec = max(0, int(sec))
    if sec < 60:
        return '不足 1 分钟'
    m = sec // 60
    if m < 60:
        return f'{m} 分钟'
    h, rest = divmod(m, 60)
    return f'{h} 小时' if rest == 0 else f'{h} 小时 {rest} 分钟'


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


def validate_usage_payload(kind, payload):
    """应用使用事件 payload 校验（非法一律 ValueError → 422）。

    🔴 脱敏是**端侧**完成的，服务端只做一道"不许冒充"的检查：
    `masked=true` 时 pkg 必须是哨兵 `masked.other`，否则拒收——防止客户端
    一边声称已脱敏、一边把真实包名塞进来。
    """
    if not isinstance(payload, dict):
        raise ValueError('payload 必须是对象')
    masked = payload.get('masked') is True
    pkg = str(payload.get('pkg') or '').strip()[:128]
    app = str(payload.get('app') or '').strip()[:64]
    if masked:
        if pkg and pkg != SENSITIVE_MASK_PKG:
            raise ValueError('已脱敏的事件不许携带真实包名')
        pkg = SENSITIVE_MASK_PKG
        app = SENSITIVE_MASK_NAME
    if kind == 'usage.now':
        if not app:
            raise ValueError('app 不能为空')
        out = {'app': app, 'masked': masked, 'pkg': pkg}
        since = payload.get('since')
        if isinstance(since, (int, float)) and not isinstance(since, bool):
            out['since'] = float(since)
        return out

    if not pkg:
        raise ValueError('pkg 不能为空')
    if not app:
        raise ValueError('app 不能为空')
    start, end = payload.get('start'), payload.get('end')
    for name, v in (('start', start), ('end', end)):
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            raise ValueError(f'{name} 必须是数字')
    if float(end) < float(start):
        raise ValueError('end 不能早于 start')
    dur = payload.get('dur')
    if isinstance(dur, bool) or not isinstance(dur, (int, float)):
        dur = float(end) - float(start)
    dur = int(max(0, min(float(dur), 86400)))
    return {
        'pkg': pkg, 'app': app, 'start': float(start), 'end': float(end),
        'dur': dur, 'masked': masked,
    }


def validate_telemetry(kind, payload):
    """遥测类事件统一入口：state.* / usage.* 各自校验。"""
    if kind in STATE_KINDS:
        return validate_state_payload(kind, payload)
    if kind in USAGE_KINDS:
        return validate_usage_payload(kind, payload)
    raise ValueError(f'未知事件类型：{kind}')


def telemetry_allowed(kind, payload, policy, now=None):
    """写侧闸门：属主 policy 是否允许这条遥测。返回 None=允许，否则返回拒收原因。

    与读侧裁剪同一份 policy，口径一致（写侧拒收是防越权的第一道，读侧裁剪
    是第二道）。
    """
    halt = halt_state(policy, now=now)
    if halt['halted']:
        return '报备已关闭' if halt['reason'] == 'off' else '报备已暂停'
    if kind == 'state.net' and policy.get('network_level') == 'off':
        return '网络共享已关闭'
    if kind in ('state.screen', 'state.unlock') and policy.get('usage_level') == 'off':
        return '手机使用共享已关闭'
    if kind == 'state.battery' and not policy.get('battery', True):
        return '电量共享已关闭'
    if kind.startswith('usage.'):
        if policy.get('usage_level') == 'off':
            return '手机使用共享已关闭'
        if policy.get('app_level') == 'off':
            return '应用记录共享已关闭'
        # 会话明细在 top5 档**照收**（服务端要靠它算 Top5），只是读侧不给；
        # 「正在使用 X」属于时间流级细节，top5 档不收（否则等于绕过档位偷看）。
        if kind == 'usage.now' and policy.get('app_level') != 'stream':
            return '应用记录不是精确时间流档，不接收正在使用'
    return None


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
    elif kind == 'usage.session':
        # 应用会话：只更新当日 Top5 聚合列（围栏解除后此列正式启用）。
        # 🔴 口径：按 app 名汇总 dur；masked 会话的 app 名端侧已改写为
        # 「其他应用」，这里自然合并在同一个桶里，服务端不再识别真实包名。
        day = _space_day(c, event_ts)
        _merge_top_app(c, user_id, day, payload.get('app') or '',
                       int(payload.get('dur') or 0))
    # usage.now 不写汇总：快照的「正在使用」由读侧取最新一条 usage.now 事件派生


def _merge_top_app(c, user_id, day, app, dur):
    """把一次会话并进当日 Top5 聚合（内存里合、整列覆写，列表恒 ≤5）。"""
    if not app or dur <= 0:
        return
    row = c.execute('SELECT top_apps FROM peer_usage_daily WHERE user=? AND day=?',
                    (user_id, day)).fetchone()
    items = []
    if row and row['top_apps']:
        try:
            parsed = json.loads(row['top_apps'])
            if isinstance(parsed, list):
                items = [it for it in parsed
                         if isinstance(it, dict) and it.get('app')]
        except (ValueError, TypeError):
            items = []
    agg = {}
    for it in items:
        agg[str(it['app'])] = int(it.get('sec') or 0)
    agg[app] = agg.get(app, 0) + int(dur)
    top = sorted(agg.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
    c.execute(
        'INSERT INTO peer_usage_daily(user,day,screen_sec,unlocks,top_apps,updated) '
        'VALUES (?,?,0,0,?,?) '
        'ON CONFLICT(user,day) DO UPDATE SET '
        'top_apps=excluded.top_apps, updated=excluded.updated',
        (user_id, day,
         json.dumps([{'app': a, 'sec': s} for a, s in top],
                    ensure_ascii=False, separators=(',', ':')),
         time.time()))


def create_state_event(c, user_id, *, kind, payload, client_id='', ts=None):
    """创建一条遥测事件（state.* / usage.*；client_id 幂等，与主动报备同口径）。

    与 manual_report 的区别：source='auto'、scene/note/place_name 全空
    （**不污染主动报备的三个语义字段**）、payload 落 payload 列、不写通知中心
    （低电量提醒是唯一例外，见 _battery_crossed_low）。
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

    # 低电量跨越：**必须在写快照之前**判（旧电量只有这一刻读得到）
    low = False
    if kind == 'state.battery':
        low = _battery_crossed_low(c, user_id, payload)
        if low:
            payload = {**payload, 'low': True}

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
    if low:
        partner_id = peer_partner(c, user_id)
        if partner_id:
            db.notice(c, 'peer_battery_low',
                      f'TA 的手机电量低了（{int(payload["level"])}%）',
                      actor=user_id, recipient=partner_id)
    rev = bump_peer_revision(c)
    row = c.execute('SELECT * FROM peer_events WHERE id=?', (event_id,)).fetchone()
    return serialize_peer_event(row), True, rev


def _batt_alert_key(user_id):
    return f'peer_batt_armed:{user_id}'


def _batt_armed(c, user_id):
    """低电量提醒的「已武装」标记：无记录 = 武装（首次跌破就该提醒一次）。

    🔴 app_state.value 是 **INTEGER** 列：写 '1' 会存成整数 1，读回来是 int。
    比较一律走 `str(...)`，否则 `1 == '1'` 为假 → 永远「未武装」，第二次
    跌破就再也不会提醒（真机上一个跨日就复现）。
    """
    row = c.execute('SELECT value FROM app_state WHERE key=?',
                    (_batt_alert_key(user_id),)).fetchone()
    return not row or str(row['value']) == '1'


def _set_batt_armed(c, user_id, armed):
    c.execute('INSERT INTO app_state(key,value) VALUES (?,?) '
              'ON CONFLICT(key) DO UPDATE SET value=excluded.value',
              (_batt_alert_key(user_id), '1' if armed else '0'))


def _battery_crossed_low(c, user_id, payload):
    """判「这次上报是否构成一次跌破 20%」并翻转武装标记（不写通知）。

    口径：充电中不算；回升到 ≥25% 重新武装；20% ≤ level < 25% 只是回差带，
    不算跌破也不算回升。每次跨越只提醒一次（武装标记保证）。
    """
    policy = load_policy(c, user_id)
    if not policy.get('battery', True) or not policy.get('battery_alert', True):
        return False
    level = int(payload['level'])
    if payload.get('charging'):
        _set_batt_armed(c, user_id, True)
        return False
    if level >= 25:
        _set_batt_armed(c, user_id, True)
        return False
    if level >= 20:
        return False
    if not _batt_armed(c, user_id):
        return False
    _set_batt_armed(c, user_id, False)
    return True


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
