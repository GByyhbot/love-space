"""2.8.5 护栏：SSE 契约级测试（审计 P2-7「双端无 SSE 测试」）。

不测实现细节，钉四件契约：
① 未登录连 /api/events 被拒；
② 签名构成：内容变化 → 前段变化；peer 数据变化 → 仅第 7 段变化（互不串扰）；
③ 事件帧形状：data 帧含 rev（7 段）与既定布尔字段；
④ 注释/心跳帧不破坏帧解析（连上后先到的帧序列能被逐帧吃下）。

⚠️ 一处如实说明（令文允许按代码实情断言）：
令文提到「聊天动作不出现在铃铛口径内」。实际代码里事件层签名第 3 段 `unread`
取的是 `notices` 全量未读（`main.py:2614`，**不含 chat 排除**），而 chat 记录
确实会 `db.notice(event='chat')` 落库（`main.py:1466` + `db.py:841`）。
也就是说**事件层与「铃铛排除 chat」本就不同构**，排除发生在消费端而非这里。
本文件按实情断言，不改代码去迎合令文。
"""
import json

import pytest
from fastapi.testclient import TestClient

from app import db
from app.main import app, _sse_payload, _sse_probe


@pytest.fixture
def anon():
    with TestClient(app, base_url='https://testserver',
                    headers={'X-Love-Space': '1'}) as c:
        yield c


def _uid(client):
    return client.get('/api/me').json()['user']['id']


def _probe(uid):
    """签名七段（不查会话，专注构成）。"""
    return _sse_probe('not-a-real-token', uid, False)


def _signature(t):
    return ':'.join(str(x) for x in t)


# ① 未登录被拒
def test_events_requires_login(anon):
    r = anon.get('/api/events')
    assert r.status_code == 401


# ② 签名构成：内容段与 peer 段互不串扰
def test_signature_content_and_peer_segments_are_independent(client_a):
    uid = _uid(client_a)
    before = _probe(uid)

    client_a.post('/api/records',
                  json={'kind': 'post', 'body': {'content': '签名构成用'}})
    after = _probe(uid)

    assert after[0] > before[0], '新建记录必须推进 content_revision（签名第 1 段）'
    assert after[6] == before[6], '纯内容变化不许动 peer_revision（第 7 段）'

    # peer 侧独立：开共享 → 报一个定位点
    client_a.put('/api/peer/settings',
                 json={'location': True, 'track': True, 'events': True, 'sos': True})
    mid = _probe(uid)
    client_a.post('/api/peer/location',
                  json={'points': [{'id': 'sse-test-pt-1', 'ts': 1700000000.0,
                                    'lat': 31.2, 'lng': 121.4}]})
    after2 = _probe(uid)
    assert after2[6] > mid[6], 'peer 数据变化必须推进第 7 段'
    assert after2[0] == mid[0], 'peer 变化不许动 content_revision（只刷地图，不整站刷新）'


# ③ + ④ 真实流：注释帧可解析，再变化后出 data 帧且形状正确
def test_stream_frames_shape_and_comment_frames(client_a, client_b):
    uid = _uid(client_a)
    with client_a.stream('GET', '/api/events') as r:
        assert r.status_code == 200
        assert r.headers['content-type'].startswith('text/event-stream')
        it = r.iter_lines()
        head = [next(it) for _ in range(4)]
        # 首轮固定是 retry + 空行 + ready 注释 + 空行（注释帧不产生数据事件）
        assert head[0].startswith('retry: 3000'), head
        assert head[2].startswith(':'), f'第二帧应是注释帧：{head}'
        assert all(not h.startswith('data:') for h in head), \
            '首轮只建基线，不许推 data（否则客户端会把每次重连当成数据变化）'

        # 让对方发一条 → 下一轮应推 data 帧
        client_b.post('/api/records',
                      json={'kind': 'post', 'body': {'content': '触发一帧'}})
        data_line = None
        for _ in range(3):
            line = next(it)
            if line.startswith('data:'):
                data_line = line
                break
        assert data_line is not None, '数据变化后应推 data 帧'

    payload = json.loads(data_line[5:].strip())
    assert set(payload) == {'refresh', 'unread', 'chat', 'other', 'typing', 'peer', 'rev'}, payload
    segs = payload['rev'].split(':')
    assert len(segs) == 7, f'签名必须 7 段（含 peer_revision）：{payload["rev"]}'
    assert int(segs[1]) >= 0 and isinstance(payload['unread'], int)
    assert isinstance(payload['refresh'], bool) and isinstance(payload['peer'], bool)


# ③ 附带：payload 语义（chat 单独变 → 只 chat=True，不整站刷新）
def test_payload_semantics_single_segment():
    prev = '10:1:0:5:5:0:3'
    # 只有 chat_revision 变
    p = _sse_payload(10, 1, 0, prev, chat_revision=6, other_revision=5,
                     peer_typing=0, peer_revision=3)
    assert p['chat'] is True and p['other'] is False
    assert p['refresh'] is False, '只聊天变化不该要求整站刷新'
    # only peer 变
    p2 = _sse_payload(10, 1, 0, prev, chat_revision=5, other_revision=5,
                      peer_typing=0, peer_revision=4)
    assert p2['peer'] is True and p2['refresh'] is False
    # 旧签名缺 peer 段 → 宁多不漏
    p3 = _sse_payload(10, 1, 0, '10:1:0:5:5', chat_revision=5, other_revision=5,
                      peer_typing=0, peer_revision=9)
    assert p3['peer'] is True


# ③ 附带（如实记录不同构）：chat 记录会落 notices，事件层 unread 计入
def test_chat_notice_counts_in_unread_segment(client_a, client_b):
    uid = _uid(client_a)
    before = _probe(uid)[2]
    client_b.post('/api/records',
                  json={'kind': 'chat', 'body': {'content': '悄悄话'}})
    after = _probe(uid)[2]
    assert after == before + 1, (
        '事件层 unread 取 notices 全量（含 chat）；「铃铛排除 chat」在消费端，'
        '两者本就不同构——此处按代码实情断言')
    # 清掉这条 chat 通知，避免影响后续用例的未读基线
    with db.connect() as c:
        c.execute("DELETE FROM notices WHERE user_id=? AND event='chat'", (uid,))
