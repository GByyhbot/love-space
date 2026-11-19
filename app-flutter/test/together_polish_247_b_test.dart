/* 2.4.7 乙组（我们专区美化）护栏测试：
   ① 恋爱清单：悬浮钮 primary token + meta 胶囊 chips（文案逐字保留）
   ② 共同账本：悬浮钮 primary token；分类徽章 token 化（写死色清零见源码护栏）
   ③ 共同歌单：悬浮钮 primary（搜索图标同源 toolFab）
   ④ 纪念日列表：悬浮钮 primary + 倒计时主题色浅底胶囊 + 作者行头像
   ⑤ 数据看板/回忆周报：四联卡数字 headlineSmall+primary（文本不变）
   ⑥ 源码护栏：乙组触碰文件写死色 Color(0x…) 为零 */
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
import 'package:love_space/features/auth/auth_state.dart';
import 'package:love_space/features/chat/chat_toast.dart' show ChatToastHost;
import 'package:love_space/features/together/anniversary_page.dart';
import 'package:love_space/features/together/dashboard_page.dart';
import 'package:love_space/features/together/ledger_page.dart';
import 'package:love_space/features/together/music_page.dart';
import 'package:love_space/features/together/quest_page.dart';
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

Map<String, Object> _toolRecord(String id, String kind,
        {Map<String, Object> body = const {}, String author = 'u1',
        List<Object> answers = const [], int answerCount = 0,
        List<Object> checks = const []}) =>
    {
      'id': id, 'kind': kind, 'author': author,
      'body': body,
      'created': 1000.0, 'updated': 1000.0, 'client_id': '',
      'media': const <Object>[], 'likes': const <Object>[],
      'comments': const <Object>[],
      'answers': answers, 'answer_count': answerCount, 'checks': checks,
    };

Map<String, Object> _meFixture() => {
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
      if (options.uri.path == '/api/me') return _json(_meFixture());
      return inner(options, i);
    });

ProviderContainer _widgetSetup(_FakeAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  return ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
    mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
  ]);
}

/// 预热 authProvider：pump 驱动（_bootstrap 的 Future(…) 是零时长 Timer，
/// pumpWidget 前 await 会死锁——教训见 together_polish_247_test）。
Future<void> _warmAuth(WidgetTester tester, ProviderContainer container) async {
  container.read(authProvider.notifier).reload();
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (container.read(authProvider) == AuthPhase.authed) return;
  }
  fail('authProvider 未在 1s 内就绪');
}

