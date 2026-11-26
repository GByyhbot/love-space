/* 条目 8 · 段 8-A 自测夹具（2.2.1/VC221 · 生理期地基 + 入口 + 读写 + 最小页面）。
   覆盖主人 0–7 条的验收点 ①–④ 与 D6 权限，复用 7-C 返修后的错误通道契约：
   · 拉取 `GET /api/records?kind=period&limit=1000`（**不带 media_type / exclude /
     author / trash**），走 `main.py:1165/:1169-1171` 的 only_period 短路；
   · 4xx 在 `api.validateAppStatus` 下是「成功 Response 不抛异常」，夹具 Dio
     与生产**共用同一个 validateStatus**（7-C 假通过根因，绝不退回 Dio 默认）；
   · 「恢复接已有通用 restore」= `PersonalController.restore`，作者不符 404
     「记录不存在」原文透传、不静默、不发成功通知；恢复后 body 原样；
   · client_id 由表单 State 的 initState 生成一次，失败重试复用同值；
   · 编辑回填铁律（PUT 全量 body 保留原键）、绝不虚构 end 键、不按 author 过滤；
   · 状态摘要来自引擎；两入口 push('/period')；返回按钮 + 系统手势可回。
   测试坑规避（沿用 7-A/B/C）：跑前 unset 八个代理变量；纯 test() 不调
   bootstrap 且 override 固定 uid；widget 用例 pumpAndSettle + _flush(3s) 冲 toast Timer；
   find.textContaining 可能命中多处，用 evaluate().length 或精确 find.text。 */
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
import 'package:love_space/core/together/together_data.dart';
import 'package:love_space/features/chat/chat_toast.dart' show ChatToastHost;
import 'package:love_space/features/personal/personal_controller.dart';
import 'package:love_space/features/period/period_controller.dart';
import 'package:love_space/features/period/period_engine.dart';
import 'package:love_space/features/period/period_page.dart';
import 'package:love_space/features/together/together_page.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final FutureOr<ResponseBody> Function(RequestOptions options, int callIndex)
      handler;
  final List<RequestOptions> requests = [];
  int calls = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return await handler(options, calls++);
  }
}

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

/// 可变后端：模拟分库记录（含双方作者）、软删、恢复、4xx 原文。
class _Store {
  _Store({List<Map<String, dynamic>>? records})
      : records = List<Map<String, dynamic>>.from(records ?? _defaultRecords());

  List<Map<String, dynamic>> records;
  String uid = 'u1';
  int postStatus = 200;
  String postDetail = '周期需在 15–60 天、经期需在 1–15 天之间';
  int putStatus = 200;
  String putDetail = '已发布内容不能改变可见范围，请另建记录';
  int deleteStatus = 200;
  String deleteDetail = '删除失败：服务端拒绝了这次操作';
  int restoreStatus = 200;
  String restoreDetail = '记录不存在';
  int postCalls = 0;
  final List<Map<String, dynamic>> postBodies = [];
  final List<Map<String, dynamic>> putBodies = [];
}

/// 与 PeriodPage 同源：空间时区（默认 Asia/Shanghai）日历日，不是设备本机时区。
String _today() => spaceTodayIso(DateTime.now().toUtc());

Map<String, dynamic> _defaultEpisodeBody() => {
      'start': dayStr(dayNum(_today()) - 2),
      'length': 6,
      'cycle': 31, // ≠28：证明无 gap 时前端回落 body.cycle（C4）
      'content': '这次来得早',
      'flow': 3, // 编辑回填铁律：原键必须保留
      'symptoms': <String>['腰酸'],
    };

Map<String, dynamic> _defaultDayBody() => {
      'date': _today(),
      'content': '第一天有点累',
    };

List<Map<String, dynamic>> _defaultRecords() => [
      _rec(id: 'ep1', author: 'u1', body: _defaultEpisodeBody()),
      _rec(id: 'day1', author: 'u2', body: _defaultDayBody()),
    ];

