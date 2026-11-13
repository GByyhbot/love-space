/* 相册页段 D 单测（条目 5 · 视频专项 + 选图态设封面）：
   ① 数据层纯函数：parseVideos（video mime 提取、mid 去重最新优先、album/date/caption 回填）、
      videosForAlbum（客户端相册筛选）、mergePhotoVideo（统一日期排序、空 date 最后、跨类去重）
   ② 控制器：load 增拉 /api/records?kind=post&media_type=video、相册筛选入 items、
      startCoverPick / cancelCoverPick / pickCover（复用 setCover 回填铁律）、换相册/换视图清选图态
   ③ 网格 UI：视频瓦片 ▶ 角标 + 点击全屏播放（不进查看器）；选图态横幅出现/取消不误设/
      点照片即 PUT 设封面（media[0]） */
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
import 'package:love_space/features/chat/chat_toast.dart' show ChatToastHost;
import 'package:love_space/features/chat/video_player_page.dart';

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

/// 序列化 post 记录（D 段视频数据源：记录级 media 带 mime）
Map<String, Object> _postRecord(String id,
        {Map<String, Object> body = const {},
        List<Object> media = const []}) =>
    {
      'id': id, 'kind': 'post', 'author': 'u1',
      'body': body,
      'created': 1.0, 'updated': 1.0, 'client_id': '',
      'media': media,
      'likes': const <Object>[], 'comments': const <Object>[],
    };

Map<String, Object> _videoMedia(String id, {String mime = 'video/mp4'}) =>
    {'id': id, 'name': '$id.mp4', 'mime': mime, 'size': 1,
     'status': 'ready', 'preview': '$id.preview.mp4'};

Map<String, Object> _imageMedia(String id) =>
    {'id': id, 'name': '$id.jpg', 'mime': 'image/jpeg', 'size': 1,
     'status': 'ready', 'preview': '$id.preview.jpg'};

