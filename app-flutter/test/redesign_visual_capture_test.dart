// 主要页面真改版式令 · 视觉截图捕获套件（393×859 手机视口 × 浅/深双主题）。
// 纪律：
// · 默认跳过（不影响常规 flutter test / CI）；传入
//   `--dart-define=CAPTURE_REDESIGN=true --update-goldens` 时在 `../output/改版截图/` 生成 PNG；
// · 不使用 pumpAndSettle（避免呼吸灯/脉冲/循环动画阻塞），固定推进 4 帧即截；
// · 外层包 TickerMode(enabled: false) 关掉全部循环动画；
// · 页面数据全用内存桩 + StubAuthNotifier + FakeDioAdapter，绝不连真接口/真 SSE/原生通道；
// · 每用例 20 秒硬超时。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/sse/sse_client.dart'
    show SseEvent, sseEventsProvider;
import 'package:love_space/core/theme/app_icons.dart';
import 'package:love_space/core/theme/tokens.dart';
import 'package:love_space/core/ui/apple_ui.dart';
import 'package:love_space/features/album/album_page.dart';
import 'package:love_space/features/auth/auth_state.dart';
import 'package:love_space/features/home/home_page.dart';
import 'package:love_space/features/settings/settings_home_page.dart';
import 'package:love_space/features/settings/settings_state.dart'
    show themeSeedColor;
import 'package:love_space/features/shell/web_chrome.dart';
import 'package:love_space/features/timeline/timeline_page.dart';
import 'package:love_space/features/together/peer_hub_page.dart';
import 'package:love_space/features/together/together_page.dart';

const bool _doCapture = bool.fromEnvironment('CAPTURE_REDESIGN');

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final FutureOr<ResponseBody> Function(RequestOptions options) handler;
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

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: const ['application/json']
      },
    );

final _stubMe = MeData(
  user: const SpaceUser(
    id: 'u1',
    name: '小禾',
    username: 'xiaohe',
    admin: true,
  ),
  users: const [
    SpaceUser(id: 'u1', name: '小禾', username: 'xiaohe', admin: true),
    SpaceUser(id: 'u2', name: '阿远', username: 'ayuan'),
  ],
  spaceName: '我们的小屋',
  spaceRaw: const {
    'id': 's1',
    'name': '我们的小屋',
    'since': '2024-01-14',
    'cover': '',
  },
  spaceSince: '2024-01-14',
  unread: 2,
  chatUnread: 1,
  paired: true,
);

class _StubAuthNotifier extends AuthNotifier {
  @override
  AuthPhase build() {
    me = _stubMe;
    return AuthPhase.authed;
  }

  @override
  Future<void> reload() async {
    me = _stubMe;
  }
}

Map<String, dynamic> _peerStatusJson() {
  final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
  return {
    'peer': {
      'user_id': 'u2',
      'name': '阿远',
      'lat': 22.5176,
      'lng': 113.9438,
      'acc': 12.0,
      'speed': 0.2,
      'battery': 64,
      'charging': false,
      'net': 'wifi',
      'wifi_ssid': 'MixC_Guest_5G',
      'place_name': '万象城 · 南山粤海街区',
      'updated': now - 45,
      'screen_on': true,
      'closed_off': false,
    },
    'mine': {
      'user_id': 'u1',
      'name': '小禾',
      'lat': 22.5661,
      'lng': 114.0545,
      'acc': 10.0,
      'speed': 0.0,
      'battery': 84,
      'charging': true,
      'net': 'wifi',
      'wifi_ssid': 'Home_5G',
      'place_name': '家 · 梅林一村街区',
      'updated': now - 20,
      'screen_on': true,
      'closed_off': false,
    },
    'peer_share': {
      'location': true,
      'track': true,
      'events': true,
      'usage': true,
    },
  };
}

