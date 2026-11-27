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
import 'package:love_space/core/chat/chat_models.dart';
import 'package:love_space/core/chat/chat_state.dart';
import 'package:love_space/core/peer/peer_expected_state.dart';
import 'package:love_space/core/peer/peer_permissions.dart';
import 'package:love_space/core/sse/sse_client.dart'
    show SseClient, SseEvent, SsePhase, SseState, sseEventsProvider, sseProvider;
import 'package:love_space/core/theme/app_icons.dart';
import 'package:love_space/core/theme/tokens.dart';
import 'package:love_space/core/ui/apple_ui.dart';
import 'package:love_space/core/ui/selection_sheet.dart';
import 'package:love_space/features/album/album_page.dart';
import 'package:love_space/features/auth/auth_state.dart';
import 'package:love_space/features/chat/chat_toast.dart'
    show ChatToastController, ChatToastMessage, ChatToastTone, chatToastProvider;
import 'package:love_space/features/chat/messages_page.dart';
import 'package:love_space/features/home/home_page.dart';
import 'package:love_space/features/personal/personal_page.dart';
import 'package:love_space/features/settings/notify_settings_page.dart'
    show showXiaomiGuideSheet;
import 'package:love_space/features/settings/peer_permission_sheet.dart'
    show showPeerPermissionGuideSheet;
import 'package:love_space/features/settings/settings_home_page.dart';
import 'package:love_space/features/settings/settings_state.dart'
    show themeSeedColor;
import 'package:love_space/features/settings/settings_widgets.dart'
    show showFormSheet;
import 'package:love_space/features/shell/shell_page.dart';
import 'package:love_space/features/shell/web_chrome.dart';
import 'package:love_space/features/timeline/comment_sheet.dart';
import 'package:love_space/features/timeline/timeline_page.dart';
import 'package:love_space/features/together/peer_hub_page.dart';
import 'package:love_space/features/together/peer_poke_sheet.dart';
import 'package:love_space/features/together/together_page.dart';
import 'package:love_space/main.dart' show buildAppTheme;

const bool _doCapture = bool.fromEnvironment('CAPTURE_POLISH');

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions options) handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      handler(options);
}

ResponseBody _json(Object data) => ResponseBody.fromString(
      jsonEncode(data),
      200,
      headers: {Headers.contentTypeHeader: const ['application/json']},
    );

class _StubAuthNotifier extends AuthNotifier {
  @override
  AuthPhase build() {
    me = _sampleMe();
    return AuthPhase.authed;
  }
}

