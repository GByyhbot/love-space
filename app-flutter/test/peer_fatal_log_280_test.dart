/// 2.8.0 第 0 步 fix5 · 致命态与诊断落盘护栏（Dart 侧，不 mock 通道接线）。
///
/// 与 peer_loc_verify / peer_toggle_visibility 的分工：
/// · 那两个文件 mock 了 peer_loc/native，只验协议形状；
/// · 本文件**故意不给 peer_loc/native 装 handler**，让通道真的不可用
///   （MissingPluginException），验证两件事：
///   ① 卡面拿到「通道未注册（致命）」结构化原因，不被当普通失败/开关关了吞掉；
///   ② 导出**凭 Dart 侧文件**仍能拿到内容（fix4 真机导出空的病根：文件从未生成）；
///   ③ fatal 文件只写诊断，不参与开关判定（peerVerifyOn 仍只认原生 status）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:love_space/core/peer/peer_fatal_log.dart';
import 'package:love_space/core/peer/peer_locator.dart';
import 'package:love_space/features/settings/settings_home_page.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.dir);
  final String dir;

  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

const _native = MethodChannel('peer_loc/native');
const _storage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// 凭据正本（secure_storage）只在有通道时才读得到；与原生通道无关。
void _mockStorage({bool withCredentials = true}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_storage, (call) async {
    if (withCredentials && call.method == 'read') {
      final key = (call.arguments as Map)['key'] as String?;
      if (key == 'love_session_token') return 'tok123';
      if (key == 'last_route') return 'https://test.local';
    }
    return null;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('peer-fatal-280-');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    _mockStorage();
    // 关键：**故意不装** peer_loc/native 的 handler —— 通道在测试里真的不存在
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_storage, null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('通道不可用 → 致命态结构化原因（不被当普通失败吞掉）', () async {
    final r = await peerVerifyToggle(true);
    expect(r.ok, isFalse);
    expect(r.reason, contains('通道未注册（致命）'),
        reason: 'MissingPluginException 必须走致命态文案');
    expect(r.detail['fatal'], 'unregistered');
  });

  test('通道不可用 → Dart 侧 fatal 文件已生成且含原文 + status 快照', () async {
    await peerVerifyToggle(true);
    final read = await peerFatalRead();
    expect(read.path, isNotEmpty, reason: '导出要能指出文件位置');
    expect(File(read.path).existsSync(), isTrue, reason: 'fix4 病根：文件必须真的生成');
    expect(read.content, contains('toggle-missing-plugin'));
    expect(read.content, contains('MissingPluginException'));
    expect(read.content, contains('status=unregistered'),
        reason: 'status 快照一并落盘（通道不可用时标记 unregistered）');
  });

  test('导出主路径 = Dart 文件：原生补充源缺席仍拿到内容', () async {
    await peerVerifyToggle(false);
    final log = await exportPeerFatalLog();
    expect(log.content, isNotEmpty, reason: '导出永远有内容可导');
    expect(log.content, contains('toggle-missing-plugin'));
    expect(log.content, isNot(contains('原生补充源')),
        reason: '通道未注册时不得出现空的原生补充段落');
    expect(log.path, contains('fatal-dart.txt'));
  });

  test('toggle 成功路径：结构化结果 + status 快照一并落盘', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, (call) async {
      switch (call.method) {
        case 'toggle':
          return {
            'ok': true,
            'reason': '',
            'detail': {'fine': 'granted', 'background': 'granted'},
          };
        case 'status':
          return {'running': true, 'received': 3, 'queue': 1, 'reported': 2};
        case 'exportFatal':
          return {'path': '/native/fatal-native.txt', 'content': 'native-line'};
      }
      return null;
    });

    final r = await peerVerifyToggle(true);
    expect(r.ok, isTrue);

    final read = await peerFatalRead();
    expect(read.content, contains('toggle-result'));
    expect(read.content, contains('ok=true'));
    expect(read.content, contains('running: true'), reason: 'status 快照');

    final log = await exportPeerFatalLog();
    expect(log.content, contains('原生补充源'), reason: '通道可用时原生降为补充源');
    expect(log.content, contains('native-line'));
  });

  test('fatal 文件只写诊断：不参与开关判定', () async {
    await peerFatalRecord('manual-probe', {'x': 1});
    expect(peerVerifyOn, isFalse, reason: '开关态只认原生 status，文件内容不影响');
    final read = await peerFatalRead();
    expect(read.content, contains('manual-probe'));
  });

  // 验收专项（定夺令第四）：人为让通道不可用时，卡面出「通道未注册（致命）」
  // 且导出能拿到文件——卡面全链（widget），不是函数级孤证。
  testWidgets('卡面致命态 + 导出可拿到文件（通道不可用，全链）', (tester) async {
    String? copied;
    // 「通道不可用」用 mock handler 抛 MissingPluginException 表达，与真机
    // 「No implementation found for method …」同一类型。注意不能靠「不装
    // handler」：widget 测试里未注册通道的消息要走真实平台消息通道才拿到
    // 回执，FakeAsync 下永远等不到，调用会静默挂死（调试实证）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, (call) async {
      throw MissingPluginException('No implementation found for method '
          '${call.method} on channel peer_loc/native');
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });

    await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: Scaffold(body: PeerVerifyCard()))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.textContaining('通道未注册（致命）'), findsOneWidget,
        reason: '致命态必须常驻可见');
    await tester.tap(find.text('导出定位诊断日志'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(copied, isNotNull, reason: '导出必须真的交付内容（不是「暂无记录」）');
    expect(copied, contains('MissingPluginException'),
        reason: '导出内容含致命原文');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
}
