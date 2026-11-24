"""2.8.1 通知明文 + 补覆盖 + apk_version 治本 —— pytest。

两层：
1. 纯函数层（notice_title.build_title）：每个 kind 的标题模板逐条钉死，
   含摘录截断、媒体占位、period 只报类型、兜底与 kind 中文名；
2. 接线层（真实 TestClient + 双账号）：确认 main.py 的创建/评论/点赞/打卡/
   问答路径确实把明文标题送进了 notices 表，且红线（chat 不解密、PRIVATE
   三 kind 零通知、personal_wish 不带内容）不被破坏。
"""

import re
from pathlib import Path

import pytest

from app import config, notice_title


# ── 1. 纯函数：标题模板 ──────────────────────────────────────────────
@pytest.mark.parametrize('kind,body,extra,expect', [
    ('post', {'content': '今天去看海了'}, {}, '对方发布了一条时光：今天去看海了'),
    ('post', {'media': ['m1']}, {'first_media_mime': 'image/jpeg'}, '对方发布了一条时光：[图片]'),
    ('post', {'media': ['m1']}, {'first_media_mime': 'video/mp4'}, '对方发布了一条时光：[视频]'),
    ('post', {'media': ['m1']}, {'first_media_mime': 'audio/webm'}, '对方发布了一条时光：[语音]'),
    ('post', {'song': {'title': '晴天'}}, {'first_media_mime': 'audio/mpeg'}, '对方发布了一条时光：[音乐]'),
    ('post', {'album_only': True, 'media': ['a', 'b', 'c'], 'album': 'x'},
     {'album_name': '毕业旅行'}, '对方往相册传了 3 张照片到「毕业旅行」'),
    ('post', {'album_only': True, 'media': ['a', 'b']}, {}, '对方往相册传了 2 张照片'),
    ('mood', {'content': '有点累', 'emoji': '😮‍💨'}, {}, '对方记录了心情：有点累'),
    ('mood', {'emoji': '☀️'}, {}, '对方记录了心情：☀️'),
    ('mood', {}, {}, '对方记录了今日心情'),
    ('note', {'content': '记得带伞'}, {}, '对方留了一条留言：记得带伞'),
    ('album', {'title': '毕业旅行'}, {}, '对方新建了相册「毕业旅行」'),
    ('anniversary', {'title': '在一起'}, {}, '对方添加了纪念日「在一起」'),
    ('wish', {'title': '去北海道'}, {}, '对方添加了一个共同愿望：去北海道'),
    ('question', {'title': '你最喜欢我哪一点'}, {}, '对方发布了情侣问答：你最喜欢我哪一点'),
    ('habit', {'title': '早睡'}, {}, '对方新建了打卡目标「早睡」'),
    ('music', {'song': {'title': '晴天'}}, {}, '对方添加了一首歌：晴天'),
    ('ledger', {'content': '晚饭', 'amount': 38.5}, {}, '对方记了一笔：晚饭'),
    ('period', {'content': '疼得厉害', 'flow': 4}, {}, '对方添加了一条生理期记录'),
    ('comment', None, {'comment_text': '好美'}, '对方评论了你的记录：好美'),
    ('like', None, {}, '对方喜欢了你的记录'),
    ('quest', {'title': '去看展'}, {}, '对方发布了一条新记录（清单任务）'),
])
def test_build_title_templates(kind, body, extra, expect):
    assert notice_title.build_title(kind, body, **extra) == expect


def test_excerpt_truncates_and_collapses_whitespace():
    long_text = '一二三四五六七八九十' * 4  # 40 字
    title = notice_title.build_title('note', {'content': long_text})
    assert title == '对方留了一条留言：' + long_text[:30] + '…'
    assert len(title) == len('对方留了一条留言：') + 31
    # 换行/多空格压成单空格
    assert notice_title.build_title('note', {'content': 'a\n\n   b'}) == '对方留了一条留言：a b'


def test_period_never_carries_content():
    """红线：生理期只报类型，任何内容字段都不得出现在标题里。"""
    body = {'content': '疼得厉害', 'flow': 5, 'symptoms': ['痛经'], 'mood': '难过', 'weight': 50}
    title = notice_title.build_title('period', body)
    assert title == '对方添加了一条生理期记录'
    for leak in ('疼得厉害', '痛经', '难过', '50'):
        assert leak not in title


def test_generic_title_string_gone_from_source():
    """旧泛化文案必须从后端源码彻底消失（护栏，不许回退）。"""
    for path in ('app/main.py', 'app/notice_title.py'):
        text = Path(path).read_text(encoding='utf-8')
        assert '你们的空间有了新记录' not in text, path


