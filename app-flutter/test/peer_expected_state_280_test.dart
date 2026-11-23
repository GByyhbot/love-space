/// 2.8.0 第 0 步 fix6 · 期望态两态显示护栏（A1）。
///
/// 口径（fix6 施工令三）：期望态只用于「显示 + 恢复入口」，**永不自动开启
/// 采集**；实态唯一事实源仍是原生 status。两条用例：
/// ① 期望开 + 实态停 → 出黄色提示，且**不自动**调 toggle；点「恢复」才调；
/// ② 期望关 → 不出提示。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:love_space/core/peer/peer_expected_state.dart';
import 'package:love_space/features/settings/settings_home_page.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.dir);
  final String dir;

  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

const _native = MethodChannel('peer_loc/native');
const _storage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// 通道 mock：status 固定「未运行」，toggle 计数并返回成功。
class _NativeMock {
  int toggleCalls = 0;
  bool? lastEnable;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, (call) async {
      switch (call.method) {
        case 'toggle':
          toggleCalls++;
          lastEnable = (call.arguments as Map)['enable'] as bool?;
          return {
            'ok': true,
            'reason': '',
            'detail': {'fine': 'granted', 'background': 'granted'},
          };
        case 'status':
          return {'running': false, 'received': 0, 'queue': 0, 'reported': 0};
        case 'exportFatal':
          return {'path': '', 'content': ''};
        case 'batteryIgnored':
          return true;
        case 'requestIgnoreBattery':
          return true;
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_storage, (call) async {
      if (call.method == 'read') {
        final key = (call.arguments as Map)['key'] as String?;
        if (key == 'love_session_token') return 'tok123';
        if (key == 'last_route') return 'https://test.local';
      }
      return null;
    });
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_storage, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  final mock = _NativeMock();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('peer-expected-280-');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    mock
      ..toggleCalls = 0
      ..lastEnable = null
      ..install();
  });

  tearDown(() {
    mock.remove();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> pumpCard(WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: Scaffold(body: PeerVerifyCard()))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('期望开 + 实态停 → 出提示且不自动 toggle；点恢复才调', (tester) async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{kPeerExpectedKey: true});
    await pumpCard(tester);

    expect(find.textContaining('已停止（进程被系统结束）'), findsOneWidget,
        reason: '期望开而实态停必须出黄色提示');
    expect(mock.toggleCalls, 0, reason: '期望态只提示，绝不自动开启采集');

    await tester.tap(find.text('恢复'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(mock.toggleCalls, 1, reason: '点「恢复」才走既有 toggle 一口价链');
    expect(mock.lastEnable, isTrue);
  });

  testWidgets('期望关 → 无提示（实态停也不提示）', (tester) async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{kPeerExpectedKey: false});
    await pumpCard(tester);

    expect(find.textContaining('已停止（进程被系统结束）'), findsNothing,
        reason: '期望关时不得提示恢复');
    expect(find.text('恢复'), findsNothing);
    expect(mock.toggleCalls, 0);
  });

  test('期望态落盘/读回（独立模块）', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    expect(await readPeerExpectedOn(), isFalse, reason: '缺省按关');
    await writePeerExpectedOn(true);
    expect(await readPeerExpectedOn(), isTrue);
    await writePeerExpectedOn(false);
    expect(await readPeerExpectedOn(), isFalse);
  });
}
