/* 「我们」页段 E 回归（2.1.6/VC216 · 数据看板 + 回忆周报，只读）：
   契约实读 app/main.py:2082（dashboard）/:2126（weekly），呈现口径逐字
   对齐 Web dashboardPage/weeklyPage（app.js:1303/:1317）与
   act('week-copy')（app.js:2479）。
   ① 纯函数：parseDashboard（months 旧→新、days_together null、kindRows
      过滤+降序）、parseWeekly（highlights 走 parseTogetherRecords、
      deltaText/streakLine/rangeLabel/weeklyCopyText 逐字）
   ② 看板页：四联卡数字、愿望进度与完成度（Math.round 口径）、记录构成
      /心情分布行、days_together=null → '—'
   ③ 周报页：hero 文案、四联卡、下一周在 offset>=0 禁用、上一周 →
      offset=-1 重拉（断言 query）、复制文字版 → 剪贴板 4 行
   ④ hub 增补看板/周报两卡 */
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import 'package:love_space/core/together/together_data.dart';
import 'package:love_space/features/together/dashboard_page.dart';
import 'package:love_space/features/together/together_page.dart';
import 'package:love_space/features/together/weekly_page.dart';

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

Map<String, Object> _meFixture = {
  'user': {'id': 'u1', 'name': '我', 'username': 'u1'},
  'users': [
    {'id': 'u1', 'name': '我', 'username': 'u1'},
    {'id': 'u2', 'name': 'TA', 'username': 'u2'},
  ],
  'space': {}, 'unread': 0, 'chat_unread': 0,
};

Future<ProviderContainer> _setup(_FakeAdapter adapter) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  final container = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
  ]);
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container,
    {Widget page = const DashboardPage()}) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(home: page),
  ));
  await tester.pumpAndSettle();
}

// 看板夹具：数字刻意互不重样（除月柱计数），find.text 断言唯一可判
Map<String, Object?> _dashboardFixture({int? daysTogether = 100}) => {
      'total': 42,
      'by_kind': {'post': 20, 'wish': 10, 'chat': 4, 'diary': 2},
      'months': [
        for (var i = 1; i <= 12; i++)
          {'month': '2025-${i.toString().padLeft(2, '0')}', 'count': i},
      ],
      'moods': {'😊': 3, '🥲': 1},
      'likes': 6, 'comments': 3, 'photos': 5,
      'days_together': daysTogether,
      'wishes_total': 10, 'wishes_done': 3,
    };

// 周报夹具：四联卡数字与 kind/mood 计数互不重样，find.text 唯一可判
Map<String, Object?> _weeklyFixture({
  int offset = 0,
  int delta = 2,
  int streak = 2,
  Object? lastRecordDaysAgo,
  String? topMood = '😊',
}) =>
    {
      'offset': offset,
      'label': offset == 0 ? '这一周' : '上一周',
      'start': '2026-11-09', 'end': '2026-11-15',
      'total': 6, 'prev_total': 4, 'delta': delta,
      'days_active': 3, 'photos': 7,
      'by_kind': {'post': 4, 'note': 2},
      'moods': {'😊': 1},
      'top_mood': topMood,
      'likes': 5, 'comments': 3,
      'streak': streak,
      'last_record_days_ago': lastRecordDaysAgo,
      'highlights': [
        {
          'id': 'h1', 'kind': 'post', 'author': 'u1',
          'body': {'title': '第一场电影', 'content': '看完吃了火锅'},
          'created': 1763000000.0, 'updated': 1763000000.0,
          'client_id': '', 'media': [],
          'likes': ['u2'], 'comments': [
            {'id': 'c1', 'author': 'u2', 'content': '好看！'}
          ],
        },
      ],
      'message': '这一周，你们一起写下了 6 段回忆、7 张照片，有 3 天留下了痕迹。',
    };

