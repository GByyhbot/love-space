/// 2.8.4 缺陷一护栏：编辑已有记录时，附件必须与新建态同形态预览。
///
/// 报障现象：编辑页只显示 `media:fa719…` 这种原始 token 芯片，无缩略图、
/// 点不开——已添加的图/视频/音频只能盲删或盲留。
/// 根因：`_initFromEditRecord` 把 body.media 的 id 塞进 `localFile.name`
/// 当文件名显示，而渲染层只画名字。
///
/// 这里钉死三件事：
/// ① token 原文不再出现在界面上；
/// ② 图片给缩略图且可点开查看器；
/// ③ 视频 / 音频各自可达预览入口（VideoCardView / 音频试听块）。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/features/chat/media_bubble_widgets.dart'
    show MediaImageView, VideoCardView;
import 'package:love_space/features/timeline/composer_sheet.dart';
import 'package:love_space/features/timeline/image_viewer.dart'
    show ImageViewerPage;

/// 任何 GET 都回空数组：composer 初始化时只会拉相册等列表，本测试不关心。
class _QuietAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromString(jsonEncode(<Object>[]), 200, headers: {
      Headers.contentTypeHeader: const <String>['application/json'],
    });
  }
}

api.Record _record(String mid, String mime, String name) => api.Record.fromJson(
      <String, dynamic>{
        'id': 'r1',
        'kind': 'post',
        'author': 'u1',
        'created': 1700000000.0,
        'body': <String, dynamic>{
          'content': '海边的一天',
          'media': <String>[mid],
        },
        // 服务端 serialize_many 会带 media 元数据（id/mime/name）
        'media': <Object>[
          <String, dynamic>{'id': mid, 'mime': mime, 'name': name},
        ],
      },
    );

Future<void> _openEdit(WidgetTester tester, api.Record rec) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      api.dioProvider.overrideWith((ref) async =>
          Dio(BaseOptions(baseUrl: 'https://test.local'))
            ..httpClientAdapter = _QuietAdapter()),
    ],
    child: const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
  ));
  final ctx = tester.element(find.byType(Scaffold));
  showComposerSheet(ctx, editRecord: rec, editKind: rec.kind);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('编辑态带图：出现缩略图、可点开查看器，且不露 token', (tester) async {
    await _openEdit(tester, _record('m-img', 'image/jpeg', '海边.jpg'));

    expect(find.byType(MediaImageView), findsOneWidget,
        reason: '已有图片必须有缩略图，不能退化成 token 芯片');
    expect(find.text('海边.jpg'), findsOneWidget, reason: '显示真实文件名');
    expect(find.textContaining('media:m-img'), findsNothing,
        reason: 'token 原文不许直接露给用户');

    // 点击缩略图 → 既有全屏查看器
    await tester.tap(find.byKey(const ValueKey('composer-media-open-m-img')));
    // 不用 pumpAndSettle：查看器里的网络图在测试环境永远加载不完，
    // settle 会等到超时。推路由是同步的，单帧即可断言。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(ImageViewerPage), findsOneWidget,
        reason: '点击应打开既有查看器');
  });

  testWidgets('编辑态带视频：出现视频卡片（可进播放页）', (tester) async {
    await _openEdit(tester, _record('m-vid', 'video/mp4', '浪.mp4'));

    expect(find.byType(VideoCardView), findsOneWidget,
        reason: '已有视频必须有封面/播放入口');
    expect(find.textContaining('media:m-vid'), findsNothing);
  });

  testWidgets('编辑态带音频：出现试听块', (tester) async {
    await _openEdit(tester, _record('m-aud', 'audio/mp4', '海浪声.m4a'));

    expect(find.byKey(const ValueKey('composer-media-audio-m-aud')),
        findsOneWidget, reason: '已有音频必须可试听');
    expect(find.textContaining('media:m-aud'), findsNothing);
  });

  testWidgets('新建态仍显示本地文件名（回归：老行为不变）', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        api.dioProvider.overrideWith((ref) async =>
            Dio(BaseOptions(baseUrl: 'https://test.local'))
              ..httpClientAdapter = _QuietAdapter()),
      ],
      child: const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
    ));
    final ctx = tester.element(find.byType(Scaffold));
    // 聊天「记入时光」预填：无元数据 → 通用「附件」，同样不许露 token
    showComposerSheet(ctx,
        initialContent: '带图的悄悄话', initialMediaIds: const <String>['x-1']);
    await tester.pumpAndSettle();
    expect(find.textContaining('media:x-1'), findsNothing,
        reason: '预填路径同样不许露 token');
    expect(find.text('附件'), findsOneWidget);
  });
}
