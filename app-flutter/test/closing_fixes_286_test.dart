import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import 'package:love_space/core/peer/peer_expected_state.dart';
import 'package:love_space/core/peer/peer_locator.dart';
import 'package:love_space/core/peer/peer_permissions.dart';
import 'package:love_space/core/sse/sse_client.dart'
    show SseClient, SseEvent, SsePhase, SseState, sseEventsProvider, sseProvider;
import 'package:love_space/core/ui/apple_ui.dart';
import 'package:love_space/core/ui/liquid_glass.dart';
import 'package:love_space/features/auth/auth_state.dart'
    show AuthNotifier, AuthPhase, MeData, SpaceUser, authProvider;
import 'package:love_space/features/chat/chat_compose.dart';
import 'package:love_space/features/chat/chat_toast.dart'
    show ChatToastController, ChatToastMessage, ChatToastTone, chatToastProvider;
import 'package:love_space/features/home/home_page.dart';
import 'package:love_space/features/home/report_capsule_bar.dart';
import 'package:love_space/features/settings/notify_settings_page.dart'
    show showXiaomiGuideSheet;
import 'package:love_space/features/settings/settings_home_page.dart';
import 'package:love_space/features/shell/shell_page.dart';
import 'package:love_space/features/shell/web_chrome.dart' show WebDock;
import 'package:love_space/features/together/peer_phone_page.dart';
import 'package:love_space/features/together/peer_report_page.dart';
import 'package:love_space/features/together/peer_track_page.dart';
import 'package:love_space/features/together/together_page.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter();

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final data = switch (options.uri.path) {
      '/api/me' => _meJson(),
      '/api/records' => <Object>[],
      '/api/dashboard' => <String, Object>{
          'days_together': 100,
          'posts': 12,
          'photos': 34,
        },
      '/api/peer/report-presets' => <Object>[
          {
            'scene': 'home',
            'emoji': '🏠',
            'label': '到家了',
            'summary': '到家了',
            'push': true,
          },
        ],
      '/api/peer/events' => <String, Object?>{
          'date': '2026-11-27',
          'peer_closed_off': false,
          'items': <Object>[],
        },
      '/api/peer/status' => <String, Object?>{
          'date': '2026-11-27',
          'peer': <String, Object?>{'hidden': false, 'closed_off': false},
          'mine': <String, Object?>{'hidden': false, 'closed_off': false},
        },
      '/api/peer/track' => <String, Object?>{
          'date': '2026-11-27',
          'peer': <String, Object?>{
            'level': 'exact',
            'closed_off': false,
            'distance_m': 0,
            'points': <Object>[],
            'stays': <Object>[],
          },
          'mine': <String, Object?>{
            'level': 'exact',
            'closed_off': false,
            'distance_m': 0,
            'points': <Object>[],
            'stays': <Object>[],
          },
        },
      '/api/peer/usage-daily' => <String, Object?>{
          'date': '2026-11-27',
          'peer': <String, Object?>{'hidden': false, 'closed_off': false},
          'mine': <String, Object?>{'hidden': false, 'closed_off': false},
        },
      '/api/peer/settings' => <String, Object?>{
          'location': true,
          'track': true,
          'events': true,
          'usage': true,
          'policy': <String, Object?>{
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
      _ => <String, Object?>{},
    };
    return ResponseBody.fromString(
      jsonEncode(data),
      200,
      headers: {
        Headers.contentTypeHeader: const ['application/json'],
      },
    );
  }
}

Map<String, Object> _meJson() => {
      'user': {'id': 'u1', 'name': '我', 'username': 'u1', 'avatar': ''},
      'users': [
        {'id': 'u1', 'name': '我', 'username': 'u1', 'avatar': ''},
        {'id': 'u2', 'name': 'TA', 'username': 'u2', 'avatar': ''},
      ],
      'space': {'name': '小空间', 'since': '2024-01-01'},
      'unread': 0,
      'chat_unread': 0,
    };

class _FakeAuth extends AuthNotifier {
  @override
  AuthPhase build() {
    me = MeData(
      user: const SpaceUser(id: 'u1', name: '我', username: 'u1'),
      users: const [
        SpaceUser(id: 'u1', name: '我', username: 'u1'),
        SpaceUser(id: 'u2', name: 'TA', username: 'u2'),
      ],
      spaceName: '小空间',
      spaceRaw: const <String, dynamic>{},
      spaceSince: '2024-01-01',
    );
    return AuthPhase.authed;
  }
}

class _FakeSse extends SseClient {
  @override
  SseState build() => const SseState(phase: SsePhase.idle);
  @override
  void start() {}
}

