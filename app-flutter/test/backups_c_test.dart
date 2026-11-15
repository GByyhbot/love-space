/* 「数据管理与通知渠道」章 · 段 C（2.2.7 / VC227）完整备份与存储占用
   契约 + widget 测试。
   覆盖：Web fmt/pct/backupSize 公式对拍（fixtures 由 Node vm 实跑
   static/app.js 生成）/ 存储字段逐项映射（db 含 period、record_count 含
   分库）/ 四端点 4xx 与 503 detail 原文 / 备份下载复用段 B saveBytesResponse
   / admin 入口显隐 + 非 admin 直达门控 / POST 成功重拉列表 + 在途防重入 /
   恢复只说明 / 返回两条路径 / 段 B 导出区互不干扰。
   跑前 unset 八个代理变量（flutter_tester 本地 WebSocket 会被代理劫持）。
   🔴 测试环境无 path_provider 通道（项目既有约定）：widget 层落盘不触，
   2xx 落盘由函数级注入临时目录覆盖；widget 下载/导出走 4xx 错误路径。 */
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
import 'package:love_space/features/auth/auth_state.dart';
import 'package:love_space/features/chat/chat_toast.dart' show ChatToastHost;
import 'package:love_space/features/settings/backups_api.dart';
import 'package:love_space/features/settings/backups_page.dart';
import 'package:love_space/features/settings/settings_page.dart';
import 'package:love_space/main.dart' show routerProvider;
import 'package:shared_preferences/shared_preferences.dart';

// ── 响应夹具（模拟服务端四端点形状）────────────────────────────────────

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: const <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
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

/// 服务端 storage 下发形状（`main.py:2720-2724`）：db 含 period、record_count
/// 含 period.count_active()，客户端逐字段照搬、不补算。
Map<String, dynamic> _storageJson() => <String, dynamic>{
      'total': 1073741824 + 1048576,
      'media_by_kind': <String, dynamic>{
        'image': 629145600,
        'video': 314572800,
        'audio': 104857600,
      },
      'media_by_month': <String, dynamic>{'2026-01': 1048576000},
      // love.db + love.db-wal + period.db + period.db-wal
      'db': 4096 + 1024 + 2048 + 512,
      'backups': 10485760,
      'disk_free': 2147483648,
      'disk_total': 4294967296,
      // 主库未删 100 + period.count_active() 7
      'record_count': 100 + 7,
      'media_count': 42,
    };

List<Map<String, dynamic>> _backupsJson() => <Map<String, dynamic>>[
      <String, dynamic>{
        'name': 'backup-20260115.zip.enc',
        'size': 5 * 1024 * 1024,
        'created': 1768435200.0,
        'encrypted': true,
      },
      <String, dynamic>{
        'name': 'backup-20260114.zip',
        'size': 3 * 1024 * 1024,
        'created': 1768348800.0,
        'encrypted': false,
      },
    ];

const String _backup503 =
    '服务器未配置备份密码，已拒绝生成明文备份；请联系管理员设置 BACKUP_PASSWORD';
const String _backup403 = '完整备份由服务器管理员操作；个人记录可在导出中下载';

class _Store {
  _Store({this.admin = false});

  final bool admin;

  Map<String, dynamic> storage = _storageJson();
  int storageStatus = 200;
  String storageDetail = '需要管理员账号';

  List<Map<String, dynamic>> backups = _backupsJson();
  int backupsStatus = 200;
  String backupsDetail = '需要管理员账号';

  int backupStatus = 200; // POST /api/backups
  String backupDetail = _backup503;
  String backupName = 'backup-20260116.zip';
  bool addBackupOnPost = true;

  int downloadStatus = 200;
  String downloadDetail = '无权访问';
  List<int> downloadBody = utf8.encode('PK-zip-backup-bytes');
  Map<String, List<String>> downloadHeaders = const <String, List<String>>{};

  /// 非空时对该路径的请求挂起（在途防重入用例）。
  String? gatingPath;
  final Completer<void> gate = Completer<void>();

  final List<RequestOptions> requests = <RequestOptions>[];

  int count(String path) => requests.where((r) => r.uri.path == path).length;

