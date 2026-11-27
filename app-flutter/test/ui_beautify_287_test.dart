import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import 'package:love_space/core/sse/sse_client.dart'
    show SseClient, SseEvent, SsePhase, SseState, sseEventsProvider, sseProvider;
import 'package:love_space/core/theme/app_icons.dart';
import 'package:love_space/core/theme/motion.dart';
import 'package:love_space/core/theme/tokens.dart';
import 'package:love_space/core/theme/typography.dart';
import 'package:love_space/features/album/album_page.dart';
import 'package:love_space/features/auth/auth_state.dart';
import 'package:love_space/features/chat/chat_toast.dart'
    show ChatToastController, ChatToastMessage, ChatToastTone, chatToastProvider;
import 'package:love_space/features/home/home_page.dart';
import 'package:love_space/features/personal/personal_page.dart';
import 'package:love_space/features/timeline/timeline_page.dart';
import 'package:love_space/features/together/anniversary_page.dart';
import 'package:love_space/features/together/together_page.dart';

class _StubAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path == '/api/me') {
      return _json(<String, Object?>{
        'user': <String, Object?>{
          'id': 'u1',
          'name': '林晚晚（超长测试昵称检查不溢出）',
          'username': 'u1',
        },
        'users': <Object>[
          <String, Object?>{
            'id': 'u1',
            'name': '林晚晚（超长测试昵称检查不溢出）',
            'username': 'u1',
          },
          <String, Object?>{
            'id': 'u2',
            'name': '周屿白',
            'username': 'u2',
          },
        ],
        'space': <String, Object?>{
          'name': '我们的温柔小屋',
          'since': '2024-02-14',
        },
        'unread': 2,
        'chat_unread': 1,
      });
    }
    if (path == '/api/dashboard') {
      return _json(<String, Object?>{'days_together': 320, 'photos': 18});
    }
    if (path == '/api/records') {
      return _json(<Object>[
        <String, Object?>{
          'id': 'rec-post-1',
          'kind': 'post',
          'author': 'u1',
          'body': <String, Object?>{
            'date': '2026-11-27',
            'title': '周末散步时遇到的晚霞',
            'content': '风很轻，云像奶油一样铺在天边。',
            'media': <Object>[],
          },
          'created': 1795700000.0,
          'updated': 1795700000.0,
          'published': null,
          'client_id': 'cid-1',
          'media': <Object>[],
          'likes': <Object>['u2'],
          'comments': <Object>[],
        },
        <String, Object?>{
          'id': 'rec-ann-1',
          'kind': 'anniversary',
          'author': 'u1',
          'body': <String, Object?>{
            'title': '在一起两周年纪念日',
            'date': '2024-12-20',
            'annual': true,
            'remind_days': 3,
          },
          'created': 1795700000.0,
          'updated': 1795700000.0,
          'published': null,
          'client_id': 'cid-2',
          'media': <Object>[],
          'likes': <Object>[],
          'comments': <Object>[],
        },
      ]);
    }
    if (path == '/api/peer/report') {
      return _json(<String, Object?>{
        'status': null,
        'timeline': <Object>[],
        'sharing_paused': false,
      });
    }
    return _json(<Object>[]);
  }
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: const <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );

class _FakeSse extends SseClient {
  @override
  SseState build() => const SseState(phase: SsePhase.idle);

  @override
  void start() {}
}

class _NoTimerToastController extends ChatToastController {
  @override
  void show(String text, {ChatToastTone tone = ChatToastTone.info}) {
    state = ChatToastMessage(id: 1, text: text, tone: tone);
  }
}

