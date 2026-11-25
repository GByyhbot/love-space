/// ORD-UPDATER-HARDENING-01 专项单测。
///
/// 覆盖令文 §三 的四个可测面：通道调度（同表迭代 / 双格式拼接 / 切换判定）、
/// Trace 与脱敏、流式 SHA-256、以及「检查与下载共用同一套迭代」的实际行为。
/// 不测 UI（widget 层另有既有用例），这里全部是纯逻辑 + fake adapter。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/features/update/channel_scheduler.dart';
import 'package:love_space/features/update/sha256_verifier.dart';
import 'package:love_space/features/update/update_service.dart';
import 'package:love_space/features/update/update_trace.dart';

const String _kApk = 'app-arm64-v8a-release.apk';

/// 按 URL 路由的假适配器：直连可配成失败，加速源恒成功。
class _Adapt implements HttpClientAdapter {
  _Adapt({
    required this.apkBytes,
    this.directCheckStatus = 200,
  });

  final List<int> apkBytes;
  final int directCheckStatus;
  final List<String> urls = <String>[];

  bool _proxied(RequestOptions o) => o.uri.host != 'api.github.com' &&
      o.uri.host != 'github.com';

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final url = options.uri.toString();
    urls.add(url);
    // 注意：下载地址也含 /releases/download/，必须排除掉
    final isCheck = url.contains('/releases') && !url.contains('/download');

    if (isCheck) {
      final status = _proxied(options) ? 200 : directCheckStatus;
      if (status != 200) {
        // 必须回**合法 JSON**：dio 对 List 响应遇到非 JSON 体会抛 unknown
        // （状态码丢失），那样就测不出 404 终止逻辑了
        return ResponseBody.fromString(
            jsonEncode(<String, dynamic>{'message': 'failed'}), status,
            headers: {
              Headers.contentTypeHeader: const ['application/json'],
            });
      }
      return ResponseBody.fromString(
        jsonEncode(<Object>[
          <String, dynamic>{
            'tag_name': 'app-v9.9.9',
            'name': 'v9.9.9',
            'body': '',
            'prerelease': false,
            'assets': <Object>[
              <String, dynamic>{
                'name': _kApk,
                'browser_download_url':
                    'https://github.com/o/r/releases/download/app-v9.9.9/$_kApk',
                'digest': 'sha256:${'00' * 32}',
                'size': apkBytes.length,
              },
            ],
          },
        ]),
        200,
        headers: {
          Headers.contentTypeHeader: const ['application/json'],
        },
      );
    }

    final bytes = Uint8List.fromList(apkBytes);
    return ResponseBody.fromBytes(bytes, 200, headers: {
      Headers.contentLengthHeader: <String>['${bytes.length}'],
      Headers.contentTypeHeader: const <String>['application/octet-stream'],
    });
  }
}