MeData _sampleMe() => MeData(
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

class _MemChatStore implements ChatPersistence {
  final records = <ChatRecord>[];
  final pendings = <String, ChatPending>{};
  @override
  Future<void> saveRecords(List<ChatRecord> rs) async => records.addAll(rs);
  @override
  Future<List<ChatRecord>> loadRecords() async => records;
  @override
  Future<void> upsertPending(ChatPending p) async => pendings[p.clientId] = p;
  @override
  Future<void> deletePending(String clientId) async => pendings.remove(clientId);
  @override
  Future<List<ChatPending>> loadPending() async => pendings.values.toList();
  @override
  Future<void> saveMySticker(String userId, String mid, String name) async {}
  @override
  Future<void> deleteMySticker(String userId, String mid) async {}
  @override
  Future<List<(String, String)>> loadMyStickers(String userId) async => const [];
}

Map<String, dynamic> _peerStatusJson() {
  final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
  return {
    'revision': 12,
    'peer': {
      'enabled': true,
      'closed_off': false,
      'location': {
        'lat': 22.5236,
        'lng': 113.9408,
        'updated': now - 90,
        'acc': 12.0,
        'battery': 82,
        'charging': false,
        'net': 'wifi',
        'wifi': 'MixC_Guest_5G',
        'state_updated': now - 45,
        'place_name': '万象城 · 南山粤海',
      },
      'current_app': {'app': '微信', 'since': now - 180},
      'halted': null,
      'policy': {
        'global_off': false,
        'paused_until': null,
        'location_level': 'exact',
        'usage_level': 'full',
        'app_level': 'stream',
        'network_level': 'ssid',
        'battery_on': true,
        'sensitive_apps': <String>[],
      },
    },
    'mine': {
      'settings': {'events': true},
      'location': {
        'lat': 22.5311,
        'lng': 113.9522,
        'updated': now - 60,
        'acc': 8.0,
        'battery': 91,
        'charging': true,
        'net': 'wifi',
        'wifi': 'Home_5G',
        'state_updated': now - 30,
        'place_name': '家 · 科技园',
      },
      'policy': {
        'global_off': false,
        'paused_until': null,
        'location_level': 'exact',
        'usage_level': 'full',
        'app_level': 'stream',
        'network_level': 'ssid',
        'battery_on': true,
        'sensitive_apps': ['招商银行', '系统相册'],
      },
    },
  };
}

Map<String, dynamic> _peerTrackJson() {
  final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
  return {
    'date': '2026-11-27',
    'peer': {
      'level': 'exact',
      'closed_off': false,
      'distance_m': 3850,
      'points': [
        {'lat': 22.5311, 'lng': 113.9522, 'ts': now - 7200},
        {'lat': 22.5270, 'lng': 113.9460, 'ts': now - 3600},
        {'lat': 22.5236, 'lng': 113.9408, 'ts': now - 90},
      ],
      'stays': [
        {
          'lat': 22.5311,
          'lng': 113.9522,
          'start_ts': now - 14400,
          'end_ts': now - 7200,
          'duration_sec': 7200,
          'place_name': '家',
        },
        {
          'lat': 22.5236,
          'lng': 113.9408,
          'start_ts': now - 3600,
          'end_ts': now - 90,
          'duration_sec': 3510,
          'place_name': '万象城',
        },
      ],
    },
    'mine': {
      'level': 'exact',
      'closed_off': false,
      'distance_m': 1200,
      'points': [
        {'lat': 22.5311, 'lng': 113.9522, 'ts': now - 3600},
      ],
      'stays': <Object>[],
    },
  };
}

Map<String, dynamic> _peerUsageJson() {
  final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
  return {
    'date': '2026-11-27',
    'peer': {
      'hidden': false,
      'screen_sec': 15960,
      'delta_sec': 1920,
      'unlocks': 52,
      'longest_session_sec': 2880,
      'hourly': [
        18, 28, 6, 0, 0, 0, 0, 14, 26, 15, 11, 18,
        36, 22, 12, 16, 14, 19, 25, 24, 0, 0, 0, 0,
      ],
      'current_app': {'app': '微信', 'since': now - 180},
      'sessions': [
        {
          'app': '微信',
          'start_ts': now - 180,
          'end_ts': now,
          'duration_sec': 180,
          'live': true,
        },
        {
          'app': '抖音',
          'start_ts': now - 720,
          'end_ts': now - 180,
          'duration_sec': 540,
        },
      ],
      'top_apps': [
        {'app': '微信', 'duration_sec': 5820},
        {'app': '抖音', 'duration_sec': 3420},
        {'app': '小红书', 'duration_sec': 2100},
      ],
      'network_events': [
        {'ts': now - 1440, 'net': 'wifi', 'ssid': 'MixC_Guest_5G'},
        {'ts': now - 3360, 'net': 'mobile', 'ssid': ''},
      ],
    },
    'mine': {
      'hidden': false,
      'screen_sec': 11880,
      'delta_sec': -840,
      'unlocks': 38,
      'longest_session_sec': 2040,
      'hourly': [
        12, 8, 0, 0, 0, 0, 0, 10, 22, 14, 9, 12,
        28, 16, 10, 12, 14, 18, 16, 15, 0, 0, 0, 0,
      ],
      'sessions': <Object>[],
      'top_apps': <Object>[],
      'network_events': <Object>[],
    },
  };
}

List<Map<String, dynamic>> _recordsJson() {
  final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
  final today = DateTime.now();
  final todayIso =
      '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
  return [
    {
      'id': 'm1',
      'kind': 'mood',
      'author': 'u1',
      'date': todayIso,
      'body': {'emoji': '😊', 'text': '今天风很温柔'},
      'created': now - 1800,
      'media': <Object>[],
      'likes': <Object>[],
      'comments': <Object>[],
    },
    {
      'id': 'm2',
      'kind': 'mood',
      'author': 'u2',
      'date': todayIso,
      'body': {'emoji': '🥰', 'text': '晚上一起吃好吃的'},
      'created': now - 1200,
      'media': <Object>[],
      'likes': <Object>[],
      'comments': <Object>[],
    },
    {
      'id': 'p1',
      'kind': 'post',
      'author': 'u2',
      'date': todayIso,
      'body': {
        'title': '傍晚散步遇见晚霞',
        'content': '下班一起走回家的路上，天空突然变成温柔的橘粉色，随手记下来。',
      },
      'created': now - 3600,
      'media': <Object>[],
      'likes': ['u1'],
      'comments': [
        {
          'id': 'c1',
          'author': 'u1',
          'text': '超好看！',
          'created': now - 1500,
        },
      ],
    },
    {
      'id': 'c_msg1',
      'kind': 'chat',
      'author': 'u2',
      'body': {'content': '下班了吗？今晚吃寿喜烧好不好～'},
      'created': now - 600,
      'updated': now - 600,
      'client_id': '',
      'media': <Object>[],
    },
    {
      'id': 'c_msg2',
      'kind': 'chat',
      'author': 'u1',
      'body': {'content': '刚出地铁！我顺路买杯热的杨枝甘露带回去。'},
      'created': now - 300,
      'updated': now - 300,
      'client_id': '',
      'media': <Object>[],
    },
  ];
}

Future<void> _loadChineseFont() async {
  final loader = FontLoader('Roboto');
  var loaded = false;
  for (final path in const [
    r'C:\Windows\Fonts\msyh.ttc',
    r'C:\Windows\Fonts\msyhbd.ttc',
    r'C:\Windows\Fonts\msyh.ttf',
    r'C:\Windows\Fonts\simhei.ttf',
  ]) {
    final f = File(path);
    if (f.existsSync()) {
      final bytes = await f.readAsBytes();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
      loaded = true;
    }
  }
  if (loaded) await loader.load();
}

void _setupMethodChannelMocks({bool missingPerms = false}) {
  SharedPreferences.setMockInitialValues(<String, Object>{
    kPeerExpectedKey: true,
    kFirstInstallPermGuideDoneKey: true,
  });
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('peer_loc/native'),
    (call) async {
      switch (call.method) {
        case 'status':
          return <String, Object?>{
            'running': true,
            'receiving': true,
            'received': 18,
          };
        case 'permissions':
          return <String, Object?>{
            'channelAvailable': true,
            'fine': !missingPerms,
            'background': !missingPerms,
            'usage': !missingPerms,
            'notification': true,
            'batteryIgnored': !missingPerms,
            'manufacturer': 'Xiaomi',
            'autoStartIntentSupported': true,
          };
        case 'diagnostics':
          return <String, Object?>{
            'channelAvailable': true,
            'manufacturer': 'Xiaomi',
            'loc': {'running': true, 'received': 18, 'queue': 0, 'reported': 18, 'dropped': 0},
            'state': {'enabled': true, 'emitted': 12},
            'usage': {'granted': !missingPerms, 'enabled': true, 'emitted': 8},
            'permissions': {
              'channelAvailable': true,
              'fine': !missingPerms,
              'background': !missingPerms,
              'usage': !missingPerms,
              'notification': true,
              'batteryIgnored': !missingPerms,
              'manufacturer': 'Xiaomi',
              'autoStartIntentSupported': true,
            },
          };
        default:
          return true;
      }
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

Dio _buildStubDio() => Dio(
      BaseOptions(
        baseUrl: 'https://test.local',
        validateStatus: api.validateAppStatus,
      ),
    )..httpClientAdapter = _FakeAdapter((o) {
        final p = o.uri.path;
        if (p == '/api/me') {
          return _json({
            'user': {'id': 'u1', 'name': '小禾', 'username': 'u1', 'avatar': ''},
            'users': [
              {'id': 'u1', 'name': '小禾', 'username': 'u1', 'avatar': ''},
              {'id': 'u2', 'name': '阿远', 'username': 'u2', 'avatar': ''},
            ],
            'space': {'name': '小禾与阿远的空间', 'theme': 'rose', 'since': '2024-01-14'},
            'unread': 2,
            'chat_unread': 1,
          });
        }
        if (p == '/api/records') {
          final kind = o.uri.queryParameters['kind'] ?? '';
          final all = _recordsJson();
          if (kind == 'chat') {
            return _json(all.where((e) => e['kind'] == 'chat').toList());
          }
          if (kind == 'diary') {
            return _json([
              {
                'id': 'd1',
                'kind': 'diary',
                'author': 'u1',
                'date': '2026-11-27',
                'body': {'title': '今日份安稳', 'content': '认真打磨完每一个弹层和对比度。'},
                'created': DateTime.now().millisecondsSinceEpoch / 1000.0 - 900,
              }
            ]);
          }
          return _json(all);
        }
        if (p == '/api/dashboard') {
          return _json({'days_together': 1049, 'posts': 128, 'photos': 342});
        }
        if (p == '/api/yearbook') {
          return _json({
            'year': 2026,
            'is_current': true,
            'total': 186,
            'photos': 342,
            'mood_days': 94,
            'wishes_done': 18,
            'anniversaries': 6,
            'moods': 142,
            'active_days': 120,
            'streak': 21,
            'interactions': 640,
            'by_kind': <String, int>{},
          });
        }
        if (p == '/api/on-this-day') return _json(<Object>[]);
        if (p == '/api/albums') {
          return _json([
            {'id': 'al1', 'name': '海边旅行', 'count': 24, 'cover': ''},
            {'id': 'al2', 'name': '日常美食', 'count': 41, 'cover': ''},
          ]);
        }
        if (p == '/api/photos') return _json(<Object>[]);
        if (p == '/api/peer/report-presets') {
          return _json([
            {'scene': 'home', 'emoji': '🏠', 'label': '到家了', 'summary': '到家了', 'push': true},
            {'scene': 'eat', 'emoji': '🍜', 'label': '吃饭中', 'summary': '在吃饭', 'push': false},
            {'scene': 'commute', 'emoji': '🚇', 'label': '在路上', 'summary': '在通勤路上', 'push': false},
            {'scene': 'sleep', 'emoji': '🌙', 'label': '准备睡了', 'summary': '准备睡觉啦', 'push': true},
          ]);
        }
        if (p == '/api/peer/status') return _json(_peerStatusJson());
        if (p == '/api/peer/track') return _json(_peerTrackJson());
        if (p == '/api/peer/usage-daily') return _json(_peerUsageJson());
        if (p == '/api/peer/events') {
          final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
          return _json({
            'date': '2026-11-27',
            'peer_closed_off': false,
            'items': [
              {
                'id': 'ev1',
                'author': 'u2',
                'kind': 'manual',
                'scene': 'arrived',
                'summary': '到达万象城 · 南山粤海',
                'ts': now - 1560,
                'acks': <Object>[],
              },
            ],
          });
        }
        if (p == '/api/peer/state-daily') {
          return _json({'peer': <String, Object?>{}, 'mine': <String, Object?>{}});
        }
        if (p == '/api/peer/settings') {
          return _json({
            'location': true,
            'track': true,
            'events': true,
            'usage': true,
            'policy': {
              'global_off': false,
              'paused_until': null,
              'location_level': 'exact',
              'usage_level': 'full',
              'app_level': 'stream',
              'network_level': 'ssid',
              'battery_on': true,
              'sensitive_apps': ['招商银行', '系统相册'],
            },
          });
        }
        if (p == '/api/peer/policy-audit') return _json({'items': <Object>[]});
        if (p == '/api/status') {
          return _json({'version': '2.8.6', 'apk_version': '2.8.6'});
        }
        return _json(<String, Object>{});
      });

Widget _glassShellPreview(Widget page, int tabIndex) {
  return Builder(builder: (context) {
    final theme = Theme.of(context);
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight;
    return Scaffold(
      backgroundColor: appleCanvasColor(theme),
      extendBodyBehindAppBar: true,
      appBar: AppleGlassAppBar(
        actions: [
          WebTopIconButton(
            tooltip: '通知',
            onPressed: () {},
            icon: Icons.notifications_none_rounded,
            badge: const WebBadge('2'),
          ),
          const SizedBox(width: ChromeMetrics.topBtnGap),
          WebTopIconButton(
            tooltip: '私聊',
            onPressed: () {},
            icon: Icons.chat_bubble_outline_rounded,
            badge: const WebBadge('1'),
          ),
          const SizedBox(width: ChromeMetrics.topBtnGap),
          WebTopIconButton(
            tooltip: '设置',
            onPressed: () {},
            icon: AppIcons.settings,
          ),
          const SizedBox(width: ChromeMetrics.topBtnGap),
          WebAvatarButton(
            onPressed: () {},
            initial: '禾',
            avatarId: '',
          ),
          const SizedBox(width: Spacing.xs),
        ],
      ),
      body: ApplePageBackground(
        child: Stack(
          children: [
            Positioned.fill(
              child: ShellChromeScope(topInset: topInset, child: page),
            ),
            Positioned(
              left: ChromeMetrics.dockInset,
              right: ChromeMetrics.dockInset,
              bottom: ChromeMetrics.dockInset,
              child: WebDock(
                currentIndex: tabIndex,
                onTab: (_) {},
                onOpenDrawer: () {},
              ),
            ),
          ],
        ),
      ),
    );
  });
}

Future<void> _capture(
  WidgetTester tester, {
  required String filename,
  required Widget child,
  required bool dark,
  bool missingPerms = false,
  Future<void> Function(WidgetTester tester)? afterPump,
}) async {
  _setupMethodChannelMocks(missingPerms: missingPerms);
  final dio = _buildStubDio();
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      authProvider.overrideWith(_StubAuthNotifier.new),
      api.dioProvider.overrideWith((ref) async => dio),
      api.baseProvider.overrideWith((ref) async => 'https://test.local'),
      chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
      mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
      chatPersistenceProvider.overrideWith((ref) async => _MemChatStore()),
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

  // 推进异步 FutureProvider 与初始过渡动画帧
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
    matchesGoldenFile('../../output/精修截图/$filename'),
  );

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

Widget _launcher(Future<void> Function(BuildContext ctx, WidgetRef ref) open) {
  return _glassShellPreview(
    Consumer(
      builder: (ctx, ref, _) => Center(
        child: FilledButton(
          key: const Key('capture-open-btn'),
          onPressed: () => open(ctx, ref),
          child: const Text('打开'),
        ),
      ),
    ),
    0,
  );
}

void main() {
  if (!_doCapture || !Platform.isWindows) {
    test(
      'polish visual capture skipped without --dart-define=CAPTURE_POLISH=true',
      () {},
    );
    return;
  }

  setUpAll(() async {
    final outDir = Directory(r'..\output\精修截图');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    await _loadChineseFont();
  });

  // 1. 主界面与子页（浅色 + 深色各一）
  final pages = <(
    String,
    Widget Function(),
    Future<void> Function(WidgetTester)?,
  )>[
    ('home', () => _glassShellPreview(const HomePage(), 0), null),
    ('timeline', () => _glassShellPreview(const TimelinePage(active: true), 1), null),
    ('album', () => _glassShellPreview(const AlbumPage(active: true), 2), null),
    ('together', () => _glassShellPreview(const TogetherPage(active: true), 3), null),
    ('personal', () => _glassShellPreview(const PersonalPage(), 4), null),
    ('settings_home', () => const SettingsHomePage(), null),
    (
      'messages_plus_panel',
      () => const MessagesPage(),
      (tester) async {
        await tester.tap(find.byTooltip('更多'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      },
    ),
    ('peer_today', () => const PeerHubPage(initialTab: 0), null),
    ('peer_track', () => const PeerHubPage(initialTab: 1), null),
    ('peer_phone', () => const PeerHubPage(initialTab: 2), null),
    ('peer_settings', () => const PeerHubPage(initialTab: 3), null),
  ];

  for (final (name, builder, hook) in pages) {
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
        timeout: const Timeout(Duration(seconds: 25)),
      );
    }
  }

  // 2. 关键弹层（浅色 + 深色）
  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';
    testWidgets(
      'capture composer_drawer_$mode',
      (tester) => _capture(
        tester,
        filename: 'composer_drawer_$mode.png',
        child: const ShellPage(),
        dark: dark,
        afterPump: (tester) async {
          await tester.tap(find.byKey(const Key('shell-dock-handle')));
        },
      ),
      timeout: const Timeout(Duration(seconds: 25)),
    );

    testWidgets(
      'capture first_install_perm_sheet_$mode',
      (tester) => _capture(
        tester,
        filename: 'first_install_perm_sheet_$mode.png',
        missingPerms: true,
        child: _launcher(
          (ctx, _) => showPeerPermissionGuideSheet(
            ctx,
            isFirstInstall: true,
            initialSnapshot: const PeerPermissionSnapshot(
              fine: true,
              background: false,
              usage: false,
              notification: true,
              batteryIgnored: false,
              manufacturer: 'Xiaomi',
              autoStartIntentSupported: true,
              channelAvailable: true,
            ),
          ),
        ),
        dark: dark,
        afterPump: (tester) async {
          await tester.tap(find.byKey(const Key('capture-open-btn')));
        },
      ),
      timeout: const Timeout(Duration(seconds: 25)),
    );
  }

  // 3. 其余全量弹窗 / 抽屉 / 菜单（浅色）
  final lightSheets = <(
    String,
    Widget Function(),
    Future<void> Function(WidgetTester),
  )>[
    (
      'selection_sheet_light',
      () => _launcher(
            (ctx, _) => showSelectionSheet<String>(
              context: ctx,
              title: '选择轨迹精度',
              selected: 'exact',
              options: const [
                SelectionOption(
                  value: 'exact',
                  label: '精确轨迹 · 实时展示轨迹曲线与停留点',
                ),
                SelectionOption(
                  value: 'street',
                  label: '街区概览 · 仅显示常去地点与大致区域',
                ),
                SelectionOption(
                  value: 'off',
                  label: '暂不共享 · 双方均停止上报实时位置',
                ),
              ],
            ),
          ),
      (tester) async => tester.tap(find.byKey(const Key('capture-open-btn'))),
    ),
    (
      'form_sheet_light',
      () => _launcher(
            (ctx, _) => showFormSheet(
              ctx,
              title: '编辑空间昵称',
              saveLabel: '保存修改',
              builder: (_) => TextFormField(
                initialValue: '小禾与阿远的小窝',
                decoration: const InputDecoration(labelText: '空间名称'),
              ),
              onSave: (closeOk, _) => closeOk(),
            ),
          ),
      (tester) async => tester.tap(find.byKey(const Key('capture-open-btn'))),
    ),
    (
      'report_compose_sheet_light',
      () => _glassShellPreview(const HomePage(), 0),
      (tester) async {
        await tester.longPress(find.text('到家了').first);
      },
    ),
    (
      'peer_poke_sheet_light',
      () => _launcher((ctx, ref) => showPeerPokeSheet(ctx, ref)),
      (tester) async => tester.tap(find.byKey(const Key('capture-open-btn'))),
    ),
    (
      'xiaomi_guide_sheet_light',
      () => _launcher((ctx, _) => showXiaomiGuideSheet(ctx)),
      (tester) async => tester.tap(find.byKey(const Key('capture-open-btn'))),
    ),
    (
      'comment_sheet_light',
      () => _launcher(
            (ctx, _) => showCommentSheet(ctx, rid: 'p1', me: _sampleMe()),
          ),
      (tester) async => tester.tap(find.byKey(const Key('capture-open-btn'))),
    ),
    (
      'confirm_dialog_light',
      () => _launcher(
            (ctx, _) => showDialog<void>(
              context: ctx,
              builder: (dCtx) => AlertDialog(
                title: const Text('确认删除这条记录吗？'),
                content: const Text('删除后可在个人角落的回收站内找回。'),
                actions: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(dCtx).pop(),
                    child: const Text('先留着'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(dCtx).pop(),
                    child: const Text('移入回收站'),
                  ),
                ],
              ),
            ),
          ),
      (tester) async => tester.tap(find.byKey(const Key('capture-open-btn'))),
    ),
    (
      'chat_longpress_menu_light',
      () => _launcher(
            (ctx, _) => showMenu<String>(
              context: ctx,
              position: const RelativeRect.fromLTRB(120, 260, 40, 0),
              items: const [
                PopupMenuItem(value: 'reply', child: Text('引用回复')),
                PopupMenuItem(value: 'copy', child: Text('复制文字')),
                PopupMenuItem(value: 'sticker', child: Text('存为表情包')),
                PopupMenuItem(value: 'recall', child: Text('撤回消息')),
              ],
            ),
          ),
      (tester) async => tester.tap(find.byKey(const Key('capture-open-btn'))),
    ),
  ];

  for (final (name, builder, hook) in lightSheets) {
    testWidgets(
      'capture $name',
      (tester) => _capture(
        tester,
        filename: '$name.png',
        child: builder(),
        dark: false,
        afterPump: hook,
      ),
      timeout: const Timeout(Duration(seconds: 25)),
    );
  }
}
