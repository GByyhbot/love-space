/* 条目 8 · 段 8-B 落地自测（2.2.2/VC222 · 生理期主页 UI）。
   覆盖验收点 ①–⑤ 的「App 真实写路径 + widget」侧：
   · executePlan 真实 HTTP 请求逐项与 Web 实跑期望值全等（四动作 / 9 字段）；
   · 7-C 错误通道：4xx 原文、不自动重试、不发成功；
   · 9 字段各填一遍 + 日记录不污染推算（真实 GET/PUT/POST 后 periodData 不变）；
   · 已存值重开弹层逐项回显；
   · 四条预警在真实 widget 上有无与文案逐字；
   · 整月日历格子 / 选中日 / 切月不丢已选日期 / 返回按钮 + 系统手势；
   · 删整次对全部碎片逐个 DELETE。
   夹具与 expected 全来自 Node vm 实跑 Web 原函数（period_b_expected.json）。
   跑前 unset 八个代理变量（flutter_tester 本地 WebSocket 被代理劫持）。
*/
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import '_hold_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/ui/hold_to_confirm.dart';
import 'package:love_space/core/sse/sse_client.dart'
    show SseEvent, sseEventsProvider;
import 'package:love_space/features/chat/chat_toast.dart'
    show ChatToastHost, chatToastProvider;
import 'package:love_space/features/personal/personal_controller.dart';
import 'package:love_space/features/period/period_actions.dart';
import 'package:love_space/features/period/period_controller.dart';
import 'package:love_space/features/period/period_engine.dart';
import 'package:love_space/features/period/period_grid.dart';
import 'package:love_space/features/period/period_meta.dart';
import 'package:love_space/features/period/period_page.dart';
import 'package:love_space/features/together/together_page.dart';

const String _fixedToday = '2026-11-14';

Map<String, dynamic> _load(String name) => jsonDecode(
      File('test/fixtures/$name').readAsStringSync(),
    ) as Map<String, dynamic>;

List<PeriodRow> _rows(Object? raw) => (raw as List)
    .map((e) => PeriodRow.fromJson((e as Map).cast<String, dynamic>()))
    .toList();

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
    jsonEncode(data), status,
    headers: {Headers.contentTypeHeader: const ['application/json']});

Map<String, dynamic> _rec({
  required String id,
  required String author,
  required Map<String, dynamic> body,
  Object? deleted,
}) =>
    {
      'id': id,
      'kind': 'period',
      'author': author,
      'body': body,
      'created': 1791195587.0,
      'deleted': deleted,
      'media': <Object>[],
      'likes': <Object>[],
      'comments': <Object>[],
    };

/// 夹具里的 `{id,author,body}` 补成 `/api/records` 的真实形状（含 `kind`）。
/// `parseTogetherRecords` 要求 `kind` 非空，否则整批会被丢掉（8-A 同款）。
List<Map<String, dynamic>> _fixtureRecords(Object? raw) => <Map<String, dynamic>>[
      for (final e in (raw as List))
        _rec(
          id: (e as Map)['id'] as String,
          author: e['author'] as String,
          body: Map<String, dynamic>.from(
              (e['body'] as Map).cast<String, dynamic>()),
        ),
    ];

/// 与页面同源的「空间时区（UTC+8）日历日」。
String _today() => spaceTodayIso(DateTime.now().toUtc());

class _Store {
  _Store({List<Map<String, dynamic>>? records})
      : records = List<Map<String, dynamic>>.from(records ?? <Map<String, dynamic>>[]);

