"""SSE 刷新的颗粒度：聊天变了就别整站重拉。

背景：聊天占全部记录的 88%，对方每发一句话都会触发一轮刷新。以前这一轮要把
1000 条非聊天记录 + 整本相册 + /me 全部重拉一遍，只为了一条新消息。
现在 records 的写入会同时推进两个分类计数器（chat_revision / other_revision），
SSE 把它们一起推给客户端，客户端据此决定走快速路径还是整站刷新。

这里锁死三件事：
1. 写聊天只动 chat_revision，不动 other_revision；
2. 写别的记录（纪念日/账本…）反过来；
3. 载荷在拿不到分类计数时（老签名四段）必须退回"两类都变了"，不许漏。
"""
from app import db
from app.main import _sse_payload

HEADERS = {'X-Love-Space': '1'}


def _revisions():
    with db.connect() as c:
        return {k: c.execute("SELECT value FROM app_state WHERE key=?", (k,)).fetchone()[0]
                for k in ('content_revision', 'chat_revision', 'other_revision')}


def test_chat_write_bumps_chat_not_other(client_a):
    before = _revisions()
    r = client_a.post('/api/records', headers=HEADERS,
                      json={'kind': 'chat', 'body': {'content': '颗粒度测试'}, 'client_id': db.uid()})
    assert r.status_code == 200, r.text
    after = _revisions()
    assert after['chat_revision'] > before['chat_revision'], '写聊天必须推进 chat_revision'
    assert after['other_revision'] == before['other_revision'], '写聊天不该推进 other_revision'
    # content_revision 的语义不变：它仍然涵盖一切，老客户端继续按整站刷新
    assert after['content_revision'] > before['content_revision']


def test_other_write_bumps_other_not_chat(client_a):
    before = _revisions()
    r = client_a.post('/api/records', headers=HEADERS,
                      json={'kind': 'note', 'body': {'title': '颗粒度', 'content': 'x'},
                            'client_id': db.uid()})
    assert r.status_code == 200, r.text
    after = _revisions()
    assert after['other_revision'] > before['other_revision'], '写普通记录必须推进 other_revision'
    assert after['chat_revision'] == before['chat_revision'], '写普通记录不该推进 chat_revision'


def test_payload_marks_chat_only():
    """签名从 4 段扩到 6 段后，只改聊天 → chat=True、other=False。"""
    prev = '7:0:0:4:10:5'
    payload = _sse_payload(7, 0, 0, 4, prev, chat_revision=11, other_revision=5)
    assert payload['chat'] is True and payload['other'] is False, payload
    # 一起看也变了：连 watch 一起标上，客户端两边都要跟
    payload = _sse_payload(7, 0, 0, 5, prev, chat_revision=11, other_revision=5)
    assert payload['watch'] is True and payload['other'] is False, payload
    # 只改普通记录
    payload = _sse_payload(7, 0, 0, 4, prev, chat_revision=10, other_revision=6)
    assert payload['chat'] is False and payload['other'] is True, payload
    # 两样都没变（只是心跳把 signature 拼出来了）
    payload = _sse_payload(7, 0, 0, 4, prev, chat_revision=10, other_revision=5)
    assert payload['chat'] is False and payload['other'] is False, payload


def test_payload_without_granularity_falls_back_to_full_refresh():
    """升级瞬间的旧连接只有四段签名：必须当作两类都变了，不能把变化漏过去。"""
    payload = _sse_payload(8, 0, 0, 4, '7:0:0:4')
    assert payload['refresh'] is True
    assert payload['chat'] is True and payload['other'] is True, payload
