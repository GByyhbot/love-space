/* 媒体层单测（段二 · Step 5）：
   ① 白名单/250MB 本地预检矩阵（不发请求）；
   ② 上传→pending 态迁移（upload 阶段进度起点 → send 阶段 → 成功清除/失败落盘）；
   ③ 媒体链路重试复用同一 client_id（上传失败重试不换 id、文件重新上传）；
   ④ 相册选择器路径：已上传媒体 id 直发（Web sendAlbumPick 语义）。 */
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart';
import 'package:love_space/core/chat/chat_media.dart';
import 'package:love_space/core/chat/chat_models.dart';
import 'package:love_space/core/chat/chat_state.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions options, int callIndex) handler;
  final List<RequestOptions> posts = [];
  int gets = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.method == 'POST') {
      posts.add(options);
      return handler(options, posts.length - 1);
    }
    return handler(options, gets++);
  }
}

ResponseBody jsonOk(Object data) => ResponseBody.fromString(
    jsonEncode(data), 200,
    headers: {Headers.contentTypeHeader: const ['application/json']});

ResponseBody _err422(String detail) => ResponseBody.fromString(
    jsonEncode({'detail': detail}), 422,
    headers: {Headers.contentTypeHeader: const ['application/json']});

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── ① 白名单 / 250MB 预检矩阵 ─────────────────────────────────────
  group('validateUploadFile 本地预检矩阵', () {
    test('白名单格式放行（大小写不敏感）', () {
      expect(validateUploadFile('a.jpg', 100), isNull);
      expect(validateUploadFile('a.JPG', 100), isNull);
      expect(validateUploadFile('a.jpeg', 100), isNull);
      expect(validateUploadFile('a.png', 100), isNull);
      expect(validateUploadFile('a.webp', 100), isNull);
      expect(validateUploadFile('a.gif', 100), isNull);
      expect(validateUploadFile('a.heic', 100), isNull);
      expect(validateUploadFile('a.mp4', 100), isNull);
      expect(validateUploadFile('a.mov', 100), isNull);
      expect(validateUploadFile('a.webm', 100), isNull);
      expect(validateUploadFile('a.m4a', 100), isNull);
      expect(validateUploadFile('a.mp3', 100), isNull);
      expect(validateUploadFile('a.wav', 100), isNull);
      expect(validateUploadFile('a.aac', 100), isNull);
      expect(validateUploadFile('a.ogg', 100), isNull);
    });

    test('非白名单格式拦截（无扩展名 / 文本 / 可执行）', () {
      expect(validateUploadFile('noext', 100), isNotNull);
      expect(validateUploadFile('a.txt', 100), isNotNull);
      expect(validateUploadFile('a.exe', 100), isNotNull);
      expect(validateUploadFile('a.pdf', 100), isNotNull);
    });

    test('250MB 上限：恰好 250MB 放行，超过本地先拦（不发请求）', () {
      expect(validateUploadFile('big.mp4', 250 * 1024 * 1024), isNull);
      expect(validateUploadFile('big.mp4', 250 * 1024 * 1024 + 1), isNotNull);
      final err = validateUploadFile('big.mp4', 300 * 1024 * 1024)!;
      expect(err, contains('250'));
    });

    test('mimeOfName 声明映射', () {
      expect(mimeOfName('a.jpg'), 'image/jpeg');
      expect(mimeOfName('a.m4a'), 'audio/mp4');
      expect(mimeOfName('a.webm'), 'video/webm');
      expect(mimeOfName('noext'), '');
    });
  });

  // ── ② 上传 → pending 态迁移 ──────────────────────────────────────
  test('媒体发送：pending 起于 upload 阶段 → send 阶段 → 成功后清除并入列表', () async {
    final store = _MemStore();
    final adapter = _FakeAdapter((options, callIndex) {
      if (options.uri.path == '/api/media') {
        return jsonOk(
            {'id': 'mid-${callIndex + 1}', 'mime': 'image/png', 'name': 'p.png', 'status': 'pending'});
      }
      if (options.uri.path == '/api/records') {
        final body = options.data as Map;
        return jsonOk({
          'id': 'srv-m1', 'kind': 'chat', 'author': 'u1',
          'body': body['body'], 'created': 2000.0, 'updated': 2000.0,
          'client_id': body['client_id'],
          'media': [
            for (final mid in (body['body'] as Map)['media'] as List)
              {'id': mid, 'name': 'p.png', 'mime': 'image/png', 'size': 1,
               'status': 'ready', 'preview': 'p.preview.jpg'},
          ],
        });
      }
      return jsonOk(const []); // GET 对账：无历史
    });
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final container = ProviderContainer(overrides: [
      dioProvider.overrideWith((ref) async => dio),
      chatPersistenceProvider.overrideWith((ref) async => store),
    ]);
    addTearDown(container.dispose);

    // 造一个真实存在的临时文件（上传链路要读本机文件）
    final file = File('${Directory.systemTemp.path}/chat_test_img.png');
    await file.writeAsBytes([1, 2, 3, 4]);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.bootstrap('u1');
    await controller.sendMedia(
        [ChatLocalFile(path: file.path, name: 'chat_test_img.png')],
        caption: '看图');

    final state = container.read(chatControllerProvider);
    expect(state.rows.whereType<ChatPendingRow>(), isEmpty); // 成功清除
    final recordRow = state.rows.whereType<ChatRecordRow>().single;
    expect(recordRow.record.body.mediaIds, ['mid-1']); // 记录 body.media 为上传 id
    expect(recordRow.record.body.content, '看图');
    expect(store.pendings, isEmpty);
    expect(adapter.posts.map((p) => p.uri.path).toList(),
        ['/api/media', '/api/records']); // 先传后发（两段式）
  });

  test('上传失败：pending 落盘保持 upload 阶段（重试会重新上传）', () async {
    final store = _MemStore();
    var mediaFailed = false;
    final adapter = _FakeAdapter((options, callIndex) {
      if (options.uri.path == '/api/media') {
        if (!mediaFailed) {
          mediaFailed = true;
          return _err422('文件内容与声明的类型不符，请重新选择');
        }
        return jsonOk({'id': 'm1', 'mime': 'image/png', 'name': 'p.png', 'status': 'pending'});
      }
      return jsonOk(const []);
    });
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final container = ProviderContainer(overrides: [
      dioProvider.overrideWith((ref) async => dio),
      chatPersistenceProvider.overrideWith((ref) async => store),
    ]);
    addTearDown(container.dispose);
    final file = File('${Directory.systemTemp.path}/chat_test_img2.png');
    await file.writeAsBytes([1, 2, 3]);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.bootstrap('u1');
    await expectLater(
        controller.sendMedia([ChatLocalFile(path: file.path, name: 'chat_test_img2.png')]),
        throwsA(anything));

    final row = container
        .read(chatControllerProvider)
        .rows
        .whereType<ChatPendingRow>()
        .single;
    expect(row.failed, true);
    final stored = store.pendings.values.single;
    expect(stored.phase, ChatPendingPhase.upload); // 落盘保持 upload：重试重传
    expect(stored.mediaFiles.single.path, file.path);
  });

  // ── ③ 媒体链路重试复用同一 client_id ──────────────────────────────
  test('媒体重试：同一 client_id、文件重新上传（POST /api/media 共 2 次）', () async {
    final store = _MemStore();
    var mediaFailed = true;
    final adapter = _FakeAdapter((options, callIndex) {
      if (options.uri.path == '/api/media') {
        if (mediaFailed) {
          mediaFailed = false;
          return _err422('图片文件损坏，请重新选择');
        }
        return jsonOk({'id': 'm1', 'mime': 'image/png', 'name': 'p.png', 'status': 'pending'});
      }
      if (options.uri.path == '/api/records') {
        final body = options.data as Map;
        return jsonOk({
          'id': 'srv-r', 'kind': 'chat', 'author': 'u1',
          'body': body['body'], 'created': 3000.0, 'updated': 3000.0,
          'client_id': body['client_id'],
          'media': [
            {'id': 'm1', 'name': 'p.png', 'mime': 'image/png', 'size': 1,
             'status': 'ready', 'preview': null},
          ],
        });
      }
      return jsonOk(const []);
    });
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final container = ProviderContainer(overrides: [
      dioProvider.overrideWith((ref) async => dio),
      chatPersistenceProvider.overrideWith((ref) async => store),
    ]);
    addTearDown(container.dispose);
    final file = File('${Directory.systemTemp.path}/chat_test_img3.png');
    await file.writeAsBytes([9, 9, 9]);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.bootstrap('u1');
    await expectLater(
        controller.sendMedia([ChatLocalFile(path: file.path, name: 'chat_test_img3.png')]),
        throwsA(anything));
    final clientId = container
        .read(chatControllerProvider)
        .rows
        .whereType<ChatPendingRow>()
        .single
        .clientId;

    await controller.retry(clientId);

    final state = container.read(chatControllerProvider);
    expect(state.rows.whereType<ChatPendingRow>(), isEmpty);
    expect(state.rows.whereType<ChatRecordRow>().single.record.clientId, clientId);
    // POST 顺序：媒体失败 → 媒体重传 → 记录发送；records 的 client_id 与首次生成一致
    final paths = adapter.posts.map((p) => p.uri.path).toList();
    expect(paths, ['/api/media', '/api/media', '/api/records']);
    expect((adapter.posts.last.data as Map)['client_id'], clientId);
    expect(store.pendings, isEmpty);
  });

  // ── ④ 相册选择器：已上传 id 直发 ─────────────────────────────────
  test('sendMediaIds：记录 body.content/media 直发（Web sendAlbumPick 语义）', () async {
    final store = _MemStore();
    final adapter = _FakeAdapter((options, _) {
      if (options.uri.path == '/api/records') {
        final body = options.data as Map;
        return jsonOk({
          'id': 'srv-a', 'kind': 'chat', 'author': 'u1',
          'body': body['body'], 'created': 4000.0, 'updated': 4000.0,
          'client_id': body['client_id'],
          'media': [
            {'id': 'm9', 'name': 'a.png', 'mime': 'image/png', 'size': 1,
             'status': 'ready', 'preview': null},
          ],
        });
      }
      return jsonOk(const []);
    });
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final container = ProviderContainer(overrides: [
      dioProvider.overrideWith((ref) async => dio),
      chatPersistenceProvider.overrideWith((ref) async => store),
    ]);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.bootstrap('u1');
    await controller.sendMediaIds(['m9'], caption: '说点啥');

    final record = container
        .read(chatControllerProvider)
        .rows
        .whereType<ChatRecordRow>()
        .single
        .record;
    expect(record.body.mediaIds, ['m9']);
    expect(record.body.content, '说点啥');
    expect(adapter.posts, hasLength(1)); // 无上传，只发记录
  });
}
