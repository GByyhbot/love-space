"""Regression tests for peer place_name persistence, point carriage, and stay naming."""
import datetime as dt

import pytest

from app import db, peer, peer_agg

HEADERS = {'X-Love-Space': '1'}


@pytest.fixture(autouse=True)
def _peer_reset():
    yield
    with db.connect() as c:
        c.execute('DELETE FROM peer_location_points')
        c.execute('DELETE FROM peer_places')
        c.execute('DELETE FROM peer_location_latest')
        c.execute("DELETE FROM app_state WHERE key LIKE 'peer_settings:%'")


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


def test_points_place_name_column_and_stay_naming_priority(client_a, client_b):
    uid_a = client_a.get('/api/me', headers=HEADERS).json()['user']['id']
    with db.connect() as c:
        cols = {r[1] for r in c.execute('PRAGMA table_info(peer_location_points)')}
        assert 'place_name' in cols
        day = dt.datetime.now(peer_agg.space_tz(c)).strftime('%Y-%m-%d')
        start, _ = peer_agg.day_bounds(c, day)

    t0 = start + 3600.0
    long_pt_place = '深圳市南山区深南大道万象天地北区广场' * 4
    # Cluster 1 (no geofence, has point place_name -> named by point place_name)
    # Cluster 2 (matches peer_places geofence -> geofence wins over point place_name)
    # Cluster 3 (historical points without place_name & no geofence -> stays '', never fabricated)
    r = client_a.post(
        '/api/peer/location',
        headers=HEADERS,
        json={
            'points': [
                {'id': 'p1', 'ts': t0, 'lat': 22.5400, 'lng': 113.9500, 'acc': 8.0,
                 'speed': 0.0, 'place_name': f'  {long_pt_place}  '},
                {'id': 'p2', 'ts': t0 + 400, 'lat': 22.5401, 'lng': 113.9501, 'acc': 8.0,
                 'speed': 0.0, 'place_name': '万象天地'},
                {'id': 'p3', 'ts': t0 + 800, 'lat': 22.5401, 'lng': 113.9500, 'acc': 8.0,
                 'speed': 0.0, 'place_name': '万象天地'},
                # Outside point shifted >1km away: defines left_at of Cluster 1 without polluting Cluster 1
                {'id': 'p_move', 'ts': t0 + 1200, 'lat': 22.5550, 'lng': 113.9650, 'acc': 8.0,
                 'speed': 6.0, 'place_name': '高新南九道'},
                # Cluster 2 (geofence priority)
                {'id': 'p4', 'ts': t0 + 1800, 'lat': 22.5700, 'lng': 113.9800, 'acc': 8.0,
                 'speed': 0.0, 'place_name': '海岸城路边'},
                {'id': 'p5', 'ts': t0 + 2500, 'lat': 22.5701, 'lng': 113.9801, 'acc': 8.0,
                 'speed': 0.0, 'place_name': '海岸城路边'},
                # Cluster 3 (historical points with empty place_name)
                {'id': 'p6', 'ts': t0 + 3600, 'lat': 22.6000, 'lng': 114.0100, 'acc': 8.0,
                 'speed': 0.0},
                {'id': 'p7', 'ts': t0 + 4200, 'lat': 22.6001, 'lng': 114.0101, 'acc': 8.0,
                 'speed': 0.0, 'place_name': ''},
            ],
            'latest': {
                'lat': 22.6001,
                'lng': 114.0101,
                'acc': 8.0,
                'battery': 75,
                'place_name': '  南山区科技园  ',
            },
        },
    )
    assert r.status_code == 200, r.text

    with db.connect() as c:
        c.execute(
            'INSERT INTO peer_places (id, name, lat, lng, radius, created) VALUES (?, ?, ?, ?, ?, ?)',
            ('home-1', '公司', 22.57005, 113.98005, 150.0, t0),
        )
        row_p1 = c.execute(
            'SELECT place_name FROM peer_location_points WHERE id=?', ('p1',)
        ).fetchone()
        assert row_p1['place_name'] == long_pt_place[:80]

    track = client_b.get(f'/api/peer/track?date={day}', headers=HEADERS).json()
    peer_side = track['peer']
    assert peer_side['latest']['place_name'] == '南山区科技园'
    assert peer_side['points'][0]['place_name'] == long_pt_place[:80]
    stays = peer_side['stays']
    assert len(stays) == 3
    assert stays[0]['place_name'] == '万象天地'
    assert stays[1]['place_name'] == '公司'  # geofence overrides point place_name
    assert stays[2]['place_name'] == ''  # historical point stays empty, never fabricated

    # Street mode still suppresses points while keeping stays named & latest.place_name
    client_a.put('/api/peer/settings', headers=HEADERS,
                 json={'policy': {'location_level': 'street'}})
    street_track = client_b.get(f'/api/peer/track?date={day}', headers=HEADERS).json()['peer']
    assert street_track['level'] == 'street'
    assert street_track['points'] == []
    assert [s['place_name'] for s in street_track['stays']] == ['万象天地', '公司', '']
    assert street_track['latest']['place_name'] == '南山区科技园'

    # Also verify historical point without place_name stored earlier cannot be guessed
    with db.connect() as c:
        assert c.execute(
            'SELECT COUNT(*) FROM peer_location_points WHERE user=? AND place_name=""',
            (uid_a,),
        ).fetchone()[0] >= 2
