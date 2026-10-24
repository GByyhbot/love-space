"""数据看板聚合接口的形状与私有可见性。"""
KEYS = ('total', 'by_kind', 'months', 'moods', 'likes', 'comments', 'photos',
        'days_together', 'wishes_total', 'wishes_done')


def test_dashboard_shape(client_a):
    r = client_a.get('/api/dashboard')
    assert r.status_code == 200, r.text
    data = r.json()
    for key in KEYS:
        assert key in data, key
    assert isinstance(data['by_kind'], dict)
    assert isinstance(data['months'], list)
    assert isinstance(data['moods'], dict)


def test_dashboard_private_not_leaked(client_a, client_b):
    """A 写一条私密日记，B 的看板总数不应因此增加。"""
    total_b = client_b.get('/api/dashboard').json()['total']
    r = client_a.post('/api/records', json={'kind': 'diary', 'body': {'content': 'only for me'}})
    assert r.status_code == 200, r.text
    total_b_after = client_b.get('/api/dashboard').json()['total']
    assert total_b_after == total_b
