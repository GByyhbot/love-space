"""媒体转码链路的单元测试。

这条链路以前零测试（改之前 `grep -c process_media tests/` = 0），而它正是
「附件永久消失」这类不可逆问题的来源：转码不认领 → cleanup 抢先删行 →
结果写进空气 → 用户看到永远缺失的附件。下面每条都钉住一个具体的事故场景。
"""
import io
import shutil

import pytest
from PIL import Image

from app import db, worker
from app.db import connect, now

DAY = 86400


@pytest.fixture(scope='module', autouse=True)
def _schema():
    """单独跑本文件时 lifespan 不会触发，schema 得自己建（db.init 可重入）。

    顺便清空媒体表：验收测试留下了若干 pending 附件，claim 是「取最早的一条」，
    不清场的话本文件断言的会是别人的那条记录。
    """
    db.init()
    with connect() as c:
        c.execute('DELETE FROM import_messages')
        c.execute('DELETE FROM imports')
        c.execute('DELETE FROM media')


@pytest.fixture
def owner():
    """media.owner 是 users 的外键，得有个真实用户。"""
    with connect() as c:
        row = c.execute('SELECT id FROM users LIMIT 1').fetchone()
        if row:
            return row['id']
        uid = db.uid()
        c.execute('INSERT INTO users(id,username,password,name,created) VALUES (?,?,?,?,?)',
                  (uid, 'media-owner-' + uid[:8], 'x', '测试者', now()))
        return uid


def add_media(owner, mime='image/jpeg', ext='.jpg', *, attached=1, status='pending',
              created=None, payload=None):
    mid = db.uid()
    created = now() if created is None else created
    folder = db.media_dir(mime, created)
    folder.mkdir(parents=True, exist_ok=True)
    if payload is None:
        buf = io.BytesIO()
        Image.new('RGB', (240, 180), (200, 120, 140)).save(buf, 'JPEG')
        payload = buf.getvalue()
    (folder / (mid + ext)).write_bytes(payload)
    with connect() as c:
        c.execute('INSERT INTO media(id,owner,name,mime,size,ext,created,attached,status)'
                  ' VALUES (?,?,?,?,?,?,?,?,?)',
                  (mid, owner, 'test' + ext, mime, len(payload), ext, created, attached, status))
    return mid


def media_row(mid):
    with connect() as c:
        return c.execute('SELECT * FROM media WHERE id=?', (mid,)).fetchone()


def force_processing(mid):
    """把指定附件置为 processing 并返回它的 row。

    不用 claim_pending_media 是为了让断言锁定在"我造的那条"上——别的用例会留下
    pending/processing 的行，claim 取的是最早的一条，可能不是我要的。
    """
    with connect() as c:
        c.execute("UPDATE media SET status='processing' WHERE id=?", (mid,))
        return c.execute('SELECT * FROM media WHERE id=?', (mid,)).fetchone()


def test_claim_is_atomic_and_exclusive(owner):
    """认领后立刻变 processing，第二个 worker 不能再拿到同一个任务。"""
    mid = add_media(owner)
    with connect() as c:
        row = worker.claim_pending_media(c)
    assert row is not None and row['id'] == mid
    assert media_row(mid)['status'] == 'processing'
    with connect() as c:
        assert worker.claim_pending_media(c) is None  # 已被认领，不会被重复处理


def test_claim_ignores_unattached_media(owner):
    """未关联记录的孤儿附件不转码（省算力），也不该被认领。"""
    add_media(owner, attached=0)
    with connect() as c:
        assert worker.claim_pending_media(c) is None


def test_cleanup_does_not_delete_processing_media(owner):
    """正在转码的旧附件不能被 cleanup 物理删掉——删了转码结果就无处可写。"""
    old = now() - 40 * DAY
    safe = add_media(owner, status='processing', attached=0, created=old)
    doomed = add_media(owner, status='ready', attached=0, created=old)
    worker.cleanup()
    assert media_row(safe) is not None
    assert media_row(doomed) is None


def test_finish_media_after_row_vanished_leaves_no_orphan(owner):
    """行被删了还写成功 = 静默数据丢失。必须返回 False，并且清掉已生成的 preview。"""
    mid = add_media(owner)
    row = force_processing(mid)
    folder = db.media_dir(row['mime'], row['created'])
    (folder / 'preview.jpg').write_bytes(b'x')
    with connect() as c:
        c.execute('DELETE FROM media WHERE id=?', (mid,))
    assert worker.finish_media(row, 'ready', preview='preview.jpg') is False
    assert not (folder / 'preview.jpg').exists()  # 不能留下孤儿文件


def test_process_media_image_becomes_ready(owner):
    mid = add_media(owner)
    worker.process_media()
    row = media_row(mid)
    assert row['status'] == 'ready', row['error']
    assert row['preview'] == mid + '.preview.jpg'
    assert (db.media_dir(row['mime'], row['created']) / row['preview']).is_file()


