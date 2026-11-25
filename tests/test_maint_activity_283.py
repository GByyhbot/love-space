"""审计 P2-3 护栏：/api/status 的维护活性字段。

背景：2026-11-23 maintenance 停摆约 36h 无人知晓；2.8.2 的 P4 只覆盖「备份逾期
48h」，维护循环本身死没死在 /api/status 上不可见。本批补 last_maintenance_at /
maintenance_steps / pending_media / started_at。

三条：
① 字段形状稳定（四步恒定存在，每步三键，时间 UTC ISO）；
② 某步抛错时只有该步记为失败，其余步照常记 ok（与 2.8.2 的步骤隔离同源）；
③ pending_media 真实反映待转码行数（插一行 pending 再删）。
"""
import time

import pytest

from app import db, worker


@pytest.fixture
def keep_maint_state():
    """maintenance() 会改进程内全局状态，测完还原，避免污染其它用例。"""
    saved = {
        'last_at': worker._MAINT_STATE['last_at'],
        'steps': {k: dict(v) for k, v in worker._MAINT_STATE['steps'].items()},
    }
    yield
    worker._MAINT_STATE['last_at'] = saved['last_at']
    for k, v in saved['steps'].items():
        worker._MAINT_STATE['steps'][k] = v


# ① 形状稳定
def test_status_exposes_maintenance_activity(client_a):
    body = client_a.get('/api/status').json()

    for key in ('started_at', 'last_maintenance_at', 'maintenance_steps',
                'pending_media'):
        assert key in body, f'缺字段 {key}'

    # 进程启动时间一定有；last_maintenance_at 可能为 None（还没跑过一轮）
    assert body['started_at'] is not None and body['started_at'].endswith('+00:00')
    assert body['last_maintenance_at'] is None or body[
        'last_maintenance_at'].endswith('+00:00')

    steps = body['maintenance_steps']
    assert set(steps) == {'schedule', 'cleanup', 'peer_cleanup', 'backup'}, \
        '四步必须恒定存在（形状稳定，可被监控直接消费）'
    for name, st in steps.items():
        assert set(st) == {'last_ok', 'last_error_at', 'last_error'}, name
        assert st['last_error'] == '' or isinstance(st['last_error'], str)

    assert isinstance(body['pending_media'], int) and body['pending_media'] >= 0


# ② 步骤隔离 + 失败留痕
def test_failing_step_is_recorded_and_isolated(client_a, monkeypatch, keep_maint_state):
    ran = []

    monkeypatch.setattr(worker, 'schedule', lambda: ran.append('schedule'))
    monkeypatch.setattr(worker, 'cleanup', lambda: ran.append('cleanup'))

    def boom():
        raise RuntimeError('boom-for-test')

    monkeypatch.setattr(worker, '_peer_cleanup_step', boom)
    monkeypatch.setattr(worker, '_backup_step', lambda: ran.append('backup'))

    # 先清该步的历史成绩：全量跑时前面的用例可能已经让它 ok 过一次，
    # 否则「失败不该留 ok 时间」这条断言会随执行顺序飘
    worker._MAINT_STATE['steps']['peer_cleanup'] = {
        'last_ok': None, 'last_error_at': None, 'last_error': ''}
    # 其它步可能带着**别的用例**留下的历史错误摘要，所以「不受影响」的判据
    # 不是「没有错误」，而是「本次没有新写入」——对比错误时间戳。
    before = {k: v.get('last_error_at') for k, v in worker._MAINT_STATE['steps'].items()}

    worker.maintenance()

    # 失败不连累后续：backup 仍执行
    assert ran == ['schedule', 'cleanup', 'backup']
    st = worker.maintenance_state()
    assert st['maintenance_steps']['peer_cleanup']['last_error'].startswith('RuntimeError')
    assert st['maintenance_steps']['peer_cleanup']['last_error_at'] is not None
    assert st['maintenance_steps']['peer_cleanup']['last_ok'] is None, \
        '失败的那步不应留下 ok 时间'
    # 其余三步照常记 ok
    for name in ('schedule', 'cleanup', 'backup'):
        assert st['maintenance_steps'][name]['last_ok'] is not None, name
        assert worker._MAINT_STATE['steps'][name]['last_error_at'] == before[name], \
            f'{name} 的错误时间戳不该被本次运行改动'
    # 整轮已完成（last_at 有值），失败不影响「循环还在转」这个信号
    assert st['last_maintenance_at'] is not None


# ③ pending_media 真实反映
def test_pending_media_counts_real_rows(client_a):
    before = client_a.get('/api/status').json()['pending_media']
    me = client_a.get('/api/me').json()
    uid = me['user']['id']
    mid = 'test-pending-283'
    with db.connect() as c:
        c.execute(
            "INSERT INTO media(id,owner,name,mime,size,ext,status,created,attached)"
            " VALUES (?,?,?,?,?,?,?,?,0)",
            (mid, uid, 'p.jpg', 'image/jpeg', 3, '.jpg', 'pending', time.time()))
    try:
        after = client_a.get('/api/status').json()['pending_media']
        assert after == before + 1
    finally:
        with db.connect() as c:
            c.execute('DELETE FROM media WHERE id=?', (mid,))
