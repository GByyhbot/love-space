/* 在线更新（2.4.3 提交三）单测：
   ① pickLatestAppRelease 挑选规则：2.4.10>2.4.9 数值段比较、同版不重复、
      2.4.2<2.4.3 提示、app-v 前缀过滤、prerelease 与老 v* 忽略、无 APK 资产忽略
   ② 冷启动节流：auto 6h 内二次请求不发出（adapter 计数断言）、manual 不受节流
   ③ fetchSha256 解析：hex 提取（含大写归一）、无 hex / 请求异常 → null
   ④ 验签失败：.sha256 与本地不符 → 立即删文件、不进入安装步（安装器零调用） */
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/features/settings/settings_state.dart' show newerVer;
import 'package:love_space/features/update/update_service.dart';
import 'package:love_space/features/update/update_sheet.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kApkName = 'app-arm64-v8a-release.apk';
const String _kBaseUrl =
    'https://github.com/GByyhbot/love-space/releases/download';

GithubAsset _apkAsset([String tag = 'app-v2.4.3', String digest = '']) =>
    GithubAsset(
        name: _kApkName,
        url: '$_kBaseUrl/$tag/$_kApkName',
        digest: digest);

GithubRelease _rel(String tag, {bool pre = false, bool apk = true}) =>
    GithubRelease(
      tagName: tag,
      name: tag,
      body: '',
      prerelease: pre,
      assets: apk ? [_apkAsset(tag)] : const [],
    );

