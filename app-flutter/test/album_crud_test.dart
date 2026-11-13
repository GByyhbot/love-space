/* 相册页段 C 单测（条目 5 · 增删改与上传 + 封面）：
   ① 数据层纯函数：AlbumInfo 封面解析、mergeAlbumBody 回填铁律（改名保留封面/未知字段）
   ② 控制器：createAlbum / renameAlbum（回填铁律专项：先设封面再改名封面还在）/
      setCover（media[0] 置顶 / 空 mid 清空）/ deleteAlbum（删后切回全部、相册列表剔除）
   ③ 相册页 UI：新建相册弹层「取消」不触发 POST、「确认」才 POST（返回路径可取消验收） */
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/album/album_data.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import 'package:love_space/features/album/album_controller.dart';
import 'package:love_space/features/album/album_page.dart';

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

Map<String, Object> _albumRecord(String id, String title,
        {List<Object> media = const []}) =>
    {
      'id': id, 'kind': 'album', 'author': 'u1',
      'body': {'title': title, 'media': media},
      'created': 1.0, 'updated': 1.0, 'client_id': '', 'media': const <Object>[],
      'likes': const <Object>[], 'comments': const <Object>[],
    };

Future<ProviderContainer> _setup(_FakeAdapter adapter) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  final container = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
  ]);
  addTearDown(container.dispose);
  await container.read(albumControllerProvider.notifier).bootstrap();
  return container;
}

