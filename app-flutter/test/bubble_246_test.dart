/// 2.4.6 气泡各发各的（按人皮肤）：提示词钉死的断言组。
/// · 渲染映射回退链三态（纯函数）+「渲染行级与查看者无关」的源码护栏；
/// · 保存走按人端点 PUT /api/profile 且不触发空间 PUT（mock 计数断言）；
/// · 对方改皮肤后我方重渲染生效（SpaceUser 载荷更新 → fromAuthor 新值断言）；
/// · 聊天页 sheet 与设置页两入口写同一数据源（源码护栏）；
/// · 硬性护栏：气泡保存不得再走 PUT /api/space 写空间字段（源码 + 行为双钉）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_bubbles.dart';
import 'package:love_space/core/chat/chat_media.dart';
import 'package:love_space/features/auth/auth_state.dart';
import 'package:love_space/features/chat/bubble_skin_sheet.dart';
import 'package:love_space/features/chat/chat_toast.dart'
    show ChatToastController, ChatToastTone, chatToastProvider;

// ── 纯函数：载荷解析 + 回退链（对方改皮肤 → 生效）────────────────────────

final meUserJson = <String, dynamic>{
  'id': 'u1', 'name': '我', 'username': 'u1', 'avatar': '',
  'bubble_skin': 'p1/a.png', 'bubble_fg': 'dark', 'bubble_swap': 1,
};
final meJson = <String, dynamic>{
  'users': <Map<String, dynamic>>[
    meUserJson,
    {'id': 'u2', 'name': 'TA', 'username': 'u2', 'avatar': '',
     'bubble_skin': '', 'bubble_fg': '', 'bubble_swap': null},
  ],
  'space': <String, dynamic>{
    'name': '小家', 'chat_bubble': 'p9/space.png',
    'chat_bubble_fg': 'dark', 'chat_bubble_swap': true,
  },
  'unread': 0, 'chat_unread': 0,
};

MeData buildMeData() => MeData(
      user: SpaceUser.fromJson(meUserJson.cast<String, dynamic>()),
      users: ((meJson['users'] as List).cast<Map<String, dynamic>>())
          .map((u) => SpaceUser.fromJson(u.cast<String, dynamic>()))
          .toList(),
      spaceName: '小家',
      spaceRaw:
          (meJson['space'] as Map<String, dynamic>).cast<String, dynamic>(),
      spaceSince: '',
    );

