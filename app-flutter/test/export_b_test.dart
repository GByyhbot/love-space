/* 「数据管理与通知渠道」章 · 段 B（2.2.6 / VC226）数据导出三件
   契约 + widget 测试。
   覆盖：三端点 2xx bytes 落盘（注入临时目录，文件名与通知同源）/
   Content-Disposition 解析（RFC 5987 filename* 优先）与回退命名 /
   429 原文「尝试过于频繁，请 5 分钟后再试」不落盘不假成功 /
   ics 404 原文「还没有可导出的纪念日或计划」/ 5xx 兜底 /
   逐请求 receiveTimeout 10min 覆盖基座 20s / 在途防重入（全卡统一禁用）/
   /settings 三行入口文案逐字 / 返回两条独立路径 / 既有设置项不受影响。
   跑前 unset 八个代理变量（flutter_tester 本地 WebSocket 会被代理劫持）。
   🔴 测试环境无 path_provider 通道（项目既有约定）：widget 层落盘由函数级
   注入临时目录覆盖，widget 用例走 429 错误路径（不触 path_provider）。 */
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart' show chatBaseProvider;
import 'package:love_space/core/sse/sse_client.dart'
    show SseEvent, sseEventsProvider;
import 'package:love_space/features/chat/chat_toast.dart' show ChatToastHost;
import 'package:love_space/features/settings/export_api.dart';
import 'package:love_space/features/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── 夹具（模拟服务端三端点形状，4xx 走 bytes JSON 错误体）──────────────

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(data),
  status,
  headers: <String, List<String>>{
    Headers.contentTypeHeader: const <String>['application/json'],
  },
);

ResponseBody _bytes(List<int> data, int status,
    {Map<String, List<String>> headers = const <String, List<String>>{}}) =>
    ResponseBody.fromBytes(
      Uint8List.fromList(data),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: const <String>['application/octet-stream'],
        ...headers,
      },
    );

List<int> _detailBody(String detail) =>
    utf8.encode(jsonEncode(<String, dynamic>{'detail': detail}));

class _Store {
  int recordsStatus = 200;
  int markdownStatus = 200;
  int icsStatus = 200;
  List<int> recordsBody = utf8.encode('zip-bytes-records');
  List<int> markdownBody = utf8.encode('zip-bytes-markdown');
  List<int> icsBody = utf8.encode('BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n');
  Map<String, List<String>> recordsHeaders = const <String, List<String>>{};
  Map<String, List<String>> markdownHeaders = const <String, List<String>>{};
  Map<String, List<String>> icsHeaders = const <String, List<String>>{};

  /// 非空时对该路径的请求挂起（防重入用例）。
  String? gatingPath;
  final Completer<void> gate = Completer<void>();

  final List<RequestOptions> requests = <RequestOptions>[];

  int count(String path) =>
      requests.where((r) => r.uri.path == path).length;
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.store);

  final _Store store;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    store.requests.add(options);
    final path = options.uri.path;
    if (options.method == 'GET' && path == '/api/me') {
      return _json(<String, dynamic>{
        'user': <String, dynamic>{'id': 'u1', 'name': '我', 'username': 'u1'},
        'users': <Object>[
          <String, dynamic>{'id': 'u1', 'name': '我', 'username': 'u1'},
        ],
        'space': <String, dynamic>{
          'name': '我们的小世界',
          'since': '2020-05-20',
          'theme': 'rose',
          'custom_color': '',
          'motion': true,
          'timezone': 'Asia/Shanghai',
        },
        'unread': 0,
        'chat_unread': 0,
      });
    }
    if (options.method == 'GET' && path == '/api/records') {
      return _json(<Object>[]);
    }
    if (options.method == 'GET' && path == '/api/dashboard') {
      return _json(<String, dynamic>{
        'total': 0,
        'likes': 0,
        'comments': 0,
        'photos': 0,
      });
    }
    if (options.method == 'GET' && path == '/api/routes') {
      return _json(<String, dynamic>{'routes': <Object>[]});
    }
    if (options.method == 'GET' && path == '/api/status') {
      return _json(<String, dynamic>{'initialized': true});
    }
    if (options.method == 'GET' && path == '/api/export') {
      if (store.gatingPath == path) await store.gate.future;
      return _bytes(store.recordsBody, store.recordsStatus,
          headers: store.recordsHeaders);
    }
    if (options.method == 'GET' && path == '/api/export/markdown') {
      if (store.gatingPath == path) await store.gate.future;
      return _bytes(store.markdownBody, store.markdownStatus,
          headers: store.markdownHeaders);
    }
    if (options.method == 'GET' && path == '/api/export/ics') {
      if (store.gatingPath == path) await store.gate.future;
      return _bytes(store.icsBody, store.icsStatus, headers: store.icsHeaders);
    }
    return _json(<Object>[]);
  }
}

