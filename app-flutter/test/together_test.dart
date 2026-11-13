/* 「我们」页段 A 单测（条目 6 · hub + mood/note/wish）：
   ① 数据层纯函数：parseTogetherRecords 容错、mergeRecordBody 回填铁律
      （未知字段存活）、nextAnniversary（annual 推进 + 02-29 回退 + 一次性/已过跳过）、
      mood 排序（date 倒序、无日期归末尾）
   ② 控制器：load 一次全量 kind 参数、add（POST kind/body/client_id）、
      edit 回填铁律专项（PUT body 未知字段存活）、toggleWishDone（done 翻转 + 全量 body）、
      delete（软删 → 重拉剔除）
   ③ UI：hub 纪念日展示卡（点击切首页 tab）、mood 表单取消不误写/提交 POST、
      wish done 勾选 PUT */
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import 'package:love_space/core/together/together_data.dart';
import 'package:love_space/features/chat/chat_toast.dart' show ChatToastHost;
import 'package:love_space/features/together/together_controller.dart';
import 'package:love_space/features/together/together_page.dart';
import 'package:love_space/features/together/tool_pages.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions options, int callIndex) handler;
  final List<RequestOptions> requests = [];
  int calls = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return handler(options, calls++);
  }
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
    jsonEncode(data), status,
    headers: {Headers.contentTypeHeader: const ['application/json']});

Map<String, Object> _toolRecord(String id, String kind,
        {Map<String, Object> body = const {}, String author = 'u1'}) =>
    {
      'id': id, 'kind': kind, 'author': author,
      'body': body,
      'created': 1000.0, 'updated': 1000.0, 'client_id': '',
      'media': const <Object>[],
      'likes': const <Object>[], 'comments': const <Object>[],
    };

/// 距今天 [days] 天的日期串（保证 nextAnniversary 用例随时间稳定）
String _dateInDays(int days) {
  final d = DateTime.now().add(Duration(days: days));
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

Future<ProviderContainer> _setup(_FakeAdapter adapter) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  final container = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
  ]);
  addTearDown(container.dispose);
  await container.read(togetherControllerProvider.notifier).bootstrap();
  return container;
}