  int countMethod(String method, String path) => requests
      .where((r) => r.method == method && r.uri.path == path)
      .length;
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
        'user': <String, dynamic>{
          'id': 'u1',
          'name': '我',
          'username': 'u1',
          'admin': store.admin ? 1 : 0,
        },
        'users': <Object>[
          <String, dynamic>{
            'id': 'u1',
            'name': '我',
            'username': 'u1',
            'admin': store.admin ? 1 : 0,
          },
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
    // 段 B 导出（验证「段 B 三行仍可点」；429 bytes 错误体不触 path_provider）
    if (options.method == 'GET' && path == '/api/export') {
      return _bytes(_detailBody('尝试过于频繁，请 5 分钟后再试'), 429);
    }
    if (options.method == 'GET' && path == '/api/storage') {
      if (store.storageStatus >= 400) {
        return _json(<String, dynamic>{'detail': store.storageDetail},
            store.storageStatus);
      }
      return _json(store.storage);
    }
    if (options.method == 'POST' && path == '/api/backups') {
      if (store.gatingPath == path) await store.gate.future;
      if (store.backupStatus >= 400) {
        return _json(<String, dynamic>{'detail': store.backupDetail},
            store.backupStatus);
      }
      if (store.addBackupOnPost) {
        store.backups.insert(0, <String, dynamic>{
          'name': store.backupName,
          'size': 1234,
          'created': 1768521600.0,
          'encrypted': false,
        });
      }
      return _json(<String, dynamic>{'name': store.backupName});
    }
    // GET /api/backups（列表，精确匹配，勿与下载 path 混淆）
    if (options.method == 'GET' && path == '/api/backups') {
      if (store.backupsStatus >= 400) {
        return _json(<String, dynamic>{'detail': store.backupsDetail},
            store.backupsStatus);
      }
      return _json(store.backups);
    }
    // GET /api/backups/{name}（bytes 下载）
    if (options.method == 'GET' && path.startsWith('/api/backups/')) {
      if (store.downloadStatus >= 400) {
        return _bytes(_detailBody(store.downloadDetail), store.downloadStatus);
      }
      return _bytes(store.downloadBody, 200, headers: store.downloadHeaders);
    }
    return _json(<Object>[]);
  }
}

Future<Dio> _dio(_Store store) async => Dio(
      BaseOptions(
        baseUrl: 'https://test.local',
        // 🔴 与生产 buildDio 共用策略：4xx 放行成 Response、>=500 抛
        // DioException(badResponse)，模块须显式判 2xx。
        validateStatus: api.validateAppStatus,
      ),
    )..httpClientAdapter = _FakeAdapter(store);

/// 可控 admin 的 AuthNotifier：build() 同步装填 me、不跑 bootstrap
/// （避免真实 /api/me 异步与 path_provider），供入口显隐 / 直达门控测试。
class _FakeAuth extends AuthNotifier {
  _FakeAuth({required this.admin});

  final bool admin;

  @override
  AuthPhase build() {
    final user = SpaceUser(
        id: 'u1', name: '我', username: 'u1', admin: admin);
    me = MeData(
      user: user,
      users: <SpaceUser>[user],
      spaceName: '我们的小世界',
      spaceRaw: const <String, dynamic>{},
      spaceSince: '2020-05-20',
    );
    return AuthPhase.authed;
  }
}