void main() {
  group('载荷解析：SpaceUser 按人三键（/api/me 下发形状）', () {
    test('三键齐全：skin/fg 解析，swap 0/1 归一 bool', () {
      final u = SpaceUser.fromJson(const {
        'id': 'u1', 'name': '我', 'username': 'u1',
        'bubble_skin': 'p1/a.png', 'bubble_fg': 'light', 'bubble_swap': 0,
      });
      expect(u.bubbleSkin, 'p1/a.png');
      expect(u.bubbleFg, 'light');
      expect(u.bubbleSwap, isFalse);
    });

    test('旧后端不下发这些键 → 容错缺省（空串/空串/null），语义=未设置', () {
      final u = SpaceUser.fromJson(const {'id': 'u2', 'name': 'TA', 'username': 'u2'});
      expect(u.bubbleSkin, '');
      expect(u.bubbleFg, '');
      expect(u.bubbleSwap, isNull);
    });

    test('null=未设置 与 true/false 设置并存（swap 独立清空无入口）', () {
      final set = SpaceUser.fromJson(const {'id': 'u', 'bubble_swap': 1});
      final unset = SpaceUser.fromJson(const {'id': 'u', 'bubble_swap': null});
      expect(set.bubbleSwap, isTrue);
      expect(unset.bubbleSwap, isNull);
    });
  });

  group('渲染映射：对方改皮肤后我方重渲染生效（provider 更新断言）', () {
    test('reload 拿到对方新皮肤 → fromAuthor 立即用新值（SSE other→reload 链）', () {
      const spaceSkin = ChatSkin(skin: 'p9/s.png', fg: 'dark', swap: true);
      // 我方视角：对方（旧）未设置 → 对方消息走空间回退
      final oldPeer = SpaceUser.fromJson(const {'id': 'u2', 'name': 'TA'});
      final oldRendered = ChatSkin.fromAuthor(
          skin: oldPeer.bubbleSkin, fg: oldPeer.bubbleFg,
          swap: oldPeer.bubbleSwap, fallback: spaceSkin);
      expect(oldRendered, spaceSkin);
      // 对方改了皮肤（reload 后 me.users 里的 SpaceUser 带新三键）
      final newPeer = SpaceUser.fromJson(const {
        'id': 'u2', 'name': 'TA', 'bubble_skin': 'p3/new.png',
        'bubble_fg': 'light', 'bubble_swap': true,
      });
      final newRendered = ChatSkin.fromAuthor(
          skin: newPeer.bubbleSkin, fg: newPeer.bubbleFg,
          swap: newPeer.bubbleSwap, fallback: spaceSkin);
      expect(newRendered.skin, 'p3/new.png');
      expect(newRendered.fg, 'light');
      expect(newRendered.swap, isTrue);
      // 作者消息图由作者 swap 决定（与查看者无关 → 两台手机一致）
      expect(newRendered.authorMessageUrl, 'p3/new-r.png');
    });
  });

  // ── 源码护栏（硬性护栏：防两处事实源打架）─────────────────────────────

  group('源码护栏', () {
    final sheetSrc =
        File('lib/features/chat/bubble_skin_sheet.dart').readAsStringSync();
    final bubblesSrc = File('lib/core/chat/chat_bubbles.dart').readAsStringSync();
    final pageSrc = File('lib/features/chat/messages_page.dart').readAsStringSync();
    final settingsSrc =
        File('lib/features/settings/chat_bubble_page.dart').readAsStringSync();

    test('气泡保存不得再走 PUT /api/space 写空间字段', () {
      expect(sheetSrc.contains("'/api/space'"), isFalse,
          reason: 'BubbleSkinSheet 保存只走按人端点');
      expect(sheetSrc.contains('applyChatSkinPayload'), isFalse,
          reason: '空间全量覆盖 payload 组装函数已退役');
      expect(bubblesSrc.contains('applyChatSkinPayload'), isFalse,
          reason: 'chat_bubbles.dart 不再提供空间写入组装');
    });

    test('保存走按人端点 PUT /api/profile', () {
      expect(sheetSrc.contains("dio.put('/api/profile'"), isTrue);
    });

    test('渲染行级按作者解析皮肤（作者原则：每条消息=该消息作者的皮肤）', () {
      expect(pageSrc.contains('skin: mine ? mySkin : peerSkin'), isTrue);
      expect(pageSrc.contains('ChatSkin.fromAuthor'), isTrue);
      expect(pageSrc.contains('authorMessageUrl'), isTrue,
          reason: '作者消息图由作者 swap 决定，与查看者无关（两台一致）');
    });

    test('两入口共用同一组件同一数据源（ChatBubblePage 内嵌 BubbleSkinSheet）', () {
      expect(settingsSrc.contains('BubbleSkinSheet(embedded: true)'), isTrue,
          reason: '设置独立页与聊天页 sheet 共用同一保存链，不留第二套实现');
    });
  });

  // ── 行为断言：保存链（widget）────────────────────────────────────────

  Future<(_StubAuth, List<String>, List<String>)> pumpSheet(
      WidgetTester tester) async {
    _StubAuth.reloadCalls = 0; // 静态计数跨用例共享，先归零
    final putPaths = <String>[];
    final putBodies = <String>[];
    final adapter = _FakeAdapter(putPaths, putBodies);
    final dio = Dio(BaseOptions(
      baseUrl: 'https://test.local',
      validateStatus: api.validateAppStatus,
    ))..httpClientAdapter = adapter;
    final auth = _StubAuth();
    final container = ProviderContainer(overrides: <Override>[
      api.dioProvider.overrideWith((ref) async => dio),
      api.baseProvider.overrideWith((ref) async => 'https://test.local'),
      chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
      mediaCookieHeadersProvider.overrideWith((ref) async => const {}),
      authProvider.overrideWith(_StubAuth.new),
      chatToastProvider.overrideWith(_NoTimerToastController.new),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showBubbleSkinSheet(context),
            child: const Text('OPEN'),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
    return (auth, putPaths, putBodies);
  }

  testWidgets('保存走按人端点且不触发空间 PUT（mock 计数断言）', (tester) async {
    final (auth, putPaths, putBodies) = await pumpSheet(tester);
    await tester.tap(find.text('使用这个'));
    await tester.pumpAndSettle();
    expect(putPaths, ['/api/profile'], reason: '只发按人端点一次');
    final body = jsonDecode(putBodies.first) as Map<String, dynamic>;
    expect(body['bubble_skin'], 'p1/a.png');
    expect(body['bubble_fg'], 'dark');
    expect(body['bubble_swap'], true);
    expect(body['name'], '我');
    expect(_StubAuth.reloadCalls, 1, reason: '保存成功后 reload me（载荷即时更新）');
    // 保存成功 pop 回上一层（sheet 关闭）
    expect(find.byType(BubbleSkinSheet), findsNothing);
  });

  testWidgets('不用皮肤 = bubble_skin 清空请求（服务端三键整体回未设置）', (tester) async {
    final (_, putPaths, putBodies) = await pumpSheet(tester);
    await tester.tap(find.text('不用皮肤'));
    await tester.pumpAndSettle();
    expect(putPaths, ['/api/profile']);
    final body = jsonDecode(putBodies.first) as Map<String, dynamic>;
    expect(body['bubble_skin'], '');
    expect(body.containsKey('bubble_fg'), isFalse, reason: '清空=服务端整体回退，不另发键');
  });

  testWidgets('面板初始取我的按人皮肤（非空间级），文案点明各发各的', (tester) async {
    await pumpSheet(tester);
    expect(find.text('聊天气泡'), findsOneWidget);
    expect(find.text('只换你发出的气泡，对方的由对方设置'), findsOneWidget);
  });
}

// ── 夹具 ─────────────────────────────────────────────────────────────

class _StubAuth extends AuthNotifier {
  final MeData data = buildMeData();
  static int reloadCalls = 0;   // provider 内实例与测试持有者不同，用静态计数
  @override
  AuthPhase build() {
    me = data;
    return AuthPhase.authed;
  }

  @override
  Future<void> reload() async {
    reloadCalls++;
    me = data;
  }}

class _FakeAdapter implements HttpClientAdapter {
  final List<String> putPaths;
  final List<String> putBodies;
  _FakeAdapter(this.putPaths, this.putBodies);

  @override
  void close({bool force = false}) {}

  ResponseBody _json(Object data, [int status = 200]) =>
      ResponseBody.fromString(jsonEncode(data), status, headers: {
        Headers.contentTypeHeader: const <String>['application/json'],
      });

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final method = options.method;
    if (method == 'GET' && path == '/api/bubbles') {
      return _json(<String, dynamic>{
        'groups': <Map<String, dynamic>>[
          {'id': 'p1', 'count': 1, 'items': <String>['a.png']},
        ],
      });
    }
    if (method == 'PUT' && path == '/api/profile') {
      putPaths.add(path);
      putBodies.add(jsonEncode(options.data));
      return _json(<String, dynamic>{'ok': true});
    }
    return _json(<String, dynamic>{'msg': 'unexpected: $method $path'}, 404);
  }
}

class _NoTimerToastController extends ChatToastController {
  @override
  void show(String text, {ChatToastTone tone = ChatToastTone.info}) {}
}
