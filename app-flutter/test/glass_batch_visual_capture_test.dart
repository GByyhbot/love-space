import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import 'package:love_space/core/peer/peer_expected_state.dart';
import 'package:love_space/core/peer/peer_permissions.dart';
import 'package:love_space/core/sse/sse_client.dart'
    show SseClient, SseEvent, SsePhase, SseState, sseEventsProvider, sseProvider;
import 'package:love_space/features/auth/auth_state.dart';
import 'package:love_space/features/chat/chat_toast.dart'
    show ChatToastController, ChatToastMessage, ChatToastTone, chatToastProvider;
import 'package:love_space/features/home/home_page.dart';
import 'package:love_space/features/settings/settings_state.dart'
    show themeSeedColor;
import 'package:love_space/features/settings/settings_widgets.dart'
    show showFormSheet;
import 'package:love_space/features/shell/shell_page.dart';
import 'package:love_space/features/timeline/composer_sheet.dart'
    show showComposerSheet;
import 'package:love_space/features/timeline/photo_upload_sheet.dart'
    show showPhotoUploadSheet;
import 'package:love_space/features/together/calendar_page.dart';
import 'package:love_space/features/together/ledger_page.dart';
import 'package:love_space/features/together/peer_hub_page.dart';
import 'package:love_space/main.dart' show buildAppTheme;

const bool _doCapture = bool.fromEnvironment('CAPTURE_GLASS_BATCH');

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final Object Function(RequestOptions o) handler;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody.fromString(
        jsonEncode(handler(options)),
        200,
        headers: {Headers.contentTypeHeader: const ['application/json']},
      );
}

class _StubAuth extends AuthNotifier {
  @override
  AuthPhase build() {
    me = MeData(
      user: const SpaceUser(id: 'u1', name: '小禾', username: 'u1'),
      users: const [
        SpaceUser(id: 'u1', name: '小禾', username: 'u1'),
        SpaceUser(id: 'u2', name: '阿远', username: 'u2'),
      ],
      spaceName: '小禾与阿远的空间',
      spaceRaw: const <String, dynamic>{
        'name': '小禾与阿远的空间',
        'theme': 'rose',
        'since': '2024-01-14',
      },
      spaceSince: '2024-01-14',
    );
    return AuthPhase.authed;
  }
}

class _FakeSse extends SseClient {
  @override
  SseState build() => const SseState(phase: SsePhase.connected);
  @override
  void start() {}
}

class _NoTimerToast extends ChatToastController {
  @override
  void show(String text, {ChatToastTone tone = ChatToastTone.info}) {
    state = ChatToastMessage(id: 1, text: text, tone: tone);
  }
}

Future<void> _loadChineseFont() async {
  final loader = FontLoader('Roboto');
  var loaded = false;
  for (final p in const [
    r'C:\Windows\Fonts\msyh.ttc',
    r'C:\Windows\Fonts\msyhbd.ttc',
    r'C:\Windows\Fonts\msyh.ttf',
    r'C:\Windows\Fonts\simhei.ttf',
  ]) {
    final f = File(p);
    if (f.existsSync()) {
      final bytes = await f.readAsBytes();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
      loaded = true;
    }
  }
  if (loaded) await loader.load();
}

void _setupMocks() {
  SharedPreferences.setMockInitialValues(<String, Object>{
    kPeerExpectedKey: true,
    kFirstInstallPermGuideDoneKey: true,
  });
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('peer_loc/native'),
    (call) async => switch (call.method) {
      'status' => <String, Object?>{'running': true, 'receiving': true, 'received': 12},
      'permissions' => <String, Object?>{
          'channelAvailable': true,
          'fine': true,
          'background': true,
          'usage': true,
          'notification': true,
          'batteryIgnored': true,
          'manufacturer': 'Xiaomi',
          'autoStartIntentSupported': true,
        },
      _ => true,
    },
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => call.method == 'read' ? 'test-token' : null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/package_info'),
    (call) async => <String, Object?>{
      'appName': '恋爱空间',
      'packageName': 'cn.iepose.lovespace.love_space',
      'version': '2.8.6',
      'buildNumber': '286',
      'buildSignature': '',
    },
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('cn.iepose.lovespace/amap_config'),
    (call) async => call.method == 'hasApiKey' ? false : null,
  );
}