Future<ProviderContainer> _container(
  _Store store, {
  List<Override> extra = const <Override>[],
}) async {
  final dio = await _dio(store);
  final c = ProviderContainer(
    overrides: <Override>[
      api.dioProvider.overrideWith((ref) async => dio),
      api.baseProvider.overrideWith((ref) async => 'https://test.local'),
      chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
      sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
      ...extra,
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
          children: <Widget>[
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

/// widget 夹具：自定义 router（不套 main.dart redirect，专测页面本身）。
GoRouter _testRouter() => GoRouter(
      initialLocation: '/hub',
      routes: <RouteBase>[
        GoRoute(
          path: '/hub',
          builder: (_, _) =>
              const Scaffold(body: Center(child: Text('page-hub'))),
        ),
        GoRoute(path: '/settings', builder: (_, _) => const SettingsPage()),
        GoRoute(path: '/backups', builder: (_, _) => const BackupsPage()),
      ],
    );

/// 定向 pump（不 settle）：toast 2.2s 自动收起 timer 不能被推过头。
Future<void> _settleRequests(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

/// 收尾：走完 toast 自动收起 timer（fake_async 不留 pending）。
Future<void> _drainToast(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 3));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  Map<String, dynamic> loadFixtures() => jsonDecode(
          File('test/fixtures/web_storage_expectations.json')
              .readAsStringSync()) as Map<String, dynamic>;

  // ── A. Web 公式对拍（期望值来自 Node vm 实跑 static/app.js） ──────────
  group('A · Web fmt/pct/backupSize 公式逐项对拍', () {
    test('fixtures 来源实证：fmt/pct/size 表达式从 app.js 提取、Node vm 实跑',
        () {
      final j = loadFixtures();
      final meta = j['_meta'] as Map;
      expect(meta['source'].toString(), contains('static/app.js'));
      final extraction = meta['extraction'] as Map;
      expect(extraction['fmtExpr'].toString(), contains('1073741824'));
      expect(extraction['fmtExpr'].toString(), contains('toFixed'));
      expect(extraction['pctExpr'].toString(), contains('Math.round'));
      expect(extraction['sizeExpr'].toString(), contains('1024/1024'));
    });

    test('formatStorageSize 与 Web fmt 逐项一致（0/1MiB/1GiB/边界/带小数）',
        () {
      final j = loadFixtures();
      for (final c in (j['fmt'] as List).cast<Map>()) {
        expect(
          formatStorageSize(c['input'] as num),
          c['expected'],
          reason: 'fmt(${c['input']}) 期望来自 Web 实跑',
        );
      }
      // 边界值显式锚点（防 fixtures 被误改）
      expect(formatStorageSize(0), '0.0 MB');
      expect(formatStorageSize(1048576), '1.0 MB');
      expect(formatStorageSize(1073741824), '1.00 GB');
      expect(formatStorageSize(1048575), '1.0 MB');
      expect(formatStorageSize(1073741823), '1024.0 MB');
    });

    test('storageUsedPercent 与 Web pct 逐项一致（含 disk_total=0）', () {
      final j = loadFixtures();
      for (final c in (j['pct'] as List).cast<Map>()) {
        expect(
          storageUsedPercent(c['disk_free'] as num, c['disk_total'] as num),
          c['expected'],
          reason: 'pct(${c['disk_free']},${c['disk_total']}) 期望来自 Web 实跑',
        );
      }
      expect(storageUsedPercent(0, 0), 0, reason: 'disk_total=0 → 0');
    });

    test('formatBackupSize 与 Web (size/1024/1024).toFixed(2) 逐项一致', () {
      final j = loadFixtures();
      for (final c in (j['size'] as List).cast<Map>()) {
        expect(formatBackupSize(c['input'] as num), c['expected'],
            reason: 'size(${c['input']}) 期望来自 Web 实跑');
      }
    });

    test('mediaKindPercent 与 Web 条宽 round(v/total*100) 一致', () {
      expect(mediaKindPercent(629145600, 1048576000), 60);
      expect(mediaKindPercent(314572800, 1048576000), 30);
      expect(mediaKindPercent(104857600, 1048576000), 10);
      expect(mediaKindPercent(0, 0), 0, reason: 'total=0 → 条宽 0');
    });
  });

  // ── B. 存储字段逐项映射（只照搬服务端下发数字，不补算） ───────────────
  group('B · StorageUsage/BackupItem.fromJson 逐字段映射', () {
    test('db 含 period、record_count 含分库计数、三类媒体、disk_free/total',
        () {
      final j = _storageJson();
      final s = StorageUsage.fromJson(j);
      // 🔴 客户端只呈现服务端下发数字：db/record_count 逐字段照搬，不拆不补
      expect(s.db, j['db'], reason: 'db = love.db+wal+period.db+period.db-wal');
      expect(s.recordCount, 107, reason: '主库 100 + period.count_active() 7');
      expect(s.total, j['total']);
      expect(s.backups, j['backups']);
      expect(s.diskFree, 2147483648);
      expect(s.diskTotal, 4294967296);
      expect(s.imageBytes, 629145600);
      expect(s.videoBytes, 314572800);
      expect(s.audioBytes, 104857600);
      expect(s.mediaTotal, 1048576000);
      expect(s.mediaCount, 42);
      // meta 行逐字结构（数字走 Web 同款 fmt）
      expect(
        storageMetaLine(s),
        '数据库 ${formatStorageSize(s.db)} · 备份 ${formatStorageSize(s.backups)} '
        '· 107 条记录 · 42 个媒体文件',
      );
    });

    test('缺字段时各数值安全落 0，不抛异常', () {
      final s = StorageUsage.fromJson(<String, dynamic>{});
      expect(s.total, 0);
      expect(s.db, 0);
      expect(s.recordCount, 0);
      expect(s.mediaTotal, 0);
      expect(storageUsedPercent(s.diskFree, s.diskTotal), 0);
    });

    test('BackupItem.fromJson：name/size/created(double)/encrypted', () {
      final b = BackupItem.fromJson(<String, dynamic>{
        'name': 'backup-20260115.zip.enc',
        'size': 5242880,
        'created': 1768435200.0,
        'encrypted': true,
      });
      expect(b.name, 'backup-20260115.zip.enc');
      expect(b.size, 5242880);
      expect(b.created, 1768435200.0);
      expect(b.encrypted, isTrue);
      expect(formatBackupSize(b.size), '5.00 MB');
    });
  });

  // ── C. 四端点 4xx 与 503 detail 原文（函数级，不假成功） ──────────────
  group('C · 4xx / 503 服务端 detail 原文透传', () {
    test('GET /api/storage 403「需要管理员账号」', () async {
      final store = _Store()..storageStatus = 403;
      final (usage, err) = await fetchStorage(await _dio(store));
      expect(err, '需要管理员账号');
      expect(usage, isNull, reason: '4xx 不产出数据');
    });

    test('GET /api/backups 403「需要管理员账号」', () async {
      final store = _Store()..backupsStatus = 403;
      final (list, err) = await fetchBackups(await _dio(store));
      expect(err, '需要管理员账号');
      expect(list, isNull);
    });

    test('POST /api/backups 403「完整备份由服务器管理员操作；个人记录可在导出中下载」',
        () async {
      final store = _Store()
        ..backupStatus = 403
        ..backupDetail = _backup403;
      final (name, err) = await createBackup(await _dio(store));
      expect(err, _backup403, reason: '4xx 走 writeResponseError 原文');
      expect(name, isNull, reason: '不假成功');
    });

    test('🔴 POST 503 原文（DioException badResponse + JSON detail Map）',
        () async {
      final store = _Store()
        ..backupStatus = 503
        ..backupDetail = _backup503;
      final (name, err) = await createBackup(await _dio(store));
      expect(err, _backup503,
          reason: '>=500 抛 DioException → errorDetail 取 e.response.data.detail 原文');
      expect(name, isNull, reason: '不包装、不吞成 genericErrorText、不假成功');
    });

    test('下载 403「无权访问」（bytes 错误体 → bytesResponseDetail 原文）',
        () async {
      final store = _Store()
        ..downloadStatus = 403
        ..downloadDetail = '无权访问';
      final (saved, err) = await downloadBackup(
          await _dio(store), 'backup-x.zip',
          downloadsDir: Directory.systemTemp);
      expect(err, '无权访问');
      expect(saved, isNull);
    });

    test('下载 404「备份不存在」', () async {
      final store = _Store()
        ..downloadStatus = 404
        ..downloadDetail = '备份不存在';
      final (saved, err) = await downloadBackup(
          await _dio(store), 'backup-x.zip',
          downloadsDir: Directory.systemTemp);
      expect(err, '备份不存在');
      expect(saved, isNull);
    });

    test('POST 成功解析 {\'name\':...}', () async {
      final store = _Store()..backupName = 'backup-20260116.zip';
      final (name, err) = await createBackup(await _dio(store));
      expect(err, isNull);
      expect(name, 'backup-20260116.zip');
    });

    test('GET 端点 4xx 不改写、不降级为 genericErrorText', () async {
      final store = _Store()
        ..storageStatus = 403
        ..storageDetail = '自定义原文 X';
      final (_, err) = await fetchStorage(await _dio(store));
      expect(err, '自定义原文 X');
      expect(err, isNot(api.genericErrorText));
    });
  });

  // ── D. 备份下载复用段 B saveBytesResponse（函数级真实落盘） ────────────
  group('D · downloadBackup 复用段 B 落盘范式', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('backups-c-test');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
    });

    test('2xx bytes → 真实落盘、文件名同源、10min/bytes、Content-Disposition 优先',
        () async {
      final store = _Store();
      final (saved, err) = await downloadBackup(
          await _dio(store), 'backup-20260101.zip',
          downloadsDir: tempDir);
      expect(err, isNull);
      expect(saved!.filename, 'backup-20260101.zip',
          reason: '无头 → 回退列表项服务端下发的 name');
      expect(saved.path.endsWith('backup-20260101.zip'), isTrue,
          reason: '文件名与通知同源');
      expect(await File(saved.path).exists(), isTrue);
      expect(await File(saved.path).readAsBytes(), store.downloadBody);
      final opt = store.requests
          .firstWhere((r) => r.uri.path.startsWith('/api/backups/'));
      expect(opt.method, 'GET');
      expect(opt.responseType, ResponseType.bytes);
      expect(opt.receiveTimeout, const Duration(minutes: 10));
      expect(opt.uri.path, '/api/backups/backup-20260101.zip');
    });

    test('2xx + Content-Disposition filename* → 按头命名（优先于回退名）',
        () async {
      final store = _Store()
        ..downloadHeaders = const <String, List<String>>{
          'content-disposition': <String>[
            "attachment; filename*=UTF-8''backup-from-header.zip",
          ],
        };
      final (saved, err) = await downloadBackup(
          await _dio(store), 'backup-list-name.zip',
          downloadsDir: tempDir);
      expect(err, isNull);
      expect(saved!.filename, 'backup-from-header.zip');
      expect(saved.path.endsWith('backup-from-header.zip'), isTrue);
    });

    test('🔴 下载 4xx bytes 错误体 → 原文、不落盘（不假成功）', () async {
      final store = _Store()
        ..downloadStatus = 403
        ..downloadDetail = '无权访问';
      final (saved, err) = await downloadBackup(
          await _dio(store), 'backup-x.zip',
          downloadsDir: tempDir);
      expect(err, '无权访问', reason: '复用 bytesResponseDetail 取原文');
      expect(saved, isNull);
      expect(tempDir.listSync(), isEmpty, reason: '4xx 绝不落盘');
    });

    test('🔴 源码级：备份下载 import + 调用段 B 公共 saveBytesResponse，不另写一套',
        () {
      final src =
          File('lib/features/settings/backups_api.dart').readAsStringSync();
      final exp =
          File('lib/features/settings/export_api.dart').readAsStringSync();
      expect(src.contains("import 'export_api.dart';"), isTrue,
          reason: '直接 import 段 B 助手');
      expect(src.contains('saveBytesResponse('), isTrue,
          reason: '下载路径调用公共 saveBytesResponse');
      expect(src.contains('sanitizeFilename('), isTrue,
          reason: '回退名复用 sanitizeFilename');
      expect(src.contains('exportReceiveTimeout'), isTrue,
          reason: '逐请求 10min 复用段 B 常量');
      expect(src.contains('writeAsBytes'), isFalse,
          reason: '不得另写落盘实现');
      expect(src.contains('parseContentDispositionFilename'), isFalse,
          reason: '不得复制文件名解析');
      // 段 B downloadExport 也走同一公共函数（证明两条路径共用、20 用例等价）
      expect(exp.contains('Future<(SavedExport?, String?)> saveBytesResponse('),
          isTrue);
      expect(exp.contains('return await saveBytesResponse('), isTrue);
    });
  });

  // ── E. admin 入口显隐 + 非 admin 直达门控 ─────────────────────────────
  group('E · 仅 admin 入口 / 直达门控', () {
    testWidgets('admin /settings 显示第 4 行入口 + 段 B 三行仍在且可点',
        (tester) async {
      final store = _Store(admin: true);
      final c = await _container(store,
          extra: <Override>[
            authProvider.overrideWith(() => _FakeAuth(admin: true)),
          ]);
      final router = _testRouter();
      await _pump(tester, _app(c, router: router));
      router.push('/settings');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-backups-entry')), findsOneWidget);
      expect(find.text(backupsEntryLabel), findsOneWidget);
      // 段 B 三行互不干扰
      for (final k in <String>[
        'settings-export-records',
        'settings-export-markdown',
        'settings-export-ics',
      ]) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: '$k 仍在');
      }
      // 三行「可点」：点导出行 → 发 /api/export（429 错误路径，不触 path_provider）
      await tester.tap(find.byKey(const Key('settings-export-records')));
      await _settleRequests(tester);
      expect(store.count('/api/export'), 1, reason: '段 B 导出行仍可点');
      expect(find.text('尝试过于频繁，请 5 分钟后再试'), findsOneWidget);
      await _drainToast(tester);
    });

    testWidgets('非 admin /settings 不显示入口、不留死入口；三行仍在',
        (tester) async {
      final store = _Store(admin: false);
      final c = await _container(store,
          extra: <Override>[
            authProvider.overrideWith(() => _FakeAuth(admin: false)),
          ]);
      final router = _testRouter();
      await _pump(tester, _app(c, router: router));
      router.push('/settings');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-backups-entry')), findsNothing);
      expect(find.text(backupsEntryLabel), findsNothing);
      // 摘要条本段不做（Web app.js:1481 storage-strip）
      expect(find.textContaining('存储占用与备份'), findsNothing);
      expect(find.byKey(const Key('settings-export-records')), findsOneWidget);
      expect(find.byKey(const Key('settings-export-markdown')), findsOneWidget);
      expect(find.byKey(const Key('settings-export-ics')), findsOneWidget);
    });

    testWidgets('admin 点入口 → context.push(\'/backups\')', (tester) async {
      final store = _Store(admin: true);
      final c = await _container(store,
          extra: <Override>[
            authProvider.overrideWith(() => _FakeAuth(admin: true)),
          ]);
      final router = _testRouter();
      await _pump(tester, _app(c, router: router));
      router.push('/settings');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-backups-entry')));
      await tester.pumpAndSettle();
      expect(find.byType(BackupsPage), findsOneWidget);
      expect(find.text(backupsPageTitle), findsOneWidget);
    });

    testWidgets(
        '🔴 非 admin 直达 /backups → redirect 回 /settings，零 /api/storage',
        (tester) async {
      final store = _Store(admin: false);
      final c = await _container(store,
          extra: <Override>[
            authProvider.overrideWith(() => _FakeAuth(admin: false)),
          ]);
      final router = c.read(routerProvider); // main.dart 真实 redirect
      // 挂载前先把目标设为 /backups：Router attach 时用最新 location 跑
      // redirect（避免先渲染复杂 ShellPage），验证「直达也进不去」。
      router.go('/backups');
      await _pump(tester, _app(c, router: router));
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/settings',
        reason: '非 admin 直达被挡回 /settings',
      );
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.byType(BackupsPage), findsNothing);
      expect(store.count('/api/storage'), 0,
          reason: '不发任何 /api/storage 请求');
      expect(store.count('/api/backups'), 0, reason: '也不发 /api/backups');
    });

    testWidgets('admin 直达 /backups → 不 redirect（对照）', (tester) async {
      final store = _Store(admin: true);
      final c = await _container(store,
          extra: <Override>[
            authProvider.overrideWith(() => _FakeAuth(admin: true)),
          ]);
      final router = c.read(routerProvider);
      router.go('/backups');
      await _pump(tester, _app(c, router: router));
      expect(router.routerDelegate.currentConfiguration.uri.path, '/backups');
      expect(find.byType(BackupsPage), findsOneWidget);
      expect(find.byType(SettingsPage), findsNothing);
    });
  });

  // ── F. BackupsPage 呈现 / 错误态 / POST 重拉 / 防重入 ──────────────────
  group('F · BackupsPage 呈现与交互', () {
    testWidgets('存储三格 + 三类媒体条 + meta 行 + hint + 列表 + 加密标记',
        (tester) async {
      final store = _Store();
      final c = await _container(store);
      final router = _testRouter();
      await _pump(tester, _app(c, router: router));
      router.push('/backups');
      await tester.pumpAndSettle();

      expect(find.text(backupsPageTitle), findsOneWidget);
      expect(find.text(backupsHeading), findsOneWidget);
      expect(find.text(backupsSubtitle), findsOneWidget);
      expect(find.byKey(const Key('backups-now')), findsOneWidget);
      expect(find.text(backupNowLabel), findsOneWidget);
      // 三格（值走 Web 同款 fmt）
      final s = StorageUsage.fromJson(_storageJson());
      expect(find.byKey(const Key('backups-stat-used')), findsOneWidget);
      expect(find.byKey(const Key('backups-stat-free')), findsOneWidget);
      expect(find.byKey(const Key('backups-stat-pct')), findsOneWidget);
      expect(find.text(formatStorageSize(s.total)), findsOneWidget);
      expect(find.text(formatStorageSize(s.diskFree)), findsOneWidget);
      expect(find.text('${storageUsedPercent(s.diskFree, s.diskTotal)}%'),
          findsOneWidget);
      // 三类媒体条 + 中文标签
      for (final k in <String>['image', 'video', 'audio']) {
        expect(find.byKey(Key('backups-media-$k')), findsOneWidget);
      }
      expect(find.text('照片'), findsOneWidget);
      expect(find.text('视频'), findsOneWidget);
      expect(find.text('语音'), findsOneWidget);
      // meta 行逐字
      expect(find.byKey(const Key('backups-meta')), findsOneWidget);
      expect(find.text(storageMetaLine(s)), findsOneWidget);
      // hint 逐字
      expect(find.byKey(const Key('backups-hint')), findsOneWidget);
      expect(find.text(backupsHint), findsOneWidget);
      // 列表项（名称 / 加密标记 / 大小 / 下载按钮 / timelineDateLabel 复用）
      expect(find.byKey(const Key('backups-item-backup-20260115.zip.enc')),
          findsOneWidget);
      expect(find.byKey(const Key('backups-encrypted-backup-20260115.zip.enc')),
          findsOneWidget);
      expect(find.text('🔒 已加密'), findsOneWidget);
      expect(find.textContaining('5.00 MB'), findsWidgets);
      expect(find.byKey(const Key('backups-download-backup-20260114.zip')),
          findsOneWidget);
      expect(find.text('下载'), findsWidgets);
      // 下拉刷新已挂
      expect(find.byType(RefreshIndicator), findsOneWidget);
      // 数字只来自服务端：初始加载正好一次 storage + 一次 backups
      expect(store.count('/api/storage'), 1);
      expect(store.countMethod('GET', '/api/backups'), 1);
    });

    testWidgets('空列表文案「备份还未生成 / 可以现在创建第一份完整备份。」',
        (tester) async {
      final store = _Store()..backups = <Map<String, dynamic>>[];
      final c = await _container(store);
      final router = _testRouter();
      await _pump(tester, _app(c, router: router));
      router.push('/backups');
      await tester.pumpAndSettle();
      expect(find.text(backupsEmptyTitle), findsOneWidget);
      expect(find.text(backupsEmptySubtitle), findsOneWidget);
    });

    testWidgets('GET /api/storage 403 → 页面内原文、不呈现假数据', (tester) async {
      final store = _Store()..storageStatus = 403;
      final c = await _container(store);
      final router = _testRouter();
      await _pump(tester, _app(c, router: router));
      router.push('/backups');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('backups-error')), findsOneWidget);
      expect(find.text('需要管理员账号'), findsOneWidget);
      expect(find.byKey(const Key('backups-meta')), findsNothing,
          reason: '错误态不假数据');
      expect(find.byKey(const Key('backups-stat-used')), findsNothing);
    });

    testWidgets('GET /api/backups 403 → 页面内原文', (tester) async {
      final store = _Store()..backupsStatus = 403;
      final c = await _container(store);
      final router = _testRouter();
      await _pump(tester, _app(c, router: router));
      router.push('/backups');
      await tester.pumpAndSettle();
      expect(find.text('需要管理员账号'), findsOneWidget);
    });

    testWidgets('🔴 POST 503 原文 error toast、不发成功通知、不刷列表',
        (tester) async {
      final store = _Store()
        ..backupStatus = 503
        ..backupDetail = _backup503;
      final c = await _container(store);
      final router = _testRouter();
      await _pump(tester, _app(c, router: router));
      router.push('/backups');
      await tester.pumpAndSettle();
      final before = store.countMethod('GET', '/api/backups');

      await tester.tap(find.byKey(const Key('backups-now')));
      await _settleRequests(tester);

      expect(find.text(_backup503), findsOneWidget,
          reason: '503 原文顶部 error 通知');
      expect(find.textContaining('备份已创建'), findsNothing,
          reason: '不发成功通知');
      expect(find.textContaining('已保存到本地'), findsNothing);
      expect(store.countMethod('POST', '/api/backups'), 1);
      expect(store.countMethod('GET', '/api/backups'), before,
          reason: '失败不刷新列表');
      expect(find.byKey(const Key('backups-item-backup-20260116.zip')),
          findsNothing);
      expect(find.text(backupNowLabel), findsOneWidget,
          reason: '忙碌态复位');
      await _drainToast(tester);
    });

    testWidgets('POST 403 原文 error toast、不刷列表', (tester) async {
      final store = _Store()
        ..backupStatus = 403
        ..backupDetail = _backup403;
      final c = await _container(store);
      final router = _testRouter();
      await _pump(tester, _app(c, router: router));
      router.push('/backups');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('backups-now')));
      await _settleRequests(tester);
      expect(find.text(_backup403), findsOneWidget);
      expect(find.textContaining('备份已创建'), findsNothing);
      expect(store.countMethod('GET', '/api/backups'), 1);
      await _drainToast(tester);
    });

    testWidgets('🔴 POST 成功 → 重拉 GET /api/backups（第二次）+ 列表顶部出现新备份',
        (tester) async {
      final store = _Store();
      final c = await _container(store);
      final router = _testRouter();
      await _pump(tester, _app(c, router: router));
      router.push('/backups');
      await tester.pumpAndSettle();
      expect(store.countMethod('GET', '/api/backups'), 1);

      await tester.tap(find.byKey(const Key('backups-now')));
      await _settleRequests(tester);

      expect(store.countMethod('POST', '/api/backups'), 1);
      expect(store.countMethod('GET', '/api/backups'), 2,
          reason: '成功后重拉列表（第二次请求）');
      expect(store.count('/api/storage'), 2,
          reason: '同时重拉 storage，只呈现服务端下发值');
      final newItem =
          find.byKey(const Key('backups-item-backup-20260116.zip'));
      expect(newItem, findsOneWidget, reason: '新备份出现在列表');
      final oldItem =
          find.byKey(const Key('backups-item-backup-20260115.zip.enc'));
      expect(tester.getTopLeft(newItem).dy < tester.getTopLeft(oldItem).dy,
          isTrue, reason: '新备份在顶部');
      expect(find.textContaining('备份已创建'), findsOneWidget);
      await _drainToast(tester);
    });

    testWidgets('🔴 在途防重入：POST gate 挂起时连点零叠发，放行后复位',
        (tester) async {
      final store = _Store()..gatingPath = '/api/backups';
      final c = await _container(store);
      final router = _testRouter();
      await _pump(tester, _app(c, router: router));
      router.push('/backups');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('backups-now')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(store.countMethod('POST', '/api/backups'), 1);
      expect(find.text(backupBusyLabel), findsOneWidget);

      // 连点：按钮 disabled + _busy 守卫 → 不叠发
      await tester.tap(find.byKey(const Key('backups-now')));
      await tester.pump(const Duration(milliseconds: 20));
      expect(store.countMethod('POST', '/api/backups'), 1,
          reason: '在途防重入：零叠发');

      store.gate.complete();
      await _settleRequests(tester);
      expect(store.countMethod('POST', '/api/backups'), 1);
      expect(find.text(backupBusyLabel), findsNothing, reason: '放行后复位');
      expect(find.text(backupNowLabel), findsOneWidget);
      await _drainToast(tester);
    });

    testWidgets('下载按钮 4xx → 原文 error 通知、不落盘', (tester) async {
      final store = _Store()
        ..downloadStatus = 404
        ..downloadDetail = '备份不存在';
      final c = await _container(store);
      final router = _testRouter();
      await _pump(tester, _app(c, router: router));
      router.push('/backups');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(
          const Key('backups-download-backup-20260114.zip')));
      await _settleRequests(tester);
      expect(find.text('备份不存在'), findsOneWidget);
      expect(find.textContaining('已保存到本地'), findsNothing);
      await _drainToast(tester);
    });
  });

  // ── G. 恢复只说明 / 返回路径 ─────────────────────────────────────────
  group('G · D5 恢复只说明 / 返回两条路径', () {
    testWidgets('hint 逐字；页面无「恢复」按钮、无 restore 相关请求',
        (tester) async {
      final store = _Store();
      final c = await _container(store);
      final router = _testRouter();
      await _pump(tester, _app(c, router: router));
      router.push('/backups');
      await tester.pumpAndSettle();

      expect(find.text(backupsHint), findsOneWidget, reason: 'hint 逐字');
      expect(find.text('恢复'), findsNothing, reason: '无独立「恢复」按钮文案');
      for (final t in <Type>[
        ElevatedButton,
        FilledButton,
        TextButton,
        OutlinedButton,
        IconButton,
      ]) {
        expect(find.widgetWithText(t, '恢复'), findsNothing,
            reason: '$t 无「恢复」可点控件');
      }
      expect(store.requests.any((r) => r.uri.path.contains('restore')), isFalse,
          reason: '无 restore 相关请求');
      // 源码级：页面不引用 HTTP 恢复端点
      final src =
          File('lib/features/settings/backups_page.dart').readAsStringSync();
      expect(src.contains('/api/restore'), isFalse);
      expect(src.contains("'/restore"), isFalse);
    });

    testWidgets('返回按钮可回', (tester) async {
      final store = _Store();
      final c = await _container(store);
      final router = _testRouter();
      await _pump(tester, _app(c, router: router));
      router.push('/backups');
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.byType(BackupsPage), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('page-hub'), findsOneWidget);
      expect(find.byType(BackupsPage), findsNothing);
    });

    testWidgets('系统返回手势可回', (tester) async {
      final store = _Store();
      final c = await _container(store);
      final router = _testRouter();
      await _pump(tester, _app(c, router: router));
      router.push('/backups');
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('page-hub'), findsOneWidget);
      expect(find.byType(BackupsPage), findsNothing);
    });
  });
}
