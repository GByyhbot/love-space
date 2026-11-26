/// 2.8.0 报备信息展示层护栏（施工令四）。
///
/// 覆盖：①有数据渲染（双方字段齐全）②对方空态 ③拉取失败态
/// ④距离行缺一方数据不渲染 ⑤Haversine 距离单测（已知两点量级）
/// ⑥SSE 第 7 段 `peer` 已在客户端解析（源码语义断言）。
///
/// 桩：Dio 走假 HttpClientAdapter（不触网）；原生 peer_loc/native 通道
/// 用 MethodCallHandler 固定返回；SSE 流用 StreamController 手动喂。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/peer/peer_expected_state.dart';
import 'package:love_space/core/peer/peer_report_data.dart';
import 'package:love_space/core/sse/sse_client.dart';
import 'package:love_space/features/together/peer_report_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return handler(options);
  }
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
    jsonEncode(data), status,
    headers: {Headers.contentTypeHeader: const ['application/json']});

const _native = MethodChannel('peer_loc/native');

/// 固定时间戳：全部断言避开「相对时间」（依赖 now，不稳），只断言绝对时间。
/// 用本地 DateTime 造值，避免手写 epoch 踩时区/日期错位。
final double _t = DateTime(2026, 11, 23, 14, 30).millisecondsSinceEpoch / 1000;

Map<String, Object?> _loc({
  double lat = 39.9087,
  double lng = 116.3975,
  int battery = 82,
  bool charging = false,
  String net = 'wifi',
  double? updated,
}) =>
    {
      'user': 'u1',
      'lat': lat,
      'lng': lng,
      'acc': 12.0,
      'speed': 0.0,
      'battery': battery,
      'charging': charging,
      'net': net,
      'wifi': 'home',
      'updated': updated ?? _t,
    };

Map<String, Object?> _status({
  Object? mine,
  Object? peer,
  bool closedOff = false,
}) =>
    {
      'revision': 7,
      'mine': {'settings': {}, 'location': mine, 'enabled': true},
      'peer': {
        'settings': {},
        'location': peer,
        'enabled': !closedOff,
        'closed_off': closedOff,
      },
    };

