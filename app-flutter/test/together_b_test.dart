/* 「我们」页段 B 单测（条目 6 · 共同年历 + 纪念日管理页）：
   ① 纯函数：anniversaryDue（annual 推进 / 02-29 回退 / 一次性已过 null / lunar 近似，
      固定 today 参数全确定性）、parseCalendarMonth（days 解析 + 容错）
   ② 纪念日管理页：列表倒计时/重复方式文案、添加表单取消不误写/提交 POST
      （annual 三态 + remind_days int）、编辑回填铁律、删除确认可取消
   ③ 年历页：/api/calendar?month= 当前月、点日看当天条目（纪念/心情/动态/打卡）、
      翻月重新拉取
   ④ 双入口接线静态核对：首页纪念日区与 hub 展示卡都 push /together/anniversary */
import 'dart:convert';
import 'dart:io';
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
import 'package:love_space/features/together/anniversary_page.dart';
import 'package:love_space/features/together/calendar_page.dart';

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
      'media': const <Object>[], 'likes': const <Object>[],
      'comments': const <Object>[],
    };

String _dateInDays(int days) {
  final d = DateTime.now().add(Duration(days: days));
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

String _currentMonth() {
  final d = DateTime.now();
  return '${d.year}-${d.month.toString().padLeft(2, '0')}';
}

/// 认证供体：/api/me 返回合法 me（ToolTile/管理页本人菜单与人名解析依赖）
Map<String, Object> _meFixture = {
  'user': {'id': 'u1', 'name': '我', 'username': 'u1'},
  'users': [
    {'id': 'u1', 'name': '我', 'username': 'u1'},
    {'id': 'u2', 'name': 'TA', 'username': 'u2'},
  ],
  'space': {},
  'unread': 0,
  'chat_unread': 0,
};

_FakeAdapter _withMe(ResponseBody Function(RequestOptions, int) inner) =>
    _FakeAdapter((options, i) {
      if (options.uri.path == '/api/me') return _json(_meFixture);
      return inner(options, i);
    });

void main() {
  // ── ① 纯函数 ─────────────────────────────────────────────────
  group('① anniversaryDue / parseCalendarMonth', () {
    test('annual=true：未过 → 今年；已过 → 明年；02-29 回退 02-28', () {
      expect(anniversaryDue({'date': '2026-06-01', 'annual': true},
          '2027-01-10')!.due, '2027-06-01');
      expect(anniversaryDue({'date': '2026-06-01', 'annual': true},
          '2027-08-01')!.due, '2028-06-01');
      // 2027 非闰年：02-29 → 02-28
      expect(anniversaryDue({'date': '2024-02-29', 'annual': true},
          '2027-01-10')!.due, '2027-02-28');
      // 2028 闰年：保留 02-29
      expect(anniversaryDue({'date': '2024-02-29', 'annual': true},
          '2028-01-10')!.due, '2028-02-29');
    });

    test('一次性已过 → null；lunar 按原样近似；今天 → days=0', () {
      expect(anniversaryDue({'date': '2020-01-01'}, '2027-01-10'), isNull);
      expect(anniversaryDue({'date': '2020-01-01', 'annual': false},
          '2027-01-10'), isNull);
      expect(anniversaryDue({'date': '2020-01-01', 'annual': 'lunar'},
          '2027-01-10'), isNull, reason: 'lunar 原样 2020-01-01 已过 → null');
      final t = anniversaryDue({'date': '2020-01-10', 'annual': true},
          '2027-01-10');
      expect(t!.days, 0);
    });

    test('parseCalendarMonth：days 解析 + 畸形容错', () {
      final m = parseCalendarMonth({
        'month': '2026-11',
        'days': {
          '05': {
            'anniversaries': [{'id': 'a1', 'title': '领证'}],
            'posts': [{'id': 'p1', 'title': '海边一天'}],
            'moods': [{'author': 'u1', 'emoji': '☀️'}],
            'checks': [{'author': 'u1'}, {'author': 'u2'}],
          },
          'junk': 'not-a-map',
        },
      });
      expect(m.month, '2026-11');
      expect(m.days['05']!.anniversaries.single['title'], '领证');
      expect(m.days['05']!.posts.single['id'], 'p1');
      expect(m.days['05']!.moods.single['emoji'], '☀️');
      expect(m.days['05']!.checks.length, 2);
      expect(m.days['05']!.hasEvents, isTrue);
      expect(m.days.containsKey('junk'), isFalse);
      expect(parseCalendarMonth(null).days, isEmpty);
    });
  });

  // ── ② 纪念日管理页 ───────────────────────────────────────────
  group('② 纪念日管理页', () {
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
          home: const AnniversaryPage(),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('列表：标题/重复方式/倒计时（复用 anniversaryDue）', (tester) async {
      final adapter = _withMe((options, i) {
        return _json([
          _toolRecord('a1', 'anniversary', body: {
            'title': '领证纪念日', 'date': _dateInDays(10), 'annual': true,
            'remind_days': 3, 'content': '记得订餐厅',
          }),
          _toolRecord('a2', 'anniversary', body: {
            'title': '旧的一天', 'date': '2020-01-01',
          }, author: 'u2'),
        ]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      expect(find.text('领证纪念日'), findsOneWidget);
      expect(find.textContaining('每年公历日期'), findsNWidgets(2), reason: '本人+对方各一条（对方的缺省也是公历）');
      expect(find.textContaining('提前 3 天提醒'), findsOneWidget);
      expect(find.text('还有 10 天'), findsOneWidget);
      expect(find.textContaining('每年农历日期'), findsNothing);
      // 对方的过期纪念日：只读展示
      expect(find.text('旧的一天'), findsOneWidget);
      expect(find.text('已过去 · 留在回忆里'), findsOneWidget);
      // 非本人无 ⋯ 菜单：两条记录只有 1 个菜单按钮（a1 是本人的）
      expect(find.byTooltip('更多操作'), findsOneWidget);
    });

    testWidgets('添加表单：取消不误写；提交 POST annual=true + remind_days int',
        (tester) async {
      var postCount = 0;
      final adapter = _withMe((options, i) {
        if (options.method == 'POST' && options.uri.path == '/api/records') {
          postCount++;
          return _json(_toolRecord('aNew', 'anniversary',
              body: (options.data['body'] as Map).cast<String, Object>()));
        }
        return _json([]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      await tester.tap(find.byTooltip('添加纪念日'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(postCount, 0, reason: '取消不误写');

      await tester.tap(find.byTooltip('添加纪念日'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), '拍拖纪念日');
      // date 必填：不选日期直接提交 → 校验拦截
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      expect(postCount, 0, reason: 'date 必填校验拦截');
      // 选日期：点开系统日期选择器 → OK（选今天）
      await tester.tap(find.byType(TextFormField).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      expect(postCount, 1);
      final post = adapter.requests.firstWhere((r) => r.method == 'POST');
      expect(post.data['kind'], 'anniversary');
      final body = post.data['body'] as Map;
      expect(body['title'], '拍拖纪念日');
      expect(body['date'], todayDateStr());
      expect(body['annual'], true, reason: '默认每年公历');
      expect(body['remind_days'], 1, reason: '默认提前 1 天（int）');
      expect(find.text('已添加纪念日'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('编辑：预填 + PUT 回填铁律（未知字段存活）；删除确认可取消',
        (tester) async {
      final original = {'title': '领证纪念日', 'date': '2026-06-01',
        'annual': true, 'remind_days': 3, 'unknown_web_only': 'keep'};
      var putCount = 0, deleteCount = 0;
      final adapter = _withMe((options, i) {
        if (options.method == 'PUT' && options.uri.path == '/api/records/a1') {
          putCount++;
          return _json(_toolRecord('a1', 'anniversary',
              body: (options.data['body'] as Map).cast<String, Object>()));
        }
        if (options.method == 'DELETE' && options.uri.path == '/api/records/a1') {
          deleteCount++;
          return _json({'ok': true});
        }
        return _json([_toolRecord('a1', 'anniversary', body: original)]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(find.text('领证纪念日'), findsWidgets, reason: '标题预填');
      await tester.enterText(find.byType(TextFormField).at(0), '领证纪念日快乐');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(putCount, 1);
      final put = adapter.requests.firstWhere((r) => r.method == 'PUT');
      final body = put.data['body'] as Map;
      expect(body['title'], '领证纪念日快乐');
      expect(body['annual'], true);
      expect(body['remind_days'], 3);
      expect(body['unknown_web_only'], 'keep', reason: '回填铁律');

      // 删除：确认弹层取消 → 不删；确认 → DELETE
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(deleteCount, 0, reason: '取消不删');
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(deleteCount, 1);
      expect(find.text('已删除'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  // ── ③ 共同年历 ───────────────────────────────────────────────
  group('③ 共同年历', () {
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
        child: MaterialApp(home: const CalendarPage()),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('首屏：/api/calendar?month=当前月；点日看当天条目（只读）',
        (tester) async {
      final adapter = _withMe((options, i) {
        return _json({
          'month': _currentMonth(),
          'days': {
            '10': {
              'anniversaries': [{'id': 'a1', 'title': '领证纪念日'}],
              'posts': [{'id': 'p1', 'title': '海边一天'}],
              'moods': [{'author': 'u1', 'emoji': '☀️'}],
              'checks': [{'author': 'u1'}, {'author': 'u2'}],
            },
          },
        });
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      final calReq = adapter.requests.first;
      expect(calReq.uri.path, '/api/calendar');
      expect(calReq.queryParameters['month'], _currentMonth());

      // 点 10 日格（今天的日期数字可能多处出现——用「有事件那格」不可直查，
      // 改点数字 10：当天=todayDay 时同一数字只出现一次（today 样式）
      await tester.tap(find.text('10'));
      await tester.pumpAndSettle();
      expect(find.textContaining('领证纪念日'), findsOneWidget, reason: '当天纪念条目');
      expect(find.textContaining('海边一天'), findsOneWidget, reason: '当天动态条目');
      expect(find.textContaining('☀️'), findsOneWidget, reason: '当天心情条目');
      expect(find.textContaining('2 人完成'), findsOneWidget, reason: '打卡人数');
    });

    testWidgets('翻月：上月/下月重新拉取对应 month 参数', (tester) async {
      final adapter = _withMe((options, i) {
        return _json({'month': _currentMonth(), 'days': {}});
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container);
      final firstCount = adapter.requests.length;

      await tester.tap(find.byTooltip('上个月'));
      await tester.pumpAndSettle();
      final now = DateTime.now();
      final prev = DateTime(now.year, now.month - 1, 1);
      final prevMonth =
          '${prev.year}-${prev.month.toString().padLeft(2, '0')}';
      expect(adapter.requests.length, greaterThan(firstCount));
      expect(adapter.requests.last.queryParameters['month'], prevMonth);

      await tester.tap(find.byTooltip('下个月'));
      await tester.pumpAndSettle();
      expect(adapter.requests.last.queryParameters['month'], _currentMonth());
    });
  });

  // ── ④ 双入口接线静态核对 ──────────────────────────────────────
  group('④ 双入口接线（静态核对）', () {
    test('首页纪念日区与 hub 展示卡都 push /together/anniversary', () {
      final home = File('lib/features/home/home_page.dart').readAsStringSync();
      final hub =
          File('lib/features/together/together_page.dart').readAsStringSync();
      expect(home.contains("context.push('/together/anniversary')"), isTrue,
          reason: '首页纪念日区直达管理页（不再跳「我们」tab）');
      expect(hub.contains("context.push('/together/anniversary')"), isTrue,
          reason: 'hub 展示卡直达管理页（不再切首页 tab）');
      expect(home.contains('onGoTab?.call(3)'), isFalse,
          reason: '旧的跳 tab 接线已移除');
    });
  });
}
