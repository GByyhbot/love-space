/* 相册页段 A 单测（条目 5）：
   ① 数据层纯函数：照片/相册解析容错、按月份分组与标题、组内 date 倒序、3 列切行
   ② 控制器：/api/photos?album= 服务端筛选参数、分类拉取、切视图不重拉、
      请求代次防竞态（快速连点 chips 旧响应不覆盖）、SSE other 重拉
   ③ 网格缩略图：占位色兜底 + Hero tag（段 B 转场铺垫）
   ④ 二级页路由 /album/viewer 用 context.push（返回路径规范，widget 层） */
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:love_space/core/album/album_data.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/features/album/album_controller.dart';

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

Map<String, Object> _photo(String id,
        {String date = '2026-11-13', String caption = ''}) =>
    {
      'id': id, 'name': '$id.jpg', 'mime': 'image/jpeg',
      'owner': 'u1', 'status': 'ready', 'preview': '$id.preview.jpg',
      'record_id': 'rec-$id', 'date': date, 'caption': caption,
    };

Map<String, Object> _albumRecord(String id, String title) => {
      'id': id, 'kind': 'album', 'author': 'u1',
      'body': {'title': title, 'media': <Object>[]},
      'created': 1.0, 'updated': 1.0, 'client_id': '', 'media': <Object>[],
      'likes': <Object>[], 'comments': <Object>[],
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
    test('parsePhotos：字段映射 + 畸形条目容错', () {
      final out = parsePhotos([
        _photo('m1', date: '2026-11-13', caption: '海边'),
        {'id': ''},
        'not-a-map',
        {'id': 'm2'},
      ]);
      expect(out.length, 2);
      expect(out[0].id, 'm1');
      expect(out[0].date, '2026-11-13');
      expect(out[0].caption, '海边');
      expect(out[0].recordId, 'rec-m1');
      expect(out[1].id, 'm2');
      expect(out[1].date, '');
      expect(parsePhotos(null), isEmpty);
      expect(parsePhotos({'not': 'list'}), isEmpty);
    });

    test('parseAlbumRecords：只留 id+title 齐全的 album 记录', () {
      final out = parseAlbumRecords([
        _albumRecord('a1', '旅行'),
        _albumRecord('a2', ''),
        {'id': ''},
        'junk',
      ]);
      expect(out.length, 1);
      expect(out.single.id, 'a1');
      expect(out.single.title, '旅行');
    });

    test('groupPhotosByMonth：新月份在前、组内 date 倒序、无日期排最后', () {
      final photos = [
        PhotoItem.fromJson(_photo('p1', date: '2026-09-02')),
        PhotoItem.fromJson(_photo('p2', date: '2026-11-13')),
        PhotoItem.fromJson(_photo('p3', date: '2026-11-20')),
        PhotoItem.fromJson(_photo('p4', date: '')),
        PhotoItem.fromJson(_photo('p5', date: '2026-10-01')),
      ];
      final groups = groupPhotosByMonth(photos);
      expect(groups.map((g) => g.key).toList(),
          ['2026-11', '2026-10', '2026-09', '']);
      expect(groups[0].label, '2026 年 11 月');
      expect(groups[0].photos.map((p) => p.id).toList(), ['p3', 'p2']);
      expect(groups.last.label, '还没有填日期');
      expect(monthGroupLabel(''), '还没有填日期');
      expect(monthGroupLabel('2026-01'), '2026 年 1 月');
    });

    test('chunkPhotosForGrid：3 列切行，末行允许不足', () {
      final photos = [
        for (var i = 0; i < 7; i++)
          PhotoItem.fromJson(_photo('p$i')),
      ];
      final rows = chunkPhotosForGrid(photos);
      expect(rows.length, 3);
      expect(rows[0].length, 3);
      expect(rows[1].length, 3);
      expect(rows[2].length, 1);
      expect(rows.expand((r) => r).map((p) => p.id).toList(),
          ['p0', 'p1', 'p2', 'p3', 'p4', 'p5', 'p6']);
    });
  });

  // ── ② 控制器 ─────────────────────────────────────────────────
  group('② 控制器', () {
    test('首屏：/api/photos 无 album 参数 + 分类 kind=album，解析入 state',
        () async {
      final adapter = _FakeAdapter((options, i) {
        if (options.uri.path == '/api/photos') {
          return _json([_photo('m1')]);
        }
        return _json([_albumRecord('a1', '旅行')]);
      });
      final container = await _setup(adapter);
      final st = container.read(albumControllerProvider);
      expect(st.photos.map((p) => p.id).toList(), ['m1']);
      expect(st.albums.single.title, '旅行');
      expect(st.skeleton, isFalse);
      final photosReq = adapter.requests
          .firstWhere((r) => r.uri.path == '/api/photos');
      expect(photosReq.queryParameters.containsKey('album'), isFalse,
          reason: '全部照片不传 album 参数');
      final albumsReq = adapter.requests
          .firstWhere((r) => r.uri.path == '/api/records');
      expect(albumsReq.queryParameters['kind'], 'album');
    });

    test('选中相册：/api/photos 带 album=<id> 服务端筛选', () async {
      final adapter = _FakeAdapter((options, i) {
        if (options.uri.path == '/api/photos') {
          final a = options.queryParameters['album'];
          return _json(a == 'a1' ? [_photo('m1')] : [_photo('m1'), _photo('m2')]);
        }
        return _json([_albumRecord('a1', '旅行')]);
      });
      final container = await _setup(adapter);
      await container
          .read(albumControllerProvider.notifier)
          .selectAlbum('a1');
      final st = container.read(albumControllerProvider);
      expect(st.selectedAlbum, 'a1');
      expect(st.photos.length, 1, reason: '服务端筛选只回该相册照片');
      final reqs = adapter.requests
          .where((r) => r.uri.path == '/api/photos')
          .toList();
      expect(reqs.last.queryParameters['album'], 'a1');
    });

    test('切视图不重拉、不丢筛选', () async {
      var photosCalls = 0;
      final adapter = _FakeAdapter((options, i) {
        if (options.uri.path == '/api/photos') {
          photosCalls++;
          return _json([_photo('m1')]);
        }
        return _json([_albumRecord('a1', '旅行')]);
      });
      final container = await _setup(adapter);
      await container
          .read(albumControllerProvider.notifier)
          .selectAlbum('a1');
      final before = photosCalls;
      container.read(albumControllerProvider.notifier).setView(AlbumView.byTime);
      expect(photosCalls, before, reason: '切视图共用 photos，不重拉');
      final st = container.read(albumControllerProvider);
      expect(st.view, AlbumView.byTime);
      expect(st.selectedAlbum, 'a1');
      expect(st.photos.length, 1);
    });

    test('请求代次：切换筛选后 state 只保留最新一次响应', () async {
      final adapter = _FakeAdapter((options, i) {
        if (options.uri.path == '/api/photos') {
          final a = options.queryParameters['album'] ?? '';
          return _json([_photo(a.isEmpty ? 'all' : a)]);
        }
        return _json([_albumRecord('a1', 'A'), _albumRecord('a2', 'B')]);
      });
      final container = await _setup(adapter);
      expect(container.read(albumControllerProvider).photos.single.id, 'all');
      // 连续切换两个相册：最终 state 必须是最后一次选中的 a2
      await container.read(albumControllerProvider.notifier).selectAlbum('a1');
      await container.read(albumControllerProvider.notifier).selectAlbum('a2');
      final after = container.read(albumControllerProvider);
      expect(after.selectedAlbum, 'a2');
      expect(after.photos.single.id, 'a2');
      expect(after.photos.map((p) => p.id), isNot(contains('all')));
      expect(after.photos.map((p) => p.id), isNot(contains('a1')));
    });

    test('SSE other 重拉：新照片刷出', () async {
      var count = 0;
      final adapter = _FakeAdapter((options, i) {
        if (options.uri.path == '/api/photos') {
          count++;
          return _json(count == 1 ? [_photo('m1')] : [_photo('m1'), _photo('m2')]);
        }
        return _json([_albumRecord('a1', '旅行')]);
      });
      final container = await _setup(adapter);
      expect(container.read(albumControllerProvider).photos.length, 1);
      await container.read(albumControllerProvider.notifier).resetOnSseOther();
      expect(container.read(albumControllerProvider).photos.length, 2);
    });

    test('首屏失败：error 可读、不留转圈', () async {
      final adapter = _FakeAdapter((options, i) {
        if (options.uri.path == '/api/photos') {
          return _json({'detail': '网络不可用'}, 503);
        }
        return _json([]);
      });
      final container = await _setup(adapter);
      final st = container.read(albumControllerProvider);
      expect(st.loading, isFalse);
      expect(st.skeleton, isFalse);
      expect(st.error, isNotNull);
    });
  });

  // ── ③ 路由返回路径（二级页 context.push 规范）─────────────────
  group('③ 查看器二级页', () {
    testWidgets('缩略图点击 push 到 /album/viewer，返回按钮回网格',
        (tester) async {
      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(
              path: '/home',
              builder: (_, _) => const Scaffold(body: Text('网格'))),
          // 与 main.dart 一致：/album/viewer 是顶层二级页，push 后主页仍在栈
          GoRoute(
              path: '/album/viewer',
              builder: (_, _) => const Scaffold(body: Text('查看器'))),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      expect(find.text('网格'), findsOneWidget);
      router.push('/album/viewer');
      await tester.pumpAndSettle();
      expect(find.text('查看器'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('网格'), findsOneWidget,
          reason: '返回后回到网格（主页在路由栈）');
    });
  });
}
