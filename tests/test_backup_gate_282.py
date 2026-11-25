"""2.8.2 备份门控护栏（P0 步骤隔离 / P1 锚点分离 / P3 状态字段 / P4 逾期告警）。

来由（2026-11-24 诊断实证）：
· 11-22 20:01 `f7a11c8` 给 maintenance 加了 `peer.cleanup_expired` 却漏 import，
  每 60s 抛 NameError → **其后的备份块 36 小时未执行**，且失败告警代码就在
  那个块里，全程静默；
· 唯一锚点 `last_backup` 被任何来源的 create_backup 推进，部署备份一密集，
  自动备份就被无限后推（11-24/25 两天没出文件，不是漏跑而是从未到期）。
"""

import time

import pytest

from app import backups, db, main, worker


def _ensure_space():
    db.init()
    with db.connect() as c:
        if db.setting(c, 'space') is None:
            db.set_setting(c, 'space', {'name': '测试空间', 'since': '', 'timezone': 'Asia/Shanghai'})


def _fresh_gate(mp, last_auto=None, last_manual=None):
    """把锚点摆成指定状态，并给 create_backup 打桩（不落盘）。"""
    _ensure_space()
    calls = []
    mp.setattr(worker, 'create_backup', lambda anchor='manual': calls.append(anchor))
    with db.connect() as c:
        for key, val in (('last_backup', last_auto), ('last_backup_manual', last_manual)):
            c.execute('DELETE FROM settings WHERE key=?', (key,))
            if val is not None:
                db.set_setting(c, key, val)
    return calls


# ── P1：锚点分离 ──────────────────────────────────────────────────────
def test_manual_backup_does_not_postpone_auto_gate(client_a, monkeypatch):
    """手动备份刚做过，自动门控该到还是到（旧实现会被顺延）。"""
    now = time.time()
    calls = _fresh_gate(monkeypatch, last_auto=now - 25 * 3600, last_manual=now - 60)
    worker._backup_step()
    assert calls == ['auto'], '自动门控只看 last_backup，手动备份不得顺延它'


def test_auto_backup_just_ran_is_not_due(client_a, monkeypatch):
    now = time.time()
    calls = _fresh_gate(monkeypatch, last_auto=now - 3600, last_manual=now - 7200)
    worker._backup_step()
    assert calls == [], '距自动备份不足 24h 不该再跑'


def test_auto_gate_ignores_manual_anchor_entirely(client_a, monkeypatch):
    """只有手动锚、没有自动锚时，按「从未自动备份」处理 → 立即到期。"""
    now = time.time()
    calls = _fresh_gate(monkeypatch, last_auto=None, last_manual=now - 60)
    worker._backup_step()
    assert calls == ['auto'], '没有自动锚 = 从没自动跑过，不能因为手动备份过就一直不算'


def test_worker_passes_auto_anchor(client_a, monkeypatch):
    """worker 必须显式传 anchor='auto'，否则自己都不推自动锚。"""
    now = time.time()
    calls = _fresh_gate(monkeypatch, last_auto=now - 25 * 3600)
    worker._backup_step()
    assert calls == ['auto']


def test_create_backup_defaults_to_manual():
    """新增调用方忘传参时默认手动 —— 绝不污染自动门控。"""
    import inspect
    sig = inspect.signature(backups.create_backup)
    assert sig.parameters['anchor'].default == 'manual'


# ── P0：步骤隔离 ──────────────────────────────────────────────────────
def test_failing_step_does_not_kill_backup(client_a, monkeypatch):
    """peer 清理炸了，备份步骤照样跑（2026-11-23 的事故形态）。"""
    now = time.time()
    calls = _fresh_gate(monkeypatch, last_auto=now - 25 * 3600)
    monkeypatch.setattr(worker, 'peer_cleanup_step_should_not_exist', None, raising=False)

    def boom(c, ts):
        raise NameError("name 'peer' is not defined")

    monkeypatch.setattr(worker.peer, 'cleanup_expired', boom)
    monkeypatch.setattr(worker, 'schedule', lambda: None)
    monkeypatch.setattr(worker, 'cleanup', lambda: None)

    worker.maintenance()          # 不许抛
    assert calls == ['auto'], '前面步骤抛异常后，备份门控必须仍然执行'


