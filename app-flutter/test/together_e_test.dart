/* 「我们」页段 D 返修回归（2.1.4/VC214）——夹具 = 真实后端存量形状
   （2026-11-13 自 NAS 容器 /data/love.db 实测导出，脱敏）：
   · quest 存量 body：{title, category, done(bool), media: []}
   · music 存量 body：{title: '唯一', content: '', media: ['7523…']}，
     记录级序列化 media = [{id, name, mime:'audio/mpeg', status:'ready', preview}]
   根因回归：段 D 漏扩 togetherKinds → 服务端 kind 过滤把存量 quest/music
   滤掉（自测夹具无视 kind 参数而漏网）。本文件第一例直接断言 kind 参数。 */
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import 'package:love_space/features/chat/chat_toast.dart' show ChatToastHost;
import 'package:love_space/features/together/music_page.dart';
import 'package:love_space/features/together/quest_page.dart';
import 'package:love_space/features/together/together_controller.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions options, int callIndex) handler;
  final List<RequestOptions> requests = [];
  int calls = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return handler(options, calls++);
  }
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
    jsonEncode(data), status,
    headers: {Headers.contentTypeHeader: const ['application/json']});

Map<String, Object> _meFixture = {
  'user': {'id': 'u1', 'name': '我', 'username': 'u1'},
  'users': [
    {'id': 'u1', 'name': '我', 'username': 'u1'},
    {'id': 'u2', 'name': 'TA', 'username': 'u2'},
  ],
  'space': {}, 'unread': 0, 'chat_unread': 0,
};

