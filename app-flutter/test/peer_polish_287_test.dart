/// Regression & polish tests for 2.8.7 peer report, phone usage, permissions,
/// diagnostics, and zero-raw-coord / delta / icon rules.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/peer/peer_expected_state.dart';
import 'package:love_space/core/peer/peer_permissions.dart';
import 'package:love_space/core/peer/state_event_text.dart';
import 'package:love_space/core/sse/sse_client.dart';
import 'package:love_space/core/ui/liquid_glass.dart';
import 'package:love_space/features/chat/chat_toast.dart'
    show ChatToastController, ChatToastMessage, ChatToastTone, chatToastProvider;
import 'package:love_space/features/personal/personal_controller.dart'
    show personalCurrentUserProvider;
import 'package:love_space/features/settings/peer_share_settings_page.dart';
import 'package:love_space/features/together/peer_phone_page.dart';
import 'package:love_space/features/together/peer_report_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final FutureOr<ResponseBody> Function(RequestOptions options) handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return handler(options);
  }
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {Headers.contentTypeHeader: const ['application/json']},
    );

class _NoTimerToast extends ChatToastController {
  @override
  void show(String text, {ChatToastTone tone = ChatToastTone.info}) {
    state = ChatToastMessage(id: 1, text: text, tone: tone);
  }
}

const _nativeChannel = MethodChannel('peer_loc/native');

Future<ProviderContainer> _pumpWithRouter(
  WidgetTester tester, {
  required Widget home,
  required _Adapter adapter,
  Size size = const Size(390, 844),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  final dio = Dio(BaseOptions(
    baseUrl: 'https://test.local',
    validateStatus: api.validateAppStatus,
  ))..httpClientAdapter = adapter;

  final container = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    personalCurrentUserProvider.overrideWith((ref) => 'u1'),
    chatToastProvider.overrideWith(_NoTimerToast.new),
  ]);
  addTearDown(container.dispose);

  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => home),
      GoRoute(
        path: '/settings/peer-share',
        builder: (_, _) => const PeerShareSettingsPage(),
      ),
      GoRoute(
        path: '/together/peer-report/phone',
        builder: (_, _) => const PeerPhonePage(),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: ThemeData(useMaterial3: true),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  return container;
}

