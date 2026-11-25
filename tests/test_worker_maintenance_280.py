"""2.8.0 后端维护缺陷护栏：maintenance() 的 peer 清理调用链必须真实可跑。

背景（排查轮坐实）：worker.py 曾调用 peer.cleanup_expired 却未 import peer，
maintenance() 每 60s 抛一次 NameError（20 小时 1205 次），后果：
①peer 轨迹/事件 15 天滚动清理从未执行；②maintenance 在该行中断，其后的
自动备份判定块（worker.py:604 起）从未运行。

本护栏选型：**真实调用链冒烟测试**（不是仅 import 的断言）——
· 真跑一遍 worker.maintenance()，不捕获异常：修复前必 NameError 失败；
· 用 spy 包住 peer.cleanup_expired（内部仍调原函数），证明它是被**真实
  调用**的，而不是被跳过或替换；
· create_backup 打桩（备份会真的写近 1GB 包，测试不落盘），只防止
  「测试库里凑巧满足 24h 条件」时去跑真备份。
不 mock schedule/cleanup：那两段是 maintenance 的前半程，必须一起真跑，
否则证明不了「整轮跑通」。
"""
import pytest

from app import db, peer, worker


def _ensure_space():
    """maintenance→schedule() 读 space.timezone；测试库若尚未 setup 会 None 下标。
    只在缺失时补最小配置，幂等，不覆盖已有空间设置。"""
    db.init()   # 单跑本文件时 conftest 尚未触发 app 启动的建表；init 自身幂等
    with db.connect() as c:
        if db.setting(c, 'space') is None:
            db.set_setting(c, 'space', {
                'name': '测试空间', 'since': '', 'timezone': 'Asia/Shanghai',
            })


def test_maintenance_runs_with_peer_cleanup(monkeypatch):
    _ensure_space()

    calls = []
    real_cleanup = peer.cleanup_expired

    def spy(c, ts):
        calls.append(ts)
        return real_cleanup(c, ts)   # 内部仍执行真实清理

    monkeypatch.setattr(peer, 'cleanup_expired', spy)
    # 备份落盘打桩：只记录，不写包（磁盘细节可 mock，调用链不 mock）
    # 2.8.2 起 create_backup 带 anchor 参数，桩必须接住，否则 TypeError 会被
    # maintenance 的步骤隔离吞掉，护栏就假绿了。
    backups = []
    monkeypatch.setattr(worker, 'create_backup', lambda anchor='manual': backups.append(anchor))

    # 修复前此行必抛 NameError: name 'peer' is not defined
    worker.maintenance()

    assert calls, 'maintenance 必须真实调用 peer.cleanup_expired'
    assert worker.peer is peer, 'worker 必须 import 到同一个 peer 模块'


def test_worker_imports_peer_module():
    """最小回归钉：模块级 import 存在（防再次删掉/写错名字）。"""
    assert worker.peer.POINT_RETENTION_DAYS == 15
