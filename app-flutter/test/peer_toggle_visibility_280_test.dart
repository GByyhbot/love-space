/// 2.8.0 第 0 步 fix2 · 真机报告复现护栏（widget 级证据，fix1 静默回弹口径）。
///
/// 复现：geolocator 平台通道抛 PlatformException（MIUI 实证路径）→
/// fix1 行为：异常在 PeerVerifyResult 产生前冒泡被 framework 吞 → 开关
/// 回弹、无 SnackBar、无常驻文案。
/// 修复后行为：_toggle 全程装甲 + 常驻原因行（⚠）常驻在开关行下方 +
/// 顶部弹窗（既有契约，SnackBar 禁用），开关保持关。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:love_space/features/settings/settings_home_page.dart';
// PeerLocNative 原生通道 mock（返回结构化拒绝/成功，不依赖真机）
Future<void> mockNative(Future<Object?>? Function(MethodCall call) handler) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('peer_loc/native'),
          (call) async => handler(call));
  // 开关态已改 path_provider 文件持久化（fix3：去 shared_preferences）——
  // test binding 下 path_provider Pigeon 通道无 mock 会永挂（fix3 实证），
  // 用官方 PathProviderPlatform.override 注入临时目录。
  final tmp = Directory.systemTemp.createTempSync('peer-verify-test');
  PathProviderPlatform.instance = _FakePathProvider(tmp.path);
}

void main() {
  testWidgets('复现 fix1 缺陷：geolocator 平台异常 → 必须有可见说明（SnackBar + 常驻原因行）',
      (tester) async {
    // 原生层：start 也会被调到（权限终判走原生；原生 hasPermission=false
    // → 引导 → geolocator 抛平台异常 → 原生终判 false → 结构化原因）
    await mockNative((call) async {
      switch (call.method) {
        case 'hasPermission':
          return false;
        case 'start':
          return {'started': false, 'reason': '需要定位权限'};
        case 'stop':
          return true;
        case 'stats':
          return {'received': 0, 'queue': 0, 'reported': 0};
      }
      return null;
    });
    // geolocator 平台通道：抛 PlatformException（MIUI 实证路径）
    for (final ch in [
      'flutter.baseflow.com/geolocator',
      'flutter.baseflow.com/geolocator_android',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(ch), (call) async {
        throw PlatformException(code: 'locationServicesDisabled');
      });
    }

    await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: Scaffold(body: PeerVerifyCard()))));
    await tester.pump();

    final sw = find.byType(SwitchListTile);
    expect(sw, findsOneWidget);
    await tester.tap(sw);
    await tester.pump(); // 触发 _toggle
    await tester.pump(const Duration(milliseconds: 100)); // async 链推进
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    // 修复后：常驻原因行必须出现（转瞬提示走顶部 toast——App 内禁
    // SnackBar 是既有契约；fix1 是连常驻行都没有）
    expect(find.byType(SnackBar), findsNothing,
        reason: 'App 内禁底部 SnackBar（2.4.x 契约）');
    // 常驻原因行必须出现（SnackBar 转瞬后仍可见）
    expect(find.textContaining('⚠'), findsOneWidget,
        reason: '失败原因常驻文案（fix1 缺失项）');
    // 开关保持关（不假开）
    final swWidget = tester.widget<SwitchListTile>(sw);
    expect(swWidget.value, isFalse, reason: '失败态开关保持关');
  });
}

/// path_provider 官方 override 口径（platform_interface 注入，test binding
/// 不挂；真机走真通道）。
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}
