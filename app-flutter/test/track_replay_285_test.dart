/// 2.8.7 全量施工令 · 轨迹回放纯函数（施工令 §六·11）。
///
/// 钉住：滑块时刻 → 光点插值、速度取所在区间、网络/电量取「最近一次已发生」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/peer/peer_track_data.dart';
import 'package:love_space/features/together/track_replay.dart';

PeerTrackPoint _p(double ts, double lat, double lng) =>
    PeerTrackPoint(ts: ts, lat: lat, lng: lng);

void main() {
  final points = <PeerTrackPoint>[
    _p(1000, 39.9000, 116.4000),
    _p(1600, 39.9010, 116.4000),
    _p(2200, 39.9020, 116.4000),
  ];

  group('光点插值', () {
    test('区间中点落在两点正中', () {
      final r = pointAt(points, 1300)!;
      expect(r.lat, closeTo(39.9005, 1e-9));
      expect(r.lng, closeTo(116.4000, 1e-9));
    });

    test('边界：早于首点 → 首点；晚于末点 → 末点', () {
      expect(pointAt(points, 0)!.lat, closeTo(39.9000, 1e-9));
      expect(pointAt(points, 99999)!.lat, closeTo(39.9020, 1e-9));
    });

    test('单点 / 空点列', () {
      final one = [points.first];
      expect(pointAt(one, 5000)!.lat, closeTo(39.9000, 1e-9));
      expect(pointAt(const <PeerTrackPoint>[], 0), isNull);
    });
  });

  group('速度读数', () {
    test('取所在区间的两点速度（≈公里/小时）', () {
      // 0.001° 纬度 ≈ 111m / 600s ≈ 0.67 km/h
      final v = speedKmhAt(points, 1300)!;
      expect(v, closeTo(0.67, 0.1));
    });

    test('少于两点 → null（不编造静止）', () {
      expect(speedKmhAt([points.first], 1000), isNull);
      expect(speedKmhAt(const <PeerTrackPoint>[], 1000), isNull);
    });
  });

  group('网络 / 电量读数取最近一次已发生', () {
    final nets = <PeerNetRecord>[
      const PeerNetRecord(ts: 1000, net: 'wifi', ssid: 'home'),
      const PeerNetRecord(ts: 2000, net: 'cell'),
    ];

    test('停在两条之间取前一条', () {
      expect(netAt(nets, 1500)!.ssid, 'home');
      expect(netAt(nets, 2500)!.net, 'cell');
    });

    test('早于第一条 → null（不显示假值）', () {
      expect(netAt(nets, 500), isNull);
    });

    test('电量同理', () {
      final b = <BatteryReading>[
        const BatteryReading(ts: 1000, level: 80),
        const BatteryReading(ts: 2000, level: 60),
      ];
      expect(batteryAt(b, 1500), 80);
      expect(batteryAt(b, 2000), 60);
      expect(batteryAt(b, 10), isNull);
    });
  });

  group('进度与投影', () {
    test('进度按首末时刻归一，越界钳制', () {
      expect(replayProgress(points, 1000), 0);
      expect(replayProgress(points, 1600), closeTo(0.5, 1e-9));
      expect(replayProgress(points, 9999), 1);
      expect(timeAtProgress(points, 0.5), 1600);
    });

    test('投影把包围盒铺满 0..1，纬度越大越靠上', () {
      final proj = TrackProjector(points);
      final bottom = proj.project(39.9000, 116.4000);
      final top = proj.project(39.9020, 116.4000);
      expect(bottom.y, closeTo(1.0, 1e-9));
      expect(top.y, closeTo(0.0, 1e-9));
      // 同一经度 → x 居中为 0.5（跨度 0 按 1 处理，不除零）
      expect(bottom.x, closeTo(0.0, 1e-9));
    });

    test('空点列 → 投影无效', () {
      expect(TrackProjector(const <PeerTrackPoint>[]).valid, isFalse);
    });
  });
}
