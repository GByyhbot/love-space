/* 时光页段二 C 单测（条目 4 收尾段）：
   ① 回填铁律纯函数 buildEditBody：原始 body 逐键复制 + 只覆盖改动字段
   ② 【专项】带客户端未知字段的记录（permitted 集内/集外）编辑内容后提交，
      逐字核对 PUT 请求体：未知字段、album、date 全部存活（核对方法见用例注释）
   ③ 编辑成功后本卡原地替换（服务端返回完整记录），其它卡引用不变
   ④ 删除成功后本卡原地移除（其余引用/顺序不变）；PUT/DELETE 失败不动列表
   ⑤ 仅本人卡片显示「⋯」菜单（isOwnPost）
   ⑥ 聊天「记入时光」预填：composer 带入原消息文本与媒体 id（widget 层） */
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/timeline/timeline_data.dart';
import 'package:love_space/features/timeline/composer_sheet.dart';
import 'package:love_space/features/timeline/timeline_controller.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions options, int callIndex) handler;
  int calls = 0;
  final List<RequestOptions> requests = [];

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

Map<String, Object> _recJson(String id,
        {Map<String, Object>? body, double created = 100.0}) =>
    {
      'id': id, 'kind': 'post', 'author': 'u1',
      'body': body ?? {'content': 'm-$id', 'date': '2026-01-02', 'media': <Object>[]},
      'created': created, 'updated': created,
      'client_id': '', 'media': <Object>[],
      'likes': <Object>[], 'comments': <Object>[],
    };

Future<ProviderContainer> _setup(_FakeAdapter adapter,
    {required List<Map<String, Object>> records}) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  final container = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
  ]);
  addTearDown(container.dispose);
  await container.read(timelineControllerProvider.notifier).load(reset: true);
  return container;
}

