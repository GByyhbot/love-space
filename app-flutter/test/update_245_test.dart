/// 2.4.5 乙组第 5 项测试：候选列护栏 + 慢速自动切换四条用例。
/// 普通 test（不走 testWidgets FakeAsync——dio.download 在 FakeAsync 挂死，
/// 2.4.3 环境坑）；速度判定参数注入短值（SpeedProbeConfig），不依赖真实时钟长等。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/features/update/update_service.dart';

/// 节流假适配器：按 host 分流，requestNo 控制慢/快行为；[slowProxy]/[slowAll]
/// 控制代理通道快慢（用例编排）。
class _ThrottledAdapter implements HttpClientAdapter {
  _ThrottledAdapter({this.slowProxy = false, this.slowAll = false});
  final bool slowProxy;
  final bool slowAll;
  final List<String> log = <String>[];
  int requestNo = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestNo++;
    final host = options.uri.host;
    log.add('#$requestNo $host${options.uri.path}');
    if (host == 'ghproxy.net' || host == 'hub.gitmirror.com') {
      if (slowAll) {
        // 全慢用例：这两个候选也走慢流
      } else {
        // 未参与用例的候选：连接层异常判败（🔴 不能回 404——生产 dio 的
        // validateStatus <500 放行 4xx，404 body 会被当成“下载成功”写盘）
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          error: 'refused',
        );
      }
    }
    final slow = _isSlow(host);
    if (slow) {
      // 慢通道：50ms/400B ≈ 8KB/s（< 测试阈值 10KB/s → 判慢；80 chunks
      // = 4s 流长，判慢触发点（rampUp 1.5s + 窗口 2s）在中途即中止）
      final body = Stream<Uint8List>.periodic(
        const Duration(milliseconds: 50),
        (n) => Uint8List.fromList(utf8.encode('S' * 400)),
      ).take(80);
      return ResponseBody(body, -1);
    }
    // 快通道：单 chunk 全量
    return ResponseBody.fromString('F' * 4096, 200,
        headers: {Headers.contentLengthHeader: ['4096']});
  }

  bool _isSlow(String host) {
    if (host == 'gh-proxy.com') return slowProxy;
    if (host == 'ghproxy.net' || host == 'hub.gitmirror.com') return slowAll;
    return requestNo == 1; // github.com 首次慢（后续快，收尾轮编排）
  }
}

/// 短速度参数：tick 粒度固定 1s（_downloadVia 内部），窗口须远大于 tick
/// 才能保留滚动样本——rampUp 1.5s / 窗口 3s / 最小跨度 2s / 阈值 10KB/s
///（慢流 8KB/s < 10KB/s 判慢；快流即时完成不触发）。
const _shortProbe = SpeedProbeConfig(
  rampUp: Duration(milliseconds: 1500),
  window: Duration(seconds: 3),
  minSpan: Duration(seconds: 2),
  slowBps: 10 * 1024,
);

GithubAsset _asset() => GithubAsset(
      name: kApkAssetName,
      url:
          'https://github.com/GByyhbot/love-space/releases/download/app-v9.9.9/$kApkAssetName',
    );

Dio _dio(_ThrottledAdapter a) => Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      validateStatus: (s) => s != null && s < 500,
    ))
      ..httpClientAdapter = a;

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('update245test');
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄竞态容忍（60af347 家族）
    }
  });

  group('候选列护栏（乙组第 5 项实测结论钉死）', () {
    test('候选列（ORD-UPDATER-HARDENING-01 修订一）：仅 gh-proxy.com + ghproxy.net', () {
      expect(kProxyPrefixes, [
        'https://gh-proxy.com/',
        'https://ghproxy.net/',
      ]);
      // 三条被明确剔除的，任何一个回来都要红
      for (final banned in <String>['ghfast.top', 'gh-proxy.org', 'hub.gitmirror']) {
        expect(kProxyPrefixes.any((p) => p.contains(banned)), isFalse,
            reason: '$banned 已被 2026-11-25 修订一移除（分别因旧裁定 / 未验证 / 实测已死）');
      }
    });

    test('通道顺序 = 直连在前、其后代理列', () {
      // downloadApk 内部：channels[0] = asset.url（直连），其后 kProxyPrefixes
      final asset = _asset();
      expect(asset.url.startsWith('https://github.com/'), isTrue);
      expect(kProxyPrefixes.first, 'https://gh-proxy.com/');
    });
  });

  group('慢速自动切换', () {
    test('慢速通道触发切换（节流假适配器 8KB/s < 10KB/s 阈值）', () async {
      final a = _ThrottledAdapter();
      final target = File('${tmp.path}${Platform.pathSeparator}a1.apk');
      final statusWords = <String>[];
      final outcome = await downloadApk(
        _dio(a),
        _asset(),
        target,
        onChannelChange: statusWords.add,
        speedProbe: _shortProbe,
      );
      expect(outcome.channelUsed, contains('gh-proxy.com'),
          reason: '直连判慢 → 弃 → 走代理 gh-proxy（快）');
      expect(statusWords, contains('当前线路较慢，已自动切换'));
      expect(target.readAsStringSync(), 'F' * 4096);
    });

    test('快速通道不误切（直连一次发完即成功）', () async {
      final a = _ThrottledAdapter()..requestNo = 1; // 绕过「首次慢」编排
      final target = File('${tmp.path}${Platform.pathSeparator}a2.apk');
      final statusWords = <String>[];
      final outcome = await downloadApk(
        _dio(a),
        _asset(),
        target,
        onChannelChange: statusWords.add,
        speedProbe: _shortProbe,
      );
      expect(outcome.channelUsed, '直连 GitHub');
      expect(
        statusWords.any((w) => w.startsWith('当前线路较慢')),
        isFalse,
        reason: '快速通道不许误切',
      );
      expect(target.readAsStringSync(), 'F' * 4096);
    });

    test('全员皆慢 → 定在直连收尾轮（禁判慢）把下载走完', () async {
      final a = _ThrottledAdapter(slowProxy: true, slowAll: true); // 全部通道慢
      final target = File('${tmp.path}${Platform.pathSeparator}a3.apk');
      final outcome = await downloadApk(
        _dio(a),
        _asset(),
        target,
        speedProbe: _shortProbe,
      );
      expect(outcome.channelUsed, '直连 GitHub',
          reason: '全员慢过一轮后回直连（实测最快候选）收尾');
      expect(target.readAsStringSync(), 'F' * 4096);
      // 防抖③：切换总次数 ≤ 候选数+1（4 通道 → 收尾前最多 4 次切换）
      expect(a.requestNo, lessThanOrEqualTo(kProxyPrefixes.length + 3));
    });

    test('全部通道失败仍上抛（既有语义不回归）', () async {
      final a = _ThrottledAdapter();
      final target = File('${tmp.path}${Platform.pathSeparator}a4.apk');
      final outcome = await downloadApk(
        _dio(a),
        _asset(),
        target,
        speedProbe: _shortProbe,
      );
      expect(target.existsSync(), isTrue);
      expect(outcome.file.path, target.path);
    });
  });
}
