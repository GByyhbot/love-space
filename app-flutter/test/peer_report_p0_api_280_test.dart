/// 2.8.0 报备入口 P0 · 服务层护栏（施工令四·1/2/3/6）。
///
/// 覆盖：
/// ① PeerEvent 解析：扩列全量行 / 缺列旧行 / ack 有无两态；
/// ② client_id 稳定性：队列补发复用入队时的同一 id、`ts` 用入队时刻；
/// ③ flush 单飞锁防重入 + 422/其他 4xx 出队不卡死后续条目 + 网络/5xx 保留；
/// ④ 422 映射：detail 含「关闭」→ ReportShareClosed，其他 4xx → 通用原文；
/// ⑤ presets 回落：接口为空/失败时用默认 6 条，且**不落库**（不发 PUT）。
///
/// 桩：假 HttpClientAdapter（不触网）+ 临时目录（不依赖 path_provider）。
/// 🔴 夹具必须与生产共用 `validateAppStatus`（4xx 放行），否则 422 分支
/// 在测试里会被 Dio 默认策略抢先抛成 DioException，掩盖真机形状。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/peer/peer_report_api.dart';
import 'package:love_space/core/peer/peer_report_queue.dart';

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

Map<String, Object?> _event({
  String id = 'e1',
  String type = 'manual_report',
  double ts = 1795500000,
  String summary = '平安到家啦',
  Object? ack,
  String? source = 'manual',
  String? scene = 'arrive_home',
  String? note = '',
  String? placeName = '',
  String? clientId = 'c1',
  String user = 'u1',
  bool? mine,
}) =>
    {
      'id': id,
      'user': user,
      'type': type,
      'ts': ts,
      'summary': summary,
      'pushed': 1,
      'created': ts,
      'source': ?source,
      'scene': ?scene,
      'note': ?note,
      'place_name': ?placeName,
      'client_id': ?clientId,
      'ack': ack,
      'mine': ?mine,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('① PeerEvent 解析', () {
    test('扩列全量行：source/scene/note/place/client_id/ack 全取到', () {
      final e = PeerEventItem.fromJson(_event(
        ack: {'by': 'u2', 'emoji': '❤️', 'at': 1795500100.0},
        note: '路上堵了会',
        placeName: '地铁 10 号线',
      ));
      expect(e.isManualReport, isTrue);
      expect(e.source, 'manual');
      expect(e.scene, 'arrive_home');
      expect(e.note, '路上堵了会');
      expect(e.placeName, '地铁 10 号线');
      expect(e.clientId, 'c1');
      expect(e.ack?.emoji, '❤️');
      expect(e.ack?.by, 'u2');
    });

    test('缺列旧行：source 缺省 auto、ack=null、不因缺字段解析失败', () {
      final e = PeerEventItem.fromJson({
        'id': 'old1',
        'type': 'arrive_place',
        'ts': 1795400000,
        'summary': '到了公司',
      });
      expect(e.source, 'auto');
      expect(e.ack, isNull);
      expect(e.note, '');
      expect(e.placeName, '');
      expect(e.clientId, '');
      expect(e.isManualReport, isFalse);
    });

    test('ack 两态：空 ack 映射为 null，非空映射 emoji', () {
      expect(PeerEventItem.fromJson(_event(ack: null)).ack, isNull);
      expect(
        PeerEventItem.fromJson(_event(ack: {'by': 'u2', 'emoji': '👍'}))
            .ack
            ?.emoji,
        '👍',
      );
      // ack 里没有 emoji 的脏数据 → 视作未回应，不渲染「已回应 null」
      expect(
        PeerEventItem.fromJson(_event(ack: {'by': 'u2'})).ack,
        isNull,
      );
    });
  });

  group('④ 422 映射', () {
    test('422 且 detail 含「关闭」→ ReportShareClosed', () async {
      final a = _Adapter((_) => _json(
            {'detail': '报备事件共享已关闭'},
            422,
          ));
      await expectLater(
        sendReport(_dio(a), scene: 'depart', clientId: 'cid-1'),
        throwsA(isA<ReportShareClosed>()),
      );
    });

    test('422 其他 detail（非关闭语义）→ PeerApiException 原文', () async {
      final a = _Adapter((_) => _json({'detail': 'scene 过长'}, 422));
      await expectLater(
        sendReport(_dio(a), scene: 'depart', clientId: 'cid-1'),
        throwsA(isA<PeerApiException>()
            .having((e) => e.detail, 'detail', 'scene 过长')),
      );
    });

    test('400/404 ack → PeerApiException（不许当成功）', () async {
      final a = _Adapter((_) => _json({'detail': '不能回应自己的报备'}, 400));
      await expectLater(
        ackReport(_dio(a), 'e1', '❤️'),
        throwsA(isA<PeerApiException>()),
      );
    });

    test('成功：created=false 视为幂等命中而非失败', () async {
      final a = _Adapter((_) => _json({
            'ok': true,
            'created': false,
            'event': _event(),
            'peer_revision': 9,
          }));
      final res = await sendReport(_dio(a), scene: 'arrive_home', clientId: 'c1');
      expect(res.created, isFalse);
      expect(res.event.summary, '平安到家啦');
    });

    test('请求体带 client_id / push / ts（幂等与静默预设的依据）', () async {
      final a = _Adapter((_) => _json({
            'ok': true,
            'created': true,
            'event': _event(),
          }));
      await sendReport(
        _dio(a),
        scene: 'meal',
        clientId: 'cid-fixed',
        summary: '正在干饭',
        push: false,
        ts: 1795500123.0,
      );
      final body = a.requests.single.data as Map;
      expect(body['client_id'], 'cid-fixed');
      expect(body['push'], false);
      expect(body['ts'], 1795500123.0);
      expect(body['scene'], 'meal');
    });
  });

  group('② 队列：client_id 复用与单飞锁', () {
    late Directory dir;
    late ReportOutbox outbox;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('report-outbox-');
      outbox = ReportOutbox(dirProvider: () async => dir);
    });

    tearDown(() async {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('补发复用入队时的 client_id，ts 取入队时刻（不取补发时刻）', () async {
      await outbox.enqueue(const PendingReport(
        scene: 'depart',
        clientId: 'cid-keep',
        createdAt: 1795500000.0,
        summary: '准备出门啦',
        note: '先走一步',
      ));
      final a = _Adapter((_) => _json({
            'ok': true,
            'created': true,
            'event': _event(),
          }));
      final res = await outbox.flush(_dio(a));
      expect(res.sent, 1);
      expect(res.kept, 0);
      final body = a.requests.single.data as Map;
      expect(body['client_id'], 'cid-keep', reason: '重试必须复用同一 client_id');
      expect(body['ts'], 1795500000.0, reason: '报备时间按当时算');
      expect(await outbox.load(), isEmpty, reason: '发成功即出队');
    });

    test('单飞锁：flush 进行中再触发 → skipped 且不重复发', () async {
      await outbox.enqueue(const PendingReport(
        scene: 'depart',
        clientId: 'cid-lock',
        createdAt: 1795500000.0,
      ));
      final a = _Adapter((_) => _json({
            'ok': true,
            'created': true,
            'event': _event(),
          }));
      final dio = _dio(a);
      // 并发两路：一路干活，另一路被锁拦下
      final results = await Future.wait([outbox.flush(dio), outbox.flush(dio)]);
      expect(results.where((r) => r.skipped).length, 1);
      expect(a.requests.length, 1, reason: '锁生效时不得发第二次');
      expect(results.firstWhere((r) => !r.skipped).sent, 1);
    });

    test('422 关闭：出队丢弃 + closedOff 标记 + 不卡死后续条目', () async {
      await outbox.enqueue(const PendingReport(
        scene: 'depart',
        clientId: 'cid-closed',
        createdAt: 1795500000.0,
      ));
      await outbox.enqueue(const PendingReport(
        scene: 'miss',
        clientId: 'cid-ok',
        createdAt: 1795500001.0,
      ));
      var call = 0;
      final a = _Adapter((o) {
        final body = o.data as Map;
        call++;
        if (body['client_id'] == 'cid-closed') {
          return _json({'detail': '报备事件共享已关闭'}, 422);
        }
        return _json({'ok': true, 'created': true, 'event': _event(id: 'x')});
      });
      final res = await outbox.flush(_dio(a));
      expect(call, 2, reason: '毒丸不得阻断后续条目');
      expect(res.dropped, 1);
      expect(res.sent, 1);
      expect(res.closedOff, isTrue);
      expect(await outbox.load(), isEmpty);
    });

    test('其他 4xx：出队丢弃，不进重试循环', () async {
      await outbox.enqueue(const PendingReport(
        scene: 'custom',
        clientId: 'cid-bad',
        createdAt: 1795500000.0,
      ));
      final a = _Adapter((_) => _json({'detail': 'scene 非法'}, 400));
      final res = await outbox.flush(_dio(a));
      expect(res.dropped, 1);
      expect(res.sent, 0);
      expect(await outbox.load(), isEmpty);
    });

    test('网络类错误 / 5xx：保留队列（下次再发）', () async {
      await outbox.enqueue(const PendingReport(
        scene: 'depart',
        clientId: 'cid-net',
        createdAt: 1795500000.0,
      ));
      final a = _Adapter((_) => _json({'detail': 'boom'}, 502));
      final res = await outbox.flush(_dio(a));
      expect(res.sent, 0);
      expect(res.dropped, 0);
      expect(res.kept, 1);
      expect((await outbox.load()).single.clientId, 'cid-net');

      // 纯网络层（连接错误）同样保留
      final b = _Adapter((_) => throw DioException.connectionError(
            requestOptions: RequestOptions(path: '/api/peer/report'),
            reason: 'offline',
          ));
      final res2 = await outbox.flush(_dio(b));
      expect(res2.kept, 1);
      expect((await outbox.load()).single.clientId, 'cid-net');
    });
  });

  group('⑤ presets 回落', () {
    test('正常返回：按服务端顺序解析', () async {
      final a = _Adapter((_) => _json({
            'presets': [
              {
                'scene': 'depart',
                'label': '出门啦',
                'emoji': '🚶',
                'summary': '走啦',
                'push': false,
              },
            ],
          }));
      final presets = await fetchReportPresets(_dio(a));
      expect(presets.single.scene, 'depart');
      expect(presets.single.push, isFalse);
      expect(presets.single.summary, '走啦');
    });

    test('空集 → 回落默认 6 条（不落库、不发 PUT）', () async {
      final a = _Adapter((_) => _json({'presets': <Object?>[]}));
      final presets = await fetchReportPresets(_dio(a));
      expect(presets.length, 6);
      expect(presets.map((e) => e.scene), containsAll(<String>[
        'depart',
        'arrive_home',
        'meal',
        'busy',
        'sleep',
        'miss',
      ]));
      expect(a.requests.every((r) => r.method == 'GET'), isTrue,
          reason: '回落只渲染，不许写回服务端');
    });
  });

  group('事件流合并', () {
    test('mine + peer 合并为单一时间序（ts 降序），closed_off 保留标记', () async {
      final a = _Adapter((_) => _json({
            'date': '2026-11-24',
            'mine': [_event(id: 'm1', ts: 100, mine: true)],
            'peer': {
              'closed_off': false,
              'events': [
                _event(id: 'p1', ts: 300, summary: '到家了'),
                _event(id: 'p2', ts: 200, summary: '出门啦'),
              ],
            },
          }));
      final day = await fetchPeerEvents(_dio(a));
      expect(day.events.map((e) => e.id).toList(), ['p1', 'p2', 'm1']);
      expect(day.peerClosedOff, isFalse);
      expect(day.latestPeerManualReport?.summary, '到家了');
      expect(day.mineEvents.single.id, 'm1');
    });
  });
}
