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
