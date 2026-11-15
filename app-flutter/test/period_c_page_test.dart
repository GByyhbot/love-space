/* 条目 8 · 段 C · 页面 widget 用例：入口活卡、独立二级页、返回按钮 + 系统
   手势、空态、13 板块落地。跑前 unset 八个代理变量（flutter_tester 本地
   WebSocket 会被 127.0.0.1 代理劫持）。 */
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/sse/sse_client.dart'
    show SseEvent, sseEventsProvider;
import 'package:love_space/features/chat/chat_toast.dart'
    show ChatToastHost;
import 'package:love_space/features/personal/personal_controller.dart';
import 'package:love_space/features/period/period_analysis.dart';
import 'package:love_space/features/period/period_analysis_page.dart';
import 'package:love_space/features/period/period_page.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.records);
  final List<Map<String, dynamic>> records;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.method == 'GET' && options.uri.path == '/api/records') {
      return ResponseBody.fromString(jsonEncode(records), 200,
          headers: {Headers.contentTypeHeader: const ['application/json']});
    }
    return ResponseBody.fromString('[]', 200,
        headers: {Headers.contentTypeHeader: const ['application/json']});
  }
}

Map<String, dynamic> _load(String name) => jsonDecode(
      File('test/fixtures/$name').readAsStringSync(),
    ) as Map<String, dynamic>;

List<Map<String, dynamic>> _caseRecords(String name) {
  final c = _load('period_c_cases.json');
  final rec = (c['cases'] as Map)[name] as Map;
  // 夹具是纯 `{id,author,body}`；补上 /api/records 的元素形状（kind 必填，
  // PeriodController.load 会按 kind 过滤）。
  return (rec['records'] as List)
      .map((e) => <String, dynamic>{
        ...(e as Map).cast<String, dynamic>(),
        'kind': 'period',
        'created': 1791195587.0,
        'deleted': null,
        'media': <Object>[],
        'likes': <Object>[],
        'comments': <Object>[],
      })
      .toList();
}

Future<ProviderContainer> _setup(List<Map<String, dynamic>> records) async {
  final dio = Dio(BaseOptions(
    baseUrl: 'https://test.local',
    validateStatus: api.validateAppStatus,
  ))..httpClientAdapter = _FakeAdapter(records);
  final container = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    personalCurrentUserProvider.overrideWith((ref) => 'u1'),
  ]);
  addTearDown(container.dispose);
  return container;
}