Dio _buildStubDio() {
  final now = DateTime.now();
  final nowSec = now.millisecondsSinceEpoch / 1000.0;
  final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
  final todayIso = '$month-${now.day.toString().padLeft(2, '0')}';
  return Dio(
    BaseOptions(
      baseUrl: 'https://test.local',
      validateStatus: api.validateAppStatus,
    ),
  )..httpClientAdapter = _FakeAdapter((o) {
      final p = o.uri.path;
      if (p == '/api/me') {
        return {
          'user': {'id': 'u1', 'name': '小禾', 'username': 'u1', 'avatar': ''},
          'users': [
            {'id': 'u1', 'name': '小禾', 'username': 'u1', 'avatar': ''},
            {'id': 'u2', 'name': '阿远', 'username': 'u2', 'avatar': ''},
          ],
          'space': {
            'name': '小禾与阿远的空间',
            'theme': 'rose',
            'since': '2024-01-14',
          },
          'unread': 1,
          'chat_unread': 0,
        };
      }
      if (p == '/api/calendar') {
        return {
          'month': month,
          'days': {
            '06': {
              'anniversaries': [
                {'title': '领证两周年'},
              ],
              'moods': [
                {'author': 'u1', 'emoji': '🥰'},
              ],
              'posts': const [],
              'checks': const [],
            },
            '15': {
              'anniversaries': [
                {'title': '第一次一起看海'},
              ],
              'moods': [
                {'author': 'u1', 'emoji': '😊'},
                {'author': 'u2', 'emoji': '☀️'},
              ],
              'posts': [
                {'title': '傍晚散步遇见晚霞'},
              ],
              'checks': [
                {'user': 'u1'},
                {'user': 'u2'},
              ],
            },
            '22': {
              'anniversaries': const [],
              'moods': const [],
              'posts': [
                {'title': '手作草莓蛋糕'},
              ],
              'checks': [
                {'user': 'u1'},
              ],
            },
          },
        };
      }
      if (p == '/api/records') {
        final kind = o.uri.queryParameters['kind'] ?? '';
        if (kind == 'album') {
          return [
            {
              'id': 'al1',
              'kind': 'album',
              'author': 'u1',
              'body': {'title': '海边旅行', 'media': const []},
              'created': nowSec - 86400,
              'media': const [],
            },
          ];
        }
        return [
          {
            'id': 'm1',
            'kind': 'mood',
            'author': 'u2',
            'date': todayIso,
            'body': {'emoji': '🥰', 'content': '微风很舒服'},
            'created': nowSec - 3600,
            'media': const [],
          },
          {
            'id': 'l1',
            'kind': 'ledger',
            'author': 'u1',
            'date': todayIso,
            'body': {
              'amount': 68.5,
              'category': '餐饮',
              'date': todayIso,
              'content': '晚安奶茶',
            },
            'created': nowSec - 1800,
            'media': const [],
          },
        ];
      }
      if (p == '/api/dashboard') {
        return {'days_together': 1050, 'posts': 129, 'photos': 345};
      }
      if (p == '/api/yearbook') {
        return {
          'year': now.year,
          'is_current': true,
          'total': 186,
          'photos': 345,
          'mood_days': 94,
          'wishes_done': 18,
          'anniversaries': 6,
          'moods': 142,
          'active_days': 120,
          'streak': 21,
          'interactions': 640,
          'by_kind': const <String, int>{},
        };
      }
      if (p == '/api/peer/report-presets') {
        return [
          {'scene': 'home', 'emoji': '🏠', 'label': '到家了', 'summary': '到家了', 'push': true},
          {'scene': 'eat', 'emoji': '🍜', 'label': '吃饭中', 'summary': '在吃饭', 'push': false},
        ];
      }
      if (p == '/api/peer/status') {
        return {
          'revision': 18,
          'peer': {
            'enabled': true,
            'closed_off': false,
            'location': {
              'lat': 22.5236,
              'lng': 113.9408,
              'updated': nowSec - 90,
              'acc': 10.0,
              'battery': 76,
              'charging': true,
              'net': 'wifi',
              'wifi': 'MixC_Guest_5G',
              'state_updated': nowSec - 45,
              'place_name': '万象天地 · 南山',
            },
            'current_app': {'app': '微信', 'since': nowSec - 240},
            'policy': {'location_level': 'exact'},
          },
          'mine': {
            'settings': {'events': true},
            'location': {
              'lat': 22.5311,
              'lng': 113.9522,
              'updated': nowSec - 60,
              'battery': 90,
              'place_name': '家 · 科技园',
            },
            'policy': {'location_level': 'exact'},
          },
        };
      }
      if (p == '/api/peer/track') {
        return {
          'date': todayIso,
          'peer': {
            'level': 'exact',
            'closed_off': false,
            'distance_m': 3850,
            'points': [
              {'lat': 22.5311, 'lng': 113.9522, 'ts': nowSec - 7200, 'speed': 0.0},
              {'lat': 22.5270, 'lng': 113.9460, 'ts': nowSec - 5400, 'speed': 3.5},
              {'lat': 22.5236, 'lng': 113.9408, 'ts': nowSec - 3600, 'speed': 0.0},
              {'lat': 22.5236, 'lng': 113.9408, 'ts': nowSec - 120, 'speed': 0.0},
            ],
            'stays': [
              {
                'lat': 22.5311,
                'lng': 113.9522,
                'arrived_at': nowSec - 14400,
                'left_at': nowSec - 7200,
                'duration_sec': 7200,
                'place_name': '家',
              },
              {
                'lat': 22.5236,
                'lng': 113.9408,
                'arrived_at': nowSec - 3600,
                'duration_sec': 3480,
                'place_name': '',
              },
            ],
          },
          'mine': {'level': 'exact', 'closed_off': false, 'points': const []},
        };
      }
      if (p == '/api/peer/events') {
        return {
          'date': todayIso,
          'mine': const [],
          'peer': {
            'closed_off': false,
            'events': [
              {
                'id': 'b4',
                'user': 'u2',
                'type': 'state.battery',
                'ts': nowSec - 60,
                'summary': '',
                'payload': {'level': 61, 'charging': true},
              },
              {
                'id': 'b3',
                'user': 'u2',
                'type': 'state.battery',
                'ts': nowSec - 660,
                'summary': '',
                'payload': {'level': 71, 'charging': true},
              },
              {
                'id': 'b2',
                'user': 'u2',
                'type': 'state.battery',
                'ts': nowSec - 1200,
                'summary': '',
                'payload': {'level': 82, 'charging': true},
              },
              {
                'id': 'b1',
                'user': 'u2',
                'type': 'state.battery',
                'ts': nowSec - 1560,
                'summary': '',
                'payload': {'level': 92, 'charging': true},
              },
              {
                'id': 'm1',
                'user': 'u2',
                'type': 'manual_report',
                'ts': nowSec - 2100,
                'summary': '到达万象天地',
                'note': '到了先点杯喝的',
                'place_name': '万象天地',
              },
              {
                'id': 'u2_ev',
                'user': 'u2',
                'type': 'state.unlock',
                'ts': nowSec - 2600,
                'summary': '',
                'payload': {'count': 4},
              },
              {
                'id': 'u1_ev',
                'user': 'u2',
                'type': 'state.unlock',
                'ts': nowSec - 2900,
                'summary': '',
                'payload': {'count': 3},
              },
            ],
          },
        };
      }
      if (p == '/api/peer/usage-daily') {
        return {
          'date': todayIso,
          'peer': {
            'hidden': false,
            'screen_sec': 12400,
            'delta_sec': 900,
            'unlocks': 41,
            'longest_session_sec': 2100,
          },
          'mine': {'hidden': false, 'screen_sec': 9200},
        };
      }
      return const <String, Object?>{};
    });
}

