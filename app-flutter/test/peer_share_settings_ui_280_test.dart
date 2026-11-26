/// 2.8.7 全量施工令 · 报备设置页 UI 护栏（由 2.8.0 四开关页测试演进）。
///
/// 页面已从「四个开关」重构为「危险区 + 暂停 + 四组分档 + 附加开关 + 预览/审计」；
/// 原五条用例的**口径**保留（真值渲染 / 失败不冒充 / 防连点 / 失败回滚 /
/// 成功后以后端为准），断言对象改为档位 chips 与新的开关 key。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/features/chat/chat_toast.dart'
    show ChatToastController, ChatToastMessage, ChatToastTone, chatToastProvider;
import 'package:love_space/features/settings/peer_share_settings_page.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return handler(options);
  }

  Iterable<RequestOptions> get puts =>
      requests.where((r) => r.method == 'PUT');
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: const ['application/json'],
      },
    );

class _NoTimerToastController extends ChatToastController {
  @override
  void show(String text, {ChatToastTone tone = ChatToastTone.info}) {
    state = ChatToastMessage(id: 1, text: text, tone: tone);
  }
}

const _native = MethodChannel('peer_loc/native');

Map<String, Object?> settingsJson({
  bool events = true,
  String loc = 'exact',
  String usage = 'full',
  String app = 'stream',
  String net = 'ssid',
  bool globalOff = false,
  double? pausedUntil,
}) =>
    {
      'location': loc != 'off',
      'track': loc != 'off',
      'events': events,
      'usage': usage != 'off',
      'policy': {
        'global_off': globalOff,
        'paused_until': pausedUntil,
        'location_level': loc,
        'usage_level': usage,
        'app_level': app,
        'network_level': net,
        'battery': true,
        'battery_alert': true,
        'sensitive_pkgs': <String>[],
        'fold_short': true,
      },
    };