Widget _app(ProviderContainer container, {String initial = '/period'}) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: initial,
          routes: [
            GoRoute(
                path: '/period', builder: (_, _) => const PeriodPage()),
            GoRoute(
                path: '/period/analysis',
                builder: (_, _) => const PeriodAnalysisPage()),
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

Future<void> _pump(WidgetTester tester, ProviderContainer container,
    {String initial = '/period'}) async {
  tester.view.physicalSize = const Size(1080, 3200);
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(_app(container, initial: initial));
  await tester.pumpAndSettle();
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

void main() {
  group('入口卡 → 独立二级页（活入口，非死卡）', () {
    testWidgets('主页 analysis-entry 卡文案逐字 + 点击 push /period/analysis',
        (tester) async {
      final c = await _setup(_caseRecords('analysisRich'));
      await _pump(tester, c);
      expect(find.text('数据分析'), findsOneWidget);
      expect(find.text('周期、流量、痛经、体温的变化'), findsOneWidget);
      expect(find.byKey(const Key('period-analysis-entry')), findsOneWidget);

      await tester.tap(find.byKey(const Key('period-analysis-entry')));
      await tester.pumpAndSettle();
      expect(find.text('把这半年的记录，摊成看得懂的变化。'), findsOneWidget,
          reason: 'period.js:677 页头副标题逐字');
      expect(find.byType(BackButton), findsOneWidget,
          reason: 'AppBar automaticallyImplyLeading 不关');
      expect(find.text('数据分析'), findsNothing,
          reason: '已进入二级页，主页入口卡不在栈上');
      await _flush(tester);
    });

    testWidgets('返回按钮 + 系统返回手势都能回生理期主页', (tester) async {
      final c = await _setup(_caseRecords('analysisRich'));
      await _pump(tester, c);

      // 系统手势
      await tester.tap(find.byKey(const Key('period-analysis-entry')));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('数据分析'), findsOneWidget,
          reason: '系统手势回主页');
      expect(find.byTooltip('上个月'), findsOneWidget);

      // AppBar 返回按钮
      await tester.tap(find.byKey(const Key('period-analysis-entry')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('数据分析'), findsOneWidget,
          reason: '返回按钮回主页');
      await _flush(tester);
    });
  });

  group('空态（period.js:678）', () {
    testWidgets('无经期记录：空态文案 + 回到生理期按钮可返回', (tester) async {
      final c = await _setup(_caseRecords('empty'));
      await _pump(tester, c);
      await tester.tap(find.byKey(const Key('period-analysis-entry')));
      await tester.pumpAndSettle();
      expect(find.text(analysisEmptyText), findsOneWidget);
      expect(find.text(analysisBackButton), findsOneWidget);
      expect(find.text(analysisSecPrediction), findsNothing,
          reason: '空态早返回，不渲染任何板块');

      await tester.tap(find.text(analysisBackButton));
      await tester.pumpAndSettle();
      expect(find.text('数据分析'), findsOneWidget);
      await _flush(tester);
    });
  });

  group('13 板块落地（有数据）', () {
    testWidgets('概览 + 12 张板块卡标题与 Web 逐字一致', (tester) async {
      final c = await _setup(_caseRecords('analysisRich'));
      await _pump(tester, c, initial: '/period/analysis');
      // 概览（①）
      expect(find.text('把这半年的记录，摊成看得懂的变化。'), findsOneWidget);
      expect(find.text('很规律'), findsOneWidget,
          reason: 'analysisRich score=99 → grade 很规律（Web 实跑）');
      expect(find.text(analysisDisclaimer), findsOneWidget);
      // ②–⑬ 逐张滚动断言
      for (final title in <String>[
        analysisSecPrediction,
        analysisSecCycle,
        analysisSecLength,
        analysisSecFlow,
        analysisSecPain,
        analysisSecColor,
        analysisSecSymptoms,
        analysisSecMood,
        analysisSecDischarge,
        analysisSecSex,
        analysisSecTemp,
        analysisSecWeight,
      ]) {
        final finder = find.text(title);
        await tester.scrollUntilVisible(finder, 240);
        expect(finder, findsOneWidget, reason: '$title 板块必须落地');
      }
      // 尾注
      final foot = find.text(analysisFoot);
      await tester.scrollUntilVisible(foot, 240);
      expect(foot, findsOneWidget);
      await _flush(tester);
    });

    testWidgets('无流量/痛经记录：对应板块不出现（不做空卡）', (tester) async {
      final c = await _setup(_caseRecords('noFlowPain'));
      await _pump(tester, c, initial: '/period/analysis');
      expect(find.text(analysisSecFlow), findsNothing);
      expect(find.text(analysisSecPain), findsNothing);
      expect(find.text(analysisSecColor), findsNothing);
      expect(find.text(analysisSecDischarge), findsNothing);
      expect(find.text(analysisSecSymptoms), findsOneWidget);
      expect(find.text(analysisSecSex), findsOneWidget);
      await _flush(tester);
    });
  });

  group('源码级护栏', () {
    test('入口是真跳转、路由已注册、不引图表库、提醒仍不做', () {
      final page =
          File('lib/features/period/period_page.dart').readAsStringSync();
      expect(page.contains("context.push('/period/analysis')"), isTrue);
      final mainDart = File('lib/main.dart').readAsStringSync();
      expect(mainDart.contains("path: '/period/analysis'"), isTrue);
      expect(mainDart.contains('const PeriodAnalysisPage()'), isTrue);
      final charts =
          File('lib/features/period/period_charts.dart').readAsStringSync();
      expect(charts.contains('CustomPaint'), isTrue);
      expect(charts.contains('fl_chart') || charts.contains('charts_flutter'),
          isFalse,
          reason: 'period.js:524 不引 Chart.js，App 不引第三方图表库');
      expect(page.contains('PERIOD_REMIND_DAYS'), isFalse,
          reason: 'D3 提醒仍不做');
    });
  });
}
