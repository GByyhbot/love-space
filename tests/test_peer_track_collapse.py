"""Regression tests for 甲 · track display-line collapse and shared real-sample anchor."""
import datetime as dt
import math

import pytest

from app import db, peer, peer_agg

HEADERS = {'X-Love-Space': '1'}


def _offset(lat, lng, north_m, east_m):
    return (
        lat + north_m / 111_320.0,
        lng + east_m / (111_320.0 * math.cos(math.radians(lat))),
    )


@pytest.fixture(autouse=True)
def _peer_reset():
    db.init()
    yield
    with db.connect() as c:
        c.execute('DELETE FROM peer_location_points')
        c.execute('DELETE FROM peer_places')
        c.execute('DELETE FROM peer_location_latest')
        c.execute("DELETE FROM app_state WHERE key LIKE 'peer_settings:%'")


def test_select_real_anchor_picks_actual_sample_closest_to_weighted_centroid():
    base_lat, base_lng = 31.2304, 121.4737
    p_hi_1 = _offset(base_lat, base_lng, 1.0, 2.0)
    p_hi_2 = _offset(base_lat, base_lng, -1.0, -1.0)
    p_best = _offset(base_lat, base_lng, 0.2, 0.3)
    p_noisy = _offset(base_lat, base_lng, 55.0, -45.0)
    members = [
        {'ts': 100.0, 'lat': p_noisy[0], 'lng': p_noisy[1], 'acc': 45.0},
        {'ts': 200.0, 'lat': p_hi_1[0], 'lng': p_hi_1[1], 'acc': 6.0},
        {'ts': 300.0, 'lat': p_best[0], 'lng': p_best[1], 'acc': 5.0},
        {'ts': 400.0, 'lat': p_hi_2[0], 'lng': p_hi_2[1], 'acc': 6.0},
    ]
    anchor = peer_agg.select_real_anchor(members)
    assert anchor is members[2]
    assert any(
        anchor['lat'] == m['lat'] and anchor['lng'] == m['lng']
        for m in members
    ), '锚点必须取真实采样点，不许用算出来的质心冒充'


def test_stationary_jitter_collapses_display_line_while_preserving_raw_points(client_a, client_b):
    with db.connect() as c:
        day = dt.datetime.now(peer_agg.space_tz(c)).strftime('%Y-%m-%d')
        start, _ = peer_agg.day_bounds(c, day)

    base_lat, base_lng = 31.2304, 121.4737
    pts_payload = []
    t0 = start + 2100.0  # 00:35
    # Stationary jitter inside 60m radius over 9.5 hours -> raw distance ~500m
    offsets = [
        (0.0, 0.0, 6.0),
        (25.0, 15.0, 18.0),
        (-20.0, 30.0, 22.0),
        (35.0, -25.0, 25.0),
        (-30.0, -20.0, 20.0),
        (45.0, 20.0, 30.0),
        (-40.0, 25.0, 28.0),
        (15.0, -35.0, 24.0),
        (-10.0, 12.0, 12.0),
        (5.0, -4.0, 8.0),
        (42.0, -18.0, 32.0),
        (-28.0, 32.0, 26.0),
        (3.0, 2.0, 5.0),
    ]
    for idx, (dn, de, acc) in enumerate(offsets):
        la, ln = _offset(base_lat, base_lng, dn, de)
        pts_payload.append({
            'id': f'stat-{idx}',
            'ts': t0 + idx * 2400.0,
            'lat': la,
            'lng': ln,
            'acc': acc,
            'speed': 0.0,
            'place_name': '矿区宿舍',
        })

    r = client_a.post('/api/peer/location', headers=HEADERS, json={
        'points': pts_payload,
        'latest': {'lat': pts_payload[-1]['lat'], 'lng': pts_payload[-1]['lng'],
                   'acc': 5.0, 'battery': 90, 'place_name': '矿区宿舍'},
    })
    assert r.status_code == 200, r.text

    res = client_b.get(f'/api/peer/track?date={day}', headers=HEADERS).json()['peer']
    assert len(res['points']) == len(pts_payload), '原始 points 必须一条不动'
    assert res['distance_m'] > 400.0
    assert len(res['stays']) == 1
    stay = res['stays'][0]
    disp = res['display_points']
    assert len(disp) == 2
    assert res['display_distance_m'] == 0.0
    assert disp[0]['lat'] == stay['lat'] and disp[0]['lng'] == stay['lng']
    assert disp[1]['lat'] == stay['lat'] and disp[1]['lng'] == stay['lng']
    assert disp[0]['ts'] == res['points'][0]['ts']
    assert disp[1]['ts'] == res['points'][-1]['ts']
    assert any(
        p['lat'] == stay['lat'] and p['lng'] == stay['lng']
        for p in res['points']
    ), '锚点必须来自真实采样点'