class _NoTimerToast extends ChatToastController {
  @override
  void show(String text, {ChatToastTone tone = ChatToastTone.info}) {
    state = ChatToastMessage(id: 1, text: text, tone: tone);
  }
}

ProviderContainer _makeContainer() {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://test.local',
      validateStatus: api.validateAppStatus,
    ),
  )..httpClientAdapter = _FakeAdapter();
  return ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      api.dioProvider.overrideWith((ref) async => dio),
      chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
      mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
      api.cookieJarProvider.overrideWith((ref) async {
        throw StateError('test: no cookie jar');
      }),
      authProvider.overrideWith(_FakeAuth.new),
      sseProvider.overrideWith(_FakeSse.new),
      sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
      chatToastProvider.overrideWith(_NoTimerToast.new),
    ],
  );
}

const _peerLocChannel = MethodChannel('peer_loc/native');
const _secureStorageChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const _packageInfoChannel =
    MethodChannel('dev.fluttercommunity.plus/package_info');

void _mockPeerLoc({
  required bool running,
  required bool fine,
  required bool background,
  required bool usage,
  required bool notification,
  required bool batteryIgnored,
  List<MethodCall>? recorded,
}) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_secureStorageChannel, (call) async {
    if (call.method == 'read') return 'test-token';
    if (call.method == 'readAll') return <String, String>{'token': 'test-token'};
    return null;
  });
  messenger.setMockMethodCallHandler(_packageInfoChannel, (call) async {
    return <String, Object?>{
      'appName': '恋爱空间',
      'packageName': 'cn.iepose.lovespace.love_space',
      'version': '2.8.6',
      'buildNumber': '286',
      'buildSignature': '',
    };
  });
  messenger.setMockMethodCallHandler(_peerLocChannel, (call) async {
    recorded?.add(call);
    switch (call.method) {
      case 'status':
        return <String, Object?>{
          'running': running,
          'receiving': running,
          'received': 0,
        };
      case 'toggle':
        return <String, Object?>{
          'ok': true,
          'reason': '',
          'detail': <String, Object?>{},
        };
      case 'permissions':
        return <String, Object?>{
          'channelAvailable': true,
          'fine': fine,
          'background': background,
          'usage': usage,
          'notification': notification,
          'batteryIgnored': batteryIgnored,
          'manufacturer': 'Xiaomi',
          'autoStartIntentSupported': true,
        };
      case 'diagnostics':
        return <String, Object?>{
          'channelAvailable': true,
          'manufacturer': 'Xiaomi',
        };
      default:
        return true;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_peerLocChannel, null);
    messenger.setMockMethodCallHandler(_secureStorageChannel, null);
    messenger.setMockMethodCallHandler(_packageInfoChannel, null);
  });

  group('第 1 项：轨迹页离开防原生 SIGABRT 与生命周期析构顺序', () {
    test('AmapTrackPlatformView 按暂停→摘除→单次销毁重排，且保留 353db8e 预载', () {
      final kt = File(
        'android/app/src/main/kotlin/cn/iepose/lovespace/love_space/AmapTrackPlatformView.kt',
      ).readAsStringSync();
      expect(kt.contains('AtomicBoolean(false)'), isTrue);
      expect(kt.contains('disposed.compareAndSet(false, true)'), isTrue);
      expect(kt.contains('AmapPreload'), isTrue);
      expect(kt.contains('initOnMainThread'), isTrue);
      expect(kt.contains('System.loadLibrary("AMapSDK_MAP_v9_8_3")'), isTrue);

      final idxPause = kt.indexOf('mv.onPause()');
      final idxRemove = kt.indexOf('container.removeView(mv)');
      final idxDestroy = kt.indexOf('mv.onDestroy()');
      expect(idxPause, greaterThan(-1));
      expect(idxRemove, greaterThan(idxPause));
      expect(idxDestroy, greaterThan(idxRemove));
    });

    test('AndroidManifest 关闭原生堆指针标记避免 libAMapSDK TBI free abort', () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(
        manifest.contains('android:allowNativeHeapPointerTagging="false"'),
        isTrue,
      );
    });
  });

  group('第 2 项：位置共享开关持久化绑定与冷启动自恢复', () {
    testWidgets('期望开但采集未运行时，设置页开关仍保持开启态', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kPeerExpectedKey: true,
      });
      _mockPeerLoc(
        running: false,
        fine: true,
        background: true,
        usage: true,
        notification: true,
        batteryIgnored: true,
      );
      final container = _makeContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: PeerVerifyCard()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final sw = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(sw.value, isTrue);
    });

    test('冷启动 resumeIfExpected=true 且期望开+实态停时自动恢复 toggle(true)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kPeerExpectedKey: true,
      });
      final calls = <MethodCall>[];
      _mockPeerLoc(
        running: false,
        fine: true,
        background: true,
        usage: true,
        notification: true,
        batteryIgnored: true,
        recorded: calls,
      );

      await peerLocatorAutoStart(resumeIfExpected: true);
      expect(
        calls.any((c) =>
            c.method == 'toggle' &&
            (c.arguments as Map)['enable'] == true),
        isTrue,
      );
    });

    test('期望关时不触发自动 toggle(true)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kPeerExpectedKey: false,
      });
      final calls = <MethodCall>[];
      _mockPeerLoc(
        running: false,
        fine: true,
        background: true,
        usage: true,
        notification: true,
        batteryIgnored: true,
        recorded: calls,
      );

      await peerLocatorAutoStart(resumeIfExpected: true);
      expect(calls.where((c) => c.method == 'toggle'), isEmpty);
    });
  });

  group('第 3 项：设置主页移除「伴侣共享与守护」入口', () {
    testWidgets('设置主页不再出现「伴侣共享与守护」行，且保留有效路由跳转', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      _mockPeerLoc(
        running: false,
        fine: true,
        background: true,
        usage: true,
        notification: true,
        batteryIgnored: true,
      );
      final container = _makeContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SettingsHomePage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const Key('settings-home-peer-share')), findsNothing);
      expect(find.text('伴侣共享与守护'), findsNothing);

      final mainSrc = File('lib/main.dart').readAsStringSync();
      expect(mainSrc.contains("path: '/settings/peer-share'"), isTrue);
      expect(mainSrc.contains('PeerHubPage(initialTab: 3)'), isTrue);
    });
  });

  group('第 4 项：首次安装主动权限引导弹层', () {
    test('首次标记未完成且权限缺失时判定需弹窗，标记后不再触发', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      const missingSnap = PeerPermissionSnapshot(
        channelAvailable: true,
        fine: false,
        background: false,
        usage: false,
        notification: false,
        batteryIgnored: false,
        manufacturer: 'Xiaomi',
        autoStartIntentSupported: true,
      );
      expect(await shouldShowFirstInstallPermissionGuide(missingSnap), isTrue);
      await markFirstInstallPermissionGuideDone();
      expect(await shouldShowFirstInstallPermissionGuide(missingSnap), isFalse);
    });

    testWidgets('首次安装挂载 ShellPage 自动弹出权限引导；二次进入不重复弹',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      _mockPeerLoc(
        running: false,
        fine: false,
        background: false,
        usage: false,
        notification: false,
        batteryIgnored: false,
      );
      final container1 = _makeContainer();
      addTearDown(container1.dispose);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(393, 840);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container1,
          child: const MaterialApp(home: ShellPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byKey(const Key('peer-perm-prompt-sheet')), findsOneWidget);

      // 关闭首装弹窗后，二次挂载新 MaterialApp（同一持久化状态）不再自动弹出
      await tester.tap(find.byKey(const Key('peer-perm-prompt-later')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const Key('peer-perm-prompt-sheet')), findsNothing);

      final container2 = _makeContainer();
      addTearDown(container2.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          key: const ValueKey('second-mount'),
          container: container2,
          child: const MaterialApp(
            key: ValueKey('second-app'),
            home: ShellPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const Key('peer-perm-prompt-sheet')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('第 5 & 6 项：弹层统一规范、聊天+面板去双层描边、浅色对比度', () {
    test('全局主题禁用重复系统抓手 & messages_page 移除外层冗余 ClipRRect(24)', () {
      final mainSrc = File('lib/main.dart').readAsStringSync();
      final msgSrc = File('lib/features/chat/messages_page.dart').readAsStringSync();
      expect(mainSrc.contains('showDragHandle: false'), isTrue);
      expect(msgSrc.contains('borderRadius: BorderRadius.circular(24)'), isFalse);
    });

    testWidgets('Xiaomi 引导弹层使用非透明 AppleSheetContainer，且聊天+面板展示 16 枚徽章',
        (tester) async {
      final container = _makeContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Builder(
              builder: (ctx) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showXiaomiGuideSheet(ctx),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(AppleSheetContainer), findsOneWidget);
      expect(find.text('小米手机放行三步'), findsOneWidget);
      expect(find.text('自启动'), findsOneWidget);
    });

    testWidgets('聊天+面板单层描边与 16 枚 AppleIconBadge', (tester) async {
      final container = _makeContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [ChatCompose()],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add_circle_outline_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('fn-panel-surface')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('fn-panel-surface')),
          matching: find.byType(AppleIconBadge),
        ),
        findsNWidgets(16),
      );
    });

    test('浅色对比度护栏：移除低对比度 Colors.amber 并加强分段/胶囊文本边界', () {
      final settingsSrc =
          File('lib/features/settings/settings_home_page.dart').readAsStringSync();
      final lgSrc = File('lib/core/ui/liquid_glass.dart').readAsStringSync();
      final hubSrc =
          File('lib/features/together/peer_hub_page.dart').readAsStringSync();
      expect(RegExp(r'\bColors\.amber\b').hasMatch(settingsSrc), isFalse);
      expect(lgSrc.contains('cs.onSurfaceVariant'), isTrue);
      expect(hubSrc.contains('cs.onSurfaceVariant'), isTrue);
    });

    testWidgets('浅色模式下核心胶囊与底栏渲染正常', (tester) async {
      final container = _makeContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData.light(useMaterial3: true),
            home: Scaffold(
              body: Column(
                children: [
                  LiquidPillSegmented<int>(
                    segments: const [
                      LiquidPillSegment(value: 0, label: '今日'),
                      LiquidPillSegment(value: 1, label: '本周'),
                    ],
                    selected: 0,
                    onChanged: (_) {},
                  ),
                  const ReportCapsuleBar(),
                  WebDock(
                    currentIndex: 0,
                    onTab: (_) {},
                    onOpenDrawer: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('本周'), findsOneWidget);
      expect(find.byType(ReportCapsuleBar), findsOneWidget);
      expect(find.byType(WebDock), findsOneWidget);
    });
  });

  group('第 7 项：下拉刷新指示器顶栏避让 (edgeOffset == topInset)', () {
    Future<void> verifyEdgeOffset(WidgetTester tester, Widget page) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      _mockPeerLoc(
        running: false,
        fine: true,
        background: true,
        usage: true,
        notification: true,
        batteryIgnored: true,
      );
      final container = _makeContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: ShellChromeScope(
              topInset: 96,
              child: page,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final indicators = tester
          .widgetList<RefreshIndicator>(find.byType(RefreshIndicator))
          .toList();
      expect(indicators, isNotEmpty);
      expect(indicators.every((r) => r.edgeOffset == 96), isTrue);
      // 卸载页面并推帧释放 Dio/Riverpod 零时长内部定时器
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('HomePage RefreshIndicator edgeOffset == topInset',
        (tester) => verifyEdgeOffset(tester, const HomePage()));

    testWidgets('TogetherPage RefreshIndicator edgeOffset == topInset',
        (tester) => verifyEdgeOffset(tester, const TogetherPage(active: true)));

    testWidgets('PeerReportPage RefreshIndicator edgeOffset == topInset',
        (tester) => verifyEdgeOffset(tester, const PeerReportPage(embedded: true)));

    testWidgets('PeerTrackPage RefreshIndicator edgeOffset == topInset',
        (tester) => verifyEdgeOffset(tester, const PeerTrackPage(embedded: true)));

    testWidgets('PeerPhonePage RefreshIndicator edgeOffset == topInset',
        (tester) => verifyEdgeOffset(tester, const PeerPhonePage(embedded: true)));
  });

  group('第 8 项：抽屉展开时 Dock 抓手隐藏、关闭后恢复', () {
    testWidgets('展开记录此刻抽屉只保留单条抓手，手势仍归属 WebDock', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kFirstInstallPermGuideDoneKey: true,
      });
      _mockPeerLoc(
        running: false,
        fine: true,
        background: true,
        usage: true,
        notification: true,
        batteryIgnored: true,
      );
      final container = _makeContainer();
      addTearDown(container.dispose);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(393, 840);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ShellPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      double dockHandleOpacity() {
        final anim = tester.widget<AnimatedOpacity>(
          find.ancestor(
            of: find.byKey(const Key('shell-dock-handle')),
            matching: find.byType(AnimatedOpacity),
          ).first,
        );
        return anim.opacity;
      }

      expect(dockHandleOpacity(), 1.0);
      expect(find.byKey(const Key('composer-drawer-handle')), findsNothing);

      await tester.tap(find.byKey(const Key('shell-dock-handle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byKey(const Key('composer-drawer-handle')), findsOneWidget);
      expect(dockHandleOpacity(), 0.0);

      // 关闭抽屉后 Dock 抓手恢复可见
      final drawerCtx = tester.element(find.byKey(const Key('composer-drawer-handle')));
      Navigator.of(drawerCtx).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('composer-drawer-handle')), findsNothing);
      expect(dockHandleOpacity(), 1.0);
    });
  });
}
