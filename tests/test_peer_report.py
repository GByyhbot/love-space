"""情侣主动报备（P0）pytest 验收测试（已对齐 experiment 分支真实契约）。

建议存放路径：tests/test_peer_report.py
覆盖范围：
1. db.init() 存量库幂等迁移与 peer_events 新增 8 列 / 部分唯一索引
2. 全局 X-Love-Space: 1 写门禁与 events 共享开关关闭时 422 拒绝
3. POST /api/peer/report 默认模板补全、peer_revision 递增与 db.notice 调用
4. client_id 弱网重试幂等防重（不重复入库、不重复推送）
5. POST /api/peer/events/{event_id}/ack 404 / 禁止自回应 400 / 伴侣回应 200
6. GET / PUT /api/peer/report-presets 模板读写与 12 条上限裁剪
7. peer.cleanup_expired() 仅清理 15 天前 auto 事件，保留 manual 手动报备
"""

import time

import pytest
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient

from app import db, peer, report_routes, security


@pytest.fixture()
def env(tmp_path, monkeypatch):
    """隔离临时 SQLite 数据库并构造挂载了真实 report_routes.router 的 TestClient。"""
    monkeypatch.setattr(db, 'DATA', tmp_path)
    db.init()

    now = time.time()
    # 补齐 users 表全部 NOT NULL 字段（id / username / password / name / created）
    with db.connect() as c:
        c.execute(
            "INSERT OR IGNORE INTO users(id, username, password, name, created) "
            "VALUES ('u1', 'u1', 'hashed_pw_1', '小明', ?), "
            "       ('u2', 'u2', 'hashed_pw_2', '小红', ?)",
            (now, now),
        )

    notices = []

    def fake_notice(c, event, title, *, actor=None, recipient=None):
        notices.append({
            'event': event,
            'title': title,
            'actor': actor,
            'recipient': recipient,
        })

    monkeypatch.setattr(db, 'notice', fake_notice)

    current_user = {'id': 'u1', 'username': 'u1', 'name': '小明'}

    app = FastAPI()

    # 模拟 app/main.py 全局写门禁中间件（拦截 POST/PUT 缺少 X-Love-Space: 1）
    @app.middleware('http')
    async def write_gate_middleware(request: Request, call_next):
        if request.method in ('POST', 'PUT', 'PATCH', 'DELETE'):
            if request.headers.get('X-Love-Space') != '1':
                return JSONResponse({'detail': 'missing X-Love-Space header'}, status_code=403)
        return await call_next(request)

    # 对齐真实 security.current_user（返回 user 行字典）
    app.dependency_overrides[security.current_user] = lambda: dict(current_user)
    app.include_router(report_routes.router)

    return {
        'client': TestClient(app),
        'current_user': current_user,
        'notices': notices,
    }


WRITE_HEADERS = {'X-Love-Space': '1'}


def test_init_migration_is_idempotent(env):
    """重复调用 db.init() 不报错，且 8 个新列与部分唯一索引均已就位。"""
    db.init()
    with db.connect() as c:
        cols = {r[1] for r in c.execute('PRAGMA table_info(peer_events)')}
        expected = {
            'source', 'scene', 'note', 'place_name',
            'client_id', 'ack_by', 'ack_emoji', 'ack_at',
        }
        assert expected.issubset(cols)

        indexes = {r[1] for r in c.execute('PRAGMA index_list(peer_events)')}
        assert 'peer_events_user_client' in indexes


def test_create_report_requires_write_header(env):
    """缺少全局写门禁头 X-Love-Space: 1 时应被拒绝。"""
    resp = env['client'].post('/api/peer/report', json={'scene': 'depart'})
    assert resp.status_code == 403


def test_create_report_blocked_when_events_share_disabled(env):
    """对齐现行 peer 口径：关闭 events 共享开关后，主动报备返回 422 且不入库、不推送。"""
    with db.connect() as c:
        peer.save_settings(
            c,
            'u1',
            {'location': True, 'track': True, 'events': False, 'usage': True},
        )

    resp = env['client'].post(
        '/api/peer/report',
        headers=WRITE_HEADERS,
        json={'scene': 'depart', 'note': '准备出门'},
    )
    assert resp.status_code == 422
    assert len(env['notices']) == 0

    with db.connect() as c:
        cnt = c.execute('SELECT COUNT(*) AS cnt FROM peer_events').fetchone()['cnt']
        assert cnt == 0