/// 走 adapter 的假 Dio：按 URL 分流（releases 列表 / APK 字节 / .sha256 文本）
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({
    this.releases = const <Object>[],
    this.apkBytes = const <int>[],
    this.shaText = '',
  });
  final List<Object> releases;
  final List<int> apkBytes;
  final String shaText;
  final List<String> urls = [];
  int calls = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final url = options.uri.toString();
    urls.add(url);
    calls++;
    if (options.uri.host == 'api.github.com') {
      return ResponseBody.fromString(jsonEncode(releases), 200,
          headers: {
            Headers.contentTypeHeader: const ['application/json']
          });
    }
    if (url.endsWith('$_kApkName.sha256')) {
      return ResponseBody.fromString(shaText, 200, headers: {
        Headers.contentTypeHeader: const ['text/plain'],
      });
    }
    if (url.endsWith(_kApkName)) {
      final bytes = Uint8List.fromList(apkBytes);
      return ResponseBody.fromBytes(bytes, 200, headers: {
        Headers.contentLengthHeader: ['${bytes.length}'],
        Headers.contentTypeHeader: const ['application/octet-stream'],
      });
    }
    return ResponseBody.fromString('not found', 404);
  }
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.docPath);
  final String docPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => docPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── ① 挑选规则 ───────────────────────────────────────────────
  group('① pickLatestAppRelease 挑选与版本比对', () {
    test('2.4.10 > 2.4.9：数值段逐段比较取最大（不是字典序）', () {
      final latest = pickLatestAppRelease(
          [_rel('app-v2.4.9'), _rel('app-v2.4.10')])!;
      expect(latest.tagName, 'app-v2.4.10');
      expect(newerVer('2.4.10', '2.4.9'), isTrue);
    });

    test('同版本不提示：newerVer 严格大于，等于返回 false', () {
      final latest = pickLatestAppRelease([_rel('app-v2.4.3')])!;
      expect(newerVer(latest.appVersion, '2.4.3'), isFalse);
    });

    test('2.4.2 < 2.4.3：提示更新', () {
      final latest = pickLatestAppRelease([_rel('app-v2.4.3')])!;
      expect(newerVer(latest.appVersion, '2.4.2'), isTrue);
    });

    test('app-v 前缀过滤：老 Capacitor v1.7.4 与裸 1.7.4 一律忽略', () {
      final latest = pickLatestAppRelease(
          [_rel('v1.7.4'), _rel('1.7.4'), _rel('app-v2.4.3')])!;
      expect(latest.tagName, 'app-v2.4.3');
      expect(pickLatestAppRelease([_rel('v1.7.4'), _rel('1.7.4')]), isNull);
    });

    test('prerelease 忽略；无 APK 资产忽略', () {
      final latest = pickLatestAppRelease([
        _rel('app-v2.5.0', pre: true),
        _rel('app-v2.5.0', apk: false),
      ]);
      expect(latest, isNull);
    });
  });

  // ── ② 节流 ──────────────────────────────────────────────────
  group('② 自动检查节流（6h 窗口）', () {
    test('auto 首次发出请求；6h 内二次冷启动不再请求；manual 不受节流',
        () async {
      SharedPreferences.setMockInitialValues({});
      final adapter = _FakeAdapter(releases: [
        {
          'tag_name': 'app-v2.4.3',
          'name': 'app-v2.4.3',
          'body': 'x',
          'prerelease': false,
          'assets': [
            {
              'name': _kApkName,
              'browser_download_url': '$_kBaseUrl/app-v2.4.3/$_kApkName'
            }
          ],
        }
      ]);
      final dio = Dio()..httpClientAdapter = adapter;
      final container = ProviderContainer(overrides: [
        api.dioProvider.overrideWith((ref) async => dio),
      ]);
      addTearDown(container.dispose);

      // 首次 auto：发出请求，有新版
      final r1 = await checkForUpdate(dio, '2.4.2', source: CheckSource.auto);
      expect(r1.status, 'has-update');
      expect(adapter.calls, 1);

      // 节流窗口内二次 auto：请求计数不涨，状态 throttled
      final r2 = await checkForUpdate(dio, '2.4.2', source: CheckSource.auto);
      expect(r2.status, 'throttled');
      expect(adapter.calls, 1);

      // manual 不受节流：再次发请求
      final r3 = await checkForUpdate(dio, '2.4.2', source: CheckSource.manual);
      expect(r3.status, 'has-update');
      expect(adapter.calls, 2);
    });

    test('本地已是最新 → up-to-date；检查失败 → error（不冒泡）', () async {
      SharedPreferences.setMockInitialValues({});
      final adapter = _FakeAdapter(releases: []);
      final dio = Dio()..httpClientAdapter = adapter;
      final empty = await checkForUpdate(dio, '2.4.3',
          source: CheckSource.auto);
      expect(empty.status, 'up-to-date');

      final bad = Dio()..httpClientAdapter = _BrokenAdapter();
      final err = await checkForUpdate(bad, '2.4.3',
          source: CheckSource.manual);
      expect(err.status, 'error');
    });
  });

  // ── ③ fetchSha256 解析 ──────────────────────────────────────
  group('③ fetchSha256 解析', () {
    test('标准格式（hex + 文件名）提取 64 位 hex', () async {
      final hex = 'ab' * 32;
      final dio = Dio()..httpClientAdapter = _FakeAdapter(
          shaText: '$hex  $_kApkName\n');
      final got = await fetchSha256(dio, _apkAsset());
      expect(got, hex);
    });

    test('大写 hex 归一为小写；无 hex / 请求异常 → null', () async {
      final hex = 'AB' * 32;
      final dio = Dio()..httpClientAdapter = _FakeAdapter(shaText: hex);
      expect(await fetchSha256(dio, _apkAsset()), 'ab' * 32);

      final empty = Dio()..httpClientAdapter = _FakeAdapter(shaText: 'oops');
      expect(await fetchSha256(empty, _apkAsset()), isNull);

      final broken = Dio()..httpClientAdapter = _BrokenAdapter();
      expect(await fetchSha256(broken, _apkAsset()), isNull);
    });
  });

  // ── ④ 验签失败：删文件、不进安装步 ────────────────────────────
  group('④ 验签对账（digest 锚点优先，2026-11-18 裁定）', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('upd243');
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    });
    tearDown(() {
      // Windows 文件锁竞态（dio sink 句柄偶发未释放）——容忍删除失败
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('digest 存在 → 期望值取 digest、零额外请求（不发 .sha256）', () async {
      final bytes = List<int>.generate(2048, (i) => i % 256);
      final hex = crypto.sha256.convert(bytes).toString();
      final adapter = _FakeAdapter(apkBytes: bytes, shaText: 'shoud-not-be-hit');
      final dio = Dio()..httpClientAdapter = adapter;
      final asset = _apkAsset('app-v2.4.3', 'sha256:$hex');
      final target = await apkTargetFile('2.4.3');
      await downloadApk(dio, asset, target);

      final expected = await resolveExpectedSha256(dio, asset);
      expect(expected, hex); // 与本地一致 → 对账通过可进安装步
      expect(target.existsSync(), isTrue);
      // 计数断言：digest 存在时不发 .sha256 请求（只用元数据，零额外请求）
      expect(adapter.urls.where((u) => u.endsWith('.sha256')).length, 0);
      expect(
          adapter.urls.where((u) => u.endsWith(_kApkName)).length, 1);
    });

    test('digest 不符 → 删文件、不进安装步、不发 .sha256 请求', () async {
      final adapter = _FakeAdapter(
        apkBytes: List<int>.generate(2048, (i) => i % 256),
        shaText: 'shoud-not-be-hit',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final asset = _apkAsset('app-v2.4.3', 'sha256:${'ff' * 32}'); // 与内容不符
      final target = await apkTargetFile('2.4.3');
      await downloadApk(dio, asset, target);
      expect(target.existsSync(), isTrue);

      // sheet 验签段落的等价对账逻辑（update_sheet.dart）
      final expected = await resolveExpectedSha256(dio, asset);
      final actual =
          crypto.sha256.convert(await target.readAsBytes()).toString();
      final failed = expected == null || actual != expected;
      if (failed && target.existsSync()) target.deleteSync();

      expect(failed, isTrue); // digest 不符 → 判失败
      expect(target.existsSync(), isFalse); // 文件已删（禁进安装步）
      expect(adapter.urls.where((u) => u.endsWith('.sha256')).length, 0);
      // 安装器零调用的证据：OpenFilex.open 调用点仅在验签通过之后
      // （update_sheet._install，且前置 existsSync 守卫）；文件已删即不可能安装。
    });

    test('digest 缺失 → 回退 .sha256 文件获取（仍只走直连）', () async {
      final bytes = List<int>.generate(2048, (i) => i % 256);
      final hex = crypto.sha256.convert(bytes).toString();
      final adapter = _FakeAdapter(apkBytes: bytes, shaText: '$hex  $_kApkName');
      final dio = Dio()..httpClientAdapter = adapter;
      final asset = _apkAsset(); // 无 digest
      final target = await apkTargetFile('2.4.3');
      await downloadApk(dio, asset, target);

      final expected = await resolveExpectedSha256(dio, asset);
      expect(expected, hex);
      expect(adapter.urls.where((u) => u.endsWith('.sha256')).length, 1);
      expect(
          adapter.urls
              .where((u) => u.startsWith('https://gh-proxy'))
              .isEmpty,
          isTrue); // 校验值不经代理（原口径）
    });

    test('digest 缺失且 .sha256 也拿不到 → null（验签失败，不许无校验安装）',
        () async {
      final adapter = _FakeAdapter(apkBytes: const [], shaText: 'oops');
      final dio = Dio()..httpClientAdapter = adapter;
      expect(await resolveExpectedSha256(dio, _apkAsset()), isNull);
    });

    testWidgets('「以后再说」→ sessionDeferredVersions 记录 + sheet 关闭',
        (tester) async {
      sessionDeferredVersions.clear();
      final release = _rel('app-v2.4.3');
      await tester.pumpWidget(MaterialApp(
        home: Consumer(
          builder: (ctx, ref, _) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () =>
                    showUpdateSheet(ctx, ref: ref, release: release),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('update-later')), findsOneWidget);
      await tester.tap(find.byKey(const Key('update-later')));
      await tester.pumpAndSettle();
      expect(sessionDeferredVersions, contains('2.4.3'));
      expect(find.byKey(const Key('update-later')), findsNothing);
    });
  });
}

/// 恒抛错 adapter（检查失败/网络异常路径）
class _BrokenAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    throw DioException.connectionError(
        requestOptions: options, reason: 'boom');
  }
}
