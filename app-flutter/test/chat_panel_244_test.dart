/* 2.4.4 提交一（第 1+5 项）断言：
   ① 表情面板悬浮化：容器与工具面板共用 _PanelSurface（单一事实源）——
      常量钉死 + 真挂载读两面板 Container 的圆角/高度相等 + 高度槽位不跳；
   ② 顶栏精简：聊天气泡/聊天背景/搜索三 icon 不存在（widget + 源码护栏）；
   ③ 面板「聊天气泡」位于原语音位（第一行第三格）且点击打开 BubbleSkinSheet；
   ④ 源码护栏：面板 voice 入口清零、_PanelSurface 共用、顶栏三 tooltip 清零。 */
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart';
import 'package:love_space/core/chat/chat_media.dart';
import 'package:love_space/core/chat/chat_models.dart';
import 'package:love_space/core/chat/chat_state.dart';
import 'package:love_space/features/chat/chat_compose.dart'
    show kChatPanelPadding, kChatPanelRadius;
import 'package:love_space/features/chat/messages_page.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions options, int callIndex) handler;
  int gets = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return handler(options, gets++);
  }
}

ResponseBody jsonOk(Object data) => ResponseBody.fromString(
    jsonEncode(data), 200,
    headers: {Headers.contentTypeHeader: ['application/json']});

class _MemStore implements ChatPersistence {
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

Future<ProviderContainer?> _pumpChat(WidgetTester tester) async {
  final created = DateTime.now().millisecondsSinceEpoch / 1000;
  final adapter = _FakeAdapter((options, callIndex) {
    if (options.uri.path == '/api/me') {
      return jsonOk({
        'user': {'id': 'u1', 'name': '我', 'username': 'u1'},
        'users': [
          {'id': 'u1', 'name': '我', 'username': 'u1'},
          {'id': 'u2', 'name': 'TA', 'username': 'u2'},
        ],
        'space': {},
        'unread': 0,
        'chat_unread': 0,
      });
    }
    if (options.uri.path == '/api/records') {
      return jsonOk([
        {
          'id': 'r1', 'kind': 'chat', 'author': 'u1',
          'body': {'content': '你好呀'},
          'created': created, 'updated': created,
          'client_id': '', 'media': [],
        }
      ]);
    }
    return jsonOk(const []);
  });
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      dioProvider.overrideWith((ref) async => dio),
      chatPersistenceProvider.overrideWith((ref) async => _MemStore()),
      chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
      mediaCookieHeadersProvider.overrideWith((ref) async => {'Cookie': 'k=v'}),
    ],
    child: const MaterialApp(home: MessagesPage()),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle(const Duration(seconds: 1));
  return null;
}

Future<void> _openFnPanel(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多'));
  await tester.pumpAndSettle(const Duration(seconds: 1));
}

Future<void> _switchToSticker(WidgetTester tester) async {
  await tester.tap(find.byTooltip('表情'));
  await tester.pumpAndSettle(const Duration(seconds: 1));
}

