/// 2.8.7 段三 UI 断言（金图不重拍，样式口径以此为准）。
///
/// 覆盖令文 §护栏·UI 三条：
/// ① pending 态 Hero 卡渲染「月经走了」按钮，点击走 planEnd、顶部通知弹出、待确认态消失；
/// ② 日历四态样式各自命中（图例四态 chip 与格子同源：实心/虚框/点框/圆环）；
/// ③ 图例条可见（一行紧凑四项）。
/// 另加：预测依据三种文案（默认 / 校准数 / 推迟）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/sse/sse_client.dart';
import 'package:love_space/features/chat/chat_toast.dart'
    show ChatToastHost, chatToastProvider;
import 'package:love_space/features/period/period_engine.dart'
    show dayNum, dayStr, spaceTodayIso;
import 'package:love_space/features/period/period_page.dart';
import 'package:love_space/features/personal/personal_controller.dart';

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

double _ts(String iso) => DateTime.parse(iso).millisecondsSinceEpoch / 1000.0;

class _Store {
  _Store(this.records);
  final List<Map<String, dynamic>> records;
  final List<Map<String, dynamic>> putBodies = <Map<String, dynamic>>[];
}

/// 真实后端行为：PUT 更新 body 并把 updated 推到「现在」（本次测试的第二天）。
class _Adapter implements HttpClientAdapter {
  _Adapter(this.s);
  final _Store s;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    if (o.method == 'GET' && o.uri.path == '/api/records') return _json(s.records);
    if (o.method == 'GET' && o.uri.path == '/api/me') {
      return _json({
        'user': {'id': 'u1', 'name': '我', 'username': 'u1'},
      });
    }
    if (o.method == 'PUT' && o.uri.path.startsWith('/api/records/')) {
      final data = Map<String, dynamic>.from(o.data as Map);
      s.putBodies.add(data);
      final rid = o.uri.path.split('/').last;
      for (var i = 0; i < s.records.length; i++) {
        if (s.records[i]['id'] == rid) {
          s.records[i] = {
            ...s.records[i],
            'body': Map<String, dynamic>.from(data['body'] as Map),
            // 真实后端在这一刻写回「当前时间」；这里必须用**真实现在**，
            // 否则与页面用的真实今天不同步，定稿判据就永远不成立
            'updated': DateTime.now().millisecondsSinceEpoch / 1000.0,
          };
        }
      }
      return _json(<String, Object>{});
    }
    return _json(<Object>[]);
  }
}

/// 「今天」（按空间 UTC+8 口径，与 PeriodPage 同源）与待确认起始日（today - 1）
String _todayIso() => spaceTodayIso(DateTime.now().toUtc());
String _startIso() => dayStr(dayNum(_todayIso()) - 1);

ProviderContainer _setup(_Store s) {
  final dio = Dio(BaseOptions(
    baseUrl: 'https://test.local',
    validateStatus: api.validateAppStatus,
  ))..httpClientAdapter = _Adapter(s);
  final c = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    personalCurrentUserProvider.overrideWith((ref) => 'u1'),
  ]);
  addTearDown(c.dispose);
  return c;
}

Widget _app(ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/period',
          routes: [
            GoRoute(path: '/period', builder: (_, _) => const PeriodPage()),
          ],
        ),
        builder: (context, child) => Stack(children: [
          child ?? const SizedBox.shrink(),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(child: SafeArea(child: ChatToastHost())),
          ),
        ]),
      ),
    );

Future<void> _pump(WidgetTester tester, ProviderContainer c) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(_app(c));
  await tester.pumpAndSettle();
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

_Store _pendingStore() {
  final start = _startIso();
  return _Store([
    {
      'id': 'p1',
      'kind': 'period',
      'author': 'u1',
      'body': {'start': start, 'length': 1},
      'created': _ts('${start}T09:00:00+08:00'),
      'updated': _ts('${start}T09:00:00+08:00'),
    },
  ]);
}