/// PUT 回写：用提交的 policy 原样回一张 GET 形态（模拟后端落库后返回）。
Map<String, Object?> echo(RequestOptions o) {
  final data = (o.data as Map).cast<String, dynamic>();
  final pol = (data['policy'] as Map).cast<String, dynamic>();
  return {
    'location': (pol['location_level'] ?? 'exact') != 'off',
    'track': (pol['location_level'] ?? 'exact') != 'off',
    'events': data['events'] != false,
    'usage': (pol['usage_level'] ?? 'full') != 'off',
    'policy': pol,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, (call) async {
      if (call.method == 'status') {
        return {'running': true, 'received': 1, 'queue': 0};
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, null);
  });

  ProviderContainer makeContainer(_Adapter adapter) {
    final dio = Dio(BaseOptions(
      baseUrl: 'https://test.local',
      validateStatus: api.validateAppStatus,
    ))..httpClientAdapter = adapter;
    final c = ProviderContainer(overrides: [
      api.dioProvider.overrideWith((ref) async => dio),
      chatToastProvider.overrideWith(_NoTimerToastController.new),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  Future<void> pumpPage(WidgetTester tester, ProviderContainer c) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(393, 1600);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: PeerShareSettingsPage()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
  }

  _Adapter okAdapter(Object? body) => _Adapter((o) async {
        if (o.path == '/api/peer/settings') {
          return o.method == 'PUT' ? _json(echo(o)) : _json(body ?? settingsJson());
        }
        if (o.path == '/api/peer/policy-audit') {
          return _json({'items': <Object?>[]});
        }
        return _json({});
      });

  bool chipSelected(WidgetTester tester, String key) =>
      tester.widget<ChoiceChip>(find.byKey(Key(key))).selected;

  testWidgets('首屏成功：按服务端 policy 渲染档位选中态 + 状态条', (tester) async {
    final c = makeContainer(okAdapter(settingsJson(
        loc: 'street', usage: 'screen_only', app: 'top5', net: 'type_only')));
    await pumpPage(tester, c);

    expect(find.byKey(const Key('peer-share-status')), findsOneWidget);
    expect(find.textContaining('采集中'), findsOneWidget);
    expect(chipSelected(tester, 'peer-level-location-street'), isTrue);
    expect(chipSelected(tester, 'peer-level-location-exact'), isFalse);
    expect(chipSelected(tester, 'peer-level-usage-screen_only'), isTrue);
    expect(chipSelected(tester, 'peer-level-app-top5'), isTrue);
    expect(chipSelected(tester, 'peer-level-net-type_only'), isTrue);
    // events 独立开关仍在（报备通道不并入档位）
    expect(find.byKey(const Key('peer-share-events')), findsOneWidget);
  });

  testWidgets('首屏失败：错误态 + 重试，不渲染任何档位（不冒充满开）', (tester) async {
    var fail = true;
    final adapter = _Adapter((o) async {
      if (fail) return _json({'detail': 'boom'}, 500);
      return _json(settingsJson());
    });
    final c = makeContainer(adapter);
    await pumpPage(tester, c);

    expect(find.byKey(const Key('peer-level-location-exact')), findsNothing);
    expect(find.byKey(const Key('peer-share-events')), findsNothing);
    expect(find.text('重试'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(const Key('peer-level-location-exact')), findsOneWidget);
  });

  testWidgets('改档位：PUT 整对象（policy + 四键），成功 toast', (tester) async {
    final adapter = okAdapter(settingsJson());
    final c = makeContainer(adapter);
    await pumpPage(tester, c);

    await tester.tap(find.byKey(const Key('peer-level-location-street')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    final put = adapter.puts.single;
    final data = (put.data as Map).cast<String, dynamic>();
    // 整对象提交：四键 + policy 一个都不能少
    for (final k in ['location', 'track', 'events', 'usage', 'policy']) {
      expect(data.containsKey(k), isTrue, reason: 'PUT 必须带全 $k');
    }
    final pol = (data['policy'] as Map).cast<String, dynamic>();
    expect(pol['location_level'], 'street');
    expect(pol.keys.length, 10, reason: 'policy 十键全量');
    // 轨道投影：location=false 时 track 也随档位关掉
    expect(chipSelected(tester, 'peer-level-location-street'), isTrue);
  });

  testWidgets('保存失败：档位回滚 + 错误提示，不假成功', (tester) async {
    final adapter = _Adapter((o) async {
      if (o.path == '/api/peer/settings') {
        if (o.method == 'PUT') return _json({'detail': 'boom'}, 500);
        return _json(settingsJson());
      }
      if (o.path == '/api/peer/policy-audit') {
        return _json({'items': <Object?>[]});
      }
      return _json({});
    });
    final c = makeContainer(adapter);
    await pumpPage(tester, c);

    await tester.tap(find.byKey(const Key('peer-level-usage-off')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(chipSelected(tester, 'peer-level-usage-full'), isTrue);
    expect(chipSelected(tester, 'peer-level-usage-off'), isFalse);
    expect(c.read(chatToastProvider)?.text, contains('未保存'));
  });

  testWidgets('暂停 2 小时：PUT 带 paused_until，状态条显示暂停', (tester) async {
    final adapter = okAdapter(settingsJson());
    final c = makeContainer(adapter);
    await pumpPage(tester, c);

    await tester.tap(find.byKey(const Key('peer-share-pause-2h')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    final put = adapter.puts.single;
    final pol = ((put.data as Map)['policy'] as Map).cast<String, dynamic>();
    expect(pol['paused_until'], isNotNull);
    expect(pol['global_off'], isFalse);
    expect(find.textContaining('已暂停至'), findsOneWidget);
  });

  testWidgets('完全关闭：二次确认后 PUT global_off=true', (tester) async {
    final adapter = okAdapter(settingsJson());
    final c = makeContainer(adapter);
    await pumpPage(tester, c);

    // 开关在 ListTile 的 trailing 上：点 Switch 本体（点整行不会翻转）
    await tester.tap(find.descendant(
      of: find.byKey(const Key('peer-share-off')),
      matching: find.byType(Switch),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const Key('peer-share-off-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    final pol = ((adapter.puts.single.data as Map)['policy'] as Map)
        .cast<String, dynamic>();
    expect(pol['global_off'], isTrue);
    expect(find.textContaining('已完全关闭报备'), findsWidgets);
  });

  testWidgets('保存中禁用：PUT 未回来前再点档位不发第二次请求', (tester) async {
    final gate = Completer<void>();
    final adapter = _Adapter((o) async {
      if (o.path == '/api/peer/settings') {
        if (o.method == 'PUT') {
          await gate.future;
          return _json(echo(o));
        }
        return _json(settingsJson());
      }
      if (o.path == '/api/peer/policy-audit') {
        return _json({'items': <Object?>[]});
      }
      return _json({});
    });
    final c = makeContainer(adapter);
    await pumpPage(tester, c);

    await tester.tap(find.byKey(const Key('peer-level-location-street')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(adapter.puts.length, 1);

    final chip = tester
        .widget<ChoiceChip>(find.byKey(const Key('peer-level-usage-off')));
    expect(chip.onSelected, isNull, reason: '保存中整组禁用，防连点覆盖');

    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(adapter.puts.length, 1);
  });
}
