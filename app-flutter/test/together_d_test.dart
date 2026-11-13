/* 「我们」页段 D 单测（条目 6 · 恋爱清单 + 账本 + 歌单）：
   ① 纯函数：questIdeas 40 条、ledgerSummary 汇总（对照数值逐项断言，算法
      逐字对齐 Web ledgerPage）、ledgerMoney（'¥'+toFixed(2)）、sortQuests 未完成在前
   ② 控制器：toggleQuestDone = 记录级 PUT body 翻转 done（非 check 子资源）
   ③ 恋爱清单页：进度卡数字、完成勾选 PUT、精选一键添加（POST title+category+done）、
      自定义输入添加
   ④ 账本页：汇总数字与纯函数同源（对照数值贴 UI）、金额边界（空拦/0 元/两位小数）、
      下月封顶
   ⑤ 歌单页：搜索→加入歌单（POST kind=music 带 song 字段）、试听走下载优先
      （GET /api/music/stream?u=，无 Range）、hub 三卡就位 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import 'package:love_space/core/together/together_data.dart';
import 'package:love_space/features/chat/chat_toast.dart' show ChatToastHost;
import 'package:love_space/features/together/ledger_page.dart';
import 'package:love_space/features/together/music_page.dart';
import 'package:love_space/features/together/quest_page.dart';
import 'package:love_space/features/together/together_controller.dart';
import 'package:love_space/features/together/together_page.dart';

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
        {Map<String, Object> body = const {}, String author = 'u1',
        List<Object> media = const []}) =>
    {
      'id': id, 'kind': kind, 'author': author,
      'body': body,
      'created': 1000.0, 'updated': 1000.0, 'client_id': '',
      'media': media,
      'likes': const <Object>[], 'comments': const <Object>[],
    };

String _cm() {
  final d = DateTime.now();
  return '${d.year}-${d.month.toString().padLeft(2, '0')}';
}

String _pm() {
  final d = DateTime.now();
  final p = DateTime(d.year, d.month - 1, 1);
  return '${p.year}-${p.month.toString().padLeft(2, '0')}';
}

Map<String, Object> _meFixture = {
  'user': {'id': 'u1', 'name': '我', 'username': 'u1'},
  'users': [
    {'id': 'u1', 'name': '我', 'username': 'u1'},
    {'id': 'u2', 'name': 'TA', 'username': 'u2'},
  ],
  'space': {}, 'unread': 0, 'chat_unread': 0,
};

_FakeAdapter _withMe(ResponseBody Function(RequestOptions, int) inner) =>
    _FakeAdapter((options, i) {
      if (options.uri.path == '/api/me') return _json(_meFixture);
      return inner(options, i);
    });

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
  group('① 纯函数', () {
    test('questIdeas：五组 40 条', () {
      expect(questIdeas.values.fold<int>(0, (s, l) => s + l.length), 40);
      expect(questIdeas.keys.toList(),
          ['日常', '旅行', '美食', '约会', '生活']);
    });

    test('ledgerMoney：\'¥\'+toFixed(2)（0 元、两位小数）', () {
      expect(ledgerMoney(0), '¥0.00');
      expect(ledgerMoney(12.5), '¥12.50');
      expect(ledgerMoney(100.5), '¥100.50');
    });

    test('ledgerSummary：汇总对照数值（算法逐字对齐 Web ledgerPage）', () {
      final cm = _cm(), pm = _pm();
      final items = [
        TogetherRecord.fromJson(_toolRecord('l1', 'ledger',
            body: {'amount': 100.5, 'date': '$cm-01', 'category': '餐饮'},
            author: 'u1').cast<String, dynamic>()),
        TogetherRecord.fromJson(_toolRecord('l2', 'ledger',
            body: {'amount': 49.5, 'date': '$cm-05', 'category': '交通'},
            author: 'u2').cast<String, dynamic>()),
        TogetherRecord.fromJson(_toolRecord('l3', 'ledger',
            body: {'amount': 30, 'date': '$pm-20', 'category': '礼物'},
            author: 'u1').cast<String, dynamic>()),
        TogetherRecord.fromJson(_toolRecord('l4', 'ledger',
            body: {'amount': 0, 'date': '$cm-15', 'category': '其他'},
            author: 'u2').cast<String, dynamic>()),
      ];
      final s = ledgerSummary(items, cm, ['u1', 'u2']);
      expect(s.monthTotal, 150.0, reason: '100.5+49.5+0（0 元入账不崩）');
      expect(s.allTotal, 180.0, reason: '含上月 30');
      expect(s.monthCount, 3);
      expect(s.byUser, [('u1', 100.5), ('u2', 49.5)],
          reason: '付款人=作者（当月）');
      expect(s.allByUser, [('u1', 130.5), ('u2', 49.5)], reason: '累计按人');
      expect(s.byCat.first, ('餐饮', 100.5), reason: '当月按分类降序');
      expect(s.trend.last, (cm, 150.0));
      expect(s.trend.any((t) => t.$1 == pm && t.$2 == 30.0), isTrue);
      expect(s.trend.length, 6, reason: '空月也占位');
    });

    test('sortQuests：未完成在前', () {
      final items = [
        TogetherRecord.fromJson(_toolRecord('q1', 'quest',
            body: {'title': 'A', 'done': true}).cast<String, dynamic>()),
        TogetherRecord.fromJson(_toolRecord('q2', 'quest',
            body: {'title': 'B'}).cast<String, dynamic>()),
      ];
      expect(sortQuests(items).map((r) => r.id).toList(), ['q2', 'q1']);
    });
  });

  group('② 控制器', () {
    test('toggleQuestDone：记录级 PUT body 翻转 done（非 check 子资源）', () async {
      final original = {'title': '一起看日出', 'category': '旅行', 'done': false};
      final captured = <String, dynamic>{};
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'PUT' && options.uri.path == '/api/records/q1') {
          captured.addAll((options.data as Map).cast<String, dynamic>());
          return _json(_toolRecord('q1', 'quest',
              body: (options.data['body'] as Map).cast<String, Object>()));
        }
        return _json([_toolRecord('q1', 'quest', body: original)]);
      });
      final container = await _setup(adapter);
      final rec = container.read(togetherControllerProvider).records.single;
      final err = await container
          .read(togetherControllerProvider.notifier)
          .toggleQuestDone(rec);
      expect(err, isNull);
      final put = adapter.requests.firstWhere((r) => r.method == 'PUT');
      expect(put.uri.path, '/api/records/q1', reason: '记录级 PUT');
      expect((put.data as Map)['kind'], 'quest');
      expect((put.data['body'] as Map)['done'], true);
      expect((put.data['body'] as Map)['category'], '旅行');
    });
  });

  group('③ 恋爱清单页', () {
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
        {Widget page = const QuestPage()}) async {
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

    testWidgets('进度卡数字 + 完成勾选 PUT + 精选一键添加', (tester) async {
      var postCount = 0;
      final adapter = _withMe((options, i) {
        if (options.method == 'POST' && options.uri.path == '/api/records') {
          postCount++;
          return _json(_toolRecord('qNew', 'quest',
              body: (options.data['body'] as Map).cast<String, Object>()));
        }
        if (options.method == 'PUT' && options.uri.path == '/api/records/q1') {
          return _json(_toolRecord('q1', 'quest',
              body: (options.data['body'] as Map).cast<String, Object>()));
        }
        return _json([
          _toolRecord('q1', 'quest',
              body: {'title': '一起看日出', 'category': '旅行', 'done': false}),
        ]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      expect(find.textContaining('一起完成 0 / 1'), findsOneWidget);
      expect(find.textContaining('精选清单里挑'), findsOneWidget);

      // 精选一键添加：POST title+category+done:false
      await tester.tap(find.textContaining('＋ 一起看一次日出'));
      await tester.pumpAndSettle();
      expect(postCount, 1);
      final post = adapter.requests
          .firstWhere((r) => r.method == 'POST' && r.uri.path == '/api/records');
      expect((post.data['body'] as Map)['title'], '一起看一次日出');
      expect((post.data['body'] as Map)['category'], '旅行');
      expect((post.data['body'] as Map)['done'], false);
      expect(find.text('已加入清单'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));

      // 完成勾选（双方可点）
      await tester.tap(find.byIcon(Icons.radio_button_unchecked_rounded));
      await tester.pumpAndSettle();
      final put = adapter.requests.firstWhere((r) => r.method == 'PUT');
      expect((put.data['body'] as Map)['done'], true);
      // 顶部通知自动收起计时器走完，避免测试结束仍挂计时器
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('自定义输入添加（title+category 日常）', (tester) async {
      var postCount = 0;
      final adapter = _withMe((options, i) {
        if (options.method == 'POST' && options.uri.path == '/api/records') {
          postCount++;
          return _json(_toolRecord('qNew', 'quest',
              body: (options.data['body'] as Map).cast<String, Object>()));
        }
        return _json([]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      await tester.enterText(
          find.widgetWithText(TextFormField, '想一起做的一件小事…'), '一起去看海');
      await tester.tap(find.byTooltip('加入清单'));
      await tester.pumpAndSettle();
      expect(postCount, 1);
      final post = adapter.requests
          .firstWhere((r) => r.method == 'POST' && r.uri.path == '/api/records');
      expect((post.data['body'] as Map)['title'], '一起去看海');
      expect((post.data['body'] as Map)['category'], '日常');
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('④ 共同账本页', () {
    ProviderContainer widgetSetup(_FakeAdapter adapter) {
      final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
        ..httpClientAdapter = adapter;
      return ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
        mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
      ]);
    }

    Future<void> pumpPage(WidgetTester tester, ProviderContainer container) async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => Stack(children: [
            child ?? const SizedBox.shrink(),
            const Positioned(
                top: 0, left: 0, right: 0,
                child: IgnorePointer(child: SafeArea(child: ChatToastHost()))),
          ]),
          home: const LedgerPage(),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('汇总数字与纯函数同源（对照数值贴 UI）+ 下月封顶', (tester) async {
      final cm = _cm(), pm = _pm();
      final adapter = _withMe((options, i) {
        return _json([
          _toolRecord('l1', 'ledger',
              body: {'amount': 100.5, 'date': '$cm-01', 'category': '餐饮'},
              author: 'u1'),
          _toolRecord('l2', 'ledger',
              body: {'amount': 49.5, 'date': '$cm-05', 'category': '交通'},
              author: 'u2'),
          _toolRecord('l3', 'ledger',
              body: {'amount': 30, 'date': '$pm-20', 'category': '礼物'},
              author: 'u1'),
        ]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      // 对照数值（与 ledgerSummary 纯函数同一份数据）：月合计 150.00 / 累计 180.00
      expect(find.text('¥150.00'), findsOneWidget);
      expect(find.text('¥180.00'), findsOneWidget);
      expect(find.textContaining('这个月 2 笔'), findsOneWidget);
      expect(find.text('¥100.50'), findsNWidgets(2),
          reason: '当月按人 + 花在哪（餐饮）各一条');
      expect(find.text('¥49.50'), findsNWidgets(3),
          reason: '当月按人 + 累计按人 + 花在哪（交通）');
      expect(find.textContaining('累计谁花得多'), findsOneWidget);
      expect(find.textContaining('¥130.50'), findsOneWidget,
          reason: '累计按人：我 130.50');
      expect(find.textContaining('花在哪'), findsOneWidget);

      // 下月封顶：本月态下「下个月」禁用
      final nextBtn = tester.widget<IconButton>(find
          .widgetWithIcon(IconButton, Icons.chevron_right_rounded));
      expect(nextBtn.onPressed, isNull, reason: '本月时下月禁用（Web switcher 口径）');
      await tester.tap(find.byTooltip('上个月'));
      await tester.pumpAndSettle();
      expect(find.textContaining('上月'), findsNothing);
      // 上月标签精确断言（'10' 会同时命中年份/趋势列等多处，用整句）
      expect(find.text('10 月一起花了'), findsOneWidget);
      // 上月汇总数字变化：当月合计=0（上月只有 30 计入累计；按人两行也归零）
      expect(find.text('¥0.00'), findsWidgets);
    });

    testWidgets('金额边界：空拦 / 0 元可记 / 两位小数', (tester) async {
      var postCount = 0;
      final adapter = _withMe((options, i) {
        if (options.method == 'POST' && options.uri.path == '/api/records') {
          postCount++;
          return _json(_toolRecord('lNew', 'ledger',
              body: (options.data['body'] as Map).cast<String, Object>()));
        }
        return _json([]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      Future<void> openAndSubmit(String? amount) async {
        await tester.tap(find.byTooltip('记一笔'));
        await tester.pumpAndSettle();
        if (amount != null) {
          await tester.enterText(find.byType(TextFormField).first, amount);
        }
        await tester.tap(find.text('记下来'));
        await tester.pumpAndSettle();
      }

      await openAndSubmit(null);
      expect(postCount, 0, reason: '空金额被拦（请填写金额）');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      await openAndSubmit('12.5');
      expect(postCount, 1, reason: '两位小数可记');
      final post = adapter.requests
          .firstWhere((r) => r.method == 'POST' && r.uri.path == '/api/records');
      expect((post.data['body'] as Map)['amount'], 12.5);
      await tester.pump(const Duration(seconds: 3));

      await openAndSubmit('0');
      expect(postCount, 2, reason: '0 元合法（不崩）');
      final post2 = adapter.requests.lastWhere(
          (r) => r.method == 'POST' && r.uri.path == '/api/records');
      expect((post2.data['body'] as Map)['amount'], 0.0);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('⑤ 共同歌单页', () {
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
        {Widget page = const MusicPage()}) async {
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

    testWidgets('搜索→加入歌单：POST kind=music 带 song 字段', (tester) async {
      var postCount = 0;
      final adapter = _withMe((options, i) {
        if (options.uri.path == '/api/music/search') {
          return _json({
            'items': [
              {'title': '晚安', 'artist': '颜人中', 'album': '晚安',
               'preview': 'https://audio-ssl.itunes.apple.com/a.m4a',
               'art': 'https://is1-ssl.mzstatic.com/a.jpg', 'dur': 30},
            ],
          });
        }
        if (options.method == 'POST' && options.uri.path == '/api/records') {
          postCount++;
          return _json(_toolRecord('mNew', 'music',
              body: (options.data['body'] as Map).cast<String, Object>()));
        }
        return _json([]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      await tester.tap(find.byTooltip('搜歌入单'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '晚安');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('晚安'), findsWidgets, reason: '搜索结果出现');

      await tester.tap(find.byTooltip('加入歌单'));
      await tester.pumpAndSettle();
      expect(postCount, 1);
      final post = adapter.requests
          .firstWhere((r) => r.method == 'POST' && r.uri.path == '/api/records');
      expect(post.data['kind'], 'music');
      final body = post.data['body'] as Map;
      expect(body['title'], '晚安');
      expect(body['content'], '颜人中');
      expect((body['song'] as Map)['src'],
          'https://audio-ssl.itunes.apple.com/a.m4a');
      expect((body['song'] as Map)['dur'], 30);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('试听走下载优先：GET /api/music/stream?u=（无 Range 流播）', (tester) async {
      final adapter = _withMe((options, i) {
        if (options.uri.path == '/api/music/stream') {
          // 测试环境无音频插件：下载成功后 setFilePath 会抛错被 UI 兜底——
          // 但下载请求本身必须发生（Range 缺陷规避的可验证口径）
          return ResponseBody.fromBytes(Uint8List.fromList([1, 2, 3]), 200,
              headers: {
                Headers.contentTypeHeader: ['audio/mp4'],
              });
        }
        return _json([
          _toolRecord('m1', 'music', body: {
            'title': '晚安',
            'content': '颜人中',
            'song': {
              'title': '晚安', 'artist': '颜人中',
              'src': 'https://audio-ssl.itunes.apple.com/a.m4a',
              'art': '', 'dur': 30,
            },
          }),
        ]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      await tester.tap(find.byTooltip('试听'));
      // 有界 pump：试听流程里有 indeterminate spinner（loading 态），不能用
      // pumpAndSettle（会因动画永不停止而超时）
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 1));
      final dl = adapter.requests
          .firstWhere((r) => r.uri.path == '/api/music/stream');
      expect(dl.queryParameters['u'],
          'https://audio-ssl.itunes.apple.com/a.m4a');
      // 无 Range 头（全量 GET，规避中转线 Range 缺陷）
      expect(dl.headers.containsKey('range'), isFalse);
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('⑥ hub 三卡', () {
    testWidgets('恋爱清单/账本/歌单三卡就位', (tester) async {
      final adapter = _withMe((options, i) => _json([]));
      final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
        ..httpClientAdapter = adapter;
      final container = ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
        mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: TogetherPage(active: true)),
      ));
      await tester.pumpAndSettle();
      // ListView 懒构建：后半段卡片在测试视口外未进树，滚动让它们构建
      await tester.scrollUntilVisible(find.text('恋爱清单'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('恋爱清单'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('共同账本'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('共同账本'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('共同歌单'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('共同歌单'), findsOneWidget);
    });
  });
}
