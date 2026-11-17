// 2.3.9 验收材料产出：生理期页四组「主题 × 明暗」渲染截图。
// 产出物：test/goldens/period_<theme>_<mode>.png（跑 --update-goldens 生成），
// 交付时拷贝至 output/。只截图不断言业务——断言在 period_colors_test。
// 🔴 Platform.isWindows 守卫（golden 规范，沿用既有 golden 测试口径）。
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
import 'package:love_space/features/personal/personal_controller.dart';
import 'package:love_space/features/period/period_engine.dart';
import 'package:love_space/features/period/period_page.dart';
import 'package:love_space/features/settings/settings_state.dart'
    show themeSeedColor;

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final FutureOr<ResponseBody> Function(RequestOptions options, int callIndex)
      handler;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return await handler(options, 0);
  }
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
    jsonEncode(data), status,
    headers: {Headers.contentTypeHeader: const ['application/json']});

Map<String, dynamic> _rec(String id, String author, Map<String, dynamic> body) =>
    {
      'id': id,
      'kind': 'period',
      'author': author,
      'body': body,
      'created': 1791195587.0,
      'deleted': null,
      'media': <Object>[],
      'likes': <Object>[],
      'comments': <Object>[],
    };

List<Map<String, dynamic>> _records() {
  final today = spaceTodayIso(DateTime.now().toUtc());
  final start = dayStr(dayNum(today) - 2);
  return [
    _rec('ep1', 'u1', {
      'start': start,
      'length': 6,
      'cycle': 31,
      'content': '这次来得早',
      'flow': 3,
      'symptoms': <String>['腰酸'],
    }),
    _rec('day1', 'u2', {'date': today, 'pain': 2}),
  ];
}

Widget _app(String theme, bool dark) {
  final dio = Dio(BaseOptions(
    baseUrl: 'https://test.local',
    validateStatus: api.validateAppStatus,
  ))
    ..httpClientAdapter = _FakeAdapter((o, i) async {
      if (o.method == 'GET' && o.uri.path == '/api/records') {
        return _json(_records());
      }
      return _json(<String, Object>{});
    });
  final container = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    personalCurrentUserProvider.overrideWith((ref) => 'u1'),
  ]);
  final seed = themeSeedColor(theme, '', dark: dark);
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      theme: ThemeData(
        brightness: dark ? Brightness.dark : Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: dark ? Brightness.dark : Brightness.light,
        ),
        useMaterial3: true,
      ),
      routerConfig: GoRouter(initialLocation: '/period', routes: [
        GoRoute(path: '/period', builder: (_, _) => const PeriodPage()),
      ]),
    ),
  );
}

void main() {
  if (!Platform.isWindows) return; // golden 规范守卫（沿用既有口径）

  final cases = <(String, bool)>[
    ('rose', false), // ① 浅色对照（草莓牛奶默认）
    ('rose', true), // ② 深色对照
    ('lavender', false), // ③ 机制证明：薰衣草浅色
    ('lavender', true), // ④ 机制证明：薰衣草夜色
  ];

  for (final (theme, dark) in cases) {
    testWidgets('period ${theme}_${dark ? "dark" : "light"} 截图', (tester) async {
      tester.view.physicalSize = const Size(393, 859);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(theme, dark));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/period_${theme}_${dark ? "dark" : "light"}.png'),
      );
    }, skip: !Platform.isWindows);
  }
}
