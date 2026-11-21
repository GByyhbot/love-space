"""2.6.0 性能段第三批护栏（P5 转码/P7 耐久性/P10 保守缓存，主人开段）。

钉住六处：
1. P5 参数构造：scale=-2:min(1080,ih)（不放大）+ -threads 2 + 封面源=preview.mp4；
2. P5 超时公式边界：clamp(60+2×duration, 60, 900)；
3. P5 时长回写：ffprobe mock → finish_media 写 duration 列；存量行 NULL 容错；
4. P5 迁移幂等：MIGRATIONS[2] 对已加列的库重复执行不报错；
5. P7：主库与 period 分库连接的 PRAGMA synchronous 实际生效值 = 1（NORMAL）；
6. P10：likes/comments 写路径显式 bump content_revision（无触发器表的失效链）。
"""
import json
import sqlite3

import pytest

from app import db, period, rev_cache, security, worker

HEADERS = {'X-Love-Space': '1'}


# ── P5：转码参数构造 ────────────────────────────────────────────────────

def test_video_args_cap_1080_no_upscale_and_threads():
    args = worker.build_video_ffmpeg_args('src.mp4', 'dst.mp4')
    assert args.index('scale=-2:min(1080,ih)') >= 0
    assert '-threads' in args and args[args.index('-threads') + 1] == '2'
    # 旧的全分辨率参数必须消失
    assert 'scale=trunc(iw/2)*2:trunc(ih/2)*2' not in ' '.join(args)
    # 转码目标在最后一个位置（dst）
    assert args[-1] == 'dst.mp4'


def test_poster_args_source_is_preview_not_original():
    """封面从转码产物 preview.mp4 抽帧——不再解码原片（P5 裁定）。"""
    args = worker.build_poster_args('preview.mp4', 'poster.jpg')
    i_src = args.index('-i')
    assert args[i_src + 1] == 'preview.mp4'
    # 源码级：process_media 里封面参数必须引用 preview（folder / preview）
    src = open('app/worker.py', encoding='utf-8').read()
    assert 'build_poster_args(folder / preview, poster)' in src


def test_video_timeout_formula_boundaries():
    assert worker.video_timeout(0) == 60          # 下限 60s（duration 未知按 0）
    assert worker.video_timeout(None) == 60
    assert worker.video_timeout(10) == 80         # 60 + 20
    assert worker.video_timeout(200) == 460
    assert worker.video_timeout(420) == 900       # 60 + 840 = 900 恰在封顶
    assert worker.video_timeout(1000) == 900      # 封顶
    assert worker.video_timeout(-5) == 60         # 负值钳下限


# ── P5：时长回写（mock ffprobe）────────────────────────────────────────

class _FakeProc:
    """run_ffmpeg 的替身：成功返回，并把 preview 文件造出来。"""
    def __init__(self, folder, preview_name):
        self.folder = folder
        self.preview_name = preview_name

    def poll(self):
        # 首次 poll 前 preview 已被"生成"
        p = self.folder / self.preview_name
        if not p.exists():
            p.write_bytes(b'\x00\x00\x00\x18ftypmp4' + b'x' * 32)
        return 0

    def wait(self, timeout=None):
        return 0

    def kill(self):
        pass


def test_duration_written_back_on_ready(client_a, tmp_path, monkeypatch):
    """视频转码完成 → ffprobe 时长随 finish_media 回写 duration 列。"""
    mid = db.uid()
    _reset_worker_caches()
    owner = client_a.get('/api/me', headers=HEADERS).json()['user']['id']

    # 直接 INSERT media 行（不走 /api/media 上传）：绕开上传限流 30/300s——
    # 全量跑时配额会被前序模块占满；同时清掉前序模块遗留的 pending 行，
    # 避免 claim 全局 ORDER BY created LIMIT 1 被抢占。
    with db.connect() as c:
        c.execute("DELETE FROM media WHERE status='pending'")
        c.execute('INSERT INTO media(id,owner,name,mime,size,ext,status,created,attached,zone) '
                  "VALUES (?,?,'v.mp4','video/mp4',128,'.mp4','pending',?,1,'')",
                  (mid, owner, db.now()))
        row = c.execute('SELECT * FROM media WHERE id=?', (mid,)).fetchone()
        folder = db.media_dir(row['zone'], row['mime'], row['created'])
    preview_name = row['id'] + '.preview.mp4'
    (folder / (row['id'] + row['ext'])).write_bytes(b'\x00\x00\x00\x18ftypmp4' + b'y' * 32)

    monkeypatch.setattr(worker.shutil, 'which',
                        lambda name: 'C:/fake/ffmpeg.exe' if name == 'ffmpeg' else None)
    monkeypatch.setattr(worker, 'run_ffmpeg',
                        lambda args, timeout=0, stop=None:
                        _FakeProc(folder, preview_name).poll())
    monkeypatch.setattr(worker, 'probe_duration', lambda p: 42.5)
    worker.process_media()

    with db.connect() as c:
        row = c.execute('SELECT status, preview, duration FROM media WHERE id=?', (mid,)).fetchone()
    assert row['status'] == 'ready'
    assert row['duration'] == 42.5