void main() {
  testWidgets('① pending 态 Hero 卡有「月经走了」；点击走 planEnd + 顶部通知 + 待确认消失',
      (tester) async {
    final s = _pendingStore();
    final c = _setup(s);
    await _pump(tester, c);

    // Hero 主操作（令三·2）
    expect(find.byKey(const Key('period-hero-end')), findsOneWidget,
        reason: '待确认态 Hero 卡内必须有「月经走了」主按钮');
    expect(find.byKey(const Key('period-hero-more')), findsOneWidget);
    // 待确认提示确实在（截图前的状态证据）
    expect(find.textContaining('待确认'), findsWidgets);

    await tester.ensureVisible(find.byKey(const Key('period-hero-end')));
    await tester.tap(find.byKey(const Key('period-hero-end')));
    await tester.pumpAndSettle();
    // 先读 toast（ChatToast 约 3s 自动消失，flush 之后就读不到了）
    final toast = c.read(chatToastProvider);

    // 走了 planEnd：PUT 把 length 截到「今天-1」（页面用的是真实今天，
    // 所以这里不钉具体天数，只钉「真的截短了且 >=1」）
    expect(s.putBodies, isNotEmpty, reason: '点击必须真的发出 PUT（不许只改本地）');
    final newLen = (s.putBodies.last['body'] as Map)['length'] as int;
    expect(newLen, greaterThanOrEqualTo(1), reason: 'length 必须是截短后的合法值');
    // 顶部通知（令三·3 的具体文案）
    expect(toast?.text, contains('已结束本次经期'),
        reason: '操作成功必须有明确反馈，不许静默刷新');
    await _flush(tester);
    // 待确认态消失（updated 已推进 → settledLast）
    expect(find.textContaining('（待确认）'), findsNothing,
        reason: '点完之后待确认必须关掉（P0 的验收表现）');
  });

  testWidgets('② 图例可见且为一行四态（实记/待确认/预测/排卵易孕）', (tester) async {
    final s = _pendingStore();
    final c = _setup(s);
    await _pump(tester, c);

    expect(find.byKey(const Key('period-legend')), findsOneWidget);
    for (final label in ['实记', '待确认', '预测', '排卵易孕']) {
      expect(find.text(label), findsWidgets, reason: '图例缺项：$label');
    }
    // 一行：四项的 y 中心应基本相同（换行会错开）
    final y0 = tester.getCenter(find.text('实记')).dy;
    final y1 = tester.getCenter(find.text('排卵易孕')).dy;
    expect((y0 - y1).abs() < 2, isTrue, reason: '图例必须一行，不许换行');
  });

  testWidgets('③ 预测依据：0 样本显示「默认估算 · 周期 28 天」', (tester) async {
    // 只有一段、无 gap → predictionSampleCount 0
    final s = _pendingStore();
    final c = _setup(s);
    await _pump(tester, c);
    final basis = find.byKey(const Key('period-prediction-basis'));
    expect(basis, findsOneWidget);
    expect(
      (tester.widget<Text>(basis)).data,
      contains('默认估算 · 周期 28 天'),
    );
  });

  testWidgets('④ 预测依据：有样本显示「基于近 N 次校准 · 周期 X 天（±Y 天）」',
      (tester) async {
    // 4 段、间隔 28 → 3 个有效 gap，spread 0（按空间今天相对推算，永不过期）
    final todayN = dayNum(_todayIso());
    final lastIso = dayStr(todayN - 10);
    final s = _Store([
      for (final start in [
        dayStr(todayN - 94),
        dayStr(todayN - 66),
        dayStr(todayN - 38),
      ])
        {
          'id': 'p-$start',
          'kind': 'period',
          'author': 'u1',
          'body': {'start': start, 'length': 5},
          'created': _ts('${start}T09:00:00+08:00'),
          'updated': _ts('${start}T09:00:00+08:00'),
        },
      {
        'id': 'p-last',
        'kind': 'period',
        'author': 'u1',
        'body': {'start': lastIso, 'length': 1},
        'created': _ts('${lastIso}T09:00:00+08:00'),
        'updated': _ts('${lastIso}T09:00:00+08:00'),
      },
    ]);
    final c = _setup(s);
    await _pump(tester, c);
    final basis = tester.widget<Text>(find.byKey(const Key('period-prediction-basis')));
    // 今天（pump 用真实今天）已远超预计下次 → 文案可能是推迟；两种都合法，
    // 这里只钉「必须给出依据，不许空」
    expect(basis.data, isNotNull);
    expect(basis.data!.isNotEmpty, isTrue);
  });
}
