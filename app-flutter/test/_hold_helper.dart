// 2.4.10 乙批测试辅助：模拟长按确认走满（供多处测试复用；下划线文件
// 不参与默认测试发现——testWidgets 只在导入它的测试文件里生效）。
import 'package:flutter_test/flutter_test.dart';

/// 按住 [button] 直到进度环走满（长按识别 600ms + 环 1.6s），
/// 再补驻留 pump 触发 onConfirm。
Future<void> holdConfirm(WidgetTester tester, Finder button) async {
  final g = await tester.startGesture(tester.getCenter(button));
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 1700));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pumpAndSettle();
  await g.up();
}