Map<String, dynamic> _peerTrackJson() {
  final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
  final base = now - 3600 * 6;
  return {
    'date': '2026-11-27',
    'peer': {
      'level': 'exact',
      'closed_off': false,
      'distance_m': 18400,
      'points': [
        {'ts': base, 'lat': 22.5661, 'lng': 114.0545, 'speed': 0.8},
        {'ts': base + 900, 'lat': 22.5540, 'lng': 114.0220, 'speed': 9.5},
        {'ts': base + 1800, 'lat': 22.5405, 'lng': 113.9880, 'speed': 12.2},
        {'ts': base + 3600, 'lat': 22.5310, 'lng': 113.9560, 'speed': 1.1},
        {'ts': base + 7200, 'lat': 22.5230, 'lng': 113.9480, 'speed': 6.4},
        {'ts': now - 1560, 'lat': 22.5176, 'lng': 113.9438, 'speed': 0.2},
      ],
      'stays': [
        {
          'lat': 22.5661,
          'lng': 114.0545,
          'arrived_at': base - 3600,
          'left_at': base,
          'duration_sec': 3600,
          'place_name': '家',
        },
        {
          'lat': 22.5310,
          'lng': 113.9560,
          'arrived_at': base + 3600,
          'left_at': base + 6900,
          'duration_sec': 3300,
          'place_name': '科技园',
        },
        {
          'lat': 22.5176,
          'lng': 113.9438,
          'arrived_at': now - 1560,
          'left_at': null,
          'duration_sec': 1560,
          'place_name': '万象城',
        },
      ],
    },
    'mine': {
      'level': 'exact',
      'closed_off': false,
      'distance_m': 4200,
      'points': [
        {'ts': base, 'lat': 22.5661, 'lng': 114.0545, 'speed': 0.5},
        {'ts': now - 600, 'lat': 22.5690, 'lng': 114.0590, 'speed': 0.1},
      ],
      'stays': [
        {
          'lat': 22.5661,
          'lng': 114.0545,
          'arrived_at': base,
          'left_at': null,
          'duration_sec': 7200,
          'place_name': '家',
        },
      ],
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
        {
          'app': '高德地图',
          'start_ts': now - 1800,
          'end_ts': now - 1320,
          'duration_sec': 480,
        },
      ],
      'top_apps': [
        {'app': '微信', 'duration_sec': 5820},
        {'app': '抖音', 'duration_sec': 3420},
        {'app': '小红书', 'duration_sec': 2100},
        {'app': '高德地图', 'duration_sec': 1380},
        {'app': '网易云音乐', 'duration_sec': 960},
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
      'sessions': [
        {
          'app': '微信',
          'start_ts': now - 420,
          'end_ts': now,
          'duration_sec': 420,
          'live': true,
        },
      ],
      'top_apps': [
        {'app': '微信', 'duration_sec': 4200},
      ],
      'network_events': [
        {'ts': now - 3600, 'net': 'wifi', 'ssid': 'Home_5G'},
      ],
    },
  };
}

Map<String, dynamic> _peerEventsJson() {
  final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
  return {
    'date': '2026-11-27',
    'peer_closed_off': false,
    'items': [
      {
        'id': 'ev1',
        'author': 'u2',
        'kind': 'manual',
        'scene': 'arrived',
        'summary': '到达万象城 · 南山粤海街区',
        'ts': now - 1560,
        'acks': <Object>[],
      },
      {
        'id': 'ev2',
        'author': 'u1',
        'kind': 'manual',
        'scene': 'home',
        'summary': '到家了 · 连上 Home_5G',
        'ts': now - 4200,
        'acks': <Object>[],
      },
    ],
  };
}

Map<String, dynamic> _peerSettingsJson() => {
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
    };

Map<String, dynamic> _peerAuditJson() {
  final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
  return {
    'items': [
      {
        'ts': now - 7200,
        'actor_name': '阿远',
        'summary': '位置与轨迹设为「精确轨迹」',
      },
      {
        'ts': now - 14400,
        'actor_name': '小禾',
        'summary': '已开启敏感软件自动脱敏（2 项）',
      },
    ],
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
      'id': 'a1',
      'kind': 'anniversary',
      'author': 'u1',
      'date': '2024-01-14',
      'body': {'title': '相恋三周年', 'date': '2024-01-14', 'annual': true},
      'created': now - 86400 * 30,
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
      'comments': <Object>[],
    },
    {
      'id': 'p2',
      'kind': 'post',
      'author': 'u1',
      'date': todayIso,
      'body': {
        'title': '周末手作咖啡',
        'content': '拉花虽然歪了一点，但味道很香。',
      },
      'created': now - 86400,
      'media': <Object>[],
      'likes': ['u2'],
      'comments': <Object>[],
    },
  ];
}