void main() {
  // ── ① 回填铁律纯函数 ─────────────────────────────────────────
  group('① buildEditBody', () {
    test('原始 body 逐键复制 + 只覆盖改动字段（不按字段表拼装）', () {
      final original = <String, dynamic>{
        'content': '旧正文',
        'date': '2026-01-02',
        'media': ['m1'],
        'album': 'alb-1',
        'location': {'lat': 31.2, 'lng': 121.5}, // permitted 集内未知字段
        'reply_to': 'some-id', // permitted 集内未知字段
        'future_field': [1, 2, {'k': 'v'}], // 客户端完全不建模的未知字段
      };
      final out = buildEditBody(original, {'content': '新正文'});
      expect(out['content'], '新正文');
      // 逐字核对（deep equality）：值、类型、嵌套结构都不变
      expect(out['date'], '2026-01-02');
      expect(out['album'], 'alb-1');
      expect(out['media'], ['m1']);
      expect(out['location'], {'lat': 31.2, 'lng': 121.5});
      expect(out['reply_to'], 'some-id');
      expect(out['future_field'], [1, 2, {'k': 'v'}]);
      expect(out.keys.toSet(), original.keys.toSet(),
          reason: '不许按字段表拼装：原始 body 的键集合必须完整保留');
      // 原始 body 未被就地修改
      expect(original['content'], '旧正文');
    });
  });

  // ── ② 【专项】带未知字段的记录编辑后 PUT 请求体逐字核对 ────────
  group('② 回填铁律专项（未知字段 / album / date 存活）', () {
    test('编辑 content 后提交：PUT 请求体逐字核对未知字段、album、date 全部存活',
        () async {
      // 核对方法：用 FakeAdapter 捕获 PUT 的 RequestOptions.data（Dio 已
      // jsonEncode 前的 Dart Map），对 body 做逐键 deep-equality 断言，
      // 而不是只检查几个已知键——服务端 clean_body 只留 permitted 字段，
      // 但 permitted 集内的未知字段（location/reply_to/song）同样必须带回。
      final serverBody = <String, Object>{
        'content': '原文',
        'date': '2026-01-02',
        'media': <Object>['m1', 'm2'],
        'album': 'alb-1',
        'title': '原标题',
        'location': {'lat': 31.2, 'lng': 121.5},
        'reply_to': 'chat-xy',
        'song': {'title': '歌', 'artist': '人', 'mid': 'mid-9'},
        'sticker': '/static/stickers/abc/1.webp',
        'category': '生活',
        'unknown_web_only': {'deep': [1, 'two', false]},
      };
      RequestOptions? capturedPut;
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'PUT') {
          capturedPut = options;
          // 服务端返回更新后的完整记录（serialize 形态）
          final updated = Map<String, Object>.from(serverBody);
          updated['content'] = '新正文';
          return _json(_recJson('r1', body: updated));
        }
        return _json([_recJson('r1', body: serverBody)]);
      });
      final container = await _setup(adapter,
          records: [_recJson('r1', body: serverBody)]);

      final err = await container
          .read(timelineControllerProvider.notifier)
          .editRecord('r1', {'content': '新正文'}, originalBody: serverBody);
      expect(err, isNull);
      expect(capturedPut, isNotNull);
      final sent = (capturedPut!.data as Map)['body'] as Map;
      expect(sent['content'], '新正文');
      // 逐字核对：每个未知字段的 deep 值
      expect(sent['location'], {'lat': 31.2, 'lng': 121.5});
      expect(sent['reply_to'], 'chat-xy');
      expect(sent['song'], {'title': '歌', 'artist': '人', 'mid': 'mid-9'});
      expect(sent['sticker'], '/static/stickers/abc/1.webp');
      expect(sent['category'], '生活');
      expect(sent['unknown_web_only'], {'deep': [1, 'two', false]});
      // album / date 未被改动 → 原样存活
      expect(sent['album'], 'alb-1');
      expect(sent['date'], '2026-01-02');
      expect(sent['media'], ['m1', 'm2']);
      expect(sent['title'], '原标题');
      expect(sent.keys.toSet(), serverBody.keys.toSet(),
          reason: '键集合与服务器原始 body 完全一致（无拼装、无丢失）');
      // kind 原样（服务端校验 kind 不可变）
      expect((capturedPut!.data as Map)['kind'], 'post');
    });

    test('编辑成功后本卡原地替换，其它卡引用不变', () async {
      final body1 = <String, Object>{
        'content': '旧', 'date': '2026-01-02', 'media': <Object>[],
      };
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'PUT') {
          final updated = Map<String, Object>.from(body1)
            ..['content'] = '新';
          return _json(_recJson('r1', body: updated));
        }
        return _json([
          _recJson('r1', body: body1),
          _recJson('r2'),
        ]);
      });
      final container = await _setup(adapter,
          records: [_recJson('r1', body: body1), _recJson('r2')]);
      final before = container.read(timelineControllerProvider).posts;
      final other = before[1];
      await container
          .read(timelineControllerProvider.notifier)
          .editRecord('r1', {'content': '新'});
      final after = container.read(timelineControllerProvider).posts;
      expect(after.length, 2);
      expect(after[0].body['content'], '新');
      expect(identical(after[1], other), isTrue,
          reason: 'C2 本卡原地替换：其它卡对象引用不变');
    });

    test('PUT 失败：返回错误、列表不动', () async {
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'PUT') return _json({'detail': '无权限'}, 403);
        return _json([_recJson('r1')]);
      });
      final container = await _setup(adapter, records: [_recJson('r1')]);
      final before = container.read(timelineControllerProvider).posts;
      final err = await container
          .read(timelineControllerProvider.notifier)
          .editRecord('r1', {'content': '新'});
      expect(err, isNotNull);
      final after = container.read(timelineControllerProvider).posts;
      expect(identical(after[0], before[0]), isTrue);
    });
  });

  // ── ③ 删除 ───────────────────────────────────────────────────
  group('③ 删除（软删 + 本卡原地移除）', () {
    test('DELETE 成功后本卡消失，其余引用/顺序不变', () async {
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'DELETE') return _json({'ok': true});
        return _json([_recJson('r1'), _recJson('r2'), _recJson('r3')]);
      });
      final container = await _setup(adapter,
          records: [_recJson('r1'), _recJson('r2'), _recJson('r3')]);
      final before = container.read(timelineControllerProvider).posts;
      final second = before[1], third = before[2];
      final err = await container
          .read(timelineControllerProvider.notifier)
          .deleteRecord('r1');
      expect(err, isNull);
      final after = container.read(timelineControllerProvider).posts;
      expect(after.length, 2);
      expect(after.map((r) => r.id).toList(), ['r2', 'r3']);
      expect(identical(after[0], second), isTrue);
      expect(identical(after[1], third), isTrue);
    });

    test('DELETE 失败：卡片保留 + 返回错误', () async {
      final adapter = _FakeAdapter((options, i) {
        if (options.method == 'DELETE') {
          return _json({'detail': '只有作者可以修改这条记录'}, 403);
        }
        return _json([_recJson('r1')]);
      });
      final container = await _setup(adapter, records: [_recJson('r1')]);
      final err = await container
          .read(timelineControllerProvider.notifier)
          .deleteRecord('r1');
      expect(err, isNotNull);
      expect(container.read(timelineControllerProvider).posts.length, 1);
    });
  });

  // ── ④ 菜单显隐（纯函数） ─────────────────────────────────────
  group('④ C1 仅本人「⋯」菜单', () {
    test('作者=本人显示；对方不显示', () {
      expect(isOwnPost('u1', 'u1'), isTrue);
      expect(isOwnPost('u2', 'u1'), isFalse);
    });
  });

  // ── ⑤ C4 记入时光预填 composer（widget 层） ───────────────────
  group('⑤ C4 聊天记入时光：正式 composer 带入原消息', () {
    testWidgets('预填文本与媒体 id 出现在 composer，且不是旧最小弹窗',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          api.dioProvider.overrideWith((ref) async =>
              Dio(BaseOptions(baseUrl: 'https://test.local'))
                ..httpClientAdapter = _FakeAdapter((o, i) => _json([]))),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SizedBox.shrink()),
        ),
      ));
      // 通过 showComposerSheet 打开（聊天侧同款调用），预填原消息文本+媒体
      final ctx = tester.element(find.byType(Scaffold));
      showComposerSheet(ctx,
          initialContent: '带图的悄悄话',
          initialMediaIds: const ['img-1', 'img-2']);
      await tester.pumpAndSettle();

      expect(find.text('记录此刻'), findsOneWidget,
          reason: '走正式 composer 而非旧的最小发布弹窗');
      expect(find.text('带图的悄悄话'), findsOneWidget,
          reason: '原消息文本已预填');
      expect(find.text('media:img-1'), findsOneWidget);
      expect(find.text('media:img-2'), findsOneWidget);
      expect(find.text('存草稿'), findsOneWidget,
          reason: 'post 态与时光页发布共用同一套草稿/暂存/幂等逻辑');
      expect(find.text('发布'), findsOneWidget);
      // 返回路径：头部关闭按钮可关（不误提交；用 tooltip 精确定位，
      // 避开媒体项的移除按钮同图标）
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('记录此刻'), findsNothing);
    });
  });
}