def test_create_report_uses_preset_defaults_and_notifies_partner(env):
    """发起快捷报备时自动补全默认摘要，递增 peer_revision 并调用 db.notice 通知伴侣。"""
    resp = env['client'].post(
        '/api/peer/report',
        headers=WRITE_HEADERS,
        json={'scene': 'arrive_home', 'note': '刚进门，准备洗漱', 'place_name': '家里'},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data['ok'] is True
    assert data['created'] is True
    assert data['peer_revision'] == 1

    ev = data['event']
    assert ev['user'] == 'u1'
    assert ev['source'] == 'manual'
    assert ev['scene'] == 'arrive_home'
    assert ev['summary'] == '平安到家啦'
    assert ev['note'] == '刚进门，准备洗漱'
    assert ev['place_name'] == '家里'
    assert ev['ack'] is None

    assert len(env['notices']) == 1
    assert env['notices'][0]['event'] == 'peer_report'
    assert env['notices'][0]['actor'] == 'u1'
    assert env['notices'][0]['recipient'] == 'u2'
    assert '平安到家啦' in env['notices'][0]['title']
    assert '刚进门，准备洗漱' in env['notices'][0]['title']


def test_create_report_client_id_idempotency(env):
    """同一用户携带相同 client_id 重试，不重复入库、不递增 revision、不重复通知。"""
    payload = {
        'scene': 'depart',
        'summary': '出发去公司了',
        'client_id': 'req-20261123-001',
    }
    first = env['client'].post('/api/peer/report', headers=WRITE_HEADERS, json=payload)
    second = env['client'].post('/api/peer/report', headers=WRITE_HEADERS, json=payload)

    assert first.status_code == 200
    assert second.status_code == 200

    d1, d2 = first.json(), second.json()
    assert d1['created'] is True
    assert d2['created'] is False
    assert d2['event']['id'] == d1['event']['id']
    assert d2['peer_revision'] is None

    with db.connect() as c:
        count = c.execute(
            "SELECT COUNT(*) AS cnt FROM peer_events WHERE client_id='req-20261123-001'"
        ).fetchone()['cnt']
        assert count == 1

    assert len(env['notices']) == 1


def test_ack_event_validation_and_partner_flow(env):
    """校验 404、禁止自回应 400 以及伴侣成功回应并反向调用 db.notice。"""
    created = env['client'].post(
        '/api/peer/report',
        headers=WRITE_HEADERS,
        json={'scene': 'sleep'},
    ).json()
    event_id = created['event']['id']

    # 1. 不存在的事件 -> 404
    missing = env['client'].post(
        '/api/peer/events/nonexistent/ack',
        headers=WRITE_HEADERS,
        json={'emoji': '❤️'},
    )
    assert missing.status_code == 404

    # 2. 发起人自己回应 -> 400
    self_ack = env['client'].post(
        f'/api/peer/events/{event_id}/ack',
        headers=WRITE_HEADERS,
        json={'emoji': '❤️'},
    )
    assert self_ack.status_code == 400

    # 3. 切换为伴侣 u2 回应 -> 200
    env['current_user'].update({'id': 'u2', 'username': 'u2', 'name': '小红'})
    partner_ack = env['client'].post(
        f'/api/peer/events/{event_id}/ack',
        headers=WRITE_HEADERS,
        json={'emoji': '🫂'},
    )
    assert partner_ack.status_code == 200
    ack_data = partner_ack.json()
    assert ack_data['ok'] is True
    assert ack_data['peer_revision'] == 2
    assert ack_data['event']['ack']['by'] == 'u2'
    assert ack_data['event']['ack']['emoji'] == '🫂'
    assert ack_data['event']['ack']['at'] is not None

    last_notice = env['notices'][-1]
    assert last_notice['event'] == 'peer_report_ack'
    assert last_notice['actor'] == 'u2'
    assert last_notice['recipient'] == 'u1'
    assert '🫂' in last_notice['title']


def test_report_presets_get_and_put(env):
    """未配置时返回默认模板；更新后持久化且最多保留 12 条。"""
    initial = env['client'].get('/api/peer/report-presets')
    assert initial.status_code == 200
    assert len(initial.json()['presets']) == len(peer.DEFAULT_REPORT_PRESETS)

    custom_presets = [
        {'scene': f's{i}', 'label': f'状态{i}', 'emoji': '✨', 'summary': f'报备{i}', 'push': True}
        for i in range(15)
    ]
    updated = env['client'].put(
        '/api/peer/report-presets',
        headers=WRITE_HEADERS,
        json={'presets': custom_presets},
    )
    assert updated.status_code == 200
    assert len(updated.json()['presets']) == 12

    reloaded = env['client'].get('/api/peer/report-presets')
    assert len(reloaded.json()['presets']) == 12
    assert reloaded.json()['presets'][0]['scene'] == 's0'


def test_cleanup_expired_keeps_manual_reports(env):
    """超过 15 天的自动守护事件会被清理，但手动情侣报备必须保留。"""
    now = time.time()
    old_ts = now - (peer.EVENT_RETENTION_DAYS + 5) * 86400

    with db.connect() as c:
        c.execute(
            '''
            INSERT INTO peer_events(id, user, type, ts, summary, pushed, created, source)
            VALUES ('auto_old', 'u1', 'arrive_place', ?, '到达公司', 1, ?, 'auto')
            ''',
            (old_ts, old_ts),
        )
        c.execute(
            '''
            INSERT INTO peer_events(id, user, type, ts, summary, pushed, created, source, scene)
            VALUES ('manual_old', 'u1', 'manual_report', ?, '平安到家啦', 1, ?, 'manual', 'arrive_home')
            ''',
            (old_ts, old_ts),
        )
        peer.cleanup_expired(c, now)

        remaining = {
            r['id'] for r in c.execute('SELECT id FROM peer_events').fetchall()
        }

    assert 'auto_old' not in remaining
    assert 'manual_old' in remaining