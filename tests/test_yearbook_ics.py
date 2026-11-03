"""小年报的深度统计、日历导出、聊天的引用/置顶字段。"""
import datetime as dt

DEEP_KEYS = ('active_days', 'streak', 'best_month', 'best_weekday',
             'top_kind', 'mood_top', 'words', 'interactions')


def test_yearbook_has_deep_stats(client_a):
    r = client_a.get('/api/yearbook')
    assert r.status_code == 200, r.text
    data = r.json()
    for key in DEEP_KEYS:
        assert key in data, key
    assert isinstance(data['active_days'], int)
    assert isinstance(data['streak'], int)
    assert isinstance(data['words'], list)
    assert isinstance(data['interactions'], int)
    assert data['best_month'] is None or 1 <= data['best_month']['month'] <= 12
    assert data['best_weekday'] is None or 0 <= data['best_weekday']['weekday'] <= 6


def test_yearbook_streak_counts_consecutive_days(client_a):
    today = dt.date.today()
    for offset in (1, 2, 3):
        day = (today - dt.timedelta(days=offset)).isoformat()
        r = client_a.post('/api/records', json={'kind': 'post', 'body': {'content': f'连续第{offset}天', 'date': day}})
        assert r.status_code == 200, r.text
    data = client_a.get('/api/yearbook').json()
    assert data['streak'] >= 3
    assert data['active_days'] >= 3


def test_yearbook_words_are_chinese_bigrams(client_a):
    for _ in range(3):
        r = client_a.post('/api/records', json={'kind': 'post', 'body': {'content': '想和你一起去看樱花'}})
        assert r.status_code == 200, r.text
    words = client_a.get('/api/yearbook').json()['words']
    assert any(w['w'] == '樱花' for w in words), words


def test_ics_export_contains_anniversary(client_a):
    r = client_a.post('/api/records', json={'kind': 'anniversary',
                                            'body': {'title': '在一起的日子', 'date': '2026-05-20', 'annual': True}})
    assert r.status_code == 200, r.text
    r = client_a.get('/api/export/ics')
    assert r.status_code == 200, r.text
    assert r.headers['content-type'].startswith('text/calendar')
    assert "filename*=UTF-8''" in r.headers['content-disposition']
    body = r.text
    assert body.startswith('BEGIN:VCALENDAR') and 'END:VCALENDAR' in body
    assert 'SUMMARY:在一起的日子' in body
    assert 'DTSTART;VALUE=DATE:20260520' in body
    assert 'RRULE:FREQ=YEARLY' in body


def test_chat_reply_and_pin(client_a):
    r = client_a.post('/api/records', json={'kind': 'chat', 'body': {'content': '今晚吃什么'}})
    assert r.status_code == 200, r.text
    quoted = r.json()['id']
    r = client_a.post('/api/records', json={'kind': 'chat', 'body': {
        'content': '吃面吧', 'reply_to': {'id': quoted, 'text': '今晚吃什么'}, 'pinned': True}})
    assert r.status_code == 200, r.text
    record = r.json()
    assert record['body']['reply_to']['id'] == quoted
    assert record['body']['pinned'] is True


def test_chat_reply_rejects_bad_shape(client_a):
    r = client_a.post('/api/records', json={'kind': 'chat', 'body': {'content': 'x', 'reply_to': 'nope'}})
    assert r.status_code == 422
    r = client_a.post('/api/records', json={'kind': 'chat', 'body': {'content': 'x', 'reply_to': {'id': ''}}})
    assert r.status_code == 422
    r = client_a.post('/api/records', json={'kind': 'chat', 'body': {'content': 'x', 'pinned': 'yes'}})
    assert r.status_code == 422


def test_chat_location_message(client_a):
    """聊天里的「位置」：只存归一化后的经纬度，越界或形状不对一律 422。"""
    r = client_a.post('/api/records', json={'kind': 'chat', 'body': {
        'content': '', 'location': {'lat': '31.230416', 'lng': 121.473701}}})
    assert r.status_code == 200, r.text
    record = r.json()['body']['location']
    assert record == {'lat': 31.23042, 'lng': 121.4737}
    for bad in ('nope', {'lat': 'x', 'lng': 1}, {'lat': 91, 'lng': 0}, {'lat': 0, 'lng': 181}):
        r = client_a.post('/api/records', json={'kind': 'chat', 'body': {'content': '', 'location': bad}})
        assert r.status_code == 422, f'{bad} 应该被拒绝'


def test_chat_song_message(client_a):
    """聊天里分享一首歌：只存摘要 + 音频媒体 id，空歌名/野路径一律 422。"""
    r = client_a.post('/api/records', json={'kind': 'chat', 'body': {
        'content': '', 'song': {'title': ' 晚安 ', 'artist': '陈奕迅', 'mid': 'abc123'}}})
    assert r.status_code == 200, r.text
    assert r.json()['body']['song'] == {'title': '晚安', 'artist': '陈奕迅', 'mid': 'abc123'}
    for bad in ('nope', {'title': ''}, {'title': 'x', 'mid': '../etc/passwd'}, {'title': 'x' * 121}):
        r = client_a.post('/api/records', json={'kind': 'chat', 'body': {'content': '', 'song': bad}})
        assert r.status_code == 422, f'{bad} 应该被拒绝'


def test_reply_and_pin_dropped_for_non_chat(client_a):
    r = client_a.post('/api/records', json={'kind': 'post', 'body': {
        'content': '普通动态', 'reply_to': {'id': 'abc', 'text': '引用的'}, 'pinned': True}})
    assert r.status_code == 200, r.text
    body = r.json()['body']
    assert 'reply_to' not in body
    assert 'pinned' not in body


def test_chat_pin_toggle_keeps_recalled(client_a):
    rid = client_a.post('/api/records', json={'kind': 'chat', 'body': {'content': '置顶我'}}).json()['id']
    assert client_a.post(f'/api/records/{rid}/pin').json()['pinned'] is True
    assert client_a.post(f'/api/records/{rid}/recall').status_code == 200
    # 撤回后再取消置顶：recalled 不能被置顶接口顺手洗掉（这正是单开端点的原因）
    assert client_a.post(f'/api/records/{rid}/pin').json()['pinned'] is False
    row = [x for x in client_a.get('/api/records?kind=chat&limit=100').json() if x['id'] == rid][0]
    assert row['body']['recalled'] is True


def test_pin_rejects_non_chat(client_a):
    rid = client_a.post('/api/records', json={'kind': 'post', 'body': {'content': '普通动态'}}).json()['id']
    assert client_a.post(f'/api/records/{rid}/pin').status_code == 400
