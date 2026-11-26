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
    # 2.8.7 自动报备：设备状态事件。kind 以 'state.' 开头即走状态分支，
    # payload 是结构化载荷；两者对主动报备（manual_report）一律忽略，
    # 保证主动报备的 scene/note/place_name 语义不被污染。
    kind: str = Field(default='', max_length=32)
    payload: Optional[dict] = None


class AckIn(BaseModel):
    emoji: str = Field(default='❤️', max_length=8)


# 2.8.7 全量：互动抽屉三类（戳一下 / 抱抱 / 提醒）——走同一条报备通道，
# 不新建通道。频控：每类每小时 ≤6 次，超限 422（服务端是权威，端上只做提示）。
POKE_SCENES = ('poke', 'hug', 'care')
POKE_HOURLY_LIMIT = 6


def _poke_recent_count(c, user_id, scene):
    import time as _t
    since = _t.time() - 3600
    row = c.execute(
        'SELECT count(*) n FROM peer_events WHERE user=? AND scene=? AND '
        "type='manual_report' AND ts>=?", (user_id, scene, since)).fetchone()
    return int(row['n']) if row else 0


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

        # 状态/使用事件分支：与主动报备共用同一通道与 client_id 幂等，但写入
        # type='state.*' / 'usage.*'、source='auto'，不写通知中心（低电量提醒除外）。
        if body.kind:
            if body.kind not in peer.STATE_KINDS + peer.USAGE_KINDS:
                raise HTTPException(422, f'未知事件类型：{body.kind}')
            # 写侧闸门（第一道）：按**属主** policy 拒收越档遥测。
            # 手动报备不受此闸门影响（暂停/关闭期间照常可发）。
            reason = peer.telemetry_allowed(
                body.kind, body.payload, peer.load_policy(c, user_id))
            if reason:
                raise HTTPException(422, reason)
            try:
                payload = peer.validate_telemetry(body.kind, body.payload)
            except ValueError as e:
                raise HTTPException(422, str(e))
            event, created, rev = peer.create_state_event(
                c,
                user_id,
                kind=body.kind,
                payload=payload,
                client_id=body.client_id,
                ts=body.ts,
            )
            return {'ok': True, 'created': created, 'event': event,
                    'peer_revision': rev}

        presets = {p['scene']: p for p in peer.load_report_presets(c)}
        # 互动抽屉：同一类每小时最多 6 次（防刷屏；对方看到的是有节制的关心）
        if body.scene in POKE_SCENES and _poke_recent_count(
                c, user_id, body.scene) >= POKE_HOURLY_LIMIT:
            raise HTTPException(422, '这一类每小时最多 6 次，先歇一会儿吧')
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
            title = _format_report_notice_title(event)
            # 互动类的通知标题必须是明文「TA 戳了你一下」（2.8.1 口径）
            if body.scene in POKE_SCENES:
                title = f'TA {event["summary"]}'[:120]
            db.notice(
                c,
                'peer_report',
                title,
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