void main() {
  group('§三.3 双格式 URL 拼接', () {
    const target =
        'https://github.com/o/r/releases/download/app-v1/$_kApk';

    test('前缀式：自动补齐末尾斜杠后直接拼接', () {
      expect(buildChannelUrl('https://ghproxy.net/', target),
          'https://ghproxy.net/$target');
      expect(buildChannelUrl('https://ghproxy.net', target),
          'https://ghproxy.net/$target');
    });

    test('占位符式：只替换 {url}，不做任何编码', () {
      expect(buildChannelUrl('https://x/proxy?u={url}', target),
          'https://x/proxy?u=$target');
      // 目标地址里本来就有斜杠与问号，不能被二次编码
      expect(buildChannelUrl('https://x/{url}', target).contains('%2F'), isFalse);
    });

    test('空模板 = 直连，原样返回', () {
      expect(buildChannelUrl('', target), target);
      expect(buildChannelUrl('   ', target), target);
    });
  });

  group('§三.3（修订一）内置候选表', () {
    test('只有 直连 + gh-proxy.com + ghproxy.net，顺序固定', () {
      final q = buildChannelQueue();
      expect(q.map((c) => c.name).toList(),
          <String>['直连 GitHub', 'gh-proxy.com', 'ghproxy.net']);
      expect(q.first.type, ChannelType.direct);
      expect(q.skip(1).every((c) => c.type == ChannelType.builtinProxy), isTrue);
    });

    test('已删的三条不再出现（ghfast / gh-proxy.org / hub.gitmirror）', () {
      final joined = kBuiltinProxyTemplates.join(',');
      expect(joined.contains('ghfast'), isFalse);
      expect(joined.contains('gh-proxy.org'), isFalse);
      expect(joined.contains('hub.gitmirror'), isFalse);
    });

    test('自定义源插到最前（二期接线用；当前无 UI 写入）', () {
      final q = buildChannelQueue(customTemplate: 'https://my.mirror/');
      expect(q.first.isCustom, isTrue);
      expect(q.first.name, 'my.mirror');
      expect(q.length, 4);
    });
  });

  group('§三.3 切换判定（触发 / 终止）', () {
    test('404 / 410 → 立即终止，不切换', () {
      expect(decideSwitch(statusCode: 404).retryNext, isFalse);
      expect(decideSwitch(statusCode: 410).retryNext, isFalse);
    });

    test('403（限流）/ 429 / 5xx → 切下一条', () {
      for (final code in <int>[403, 429, 500, 502, 503]) {
        expect(decideSwitch(statusCode: code).retryNext, isTrue, reason: '$code');
      }
    });

    test('400 这类确定性 4xx → 终止', () {
      expect(decideSwitch(statusCode: 400).retryNext, isFalse);
      expect(decideSwitch(statusCode: 422).retryNext, isFalse);
    });

    test('无状态码（超时 / DNS / 建连）→ 切下一条', () {
      expect(decideSwitch(error: const SocketException('dns')).retryNext, isTrue);
    });
  });

  group('§三.1 Trace 与脱敏', () {
    test('敏感 query 参数被掩码，路径不受影响', () {
      expect(redactUrl('https://x/a?token=abc&sig=zzz&u=1'),
          'https://x/a?token=***&sig=***&u=1');
      // 大小写不敏感
      expect(redactUrl('https://x/a?Token=abc'), 'https://x/a?Token=***');
      // 无 query 不动；路径里的敏感词不误伤
      expect(redactUrl('https://x/token/path'), 'https://x/token/path');
    });

    test('attempts 只追加，序列化含阶段与通道类型', () {
      final t = UpdateTrace(traceId: 'tid');
      t.addAttempt(ChannelAttempt(
        phase: 'check',
        channel: '直连 GitHub',
        channelType: 'direct',
        isAutoFallback: false,
        url: 'https://api.github.com/x',
        statusCode: 500,
      ));
      t.addAttempt(ChannelAttempt(
        phase: 'download',
        channel: 'gh-proxy.com',
        channelType: 'builtin_proxy',
        isAutoFallback: true,
        url: 'https://gh-proxy.com/https://github.com/y?token=secret',
        bytesReceived: 1024,
      ));
      final j = t.toJson();
      final attempts = (j['attempts'] as List).cast<Map>();
      expect(attempts.length, 2);
      expect(attempts[0]['phase'], 'check');
      expect(attempts[1]['isAutoFallback'], isTrue);
      // 导出前脱敏
      expect((attempts[1]['url'] as String).contains('secret'), isFalse);
      expect(t.toPrettyJson().contains('"traceId": "tid"'), isTrue);
    });
  });

  group('§三.4 流式 SHA-256', () {
    test('与 crypto 一次性结果一致（256KB 与 64KB 分块都要对）', () async {
      final dir = await Directory.systemTemp.createTemp('sha282');
      final f = File('${dir.path}/x.bin');
      final bytes = List<int>.generate(700 * 1024, (i) => i % 251);
      await f.writeAsBytes(bytes);
      final expectHex = crypto.sha256.convert(bytes).toString();

      expect(await sha256OfFile(f.path), expectHex);
      expect(await sha256OfFile(f.path, chunkSize: 64 * 1024), expectHex);
      expect(isSha256Hex(expectHex), isTrue);
      await dir.delete(recursive: true);
    });
  });

  group('§三.3 检查阶段走同一套通道迭代', () {
    test('直连 500 → 自动切到加速源并成功，attempts 记录两跳', () async {
      final ad = _Adapt(
        apkBytes: List<int>.generate(64, (i) => i),
        directCheckStatus: 500,
      );
      final dio = Dio()..httpClientAdapter = ad;
      final trace = UpdateTrace(traceId: 'tid');

      final list = await fetchReleases(dio, trace: trace);
      expect(list, isNotEmpty);
      expect(ad.urls.length, 2, reason: '直连失败后应只多试一条');
      expect(ad.urls.first.startsWith('https://api.github.com'), isTrue);
      expect(trace.attempts.length, 2);
      expect(trace.attempts[0].statusCode, 500);
      expect(trace.attempts[0].isAutoFallback, isFalse);
      expect(trace.attempts[1].isAutoFallback, isTrue);
    });

    test('直连 404 → 立即终止，不触发切换（只尝试一次）', () async {
      final ad = _Adapt(
        apkBytes: const <int>[],
        directCheckStatus: 404,
      );
      final dio = Dio()..httpClientAdapter = ad;
      final trace = UpdateTrace(traceId: 'tid');

      await expectLater(fetchReleases(dio, trace: trace), throwsA(anything));
      expect(ad.urls.length, 1, reason: '404 是确定性错误，禁止无效切换');
      expect(trace.attempts.single.statusCode, 404);
    });
  });

  group('§三.4 .part 原子落盘与校验', () {
    test('校验通过 → rename 成正式包，.part 不残留', () async {
      final bytes = List<int>.generate(2048, (i) => i % 256);
      final hex = crypto.sha256.convert(bytes).toString();
      final dio = Dio()..httpClientAdapter = _Adapt(apkBytes: bytes);
      final dir = await Directory.systemTemp.createTemp('dl282');
      final target = File('${dir.path}/pkg.apk');
      final asset = GithubAsset(
          name: _kApk,
          url: 'https://github.com/o/r/releases/download/app-v9.9.9/$_kApk',
          digest: 'sha256:$hex',
          size: bytes.length);

      final out = await downloadApk(dio, asset, target, expectedSha: hex);
      expect(out.file.path, target.path);
      expect(target.existsSync(), isTrue);
      expect(File('${target.path}.part').existsSync(), isFalse);
      await dir.delete(recursive: true);
    });

    test('校验不一致 → 抛 PackageVerifyException，残包与正式包都不留', () async {
      final bytes = List<int>.generate(2048, (i) => i % 256);
      final dio = Dio()..httpClientAdapter = _Adapt(apkBytes: bytes);
      final dir = await Directory.systemTemp.createTemp('dl282b');
      final target = File('${dir.path}/pkg.apk');
      final asset = GithubAsset(
          name: _kApk,
          url: 'https://github.com/o/r/releases/download/app-v9.9.9/$_kApk',
          digest: 'sha256:${'ff' * 32}',
          size: bytes.length);

      await expectLater(
        downloadApk(dio, asset, target, expectedSha: 'ff' * 32),
        throwsA(isA<PackageVerifyException>()),
      );
      expect(target.existsSync(), isFalse, reason: '不许把坏包落到正式路径');
      expect(File('${target.path}.part').existsSync(), isFalse,
          reason: '坏包必须清理，防下次误复用');
      await dir.delete(recursive: true);
    });
  });
}
