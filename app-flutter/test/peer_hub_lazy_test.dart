import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/sse/sse_client.dart'
    show SseEvent, sseEventsProvider;
import 'package:love_space/features/settings/peer_share_settings_page.dart';
import 'package:love_space/features/together/peer_hub_page.dart';
import 'package:love_space/features/together/peer_report_page.dart';
import 'package:love_space/features/together/peer_track_page.dart';

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
      '/api/peer/events' => <String, Object?>{
          'date': '2026-11-27',
          'peer_closed_off': false,
          'items': <Object>[],
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
      '/api/peer/policy-audit' => <String, Object?>{'items': <Object>[]},
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

Widget _wrap(Widget child) {
  final dio = Dio(BaseOptions(
    baseUrl: 'https://test.local',
    validateStatus: api.validateAppStatus,
  ))
    ..httpClientAdapter = _FakeAdapter();
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      api.dioProvider.overrideWith((ref) async => dio),
      api.baseProvider.overrideWith((ref) async => 'https://test.local'),
      sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('PeerHubPage 默认打开今日页签时不创建轨迹页；切到轨迹页签后创建并保活',
      (tester) async {
    await tester.pumpWidget(_wrap(const PeerHubPage(initialTab: 0)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(PeerReportPage), findsOneWidget);
    expect(find.byType(PeerTrackPage), findsNothing,
        reason: '未选中轨迹页签前不得创建轨迹页及其 AndroidView');

    await tester.tap(find.byKey(const Key('peer-hub-tab-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(PeerTrackPage), findsOneWidget,
        reason: '首次切换到轨迹页签后才创建轨迹页');

    await tester.tap(find.byKey(const Key('peer-hub-tab-0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(PeerTrackPage, skipOffstage: false), findsOneWidget,
        reason: '切走后 IndexedStack 保持已激活页签存活（offstage 保活）');
  });

  testWidgets('PeerHubPage 从伴侣共享与守护入口直落设置页签时不创建轨迹页',
      (tester) async {
    await tester.pumpWidget(_wrap(const PeerHubPage(initialTab: 3)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(PeerShareSettingsPage), findsOneWidget);
    expect(find.byType(PeerTrackPage), findsNothing,
        reason: '落在设置页签时不得预先构造轨迹页');
  });
}
