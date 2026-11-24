/// 2.8.0 第 0 步 fix4 · 胶水重做真机复现护栏（widget 级证据）。
///
/// 口径（胶水重做令）：Dart 只搬运与渲染——mock 原生 toggle 返回
/// 「缺后台」细分 reason（{ok:false, reason:…, detail:{fine,background}}）→
/// tap 后：⚠ 常驻原因行出现（细分引导文案）、开关保持关、无 SnackBar 违约；
/// toggle 后以原生 status 回填开关。另覆盖「未登录」路径（凭据空 → 结构化
/// 原因可见，不静默回弹）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:love_space/features/settings/settings_home_page.dart';

/// path_provider 官方 override（test binding 下 Pigeon 通道无 mock 会永挂）。
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

// PeerLocNative 原生通道 mock（fix4 契约面：toggle/status/exportFatal）
Future<void> mockNative(
  Future<Object?>? Function(MethodCall call) handler, {
  bool withCredentials = false,
}) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('peer_loc/native'),
          (call) async => handler(call));
  // secure_storage（凭据正本）：withCredentials=true 返回 token/route
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
    if (withCredentials && call.method == 'read') {
      final key = (call.arguments as Map)['key'] as String?;
      if (key == 'love_session_token') return 'tok123';
      if (key == 'last_route') return 'https://test.local';
    }
    return null;
  });
  // path_provider（卡片无持久化依赖，仅平台初始化兜底）
  PathProviderPlatform.instance = _FakePathProvider('/tmp/peer-verify-test');
}

void main() {
  testWidgets('缺后台权限：原生细分 reason → ⚠ 常驻行 + 顶部弹窗 + 开关保持关',
      (tester) async {
    await mockNative((call) async {
      switch (call.method) {
        case 'toggle':
          return {
            'ok': false,
            'reason': '定位权限已授「使用期间」，还需要「始终允许」：'
                '系统设置 → 应用 → 恋爱空间 → 位置 → 选择「始终允许」后重试',
            'detail': {'fine': 'granted', 'background': 'denied'},
          };
        case 'status':
          return {'running': false, 'received': 0, 'queue': 0, 'reported': 0};
        case 'exportFatal':
          return {'path': '', 'content': ''};
      }
      return null;
    }, withCredentials: true);

    await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: Scaffold(body: PeerVerifyCard()))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final sw = find.byType(SwitchListTile);
    expect(sw, findsOneWidget);
    await tester.tap(sw);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    // 常驻原因行（细分引导文案可见）
    expect(find.textContaining('始终允许'), findsWidgets,
        reason: '缺后台的细分引导必须可见（胶水令二）');
    // App 内禁底部 SnackBar（2.4.x 契约）
    expect(find.byType(SnackBar), findsNothing);
    // 开关保持关
    final swWidget = tester.widget<SwitchListTile>(sw);
    expect(swWidget.value, isFalse, reason: '失败态开关保持关');
  });

  testWidgets('未登录路径：凭据空 → 结构化原因可见（不静默回弹）', (tester) async {
    var nativeToggleCalled = false;
    await mockNative((call) async {
      if (call.method == 'toggle') nativeToggleCalled = true;
      return {'ok': true, 'reason': '', 'detail': {}};
    });

    await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: Scaffold(body: PeerVerifyCard()))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    // secure_storage mock 返回 null → 凭据空 → 结构化原因；原生 toggle 不被调
    expect(find.textContaining('未登录或会话已失效'), findsOneWidget,
        reason: '凭据空的可见说明');
    expect(nativeToggleCalled, isFalse,
        reason: '凭据缺失时不得到达原生启动层');
  });
}
