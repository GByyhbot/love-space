/* 脚手架阶段 1 的最小测试：令牌与配置正确性（不依赖网络） */
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/config.dart';

void main() {
  test('内置主线路是生产域名', () {
    expect(AppConfig.builtinMainRoute, 'https://love.yangyuhui.xyz');
  });
  test('线路优先级：主人定版顺序，首选 Lucky 4019', () {
    expect(AppConfig.routePriority.first, 'https://love-space.yangyuhui.xyz:4019');
    expect(AppConfig.routePriority, [
      'https://love-space.yangyuhui.xyz:4019', // Lucky DDNS+重定向
      'https://love-space.iepose.cn', // 节点小宝
      'https://love.350921.xyz', // 腾讯云
      'https://love.yangyuhui.xyz', // Cloudflare
      'http://192.168.31.95:1314', // 内网明文
    ]);
    expect(AppConfig.effectiveRoutes, same(AppConfig.routePriority));
  });
  test('SSE 重连策略：3s 起步封顶 30s', () {
    expect(AppConfig.sseRetryBase, const Duration(seconds: 3));
    expect(AppConfig.sseRetryCap, const Duration(seconds: 30));
  });
  test('SSE 端点与方案一致', () {
    expect(AppConfig.ssePath, '/api/events');
  });
  test('探测与 bootstrap 预算：单条 3s 硬超时，整体 10s 兜底', () {
    expect(AppConfig.probeTimeout, const Duration(seconds: 3));
    expect(AppConfig.bootstrapDeadline, const Duration(seconds: 10));
  });
}
