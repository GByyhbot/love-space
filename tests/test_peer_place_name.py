"""Regression tests for peer_location_latest.place_name persistence and trimming."""
from app import db, peer

HEADERS = {'X-Love-Space': '1'}


def test_place_name_column_exists_and_defaults_empty(client_a):
    uid = client_a.get('/api/me', headers=HEADERS).json()['user']['id']
    with db.connect() as c:
        cols = {r[1] for r in c.execute('PRAGMA table_info(peer_location_latest)')}
        assert 'place_name' in cols
        c.execute(
            'INSERT INTO peer_location_latest (user, lat, lng, updated) VALUES (?, ?, ?, ?)',
            (uid, 31.23, 121.47, 1795747933.0),
        )
        row = dict(
            c.execute(
                'SELECT place_name FROM peer_location_latest WHERE user=?',
                (uid,),
            ).fetchone()
        )
        assert row['place_name'] == ''


def test_post_peer_location_persists_and_truncates_place_name(client_a, client_b):
    long_name = '上海市浦东新区张江高科技园区祖冲之路' * 4
    r = client_a.post(
        '/api/peer/location',
        headers=HEADERS,
        json={
            'points': [],
            'latest': {
                'lat': 31.2304,
                'lng': 121.4737,
                'acc': 10.0,
                'battery': 88,
                'place_name': f'  {long_name}  ',
            },
        },
    )
    assert r.status_code == 200, r.text
    status = client_b.get('/api/peer/status', headers=HEADERS).json()
    assert status['peer']['location']['place_name'] == long_name[:80]

    # When partner sets location_level=off, trim_snapshot clears place_name.
    trimmed = peer.trim_snapshot(
        {'lat': 31.23, 'lng': 121.47, 'place_name': '张江镇'},
        {'location_level': 'off', 'network_level': 'ssid', 'battery': True},
    )
    assert trimmed['place_name'] == ''

    # Street mode still retains place_name for city/district display.
    street_kept = peer.trim_snapshot(
        {'lat': 31.23, 'lng': 121.47, 'place_name': '浦东新区'},
        {'location_level': 'street', 'network_level': 'ssid', 'battery': True},
    )
    assert street_kept['place_name'] == '浦东新区'


def test_trim_snapshot_off_clears_coords_and_street_keeps_them():
    trimmed = peer.trim_snapshot(
        {
            'lat': 31.23,
            'lng': 121.47,
            'acc': 12.5,
            'speed': 1.8,
            'place_name': '张江镇',
        },
        {'location_level': 'off', 'network_level': 'ssid', 'battery': True},
    )
    assert trimmed['lat'] is None
    assert trimmed['lng'] is None
    assert trimmed['acc'] is None
    assert trimmed['speed'] is None
    assert trimmed['place_name'] == ''

    street_kept = peer.trim_snapshot(
        {
            'lat': 31.23,
            'lng': 121.47,
            'acc': 12.5,
            'speed': 1.8,
            'place_name': '浦东新区',
        },
        {'location_level': 'street', 'network_level': 'ssid', 'battery': True},
    )
    assert street_kept['lat'] == 31.23
    assert street_kept['lng'] == 121.47
    assert street_kept['acc'] == 12.5
    assert street_kept['speed'] == 1.8
    assert street_kept['place_name'] == '浦东新区'