Future<void> _pumpPage(
  WidgetTester tester,
  Widget page, {
  required Brightness brightness,
}) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = _StubAdapter();
  final container = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
    mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
    api.cookieJarProvider.overrideWith((ref) async {
      throw StateError('test: no cookie jar');
    }),
    sseProvider.overrideWith(_FakeSse.new),
    sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    chatToastProvider.overrideWith(_NoTimerToastController.new),
  ]);
  addTearDown(container.dispose);

  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(360, 780);
  addTearDown(tester.view.reset);

  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFFD86B86),
    brightness: brightness,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(colorScheme: scheme, useMaterial3: true),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              final phase = ref.watch(authProvider);
              if (phase != AuthPhase.authed) {
                return const SizedBox.shrink();
              }
              return page;
            },
          ),
        ),
      ),
    ),
  );
  // Trigger auth bootstrap cleanly inside FakeAsync by pumping frames.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(milliseconds: 100));
  expect(tester.takeException(), isNull);
}

void main() {
  test('Design Foundation tokens: Spacing/AppRadius/AppType/AppIcons/Motion', () {
    expect(Spacing.xs, 4);
    expect(Spacing.sm, 8);
    expect(Spacing.md, 12);
    expect(Spacing.lg, 16);
    expect(Spacing.xl, 20);
    expect(Spacing.xxl, 24);
    expect(Spacing.xxxl, 32);

    expect(AppRadius.small, 12);
    expect(AppRadius.medium, 16);
    expect(AppRadius.large, 20);
    expect(AppRadius.xl, 28);
    expect(AppRadius.concentric(20, 8), 12);
    expect(AppRadius.concentric(10, 8), 4);
    expect(AppTouch.minTarget, 44);

    expect(Motion.fast, const Duration(milliseconds: 120));
    expect(Motion.base, const Duration(milliseconds: 220));
    expect(Motion.medium, const Duration(milliseconds: 240));
    expect(Motion.slow, const Duration(milliseconds: 320));
    expect(Motion.gentle, const Duration(milliseconds: 380));

    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFD86B86)),
      useMaterial3: true,
    );
    expect(AppType.largeTitle(theme).letterSpacing, -0.4);
    expect(AppType.title(theme).letterSpacing, -0.2);
    expect(AppType.numeric(theme).fontFeatures, AppType.tabularFeatures);
    expect(AppIcons.chevronRight, Icons.chevron_right_rounded);
    expect(AppIcons.search, Icons.search_rounded);
  });

  group('甲三·主框架组 360dp × 深浅双主题零溢出', () {
    for (final b in <Brightness>[Brightness.light, Brightness.dark]) {
      final tag = b == Brightness.light ? 'light' : 'dark';
      testWidgets('HomePage 360dp-$tag', (tester) async {
        await _pumpPage(tester, const HomePage(), brightness: b);
        expect(find.text('我们的每一天'), findsOneWidget);
      });

      testWidgets('TimelinePage 360dp-$tag', (tester) async {
        await _pumpPage(tester, const TimelinePage(active: true), brightness: b);
        expect(find.text('时光慢慢，爱意满满'), findsOneWidget);
      });

      testWidgets('TogetherPage 360dp-$tag', (tester) async {
        await _pumpPage(tester, const TogetherPage(active: true), brightness: b);
        expect(find.text('关于我们，还有好多好多'), findsOneWidget);
      });
    }
  });

  group('甲三·内容组 360dp × 深浅双主题零溢出', () {
    for (final b in <Brightness>[Brightness.light, Brightness.dark]) {
      final tag = b == Brightness.light ? 'light' : 'dark';
      testWidgets('AlbumPage 360dp-$tag', (tester) async {
        await _pumpPage(tester, const AlbumPage(active: true), brightness: b);
        expect(find.text('把喜欢的瞬间，装进口袋'), findsOneWidget);
      });

      testWidgets('PersonalPage 360dp-$tag', (tester) async {
        await _pumpPage(tester, const PersonalPage(), brightness: b);
        expect(find.text('我的小角落'), findsOneWidget);
      });

      testWidgets('AnniversaryPage 360dp-$tag', (tester) async {
        await _pumpPage(tester, const AnniversaryPage(), brightness: b);
        expect(find.text('纪念日'), findsOneWidget);
      });
    }
  });
}
