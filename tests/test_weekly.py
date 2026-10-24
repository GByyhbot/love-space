"""回忆周报接口的形状、计数与私有可见性。"""
KEYS = ('offset', 'label', 'start', 'end', 'total', 'prev_total', 'delta', 'days_active',
        'photos', 'by_kind', 'moods', 'top_mood', 'likes', 'comments', 'highlights', 'message')


def test_weekly_shape(client_a):
    r = client_a.get('/api/weekly')
    assert r.status_code == 200, r.text
    data = r.json()
    for key in KEYS:
        assert key in data, key
    assert data['label'] == '这一周'
    assert data['offset'] == 0
    assert data['start'] <= data['end']
    assert isinstance(data['by_kind'], dict)
    assert isinstance(data['moods'], dict)
    assert isinstance(data['highlights'], list)
    assert len(data['highlights']) <= 4
    assert data['message']


def test_weekly_counts_own_record(client_a):
    before = client_a.get('/api/weekly').json()['total']
    r = client_a.post('/api/records', json={'kind': 'post', 'body': {'content': '周报测试'}})
    assert r.status_code == 200, r.text
    after = client_a.get('/api/weekly').json()
    assert after['total'] == before + 1
    assert after['by_kind'].get('post', 0) >= 1
    assert after['delta'] == after['total'] - after['prev_total']


def test_weekly_private_not_leaked(client_a, client_b):
    """A 的私密日记不应计入 B 的周报。"""
    before = client_b.get('/api/weekly').json()['total']
    r = client_a.post('/api/records', json={'kind': 'diary', 'body': {'content': '周报私密'}})
    assert r.status_code == 200, r.text
    assert client_b.get('/api/weekly').json()['total'] == before


def test_weekly_offset_range(client_a):
    assert client_a.get('/api/weekly?offset=-1').status_code == 200
    assert client_a.get('/api/weekly?offset=1').status_code == 422
    assert client_a.get('/api/weekly?offset=-99').status_code == 422
