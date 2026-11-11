/* 脚手架阶段 1 的最小测试：令牌与配置正确性（不依赖网络） */
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/config.dart';

void main() {
  test('内置主线路是生产域名', () {
    expect(AppConfig.builtinMainRoute, 'https://love.yangyuhui.xyz');
  });
  test('SSE 重连策略：3s 起步封顶 30s', () {
    expect(AppConfig.sseRetryBase, const Duration(seconds: 3));
    expect(AppConfig.sseRetryCap, const Duration(seconds: 30));
  });
  test('SSE 端点与方案一致', () {
    expect(AppConfig.ssePath, '/api/events');
  });
}