Map<String, Object> _photoEntry(String id, {String date = '2026-11-13'}) =>
    {
      'id': id, 'name': '$id.jpg', 'mime': 'image/jpeg',
      'owner': 'u1', 'status': 'ready', 'preview': '$id.preview.jpg',
      'record_id': 'rec-$id', 'date': date, 'caption': '',
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
  group('① 视频数据层纯函数', () {
    test('parseVideos：提取 video/* mid，album/date/caption 回填，图片跳过', () {
      final out = parseVideos([
        _postRecord('r1',
            body: {'album': 'a1', 'date': '2026-11-01', 'content': '海边视频',
                   'media': ['v1', 'p1']},
            media: [_videoMedia('v1'), _imageMedia('p1')]),
      ]);
      expect(out.length, 1, reason: '只收 video/*');
      expect(out.single.id, 'v1');
      expect(out.single.isVideo, isTrue);
      expect(out.single.album, 'a1');
      expect(out.single.date, '2026-11-01');
      expect(out.single.caption, '海边视频');
      expect(out.single.recordId, 'r1');
    });

    test('parseVideos：同一 mid 只出现一次（最新记录优先，date/album 取首条）', () {
      // 服务端 created 倒序 → 列表首条即最新记录（rNew 在前）
      final out = parseVideos([
        _postRecord('rNew',
            body: {'album': 'aA', 'date': '2026-11-01', 'media': ['v1']},
            media: [_videoMedia('v1')]),
        _postRecord('rOld',
            body: {'album': 'aB', 'date': '2026-01-01', 'media': ['v1']},
            media: [_videoMedia('v1')]),
      ]);
      expect(out.length, 1);
      expect(out.single.album, 'aA', reason: '首条=最新记录，其归属生效');
      expect(out.single.date, '2026-11-01');
    });

    test('parseVideos：畸形条目容错，非列表返回空', () {
      expect(parseVideos(null), isEmpty);
      expect(parseVideos({'x': 1}), isEmpty);
      expect(parseVideos(['junk', 42]), isEmpty);
    });

    test('videosForAlbum：空=全部，非空按 body.album 筛', () {
      final videos = [
        PhotoItem(id: 'v1', mime: 'video/mp4', album: 'a1'),
        PhotoItem(id: 'v2', mime: 'video/mp4', album: 'a2'),
        PhotoItem(id: 'v3', mime: 'video/mp4'),
      ];
      expect(videosForAlbum(videos, '').map((v) => v.id).toList(),
          ['v1', 'v2', 'v3']);
      expect(videosForAlbum(videos, 'a1').map((v) => v.id).toList(), ['v1']);
    });

    test('mergePhotoVideo：照片+视频统一 date 倒序，空 date 最后，跨类去重', () {
      final photos = [
        PhotoItem(id: 'p1', mime: 'image/jpeg', date: '2026-11-02'),
        PhotoItem(id: 'p2', mime: 'image/jpeg', date: ''),
      ];
      final videos = [
        PhotoItem(id: 'v1', mime: 'video/mp4', date: '2026-11-01'),
        PhotoItem(id: 'v2', mime: 'video/mp4', date: '2026-11-03'),
      ];
      final merged = mergePhotoVideo(photos, videos);
      expect(merged.map((e) => e.id).toList(),
          ['v2', 'p1', 'v1', 'p2'], reason: 'date 倒序统一穿插，空 date 最后');
      // 跨类同 mid 兜底去重
      final dup = mergePhotoVideo(
          [PhotoItem(id: 'x', mime: 'image/jpeg')],
          [PhotoItem(id: 'x', mime: 'video/mp4')]);
      expect(dup.length, 1);
    });
  });

  // ── ② 控制器 ─────────────────────────────────────────────────
  group('② 控制器（视频加载 + 选图态）', () {
    test('load：增拉 /api/records?kind=post&media_type=video，items 合并', () async {
      final adapter = _FakeAdapter((options, i) {
        if (options.uri.path == '/api/photos') {
          return _json([_photoEntry('p1', date: '2026-11-02')]);
        }
        if (options.uri.path == '/api/records') {
          if (options.uri.queryParameters['media_type'] == 'video') {
            return _json([
              _postRecord('r1',
                  body: {'album': 'a1', 'date': '2026-11-01',
                         'content': 'c', 'media': ['v1']},
                  media: [_videoMedia('v1')]),
            ]);
          }
          return _json([_albumRecord('a1', '旅行')]);
        }
        return _json([]);
      });
      final container = await _setup(adapter);
      final st = container.read(albumControllerProvider);
      final videosReq = adapter.requests
          .firstWhere((r) => r.uri.path == '/api/records'
              && r.queryParameters['media_type'] == 'video');
      expect(videosReq.queryParameters['kind'], 'post');
      expect(st.videos.single.id, 'v1');
      expect(st.photos.single.id, 'p1');
      expect(st.items.map((e) => e.id).toList(), ['p1', 'v1'],
          reason: '统一 date 倒序：11-02 照片在前');
    });

    test('相册筛选：items 只含该相册视频（照片由服务端筛）', () async {
      final adapter = _FakeAdapter((options, i) {
        if (options.uri.path == '/api/photos') {
          return _json([_photoEntry('p1')]);
        }
        if (options.uri.path == '/api/records') {
          if (options.uri.queryParameters['media_type'] == 'video') {
            return _json([
              _postRecord('r1',
                  body: {'album': 'a1', 'date': '2026-11-01', 'media': ['v1']},
                  media: [_videoMedia('v1')]),
              _postRecord('r2',
                  body: {'album': 'a2', 'date': '2026-11-02', 'media': ['v2']},
                  media: [_videoMedia('v2')]),
              _postRecord('r3',
                  body: {'date': '2026-11-03', 'media': ['v3']},
                  media: [_videoMedia('v3')]),
            ]);
          }
          return _json([_albumRecord('a1', '旅行')]);
        }
        return _json([]);
      });
      final container = await _setup(adapter);
      expect(container.read(albumControllerProvider).items.length, 4,
          reason: '全部照片视图：1 照片 + 3 视频');
      await container
          .read(albumControllerProvider.notifier)
          .selectAlbum('a1');
      final st = container.read(albumControllerProvider);
      expect(st.items.map((e) => e.id).toSet(), {'p1', 'v1'},
          reason: 'a1 相册内：服务端筛照片 + 客户端按 body.album 筛视频');
    });

    test('startCoverPick → pickCover：PUT media[0]=选中 mid（回填铁律），选图态退出', () async {
      final originalBody = {'title': '旅行', 'media': ['old'], 'layout': 'grid'};
      final captured = <String, dynamic>{};
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'GET' && options.uri.path == '/api/records/a1') {
          return _json({'id': 'a1', 'kind': 'album', 'body': originalBody});
        }
        if (options.method == 'PUT' && options.uri.path == '/api/records/a1') {
          captured.addAll((options.data as Map).cast<String, dynamic>());
          return _json({'id': 'a1', 'kind': 'album', 'body': options.data['body']});
        }
        if (options.uri.path == '/api/photos') return _json([_photoEntry('p1')]);
        if (options.uri.path == '/api/records') {
          if (options.uri.queryParameters['media_type'] == 'video') {
            return _json([]);
          }
          return _json([_albumRecord('a1', '旅行', media: ['old'])]);
        }
        return _json([]);
      });
      final container = await _setup(adapter);
      final ctrl = container.read(albumControllerProvider.notifier);
      await ctrl.startCoverPick('a1');
      var st = container.read(albumControllerProvider);
      expect(st.coverPickAlbum, 'a1');
      expect(st.selectedAlbum, 'a1');
      final err = await ctrl.pickCover('p1');
      expect(err, isNull);
      expect((captured['body'] as Map)['media'][0], 'p1',
          reason: '封面置 media[0]');
      expect((captured['body'] as Map)['layout'], 'grid',
          reason: '回填铁律：未知字段原样带回');
      st = container.read(albumControllerProvider);
      expect(st.coverPickAlbum, '', reason: '设完退出选图态');
    });

    test('cancelCoverPick：取消不改封面；换相册/换视图自动清选图态', () async {
      final adapter = _FakeAdapter((options, i) {
        if (options.uri.path == '/api/photos') return _json([_photoEntry('p1')]);
        if (options.uri.path == '/api/records') {
          if (options.uri.queryParameters['media_type'] == 'video') {
            return _json([]);
          }
          return _json([_albumRecord('a1', '旅行'), _albumRecord('a2', '日常')]);
        }
        return _json([]);
      });
      final container = await _setup(adapter);
      final ctrl = container.read(albumControllerProvider.notifier);
      await ctrl.startCoverPick('a1');
      expect(container.read(albumControllerProvider).coverPickAlbum, 'a1');
      ctrl.cancelCoverPick();
      expect(container.read(albumControllerProvider).coverPickAlbum, '');
      final puts = adapter.requests
          .where((r) => r.method == 'PUT')
          .toList();
      expect(puts, isEmpty, reason: '取消不误设封面');

      await ctrl.startCoverPick('a1');
      await ctrl.selectAlbum('a2');
      expect(container.read(albumControllerProvider).coverPickAlbum, '',
          reason: '换相册即取消选图态');

      await ctrl.startCoverPick('a1');
      ctrl.setView(AlbumView.byTime);
      expect(container.read(albumControllerProvider).coverPickAlbum, '',
          reason: '换视图即取消选图态');
    });
  });

  // ── ③ 网格 UI：视频瓦片 + 选图态 ─────────────────────────────
  group('③ 网格 UI（视频/选图态）', () {
    ProviderContainer widgetSetup(_FakeAdapter adapter) {
      final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
        ..httpClientAdapter = adapter;
      return ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
        chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
        mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
      ]);
    }

    Future<void> pumpPage(WidgetTester tester, ProviderContainer container) async {
      // 与 main.dart 真实架构一致：MaterialApp.builder 挂全局 ChatToastHost
      // （顶部通知断言依赖它）
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => Stack(children: [
            child ?? const SizedBox.shrink(),
            const Positioned(
                top: 0, left: 0, right: 0,
                child: IgnorePointer(child: SafeArea(child: ChatToastHost()))),
          ]),
          home: const AlbumPage(active: true),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('视频瓦片：▶ 角标可见、点击全屏播放页（照片不进视频路径）', (tester) async {
      final adapter = _FakeAdapter((options, i) {
        if (options.uri.path == '/api/photos') {
          return _json([_photoEntry('p1')]);
        }
        if (options.uri.path == '/api/records') {
          if (options.uri.queryParameters['media_type'] == 'video') {
            return _json([
              _postRecord('r1',
                  body: {'date': '2026-11-01', 'media': ['v1']},
                  media: [_videoMedia('v1')]),
            ]);
          }
          return _json([_albumRecord('a1', '旅行')]);
        }
        return _json([]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget,
          reason: '视频瓦片带 ▶ 角标');
      expect(find.byType(VideoPlayerPage), findsNothing);

      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(VideoPlayerPage), findsOneWidget,
          reason: '点视频瓦片 → 全屏播放页（iepose 线已实测链路）');
      // 播放页错误兜底文本（测试环境无视频插件，_setup 捕获后显示错误）
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('视频播放'), findsOneWidget);
    });

    testWidgets('选图态：⋯ 菜单设为封面 → 横幅出现 → 取消不误设；点照片即 PUT', (tester) async {
      var putCount = 0;
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'GET' && options.uri.path == '/api/records/a1') {
          return _json({'id': 'a1', 'kind': 'album',
              'body': {'title': '旅行', 'media': ['old']}});
        }
        if (options.method == 'PUT' && options.uri.path == '/api/records/a1') {
          putCount++;
          return _json({'id': 'a1', 'kind': 'album', 'body': options.data['body']});
        }
        if (options.uri.path == '/api/photos') {
          return _json([_photoEntry('p1')]);
        }
        if (options.uri.path == '/api/records') {
          if (options.uri.queryParameters['media_type'] == 'video') {
            return _json([
              _postRecord('r1',
                  body: {'album': 'a1', 'date': '2026-11-01', 'media': ['v1']},
                  media: [_videoMedia('v1')]),
            ]);
          }
          return _json([_albumRecord('a1', '旅行', media: ['old'])]);
        }
        return _json([]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      // 打开相册卡 ⋯ 菜单 → 设为封面
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设为封面'));
      await tester.pumpAndSettle();
      expect(find.text('点一张设为封面'), findsOneWidget, reason: '选图态横幅明示');

      // 取消：横幅消失，不发 PUT
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('点一张设为封面'), findsNothing);
      expect(putCount, 0, reason: '取消不误设封面');

      // 再进选图态：点照片（Hero 瓦片）→ PUT media[0]=p1 + 顶部通知 + 横幅退出
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设为封面'));
      await tester.pumpAndSettle();
      await tester.tap(find.byWidgetPredicate(
          (w) => w is Hero && w.tag == 'album-photo-p1'));
      await tester.pumpAndSettle();
      expect(putCount, 1, reason: '点中照片即设封面');
      final put = adapter.requests
          .firstWhere((r) => r.method == 'PUT' && r.uri.path == '/api/records/a1');
      expect(((put.data as Map)['body'] as Map)['media'][0], 'p1');
      expect(find.text('已设为封面'), findsOneWidget, reason: '顶部通知确认');
      expect(find.text('点一张设为封面'), findsNothing, reason: '设完退出选图态');
      // 让顶部通知自动收起定时器走完，避免测试结束仍挂起
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('选图态视频瓦片不可点（封面须为照片）', (tester) async {
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'GET' && options.uri.path == '/api/records/a1') {
          return _json({'id': 'a1', 'kind': 'album',
              'body': {'title': '旅行', 'media': <Object>[]}});
        }
        if (options.uri.path == '/api/photos') return _json([]);
        if (options.uri.path == '/api/records') {
          if (options.uri.queryParameters['media_type'] == 'video') {
            return _json([
              _postRecord('r1',
                  body: {'album': 'a1', 'date': '2026-11-01', 'media': ['v1']},
                  media: [_videoMedia('v1')]),
            ]);
          }
          return _json([_albumRecord('a1', '旅行')]);
        }
        return _json([]);
      });
      final container = widgetSetup(adapter);
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设为封面'));
      await tester.pumpAndSettle();
      expect(find.text('点一张设为封面'), findsOneWidget);

      // 点视频瓦片：不进播放页、不发 PUT（封面须为照片）
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(VideoPlayerPage), findsNothing,
          reason: '选图态视频点按禁用');
      expect(
          adapter.requests.where((r) => r.method == 'PUT'), isEmpty);
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