  List<Map<String, dynamic>> records;
  String uid = 'u1';
  int postStatus = 200;
  int putStatus = 200;
  int deleteStatus = 200;
  String postDetail = '服务端拒绝了这次操作';
  int nextId = 1;
  final List<RequestOptions> requests = <RequestOptions>[];
  final List<Map<String, dynamic>> postBodies = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> putBodies = <Map<String, dynamic>>[];
  final List<String> deletedIds = <String>[];
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.store);

  final _Store store;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    store.requests.add(o);
    if (o.method == 'GET' && o.uri.path == '/api/records') {
      return _json(
          store.records.where((r) => r['deleted'] == null).toList());
    }
    if (o.method == 'GET' && o.uri.path == '/api/me') {
      return _json({
        'user': {'id': store.uid, 'name': '我', 'username': store.uid},
      });
    }
    if (o.method == 'POST' && o.uri.path == '/api/records') {
      final data = Map<String, dynamic>.from(o.data as Map);
      store.postBodies.add(data);
      if (store.postStatus >= 400) {
        return _json({'detail': store.postDetail}, store.postStatus);
      }
      store.records.add(_rec(
        id: 'new-${store.nextId++}',
        author: store.uid,
        body: Map<String, dynamic>.from(data['body'] as Map),
      ));
      return _json(<String, Object>{});
    }
    if (o.method == 'PUT' && o.uri.path.startsWith('/api/records/')) {
      final data = Map<String, dynamic>.from(o.data as Map);
      store.putBodies.add(data);
      if (store.putStatus >= 400) {
        return _json({'detail': store.postDetail}, store.putStatus);
      }
      final rid = o.uri.path.split('/').last;
      for (var i = 0; i < store.records.length; i++) {
        if (store.records[i]['id'] == rid) {
          store.records[i]['body'] =
              Map<String, dynamic>.from(data['body'] as Map);
        }
      }
      return _json(<String, Object>{});
    }
    if (o.method == 'DELETE' && o.uri.path.startsWith('/api/records/')) {
      if (store.deleteStatus >= 400) {
        return _json({'detail': store.postDetail}, store.deleteStatus);
      }
      final rid = o.uri.path.split('/').last;
      store.deletedIds.add(rid);
      for (final r in store.records) {
        if (r['id'] == rid) r['deleted'] = 1791195587.0;
      }
      return _json({'ok': true});
    }
    return _json(<Object>[]);
  }
}

Future<ProviderContainer> _setup(_Store s) async {
  final dio = Dio(BaseOptions(
    baseUrl: 'https://test.local',
    validateStatus: api.validateAppStatus,
  ))..httpClientAdapter = _FakeAdapter(s);
  final c = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    personalCurrentUserProvider.overrideWith((ref) => s.uid),
  ]);
  addTearDown(c.dispose);
  await c.read(periodControllerProvider.notifier).load();
  return c;
}