Future<Dio> _dio(_Store store) async => Dio(
  BaseOptions(
    baseUrl: 'https://test.local',
    // 🔴 与生产 buildDio 同策略：4xx 放行为「成功 Response」，模块须显式判
    validateStatus: api.validateAppStatus,
  ),
)..httpClientAdapter = _FakeAdapter(store);

// widget 夹具（复用 settings_d_test 形状）

Future<ProviderContainer> _container(_Store store) async {
  final dio = await _dio(store);
  final c = ProviderContainer(
    overrides: [
      api.dioProvider.overrideWith((ref) async => dio),
      api.baseProvider.overrideWith((ref) async => 'https://test.local'),
      chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
      sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

Widget _app(ProviderContainer c, {required GoRouter router}) =>
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => Stack(
          children: [
            child ?? const SizedBox.shrink(),
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(child: SafeArea(child: ChatToastHost())),
            ),
          ],
        ),
      ),
    );

Future<void> _pump(WidgetTester tester, Widget w) async {
  tester.view.physicalSize = const Size(1080, 3200);
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(w);
  await tester.pumpAndSettle();
}

GoRouter _settingsRouter({String hubMarker = 'page-hub'}) => GoRouter(
  initialLocation: '/hub',
  routes: <RouteBase>[
    GoRoute(
      path: '/hub',
      builder: (_, _) => Scaffold(body: Center(child: Text(hubMarker))),
    ),
    GoRoute(path: '/settings', builder: (_, _) => const SettingsPage()),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  // ── Content-Disposition 解析 / 回退命名 / stamp ──────────────────
  group('文件名解析与回退命名', () {
    test('RFC 5987 filename* 优先于 filename=（main.py:2673 形状）', () {
      const header =
          "attachment; filename=love-space-20260101.ics; "
          "filename*=UTF-8''%E6%88%91%E4%BB%AC%E7%9A%84%E7%BA%AA%E5%BF%B5"
          "%E6%97%A5-20260101.ics";
      expect(
        parseContentDispositionFilename(header),
        '我们的纪念日-20260101.ics',
      );
    });

    test('Starlette FileResponse 小写 utf-8\'\' 形状（我们的回忆.zip）', () {
      const header =
          "attachment; filename*=utf-8''%E6%88%91%E4%BB%AC%E7%9A%84"
          "%E5%9B%9E%E5%BF%86.zip";
      expect(parseContentDispositionFilename(header), '我们的回忆.zip');
    });

    test('普通 filename 带引号 / 不带引号', () {
      expect(
        parseContentDispositionFilename(
          'attachment; filename="love-space-20260101.ics"',
        ),
        'love-space-20260101.ics',
      );
      expect(
        parseContentDispositionFilename(
          'attachment; filename=love-space-20260101.ics',
        ),
        'love-space-20260101.ics',
      );
    });

    test('filename* 转义非法 → 退回 filename=；头缺失/空 → null', () {
      expect(
        parseContentDispositionFilename(
          "attachment; filename*=''%ZZ; filename=\"ok.ics\"",
        ),
        'ok.ics',
        reason: '解码异常不能崩，退回普通字段',
      );
      expect(parseContentDispositionFilename(null), isNull);
      expect(parseContentDispositionFilename(''), isNull);
      expect(parseContentDispositionFilename('inline'), isNull);
    });

    test('落盘安全：路径分隔符与控制字符替换，纯空 → null', () {
      expect(sanitizeFilename('a/b\\c.zip'), 'a_b_c.zip');
      expect(sanitizeFilename('  ok.zip '), 'ok.zip');
      expect(sanitizeFilename('   '), isNull);
      expect(sanitizeFilename(null), isNull);
    });

    test('stamp 用 UTC+8（空间时区默认 Asia/Shanghai）同格式 YYYYMMDD', () {
      // UTC 17:30 → UTC+8 次日 01:30
      expect(exportStampUtc8(DateTime.utc(2026, 1, 15, 17, 30)), '20260116');
      // UTC 15:59 → UTC+8 当日 23:59
      expect(exportStampUtc8(DateTime.utc(2026, 1, 15, 15, 59)), '20260115');
    });

    test('三端点回退名与 Web/服务端同一格式（main.py:2588/:2597/:2672）', () {
      final now = DateTime.utc(2026, 1, 15, 17, 0);
      expect(exportFallbackName(ExportKind.records, now), '我们的回忆.zip');
      expect(
        exportFallbackName(ExportKind.markdown, now),
        '恋爱空间-第二大脑-20260116.zip',
      );
      expect(
        exportFallbackName(ExportKind.ics, now),
        'love-space-20260116.ics',
      );
    });

    test('端点规格：records/markdown 共用限流桶，ics 无限流', () {
      expect(exportSpecs[ExportKind.records]!.path, '/api/export');
      expect(exportSpecs[ExportKind.records]!.sharedRateLimit, isTrue);
      expect(
        exportSpecs[ExportKind.markdown]!.path,
        '/api/export/markdown',
      );
      expect(exportSpecs[ExportKind.markdown]!.sharedRateLimit, isTrue);
      expect(exportSpecs[ExportKind.ics]!.path, '/api/export/ics');
      expect(exportSpecs[ExportKind.ics]!.sharedRateLimit, isFalse);
    });
  });

  // ── 下载 + 4xx 显式判 + 落盘（函数级，注入临时目录） ────────────────
  group('downloadExport（注入临时 downloads 目录）', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('export-b-test');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
    });

    test('records 2xx + filename* 头 → 按头命名落盘，内容逐字节一致', () async {
      final store = _Store();
      store.recordsHeaders = const <String, List<String>>{
        'content-disposition': <String>[
          "attachment; filename*=UTF-8''%E6%88%91%E4%BB%AC%E7%9A%84"
              '%E5%9B%9E%E5%BF%86.zip',
        ],
      };
      final (saved, err) = await downloadExport(
        await _dio(store),
        ExportKind.records,
        downloadsDir: tempDir,
        now: () => DateTime.utc(2026, 1, 15),
      );
      expect(err, isNull);
      expect(saved!.filename, '我们的回忆.zip');
      final f = File(saved.path);
      expect(await f.exists(), isTrue);
      expect(await f.readAsBytes(), store.recordsBody);
      // 通知里报的名字与落盘文件名同源：路径末段就是 filename
      expect(saved.path.endsWith(saved.filename), isTrue);
    });

    test('markdown 2xx 无头 → 回退名（UTC+8 stamp）落盘', () async {
      final store = _Store();
      final (saved, err) = await downloadExport(
        await _dio(store),
        ExportKind.markdown,
        downloadsDir: tempDir,
        now: () => DateTime.utc(2026, 1, 15, 17, 0),
      );
      expect(err, isNull);
      expect(saved!.filename, '恋爱空间-第二大脑-20260116.zip');
      final f = File(saved.path);
      expect(await f.exists(), isTrue);
      expect(await f.readAsBytes(), store.markdownBody);
    });

    test('ics 2xx 双字段头 → filename* 权威名「我们的纪念日-*.ics」', () async {
      final store = _Store();
      store.icsHeaders = const <String, List<String>>{
        'content-disposition': <String>[
          "attachment; filename=love-space-20260101.ics; "
              "filename*=UTF-8''%E6%88%91%E4%BB%AC%E7%9A%84%E7%BA%AA%E5%BF%B5"
              '%E6%97%A5-20260101.ics',
        ],
      };
      final (saved, err) = await downloadExport(
        await _dio(store),
        ExportKind.ics,
        downloadsDir: tempDir,
        now: () => DateTime.utc(2026, 1, 1),
      );
      expect(err, isNull);
      expect(saved!.filename, '我们的纪念日-20260101.ics');
      expect(File(saved.path).existsSync(), isTrue);
    });

    test('ics 2xx 无头 → 回退名 love-space-{stamp}.ics；目录不存在则创建', () async {
      final store = _Store();
      final sub = Directory(
        '${tempDir.path}${Platform.pathSeparator}downloads',
      );
      expect(sub.existsSync(), isFalse);
      final (saved, err) = await downloadExport(
        await _dio(store),
        ExportKind.ics,
        downloadsDir: sub,
        now: () => DateTime.utc(2026, 1, 15, 17, 0),
      );
      expect(err, isNull);
      expect(saved!.filename, 'love-space-20260116.ics');
      expect(sub.existsSync(), isTrue);
      expect(await File(saved.path).readAsString(), contains('VCALENDAR'));
    });

    test('🔴 records 429 bytes JSON 错误体 → 原文呈现、不落盘、不假成功', () async {
      final store = _Store();
      store.recordsStatus = 429;
      store.recordsBody = _detailBody('尝试过于频繁，请 5 分钟后再试');
      final (saved, err) = await downloadExport(
        await _dio(store),
        ExportKind.records,
        downloadsDir: tempDir,
        now: () => DateTime.utc(2026, 1, 15),
      );
      expect(err, '尝试过于频繁，请 5 分钟后再试', reason: 'detail 原文，不改写');
      expect(saved, isNull, reason: '4xx 绝不落盘');
      expect(tempDir.listSync(), isEmpty, reason: '没有写出任何文件');
    });

    test('🔴 markdown 429（同一限流桶）→ 原文呈现、不落盘', () async {
      final store = _Store();
      store.markdownStatus = 429;
      store.markdownBody = _detailBody('尝试过于频繁，请 5 分钟后再试');
      final (saved, err) = await downloadExport(
        await _dio(store),
        ExportKind.markdown,
        downloadsDir: tempDir,
        now: () => DateTime.utc(2026, 1, 15),
      );
      expect(err, '尝试过于频繁，请 5 分钟后再试');
      expect(saved, isNull);
      expect(tempDir.listSync(), isEmpty);
    });

    test('🔴 ics 404（无内容）→ 原文「还没有可导出的纪念日或计划」、不落盘', () async {
      final store = _Store();
      store.icsStatus = 404;
      store.icsBody = _detailBody('还没有可导出的纪念日或计划');
      final (saved, err) = await downloadExport(
        await _dio(store),
        ExportKind.ics,
        downloadsDir: tempDir,
        now: () => DateTime.utc(2026, 1, 15),
      );
      expect(err, '还没有可导出的纪念日或计划');
      expect(saved, isNull);
      expect(tempDir.listSync(), isEmpty);
    });

    test('🔴 bytes 错误体 Pydantic 422 列表形状 [{"msg":...}] → msg 原文、不落盘',
        () async {
      final store = _Store();
      store.recordsStatus = 422;
      store.recordsBody = utf8.encode(jsonEncode(<Object>[
        <String, dynamic>{'msg': '字符串类型不匹配', 'type': 'string_type'},
      ]));
      final (saved, err) = await downloadExport(
        await _dio(store),
        ExportKind.records,
        downloadsDir: tempDir,
        now: () => DateTime.utc(2026, 1, 15),
      );
      expect(err, '字符串类型不匹配', reason: 'bytes List<int> 解码后喂 responseDetail，msg 形状不漏');
      expect(saved, isNull);
      expect(tempDir.listSync(), isEmpty);
    });

    test('5xx 抛 DioException → errorDetail 兜底文案、不落盘', () async {
      final store = _Store();
      store.icsStatus = 500;
      store.icsBody = _detailBody('internal');
      final (saved, err) = await downloadExport(
        await _dio(store),
        ExportKind.ics,
        downloadsDir: tempDir,
        now: () => DateTime.utc(2026, 1, 15),
      );
      expect(err, '出了点小问题，稍后再试');
      expect(saved, isNull);
      expect(tempDir.listSync(), isEmpty);
    });

    test('逐请求 receiveTimeout 10min 覆盖基座 20s；responseType 必须 bytes',
        () async {
      final store = _Store();
      await downloadExport(
        await _dio(store),
        ExportKind.records,
        downloadsDir: tempDir,
        now: () => DateTime.utc(2026, 1, 15),
      );
      final opt = store.requests
          .firstWhere((r) => r.uri.path == '/api/export');
      expect(opt.receiveTimeout, const Duration(minutes: 10));
      expect(opt.responseType, ResponseType.bytes);
      expect(opt.method, 'GET');
    });
  });

  // ── widget：/settings 三行入口 / 文案逐字 / 防重入 / 返回路径 ────────
  group('/settings 数据导出卡（widget）', () {
    testWidgets('三行入口文案逐字 + 卡标题 + 说明 + 既有设置项不受影响', (tester) async {
      final store = _Store();
      final c = await _container(store);
      final router = _settingsRouter();
      await _pump(tester, _app(c, router: router));
      router.push('/settings');
      await tester.pumpAndSettle();

      expect(find.text('数据导出'), findsOneWidget);
      // 三行文案逐字对齐 Web app.js:1482
      expect(find.text(exportRecordsLabel), findsOneWidget);
      expect(find.text(exportMarkdownLabel), findsOneWidget);
      expect(find.text(exportIcsLabel), findsOneWidget);
      // 说明文案（Web small-note 逐字，末句锚点）
      expect(find.text(exportCardNote), findsOneWidget);
      // 三个入口都带独立 key
      for (final key in <String>[
        'settings-export-records',
        'settings-export-markdown',
        'settings-export-ics',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: '$key 入口存在');
      }
      // 位置：连接卡之后、关于卡之前（…连接 → 数据导出 → 关于）
      // 🔴「关于」二字在 heading 与卡标题各出现一次（findsWidgets），
      // 位置锚点改用 about 卡内唯一文本「恋爱空间」。
      final linkPos = tester.getTopLeft(find.text('链路检测与线路切换')).dy;
      final exportPos = tester.getTopLeft(find.text('数据导出')).dy;
      final aboutPos = tester.getTopLeft(find.text('恋爱空间')).dy;
      expect(exportPos, greaterThan(linkPos));
      expect(exportPos, lessThan(aboutPos));
      // 既有设置项不受影响
      expect(find.text('主题与外观'), findsOneWidget);
      expect(find.text('主页背景'), findsOneWidget);
      expect(find.text('链路检测与线路切换'), findsOneWidget);
      expect(find.text('检查更新'), findsOneWidget);
      expect(find.text('复制 App 下载链接'), findsOneWidget);
      // 段 C 不加：无 admin 备份按钮、无存储摘要条
      expect(find.text('完整备份与存储占用'), findsNothing);
      expect(find.textContaining('存储占用与备份'), findsNothing);
    });

    testWidgets('🔴 429 原文透传：error toast、无成功通知、不落盘（不触 path_provider）',
        (tester) async {
      final store = _Store();
      store.recordsStatus = 429;
      store.recordsBody = _detailBody('尝试过于频繁，请 5 分钟后再试');
      final c = await _container(store);
      final router = _settingsRouter();
      await _pump(tester, _app(c, router: router));
      router.push('/settings');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('settings-export-records')));
      // 🔴 只定向 pump 不 pumpAndSettle：在途 spinner 是无限动画，且 toast
      // 2.2s 后按假时钟自动收起，pumpAndSettle 会把两者都推过头。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      expect(store.count('/api/export'), 1, reason: '只发一次请求');
      expect(find.text('尝试过于频繁，请 5 分钟后再试'), findsOneWidget,
          reason: '服务端 detail 原文顶部通知');
      expect(find.text('已保存到本地'), findsNothing, reason: '失败绝不假成功');
      expect(store.count('/api/export/markdown'), 0);
      expect(store.count('/api/export/ics'), 0);
      // 忙碌态已复位（toast 仍在显示中）：可再次发起
      await tester.tap(find.byKey(const Key('settings-export-records')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(store.count('/api/export'), 2, reason: '复位后可重试');
      // 收尾：把 toast 的 2.2s 自动收起 timer 走完（fake_async 不留 pending）
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('在途防重入：请求未回再点不发第二次请求（全卡统一禁用）', (tester) async {
      final store = _Store();
      store.gatingPath = '/api/export';
      // 放行后走 429 原文路径（不触 path_provider，断言文案确定）
      store.recordsStatus = 429;
      store.recordsBody = _detailBody('尝试过于频繁，请 5 分钟后再试');
      final c = await _container(store);
      final router = _settingsRouter();
      await _pump(tester, _app(c, router: router));
      router.push('/settings');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('settings-export-records')));
      // 只 pump 不 settle：请求挂起在 gate 上
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(store.count('/api/export'), 1);

      // 同按钮再点 → 不叠发
      await tester.tap(find.byKey(const Key('settings-export-records')));
      await tester.pump(const Duration(milliseconds: 20));
      // 另两个按钮也被统一禁用 → 点了也不发
      await tester.tap(find.byKey(const Key('settings-export-markdown')));
      await tester.tap(find.byKey(const Key('settings-export-ics')));
      await tester.pump(const Duration(milliseconds: 20));
      expect(store.count('/api/export'), 1, reason: '在途防重入：不许叠发');
      expect(store.count('/api/export/markdown'), 0);
      expect(store.count('/api/export/ics'), 0);
      expect(find.text('导出中…'), findsOneWidget);

      // 放行 429 → 原文呈现，忙碌态复位（同样只用定向 pump）
      store.gate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(store.count('/api/export'), 1);
      expect(find.text('尝试过于频繁，请 5 分钟后再试'), findsOneWidget);
      expect(find.text('导出中…'), findsNothing);
      // 收尾：走完 toast 自动收起 timer
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('返回按钮 + 系统返回手势两条独立路径可回', (tester) async {
      final store = _Store();
      final c = await _container(store);
      final router = _settingsRouter();
      await _pump(tester, _app(c, router: router));
      await tester.tap(find.text('page-hub'));
      await tester.pumpAndSettle();
      router.push('/settings');
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.text('数据导出'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('page-hub'), findsOneWidget);
      router.push('/settings');
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('page-hub'), findsOneWidget);
    });
  });
}
