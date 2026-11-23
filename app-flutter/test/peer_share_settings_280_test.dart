/// 2.8.0 P1 伴侣共享开关页 · 服务层护栏（施工令四·1）。
///
/// 覆盖：
/// ① `GET /api/peer/settings` 顶层四键正常解析；
/// ② 缺键 / 非 bool → 回落 `true`（与 `app/peer.py:load_settings` 同口径）；
/// ③ `PUT /api/peer/settings` 请求体**必含全部 4 键**——只改一个键时其余
///    3 键按当前值原样携带（后端逐键 `bool(data.get(k, True))` 覆盖写，
///    漏传即静默重置回 true）；
/// ④ 4xx 经 `writeResponseError` 抛 [PeerApiException]（不许当成功放行）；
/// ⑤ PUT 返回值以后端落库结果为准（不是本地快照）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/peer/peer_report_api.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
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
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: const ['application/json'],
      },
    );

Dio _dio(_Adapter a) => Dio(BaseOptions(
      baseUrl: 'https://test.local',
      validateStatus: api.validateAppStatus,
    ))
      ..httpClientAdapter = a;

void main() {
  test('GET 顶层四键正常解析', () async {
    final a = _Adapter((_) => _json({
          'location': false,
          'track': true,
          'events': false,
          'usage': true,
        }));
    final s = await fetchPeerSettings(_dio(a));
    expect(s.location, isFalse);
    expect(s.track, isTrue);
    expect(s.events, isFalse);
    expect(s.usage, isTrue);
    expect(a.requests.single.method, 'GET');
    expect(a.requests.single.path, '/api/peer/settings');
  });

  test('缺键与非 bool 回落 true（后端 load_settings 同口径）', () async {
    final a = _Adapter((_) => _json({
          'location': false,
          'events': 'off', // 非 bool → 按 true
          // track / usage 缺键 → true
        }));
    final s = await fetchPeerSettings(_dio(a));
    expect(s.location, isFalse, reason: '显式 false 不能被吞');
    expect(s.track, isTrue);
    expect(s.events, isTrue);
    expect(s.usage, isTrue);
  });

  test('GET 空对象 = 全开', () async {
    final s = await fetchPeerSettings(_dio(_Adapter((_) => _json({}))));
    expect(s, PeerShareSettings.allOn);
  });

  test('PUT 只改 events 时请求体仍含全部 4 键且其余原样', () async {
    final a = _Adapter((_) => _json({
          'location': false,
          'track': false,
          'events': false,
          'usage': true,
        }));
    final current = const PeerShareSettings(
      location: false,
      track: false,
      events: true,
      usage: true,
    );
    final saved = await updatePeerSettings(
      _dio(a),
      current.copyWith(events: false),
    );

    final req = a.requests.single;
    expect(req.method, 'PUT');
    expect(req.path, '/api/peer/settings');
    final body = (req.data as Map).cast<String, Object?>();
    expect(body.keys.toSet(), {'location', 'track', 'events', 'usage'},
        reason: '漏任何一键，后端都会把它覆盖成 true');
    expect(body['location'], isFalse);
    expect(body['track'], isFalse);
    expect(body['events'], isFalse);
    expect(body['usage'], isTrue);

    expect(saved.events, isFalse);
    expect(saved, isA<PeerShareSettings>());
  });

  test('PUT 返回值以后端落库结果为准（不信本地快照）', () async {
    // 后端把 usage 强制改回 true（模拟未来服务端口径变化）
    final a = _Adapter((_) => _json({
          'location': true,
          'track': true,
          'events': true,
          'usage': true,
        }));
    final s = await updatePeerSettings(
      _dio(a),
      const PeerShareSettings(
          location: false, track: false, events: false, usage: false),
    );
    expect(s, PeerShareSettings.allOn);
  });

  test('GET 4xx 抛 PeerApiException 原文（不回落全开）', () async {
    final a = _Adapter((_) => _json({'detail': '未登录'}, 401));
    expect(
      () => fetchPeerSettings(_dio(a)),
      throwsA(isA<PeerApiException>()
          .having((e) => e.detail.contains('未登录'), 'detail', isTrue)),
    );
  });

  test('PUT 4xx 抛 PeerApiException 原文', () async {
    final a = _Adapter((_) => _json({'detail': '空间未初始化'}, 400));
    expect(
      () => updatePeerSettings(
          _dio(a), const PeerShareSettings(location: false)),
      throwsA(isA<PeerApiException>()
          .having((e) => e.detail.contains('空间未初始化'), 'detail', isTrue)),
    );
  });

  test('toJson 恒 4 键（全开基线也不能少键）', () {
    expect(PeerShareSettings.allOn.toJson().keys.toSet(),
        {'location', 'track', 'events', 'usage'});
  });
}