Map<String, Object?> _track(List<Object?> peerPoints,
        {bool closedOff = false}) =>
    {
      'date': '2026-11-23',
      'mine': <Object?>[],
      'peer': {'closed_off': closedOff, 'points': peerPoints},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kPeerExpectedKey: true,
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, (call) async {
      switch (call.method) {
        case 'status':
          return {'running': true, 'received': 12, 'queue': 2, 'reported': 40};
        case 'batteryIgnored':
          return true;
        case 'requestIgnoreBattery':
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, null);
  });

  Future<void> pumpPage(WidgetTester tester, _FakeAdapter adapter) async {
    // 2.8.7 全量：页面变长（状态大卡+使用卡+足迹卡+时间线+我方），
    // 视口开高一点让各节一次建出来（否则 ListView 惰性构建看不到断言目标）
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(393, 2400);
    addTearDown(tester.view.reset);
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final sse = StreamController<SseEvent>.broadcast();
    addTearDown(sse.close);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        // SSE 换成受控流：避免真实 SSE 客户端在测试里留 watchdog Timer
        sseEventsProvider.overrideWith((ref) => sse.stream),
      ],
      child: const MaterialApp(home: PeerReportPage()),
    ));
    await tester.pump(); // 首帧
    await tester.pump(const Duration(milliseconds: 50)); // microtask 拉取
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('① 有数据：双方字段齐全（TA 电量/充电/网络/坐标/距离/今日点数 + 我的实态）',
      (tester) async {
    final adapter = _FakeAdapter((o) {
      if (o.path.contains('/api/peer/status')) {
        return _json(_status(
          mine: _loc(lat: 39.9087, lng: 116.3975),
          // 故宫一带，距天安门约 845m
          peer: _loc(lat: 39.9163, lng: 116.3972, net: 'cell'),
        ));
      }
      return _json(_track([1, 2, 3]));
    });
    await pumpPage(tester, adapter);

    // 2.8.7 全量重构：原「TA 的报备」块并入顶部状态大卡与今日足迹卡
    expect(find.text('TA 的状态'), findsOneWidget);
    expect(find.text('我的报备'), findsOneWidget);
    expect(find.text('82% · 未充电'), findsOneWidget, reason: '电量与充电原值呈现');
    // 2.8.7 第三段：网络改由顶部状态卡呈现，按口径说人话（不再暴露 cell 原值）
    expect(find.text('移动数据'), findsOneWidget, reason: '移动数据说人话');
    expect(find.text('39.916300, 116.397200'), findsOneWidget,
        reason: '坐标按 GCJ-02 原值展示');
    expect(find.textContaining('今日报备'), findsOneWidget,
        reason: '接口给得出就显示');
    expect(find.textContaining('3 点'), findsOneWidget);
    // 距离行：约 845m → 米档
    expect(find.textContaining('距我约'), findsOneWidget);
    expect(find.textContaining('米'), findsWidgets);
    // 我的报备：实态 / 队列 / 期望态 / 电池豁免（与设置页同源）
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('2 条'), findsOneWidget);
    expect(find.text('期望开启'), findsOneWidget);
    expect(find.text('已豁免'), findsOneWidget);
    // 最近一次上报：相对 + 绝对并列（绝对时间可断言）
    expect(find.textContaining('2026-11-23 14:30'), findsWidgets);
    expect(find.text('状态未知'), findsNothing);
  });

  testWidgets('② 对方空态：没有报备数据 → 空态文案 + 无距离行', (tester) async {
    final adapter = _FakeAdapter((o) {
      if (o.path.contains('/api/peer/status')) {
        return _json(_status(mine: _loc(), peer: null));
      }
      return _json(_track(<Object?>[], closedOff: true));
    });
    await pumpPage(tester, adapter);

    expect(find.text('TA 还没有报备数据'), findsOneWidget);
    expect(find.text('开通位置共享后这里会显示 TA 的最新报备'), findsOneWidget);
    expect(find.textContaining('距我约'), findsNothing, reason: '无对方坐标不得渲染距离');
    expect(find.text('今日报备'), findsNothing, reason: 'track 关闭不显示点数行');
  });

  testWidgets('③ 拉取失败：状态未知 + 重试入口（不显示旧值冒充）', (tester) async {
    final adapter = _FakeAdapter((o) {
      if (o.path.contains('/api/peer/status')) {
        return ResponseBody.fromString('boom', 500);
      }
      return ResponseBody.fromString('boom', 500);
    });
    await pumpPage(tester, adapter);

    expect(find.textContaining('状态未知'), findsWidgets);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('TA 的报备'), findsNothing, reason: '拉不到不得渲染 TA 块数据');
    // 点重试必须真的重发请求
    final before = adapter.requests.length;
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.requests.length, greaterThan(before));
  });

  testWidgets('④ 距离行：我方无坐标 → 整行不渲染（对方有坐标也不显示 0）',
      (tester) async {
    final adapter = _FakeAdapter((o) {
      if (o.path.contains('/api/peer/status')) {
        return _json(_status(mine: null, peer: _loc(lat: 39.9163)));
      }
      return _json(_track(<Object?>[1]));
    });
    await pumpPage(tester, adapter);

    expect(find.text('TA 的状态'), findsOneWidget);
    expect(find.textContaining('距我约'), findsNothing);
    expect(find.text('距离'), findsNothing);
    // 对方字段照常渲染（2.8.7：网络在顶部状态卡里按口径呈现）
    expect(find.text('移动数据'), findsNothing); // 本用例 peer net 为默认 wifi
    expect(find.text('Wi-Fi（home）'), findsOneWidget);
  });

  test('⑤ Haversine：已知两点量级正确 + 单位自适应', () {
    // 天安门(39.9087,116.3975) → 故宫(39.9163,116.3972)
    final m = haversineMeters(39.9087, 116.3975, 39.9163, 116.3972);
    expect(m, greaterThan(800), reason: '同城两点应在 800m 量级');
    expect(m, lessThan(900), reason: '不得因单位/半径写错而放大 10 倍');
    expect(formatDistance(m), endsWith('米'));
    expect(formatDistance(1200), '1.2 公里');
    expect(formatDistance(999), '999 米');
    expect(formatDistance(1000), '1.0 公里');
    // 零距离不产生 NaN
    expect(haversineMeters(39.9, 116.4, 39.9, 116.4), closeTo(0, 0.001));
    // 任一方缺坐标 → 距离行不渲染
    final a = PeerLatest.fromJson(_loc());
    final b = PeerLatest.fromJson(_loc(lat: 39.9163));
    expect(distanceLine(null, null), isNull);
    expect(distanceLine(a, null), isNull);
    expect(distanceLine(null, b), isNull);
    expect(distanceLine(a, b), isNotNull);
  });

  test('⑥ 相对时间口径（避免出现负值/越界）', () {
    final now = DateTime.fromMillisecondsSinceEpoch((_t * 1000).round());
    double ago(int seconds) => _t - seconds;
    expect(relativeTimeZh(ago(10), now: now), '刚刚');
    expect(relativeTimeZh(ago(120), now: now), '2 分钟前');
    expect(relativeTimeZh(ago(3 * 3600), now: now), '3 小时前');
    expect(relativeTimeZh(ago(2 * 86400), now: now), '2 天前');
    expect(relativeTimeZh(_t + 60, now: now), '刚刚', reason: '时钟漂移不显示负数');
    expect(relativeTimeZh(null), '未知');
    expect(absoluteTimeZh(null), '未知');
  });

  test('⑦ SSE 第 7 段 peer 已在客户端解析（源码语义断言）', () {
    final src = _read('lib/core/sse/sse_client.dart');
    expect(src.contains("peer: j?['peer'] == true"), isTrue,
        reason: 'peer_revision 段未解析 → 报备页静默刷新永不触发');
    expect(src.contains('final bool peer;'), isTrue);
  });

  test('⑧ 卡面摘要一行（入口卡口径）', () {
    final now = DateTime(2026, 11, 23, 14, 42);
    final withData = PeerStatusData.fromJson(_status(peer: _loc()));
    // 12 分钟前报备（now 14:42 / 报备 14:30）→ 电量 82%
    expect(peerSummaryLine(withData, now: now), 'TA · 12 分钟前报备 · 电量 82%');
    // 电量读不到 → 不拼「电量 未知%」
    expect(
      peerSummaryLine(
          PeerStatusData.fromJson(_status(peer: _loc(battery: -1))),
          now: now),
      'TA · 12 分钟前报备',
    );
    // 对方无数据 / 关闭共享 / 失败
    expect(peerSummaryLine(PeerStatusData.fromJson(_status(peer: null))),
        'TA 还没有报备数据');
    expect(
        peerSummaryLine(
            PeerStatusData.fromJson(_status(peer: _loc(), closedOff: true))),
        'TA 已关闭位置共享');
    expect(peerSummaryLine(null), '状态未知');
    expect(peerSummaryLine(withData, failed: true), '状态未知');
  });
}

String _read(String path) => File(path).readAsStringSync();
