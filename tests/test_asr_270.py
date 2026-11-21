"""2.7.0 语音转文字（ASR）护栏。

钉住机主指定六用例 + 调度语义：
1. 未登录拒绝；2. 缺 X-Love-Space 头拒绝；3. 非音频拒绝；4. 超限拒绝；
5. media_id 缓存命中（二跑不调用引擎）；6. 模型未就绪 503。
引擎调用经 transcribe_file 替身注入，测试不依赖真实模型与 NAS 环境。
"""
import io

import pytest
from fastapi.testclient import TestClient

from app import asr as asr_mod
from app import db
from app.main import app

HEADERS = {'X-Love-Space': '1'}


@pytest.fixture
def nologin():
    """未登录客户端：无 cookie、无默认头（测试鉴权与门禁）。"""
    with TestClient(app, base_url='https://testserver') as client:
        yield client


@pytest.fixture
def asr_ready(monkeypatch):
    """模型就绪态 + transcribe_file 替身（带调用计数）。"""
    calls = {'n': 0}

    def fake_transcribe(src):
        calls['n'] += 1
        return '这是替身转写的文本'

    monkeypatch.setattr(asr_mod, 'is_ready', lambda: True)
    monkeypatch.setattr(asr_mod, 'transcribe_file', fake_transcribe)
    monkeypatch.setattr(asr_mod, 'MAX_BYTES', asr_mod.MAX_BYTES)  # 原值
    return calls


def _audio_body(name='a.m4a'):
    return {'file': (name, io.BytesIO(b'\x00\x00\x00\x18ftypM4A ' + b'a' * 64), 'audio/mp4')}


def test_asr_requires_login(nologin):
    r = nologin.post('/api/asr', json={'media_id': 'x'}, headers=HEADERS)
    assert r.status_code in (401, 403), '未登录必须拒绝'


def test_asr_requires_x_love_space(nologin, asr_ready):
    r = nologin.post('/api/asr', json={'media_id': 'x'})  # 缺 X-Love-Space
    assert r.status_code in (401, 403), '缺写接口门禁头必须拒绝'


def test_asr_rejects_non_audio(client_a, asr_ready):
    r = client_a.post('/api/asr',
                      files={'file': ('x.png', io.BytesIO(b'\x89PNG'), 'image/png')},
                      headers=HEADERS)
    assert r.status_code == 422
    assert '音频' in r.json()['detail']


def test_asr_rejects_oversize(client_a, asr_ready, monkeypatch):
    monkeypatch.setattr(asr_mod, 'MAX_BYTES', 1024)
    r = client_a.post('/api/asr',
                      files={'file': ('a.m4a', io.BytesIO(b'a' * 2048), 'audio/mp4')},
                      headers=HEADERS)
    assert r.status_code == 422
    assert '10MB' in r.json()['detail']


def test_asr_model_not_ready_503(client_a, monkeypatch):
    monkeypatch.setattr(asr_mod, 'is_ready', lambda: False)
    r = client_a.post('/api/asr',
                      files=_audio_body(), headers=HEADERS)
    assert r.status_code == 503
    assert '识别模型未就绪' in r.json()['detail']


def test_asr_media_id_caches_second_run_skips_engine(client_a, asr_ready):
    """media_id 路径：首跑调引擎并落 transcript 缓存；二跑直接返回缓存不再调。"""
    # 直插音频 media 行（不走 /api/media 上传——全量跑时上传限流 30/300s
    # 会被前序模块占满，护栏自己不能成为限流受害者）
    mid = db.uid()
    owner = client_a.get('/api/me', headers=HEADERS).json()['user']['id']
    created_at = db.now()
    with db.connect() as c:
        c.execute('BEGIN IMMEDIATE')
        c.execute('INSERT INTO media(id,owner,name,mime,size,ext,status,created,attached,zone) '
                  "VALUES (?,?,'a.m4a','audio/mp4',64,'.m4a','ready',?,1,'')",
                  (mid, owner, created_at))
    # media_id 路径要求真实文件在盘上（端点会校验 src.is_file()）
    folder = db.media_dir('', 'audio/mp4', created_at)  # zone='' 的按 mime 归档目录
    folder.mkdir(parents=True, exist_ok=True)
    (folder / (mid + '.m4a')).write_bytes(b'\x00\x00\x00\x18ftypM4A ' + b'a' * 64)
    # 清缓存键（P3 rev_cache 与本端点无关，但保持干净）
    rev_cache_reset = getattr(__import__('app.rev_cache', fromlist=['_rev_cache']), '_rev_cache')
    rev_cache_reset['data'].clear()

    r1 = client_a.post('/api/asr', json={'media_id': mid}, headers=HEADERS)
    assert r1.status_code == 200, r1.text
    assert r1.json() == {'text': '这是替身转写的文本', 'cached': False}
    assert asr_ready['n'] == 1

    r2 = client_a.post('/api/asr', json={'media_id': mid}, headers=HEADERS)
    assert r2.status_code == 200
    assert r2.json() == {'text': '这是替身转写的文本', 'cached': True}
    assert asr_ready['n'] == 1, '缓存命中不得再调引擎'


def test_asr_upload_path_not_cached(client_a, asr_ready):
    """上传路径不缓存（机主口径）——两次上传各调一次引擎。"""
    n0 = asr_ready['n']
    assert client_a.post('/api/asr', files=_audio_body(), headers=HEADERS).status_code == 200
    assert client_a.post('/api/asr', files=_audio_body(), headers=HEADERS).status_code == 200
    assert asr_ready['n'] == n0 + 2


def test_asr_media_id_404_and_non_audio_media(client_a, asr_ready):
    owner = client_a.get('/api/me', headers=HEADERS).json()['user']['id']
    assert client_a.post('/api/asr', json={'media_id': 'no-such-id'}, headers=HEADERS).status_code == 404
    # 直插图片 media 行（不走上传——限流口径同上）
    mid2 = db.uid()
    with db.connect() as c:
        c.execute('BEGIN IMMEDIATE')
        c.execute('INSERT INTO media(id,owner,name,mime,size,ext,status,created,attached,zone) '
                  "VALUES (?,?,'x.png','image/png',64,'.png','ready',?,1,'')",
                  (mid2, owner, db.now()))
    r = client_a.post('/api/asr', json={'media_id': mid2}, headers=HEADERS)
    assert r.status_code == 422
    assert '音频' in r.json()['detail']


def test_transcript_column_exists():
    with db.connect() as c:
        cols = [r[1] for r in c.execute('PRAGMA table_info(media)')]
    assert 'transcript' in cols
    assert 'duration' in cols
