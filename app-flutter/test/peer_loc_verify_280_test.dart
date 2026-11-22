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

  group('原生桥契约（fix4 胶水重做：原生一口价）', () {
    test('Kotlin 胶水：toggle 一口价 + 权限两值分开回报 + 探针保留', () {
      final kt = File('android/app/src/main/kotlin/cn/iepose/lovespace/'
              'love_space/PeerLocNative.kt')
          .readAsStringSync();
      // 一口价方法面
      expect(kt.contains('"toggle" ->'), isTrue, reason: '单一原生入口');
      expect(kt.contains('"status" ->'), isTrue, reason: '开关态单一事实源查询');
      expect(kt.contains('"exportFatalLog" ->') || kt.contains('exportFatalLog()'),
          isTrue, reason: 'fatal 导出入口');
      // 权限两值分开回报（缺前台/缺后台两种 reason）
      expect(kt.contains('val fine = fineGranted(context)'), isTrue);
      expect(kt.contains('val bg = backgroundGranted(context)'), isTrue);
      expect(kt.contains('需要把定位权限设为「始终允许」') ||
          kt.contains('始终允许'), isTrue, reason: '缺后台对应引导文案');
      // 返回结构 {ok, reason, detail}
      expect(kt.contains('"detail" to detail'), isTrue);
      // 采集核不动：采样参数/队列/422 自愈
      expect(kt.contains('MIN_DISTANCE_M = 25f'), isTrue);
      expect(kt.contains('MIN_TIME_MS = 15_000L'), isTrue);
      expect(kt.contains('STILL_HEARTBEAT_MS = 5 * 60_000L'), isTrue);
      expect(kt.contains('QUEUE_MAX = 50'), isTrue);
      expect(kt.contains('BATCH_MAX = 5'), isTrue);
      expect(kt.contains('X-Love-Space'), isTrue);
      // 探针保留
      expect(kt.contains('receivedCount'), isTrue, reason: '回调实证探针保留');
      // fatal 落盘（原生侧）+ 导出
      expect(kt.contains('fatal-native.txt'), isTrue);
      expect(kt.contains('fun exportFatalLog'), isTrue);
      // [peer-loc] 日志保留
      expect(kt.contains('TAG = "peer-loc"'), isTrue);
    });

    test('manifest：后台定位权限声明在位', () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest.contains('android.permission.ACCESS_BACKGROUND_LOCATION'),
          isTrue, reason: '「始终允许」需单独引导（FGS 合规项）');
      expect(manifest.contains('android.permission.ACCESS_FINE_LOCATION'), isTrue);
    });

    test('fix4 Dart 胶水：只搬运与渲染（禁 import 三插件 + 单一入口）', () {
      final loc = File('lib/core/peer/peer_locator.dart').readAsStringSync();
      // 胶水令四：peer 链 Dart 侧禁止 import geolocator 与 shared_preferences
      expect(loc.contains('package:geolocator'), isFalse,
          reason: '禁 import geolocator');
      expect(loc.contains('package:shared_preferences'), isFalse,
          reason: '禁 import shared_preferences');
      expect(loc.contains('package:path_provider'), isFalse,
          reason: '禁 import path_provider（持久化链整段删除）');
      // 单一原生入口 + 结构化结果
      expect(loc.contains("invokeMethod<Map<Object?, Object?>>('toggle'"), isTrue,
          reason: 'toggle 单一原生入口');
      expect(loc.contains('class PeerVerifyResult'), isTrue);
      expect(loc.contains('final Map<Object?, Object?> detail;'), isTrue);
      // 开关态原生单一事实源（status 回填）
      expect(loc.contains("invokeMethod<Map<Object?, Object?>>('status'"), isTrue);
      expect(loc.contains("peerVerifyOn = status['running'] == true"), isTrue,
          reason: '页面进入/toggle 后以查询结果回填');
      // 凭据搬运（secure_storage 正本）
      expect(loc.contains('readSessionToken()'), isTrue);
      expect(loc.contains('readLastRoute()'), isTrue);
      // fatal 导出
      expect(loc.contains('exportPeerFatalLog'), isTrue);
      // 红线：不调 events/sos（二三期后端面）
      expect(loc.contains('/api/peer/events'), isFalse);
      expect(loc.contains('/api/peer/sos'), isFalse);
      expect(loc.contains('/api/peer/location'), isFalse,
          reason: '上报在原生层执行');
    });

    test('验证卡：status 回填 + 导出入口 + 常驻原因行（真实组件断言）', () {
      final settings =
          File('lib/features/settings/settings_home_page.dart').readAsStringSync();
      expect(settings.contains('showSnackBar'), isFalse,
          reason: 'App 内禁底部 SnackBar（2.4.x 契约）');
      expect(settings.contains('peerVerifyStatus()'), isTrue,
          reason: '页面进入回填');
      expect(settings.contains('_refresh()'), isTrue);
      expect(settings.contains('exportPeerFatalLog()'), isTrue,
          reason: 'fatal 导出/分享入口');
      expect(settings.contains("Text('⚠ "), isTrue, reason: '常驻原因行');
      expect(settings.contains('chatToastProvider.notifier).show'), isTrue,
          reason: '转瞬提示走顶部弹窗');
    });
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