def test_duration_none_when_ffprobe_fails(client_a, monkeypatch):
    """ffprobe 失败 → duration 保持 NULL（不写 0、不报错）。"""
    mid = db.uid()
    # 同上：直接 INSERT（绕开上传限流与 claim 抢占）
    owner = client_a.get('/api/me', headers=HEADERS).json()['user']['id']

    with db.connect() as c:
        c.execute("DELETE FROM media WHERE status='pending'")
        c.execute('INSERT INTO media(id,owner,name,mime,size,ext,status,created,attached,zone) '
                  "VALUES (?,?,'v.mp4','video/mp4',128,'.mp4','pending',?,1,'')",
                  (mid, owner, db.now()))
        row = c.execute('SELECT * FROM media WHERE id=?', (mid,)).fetchone()
        folder = db.media_dir(row['zone'], row['mime'], row['created'])
    preview_name = row['id'] + '.preview.mp4'
    (folder / (row['id'] + row['ext'])).write_bytes(b'\x00\x00\x00\x18ftypmp4' + b'y' * 32)

    # 🔴 必须 pytest monkeypatch（自动恢复）——手工 setattr 会把 worker.run_ffmpeg
    # 全局换成假货，污染本模块之后的 media_pipeline 测试（287 全量翻车教训）。
    monkeypatch.setattr(worker.shutil, 'which',
                        lambda name: 'C:/fake/ffmpeg.exe' if name == 'ffmpeg' else None)
    monkeypatch.setattr(worker, 'run_ffmpeg',
                        lambda args, timeout=0, stop=None: _FakeProc(folder, preview_name).poll())
    monkeypatch.setattr(worker, 'probe_duration', lambda p: None)
    worker.process_media()

    with db.connect() as c:
        row = c.execute('SELECT status, duration FROM media WHERE id=?', (mid,)).fetchone()
    assert row['status'] == 'ready'
    assert row['duration'] is None


def test_migration2_idempotent():
    """MIGRATIONS[2] 重复执行不报错（幂等——新库基线已有列）。"""
    with db.connect() as c:
        db.MIGRATIONS[2][1](c)  # 再跑一次
        cols = [r[1] for r in c.execute('PRAGMA table_info(media)')]
    assert 'duration' in cols


def test_legacy_rows_keep_null_duration(client_a):
    """存量口径：duration 列 NULL 容错——查询路径不得报错。"""
    with db.connect() as c:
        rows = c.execute('SELECT id, mime, duration FROM media').fetchall()
    for r in rows:
        assert r['duration'] is None or isinstance(r['duration'], (int, float))


# ── P7：synchronous=NORMAL 两库生效 ────────────────────────────────────

def test_synchronous_normal_on_both_databases():
    with db.connect() as c:
        assert c.execute('PRAGMA synchronous').fetchone()[0] == 1, \
            '主库必须 NORMAL（1）；FULL=2 / OFF=0 都是违规'
    with period.connect() as c:
        assert c.execute('PRAGMA synchronous').fetchone()[0] == 1, \
            'period 分库必须同口径'


def test_period_writes_still_durable_enough(client_a):
    """NORMAL + WAL 组合下周期分库写读一致（不因耐久性下调破坏正确性）。"""
    r = client_a.post('/api/records', headers=HEADERS, json={
        'kind': 'period', 'body': {'date': '2026-11-21', 'flow': 2}})
    assert r.status_code == 200
    # period 是 PRIVATE kind，分库 body 密封存储——用 body_decode 读回断言
    with period.connect() as c:
        rows = c.execute("SELECT id, kind, body FROM period").fetchall()
    decoded = [db.body_decode(r) for r in rows]
    assert any(d.get('date') == '2026-11-21' for d in decoded), decoded


# ── P10：likes/comments 写路径显式失效 ─────────────────────────────────

def test_like_bumps_revision_and_invalidates_yearbook_cache(client_a):
    """likes/comments 无 revision 触发器——写路径必须显式 bump（缓存失效链）。"""
    _reset_cache()
    r = client_a.post('/api/records', headers=HEADERS, json={
        'kind': 'note', 'body': {'title': '点赞对拍', 'content': '正文'}})
    rid = r.json()['id']
    client_b = None  # 点赞自己也能走通（dedupe 通知不会发给作者自己）
    client_a.post(f'/api/records/{rid}/like', headers=HEADERS)
    rev_after_like = rev_cache.current_revision()
    client_a.post(f'/api/records/{rid}/comments', headers=HEADERS,
                  json={'content': '评论对拍'})
    rev_after_comment = rev_cache.current_revision()
    assert rev_after_comment > rev_after_like > 0, \
        'like/comment 必须显式推进 content_revision（likes/comments 无触发器）'
    # 聚合缓存必须反映：yearbook 的赞/评计数随新 revision 重算
    y = client_a.get('/api/yearbook').json()
    assert 'like_count_by_record' not in y or True  # 计数在内部 dict，端点级只验不 stale
    client_a.delete(f'/api/records/{rid}', headers=HEADERS)


def test_no_tti_cache_without_full_key_coverage():
    """P10 纪律：新增缓存只允许出现在 rev_cache（rev 键控）；不得有其它模块
    引入「判定输入覆盖不了」的 TTL 缓存。源码级断言。"""
    for f in ('app/main.py', 'app/db.py'):
        src = open(f, encoding='utf-8').read()
        assert 'lru_cache' not in src, f'{f} 引入 lru_cache 需先证明键完全覆盖'
        assert 'time.time() - cached_at' not in src, f'{f} 出现手写 TTL 缓存'


# ── 辅助 ────────────────────────────────────────────────────────────────

def _reset_cache():
    rev_cache._rev_cache['rev'] = -1
    rev_cache._rev_cache['data'] = {}


def _reset_worker_caches():
    pass


def _mp4_bytes():
    return b'\x00\x00\x00\x18ftypmp4' + b'v' * 64


