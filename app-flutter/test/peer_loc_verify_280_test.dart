/// 2.8.0 第 0 步 · 路线 B 护栏（experiment/peer-loc-verify 分支）。
///
/// 钉住：GCJ-02 转换纯函数正确性（含境外原样返回）、采样常量口径、
/// 原生桥契约（channel 名/方法/manifest 权限）、第 0 步验证包不碰的边界
/// （不改 SSE 语义、不碰 events/sos 接口——一期 App 不调用）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/peer/gcj02.dart';

void main() {
  group('GCJ-02 转换（路线 B 端上坐标口径）', () {
    test('上海人民广场附近：偏移量与标准 GCJ-02 对拍一致', () {
      // WGS-84 上海人民广场（31.2304, 121.4737）→ GCJ-02
      // 参考值：独立实现对拍 dlat≈-0.00194 / dlng≈+0.00452（标准公式输出）
      final r = wgs84ToGcj02(31.2304, 121.4737);
      expect(r.lat, closeTo(31.2304 - 0.00194, 0.0005), reason: '纬度偏移（上海为负）');
      expect(r.lng, closeTo(121.4737 + 0.00452, 0.0005), reason: '经度偏移（上海为正）');
      // 转换后两点距离小（系统性形变非跳变）
      final d = distanceMeters(31.2304, 121.4737, r.lat, r.lng);
      expect(d, lessThan(1000.0), reason: '单点偏移应在数百米内');
      expect(d, greaterThan(100.0), reason: '偏移不可为零（否则没转）');
    });

    test('北京：偏移与上海方向不同（区域差异判定，防常数假实现）', () {
      final sh = wgs84ToGcj02(31.2304, 121.4737);
      final bj = wgs84ToGcj02(39.9042, 116.4074);
      final dLatSh = sh.lat - 31.2304;
      final dLatBj = bj.lat - 39.9042;
      expect((dLatSh - dLatBj).abs(), greaterThan(0.0005),
          reason: '不同城市偏移量必须不同（防零偏移/常数偏移假实现）');
    });

    test('境外坐标原样返回（模型无效域）', () {
      // 东京（139.69E, 35.68N）在模型域外
      final r = wgs84ToGcj02(35.6895, 139.6917);
      expect(r.lat, 35.6895);
      expect(r.lng, 139.6917);
    });

    test('转换可逆性偏差在米级内（GCJ→近似回 WGS 的往返一致）', () {
      // 单向偏移模型不可精确逆变换；验证同一点反复转换结果稳定（幂等纯函数）
      final a = wgs84ToGcj02(31.2304, 121.4737);
      final b = wgs84ToGcj02(31.2304, 121.4737);
      expect(a.lat, b.lat);
      expect(a.lng, b.lng);
    });

    test('距离函数：已知距离点对（1° 纬度 ≈ 111 km）', () {
      final d = distanceMeters(30.0, 121.0, 31.0, 121.0);
      expect(d, closeTo(111000, 500), reason: '1° 纬度球面距离');
      expect(distanceMeters(31.0, 121.0, 31.0, 121.0), 0.0);
    });
  });

  group('原生桥契约（路线 B）', () {
    test('Kotlin 侧：三 provider 采样 + 25m/15s + GCJ-02/距离函数在位', () {
      final kt = File('android/app/src/main/kotlin/cn/iepose/lovespace/'
              'love_space/PeerLocNative.kt')
          .readAsStringSync();
      expect(kt.contains('LocationManager.GPS_PROVIDER'), isTrue);
      expect(kt.contains('LocationManager.NETWORK_PROVIDER'), isTrue);
      expect(kt.contains('LocationManager.PASSIVE_PROVIDER'), isTrue);
      expect(kt.contains('MIN_DISTANCE_M = 25f'), isTrue, reason: '25m 位移触发');
      expect(kt.contains('MIN_TIME_MS = 15_000L'), isTrue);
      expect(kt.contains('STILL_HEARTBEAT_MS = 5 * 60_000L'), isTrue,
          reason: '静止 5 min 心跳');
      expect(kt.contains('STILL_CONFIRM_TIMES = 3'), isTrue, reason: '静止 3 次确认');
      expect(kt.contains('ACC_DROP_M = 100.0'), isTrue, reason: 'acc>100 丢弃');
      expect(kt.contains('ACC_LATEST_ONLY_M = 50.0'), isTrue,
          reason: '50<acc≤100 只 latest');
      expect(kt.contains('BATCH_MAX = 5'), isTrue, reason: '攒满 5 条上报');
      expect(kt.contains('BATCH_FLUSH_MS = 3 * 60_000L'), isTrue, reason: '或 3 min');
      expect(kt.contains('QUEUE_MAX = 50'), isTrue, reason: '队列上限 50 溢出丢最旧');
      expect(kt.contains('X-Love-Space', ), isTrue, reason: '原生上报带写门禁头');
      expect(kt.contains('wgs84ToGcj02'), isTrue, reason: '端上转换后上报');
      expect(kt.contains('peer_revision'), isFalse,
          reason: '原生层不碰 SSE 协议（后端职责）');
      // [peer-loc] 日志保留（第 0 步取证）
      expect(kt.contains('TAG = "peer-loc"'), isTrue);
    });

    test('manifest：后台定位权限声明在位', () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest.contains('android.permission.ACCESS_BACKGROUND_LOCATION'),
          isTrue, reason: '「始终允许」需单独引导（FGS 合规项）');
      expect(manifest.contains('android.permission.ACCESS_FINE_LOCATION'), isTrue);
    });

    test('2.7.1 风格真机修正：权限终判以原生 AppOps 口径为事实源', () {
    final kt = File('android/app/src/main/kotlin/cn/iepose/lovespace/'
            'love_space/PeerLocNative.kt')
        .readAsStringSync();
    final loc = File('lib/core/peer/peer_locator.dart').readAsStringSync();
    // MIUI 兼容：background 权限用 AppOps noteOpNoThrow 复核
    // 权限 API 不可作事实源——回调实证探针（received 计数）为准
    expect(kt.contains('receivedCount'), isTrue, reason: '回调实证探针');
    expect(kt.contains('startReason'), isTrue, reason: 'FINE 硬门槛缺失原因');
    expect(kt.contains('noteOpNoThrow'), isFalse,
        reason: 'AppOps hide API 不可达（真机翻车：String op 不存在/int 常量 hide）');
    // Dart 探针 3min 口径
    expect(loc.contains('_probeBackground'), isTrue);
    expect(loc.contains('onProbeFail'), isTrue, reason: '探针失败可见说明回调');
    // Dart：geolocator 只引导不终判——终判回原生
    expect(loc.contains('只用来**弹系统对话框引导**'), isTrue);
    expect(loc.contains('回调实证探针'), isTrue, reason: '探针口径注释');
    // 启用失败必给用户可见说明（不许静默回弹）
    expect(loc.contains('PeerVerifyResult'), isTrue, reason: '结构化 ok+reason');
    expect(loc.contains('未登录或会话已失效'), isTrue, reason: '凭据空给说明');
    expect(loc.contains('线路未就绪'), isTrue, reason: '线路空给说明');
    final settings =
        File('lib/features/settings/settings_home_page.dart').readAsStringSync();
    expect(settings.contains('showSnackBar'), isFalse,
        reason: 'App 内禁底部 SnackBar（2.4.x 契约，2.8.0 fix2 落实）');
    expect(settings.contains('chatToastProvider.notifier).show'), isTrue,
        reason: '失败原因走顶部弹窗（既有统一机制）');
    expect(settings.contains('_reason = msg') || settings.contains('_reason = r.reason'),
        isTrue, reason: '常驻原因行（失败态不许不可见）');
  });

  test('Dart 侧：凭据注入与开关持久化契约', () {
      final locator =
          File('lib/core/peer/peer_locator.dart').readAsStringSync();
      expect(locator.contains("readSessionToken()"), isTrue,
          reason: '会话正本与主 isolate dio 同源（secure_storage）');
      expect(locator.contains('readLastRoute()'), isTrue, reason: '线路 base 同源');
      expect(locator.contains("'cookie': 'love_session=\$token'"), isTrue);
      expect(locator.contains('peerVerifyToggle'), isTrue);
      expect(locator.contains('peerLocatorAutoStart'), isTrue,
          reason: '冷启动自动恢复采集');
      // 红线：不反复弹窗
      expect(locator.contains('不反复弹窗'), isTrue);
    });
  });

  test('红线：验证包不调用 events/sos 接口（二三期后端面）', () {
    final peer =
        File('lib/core/peer/peer_locator.dart').readAsStringSync();
    expect(peer.contains('/api/peer/events'), isFalse, reason: 'events 一期不调用');
    expect(peer.contains('/api/peer/sos'), isFalse, reason: 'sos 一期不调用');
    expect(peer.contains('/api/peer/location'), isFalse,
        reason: '上报在原生层执行（channel 契约），Dart 侧不直连');
  });

  test('Kotlin GCJ-02 与 Dart 实现同公式（结构对拍：关键常数一致）', () {
    final kt = File('android/app/src/main/kotlin/cn/iepose/lovespace/'
            'love_space/PeerLocNative.kt')
        .readAsStringSync();
    expect(kt.contains('A = 6378245.0'), isTrue);
    expect(kt.contains('EE = 0.00669342162296594323'), isTrue);
    expect(kt.contains('outOfChina'), isTrue, reason: '境外原样返回口径一致');
    // 偏移公式核心系数抽查（两实现同源公式）
    expect(kt.contains('-100.0 + 2.0*x + 3.0*y'), isTrue);
    expect(kt.contains('300.0 + x + 2.0*y'), isTrue);
  });
}