Future<void> _capture(
  WidgetTester tester, {
  required String filename,
  required Widget child,
  required bool dark,
  Future<void> Function(WidgetTester tester)? afterPump,
}) async {
  _setupMocks();
  final dio = _buildStubDio();
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      authProvider.overrideWith(_StubAuth.new),
      api.dioProvider.overrideWith((ref) async => dio),
      api.baseProvider.overrideWith((ref) async => 'https://test.local'),
      chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
      mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
      api.cookieJarProvider.overrideWith((ref) async {
        throw StateError('test: no cookie jar');
      }),
      sseProvider.overrideWith(_FakeSse.new),
      sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
      chatToastProvider.overrideWith(_NoTimerToast.new),
    ],
  );
  addTearDown(container.dispose);

  final seed = themeSeedColor('rose', '', dark: dark);
  final brightness = dark ? Brightness.dark : Brightness.light;
  final theme = buildAppTheme(seed, brightness);
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => child),
      GoRoute(
        path: '/settings/peer-share',
        builder: (_, _) => const PeerHubPage(initialTab: 3),
      ),
    ],
  );
  addTearDown(router.dispose);

  tester.view.devicePixelRatio = 2.0;
  tester.view.physicalSize = const Size(393 * 2, 859 * 2);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: theme,
        routerConfig: router,
      ),
    ),
  );

  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 280));

  if (afterPump != null) {
    await afterPump(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pump(const Duration(milliseconds: 250));
  }

  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('../../output/玻璃批截图/$filename'),
  );

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