def test_commute_day_preserves_moving_segments_stays_and_timeline(client_a, client_b):
    with db.connect() as c:
        day = dt.datetime.now(peer_agg.space_tz(c)).strftime('%Y-%m-%d')
        start, _ = peer_agg.day_bounds(c, day)

    base_lat, base_lng = 31.2304, 121.4737
    pts = []
    # Stay 1: 4 points around 0m for 20 min
    for i, (dn, de) in enumerate([(0, 0), (15, 10), (-12, 18), (4, -6)]):
        la, ln = _offset(base_lat, base_lng, dn, de)
        pts.append({'id': f's1-{i}', 'ts': start + 3600 + i * 400,
                    'lat': la, 'lng': ln, 'acc': 8.0, 'speed': 0.0, 'place_name': '家'})

    # Moving leg: 6.2 km East in 21 steps (~295m every 40s, ~7.4 m/s), leaving >80m gap to Stay 2 at 6300m
    move_start_ts = start + 5200
    for k in range(1, 22):
        la, ln = _offset(base_lat, base_lng, 0.0, k * 295.0)
        pts.append({'id': f'mv-{k}', 'ts': move_start_ts + k * 40,
                    'lat': la, 'lng': ln, 'acc': 10.0, 'speed': 7.4})

    # Stay 2: 4 points around 6300m East for 20 min
    end_ts = move_start_ts + 21 * 40
    for i, (dn, de) in enumerate([(10, 6310), (-15, 6295), (5, 6302), (0, 6300)]):
        la, ln = _offset(base_lat, base_lng, dn, de)
        pts.append({'id': f's2-{i}', 'ts': end_ts + 300 + i * 400,
                    'lat': la, 'lng': ln, 'acc': 8.0, 'speed': 0.0, 'place_name': '公司'})

    r = client_a.post('/api/peer/location', headers=HEADERS, json={'points': pts})
    assert r.status_code == 200, r.text

    res = client_b.get(f'/api/peer/track?date={day}', headers=HEADERS).json()['peer']
    assert len(res['stays']) == 2
    assert res['stays'][0]['duration_sec'] == 1200
    assert res['stays'][1]['duration_sec'] == 1200
    # True moving distance is ~6300m; display_distance_m should stay within 5%
    assert abs(res['display_distance_m'] - 6300.0) / 6300.0 <= 0.05
    assert res['display_points'][0]['ts'] == res['points'][0]['ts']
    assert res['display_points'][-1]['ts'] == res['points'][-1]['ts']
    # Stay anchors match display endpoints exactly
    assert res['display_points'][0]['lat'] == res['stays'][0]['lat']
    assert res['display_points'][-1]['lat'] == res['stays'][1]['lat']

    # Privacy check: street & off must suppress display_points and display_distance_m
    client_a.put('/api/peer/settings', headers=HEADERS,
                 json={'policy': {'location_level': 'street'}})
    st = client_b.get(f'/api/peer/track?date={day}', headers=HEADERS).json()['peer']
    assert st['display_points'] == []
    assert st['display_segments'] == []
    assert st['display_distance_m'] is None

    client_a.put('/api/peer/settings', headers=HEADERS,
                 json={'policy': {'location_level': 'off'}})
    off = client_b.get(f'/api/peer/track?date={day}', headers=HEADERS).json()['peer']
    assert off['display_points'] == []
    assert off['display_distance_m'] == 0.0
