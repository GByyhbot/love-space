/// 2.8.7 P0 回归：点「月经走了」必须能关掉待确认态。
///
/// 🔴 这条**不许手工构造 PeriodRow**：原 bug 就是「引擎单测直接构造带 updated 的
/// 行」才漏过去的。本测试全程走真实链路——
///   fake 后端（PUT 后把 updated 推进到次日，与真实服务端行为一致）
///     → periodControllerProvider.load()（真实解析 TogetherRecord）
///     → controller.periodRows（真实接线，走 periodRowsOf）
///     → periodData() → planEnd() → executePlan()（真实写执行器）
///     → 再取 periodRows → periodData() 断言。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/sse/sse_client.dart';
import 'package:love_space/features/period/period_actions.dart';
import 'package:love_space/features/period/period_controller.dart';
import 'package:love_space/features/period/period_engine.dart';
import 'package:love_space/features/personal/personal_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 2026-11-21 12:00 (+08:00) 的 epoch 秒 —— 「次日点了月经走了」的时刻。
double _ts(String isoLocal) => DateTime.parse(isoLocal).millisecondsSinceEpoch / 1000.0;

class _Store {
  List<Map<String, dynamic>> records;
  final List<RequestOptions> requests = <RequestOptions>[];
  _Store(this.records);
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

/// 真实后端行为：PUT 记录时 body 更新、**updated 刷到当前时刻**。
class _Adapter implements HttpClientAdapter {
  _Adapter(this.store, this.nowEpoch);
  final _Store store;
  final double nowEpoch;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    store.requests.add(o);
    if (o.method == 'GET' && o.uri.path == '/api/records') {
      return _json(store.records);
    }
    if (o.method == 'GET' && o.uri.path == '/api/me') {
      return _json({
        'user': {'id': 'u1', 'name': '我', 'username': 'u1'},
      });
    }
    if (o.method == 'PUT' && o.uri.path.startsWith('/api/records/')) {
      final data = Map<String, dynamic>.from(o.data as Map);
      final rid = o.uri.path.split('/').last;
      for (var i = 0; i < store.records.length; i++) {
        if (store.records[i]['id'] == rid) {
          store.records[i] = {
            ...store.records[i],
            'body': Map<String, dynamic>.from(data['body'] as Map),
            'updated': nowEpoch, // ← 真实服务端会推进；漏传 updated 的接线在此暴露
          };
        }
      }
      return _json(<String, Object>{});
    }
    return _json(<Object>[]);
  }
}

Future<ProviderContainer> _setup(_Store store, double nowEpoch) async {
  final dio = Dio(BaseOptions(
    baseUrl: 'https://test.local',
    validateStatus: api.validateAppStatus,
  ))..httpClientAdapter = _Adapter(store, nowEpoch);
  final c = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    personalCurrentUserProvider.overrideWith((ref) => 'u1'),
  ]);
  addTearDown(c.dispose);
  await c.read(periodControllerProvider.notifier).load();
  return c;
}

void main() {
  const day1 = '2026-11-20'; // 建段当天
  const day2 = '2026-11-21'; // 次日点「月经走了」

  test('P0 全链路：建段 → 点月经走了 → 待确认消失、settledLast 为真', () async {
    final store = _Store([
      {
        'id': 'p1',
        'kind': 'period',
        'author': 'u1',
        'body': {'start': day1, 'length': 1},
        'created': _ts('${day1}T09:00:00+08:00'),
        'updated': _ts('${day1}T09:00:00+08:00'),
      },
    ]);
    final c = await _setup(store, _ts('${day2}T12:00:00+08:00'));
    final ctrl = c.read(periodControllerProvider.notifier);

    // ① 接线层：updated 必须已经一路带下来（漏传就是 0）
    final rows = ctrl.periodRows;
    expect(rows, hasLength(1));
    expect(rows.single.updated, greaterThan(0),
        reason: 'periodRowsOf 必须把 TogetherRecord.updated 传进 PeriodRow');

    // ② 次日应处「待确认」态
    final d1 = periodData(rows, today: day2);
    expect(d1.pending, isNotNull, reason: '次日未点结束，应为待确认');
    expect(d1.settledLast, isFalse);

    // ③ 点「月经走了」——走真实动作 + 真实写执行器
    final plan = planEnd(d1, day2);
    expect(plan.hasWrite, isTrue);
    final failure = await ctrl.executePlan(plan);
    expect(failure, isNull, reason: 'PUT 应 200');

    // ④ 假后端把 updated 推进到次日（真实服务端行为）
    expect(store.records.single['updated'], _ts('${day2}T12:00:00+08:00'));

    // ⑤ 重新取数（executePlan 里 plan.refresh 已 load）→ 待确认必须消失
    final d2 = periodData(ctrl.periodRows, today: day2);
    expect(d2.settledLast, isTrue,
        reason: 'updated 推进后引擎必须判定末段已定稿（这就是 P0 要修的行为）');
    expect(d2.pending, isNull, reason: '定稿后不许再显示待确认');
  });

  test('反向护栏：updated 停在当天时仍为待确认（判据没被放松）', () async {
    final store = _Store([
      {
        'id': 'p1',
        'kind': 'period',
        'author': 'u1',
        'body': {'start': day1, 'length': 1},
        'created': _ts('${day1}T09:00:00+08:00'),
        'updated': _ts('${day1}T09:00:00+08:00'),
      },
    ]);
    final c = await _setup(store, _ts('${day2}T12:00:00+08:00'));
    final rows = c.read(periodControllerProvider.notifier).periodRows;
    final d = periodData(rows, today: day2);
    expect(d.pending, isNotNull);
    expect(d.settledLast, isFalse, reason: 'updated 未推进 → 不算定稿');
  });

  test('TogetherRecord.fromJson 解析 updated（缺省 0 不崩）', () {
    // 直接用引擎入参的 JSON 工厂校验同名字段契约（引擎侧）
    final row = PeriodRow.fromJson({
      'id': 'x', 'author': 'u1', 'body': {'start': day1},
      'updated': 1795500000,
    });
    expect(row.updated, 1795500000);
    final rowNoUpd = PeriodRow.fromJson({'id': 'y', 'author': 'u1', 'body': {}});
    expect(rowNoUpd.updated, 0);
  });
}
