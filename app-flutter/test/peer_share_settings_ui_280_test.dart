/// 2.8.0 P1 伴侣共享开关页 · UI 护栏（施工令四·2）。
///
/// 覆盖：
/// ① 首屏加载成功 → 4 个开关按服务端真实值渲染；
/// ② 首屏加载失败 → 错误态 + 重试按钮，**不出现任何开关**（禁止用默认
///    全开冒充服务端配置）；重试成功后正常渲染；
/// ③ 保存中整组禁用 → PUT 未回来时点另一个开关不发第二次请求（防连点
///    用同一份旧快照互相覆盖）；
/// ④ 保存失败 → 开关回滚原值 + 错误 toast，不做本地假成功；
/// ⑤ 保存成功 → 以后端返回更新 + 成功 toast。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
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

/// 假 toast 控制器（无定时器，避免 widget 测试残留 Timer）。
class _NoTimerToastController extends ChatToastController {
  @override
  void show(String text, {ChatToastTone tone = ChatToastTone.info}) {
    state = ChatToastMessage(id: 1, text: text, tone: tone);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    tester.view.physicalSize = const Size(393, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: PeerShareSettingsPage()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
  }

  Map<String, Object?> state({
    bool location = true,
    bool track = true,
    bool events = true,
    bool usage = true,
  }) =>
      {
        'location': location,
        'track': track,
        'events': events,
        'usage': usage,
      };

  bool valueOf(WidgetTester tester, String key) => tester
      .widget<SwitchListTile>(find.byKey(Key('peer-share-$key')))
      .value;

  testWidgets('首屏成功：四个开关按服务端真实值渲染', (tester) async {
    final adapter = _Adapter((_) async =>
        _json(state(location: false, track: true, events: false, usage: true)));
    final c = makeContainer(adapter);
    await pumpPage(tester, c);

    for (final k in ['location', 'track', 'events', 'usage']) {
      expect(find.byKey(Key('peer-share-$k')), findsOneWidget,
          reason: '四个开关都要在');
    }
    expect(valueOf(tester, 'location'), isFalse);
    expect(valueOf(tester, 'track'), isTrue);
    expect(valueOf(tester, 'events'), isFalse);
    expect(valueOf(tester, 'usage'), isTrue);
    expect(find.text('实时位置共享'), findsOneWidget);
    expect(find.text('历史轨迹共享'), findsOneWidget);
    expect(find.text('报备与事件共享'), findsOneWidget);
    expect(find.text('设备使用报告共享'), findsOneWidget);
    expect(find.byKey(const Key('peer-share-note')), findsOneWidget,
        reason: '底部对等口径说明必须存在');
  });

  testWidgets('首屏失败：错误态 + 重试，且不渲染任何开关（不冒充满开）', (tester) async {
    var fail = true;
    final adapter = _Adapter((_) async => fail
        ? _json({'detail': '连接超时'}, 500)
        : _json(state(events: false)));
    final c = makeContainer(adapter);
    await pumpPage(tester, c);

    expect(find.textContaining('连接超时'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '重试'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing,
        reason: '加载失败不许拿默认全开兜底');

    // 重试成功 → 正常渲染
    fail = false;
    await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byType(SwitchListTile), findsNWidgets(4));
    expect(valueOf(tester, 'events'), isFalse);
  });

  testWidgets('保存中整组禁用：连点第二个开关不发第二次 PUT', (tester) async {
    final gate = Completer<void>();
    final adapter = _Adapter((o) async {
      if (o.method != 'PUT') return _json(state());
      await gate.future;
      return _json((o.data as Map).cast<String, Object?>());
    });
    final c = makeContainer(adapter);
    await pumpPage(tester, c);

    await tester.tap(find.byKey(const Key('peer-share-location')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(adapter.puts.length, 1);
    expect(find.byKey(const Key('peer-share-saving')), findsOneWidget);

    // 请求未回来时再点另一个开关 → 被禁用，不发第二个请求
    await tester.tap(find.byKey(const Key('peer-share-track')));
    await tester.pump();
    expect(adapter.puts.length, 1, reason: '保存中必须整组禁用，防旧快照互相覆盖');

    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(const Key('peer-share-saving')), findsNothing);
  });

  testWidgets('保存失败：开关回滚原值 + 错误提示，不假成功', (tester) async {
    final adapter = _Adapter((o) async {
      if (o.method == 'PUT') return _json({'detail': '保存被拒'}, 400);
      return _json(state(events: true));
    });
    final c = makeContainer(adapter);
    await pumpPage(tester, c);

    await tester.tap(find.byKey(const Key('peer-share-events')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(valueOf(tester, 'events'), isTrue, reason: '失败必须回滚到原值');
    final msg = c.read(chatToastProvider);
    expect(msg?.text.contains('共享设置未保存'), isTrue);
    expect(msg?.tone, ChatToastTone.error);
  });

  testWidgets('保存成功：以后端返回更新 + 成功提示', (tester) async {
    final adapter = _Adapter((o) async {
      if (o.method == 'PUT') {
        // 后端原样落库
        return _json((o.data as Map).cast<String, Object?>());
      }
      return _json(state());
    });
    final c = makeContainer(adapter);
    await pumpPage(tester, c);

    await tester.tap(find.byKey(const Key('peer-share-usage')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(valueOf(tester, 'usage'), isFalse);
    expect(c.read(chatToastProvider)?.text, '共享设置已更新');
    final body = (adapter.puts.single.data as Map).cast<String, Object?>();
    expect(body.keys.toSet(), {'location', 'track', 'events', 'usage'});
    expect(body['usage'], isFalse);
    expect(body['events'], isTrue, reason: '未变更的键必须原样带回');
  });
}