void main() {
  // ── ① 数据层纯函数 ───────────────────────────────────────────
  group('① 数据层纯函数', () {
    test('AlbumInfo.fromRecord：解析封面 mid（body.media[0]），无则空', () {
      expect(AlbumInfo.fromRecord(_albumRecord('a1', '旅行', media: ['m1', 'm2'])).cover,
          'm1');
      expect(AlbumInfo.fromRecord(_albumRecord('a2', '空')).cover, '');
    });

    test('mergeAlbumBody：改名保留封面与未知字段（回填铁律）', () {
      final original = {'title': '旅行', 'media': ['coverMid'], 'layout': 'grid'};
      final merged = mergeAlbumBody(original, {'title': '蜜月'});
      expect(merged['title'], '蜜月'); // 覆盖
      expect(merged['media'], ['coverMid']); // 封面仍在
      expect(merged['layout'], 'grid'); // 未知字段原样带回
    });
  });

  // ── ② 控制器 ─────────────────────────────────────────────────
  group('② 控制器 CRUD', () {
    test('createAlbum：POST kind=album，成功後列表新增该相册', () async {
      var posted = false;
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'POST' && options.uri.path == '/api/records') {
          posted = true;
          return _json({
            'id': 'aNew',
            'kind': 'album',
            'body': {'title': (options.data['body'] as Map)['title']}
          });
        }
        if (options.uri.path == '/api/photos') return _json([]);
        if (options.uri.path == '/api/records') {
          // 重拉分类：POST 之后才返回新相册
          return posted ? _json([_albumRecord('aNew', '我的相册')]) : _json([]);
        }
        return _json([]);
      });
      final container = await _setup(adapter);
      final err =
          await container.read(albumControllerProvider.notifier).createAlbum('我的相册');
      expect(err, isNull);
      expect(
          container.read(albumControllerProvider).albums.any((a) => a.title == '我的相册'),
          isTrue);
      final post = adapter.requests
          .firstWhere((r) => r.method == 'POST' && r.uri.path == '/api/records');
      expect(post.data['kind'], 'album');
      expect((post.data['body'] as Map)['title'], '我的相册');
    });

    test('createAlbum：标题为空直接报错，不请求', () async {
      final adapter = _FakeAdapter((options, i) {
        if (options.uri.path == '/api/photos') return _json([]);
        if (options.uri.path == '/api/records') return _json([]);
        return _json([]);
      });
      final container = await _setup(adapter);
      final err =
          await container.read(albumControllerProvider.notifier).createAlbum('   ');
      expect(err, isNotNull);
      expect(
          adapter.requests
              .any((r) => r.method == 'POST' && r.uri.path == '/api/records'),
          isFalse);
    });

    test('renameAlbum：回填铁律专项——先设封面再改名，封面与未知字段仍在', () async {
      final originalBody = {'title': '旅行', 'media': ['coverMid'], 'layout': 'grid'};
      final captured = <String, dynamic>{};
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'GET' && options.uri.path == '/api/records/a1') {
          return _json({'id': 'a1', 'kind': 'album', 'body': originalBody});
        }
        if (options.method == 'PUT' && options.uri.path == '/api/records/a1') {
          captured.addAll((options.data as Map).cast<String, dynamic>());
          return _json({'id': 'a1', 'kind': 'album', 'body': options.data['body']});
        }
        if (options.uri.path == '/api/photos') return _json([]);
        if (options.uri.path == '/api/records') {
          return _json([_albumRecord('a1', '新名', media: ['coverMid'])]);
        }
        return _json([]);
      });
      final container = await _setup(adapter);
      final err = await container
          .read(albumControllerProvider.notifier)
          .renameAlbum('a1', '新名');
      expect(err, isNull);
      expect(captured['kind'], 'album');
      expect((captured['body'] as Map)['title'], '新名');
      expect((captured['body'] as Map)['media'], ['coverMid']); // 封面还在
      expect((captured['body'] as Map)['layout'], 'grid'); // 未知字段带回
    });

    test('setCover：把照片 mid 置到 media[0]（换封面）', () async {
      final originalBody = {'title': '旅行', 'media': ['oldCover']};
      final captured = <String, dynamic>{};
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'GET' && options.uri.path == '/api/records/a1') {
          return _json({'id': 'a1', 'kind': 'album', 'body': originalBody});
        }
        if (options.method == 'PUT' && options.uri.path == '/api/records/a1') {
          captured.addAll((options.data as Map).cast<String, dynamic>());
          return _json({'id': 'a1', 'kind': 'album', 'body': options.data['body']});
        }
        if (options.uri.path == '/api/photos') return _json([]);
        if (options.uri.path == '/api/records') {
          return _json([_albumRecord('a1', '旅行', media: ['newMid'])]);
        }
        return _json([]);
      });
      final container = await _setup(adapter);
      final err = await container
          .read(albumControllerProvider.notifier)
          .setCover('a1', 'newMid');
      expect(err, isNull);
      expect((captured['body'] as Map)['media'][0], 'newMid');
    });

    test('setCover：空 mid 清空封面（media=[]，无封面回退）', () async {
      final originalBody = {'title': '旅行', 'media': ['oldCover']};
      final captured = <String, dynamic>{};
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'GET' && options.uri.path == '/api/records/a1') {
          return _json({'id': 'a1', 'kind': 'album', 'body': originalBody});
        }
        if (options.method == 'PUT' && options.uri.path == '/api/records/a1') {
          captured.addAll((options.data as Map).cast<String, dynamic>());
          return _json({'id': 'a1', 'kind': 'album', 'body': options.data['body']});
        }
        if (options.uri.path == '/api/photos') return _json([]);
        if (options.uri.path == '/api/records') return _json([_albumRecord('a1', '旅行')]);
        return _json([]);
      });
      final container = await _setup(adapter);
      final err = await container
          .read(albumControllerProvider.notifier)
          .setCover('a1', '');
      expect(err, isNull);
      expect((captured['body'] as Map)['media'], isEmpty);
    });

    test('deleteAlbum：DELETE 后切回全部照片，且相册列表剔除该相册', () async {
      var deleted = false;
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'DELETE' && options.uri.path == '/api/records/a1') {
          deleted = true;
          return _json({'ok': true});
        }
        if (options.uri.path == '/api/photos') return _json([]);
        if (options.uri.path == '/api/records') {
          // 初始有 a1；删除后 load 重拉返回空列表
          return deleted ? _json([]) : _json([_albumRecord('a1', '旅行')]);
        }
        return _json([]);
      });
      final container = await _setup(adapter);
      expect(
          container.read(albumControllerProvider).albums.any((a) => a.id == 'a1'), isTrue);
      final err = await container
          .read(albumControllerProvider.notifier)
          .deleteAlbum('a1');
      expect(err, isNull);
      final st = container.read(albumControllerProvider);
      expect(st.selectedAlbum, '', reason: '删后切回全部照片');
      expect(st.albums.any((a) => a.id == 'a1'), isFalse,
          reason: '相册列表剔除已删相册');
      expect(
          adapter.requests
              .any((r) => r.method == 'DELETE' && r.uri.path == '/api/records/a1'),
          isTrue);
    });
  });

  // ── ③ 相册页 UI：新建相册弹层可取消 ─────────────────────────
  group('③ 新建相册弹层', () {
    ProviderContainer widgetSetup(_FakeAdapter adapter) {
      final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
        ..httpClientAdapter = adapter;
      return ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
        mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
      ]);
    }

    testWidgets('取消不创建，确认才 POST kind=album', (tester) async {
      final adapter = _FakeAdapter((options, i) {
        if (options.uri.path == '/api/photos') return _json([]);
        if (options.uri.path == '/api/records') return _json([]);
        if (options.method == 'POST' && options.uri.path == '/api/records') {
          return _json({'id': 'aNew', 'kind': 'album', 'body': {'title': 'x'}});
        }
        return _json([]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AlbumPage(active: true)),
      ));
      await tester.pumpAndSettle();

      // 打开新建相册弹层（+ 卡：用 InkWell 精确命中卡片，避开弹层标题同名文字）
      await tester.tap(find.widgetWithText(InkWell, '新建相册'));
      await tester.pumpAndSettle();
      expect(find.text('新建相册'), findsWidgets); // 卡片 + 弹层标题
      // 取消：不应触发 POST
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
          adapter.requests
              .any((r) => r.method == 'POST' && r.uri.path == '/api/records'),
          isFalse,
          reason: '取消不创建');

      // 再次打开，输入并确认
      await tester.tap(find.widgetWithText(InkWell, '新建相册'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '测试相册');
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      final post = adapter.requests
          .firstWhere((r) => r.method == 'POST' && r.uri.path == '/api/records');
      expect(post.data['kind'], 'album');
      expect((post.data['body'] as Map)['title'], '测试相册');
      // 让顶部通知的自动收起定时器触发，避免测试结束时仍挂起
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