void main() {
  // ── ① 数据层纯函数 ───────────────────────────────────────────
  group('① 数据层纯函数', () {
    test('parseTogetherRecords：解析 + 畸形容错', () {
      final out = parseTogetherRecords([
        _toolRecord('m1', 'mood', body: {'emoji': '☀️', 'date': '2026-11-13'}),
        'junk',
        {'id': ''},
      ]);
      expect(out.length, 1);
      expect(out.single.kind, 'mood');
      expect(out.single.body['emoji'], '☀️');
      expect(parseTogetherRecords(null), isEmpty);
    });

    test('mergeRecordBody：回填铁律（未知字段与 category/target 存活）', () {
      final original = {
        'title': '去海边', 'category': '旅行', 'target': '2027-01-01',
        'unknown_web_only': 'keep-me',
      };
      final merged = mergeRecordBody(original, {'title': '去看海', 'done': true});
      expect(merged['title'], '去看海');
      expect(merged['category'], '旅行');
      expect(merged['target'], '2027-01-01');
      expect(merged['unknown_web_only'], 'keep-me');
      expect(merged['done'], true);
    });

    test('nextAnniversary：annual=true 今年未过 → 今年日期', () {
      final recs = [
        TogetherRecord.fromJson(_toolRecord('a1', 'anniversary',
            body: {'title': '生日', 'date': _dateInDays(30), 'annual': true})
            .cast<String, dynamic>()),
      ];
      final ann = nextAnniversary(recs, todayDateStr());
      expect(ann, isNotNull);
      expect(ann!.days, 30);
      expect(ann.due, _dateInDays(30));
    });

    test('nextAnniversary：annual=true 今年已过 → 推进到明年', () {
      final recs = [
        TogetherRecord.fromJson(_toolRecord('a1', 'anniversary',
            body: {'title': '生日', 'date': _dateInDays(-30), 'annual': true})
            .cast<String, dynamic>()),
      ];
      final ann = nextAnniversary(recs, todayDateStr());
      expect(ann!.days, 335, reason: '明年同月日（365-30）');
    });

    test('nextAnniversary：一次性已过（days<0）跳过', () {
      final recs = [
        TogetherRecord.fromJson(_toolRecord('a1', 'anniversary',
            body: {'title': '旧事', 'date': _dateInDays(-97)})
            .cast<String, dynamic>()),
      ];
      expect(nextAnniversary(recs, todayDateStr()), isNull,
          reason: '过去的纪念日不倒计时（2026-11-11 真机 -97 天教训）');
    });

    test('sortMoodsByDateDesc：date 倒序、无日期归末尾、同日期新记录在前', () {
      final moods = [
        TogetherRecord.fromJson(_toolRecord('m1', 'mood',
            body: {'date': '2026-11-01'}).cast<String, dynamic>()),
        TogetherRecord.fromJson(_toolRecord('m2', 'mood',
            body: {'date': '2026-11-13'}).cast<String, dynamic>()),
        TogetherRecord.fromJson(_toolRecord('m3', 'mood',
            body: {}).cast<String, dynamic>()),
        TogetherRecord.fromJson(
            (_toolRecord('m4', 'mood', body: {'date': '2026-11-13'})
                  ..['created'] = 2000.0)
                .cast<String, dynamic>()),
      ];
      expect(sortMoodsByDateDesc(moods).map((r) => r.id).toList(),
          ['m4', 'm2', 'm1', 'm3']);
    });
  });

  // ── ② 控制器 ─────────────────────────────────────────────────
  group('② 控制器', () {
    test('load：一次全量 kind=mood,note,wish,anniversary,question,habit,quest,ledger,music&limit=1000', () async {
      final adapter = _FakeAdapter((options, i) {
        if (options.uri.path == '/api/records') {
          return _json([_toolRecord('m1', 'mood')]);
        }
        return _json([]);
      });
      final container = await _setup(adapter);
      expect(container.read(togetherControllerProvider).records.single.id, 'm1');
      final req = adapter.requests.first;
      expect(req.queryParameters['kind'],
          'mood,note,wish,anniversary,question,habit,quest,ledger,music');
      expect(req.queryParameters['limit'], 1000);
    });

    test('add：POST kind/body/client_id，成功后重拉入列表', () async {
      var posted = false;
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'POST' && options.uri.path == '/api/records') {
          posted = true;
          return _json(_toolRecord('mNew', 'mood',
              body: (options.data['body'] as Map).cast<String, Object>()));
        }
        return _json(posted
            ? [_toolRecord('m1', 'mood'), _toolRecord('mNew', 'mood')]
            : [_toolRecord('m1', 'mood')]);
      });
      final container = await _setup(adapter);
      final err = await container
          .read(togetherControllerProvider.notifier)
          .add('mood', {'emoji': '☀️', 'date': '2026-11-13', 'content': '好天气'});
      expect(err, isNull);
      final post = adapter.requests
          .firstWhere((r) => r.method == 'POST');
      expect(post.data['kind'], 'mood');
      expect((post.data['body'] as Map)['emoji'], '☀️');
      expect((post.data['client_id'] as String).isNotEmpty, isTrue,
          reason: 'client_id 幂等');
      expect(container
          .read(togetherControllerProvider)
          .records
          .any((r) => r.id == 'mNew'), isTrue);
    });

    test('edit：回填铁律专项——PUT body 未知字段存活，只盖改动键', () async {
      final original = {'title': '去海边', 'category': '旅行',
        'target': '2027-01-01', 'unknown_web_only': 'keep-me'};
      final captured = <String, dynamic>{};
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'PUT' && options.uri.path == '/api/records/w1') {
          captured.addAll((options.data as Map).cast<String, dynamic>());
          return _json(_toolRecord('w1', 'wish',
              body: (options.data['body'] as Map).cast<String, Object>()));
        }
        return _json([_toolRecord('w1', 'wish', body: original)]);
      });
      final container = await _setup(adapter);
      final err = await container
          .read(togetherControllerProvider.notifier)
          .edit('w1', 'wish', original, {'title': '去看海', 'done': true});
      expect(err, isNull);
      final body = captured['body'] as Map;
      expect(body['title'], '去看海');
      expect(body['category'], '旅行');
      expect(body['target'], '2027-01-01');
      expect(body['unknown_web_only'], 'keep-me');
      expect(body['done'], true);
    });

    test('toggleWishDone：PUT 全量 body 只翻转 done', () async {
      final original = {'title': '去海边', 'category': '旅行', 'done': false};
      final captured = <String, dynamic>{};
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'PUT' && options.uri.path == '/api/records/w1') {
          captured.addAll((options.data as Map).cast<String, dynamic>());
          return _json(_toolRecord('w1', 'wish',
              body: (options.data['body'] as Map).cast<String, Object>()));
        }
        return _json([_toolRecord('w1', 'wish', body: original)]);
      });
      final container = await _setup(adapter);
      final rec = container.read(togetherControllerProvider).records.single;
      final err = await container
          .read(togetherControllerProvider.notifier)
          .toggleWishDone(rec);
      expect(err, isNull);
      expect((captured['body'] as Map)['done'], true);
      expect((captured['body'] as Map)['title'], '去海边');
    });

    test('delete：DELETE 软删 → 重拉剔除', () async {
      var deleted = false;
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'DELETE' && options.uri.path == '/api/records/m1') {
          deleted = true;
          return _json({'ok': true});
        }
        return _json(deleted ? [] : [_toolRecord('m1', 'mood')]);
      });
      final container = await _setup(adapter);
      expect(container.read(togetherControllerProvider).records, isNotEmpty);
      final err = await container
          .read(togetherControllerProvider.notifier)
          .delete('m1');
      expect(err, isNull);
      expect(container.read(togetherControllerProvider).records, isEmpty);
      expect(deleted, isTrue);
    });
  });

  // ── ③ UI ─────────────────────────────────────────────────────
  group('③ UI（hub 与工具页）', () {
    ProviderContainer widgetSetup(_FakeAdapter adapter) {
      final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
        ..httpClientAdapter = adapter;
      return ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
        mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
      ]);
    }

    Future<void> pumpPage(WidgetTester tester, ProviderContainer container,
        {required Widget page, VoidCallback? onGoHome}) async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => Stack(children: [
            child ?? const SizedBox.shrink(),
            const Positioned(
                top: 0, left: 0, right: 0,
                child: IgnorePointer(child: SafeArea(child: ChatToastHost()))),
          ]),
          home: page,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('hub：纪念日展示卡点击直达管理页（段 B 接线）+ 年历卡就位',
        (tester) async {
      final adapter = _FakeAdapter((options, i) {
        return _json([
          _toolRecord('a1', 'anniversary', body: {
            'title': '领证纪念日', 'date': _dateInDays(10), 'annual': true,
          }),
          _toolRecord('m1', 'mood', body: {'emoji': '☀️', 'date': '2026-11-13'}),
        ]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      final router = GoRouter(initialLocation: '/home', routes: [
        GoRoute(
            path: '/home',
            builder: (_, _) => UncontrolledProviderScope(
                container: container,
                child: const TogetherPage(active: true))),
        GoRoute(
            path: '/together/anniversary',
            builder: (_, _) => const Scaffold(body: Text('纪念日管理页'))),
        GoRoute(
            path: '/together/calendar',
            builder: (_, _) => const Scaffold(body: Text('年历页'))),
      ]);
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('领证纪念日'), findsOneWidget,
          reason: '纪念日卡展示标题（嵌在天数旁文案里）');
      expect(find.text('10'), findsOneWidget, reason: '倒计时天数');
      expect(find.text('共同年历'), findsOneWidget, reason: '段 B 新卡就位（无死卡纪律）');
      expect(find.text('心情手记'), findsOneWidget);
      expect(find.text('共同愿望'), findsOneWidget);

      // 纪念日展示卡点击 → 直达管理页（决策点①段 B 接线）
      await tester.tap(find.textContaining('领证纪念日'));
      await tester.pumpAndSettle();
      expect(find.text('纪念日管理页'), findsOneWidget);

      // 返回路径：返回键/手势回 hub（主页在路由栈）
      router.pop();
      await tester.pumpAndSettle();
      expect(find.textContaining('领证纪念日'), findsOneWidget,
          reason: '返回后回到 hub');
    });

    testWidgets('mood 表单：取消不误写；提交 POST kind=mood', (tester) async {
      var postCount = 0;
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'POST' && options.uri.path == '/api/records') {
          postCount++;
          return _json(_toolRecord('mNew', 'mood',
              body: (options.data['body'] as Map).cast<String, Object>()));
        }
        return _json([]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container, page: const MoodPage());

      await tester.tap(find.byTooltip('记心情'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(postCount, 0, reason: '取消不误写');

      await tester.tap(find.byTooltip('记心情'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(1), '今天天气很好');
      await tester.tap(find.text('记下今天'));
      await tester.pumpAndSettle();
      expect(postCount, 1);
      final post = adapter.requests.firstWhere((r) => r.method == 'POST');
      expect(post.data['kind'], 'mood');
      expect((post.data['body'] as Map)['content'], '今天天气很好');
      expect((post.data['body'] as Map)['emoji'], '☀️');
      expect(find.text('已记下今天的心情'), findsOneWidget, reason: '顶部通知');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('wish done 勾选：PUT 全量 body 翻转 done', (tester) async {
      final original = {'title': '一起去看海', 'category': '旅行', 'done': false};
      final captured = <String, dynamic>{};
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'PUT' && options.uri.path == '/api/records/w1') {
          captured.addAll((options.data as Map).cast<String, dynamic>());
          return _json(_toolRecord('w1', 'wish',
              body: (options.data['body'] as Map).cast<String, Object>()));
        }
        return _json([_toolRecord('w1', 'wish', body: original)]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container, page: const WishPage());

      expect(find.text('一起去看海'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.radio_button_unchecked_rounded));
      await tester.pumpAndSettle();
      expect((captured['body'] as Map)['done'], true);
      expect((captured['body'] as Map)['category'], '旅行');
      expect(find.text('已更新'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
