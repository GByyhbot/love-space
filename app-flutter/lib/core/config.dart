/// 运行配置：API 基地来源顺序 = --dart-define 注入 → 内置主线路 → GET /api/routes 清单回退。
/// 方案 v2 阶段 1：禁止把五个域名硬抄进多处；内置主线路只在这里出现一次。
library;

class AppConfig {
  AppConfig._();

  /// 内置主线路（与服务端 config.py SPACE_ROUTES 首条一致）。
  /// 编译期可用 --dart-define=LOVE_API_BASE=... 覆盖（测试环境指向本地 uvicorn）。
  static const String builtinMainRoute = String.fromEnvironment(
    'LOVE_API_BASE',
    defaultValue: 'https://love.yangyuhui.xyz',
  );

  /// 会话 Cookie 名（方案 §0：纯 Cookie 鉴权，无 Bearer 通道）
  static const sessionCookieName = 'love_session';

  /// 会话有效期 30 天（服务端判断，客户端只处理 401 回登录）
  static const sessionTtlDays = 30;

  /// SSE 端点（方案 §0：实时通道是 SSE /api/events，无 WebSocket 消息通道）
  static const ssePath = '/api/events';

  /// SSE 断线重连：首包 retry: 3000 起步，指数退避封顶 30s（与 Web 端策略一致）
  static const sseRetryBase = Duration(seconds: 3);
  static const sseRetryCap = Duration(seconds: 30);
}