void main() {
  ProviderContainer widgetSetup(_FakeAdapter adapter) {
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    return ProviderContainer(overrides: [
      api.dioProvider.overrideWith((ref) async => dio),
      chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
      mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
    ]);
  }

  Future<void> pumpPage(WidgetTester tester, ProviderContainer container,
      {required Widget page}) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: (context, child) => Stack(children: [
          child ?? const SizedBox.shrink(),
          const Positioned(
              top: 0, left: 0, right: 0,
              child: IgnorePointer(child: SafeArea(child: ChatToastHost()))),
        ]),
        home: page,
      ),
    ));
    await tester.pumpAndSettle();
  }

  test('🔴 根因回归：load 的 kind 参数必须含 quest/ledger/music（存量漏显根因）',
      () async {
    final adapter = _FakeAdapter((options, i) => _json([]));
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final container = ProviderContainer(overrides: [
      api.dioProvider.overrideWith((ref) async => dio),
    ]);
    addTearDown(container.dispose);
    await container.read(togetherControllerProvider.notifier).bootstrap();
    final req = adapter.requests
        .firstWhere((r) => r.uri.path == '/api/records');
    final kind = req.queryParameters['kind'] ?? '';
    for (final k in ['quest', 'ledger', 'music']) {
      expect(kind.split(','), contains(k),
          reason: '缺 $k 会把存量记录全部滤掉（2.1.3 根因）');
    }
  });

  testWidgets('存量 quest 形状（body 带 media:[] 键 + done bool）完整呈现',
      (tester) async {
    // 夹具 = DB 实测形状：body 含 media: [] 键；done 为 bool；分类为中文
    final adapter = _FakeAdapter((options, i) {
      if (options.uri.path == '/api/me') return _json(_meFixture);
      return _json([
        {
          'id': '68430488', 'kind': 'quest', 'author': 'b757…',
          'body': {'title': '一起唱一次KTV', 'category': '约会', 'done': true,
                   'media': []},
          'created': 1763000000.0, 'updated': 1763000000.0, 'client_id': '',
          'media': [], 'likes': [], 'comments': [],
        },
        {
          'id': '7749c87c', 'kind': 'quest', 'author': 'b757…',
          'body': {'title': '一起过完一个没有手机的晚上', 'category': '生活',
                   'done': false, 'media': []},
          'created': 1762000000.0, 'updated': 1762000000.0, 'client_id': '',
          'media': [], 'likes': [], 'comments': [],
        },
      ]);
    });
    final container = widgetSetup(adapter);
    addTearDown(container.dispose);
    await pumpPage(tester, container, page: const QuestPage());

    // 已完成：标题可见 + 划线态 meta
    expect(find.text('一起唱一次KTV'), findsOneWidget);
    expect(find.textContaining('约会'), findsOneWidget);
    expect(find.textContaining('已完成'), findsOneWidget);
    // 未完成：正常呈现（Web 能显示的 App 不许漏）
    expect(find.text('一起过完一个没有手机的晚上'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsOneWidget);
  });

  testWidgets('存量 music 形状（音频在 body.media，序列化后记录级 media 带 mime）可见可播',
      (tester) async {
    // 夹具 = DB 实测形状：body.media=['7523…']（上传音乐），序列化 media 带 mime
    final adapter = _FakeAdapter((options, i) {
      if (options.uri.path == '/api/me') return _json(_meFixture);
      return _json([
        {
          'id': '87b0f08e', 'kind': 'music', 'author': 'b757…',
          'body': {'title': '唯一', 'content': '', 'media': ['7523f2c9a1fa']},
          'created': 1763000000.0, 'updated': 1763000000.0, 'client_id': '',
          'media': [
            {'id': '7523f2c9a1fa', 'name': '唯一.mp3',
             'mime': 'audio/mpeg', 'size': 1, 'status': 'ready',
             'preview': ''},
          ],
          'likes': [], 'comments': [],
        },
      ]);
    });
    final container = widgetSetup(adapter);
    addTearDown(container.dispose);
    await pumpPage(tester, container, page: const MusicPage());

    expect(find.text('唯一'), findsOneWidget, reason: '存量上传音乐必须可见');
    expect(find.byTooltip('试听'), findsOneWidget, reason: '本地音频可播');

    // 清缓存：downloadAudioToCache 命中即直接回本地文件、不发请求——
    // 回归要断言请求本身，必须先删上一轮留下的 song_cache
    final cacheDir = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}song_cache');
    if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);

    // 点试听 → 下载优先：GET /media/{mid}?preview=true（无 Range 流播）。
    // 测试环境无音频插件：下载成功后 setFilePath 挂起 → 8s 播放器超时
    // （FakeAsync 需 pump 推进时钟触发）→ 被 UI 兜底捕获；下载请求本身必须发生
    await tester.tap(find.byTooltip('试听'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 12));
    final dl = adapter.requests
        .firstWhere((r) => r.uri.path == '/media/7523f2c9a1fa');
    expect(dl.queryParameters['preview'], 'true');
    expect(dl.headers.containsKey('range'), isFalse);
    await tester.pump(const Duration(seconds: 3));
  });


  test('uploadMusicToPlaylist：media 上传 → kind=music body.media=[mid]（纯容器，'
      'multipart 在 FakeAsync 会挂 → upload 桩替换）', () async {
    var posted = false;
    final newRec = {
      'id': 'mNew', 'kind': 'music',
      'body': {'title': '我的歌', 'content': '想说的话', 'media': ['midUpload1']},
      'created': 1.0, 'updated': 1.0, 'client_id': '',
      'media': [], 'likes': [], 'comments': [],
    };
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = _FakeAdapter((options, i) {
        if (options.method == 'POST' && options.uri.path == '/api/records') {
          posted = true;
          return _json(newRec);
        }
        // 重拉返回已提交记录（模拟服务端持久化）
        return _json(posted ? [newRec] : []);
      });
    final container = ProviderContainer(overrides: [
      api.dioProvider.overrideWith((ref) async => dio),
    ]);
    addTearDown(container.dispose);
    await container.read(togetherControllerProvider.notifier).bootstrap();

    await uploadMusicToPlaylist(container,
        filename: 'demo.mp3', bytes: [1, 2, 3],
        title: '我的歌', content: '想说的话',
        upload: (dio, filename, bytes) async => 'midUpload1');

    final st = container.read(togetherControllerProvider);
    final rec = st.records.firstWhere((r) => r.id == 'mNew');
    expect(rec.kind, 'music');
    expect(rec.body['media'], ['midUpload1'],
        reason: '上传的 mid 进 body.media（Web musicForm 同构）');
    expect(rec.body['title'], '我的歌');
  });
}
