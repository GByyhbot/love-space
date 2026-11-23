# 情侣主动报备功能（P0）技术方案与入库实现说明

本方案面向 [GByyhbot/love-space](https://github.com/GByyhbot/love-space) 仓库（建议存放路径：`docs/couple-report-plan.md`），在现有 `2.8.0` 定位守护底座（[app/db.py](https://github.com/GByyhbot/love-space/blob/main/app/db.py)、[app/peer.py](https://github.com/GByyhbot/love-space/blob/main/app/peer.py)）之上，以**最小改动、零破坏存量契约**的方式补齐「一键主动报备 + 伴侣即时回应（Ack）+ 多渠道推送」闭环。

## 一、设计原则与核心取舍

1. **复用 `peer_events` 与 `peer_revision`**：手动报备与自动定位守护共享同一事件流和 SSE 增量版本号，避免引入第三套数据流和通知逻辑。
2. **存量库幂等迁移**：沿用 [app/db.py](https://github.com/GByyhbot/love-space/blob/main/app/db.py) 现有的 `PRAGMA table_info(...)` + `ALTER TABLE ... ADD COLUMN` 惯例，升级无感且可重复执行。
3. **保护手动报备不被误清理**：`app/peer.py` 原有 `cleanup_expired()` 会按 15 天滚动删除所有 `peer_events`，本方案将其收窄为仅删除 `source='auto'` 的自动守护事件，长期保留情侣手动报备记录。
4. **模块化隔离**：新增路由放在独立文件 `app/report_routes.py`，通过工厂函数注入 `app/main.py` 现有的鉴权、写门禁、SSE 广播和通知回调，不再向 `app/main.py` 堆叠业务代码。

## 二、数据库变更（`app/db.py`）

### 1. `peer_events` 新增字段说明

| 字段名 | SQLite 类型 | 默认值 | 说明 |
| :--- | :--- | :--- | :--- |
| `source` | `TEXT NOT NULL` | `'auto'` | 来源区分：`'manual'`（主动报备）或 `'auto'`（自动守护） |
| `scene` | `TEXT NOT NULL` | `''` | 预设场景标识（如 `depart`、`arrive_home`、`meal`、`busy`、`sleep`、`miss`、`custom`） |
| `note` | `TEXT NOT NULL` | `''` | 报备文字备注（最长 500 字） |
| `place_name` | `TEXT NOT NULL` | `''` | 可选地点名称（手动填写或定位解析） |
| `client_id` | `TEXT NOT NULL` | `''` | 客户端幂等键，用于弱网重试防重 |
| `ack_by` | `TEXT NOT NULL` | `''` | 回应方 `users.id`（与 `users.id` 保持 `TEXT` 一致） |
| `ack_emoji` | `TEXT NOT NULL` | `''` | 回应表情（如 `❤️`、`🫂`、`👍`） |
| `ack_at` | `REAL` | `NULL` | 回应时间戳，`NULL` 表示对方尚未回应 |

### 2. 迁移代码（追加至 `app/db.py` 的 `init_db()` 中）

放在 `init_db()` 现有的 `PRAGMA table_info(users)` 迁移逻辑之后：

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

## 三、数据存取与业务逻辑扩展（`app/peer.py`）

保留 [app/peer.py](https://github.com/GByyhbot/love-space/blob/main/app/peer.py) 原有的常量及 `settings_key`、`load_settings`、`save_settings`、`peer_partner`，追加以下内容并替换 `cleanup_expired`：

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
    """递增 peer_revision 并返回最新版本号，供 SSE 下发。"""
    c.execute(
        "UPDATE app_state SET value = CAST(value AS INTEGER) + 1 "
        "WHERE key='peer_revision'"
    )
    row = c.execute("SELECT value FROM app_state WHERE key='peer_revision'").fetchone()
    return int(row['value']) if row else 0


def serialize_peer_event(row):
    return {
        'id': row['id'],
        'user': row['user'],
        'type': row['type'],
        'source': row['source'],
        'scene': row['scene'],
        'ts': row['ts'],
        'summary': row['summary'],
        'note': row['note'],
        'place_name': row['place_name'],
        'pushed': row['pushed'],
        'created': row['created'],
        'client_id': row['client_id'],
        'ack': (
            {
                'by': row['ack_by'],
                'emoji': row['ack_emoji'],
                'at': row['ack_at'],
            }
            if row['ack_at'] is not None
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

### 1. 接口契约一览

| 方法与路径 | 写门禁 | 作用 | SSE / 推送行为 |
| :--- | :--- | :--- | :--- |
| `POST /api/peer/report` | 需要 `X-Love-Space: 1` | 发起一次主动报备（支持 `client_id` 幂等） | 递增 `peer_revision`，广播 `peer_report`，按开关推送伴侣 |
| `POST /api/peer/events/{event_id}/ack` | 需要 `X-Love-Space: 1` | 伴侣一键回应报备（禁止自回应） | 递增 `peer_revision`，广播 `peer_report_ack`，推送告知发送方 |
| `GET /api/peer/report-presets` | 无 | 读取双人快捷报备模板 | 无 |
| `PUT /api/peer/report-presets` | 需要 `X-Love-Space: 1` | 更新双人快捷报备模板（最多 12 条） | 递增 `peer_revision`，广播 `peer_presets` |

### 2. 路由实现代码（`app/report_routes.py`）

```python
"""情侣主动报备与回应（P0）独立 Router。"""

from typing import Optional
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from . import db, peer


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


def make_report_router(
    *,
    require_user,
    require_write,
    broadcast_peer,
    notify_partner,
):
    """
    参数说明（均直接传入 app/main.py 现有函数）：
    - require_user: 校验 love_session Cookie 并返回当前 user_id 的依赖
    - require_write: 校验 X-Love-Space: 1 写门禁的依赖
    - broadcast_peer(rev: int, event_type: str, payload: dict): 广播 SSE 事件
    - notify_partner(c, partner_id: str, title: str, body: str, kind: str, ref_id: str): 写入 notices 并触发外发推送
    """
    router = APIRouter(prefix='/api/peer', tags=['peer-report'])

    @router.post('/report', dependencies=[Depends(require_write)])
    def create_report(body: ReportIn, user_id: str = Depends(require_user)):
        with db.connect() as c:
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
                notify_body = event['note'] or event['place_name'] or event['summary']
                notify_partner(
                    c,
                    partner_id,
                    title=event['summary'],
                    body=notify_body,
                    kind='peer_report',
                    ref_id=event['id'],
                )

        if created and rev is not None:
            broadcast_peer(rev, 'peer_report', event)
        return {'ok': True, 'created': created, 'event': event, 'peer_revision': rev}

    @router.post('/events/{event_id}/ack', dependencies=[Depends(require_write)])
    def ack_event(event_id: str, body: AckIn, user_id: str = Depends(require_user)):
        with db.connect() as c:
            event, status, rev = peer.ack_peer_event(c, user_id, event_id, body.emoji)
            if status == 'not_found':
                raise HTTPException(status_code=404, detail='报备事件不存在')
            if status == 'cannot_ack_own':
                raise HTTPException(status_code=400, detail='不能回应自己的报备')

            notify_partner(
                c,
                event['user'],
                title=f"对方回应了你的报备 {body.emoji}",
                body=event['summary'],
                kind='peer_report_ack',
                ref_id=event['id'],
            )

        broadcast_peer(rev, 'peer_report_ack', event)
        return {'ok': True, 'event': event, 'peer_revision': rev}

    @router.get('/report-presets')
    def get_report_presets(user_id: str = Depends(require_user)):
        with db.connect() as c:
            return {'presets': peer.load_report_presets(c)}

    @router.put('/report-presets', dependencies=[Depends(require_write)])
    def put_report_presets(body: PresetsIn, user_id: str = Depends(require_user)):
        with db.connect() as c:
            saved = peer.save_report_presets(c, body.presets)
            rev = peer.bump_peer_revision(c)
        broadcast_peer(rev, 'peer_presets', {'presets': saved})
        return {'ok': True, 'presets': saved, 'peer_revision': rev}

    return router
```

## 五、`app/main.py` 挂载方式

在 `app/main.py` 路由注册处挂载新 Router，并将现有 `GET /api/peer/events` 的单行序列化改为调用 `peer.serialize_peer_event(r)`：

```python
from .report_routes import make_report_router

app.include_router(
    make_report_router(
        require_user=你的现有鉴权依赖,
        require_write=你的现有写门禁依赖,
        broadcast_peer=lambda rev, typ, payload: 你的现有SSE广播函数(...),
        notify_partner=lambda c, uid, title, body, kind, ref_id: 你的现有写notices与推送函数(...),
    )
)
```

## 六、入库前最小验收清单

- [ ] 存量 `love.db` 启动时 `init_db()` 幂等执行两次不报错，`PRAGMA table_info(peer_events)` 包含全部 8 个新增列。
- [ ] `POST /api/peer/report` 传入相同 `client_id` 连续请求两次，仅生成 1 条记录且不重复推送。
- [ ] 发起人自己调用 `POST /api/peer/events/{id}/ack` 返回 `400`；伴侣调用返回 `200`，且 `GET /api/peer/events` 返回完整的 `ack` 对象。
- [ ] `cleanup_expired()` 执行后，超过 15 天的 `source='auto'` 记录被清理，`source='manual'` 手动报备记录保留。