_FakeAdapter _adapterFor(_Store s) => _FakeAdapter((o, i) async {
      if (o.method == 'GET' && o.uri.path == '/api/records') {
        final q = o.uri.queryParameters;
        final isTrash = q['trash'] == 'true' || q['trash'] == '1';
        if (isTrash) {
          // 服务端 trash 分支强制 author=自己 AND deleted IS NOT NULL
          return _json(s.records
              .where((r) => r['author'] == s.uid && r['deleted'] != null)
              .toList());
        }
        // 分库合并/短路：返回全部未删记录，不按 author 过滤（D6）
        return _json(s.records.where((r) => r['deleted'] == null).toList());
      }
      if (o.method == 'GET' && o.uri.path == '/api/me') {
        return _json({
          'user': {'id': s.uid, 'name': '我', 'username': s.uid},
        });
      }
      if (o.method == 'POST' && o.uri.path == '/api/records') {
        s.postCalls++;
        final data = Map<String, dynamic>.from(o.data as Map);
        s.postBodies.add(data);
        if (s.postStatus >= 400) {
          return _json({'detail': s.postDetail}, s.postStatus);
        }
        final body = Map<String, dynamic>.from(data['body'] as Map);
        s.records.add(_rec(
            id: 'new-${s.postCalls}',
            author: s.uid,
            body: body));
        return _json(<String, Object>{});
      }
      if (o.method == 'PUT' && o.uri.path.startsWith('/api/records/')) {
        final data = Map<String, dynamic>.from(o.data as Map);
        s.putBodies.add(data);
        if (s.putStatus >= 400) {
          return _json({'detail': s.putDetail}, s.putStatus);
        }
        // 🔴 模拟 clean_body 不 merge：服务端只保存客户端传来的全量 body。
        final rid = o.uri.path.split('/').last;
        for (var k = 0; k < s.records.length; k++) {
          if (s.records[k]['id'] == rid) {
            s.records[k]['body'] =
                Map<String, dynamic>.from(data['body'] as Map);
          }
        }
        return _json(<String, Object>{});
      }
      if (o.method == 'DELETE' && o.uri.path.startsWith('/api/records/')) {
        if (s.deleteStatus >= 400) {
          return _json({'detail': s.deleteDetail}, s.deleteStatus);
        }
        final rid = o.uri.path.split('/').last;
        for (final r in s.records) {
          if (r['id'] == rid) r['deleted'] = 1791195587.0;
        }
        return _json({'ok': true});
      }
      if (o.method == 'POST' && o.uri.path.endsWith('/restore')) {
        if (s.restoreStatus >= 400) {
          return _json({'detail': s.restoreDetail}, s.restoreStatus);
        }
        // 服务端只清 deleted，不回写任何 body 字段（period.py:226-229）。
        final rid = o.uri.path.split('/')[3];
        for (final r in s.records) {
          if (r['id'] == rid) r['deleted'] = null;
        }
        return _json({'ok': true});
      }
      return _json(<Object>[]);
    });

Future<ProviderContainer> _setup(_Store s, {String? uid}) async {
  // 🔴 与生产 buildDio 共用 api.validateAppStatus：4xx 作为成功 Response 返回，
  // 不抛 DioException（7-C 返修根因，夹具不得用 Dio 默认 <300 假通过）。
  final dio = Dio(BaseOptions(
    baseUrl: 'https://test.local',
    validateStatus: api.validateAppStatus,
  ))..httpClientAdapter = _adapterFor(s);
  final container = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    personalCurrentUserProvider.overrideWith((ref) => uid ?? s.uid),
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
                path: '/hub',
                builder: (_, _) => const TogetherPage(active: false)),
            GoRoute(
                path: '/period', builder: (_, _) => const PeriodPage()),
          ],
        ),
        // 与 main.dart 同款全局顶部通知宿主（结果类提示统一走 ChatToastHost）
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