def test_process_media_corrupt_file_falls_back_to_original(owner):
    """文件损坏时保留原文件，且错误信息里不能出现服务器路径。"""
    mid = add_media(owner, payload=b'not an image at all')
    worker.process_media()
    row = media_row(mid)
    assert row['status'] == 'original'
    assert row['error']
    assert str(db.DATA) not in row['error']


def test_process_media_without_ffmpeg_keeps_original(owner, monkeypatch):
    monkeypatch.setattr(shutil, 'which', lambda _cmd: None)
    mid = add_media(owner, mime='video/mp4', ext='.mp4', payload=b'\x00\x00\x00\x18ftypmp42')
    worker.process_media()
    row = media_row(mid)
    assert row['status'] == 'original'
    assert 'FFmpeg' in row['error']


def test_requeue_stuck_media(owner):
    """崩溃遗留的 processing 行必须在启动时回到 pending，否则永远卡死。"""
    stuck = add_media(owner, status='processing')
    assert worker.requeue_stuck_media() >= 1
    assert media_row(stuck)['status'] == 'pending'
    # 救回来之后要能被正常认领
    with connect() as c:
        assert worker.claim_pending_media(c) is not None


def shared_revision():
    with connect() as c:
        return c.execute("SELECT value FROM app_state WHERE key='content_revision'").fetchone()[0]


def test_mark_attached_does_not_leak_private_content(owner):
    """附件被引用不等于「对端该刷新」——引用它的记录/头像/设置自己有触发器。

    这条钉住的是：私密日记里带图不能推进共享 revision，否则对方光是收到一次
    refresh，就等于被告知"TA 刚写了点秘密"。
    """
    mid = add_media(owner, attached=0)
    before = shared_revision()
    with connect() as c:
        db.mark_attached(c, [mid])
    assert media_row(mid)['attached'] == 1
    assert shared_revision() == before


def test_finish_media_bumps_shared_revision_only_for_shared_media(owner):
    """转码完成要通知双方（否则对端永远停在黑底占位），但私密附件不能惊动对方。"""
    # 未出现在任何记录里 → 不算共享内容，不推进
    lone = add_media(owner)
    row = force_processing(lone)
    before = shared_revision()
    assert worker.finish_media(row, 'ready', preview='p.jpg') is True
    assert shared_revision() == before

    # 出现在一条共享记录里 → 要推进
    shared = add_media(owner)
    rid = db.uid()
    with connect() as c:
        c.execute('INSERT INTO records(id,kind,author,body,created,updated) VALUES (?,?,?,?,?,?)',
                  (rid, 'post', owner, db.dumps({'content': '看图', 'media': [shared]}), now(), now()))
    before = shared_revision()
    row = force_processing(shared)
    assert worker.finish_media(row, 'ready', preview='p.jpg') is True
    assert shared_revision() > before


def test_legacy_shared_media_trigger_is_removed():
    """存量库里的性能炸弹必须被 init() 主动拆掉。

    init() 里那层 DROP 循环按「表名_操作」匹配，而这条触发器叫
    ..._update_shared，匹配不到——不显式 DROP 的话，线上的老库会永远带着
    「每次 UPDATE media 就全表 records + json_each」继续跑。
    """
    with connect() as c:
        c.execute('DROP TRIGGER IF EXISTS revision_media_update_shared')
        c.execute('''CREATE TRIGGER revision_media_update_shared AFTER UPDATE ON media
          WHEN NEW.attached=1 AND EXISTS (SELECT 1 FROM records r, json_each(r.body,'$.media') j
            WHERE r.deleted IS NULL AND j.value=NEW.id)
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END''')
    db.init()  # 可重入
    with connect() as c:
        names = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='trigger'")}
    assert 'revision_media_update_shared' not in names
    assert 'revision_import_messages_insert' not in names


def test_run_ffmpeg_is_killable_by_stop_event():
    """stop 一置位就要 kill 掉子进程，否则容器 stop 时转码被硬杀、附件永远 pending。

    这里用 python 自己当"慢命令"，避免依赖本机是否装了 ffmpeg——run_ffmpeg 只是
    个通用的「可中断地跑外部命令」包装，拿谁测都行。
    """
    import subprocess  # noqa: F401  (确认该模块可用，与被测代码同依赖)
    import sys
    import threading

    stop = threading.Event()
    stop.set()
    with pytest.raises(worker.TranscodeAborted):
        worker.run_ffmpeg([sys.executable, '-c', 'import time; time.sleep(30)'], 60, stop)


def test_run_ffmpeg_timeout():
    """超时也要 kill，不能让一个卡住的 ffmpeg 把转码队列堵死。"""
    import sys

    with pytest.raises(__import__('subprocess').TimeoutExpired):
        worker.run_ffmpeg([sys.executable, '-c', 'import time; time.sleep(30)'], 1)