def test_apk_version_comes_from_env(monkeypatch):
    """2.8.1 治本：APK 版本以环境变量为准，不再扫 static/*.apk 里的壳标记。"""
    monkeypatch.setenv('LOVE_APK_VERSION', '2.8.1')
    assert config._apk_version() == '2.8.1'
    monkeypatch.setenv('LOVE_APK_VERSION', '')
    assert config._apk_version() == '0.0.0'


# ── 2. 接线层：真实接口 + 双账号 ─────────────────────────────────────
def _notice_titles(client, limit=6):
    rows = client.get('/api/notices').json()
    return [r['title'] for r in rows[:limit]]


def test_post_and_chat_and_private_wiring(client_b, client_a):
    """new 记录的标题真的进通知；chat 不解密；PRIVATE 不发。"""
    before = _notice_titles(client_a, 1)

    client_b.post('/api/records', json={'kind': 'post', 'body': {'content': '一起看日落'}, 'client_id': 'n-post-1'})
    assert '对方发布了一条时光：一起看日落' in _notice_titles(client_a, 1)

    client_b.post('/api/records', json={'kind': 'chat', 'body': {'content': '秘密暗号'}, 'client_id': 'n-chat-1'})
    chat_title = _notice_titles(client_a, 1)[0]
    assert chat_title == '收到一条新消息'
    assert '秘密暗号' not in chat_title

    # PRIVATE 三 kind 一条通知都不许发
    snapshot = _notice_titles(client_a, 3)
    for kind in ('diary', 'draft', 'surprise'):
        client_b.post('/api/records', json={'kind': kind, 'body': {'content': f'私密-{kind}'}, 'client_id': f'n-{kind}-1'})
    assert _notice_titles(client_a, 3) == snapshot


def test_personal_wish_title_has_no_content(client_b, client_a):
    client_b.post('/api/personal-wishes', json={
        'title': '给未来的我们', 'content': '这是一段必须封存的内容', 'password': 'pw-2-8-1'})
    title = _notice_titles(client_a, 1)[0]
    assert title == '对方许下了一份个人心愿'
    assert '封存' not in title


def test_comment_and_like_titles(client_b, client_a):
    rec = client_b.post('/api/records', json={
        'kind': 'post', 'body': {'content': '这条用来被评论'}, 'client_id': 'n-cmt-1'}).json()
    client_a.post(f"/api/records/{rec['id']}/comments", json={'content': '真好看'})
    assert '对方评论了你的记录：真好看' in _notice_titles(client_b, 2)

    client_a.post(f"/api/records/{rec['id']}/like")
    assert _notice_titles(client_b, 2)[0] == '对方喜欢了你的记录'


def test_self_comment_does_not_notify(client_a, client_b):
    """自己评论自己的记录：任何一方都不该收到通知（2.8.1 口径）。"""
    rec = client_a.post('/api/records', json={
        'kind': 'post', 'body': {'content': '自己评自己'}, 'client_id': 'n-self-1'}).json()
    a_before = len(client_a.get('/api/notices').json())
    b_before = len(client_b.get('/api/notices').json())
    client_a.post(f"/api/records/{rec['id']}/comments", json={'content': '自言自语'})
    assert len(client_a.get('/api/notices').json()) == a_before
    assert len(client_b.get('/api/notices').json()) == b_before


def test_habit_check_notice_and_dedupe(client_b, client_a):
    habit = client_b.post('/api/records', json={
        'kind': 'habit', 'body': {'title': '早睡', 'done': False}, 'client_id': 'n-habit-1'}).json()
    client_b.post(f"/api/records/{habit['id']}/check")
    titles = _notice_titles(client_a, 1)
    assert titles[0] == '对方完成了打卡「早睡」'
    # 同日重复打卡不再轰炸
    n = len(client_a.get('/api/notices').json())
    client_b.post(f"/api/records/{habit['id']}/check")
    assert len(client_a.get('/api/notices').json()) == n


def test_question_answer_notice_and_dedupe(client_b, client_a):
    q = client_b.post('/api/records', json={
        'kind': 'question', 'body': {'title': '你最喜欢我哪一点'}, 'client_id': 'n-q-1'}).json()
    client_b.post(f"/api/records/{q['id']}/answer", json={'content': '全部'})
    assert _notice_titles(client_a, 1)[0] == '对方回答了情侣问答：全部'
    n = len(client_a.get('/api/notices').json())
    client_b.post(f"/api/records/{q['id']}/answer", json={'content': '全部，还有别的'})
    assert len(client_a.get('/api/notices').json()) == n, '同日改答案不许重复通知'