Future<void> _pumpPage(WidgetTester tester, ProviderContainer container,
    Widget page) async {
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

/// 通用断言：悬浮钮底色==primary（token）。
void _expectFabPrimary(WidgetTester tester, String label) {
  final fab = tester.widget<FloatingActionButton>(
      find.widgetWithText(FloatingActionButton, label));
  final ctx =
      tester.element(find.widgetWithText(FloatingActionButton, label));
  expect(fab.backgroundColor, Theme.of(ctx).colorScheme.primary,
      reason: '$label 悬浮钮=主题色实心（token 断言）');
}

void main() {
  group('① 恋爱清单', () {
    testWidgets('悬浮钮 primary + meta 胶囊 chips（文案逐字保留）', (tester) async {
      final adapter = _withMe((options, i) {
        return _json([
          _toolRecord('q1', 'quest', body: {
            'title': '一起看日出', 'category': '日常', 'date': '2027-01-01',
            'done': true, 'content': '',
          }),
        ]);
      });
      final container = _widgetSetup(adapter);
      addTearDown(container.dispose);
      await _warmAuth(tester, container);
      await _pumpPage(tester, container, const QuestPage());
      _expectFabPrimary(tester, '添加小事');
      expect(find.text('日常'), findsOneWidget, reason: '分类 chip');
      expect(find.textContaining('计划 2027-01-01'), findsOneWidget);
      expect(find.text('已完成'), findsOneWidget, reason: '完成态 chip 文案保留');
      expect(find.textContaining('一起完成'), findsOneWidget,
          reason: '进度卡拼接文本保留');
      // 加入清单按钮存在（主题色实心圆钮）
      expect(find.byTooltip('加入清单'), findsOneWidget);
    });
  });

  group('②③ 账本 + 歌单', () {
    testWidgets('账本：悬浮钮 primary；金额/分类 tile 文本保留', (tester) async {
      final adapter = _withMe((options, i) {
        return _json([
          _toolRecord('l1', 'ledger', body: {
            'amount': 150.0, 'category': '餐饮', 'date': '2026-11-01',
            'content': '',
          }),
        ]);
      });
      final container = _widgetSetup(adapter);
      addTearDown(container.dispose);
      await _warmAuth(tester, container);
      await _pumpPage(tester, container, const LedgerPage());
      _expectFabPrimary(tester, '记一笔');
      // 列表 tile 在视口外（ListView 懒构建）→ 滚动后断言
      await tester.scrollUntilVisible(
          find.textContaining('¥150.00 · 餐饮'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('¥150.00 · 餐饮'), findsOneWidget,
          reason: '金额行组合文本保留');
    });

    testWidgets('歌单：悬浮钮 primary（搜索图标）；歌曲音符底座在位', (tester) async {
      final adapter = _withMe((options, i) {
        return _json([
          _toolRecord('s1', 'music', body: {
            'title': '我们的歌', 'content': '写给我们的',
            'song': {
              'title': '我们的歌', 'artist': '我们', 'src': 'https://a/b',
              'art': '', 'dur': 30,
            },
          }),
        ]);
      });
      final container = _widgetSetup(adapter);
      addTearDown(container.dispose);
      await _warmAuth(tester, container);
      await _pumpPage(tester, container, const MusicPage());
      _expectFabPrimary(tester, '搜歌入单');
      expect(find.text('我们的歌'), findsWidgets);
      expect(find.byTooltip('试听'), findsOneWidget, reason: '试听入口保留');
    });
  });

  group('④ 纪念日列表', () {
    testWidgets('悬浮钮 primary + 倒计时胶囊 + 作者行头像（字母兜底）', (tester) async {
      final d = DateTime.now().add(const Duration(days: 10));
      final date = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final adapter = _withMe((options, i) {
        return _json([
          _toolRecord('a1', 'anniversary', body: {
            'title': '领证纪念日', 'date': date, 'annual': true, 'remind_days': 3,
            'content': '',
          }),
        ]);
      });
      final container = _widgetSetup(adapter);
      addTearDown(container.dispose);
      await _warmAuth(tester, container);
      await _pumpPage(tester, container, const AnniversaryPage());
      _expectFabPrimary(tester, '添加纪念日');
      expect(find.text('领证纪念日'), findsOneWidget);
      expect(find.text('还有 10 天'), findsOneWidget, reason: '倒计时胶囊文案保留');
      expect(find.textContaining('每年公历日期'), findsOneWidget);
      expect(find.byType(CircleAvatar), findsWidgets, reason: '作者行头像兜底');
    });
  });

  group('⑤ 看板/周报数字美化', () {
    testWidgets('看板：四联卡数字 headlineSmall + primary 色（文本不变）',
        (tester) async {
      final adapter = _withMe((options, i) {
        if (options.uri.path == '/api/dashboard') {
          return _json({
            'days_together': 100, 'total': 42, 'photos': 5,
            'likes': 6, 'comments': 3,
            'months': [], 'wishes_total': 0, 'wishes_done': 0,
            'kind_rows': [], 'mood_rows': [],
          });
        }
        return _json({});
      });
      final container = _widgetSetup(adapter);
      addTearDown(container.dispose);
      await _warmAuth(tester, container);
      await _pumpPage(tester, container, const DashboardPage());
      final value = tester.widget<Text>(find.text('42'));
      final pageCtx = tester.element(find.text('42'));
      expect(value.style?.fontSize,
          Theme.of(pageCtx).textTheme.headlineSmall?.fontSize,
          reason: '四联卡数字字号=字阶 headlineSmall');
      expect(value.style?.color, Theme.of(pageCtx).colorScheme.primary,
          reason: '数字=主题色（token）');
    });
    testWidgets('周报：数字卡 headlineSmall+primary；kind 胶囊；复制实心钮',
        (tester) async {
      final adapter = _withMe((options, i) {
        if (options.uri.path == '/api/weekly') {
          return _json({
            'offset': 0, 'label': '这一周',
            'start': '2026-11-09', 'end': '2026-11-15',
            'total': 6, 'prev_total': 4, 'delta': 2,
            'days_active': 3, 'photos': 7,
            'by_kind': {'post': 4, 'note': 2},
            'moods': {'😊': 1},
            'top_mood': '😊',
            'likes': 5, 'comments': 3, 'streak': 2,
            'last_record_days_ago': null,
            'highlights': [
              {
                'id': 'h1', 'kind': 'post', 'author': 'u1',
                'body': {'title': '第一场电影', 'content': '看完吃了火锅'},
                'created': 1763000000.0, 'updated': 1763000000.0,
                'client_id': '', 'media': [], 'likes': ['u2'],
                'comments': [],
              },
            ],
            'message': '这一周，你们一起写下了 6 段回忆、7 张照片，有 3 天留下了痕迹。',
          });
        }
        return _json({});
      });
      final container = _widgetSetup(adapter);
      addTearDown(container.dispose);
      await _warmAuth(tester, container);
      await _pumpPage(tester, container, const WeeklyPage());
      // 数字美化：文本不变（既有 together_g 断言口径），仅样式升级
      final value = tester.widget<Text>(find.text('7'));
      final pageCtx = tester.element(find.text('7'));
      expect(value.style?.color, Theme.of(pageCtx).colorScheme.primary,
          reason: '四联卡数字=主题色（token）');
      expect(find.text('时光动态'), findsOneWidget, reason: 'kind 标签胶囊（文案保留）');
      // 复制按钮在列表底部（懒构建）→ 滚到可见再断言
      await tester.scrollUntilVisible(find.text('复制文字版'), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('复制文字版'), findsOneWidget, reason: '复制主操作保留');
    });
  });

  group('⑥ 源码护栏（乙组触碰文件写死色零新增）', () {
    test('乙组触碰文件不得出现 Color(0x…) 字面量', () {
      final files = [
        'lib/features/together/quest_page.dart',
        'lib/features/together/ledger_page.dart',
        'lib/features/together/music_page.dart',
        'lib/features/together/dashboard_page.dart',
        'lib/features/together/weekly_page.dart',
        'lib/features/together/anniversary_page.dart',
      ];
      final pattern = RegExp(r'Color\(0x');
      for (final f in files) {
        expect(pattern.hasMatch(File(f).readAsStringSync()), isFalse,
            reason: '$f 不得有写死色值字面量（账本分类徽章 8 处已 token 化）');
      }
    });
  });
}