Future<void> _loadChineseFont() async {
  const candidates = [
    r'C:\Windows\Fonts\msyh.ttc',
    r'C:\Windows\Fonts\msyh.ttf',
    r'C:\Windows\Fonts\simhei.ttf',
  ];
  for (final path in candidates) {
    final f = File(path);
    if (f.existsSync()) {
      final bytes = await f.readAsBytes();
      final loader = FontLoader('Roboto')
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      return;
    }
  }
}

Dio _buildStubDio() => Dio(
      BaseOptions(
        baseUrl: 'https://test.local',
        validateStatus: api.validateAppStatus,
      ),
    )..httpClientAdapter = _FakeAdapter((o) {
        final p = o.uri.path;
        if (p == '/api/records') return _json(_recordsJson());
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
        if (p == '/api/peer/events') return _json(_peerEventsJson());
        if (p == '/api/peer/state-daily') {
          return _json({'peer': <String, Object?>{}, 'mine': <String, Object?>{}});
        }
        if (p == '/api/peer/settings') return _json(_peerSettingsJson());
        if (p == '/api/peer/policy-audit') return _json(_peerAuditJson());
        if (p == '/api/status') {
          return _json({'version': '2.8.6', 'apk_version': '2.8.6'});
        }
        return _json(<String, Object>{});
      });

/// 纯视觉壳层预览（呈现真实 AppleGlassAppBar + ApplePageBackground + WebDock，
/// 绝不启动真 SSE / NotifyCoordinator / PackageInfo）。
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

Future<void> _capturePage(
  WidgetTester tester, {
  required String filename,
  required Widget child,
  required bool dark,
}) async {
  final dio = _buildStubDio();
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      authProvider.overrideWith(_StubAuthNotifier.new),
      api.dioProvider.overrideWith((ref) async => dio),
      api.baseProvider.overrideWith((ref) async => 'https://test.local'),
      sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    ],
  );
  addTearDown(container.dispose);

  final seed = themeSeedColor('rose', '', dark: dark);
  final brightness = dark ? Brightness.dark : Brightness.light;
  final theme = ThemeData(
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    ),
    useMaterial3: true,
  );

  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => child),
    ],
  );
  addTearDown(router.dispose);

  tester.view.devicePixelRatio = 2.0;
  tester.view.physicalSize = const Size(393 * 2, 859 * 2);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    TickerMode(
      enabled: false,
      child: UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: theme,
          routerConfig: router,
        ),
      ),
    ),
  );

  // 固定推进 4 帧即截（不等页面静止，绝不卡死）
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));

  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('../../output/改版截图/$filename'),
  );
}

void main() {
  if (!_doCapture || !Platform.isWindows) {
    test('redesign visual capture skipped without --dart-define=CAPTURE_REDESIGN=true',
        () {});
    return;
  }

  setUpAll(() async {
    final outDir = Directory(r'..\output\改版截图');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    await _loadChineseFont();
  });

  final pages = <(String, Widget Function())>[
    ('home', () => _glassShellPreview(const HomePage(), 0)),
    ('timeline', () => _glassShellPreview(const TimelinePage(active: true), 1)),
    ('album', () => _glassShellPreview(const AlbumPage(active: true), 2)),
    ('together', () => _glassShellPreview(const TogetherPage(active: true), 3)),
    ('settings_home', () => const SettingsHomePage()),
    ('peer_today', () => const PeerHubPage(initialTab: 0)),
    ('peer_track', () => const PeerHubPage(initialTab: 1)),
    ('peer_phone', () => const PeerHubPage(initialTab: 2)),
    ('peer_settings', () => const PeerHubPage(initialTab: 3)),
  ];

  for (final (name, builder) in pages) {
    for (final dark in [false, true]) {
      final mode = dark ? 'dark' : 'light';
      testWidgets(
        'capture ${name}_$mode',
        (tester) async {
          await _capturePage(
            tester,
            filename: '${name}_$mode.png',
            child: builder(),
            dark: dark,
          );
        },
        timeout: const Timeout(Duration(seconds: 20)),
      );
    }
  }
}