void main() {
  group('① 纯函数', () {
    test('parseDashboard：字段逐项 + months 旧→新 + days_together null', () {
      final d = parseDashboard(_dashboardFixture());
      expect(d.total, 42);
      expect(d.byKind, {'post': 20, 'wish': 10, 'chat': 4, 'diary': 2});
      expect(d.months.length, 12);
      expect(d.months.first.month, '2025-01'); // 旧→新
      expect(d.months.last.count, 12);
      expect(d.moods['😊'], 3);
      expect(d.likes, 6);
      expect(d.comments, 3);
      expect(d.photos, 5);
      expect(d.daysTogether, 100);
      expect(d.wishesTotal, 10);
      expect(d.wishesDone, 3);
      expect(parseDashboard(_dashboardFixture(daysTogether: null)).daysTogether,
          isNull);
      // 畸形输入容错
      final bad = parseDashboard(null);
      expect(bad.total, 0);
      expect(bad.months, isEmpty);
    });

    test('kindRows：过滤有标签 kind + 数量降序（Web 同口径）', () {
      final d = parseDashboard(_dashboardFixture());
      expect(d.kindRows.map((e) => e.$1).toList(),
          ['post', 'wish', 'chat', 'diary']);
      expect(d.kindRows.map((e) => e.$2).toList(), [20, 10, 4, 2]);
    });

    test('parseWeekly：highlights 走 parseTogetherRecords + 可空字段', () {
      final w = parseWeekly(_weeklyFixture());
      expect(w.label, '这一周');
      expect(w.delta, 2);
      expect(w.daysActive, 3);
      expect(w.topMood, '😊');
      expect(w.streak, 2);
      expect(w.lastRecordDaysAgo, isNull);
      expect(w.highlights.length, 1);
      expect(w.highlights.first.id, 'h1');
      expect(w.highlights.first.likeCount, 1); // 序列化 likes 数组长度
      expect(w.highlights.first.commentCount, 1);
      expect(w.highlights.first.body['title'], '第一场电影');
      // rangeLabel：'2026 年 · 11.09 – 11.15'（Web short 口径）
      expect(w.rangeLabel, '2026 年 · 11.09 – 11.15');
      // delta 文案（app.js:1322 逐字）
      expect(w.deltaText, '比上一周多写了 2 条');
      expect(parseWeekly(_weeklyFixture(delta: -2)).deltaText,
          '比上一周少了 2 条');
      // streak 行（app.js:1323 逐字）
      expect(w.streakLine, '🔥 已连续记录 2 天');
      final w2 = parseWeekly(_weeklyFixture(
          streak: 0, lastRecordDaysAgo: 3, topMood: null));
      expect(w2.streakLine, '上次记录在 3 天前');
      expect(w2.topMood, isNull);
      final w3 = parseWeekly(_weeklyFixture(streak: 0));
      expect(w3.streakLine, '还没有开始记录');
      // 畸形输入容错
      expect(parseWeekly(null).total, 0);
    });

    test('weeklyCopyText：4 行逐字（Web act(\'week-copy\') 格式）', () {
      final w = parseWeekly(_weeklyFixture());
      expect(
          weeklyCopyText(w),
          '这一周的回忆周报（2026-11-09 至 2026-11-15）\n'
          '这一周，你们一起写下了 6 段回忆、7 张照片，有 3 天留下了痕迹。\n'
          '记录 6 条 · 照片 7 张 · 有记录 3 天\n'
          '喜欢 5 次 · 留言与评论 3 条');
    });
  });

  group('② 数据看板页', () {
    testWidgets('四联卡 + 愿望进度（Math.round 口径）+ 记录构成/心情分布行',
        (tester) async {
      final adapter = _FakeAdapter((options, i) {
        expect(options.uri.path, '/api/dashboard');
        return _json(_dashboardFixture());
      });
      final container = await _setup(adapter);
      await _pump(tester, container, page: const DashboardPage());

      // 四联卡：在一起 100 天 / 共同记录 42 条 / 照片 5 张 / 互动 9 次
      expect(find.text('在一起'), findsOneWidget);
      expect(find.text('100'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('5'), findsOneWidget); // 照片（夹具数字互不重样）
      expect(find.text('9'), findsOneWidget); // likes 6 + comments 3
      // 愿望进度（30%：3/10 Math.round；Text.rich 断言整行明文）
      Text wishText = tester.widget<Text>(find.byWidgetPredicate(
          (w) => w is Text &&
              (w.textSpan?.toPlainText() ?? '').contains('已实现')));
      expect(wishText.textSpan?.toPlainText(), '已实现 3 / 10 个共同愿望');
      expect(find.text('完成度 30%'), findsOneWidget);
      // 记录构成（数量降序）
      expect(find.text('时光动态'), findsOneWidget);
      expect(find.text('20'), findsOneWidget);
      expect(find.text('私密日记'), findsOneWidget);
      // 心情分布/互动小结在视口外（ListView 懒构建）——滚到可见再断言
      await tester.scrollUntilVisible(find.text('😊'), 250);
      expect(find.text('😊'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('留言与评论'), 250);
      // 互动小结（喜欢 / 留言与评论）
      expect(find.text('喜欢'), findsOneWidget);
      expect(find.text('留言与评论'), findsOneWidget);
    });

    testWidgets('days_together=null → 在一起显示 —（Web 同口径）', (tester) async {
      final adapter = _FakeAdapter(
          (options, i) => _json(_dashboardFixture(daysTogether: null)));
      final container = await _setup(adapter);
      await _pump(tester, container, page: const DashboardPage());
      expect(find.text('—'), findsOneWidget);
    });
  });

  group('③ 回忆周报页', () {
    testWidgets('hero 文案 + 四联卡 + 下一周禁用 + 上一周 offset=-1 重拉',
        (tester) async {
      final adapter = _FakeAdapter((options, i) {
        expect(options.uri.path, '/api/weekly');
        return _json(_weeklyFixture());
      });
      final container = await _setup(adapter);
      await _pump(tester, container, page: const WeeklyPage());

      // hero
      expect(find.text('这一周，你们一起写下了 6 段回忆、7 张照片，有 3 天留下了痕迹。'),
          findsOneWidget);
      expect(find.text('比上一周多写了 2 条 · 这周最常见的心情是 😊'),
          findsOneWidget);
      expect(find.text('🔥 已连续记录 2 天'), findsOneWidget);
      // 范围标签
      expect(find.text('2026 年 · 11.09 – 11.15'), findsOneWidget);
      // 四联卡：记录 6 / 有记录的天数 3 / 照片 7 / 互动 8（夹具数字唯一）
      expect(find.text('6'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      expect(find.text('8'), findsOneWidget); // likes 5 + comments 3
      // 记录构成 / 心情分布
      expect(find.text('时光动态'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('😊'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      // 本周精选在视口外（ListView 懒构建）——滚到可见再断言
      await tester.scrollUntilVisible(find.text('第一场电影'), 250);
      expect(find.text('第一场电影'), findsOneWidget);
      expect(find.text('看完吃了火锅'), findsOneWidget);
      // 下一周在 offset>=0 禁用（Web disabled 同口径）
      final nextBtn = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.chevron_right_rounded));
      expect(nextBtn.onPressed, isNull);
      // 上一周 → offset=-1 重拉
      adapter.requests.clear();
      await tester.tap(find.byTooltip('上一周'));
      await tester.pumpAndSettle();
      expect(
          adapter.requests,
          anyElement(predicate<RequestOptions>((r) =>
              r.uri.path == '/api/weekly' &&
              '${r.queryParameters['offset']}' == '-1')));
    });

    testWidgets('上一周后上次记录行 + 下一周恢复 + 复制文字版 → 剪贴板 4 行',
        (tester) async {
      final adapter = _FakeAdapter((options, i) => _json(_weeklyFixture(
          offset: int.parse('${options.queryParameters['offset'] ?? 0}'),
          streak: 0,
          lastRecordDaysAgo: 3,
          topMood: null)));
      final container = await _setup(adapter);
      await _pump(tester, container, page: const WeeklyPage());

      // 翻到上一周：last_record_days_ago=3、无 top_mood
      await tester.tap(find.byTooltip('上一周'));
      await tester.pumpAndSettle();
      expect(find.text('上次记录在 3 天前'), findsOneWidget);
      expect(find.textContaining('这周最常见的心情是'), findsNothing);
      // 上一周(offset=-1) 的下一周恢复可用
      final nextBtn = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.chevron_right_rounded));
      expect(nextBtn.onPressed, isNotNull);

      // 复制文字版 → 剪贴板（mock platform channel 捕获）
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = ((call.arguments as Map)['text'] ?? '').toString();
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      // 复制按钮在页尾（ListView 懒构建）——滚到可见再点
      await tester.scrollUntilVisible(find.text('复制文字版'), 250);
      await tester.tap(find.text('复制文字版'));
      await tester.pumpAndSettle();
      // 此前已切到上一周：label 跟随 offset（fixture 按 offset 返回）
      expect(
          copied,
          '上一周的回忆周报（2026-11-09 至 2026-11-15）\n'
          '这一周，你们一起写下了 6 段回忆、7 张照片，有 3 天留下了痕迹。\n'
          '记录 6 条 · 照片 7 张 · 有记录 3 天\n'
          '喜欢 5 次 · 留言与评论 3 条');
      // 冲洗 toast 的 2.2s 自毁 Timer（不冲测试 teardown 报 timersPending）
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });
  });

  group('④ hub 两卡', () {
    testWidgets('hub 增补「数据看板」「回忆周报」两张卡', (tester) async {
      final adapter = _FakeAdapter((options, i) {
        if (options.uri.path == '/api/me') return _json(_meFixture);
        return _json(<Object>[]);
      });
      final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
        ..httpClientAdapter = adapter;
      final container = ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
        mediaCookieHeadersProvider
            .overrideWith((ref) async => <String, String>{}),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: TogetherPage(active: true)),
      ));
      await tester.pumpAndSettle();
      // ListView 懒构建：末尾两卡在视口外，滚到可见再断言
      await tester.scrollUntilVisible(find.text('数据看板'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('数据看板'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('回忆周报'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('回忆周报'), findsOneWidget);
    });
  });
}