Widget _launcher(void Function(BuildContext ctx) onOpen) {
  return Builder(
    builder: (ctx) => Scaffold(
      body: Center(
        child: FilledButton(
          key: const Key('glass-capture-open'),
          onPressed: () => onOpen(ctx),
          child: const Text('打开'),
        ),
      ),
    ),
  );
}

void main() {
  if (!_doCapture || !Platform.isWindows) {
    test(
      'glass batch visual capture skipped without --dart-define=CAPTURE_GLASS_BATCH=true',
      () {},
    );
    return;
  }

  setUpAll(() async {
    final outDir = Directory(r'..\output\玻璃批截图');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    await _loadChineseFont();
  });

  final cases = <(
    String,
    Widget Function(),
    Future<void> Function(WidgetTester)?,
  )>[
    ('calendar', () => const CalendarPage(), null),
    (
      'calendar_selected',
      () => const CalendarPage(),
      (tester) async {
        await tester.tap(find.text('15'));
      },
    ),
    (
      'form_sheet',
      () => _launcher((ctx) {
            showFormSheet(
              ctx,
              title: '添加小事',
              saveLabel: '记下来',
              cancelLabel: '取消',
              builder: (_) => const TextField(
                decoration: InputDecoration(hintText: '一起去做的一件小事'),
              ),
              onSave: (closeOk, _) => closeOk(),
            );
          }),
      (tester) async => tester.tap(find.byKey(const Key('glass-capture-open'))),
    ),
    (
      'ledger_sheet',
      () => const LedgerPage(),
      (tester) async => tester.tap(find.byTooltip('记一笔')),
    ),
    (
      'mood_sheet',
      () => const HomePage(),
      (tester) async => tester.tap(find.text('＋ 记一笔').first),
    ),
    (
      'photo_upload_sheet',
      () => _launcher((ctx) => showPhotoUploadSheet(ctx)),
      (tester) async => tester.tap(find.byKey(const Key('glass-capture-open'))),
    ),
    (
      'composer_sheet',
      () => _launcher((ctx) => showComposerSheet(ctx)),
      (tester) async => tester.tap(find.byKey(const Key('glass-capture-open'))),
    ),
    (
      'composer_drawer',
      () => const ShellPage(),
      (tester) async => tester.tap(find.byKey(const Key('shell-dock-handle'))),
    ),
    ('peer_track', () => const PeerHubPage(initialTab: 1), null),
    ('peer_today_timeline', () => const PeerHubPage(initialTab: 0), null),
    (
      'peer_today_timeline_expanded',
      () => const PeerHubPage(initialTab: 0),
      (tester) async {
        final fold =
            find.byKey(const Key('report-fold-state.battery_b4_b1'));
        await tester.ensureVisible(fold);
        await tester.tap(fold);
      },
    ),
  ];

  for (final (name, builder, hook) in cases) {
    for (final dark in [false, true]) {
      final mode = dark ? 'dark' : 'light';
      testWidgets(
        'capture ${name}_$mode',
        (tester) => _capture(
          tester,
          filename: '${name}_$mode.png',
          child: builder(),
          dark: dark,
          afterPump: hook,
        ),
        timeout: const Timeout(Duration(seconds: 30)),
      );
    }
  }
}