Future<void> _pump(WidgetTester tester, ProviderContainer container,
    {String initial = '/period'}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(_app(container, initial: initial));
  await tester.pumpAndSettle();
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

void main() {
  // ── 数据层：拉取方式 / 两种形状 / 幂等 / 回填铁律 / 错误通道 ──────
  group('数据层（通用 /api/records）', () {
    test('拉取：kind=period&limit=1000，绝不带 media_type/exclude/author/trash',
        () async {
      final s = _Store();
      final adapter = _adapterFor(s);
      final dio = Dio(BaseOptions(
        baseUrl: 'https://test.local',
        validateStatus: api.validateAppStatus,
      ))..httpClientAdapter = adapter;
      final c = ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
        personalCurrentUserProvider.overrideWith((ref) => s.uid),
      ]);
      addTearDown(c.dispose);
      await c.read(periodControllerProvider.notifier).load();
      final get = adapter.requests
          .firstWhere((r) => r.method == 'GET' && r.uri.path == '/api/records');
      final q = get.uri.queryParameters;
      expect(q['kind'], 'period');
      expect(q['limit'], '1000');
      expect(q.containsKey('media_type'), isFalse,
          reason: 'merge_period 会因 media_type 非空整体置 False');
      expect(q.containsKey('exclude'), isFalse,
          reason: 'exclude 含 period 会让分库记录完全不返回');
      expect(q.containsKey('author'), isFalse,
          reason: 'D6：双方共享，不按作者过滤');
      expect(q.containsKey('trash'), isFalse,
          reason: '本页只显示未删记录，回收站另走 PersonalController.loadTrash');
      expect(c.read(periodControllerProvider).records.length, 2);
    });

    test('双账号：对象端也拉到同一条周期与她记的日记录（不按 author 过滤）',
        () async {
      final s = _Store();
      final mine = await _setup(s, uid: 'u1');
      await mine.read(periodControllerProvider.notifier).load();
      // 同一份后端数据，换到对象账号：不按 author 过滤，看到同一条周期。
      final theirs = await _setup(s, uid: 'u2');
      await theirs.read(periodControllerProvider.notifier).load();
      for (final c in [mine, theirs]) {
        final rs = c.read(periodControllerProvider).records;
        expect(rs.length, 2);
        expect(rs.map((r) => r.author).toSet(), {'u1', 'u2'});
        expect(rs.any((r) => r.id == 'ep1' && r.body['cycle'] == 31), isTrue);
        expect(
            rs.any((r) => r.id == 'day1' && r.body['content'] == '第一天有点累'),
            isTrue);
      }
    });

    test('两种形状分别解析：日记录不参与推算、绝不虚构 end 键', () {
      expect(periodShapeOf(_defaultEpisodeBody()), PeriodShape.episode);
      expect(periodShapeOf(_defaultDayBody()), PeriodShape.day);
      expect(periodShapeOf(const {}), PeriodShape.unknown);
      final ep = TogetherRecord.fromJson(
          _rec(id: 'ep1', author: 'u1', body: _defaultEpisodeBody()));
      final dy = TogetherRecord.fromJson(
          _rec(id: 'day1', author: 'u2', body: _defaultDayBody()));
      expect(isPeriodEpisode(ep), isTrue);
      expect(isPeriodDay(ep), isFalse);
      expect(isPeriodDay(dy), isTrue);
      expect(ep.body.containsKey('end'), isFalse);
      expect(dy.body.containsKey('start'), isFalse);
      expect(dy.body.containsKey('end'), isFalse);
      // 日记录行喂进引擎：没有任何经期行 → cycle 回落 28、length 5。
      final d = periodData(
          [PeriodRow(id: 'day1', author: 'u2', body: dy.body)],
          today: _today());
      expect(d.items, isEmpty);
      expect(d.cycle, 28);
      expect(d.length, 5);
    });


    test('新建日记录：body 有 date、无 start、无 end', () async {
      final s = _Store();
      final adapter = _adapterFor(s);
      final dio = Dio(BaseOptions(
        baseUrl: 'https://test.local',
        validateStatus: api.validateAppStatus,
      ))..httpClientAdapter = adapter;
      final c = ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
        personalCurrentUserProvider.overrideWith((ref) => s.uid),
      ]);
      addTearDown(c.dispose);
      final err = await c.read(periodControllerProvider.notifier).addDay(
          date: '2026-11-11',
          content: '第一天有点累',
          clientId: 'fl-day-cid');
      expect(err, isNull);
      final body = s.postBodies.single['body'] as Map;
      expect(body['date'], '2026-11-11');
      expect(body.containsKey('start'), isFalse,
          reason: 'period.js:66 日记录强制删 start');
      expect(body.containsKey('end'), isFalse);
      expect(body['content'], '第一天有点累');
    });

    test('编辑回填铁律：PUT 全量 body 保留 flow/symptoms 等原键 + 只盖改动键',
        () async {
      final s = _Store();
      final adapter = _adapterFor(s);
      final dio = Dio(BaseOptions(
        baseUrl: 'https://test.local',
        validateStatus: api.validateAppStatus,
      ))..httpClientAdapter = adapter;
      final c = ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
        personalCurrentUserProvider.overrideWith((ref) => s.uid),
      ]);
      addTearDown(c.dispose);
      final ctrl = c.read(periodControllerProvider.notifier);
      await ctrl.load();
      final original = c
          .read(periodControllerProvider)
          .records
          .firstWhere((r) => r.id == 'ep1');
      final err = await ctrl.edit(original, {
        'start': '2026-11-10',
        'length': 5,
        'cycle': 30,
        'content': '改过的文案',
      });
      expect(err, isNull);
      final data = s.putBodies.single;
      expect(data['kind'], 'period');
      final body = data['body'] as Map;
      expect(body['flow'], 3, reason: '原 body 的 flow 必须逐键带回');
      expect(body['symptoms'], ['腰酸']);
      expect(body['start'], '2026-11-10');
      expect(body['length'], 5);
      expect(body['cycle'], 30);
      expect(body['content'], '改过的文案');
      expect(body.containsKey('end'), isFalse);
    });

    test('错误通道：4xx 原文透传、不自动重试、不发成功（返回非 null）',
        () async {
      final s = _Store();
      s.putStatus = 422;
      final c = await _setup(s);
      final ctrl = c.read(periodControllerProvider.notifier);
      await ctrl.load();
      final rec = c
          .read(periodControllerProvider)
          .records
          .firstWhere((r) => r.id == 'ep1');
      final err = await ctrl.edit(rec, {'content': 'x'});
      expect(err, s.putDetail);
      expect(err, isNot(api.genericErrorText),
          reason: '服务端 detail 原文，不能用兜底文案冒充');
      s.deleteStatus = 403;
      expect(await ctrl.delete('day1'), s.deleteDetail);
    });

    test('删除软删：DELETE 通用端点，成功后本地移除、列表不含已删记录',
        () async {
      final s = _Store();
      final c = await _setup(s);
      final ctrl = c.read(periodControllerProvider.notifier);
      await ctrl.load();
      expect(c.read(periodControllerProvider).records.length, 2);
      expect(await ctrl.delete('ep1'), isNull);
      // 重拉后服务端已按 deleted IS NULL 过滤，不返回该条。
      expect(c.read(periodControllerProvider).records.length, 1);
      expect(s.records.firstWhere((r) => r['id'] == 'ep1')['deleted'],
          isNotNull);
    });
  });

  // ── 恢复：接已有通用 restore（personal_controller.dart:584-602）──────
  group('恢复接已有通用 restore（main.py:1443-1451 / :1270-1275）', () {
    test('对方恢复我的记录 → 404「记录不存在」原文透传，不静默、不发成功通知',
        () async {
      final s = _Store();
      final adapter = _adapterFor(s);
      final dio = Dio(BaseOptions(
        baseUrl: 'https://test.local',
        validateStatus: api.validateAppStatus,
      ))..httpClientAdapter = adapter;
      final c = ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
        personalCurrentUserProvider.overrideWith((ref) => s.uid),
      ]);
      addTearDown(c.dispose);
      // 我先软删一条（DELETE 零作者校验），换到对方账号尝试恢复。
      await c.read(periodControllerProvider.notifier).load();
      await c.read(periodControllerProvider.notifier).delete('ep1');
      s.restoreStatus = 404;
      s.restoreDetail = '记录不存在';
      final c2 = ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
        personalCurrentUserProvider.overrideWith((ref) => 'u2'),
      ]);
      addTearDown(c2.dispose);
      final err = await c2
          .read(personalControllerProvider.notifier)
          .restore('ep1', kind: 'period');
      expect(err, '记录不存在', reason: '服务端 404 detail 原文，不得吞');
      final restores = adapter.requests
          .where((r) => r.method == 'POST' && r.uri.path.endsWith('/restore'))
          .toList();
      expect(restores.length, 1, reason: '不自动重试');
      expect(s.records.firstWhere((r) => r['id'] == 'ep1')['deleted'],
          isNotNull, reason: '失败不误清 deleted');
      // 页面层只按 err 发 error tone，绝不发 success（由 widget 用例覆盖）。
    });

    test('本人恢复 → 200，body 原样（服务端只清 deleted，不回写任何字段）',
        () async {
      final s = _Store();
      final c = await _setup(s);
      final before = Map<String, dynamic>.from(
          s.records.firstWhere((r) => r['id'] == 'ep1')['body'] as Map);
      await c.read(periodControllerProvider.notifier).delete('ep1');
      expect(s.records.firstWhere((r) => r['id'] == 'ep1')['deleted'],
          isNotNull);
      final err = await c
          .read(personalControllerProvider.notifier)
          .restore('ep1', kind: 'period');
      expect(err, isNull);
      final after = s.records.firstWhere((r) => r['id'] == 'ep1');
      expect(after['deleted'], isNull);
      expect(after['body'], before, reason: '恢复后数据原样');
      expect((after['body'] as Map).containsKey('end'), isFalse);
    });
  });

  // ── 页面：8-B 主页 UI / 两入口 / 返回 / 双呈现 / D6 ──────────────
  // 🔴 段 8-B 起主页换成本段 UI（整月日历 + hero + 9 字段 + 四动作 +
  //    预警 + 历史卡），8-A 的「B 段内容一律不做」断言已按新定案更新；
  //    数据层 / 恢复 / 错误通道用例保持不变。
  group('页面（8-B 主页 UI）', () {
    testWidgets('状态摘要全部来自引擎：阶段 / 周期第几天 / 下次预测 / 参考值',
        (tester) async {
      final s = _Store();
      final c = await _setup(s);
      await _pump(tester, c);
      final startIso = dayStr(dayNum(_today()) - 2);
      final expectedNext = dayStr(dayNum(startIso) + 31);
      final nextM = int.parse(expectedNext.substring(5, 7));
      final nextD = int.parse(expectedNext.substring(8, 10));
      expect(find.text('周期第 3 天'), findsWidgets,
          reason: 'dayInCycle 来自引擎（8-B hero 环形卡）');
      expect(find.textContaining('$nextM 月 $nextD 日（参考值）'), findsOneWidget,
          reason: '无有效 gap → estimated=true；下次预计来自引擎');
      expect(find.text('平均周期'), findsOneWidget);
      expect(find.text('平均经期'), findsOneWidget);
      expect(find.text('记录天数'), findsOneWidget);
      expect(find.textContaining('受孕概率'), findsOneWidget,
          reason: '8-B 受孕概率三档（不给百分比）');
      expect(find.text('按日历推算，仅供参考，不能作为避孕依据。'), findsOneWidget,
          reason: '免责原文逐字、带句号');
      // 2.8.7：Hero 卡内也放了「月经走了」，文案不再唯一 → 按 Key 定位日志卡按钮
      expect(find.byKey(const Key('period-log-end')), findsOneWidget,
          reason: '今天在经期窗口内 → 四动作走了/又来了');
      expect(find.text('月经又来了'), findsOneWidget);
      expect(find.byTooltip('上个月'), findsOneWidget,
          reason: '8-B 整月日历月份栏');
      // 🔴 段 C 已落地：数据分析入口是活卡（非死卡），逐字对齐 period.js:517。
      expect(find.text('数据分析'), findsOneWidget);
      expect(find.text('周期、流量、痛经、体温的变化'), findsOneWidget);
      await _flush(tester);
    });

    testWidgets('两入口：hub 🌸宽卡 push /period；返回按钮 + 系统手势可回',
        (tester) async {
      final s = _Store();
      final c = await _setup(s);
      await _pump(tester, c, initial: '/hub');
      expect(find.text('生理期'), findsOneWidget);
      expect(find.text('记下周期，把照顾提前一点'), findsOneWidget,
          reason: '宽卡文案逐字对齐 Web app.js:1229');
      expect(find.text('关于我们，还有好多好多'), findsOneWidget);

      await tester.tap(find.text('生理期'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('上个月'), findsOneWidget,
          reason: '8-B 整月日历已落地');
      expect(find.byType(BackButton), findsOneWidget,
          reason: 'AppBar automaticallyImplyLeading 不关');

      // 系统返回手势
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('关于我们，还有好多好多'), findsOneWidget);
      expect(find.byTooltip('上个月'), findsNothing);

      // AppBar 返回按钮
      await tester.tap(find.text('生理期'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('关于我们，还有好多好多'), findsOneWidget);
      await _flush(tester);
    });


    testWidgets('D6：对方 author 的日记录与历史卡菜单都无作者门槛',
        (tester) async {
      final s = _Store();
      final c = await _setup(s);
      await _pump(tester, c);
      expect(find.textContaining('第一天有点累'), findsWidgets,
          reason: '她记的日记录我这边可见（8-B 日记行回显）');
      // 8-B 历史卡「一次月经一张卡」，菜单对所有人开放（不加 author 判断）。
      final menus = find.byTooltip('更多操作');
      expect(menus, findsWidgets);
      await tester.tap(menus.first);
      await tester.pumpAndSettle();
      // 2.8.7 段四：整段编辑表单已删 → 菜单里只剩「删除这次」，编辑入口一并消失
      expect(find.text('编辑'), findsNothing, reason: '段四已删编辑入口');
      expect(find.text('删除这次'), findsOneWidget,
          reason: '删整次仍走 period-del-episode 的 ids（对所有人开放）');
      await _flush(tester);
    });
  });

  // ── 死入口清零 / 路由注册 / 8-B 落地护栏（源码级）────────────────
  group('入口与路由（源码级护栏）', () {
    test('聊天 ⊕ 面板死入口清零，两入口与 /period 路由都落地；8-B / C 段均落地', () {
      final compose = File('lib/features/chat/chat_compose.dart')
          .readAsStringSync();
      expect(compose.contains("条目 8 迁移后开放"), isFalse,
          reason: '_snack 占位必须清零');
      expect(compose.contains("context.push('/period')"), isTrue);
      expect(compose.contains("case 'tool-period':"), isTrue);
      final hub =
          File('lib/features/together/together_page.dart').readAsStringSync();
      expect(hub.contains("context.push('/period')"), isTrue);
      expect(hub.contains('记下周期，把照顾提前一点'), isTrue);
      final mainDart = File('lib/main.dart').readAsStringSync();
      expect(mainDart.contains("path: '/period'"), isTrue);
      expect(mainDart.contains('const PeriodPage()'), isTrue);

      final page =
          File('lib/features/period/period_page.dart').readAsStringSync();
      // 8-B 主页内容必须落地。
      for (final required in [
        'buildPeriodMonthGrid',
        'planStart(',
        'planEnd(',
        'planMore',
        'periodWarnings',
        'showPeriodLogSheet',
        'periodHeadingSub',
      ]) {
        expect(page.contains(required), isTrue, reason: '8-B $required 应落地');
      }
      // 2.8.7 段四：整段编辑表单已删，页面里不许再出现它的任何痕迹
      for (final gone in [
        'PeriodFormDialog',
        'period_form.dart',
        '_openEpisodeForm',
        '记一次经期',
      ]) {
        expect(page.contains(gone), isFalse, reason: '段四已删：$gone 不应再出现');
      }
      // 🔴 段 C 已落地：数据分析入口是活卡，context.push('/period/analysis')。
      // 只检查代码行（文档注释里也会提到这些字面量）。
      final code = page
          .split('\n')
          .where((l) =>
              !l.trimLeft().startsWith('//') &&
              !l.trimLeft().startsWith('///'))
          .join('\n');
      expect(code.contains("context.push('/period/analysis')"), isTrue,
          reason: 'C 段分析入口必须真跳转，不许死卡');
      expect(code.contains('数据分析'), isTrue);
      expect(code.contains('周期、流量、痛经、体温的变化'), isTrue);
      final mainDartC = File('lib/main.dart').readAsStringSync();
      expect(mainDartC.contains("path: '/period/analysis'"), isTrue);
      expect(mainDartC.contains('const PeriodAnalysisPage()'), isTrue);
      expect(code.contains('PERIOD_REMIND_DAYS'), isFalse,
          reason: '提醒（D3）仍不做');
    });
  });
}