/// widget 用例专用：**不预先 await load()**。
/// testWidgets 跑在 fake-async zone 里，直接在测试体里 await 真实 Dio 请求会挂住
/// （8-A 的既有做法：由页面 initState 的 Future.microtask(bootstrap) 在
/// pumpAndSettle 期间完成首屏拉取）。test() 用例仍用 [_setup]（真实 async zone）。
ProviderContainer _setupWidget(_Store s) {
  final dio = Dio(BaseOptions(
    baseUrl: 'https://test.local',
    validateStatus: api.validateAppStatus,
  ))..httpClientAdapter = _FakeAdapter(s);
  final c = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    personalCurrentUserProvider.overrideWith((ref) => s.uid),
  ]);
  addTearDown(c.dispose);
  return c;
}

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/period',
          routes: [
            GoRoute(
                path: '/hub',
                builder: (_, _) => const TogetherPage(active: false)),
            GoRoute(path: '/period', builder: (_, _) => const PeriodPage()),
          ],
        ),
        builder: (context, child) => Stack(children: [
          child ?? const SizedBox.shrink(),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: SafeArea(child: ChatToastHost()),
            ),
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

/// 把 Web 期望的 write 与真实 Dio 请求逐项对照（`/records` → `/api/records`）。
void _assertWrites(_Store s, List<Object?> expWrites, String reason) {
  final writes = s.requests
      .where((r) => const ['POST', 'PUT', 'DELETE'].contains(r.method))
      .toList();
  expect(writes.length, expWrites.length, reason: '$reason · 写请求条数');
  for (var i = 0; i < expWrites.length; i++) {
    final e = (expWrites[i] as Map).cast<String, dynamic>();
    final w = writes[i];
    final method = e['method'] == 'post'
        ? 'POST'
        : e['method'] == 'put'
            ? 'PUT'
            : 'DELETE';
    expect(w.method, method, reason: '$reason[$i] method');
    expect(w.uri.path, '/api${e['path']}', reason: '$reason[$i] path');
    if (e['data'] != null) {
      expect(w.data, equals(e['data']), reason: '$reason[$i] body');
    }
  }
}

void main() {
  final aCases = _load('period_cases.json');
  final bCases = _load('period_b_cases.json');
  final expected = _load('period_b_expected.json');

  PeriodData dataOf(Map<String, dynamic> c, {String? today}) => periodData(
      _rows(c['records']), today: today ?? c['today'] as String);

  // ── ① 四动作：真实 HTTP 请求与 Web 实跑逐项全等 ───────────────────
  group('验收点② · 四动作真实写路径（Web 实跑对拍）', () {
    final actions = (expected['actions'] as Map).cast<String, dynamic>();
    for (final raw in (bCases['actionCases'] as List)) {
      final c = (raw as Map).cast<String, dynamic>();
      final name = c['name'] as String;
      test('动作 · $name · HTTP method/path/body + 提示全等', () async {
        final s = _Store(records: _fixtureRecords(c['records']));
        final container = await _setup(s);
        final d = dataOf(c);
        final day = c['day'] as String;
        final action = c['action'] as String;
        final plan = action == 'start'
            ? planStart(d, day, clientId: 'uuid-fixed-8b')
            : action == 'end'
                ? planEnd(d, day)
                : planMore(d, day);
        final err = await container
            .read(periodControllerProvider.notifier)
            .executePlan(plan);
        expect(err, isNull, reason: '$name 真成功');
        final e = (actions[name] as Map).cast<String, dynamic>();
        _assertWrites(s, (e['writes'] as List).cast<Object?>(), name);
        // 提示文案按 Web 逐字（no-write 分支也用 plan.message）。
        final toasts = (e['toasts'] as List).cast<String>();
        if (toasts.isNotEmpty) expect(plan.message, toasts.single);
        expect(plan.refresh, e['refreshed']);
      });
    }
  });

  // ── ② 9 字段各填一遍 + 不污染推算（真实 GET/PUT/POST） ────────────
  group('验收点③ · 9 字段保存 / 回显 / 不污染推算', () {
    final dayLogs = (expected['dayLogs'] as Map).cast<String, dynamic>();
    for (final raw in (bCases['dayLogCases'] as List)) {
      final c = (raw as Map).cast<String, dynamic>();
      final name = c['name'] as String;
      test('日记录 · $name · 真实 HTTP 与 Web 实跑全等', () async {
        final s = _Store(
            records: _fixtureRecords(c['records']));
        final container = await _setup(s);
        final plan = planSaveDay(
          records: container.read(periodControllerProvider.notifier).periodRows,
          day: c['day'] as String,
          patch: (c['patch'] as Map).cast<String, dynamic>(),
          clientId: 'uuid-fixed-8b',
        );
        final err = await container
            .read(periodControllerProvider.notifier)
            .executePlan(plan);
        expect(err, isNull);
        final e = (dayLogs[name] as Map).cast<String, dynamic>();
        _assertWrites(s, (e['writes'] as List).cast<Object?>(), name);
      });
    }

    test('9 字段各填一遍保存后：body 无 start、periodData 不变、逐键回显一致',
        () async {
      const day = '2026-11-11';
      final s = _Store(records: <Map<String, dynamic>>[
        _rec(
            id: 'ep1',
            author: 'u1',
            body: <String, dynamic>{
              'start': '2026-11-10',
              'length': 6,
              'cycle': 31,
            }),
      ]);
      final container = await _setup(s);
      final ctrl = container.read(periodControllerProvider.notifier);
      final before = periodData(ctrl.periodRows, today: _fixedToday);
      final patches = <Map<String, dynamic>>[
        {'flow': 4},
        {'color': 3},
        {'pain': 2},
        {'sex': [
          {'t': '21:30', 'w': [2, 5]}
        ]},
        {'symptoms': ['腰酸', '腹痛']},
        {'mood': 7},
        {'weight': 52.5},
        {'discharge': 1},
        {'temp': 36.8},
        {'content': '今天有点累'},
      ];
      for (var i = 0; i < patches.length; i++) {
        final plan = planSaveDay(
            records: ctrl.periodRows,
            day: day,
            patch: patches[i],
            clientId: 'cid-8b-$i');
        expect(await ctrl.executePlan(plan), isNull);
        final body = periodDayLogOf(ctrl.periodRows, day);
        expect(body.containsKey('start'), isFalse,
            reason: '第 $i 次保存后日记录永不带 start');
        expect(body.containsKey('end'), isFalse);
      }
      final after = periodData(ctrl.periodRows, today: _fixedToday);
      for (final label in const ['cycle', 'length', 'nextStart']) {
        expect(
            label == 'cycle'
                ? after.cycle
                : label == 'length'
                    ? after.length
                    : after.nextStart,
            label == 'cycle'
                ? before.cycle
                : label == 'length'
                    ? before.length
                    : before.nextStart,
            reason: '日记录不参与推算：$label');
      }
      expect(after.episodes.length, before.episodes.length);
      expect(after.items.length, 1);
      expect(after.inWindow, before.inWindow);
      expect(after.dayOfPeriod, before.dayOfPeriod);

      // 逐键文字化回显（已存值重开弹层时显示的就是这个文本）。
      final body = periodDayLogOf(ctrl.periodRows, day);
      for (final f in periodLogFields) {
        final value = periodValueText(f[0], body);
        expect(value.isNotEmpty, isTrue, reason: '${f[0]} 应有回显值');
        expect(body.containsKey(f[0]), isTrue);
      }
      expect(periodValueText('flow', body), '大量'); // flow=4
      expect(periodValueText('color', body), '深红色'); // color=3
      expect(periodValueText('pain', body), '轻微痛'); // pain=2
      expect(periodValueText('mood', body), '😲 惊喜'); // mood=7
      expect(periodValueText('symptoms', body), '腰酸 · 腹痛');
      expect(periodValueText('weight', body), '52.5 公斤');
      expect(periodValueText('temp', body), '36.8 ℃');
      expect(periodValueText('discharge', body), '干燥');
    });
  });

  // ── ③ 7-C 错误通道 ────────────────────────────────────────────────
  group('7-C 错误通道（executePlan）', () {
    test('4xx 原文透传、不自动重试、无写后刷新', () async {
      final s = _Store();
      s.postStatus = 422;
      s.postDetail = '周期需在 15–60 天、经期需在 1–15 天之间';
      final container = await _setup(s);
      final d = dataOf(<String, dynamic>{
        'records': <Object>[],
        'today': _fixedToday,
      });
      final plan = planStart(d, _fixedToday, clientId: 'cid-fixed');
      final err = await container
          .read(periodControllerProvider.notifier)
          .executePlan(plan);
      expect(err, s.postDetail);
      expect(err, isNot(api.genericErrorText));
      final posts = s.requests.where((r) => r.method == 'POST').toList();
      expect(posts.length, 1, reason: '不自动重试');
      // 失败复用同一 client_id（表单 State initState 生成一次）。
      final err2 = await container
          .read(periodControllerProvider.notifier)
          .executePlan(plan);
      expect(err2, s.postDetail);
      expect(s.postBodies.length, 2);
      expect(s.postBodies.map((b) => b['client_id']).toSet().length, 1);
    });

    test('删整次：对该 episode 全部碎片逐个 DELETE，全成功后才刷新', () async {
      final fm = ((aCases['cases'] as Map)['fragmentMerge'] as Map)
          .cast<String, dynamic>();
      final s = _Store(
          records: _fixtureRecords(fm['records']));
      final container = await _setup(s);
      final d = dataOf(((aCases['cases'] as Map)['fragmentMerge'] as Map)
          .cast<String, dynamic>());
      final ids = deleteEpisodeIds(d.episodes.first);
      expect(ids, ['f1', 'f2', 'f3']);
      final err = await container
          .read(periodControllerProvider.notifier)
          .deleteEpisode(ids);
      expect(err, isNull);
      expect(s.deletedIds, ['f1', 'f2', 'f3']);
      expect(container.read(periodControllerProvider).records.length, 2,
          reason: '刷新后只剩第二段（f4/f5）');
    });
  });

  // ── ④ widget：日历 / 选中日 / 切月 / 预警 / 返回 ─────────────────
  group('验收点④⑤ · 主页 widget', () {
    testWidgets('整月日历逐日格子就位；点一天切到那天；切月不丢已选日期',
        (tester) async {
      final s = _Store(records: <Map<String, dynamic>>[
        _rec(
            id: 'ep1',
            author: 'u1',
            body: <String, dynamic>{
              'start': dayStr(dayNum(_today()) - 2),
              'length': 6,
              'cycle': 31,
            }),
        _rec(
            id: 'day1',
            author: 'u2',
            body: <String, dynamic>{
              'date': _today(),
              'content': '第一天有点累',
            }),
      ]);
      final c = _setupWidget(s);
      await _pump(tester, c);
      final today = _today();
      expect(find.byKey(Key('period-day-$today')), findsOneWidget,
          reason: '整月网格必须渲染今天的格子');
      expect(find.text('第一天有点累'), findsWidgets,
          reason: '当天记录卡回显日记录');

      // 点本月 5 号 → 选中态切到那天（log 卡标题随之变化）。
      final fifth = '${today.substring(0, 8)}05';
      final fifthFinder = find.byKey(Key('period-day-$fifth'));
      await tester.ensureVisible(fifthFinder);
      await tester.tap(fifthFinder);
      await tester.pumpAndSettle();
      expect(find.byKey(Key('period-day-$fifth')), findsOneWidget);

      // 翻到下个月：选中日按 shiftMonth 夹到目标月，状态不丢（不重置回今天）。
      final next = shiftMonth(fifth, 1);
      await tester.tap(find.byTooltip('下个月'));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('period-day-$next')), findsOneWidget,
          reason: '选中日期状态保留并跟着翻月（Web shiftMonth 口径）');
      // 翻回来：仍回到原来选中的 5 号。
      await tester.tap(find.byTooltip('上个月'));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('period-day-$fifth')), findsOneWidget,
          reason: '切月往返后已选日期不丢');
      await _flush(tester);
    });

    testWidgets('预警块：short 夹具触发偏短规则，文案逐字、含尾注',
        (tester) async {
      final wc = (bCases['warningCases'] as List)
          .map((e) => (e as Map).cast<String, dynamic>())
          .firstWhere((e) => e['name'] == 'short');
      final s = _Store(
          records: _fixtureRecords(wc['records']));
      final c = _setupWidget(s);
      await _pump(tester, c);
      final warns = (expected['warnings'] as Map)['short'] as List;
      expect(find.text('有几点需要留意'), findsOneWidget);
      for (final w in warns) {
        expect(find.text(w as String), findsOneWidget,
            reason: '预警文案逐字对齐 Web');
      }
      expect(find.text('按记录推算的提示，身体不舒服还是去看医生。'),
          findsOneWidget);
      await _flush(tester);
    });

    testWidgets('normal 夹具无预警：整块不出现（不占地方）',
        (tester) async {
      final wc = (bCases['warningCases'] as List)
          .map((e) => (e as Map).cast<String, dynamic>())
          .firstWhere((e) => e['name'] == 'normal');
      final s = _Store(
          records: _fixtureRecords(wc['records']));
      final c = _setupWidget(s);
      await _pump(tester, c);
      expect(find.text('有几点需要留意'), findsNothing);
      // 🔴 段 C 已落地：数据分析入口是活卡（非死卡），逐字对齐 period.js:517。
      expect(find.text('数据分析'), findsOneWidget);
      expect(find.text('周期、流量、痛经、体温的变化'), findsOneWidget);
      await _flush(tester);
    });

    testWidgets('返回按钮 + 系统手势可回 hub（8-B 页内扩展不改返回路径）',
        (tester) async {
      final s = _Store();
      final c = _setupWidget(s);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp.router(
          routerConfig: GoRouter(
            initialLocation: '/hub',
            routes: [
              GoRoute(
                  path: '/hub',
                  builder: (_, _) => const TogetherPage(active: false)),
              GoRoute(path: '/period', builder: (_, _) => const PeriodPage()),
            ],
          ),
          builder: (context, child) => Stack(children: [
            child ?? const SizedBox.shrink(),
            const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(child: SafeArea(child: ChatToastHost()))),
          ]),
        ),
      ));
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpAndSettle();
      await tester.tap(find.text('生理期'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('上个月'), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byTooltip('上个月'), findsNothing);
      expect(find.text('关于我们，还有好多好多'), findsOneWidget);
      await _flush(tester);
    });
  });

  // ── ⑤ 四动作 widget 全程各走一遍（含首日 DELETE / 中途改 length） ──
  group('验收点② · 四动作 widget 全程', () {
    Map<String, dynamic> episodeBody(String start, int length) =>
        <String, dynamic>{'start': start, 'length': length, 'cycle': 28};

    testWidgets('月经来了（新）：POST {start,length:max(3,d.length),cycle}',
        (tester) async {
      final s = _Store();
      final c = _setupWidget(s);
      await _pump(tester, c);
      await tester.ensureVisible(find.text('月经来了'));
      await tester.tap(find.text('月经来了'));
      await tester.pumpAndSettle();
      expect(s.postBodies.length, 1);
      final body = s.postBodies.single['body'] as Map;
      expect(body['start'], _today());
      expect(body['length'], 5, reason: '无记录 d.length=5，max(3,5)=5');
      expect(body['cycle'], 28);
      expect(body.containsKey('end'), isFalse);
      expect(c.read(chatToastProvider)?.text, '已记下这次经期');
      await _flush(tester);
    });

    testWidgets('月经走了（中途）：PUT 改 length，文案逐字',
        (tester) async {
      final s = _Store(records: <Map<String, dynamic>>[
        _rec(
            id: 'ep1',
            author: 'u1',
            body: episodeBody(dayStr(dayNum(_today()) - 2), 6)),
      ]);
      final c = _setupWidget(s);
      await _pump(tester, c);
      await tester.ensureVisible(find.text('月经走了'));
      await tester.tap(find.text('月经走了'));
      await tester.pumpAndSettle();
      expect(s.putBodies.length, 1);
      final body = s.putBodies.single['body'] as Map;
      expect(body['length'], 2, reason: 'n - s = 2');
      expect(body.containsKey('end'), isFalse);
      expect(c.read(chatToastProvider)?.text, '这次经期到昨天为止');
      await _flush(tester);
    });

    testWidgets('月经走了（首日）：DELETE 那条记录，文案逐字',
        (tester) async {
      final s = _Store(records: <Map<String, dynamic>>[
        _rec(
            id: 'ep1',
            author: 'u1',
            body: episodeBody(_today(), 5)),
      ]);
      final c = _setupWidget(s);
      await _pump(tester, c);
      await tester.ensureVisible(find.text('月经走了'));
      await tester.tap(find.text('月经走了'));
      await tester.pumpAndSettle();
      expect(s.deletedIds, ['ep1'], reason: '首日 s===n → DELETE');
      expect(s.putBodies, isEmpty);
      expect(c.read(chatToastProvider)?.text, '已撤掉这次经期');
      await _flush(tester);
    });

    testWidgets('月经又来了：PUT 把 length 往后推一天（幂等口径）',
        (tester) async {
      final s = _Store(records: <Map<String, dynamic>>[
        _rec(
            id: 'ep1',
            author: 'u1',
            body: episodeBody(dayStr(dayNum(_today()) - 2), 3)),
      ]);
      final c = _setupWidget(s);
      await _pump(tester, c);
      // 今天正好是这段的第 3 天（窗口内）。
      expect(find.text('月经又来了'), findsOneWidget);
      await tester.ensureVisible(find.text('月经又来了'));
      await tester.tap(find.text('月经又来了'));
      await tester.pumpAndSettle();
      expect(s.putBodies.length, 1);
      final body = s.putBodies.single['body'] as Map;
      expect(body['length'], 4,
          reason: 'want=max(len=3, n-s+2=4)=4，把经期往后推一天');
      expect(c.read(chatToastProvider)?.text, '这次经期又多算一天');
      await _flush(tester);
    });

    testWidgets('删整次：历史卡「删除这次」→ 全部碎片 DELETE',
        (tester) async {
      final fm = ((aCases['cases'] as Map)['fragmentMerge'] as Map)
          .cast<String, dynamic>();
      final s = _Store(
          records: _fixtureRecords(fm['records']));
      final c = _setupWidget(s);
      await _pump(tester, c);
      final menus = find.byTooltip('更多操作');
      expect(menus, findsNWidgets(2), reason: '一次月经一张卡 → 2 张历史卡');
      // 历史卡按 episodes 反转：最后一张是 09-01 那次（f1/f2/f3 三段）。
      await tester.ensureVisible(menus.last);
      await tester.tap(menus.last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除这次'));
      await tester.pumpAndSettle();
      expect(find.text('删掉这次经期？'), findsOneWidget);
      await holdConfirm(tester, find.byType(HoldToConfirmButton));
      await tester.pumpAndSettle();
      expect(s.deletedIds, ['f1', 'f2', 'f3'],
          reason: 'period-del-episode 对整次全部碎片逐个 DELETE');
      await _flush(tester);
    });
  });

  // ── ⑥ 已存值重开弹层逐项回显 ────────────────────────────────────
  group('验收点③ · 重开弹层逐项回显', () {
    testWidgets('9 字段已存值：主页行值 + 弹层选中态原样回显',
        (tester) async {
      final full = (bCases['valueTextCases'] as List)
          .map((e) => (e as Map).cast<String, dynamic>())
          .firstWhere((e) => e['name'] == 'full');
      final body = Map<String, dynamic>.from(
          (full['body'] as Map).cast<String, dynamic>());
      body['date'] = _today();
      final s = _Store(records: <Map<String, dynamic>>[
        _rec(id: 'day1', author: 'u2', body: body),
      ]);
      final c = _setupWidget(s);
      await _pump(tester, c);

      // 主页 9 行 + 日记行的值文字化（periodValueText 逐键）。
      for (final f in periodLogFields) {
        final text = periodValueText(f[0], body);
        if (text.isNotEmpty) {
          expect(find.text(text), findsWidgets,
              reason: '${f[0]} 主页回显 $text');
        }
      }

      // 单选弹层：flow=3 / mood=9 的选中态（ps-on-N）。
      await tester.ensureVisible(find.text('流量'));
      await tester.tap(find.text('流量'));
      await tester.pumpAndSettle();
      expect(find.text('流量'), findsWidgets);
      expect(find.byKey(const Key('ps-on-3')), findsOneWidget,
          reason: 'flow 已存 3，重开弹层必须选中');
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('心情'));
      await tester.tap(find.text('心情'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ps-on-9')), findsOneWidget,
          reason: 'mood 已存 9（🥰 心动）');
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();

      // 症状多选：腰酸 / 腹痛 选中，'没有症状' 互斥未选。
      await tester.ensureVisible(find.text('症状'));
      await tester.tap(find.text('症状'));
      await tester.pumpAndSettle();
      final waist = tester.widget<FilterChip>(
          find.widgetWithText(FilterChip, '腰酸'));
      final belly = tester.widget<FilterChip>(
          find.widgetWithText(FilterChip, '腹痛'));
      expect(waist.selected, isTrue);
      expect(belly.selected, isTrue);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();

      // 体重数字弹层：52.5 原样显示在数字区。
      await tester.ensureVisible(find.text('体重'));
      await tester.tap(find.text('体重'));
      await tester.pumpAndSettle();
      expect(find.text('52.5'), findsWidgets);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();

      // 爱爱弹层：2 次 tab 回显（老数据/新数据统一形状）。
      await tester.ensureVisible(find.text('爱爱'));
      await tester.tap(find.text('爱爱'));
      await tester.pumpAndSettle();
      expect(find.text('第 2 次'), findsOneWidget);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      await _flush(tester);
    });
  });
}