_Adapter _reportAdapter({
  String placeName = '上海市浦东新区张江路',
  String net = 'cell',
  List<Map<String, Object?>> stays = const [],
  List<Map<String, Object?>> points = const [],
  int screenSec = 1800,
  int yesterdayScreenSec = 2160,
  int unlocks = 5,
  int longestSec = 600,
  double? updatedOffsetSec = -3600,
}) {
  final now = DateTime.now().millisecondsSinceEpoch / 1000;
  return _Adapter((o) {
    final p = o.uri.path;
    if (p == '/api/peer/status') {
      return _json({
        'revision': 1,
        'mine': {
          'settings': {'events': true},
          'location': {
            'lat': 31.2304,
            'lng': 121.4737,
            'battery': 90,
            'updated': now - 30,
          },
          'policy': {'global_off': false, 'paused_until': null},
        },
        'peer': {
          'settings': {'events': true, 'location': true, 'track': true},
          'location': {
            'lat': 31.230456,
            'lng': 121.473789,
            'battery': 75,
            'charging': false,
            'net': net,
            'wifi': '',
            'place_name': placeName,
            'updated': now + (updatedOffsetSec ?? -60),
          },
          'enabled': true,
          'closed_off': false,
          'halted': {'halted': false, 'reason': ''},
          'current_app': null,
        },
      });
    }
    if (p == '/api/peer/state-daily') {
      return _json({
        'date': '2026-11-27',
        'mine': {'screen_sec': 100, 'unlocks': 1},
        'peer': {
          'closed_off': false,
          'screen_sec': screenSec,
          'unlocks': unlocks,
        },
      });
    }
    if (p == '/api/peer/usage-daily') {
      return _json({
        'date': '2026-11-27',
        'mine': {'closed_off': false},
        'peer': {
          'closed_off': false,
          'halted': {'halted': false, 'reason': ''},
          'screen_sec': screenSec,
          'unlocks': unlocks,
          'longest_session_sec': longestSec,
          'yesterday_screen_sec': yesterdayScreenSec,
          'network_events': [
            {'ts': now - 100, 'net': 'wifi', 'ssid': 'Home'},
            {'ts': now - 200, 'net': 'cell', 'ssid': ''},
            {'ts': now - 300, 'net': 'none', 'ssid': ''},
          ],
        },
      });
    }
    if (p == '/api/peer/track') {
      return _json({
        'date': '2026-11-27',
        'mine': {'closed_off': false, 'stays': <Object?>[]},
        'peer': {
          'closed_off': false,
          'halted': {'halted': false, 'reason': ''},
          'level': 'exact',
          'points': points,
          'stays': stays,
          'distance_m': points.isEmpty ? 0.0 : 500.0,
        },
      });
    }
    if (p == '/api/peer/events') {
      return _json({
        'date': '2026-11-27',
        'mine': <Object?>[],
        'peer': {'closed_off': false, 'events': <Object?>[]},
      });
    }
    return _json(<String, Object?>{});
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nativeChannel, null);
  });

  group('Pure formatters & permission cooldown', () {
    test('usageDeltaText formats positive/negative/equal/empty cleanly', () {
      expect(usageDeltaText(4200, 3600), '比昨天多 10 分钟');
      expect(usageDeltaText(3240, 3600), '比昨天少 6 分钟');
      expect(usageDeltaText(3240, 3600)!.contains('-'), isFalse);
      expect(usageDeltaText(3600, 3600), '与昨日持平');
      expect(usageDeltaText(0, 3600), isNull);
      expect(usageDeltaText(null, 3600), isNull);
      expect(usageDeltaText(3600, 0), isNull);
      expect(usageDeltaText(3600, null), isNull);
    });

    test('networkIconFor matches semantic network icons', () {
      expect(networkIconFor('wifi'), Icons.wifi_rounded);
      expect(networkIconFor('cell'), Icons.signal_cellular_alt_rounded);
      expect(networkIconFor('none'), Icons.signal_cellular_off_rounded);
    });

    test('proactive permission prompt enforces 24h cooldown', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      const missingSnap = PeerPermissionSnapshot(
        fine: true,
        background: false,
        usage: true,
        notification: true,
        batteryIgnored: true,
        manufacturer: 'xiaomi',
        autoStartIntentSupported: false,
        channelAvailable: true,
      );
      final t0 = DateTime(2026, 11, 27, 10, 0);
      expect(await shouldShowProactivePermissionPrompt(missingSnap, now: t0),
          isTrue);
      await markProactivePermissionPromptShown(now: t0);
      expect(
        await shouldShowProactivePermissionPrompt(
          missingSnap,
          now: t0.add(const Duration(hours: 23)),
        ),
        isFalse,
      );
      expect(
        await shouldShowProactivePermissionPrompt(
          missingSnap,
          now: t0.add(const Duration(hours: 24, minutes: 1)),
        ),
        isTrue,
      );
    });
  });

  group('PeerReportPage & PeerPhonePage polish', () {
    testWidgets(
      'PeerReportPage hides raw coords, shows Geocoder place_name, deduplicates battery, keeps LiveStatusPill untruncated, hides empty footprint thumbnail & negative sign',
      (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          kPeerExpectedKey: true,
          kPeerPermPromptLastAtKey: DateTime.now().millisecondsSinceEpoch,
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_nativeChannel, (call) async {
          switch (call.method) {
            case 'status':
              return <String, Object?>{'running': true, 'queue': 0};
            case 'batteryIgnored':
              return true;
            case 'permissions':
              return <String, Object?>{
                'fine': false,
                'background': false,
                'usage': false,
                'notification': true,
                'batteryIgnored': true,
                'manufacturer': 'xiaomi',
                'autoStartIntentSupported': false,
              };
            default:
              return <String, Object?>{};
          }
        });

        await _pumpWithRouter(
          tester,
          home: const PeerReportPage(),
          adapter: _reportAdapter(
            placeName: '上海市浦东新区张江路',
            net: 'cell',
            screenSec: 1800,
            yesterdayScreenSec: 2160,
          ),
          size: const Size(320, 740),
        );

        // No redundant subtitle above status card
        expect(find.textContaining('都在这里'), findsNothing);

        // No raw coordinates; shows Geocoder place_name
        expect(find.textContaining('31.230456'), findsNothing);
        expect(find.byKey(const Key('peer-stay-line')), findsOneWidget);
        expect(find.text('上海市浦东新区张江路'), findsOneWidget);

        // Battery deduplicated (1 BatteryRing on right, no bottom usage chip)
        expect(find.byKey(const Key('peer-card-battery')), findsOneWidget);
        expect(find.byKey(const Key('peer-card-usage')), findsNothing);
        expect(find.byKey(const Key('peer-card-net')), findsOneWidget);
        expect(find.byKey(const Key('peer-card-active')), findsOneWidget);

        // Network icon matches cell
        expect(
          find.descendant(
            of: find.byKey(const Key('peer-card-net')),
            matching: find.byIcon(Icons.signal_cellular_alt_rounded),
          ),
          findsOneWidget,
        );

        // LiveStatusPill does not use ellipsis truncation
        final pill = tester.widget<LiveStatusPill>(
          find.byKey(const Key('peer-live-line')),
        );
        expect(pill.ellipsis, isFalse);

        // Footprint empty state omits _MiniTrackThumbnail
        expect(find.text('今天还没有足迹记录'), findsOneWidget);
        expect(
          find.byKey(const Key('peer-footprint-thumb')),
          findsNothing,
        );

        // Negative delta formatted without '-'
        expect(find.byKey(const Key('peer-usage-delta')), findsOneWidget);
        expect(find.text('比昨天少 6 分钟'), findsOneWidget);

        // 2.8.7 傍晚批 1-1：「我的报备」只在我视角渲染，先切视角再滚动
        await tester.tap(find.text('我').last);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const Key('report-mine-loc-perm-hint')),
          300,
        );
        expect(
          find.byKey(const Key('report-mine-loc-perm-hint')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'PeerReportPage empty usage shows empty hint & hides delta; place falls back when place_name empty',
      (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          kPeerExpectedKey: true,
        });
        // First open triggers proactive sheet because permissions missing & no cooldown recorded
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_nativeChannel, (call) async {
          switch (call.method) {
            case 'permissions':
              return <String, Object?>{
                'fine': false,
                'background': false,
                'usage': false,
                'notification': false,
                'batteryIgnored': false,
                'manufacturer': 'xiaomi',
                'autoStartIntentSupported': false,
              };
            default:
              return <String, Object?>{};
          }
        });

        await _pumpWithRouter(
          tester,
          home: const PeerReportPage(),
          adapter: _reportAdapter(
            placeName: '',
            net: 'none',
            screenSec: 0,
            unlocks: 0,
            longestSec: 0,
            yesterdayScreenSec: 3600,
          ),
        );

        // Proactive permission sheet shows on first open
        expect(find.byKey(const Key('peer-perm-prompt-sheet')), findsOneWidget);
        await tester.tap(find.byKey(const Key('peer-perm-prompt-later')));
        await tester.pumpAndSettle();

        expect(find.textContaining('位置已更新'), findsOneWidget);
        expect(find.textContaining('31.230456'), findsNothing);
        expect(find.text('对方今天还没有使用数据'), findsOneWidget);
        expect(find.byKey(const Key('peer-usage-delta')), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const Key('peer-card-net')),
            matching: find.byIcon(Icons.signal_cellular_off_rounded),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'PeerPhonePage shows negative delta wording, semantic network icons, and missing usage permission card on self tab',
      (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_nativeChannel, (call) async {
          if (call.method == 'permissions') {
            return <String, Object?>{
              'fine': true,
              'background': true,
              'usage': false,
              'notification': true,
              'batteryIgnored': true,
              'manufacturer': 'xiaomi',
              'autoStartIntentSupported': false,
            };
          }
          return <String, Object?>{'sessions': 0};
        });

        await _pumpWithRouter(
          tester,
          home: const PeerPhonePage(),
          adapter: _reportAdapter(screenSec: 1800, yesterdayScreenSec: 2160),
        );

        expect(find.text('比昨天少 6 分钟'), findsOneWidget);
        expect(find.textContaining('-6 分钟'), findsNothing);

        await tester.tap(find.byKey(const Key('phone-tab-net')));
        await tester.pump();
        final phoneNetCard = find.byKey(const Key('phone-network'));
        expect(
          find.descendant(
            of: phoneNetCard,
            matching: find.byIcon(Icons.wifi_rounded),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: phoneNetCard,
            matching: find.byIcon(Icons.signal_cellular_alt_rounded),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: phoneNetCard,
            matching: find.byIcon(Icons.signal_cellular_off_rounded),
          ),
          findsOneWidget,
        );

        await tester.tap(find.text('我'));
        await tester.pump();
        expect(find.byKey(const Key('phone-usage-perm-hint')), findsOneWidget);
      },
    );
  });

  group('PeerShareSettingsPage Permission Center, JIT prompt & Diagnostics',
      () {
    testWidgets(
      'renders 6-item Permission Center, OEM fallback guide, JIT prompt, and Diagnostics refresh',
      (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        var pullCalled = 0;
        var currentPolicy = <String, Object?>{
          'global_off': false,
          'paused_until': null,
          'location_level': 'exact',
          'usage_level': 'off',
          'app_level': 'off',
          'network_level': 'ssid',
          'battery': true,
          'battery_alert': true,
          'sensitive_pkgs': <String>[],
          'fold_short': true,
        };

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_nativeChannel, (call) async {
          switch (call.method) {
            case 'status':
              return <String, Object?>{'running': true, 'received': 3};
            case 'pullUsage':
              pullCalled++;
              return <String, Object?>{'sessions': 2};
            case 'openAutoStartSettings':
              return false;
            case 'permissions':
              return <String, Object?>{
                'fine': true,
                'background': false,
                'usage': false,
                'notification': true,
                'batteryIgnored': true,
                'manufacturer': 'xiaomi',
                'autoStartIntentSupported': false,
              };
            case 'diagnostics':
              return <String, Object?>{
                'location': <String, Object?>{
                  'running': true,
                  'received': 3,
                  'queue': 0,
                  'reported': 3,
                  'dropped': 0,
                  'still': false,
                  'heartbeatArmed': true,
                  'heartbeatTicks': 1,
                  'lastReceivedAt': 1795747933000,
                },
                'state': <String, Object?>{
                  'enabled': true,
                  'emitted': 4,
                  'unlockPending': 0,
                  'inScreenSession': true,
                },
                'usage': <String, Object?>{
                  'granted': false,
                  'enabled': false,
                  'emitted': 0,
                  'cursor': 0,
                },
                'permissions': <String, Object?>{
                  'fine': true,
                  'background': false,
                  'usage': false,
                  'notification': true,
                  'batteryIgnored': true,
                  'manufacturer': 'xiaomi',
                  'autoStartIntentSupported': false,
                },
                'lastFlushAt': 1795747933000,
                'lastStateEmitAt': 1795747933000,
                'lastUsagePullAt': 0,
                'lastUsageEmitAt': 0,
                'lastUsageRawCount': 0,
                'policySummary': 'halted=false usage=off app=off loc=exact net=ssid',
                'policyHalted': false,
              };
            default:
              return <String, Object?>{};
          }
        });

        final adapter = _Adapter((o) {
          if (o.uri.path == '/api/peer/settings') {
            if (o.method == 'PUT') {
              currentPolicy = Map<String, Object?>.from(
                (o.data as Map)['policy'] as Map,
              );
            }
            return _json({
              'location': true,
              'track': true,
              'events': true,
              'usage': currentPolicy['usage_level'] != 'off',
              'policy': currentPolicy,
            });
          }
          if (o.uri.path == '/api/peer/policy-audit') {
            return _json({'items': <Object?>[]});
          }
          return _json(<String, Object?>{});
        });

        await _pumpWithRouter(
          tester,
          home: const PeerShareSettingsPage(),
          adapter: adapter,
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('peer-perm-center')), findsOneWidget);
        expect(find.byKey(const Key('peer-perm-usage')), findsOneWidget);
        expect(find.byKey(const Key('peer-perm-fine')), findsOneWidget);
        expect(find.byKey(const Key('peer-perm-bg')), findsOneWidget);
        expect(find.byKey(const Key('peer-perm-notify')), findsOneWidget);
        expect(find.byKey(const Key('peer-perm-battery')), findsOneWidget);
        expect(find.byKey(const Key('peer-perm-autostart')), findsOneWidget);
        await tester.tap(find.byKey(const Key('peer-perm-autostart-btn')));
        await tester.pump();
        expect(find.byKey(const Key('peer-perm-autostart-guide')),
            findsOneWidget);

        // Scroll to usage level chip and tap '时长+分布' while usage permission missing -> JIT sheet
        final usageFullFinder = find.byKey(const Key('peer-level-usage-full'));
        await tester.scrollUntilVisible(usageFullFinder, 200);
        await tester.ensureVisible(usageFullFinder);
        await tester.pumpAndSettle();
        await tester.tap(usageFullFinder);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('peer-jit-perm-sheet')), findsOneWidget);

        // Save anyway
        await tester.tap(find.byKey(const Key('peer-jit-save-anyway')));
        await tester.pumpAndSettle();
        expect(currentPolicy['usage_level'], 'full');

        // Scroll to diagnostics card & tap manual pull button
        final diagBtnFinder = find.byKey(const Key('peer-diag-refresh'));
        await tester.scrollUntilVisible(diagBtnFinder, 200);
        await tester.ensureVisible(diagBtnFinder);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('peer-diagnostics-card')), findsOneWidget);
        await tester.tap(diagBtnFinder);
        await tester.pumpAndSettle();
        expect(pullCalled, greaterThanOrEqualTo(1));
      },
    );
  });
}
