/* 2.4.4 提交二（第 2 项）断言：
   ① 资产清单：两包 count==目录实际数、序号 0..count-1 连续、每张非空、
      两包合计 ≤5MB（体积预算）；
   ② tabs：两个新标签在「我的」之后、pk 老包之前（就近落位定案）；
   ③ 发送载荷：点包 A / 包 B 各一张 → POST /api/records body.sticker 为
      服务端相对路径（既有贴纸链，资产双落位）；
   ④ 面板横滑可达新标签不溢出（393px 断言宽）+ 本地渲染（Image.asset）。 */
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
import 'package:love_space/features/chat/messages_page.dart';
import 'package:love_space/features/chat/sticker_data.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions options, int callIndex) handler;
  final List<RequestOptions> posts = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.method == 'POST') {
      posts.add(options);
      return handler(options, posts.length - 1);
    }
    return handler(options, 0);
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

Future<void> _pumpChat(WidgetTester tester, _FakeAdapter adapter) async {
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('① 资产清单：count==实际文件数、序号连续、每张非空、两包合计 ≤5MB', () {
    var grand = 0;
    for (final pack in stickerPacks.where((p) => p.local)) {
      final dir = Directory('assets/stickers/${pack.dir}');
      expect(dir.existsSync(), isTrue,
          reason: '${pack.id} 资产目录存在');
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.${pack.ext}'))
          .toList();
      final indexes = files
          .map((f) => int.parse(
              f.uri.pathSegments.last.split('.').first))
          .toList()
        ..sort();
      expect(indexes, List.generate(pack.count, (i) => i),
          reason: '${pack.id} 序号 0..${pack.count - 1} 连续且 count==实际数');
      for (final f in files) {
        expect(f.lengthSync(), greaterThan(0), reason: '${f.path} 非空');
        grand += f.lengthSync();
      }
    }
    expect(grand, lessThanOrEqualTo(5 * 1024 * 1024),
        reason: '两包合计体积预算 ≤5MB（实际 ${(grand / 1024).toStringAsFixed(0)}KB）');
  });

  test('② tabs：新标签在「我的」之后、pk 老包之前（就近落位定案）', () {
    final ids = stickerTabs.map((t) => t.$1).toList();
    expect(ids.indexOf('pk-bigmoji'), ids.indexOf('mine') + 1);
    expect(ids.indexOf('pk-memes'), ids.indexOf('pk-bigmoji') + 1);
    expect(ids.indexOf('pk-dancer'), ids.indexOf('pk-memes') + 1);
    expect(
        stickerTabs
            .firstWhere((t) => t.$1 == 'pk-bigmoji')
            .$2,
        '🤪 大表情');
    expect(stickerTabs.firstWhere((t) => t.$1 == 'pk-memes').$2, '🐼 梗图');
  });

  testWidgets('③④ 横滑可达新标签、本地渲染、点图走既有发送链载荷正确',
      (tester) async {
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
      // GET /api/records：初始消息数组；POST（发送贴纸）：单条 record 对象
      final body = (options.data as Map?)?['body'] as Map?;
      if (body != null) {
        return jsonOk({
          'id': 'rS$callIndex', 'kind': 'chat', 'author': 'u1',
          'body': body,
          'created': created, 'updated': created,
          'client_id': '', 'media': [],
        });
      }
      return jsonOk([
        {
          'id': 'r1', 'kind': 'chat', 'author': 'u1',
          'body': {'content': '你好呀'},
          'created': created, 'updated': created,
          'client_id': '', 'media': [],
        }
      ]);
    });
    await _pumpChat(tester, adapter);

    // 打开表情面板
    await tester.tap(find.byTooltip('表情'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 横滑到「🤪 大表情」（393px 内第 4 个标签，tabs 行横向可滑不溢出）
    final surf = tester.getRect(find.byKey(const Key('sticker-panel-surface')));
    Future<void> dragTabs(double dx) async {
      await tester.dragFrom(Offset(surf.left + 200, surf.top + 22), Offset(dx, 0));
      await tester.pumpAndSettle(const Duration(seconds: 1));
    }

    await dragTabs(-260);
    expect(find.text('🤪 大表情'), findsOneWidget,
        reason: 'tabs 行横滑可达新标签（ListView 横向滚动，不挤压截字）');
    final bigRect = tester.getRect(find.text('🤪 大表情'));
    expect(bigRect.left, greaterThanOrEqualTo(0), reason: '大表情标签在屏内');
    expect(bigRect.right, lessThanOrEqualTo(surf.right), reason: '不溢出面板右缘');
    await tester.tap(find.text('🤪 大表情'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 本地渲染（Image.asset，面板网格出图；finder 限定面板内，避开消息区网络图）
    final gridImages = find.descendant(
        of: find.byKey(const Key('sticker-panel-surface')),
        matching: find.byType(Image));
    expect(gridImages, findsWidgets,
        reason: '大表情包网格用 App 本地资产渲染（离线秒开）');

    // 点第一张 → 既有发送链：POST body.sticker = 服务端相对路径
    await tester.tap(gridImages.first);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final stickerBodies = adapter.posts
        .where((r) => r.uri.path == '/api/records')
        .map((r) => (r.data as Map)['body'] as Map)
        .where((b) => b['sticker'] != null)
        .toList();
    expect(stickerBodies, isNotEmpty);
    expect((stickerBodies.last)['sticker'],
        '/static/stickers/bigmoji/0.webp');
    expect((stickerBodies.last)['content'], '');

    // 发送后面板自动收起（onPickFunction 对齐 Web dock.hidden=true）——重开再切梗图
    await tester.tap(find.byTooltip('表情'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final surf2 =
        tester.getRect(find.byKey(const Key('sticker-panel-surface')));
    await tester.dragFrom(Offset(surf2.left + 200, surf2.top + 22),
        const Offset(-420, 0));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final memesRect = tester.getRect(find.text('🐼 梗图'));
    expect(memesRect.left, greaterThanOrEqualTo(0), reason: '梗图标签在屏内');
    expect(memesRect.right, lessThanOrEqualTo(surf2.right), reason: '不溢出');
    await tester.tap(find.text('🐼 梗图'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(gridImages, findsWidgets);
    await tester.tap(gridImages.first);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final bodies2 = adapter.posts
        .where((r) => r.uri.path == '/api/records')
        .map((r) => (r.data as Map)['body'] as Map)
        .where((b) => b['sticker'] != null)
        .toList();
    expect(bodies2.length, greaterThan(1));
    expect((bodies2.last)['sticker'], '/static/stickers/memes/0.webp');
  });
}