def test_every_step_isolated(client_a, monkeypatch):
    """四步里任意一步炸，其余三步都必须留下痕迹。"""
    _ensure_space()
    hits = []
    monkeypatch.setattr(worker, 'schedule', lambda: (_ for _ in ()).throw(RuntimeError('s')))
    monkeypatch.setattr(worker, 'cleanup', lambda: hits.append('cleanup'))
    monkeypatch.setattr(worker.peer, 'cleanup_expired', lambda c, ts: hits.append('peer'))
    monkeypatch.setattr(worker, 'create_backup', lambda anchor='manual': hits.append('backup'))
    with db.connect() as c:
        db.set_setting(c, 'last_backup', time.time() - 25 * 3600)

    worker.maintenance()
    assert hits == ['cleanup', 'peer', 'backup'], '一步失败不得阻断后续步骤'


# ── P4：逾期告警 ──────────────────────────────────────────────────────
def test_stale_backup_warns_once_per_day(client_a, monkeypatch):
    _ensure_space()
    now = time.time()
    with db.connect() as c:
        c.execute("DELETE FROM notices WHERE event='backup'")
        db.set_setting(c, 'last_backup', now - 3 * 86400)
        db.set_setting(c, 'last_backup_manual', now - 3 * 86400)
    worker._warn_if_backup_stale()
    worker._warn_if_backup_stale()      # 同日重复调用只留一条
    with db.connect() as c:
        rows = c.execute("SELECT title, user_id FROM notices WHERE event='backup'").fetchall()
        people = c.execute('SELECT COUNT(*) FROM users').fetchone()[0]
    assert len(rows) == people, '每人一条、且同日重复调用不再新增（dedupe 按日）'
    assert all('没有成功备份' in r['title'] for r in rows)


def test_fresh_backup_does_not_warn(client_a, monkeypatch):
    _ensure_space()
    now = time.time()
    with db.connect() as c:
        c.execute("DELETE FROM notices WHERE event='backup'")
        db.set_setting(c, 'last_backup', now - 3600)
        db.set_setting(c, 'last_backup_manual', now - 5 * 86400)
    worker._warn_if_backup_stale()
    with db.connect() as c:
        n = c.execute("SELECT COUNT(*) FROM notices WHERE event='backup'").fetchone()[0]
    assert n == 0, '最近 48h 内有过成功备份（任意来源）就不该告警'


def test_stale_uses_latest_of_both_anchors(client_a, monkeypatch):
    """手动备份更近时，按手动那份算，不误报。"""
    _ensure_space()
    now = time.time()
    with db.connect() as c:
        c.execute("DELETE FROM notices WHERE event='backup'")
        db.set_setting(c, 'last_backup', now - 10 * 86400)
        db.set_setting(c, 'last_backup_manual', now - 3600)
    worker._warn_if_backup_stale()
    with db.connect() as c:
        n = c.execute("SELECT COUNT(*) FROM notices WHERE event='backup'").fetchone()[0]
    assert n == 0


# ── P3：/api/status 字段 ──────────────────────────────────────────────
def test_status_exposes_backup_gate(client_a, monkeypatch):
    now = time.time()
    with db.connect() as c:
        db.set_setting(c, 'last_backup', now - 7200)
        db.set_setting(c, 'last_backup_manual', now - 1800)
    body = client_a.get('/api/status').json()
    for key in ('last_backup', 'last_backup_manual', 'next_due', 'backup_age_hours'):
        assert key in body, key
    assert body['backup_age_hours'] is not None and 0 <= body['backup_age_hours'] < 1.5
    assert body['last_backup'] is not None and body['last_backup'].endswith('+00:00')
    assert body['next_due'] is not None


def test_status_backup_fields_null_when_never_backed_up(client_a):
    with db.connect() as c:
        c.execute("DELETE FROM settings WHERE key IN ('last_backup','last_backup_manual')")
    body = client_a.get('/api/status').json()
    assert body['last_backup'] is None
    assert body['next_due'] is None
    assert body['backup_age_hours'] is None
