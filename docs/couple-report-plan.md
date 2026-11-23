# 情侣主动报备功能（P0）技术方案与入库施工说明（已对齐 `experiment` 分支）

本方案面向 [GByyhbot/love-space](https://github.com/GByyhbot/love-space) 仓库（建议存放路径：`docs/couple-report-plan.md`），已对照仓库现行 `app/db.py`、`app/peer.py`、`app/main.py` 与 `security` 模块完成契约对齐，可直接用于整包落地。

## 一、与现行仓库的 5 处契约对齐要点

1. **初始化入口为 `db.init()`**：`peer_events` 的幂等加列迁移追加到 `app/db.py` 的 `init()` 中（位于现有 `PRAGMA table_info(users)` 迁移块之后）。
2. **复用真实鉴权与全局写门禁**：路由直接使用 `Depends(security.current_user)`（返回 `users` 行字典，取 `u['id']`）；`X-Love-Space: 1` 由 `app/main.py` 全局中间件统一拦截 `POST`/`PUT`，路由层不再重复声明写门禁依赖。
3. **复用轮询 revision 与真实通知签名**：不引入虚构的 SSE 广播函数，写入/回应后直接递增 `app_state.peer_revision`（供现行探针轮询下发）；通知统一调用 `db.notice(c, event, title, actor=..., recipient=...)`（无 `body` 参数，将摘要与备注精炼拼入 `title`）。
4. **保持现行 `GET /api/peer/events` 外层形状不变**：不破坏已交付组件消费的 `{mine, peer: {events}}` 返回结构；仅在现行 SQL `SELECT` 中增量补列并附加可选新字段，确保老组件零回归。
5. **遵循 `events` 共享开关对等口径**：`POST /api/peer/report` 写入前检查 `peer.load_settings(c, user_id)['events']`，若已关闭则返回 `422` 拒绝，与现行 peer 套件口径一致。

## 二、数据库迁移（`app/db.py` -> `init()`）

### 1. `peer_events` 新增字段说明

| 字段名 | SQLite 类型 | 默认值 | 说明 |
| :--- | :--- | :--- | :--- |
| `source` | `TEXT NOT NULL` | `'auto'` | 来源区分：`'manual'`（主动报备）或 `'auto'`（自动守护） |
| `scene` | `TEXT NOT NULL` | `''` | 预设场景标识（如 `depart`、`arrive_home`、`meal`、`busy`、`sleep`、`miss`、`custom`） |
| `note` | `TEXT NOT NULL` | `''` | 报备文字备注（最长 500 字） |
| `place_name` | `TEXT NOT NULL` | `''` | 可选地点名称（手动填写或定位解析） |
| `client_id` | `TEXT NOT NULL` | `''` | 客户端幂等键，用于弱网重试防重 |
| `ack_by` | `TEXT NOT NULL` | `''` | 回应方 `users.id`（`TEXT`） |
| `ack_emoji` | `TEXT NOT NULL` | `''` | 回应表情（如 `❤️`、`🫂`、`👍`） |
| `ack_at` | `REAL` | `NULL` | 回应时间戳，`NULL` 表示对方尚未回应 |

### 2. 追加到 `app/db.py` 的 `init()` 中

```python
    # 2.8.x 情侣主动报备：peer_events 存量库幂等加列（与 users/media 同惯例）
    # ack_at 不给 NOT NULL — NULL 表示对方尚未回应
    _peer_event_cols = {r[1] for r in c.execute('PRAGMA table_info(peer_events)')}
    if 'source' not in _peer_event_cols:
        c.execute("ALTER TABLE peer_events ADD COLUMN source TEXT NOT NULL DEFAULT 'auto'")
    if 'scene' not in _peer_event_cols:
        c.execute("ALTER TABLE peer_events ADD COLUMN scene TEXT NOT NULL DEFAULT ''")
    if 'note' not in _peer_event_cols:
        c.execute("ALTER TABLE peer_events ADD COLUMN note TEXT NOT NULL DEFAULT ''")
    if 'place_name' not in _peer_event_cols:
        c.execute("ALTER TABLE peer_events ADD COLUMN place_name TEXT NOT NULL DEFAULT ''")
    if 'client_id' not in _peer_event_cols:
        c.execute("ALTER TABLE peer_events ADD COLUMN client_id TEXT NOT NULL DEFAULT ''")
    if 'ack_by' not in _peer_event_cols:
        c.execute("ALTER TABLE peer_events ADD COLUMN ack_by TEXT NOT NULL DEFAULT ''")
    if 'ack_emoji' not in _peer_event_cols:
        c.execute("ALTER TABLE peer_events ADD COLUMN ack_emoji TEXT NOT NULL DEFAULT ''")
    if 'ack_at' not in _peer_event_cols:
        c.execute('ALTER TABLE peer_events ADD COLUMN ack_at REAL')

    # 仅对携带 client_id 的手动报备做幂等防重（弱网重试不重复入流）
    c.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS peer_events_user_client "
        "ON peer_events(user, client_id) WHERE client_id<>''"
    )
```

## 三、业务与持久化扩展（`app/peer.py`）

保留 [app/peer.py](https://github.com/GByyhbot/love-space/blob/main/app/peer.py) 原有的常量及 `settings_key`、`load_settings`、`save_settings`、`peer_partner`，追加以下函数并替换 `cleanup_expired`：

```python
import json
import time
import uuid

from . import db

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
```

## 四、独立 FastAPI Router（新建 `app/report_routes.py`）

直接对接 `security.current_user`（返回 user 行字典）、`peer.load_settings`（422 开关校验）、`peer.bump_peer_revision`（轮询 revision）和 `db.notice(c, event, title, actor=..., recipient=...)`：

```python
"""情侣主动报备与回应（P0）独立 Router。

直接对齐现行仓库契约：
- 鉴权：Depends(security.current_user) -> 返回 user 行字典（取 u['id']）
- 写门禁：由 app/main.py 全局中间件统一拦截 POST/PUT 的 X-Love-Space: 1
- 实时同步：递增 app_state.peer_revision，由现行探针轮询下发
- 通知中心：db.notice(c, event, title, actor=..., recipient=...)
"""

from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from . import db, peer, security

router = APIRouter(prefix='/api/peer', tags=['peer-report'])


class ReportIn(BaseModel):
    scene: str = Field(default='custom', max_length=32)
    summary: str = Field(default='', max_length=120)
    note: str = Field(default='', max_length=500)
    place_name: str = Field(default='', max_length=80)
    push: Optional[bool] = None
    client_id: str = Field(default='', max_length=64)
    ts: Optional[float] = None


class AckIn(BaseModel):
    emoji: str = Field(default='❤️', max_length=8)


class PresetsIn(BaseModel):
    presets: list[dict]


def _format_report_notice_title(event: dict) -> str:
    extra = event['note'] or event['place_name']
    if extra:
        return f"{event['summary']} · {extra}"[:120]
    return event['summary'][:120]


@router.post('/report')
def create_report(body: ReportIn, u=Depends(security.current_user)):
    user_id = u['id']
    with db.connect() as c:
        # 对齐现行 peer 套件口径：events 共享关闭时 422 拒绝
        if not peer.load_settings(c, user_id)['events']:
            raise HTTPException(status_code=422, detail='报备事件共享已关闭')

        presets = {p['scene']: p for p in peer.load_report_presets(c)}
        should_push = (
            body.push
            if body.push is not None
            else bool(presets.get(body.scene, {}).get('push', True))
        )
        event, created, rev = peer.create_manual_report(
            c,
            user_id,
            scene=body.scene,
            summary=body.summary,
            note=body.note,
            place_name=body.place_name,
            push=should_push,
            client_id=body.client_id,
            ts=body.ts,
        )
        partner_id = peer.peer_partner(c, user_id)
        if created and should_push and partner_id:
            db.notice(
                c,
                'peer_report',
                _format_report_notice_title(event),
                actor=user_id,
                recipient=partner_id,
            )

    return {'ok': True, 'created': created, 'event': event, 'peer_revision': rev}


@router.post('/events/{event_id}/ack')
def ack_event(event_id: str, body: AckIn, u=Depends(security.current_user)):
    user_id = u['id']
    with db.connect() as c:
        event, status, rev = peer.ack_peer_event(c, user_id, event_id, body.emoji)
        if status == 'not_found':
            raise HTTPException(status_code=404, detail='报备事件不存在')
        if status == 'cannot_ack_own':
            raise HTTPException(status_code=400, detail='不能回应自己的报备')

        db.notice(
            c,
            'peer_report_ack',
            f"回应了你的报备 {body.emoji} · {event['summary']}"[:120],
            actor=user_id,
            recipient=event['user'],
        )

    return {'ok': True, 'event': event, 'peer_revision': rev}


@router.get('/report-presets')
def get_report_presets(u=Depends(security.current_user)):
    with db.connect() as c:
        return {'presets': peer.load_report_presets(c)}


@router.put('/report-presets')
def put_report_presets(body: PresetsIn, u=Depends(security.current_user)):
    with db.connect() as c:
        saved = peer.save_report_presets(c, body.presets)
        rev = peer.bump_peer_revision(c)
    return {'ok': True, 'presets': saved, 'peer_revision': rev}
```

## 五、`app/main.py` 挂载与现行 `GET /api/peer/events` 兼容改造

### 1. 挂载新 Router（只需 2 行）

```python
from . import report_routes

app.include_router(report_routes.router)
```

### 2. 现行 `GET /api/peer/events` 零破坏扩列

保持现行响应外层 `{mine, peer: {events}}` 及原有 5 个字段完全不动，仅在现行查询语句的 `SELECT` 中增量补齐以下列，并对每行叠加可选新字段（老组件忽略未知字段，新前端可直接读取 `source`、`scene`、`note`、`place_name`、`ack`）：

```sql
SELECT id, user, type, ts, summary, pushed, created,
       source, scene, note, place_name, client_id,
       ack_by, ack_emoji, ack_at
FROM peer_events
WHERE user=? AND ts>=? AND ts<?
ORDER BY ts DESC, created DESC
```

每条记录使用 `peer.serialize_peer_event(r)` 生成，仍装入现行 `{mine: [...], peer: {..., events: [...]}}` 结构返回。

## 六、施工验收清单

- [ ] `db.init()` 对存量库重复执行两次无报错，`peer_events` 包含全部 8 个新增列与唯一索引 `peer_events_user_client`。
- [ ] `events` 共享开关关闭时，`POST /api/peer/report` 返回 `422`，不写库、不发通知。
- [ ] 同一用户携带相同 `client_id` 连续两次 `POST /api/peer/report`，第二次返回 `created=False`、`peer_revision=None`，不重复入库且不重复调用 `db.notice`。
- [ ] `POST /api/peer/events/{id}/ack`：不存在返回 `404`；自己回应自己返回 `400`；伴侣回应返回 `200`，正确更新 `ack` 并调用 `db.notice(..., actor=伴侣, recipient=发起人)`。
- [ ] `GET /api/peer/events` 外层仍保持 `{mine, peer: {events}}` 形状，现行报备信息组件无回归。
- [ ] `peer.cleanup_expired(c, now)` 仅清理 15 天前 `source='auto'` 记录，保留 `source='manual'` 手动报备。