void main() {
  test('① 常量钉死：面板容器单一事实源值与硬性规格一致', () {
    expect(kChatPanelPadding, const EdgeInsets.fromLTRB(10, 4, 10, 10),
        reason: '与工具面板原实现值逐字节一致（左右 10 / 底 10 / 顶 4）');
    expect(kChatPanelRadius, 26, reason: '与输入栏胶囊同圆角 26');
  });

  test('① 源码护栏：两面板共用 _PanelSurface，字面量不再散落', () {
    final src =
        File('lib/features/chat/chat_compose.dart').readAsStringSync();
    // 边距字面量只剩 kChatPanelPadding 定义处一处（_FnPanel/_StickerDock 均不再自写）
    expect('fromLTRB(10, 4, 10, 10)'.allMatches(src).length, 1,
        reason: '面板边距只允许在 kChatPanelPadding 定义处出现一次');
    expect('_PanelSurface('.allMatches(src).length, greaterThanOrEqualTo(3),
        reason: '定义 + 工具面板 + 表情面板两处调用，共用组件钉死');
    // 高度槽位链路未动：两面板仍收外部同一 height（kbHeight）
    expect(src.contains('height: kbHeight'), isTrue);
  });

  test('② 源码护栏：顶栏三 tooltip 清零 + 面板 voice 入口清零', () {
    final page =
        File('lib/features/chat/messages_page.dart').readAsStringSync();
    expect("tooltip: '聊天气泡'".allMatches(page).length, 0,
        reason: '顶栏「修改气泡」已删（入口移至面板原语音位）');
    expect("tooltip: '聊天背景'".allMatches(page).length, 0,
        reason: '顶栏「聊天背景」已删（面板内本就有）');
    expect("tooltip: '搜索'".allMatches(page).length, 0,
        reason: '顶栏「搜索」已删（面板「搜消息」→ 悬浮搜索栏）');
    final src =
        File('lib/features/chat/chat_compose.dart').readAsStringSync();
    expect(src.contains("('voice',"), isFalse,
        reason: '面板「语音」重复入口已置换为聊天气泡（输入栏麦克风键保留）');
    expect(src.contains("('bubble', Icons.chat_bubble_rounded, '聊天气泡')"),
        isTrue);
    expect(src.contains("case 'voice'"), isFalse);
    expect(src.contains("case 'bubble'"), isTrue);
  });

  testWidgets('① 真挂载：两面板容器圆角/高度一致，切换槽位不跳高', (tester) async {
    await _pumpChat(tester);

    // 工具面板 surface
    await _openFnPanel(tester);
    final fnContainer = tester.widget<Container>(
        find.byKey(const Key('fn-panel-surface')));
    final fnDeco = fnContainer.decoration! as BoxDecoration;
    expect(fnDeco.borderRadius, BorderRadius.circular(kChatPanelRadius));
    final fnRect = tester.getRect(find.byKey(const Key('fn-panel-surface')));

    // 切到表情面板 surface
    await _switchToSticker(tester);
    final stickerContainer = tester.widget<Container>(
        find.byKey(const Key('sticker-panel-surface')));
    final stickerDeco = stickerContainer.decoration! as BoxDecoration;
    expect(stickerDeco.borderRadius, BorderRadius.circular(kChatPanelRadius),
        reason: '表情面板圆角与工具面板同源（kChatPanelRadius）');
    final stickerRect =
        tester.getRect(find.byKey(const Key('sticker-panel-surface')));
    expect(stickerRect.height, fnRect.height,
        reason: '高度槽位不变（老规矩）：表情↔工具切换不跳高');

    // 内容原样：标签行、提示行仍在（标签文案带 emoji 前缀）
    expect(find.textContaining('日常'), findsOneWidget);
    expect(find.textContaining('点一下，就能打进输入框'), findsOneWidget);
  });

  testWidgets('② 顶栏三入口不存在（真挂载）', (tester) async {
    await _pumpChat(tester);
    expect(find.byIcon(Icons.format_paint_rounded), findsNothing,
        reason: '顶栏「修改气泡」已删');
    expect(find.byIcon(Icons.wallpaper_rounded), findsNothing,
        reason: '顶栏「聊天背景」已删（面板未开）');
    expect(find.byIcon(Icons.search_rounded), findsNothing,
        reason: '顶栏「搜索」已删（面板未开）');
  });

  testWidgets('③ 面板「聊天气泡」位于原语音位（第一行第三格）且点开 BubbleSkinSheet',
      (tester) async {
    await _pumpChat(tester);
    await _openFnPanel(tester);

    expect(find.text('聊天气泡'), findsOneWidget);
    expect(find.text('语音'), findsNothing, reason: '原语音入口已置换');

    // 位置断言：4 列均分面板，第一行第三格中心 ≈ surface.left + 0.625w（±0.1w）
    final surfaceRect =
        tester.getRect(find.byKey(const Key('fn-panel-surface')));
    final tileRect = tester.getRect(find.text('聊天气泡'));
    final relative = (tileRect.center.dx - surfaceRect.left) / surfaceRect.width;
    expect(relative, inInclusiveRange(0.525, 0.725),
        reason: '相对位置 0.625 = 第一行第三格（原语音位）');

    // 点击 → 打开 BubbleSkinSheet（先关面板再开 sheet）
    await tester.tap(find.text('聊天气泡'));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(find.text('字色'), findsOneWidget,
        reason: 'BubbleSkinSheet 已弹出（与原顶栏气泡图标同一组件）');
  });
}
