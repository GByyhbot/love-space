/// 运行配置：API 基地来源 = --dart-define 注入（测试环境用）→ 内置线路优先级清单探测回退。
/// 方案 v2：禁止把五个域名硬抄进多处；线路清单只在这里出现一次。
library;

class AppConfig {
  AppConfig._();

  /// 内置主线路（dart-define 覆盖入口）。
  /// 编译期可用 --dart-define=LOVE_API_BASE=... 覆盖（测试环境指向本地 uvicorn）；
  /// 覆盖值不在 routePriority 清单里时，客户端只探测该单条（本地/测试模式）。
  static const String builtinMainRoute = String.fromEnvironment(
    'LOVE_API_BASE',
    defaultValue: 'https://love.yangyuhui.xyz',
  );

  /// 线路优先级（主人定版 2026-11-11，与服务端 config.py SPACE_ROUTES 无关）：
  /// Lucky 直连 → 节点小宝穿透 → 腾讯云 CloudBase → Cloudflare 隧道 → 内网直连。
  /// 客户端按此顺序做可达性探测，首选 4019，逐级回退；不再读 /api/routes 的返回顺序。
  /// 五条线路同一后端、同一 sessions 表，换线只需播种会话 Cookie，不必重新登录。
  static const List<String> routePriority = [
    'https://love-space.yangyuhui.xyz:4019', // ① Lucky DDNS+重定向（首选）
    'https://love-space.iepose.cn', // ② 节点小宝内网穿透
    'https://love.350921.xyz', // ③ 腾讯云 CloudBase
    'https://love.yangyuhui.xyz', // ④ Cloudflare 隧道
    'http://192.168.31.95:1314', // ⑤ 内网直连（明文，仅家庭 WiFi 可达）
  ];

  /// 实际生效的探测清单：dart-define 覆盖值不在优先级清单里 → 视为测试环境单线模式。
  static List<String> get effectiveRoutes =>
      routePriority.contains(builtinMainRoute) ? routePriority : [builtinMainRoute];

  /// 会话 Cookie 名（方案 §0：纯 Cookie 鉴权，无 Bearer 通道）
  static const sessionCookieName = 'love_session';

  /// 会话有效期 30 天（服务端 security.py 下发 max_age=30*86400，客户端播种时对齐）
  static const sessionTtlDays = 30;

  /// SSE 端点（方案 §0：实时通道是 SSE /api/events，无 WebSocket 消息通道）
  static const ssePath = '/api/events';

  /// SSE 断线重连：首包 retry: 3000 起步，指数退避封顶 30s（与 Web 端策略一致）
  static const sseRetryBase = Duration(seconds: 3);
  static const sseRetryCap = Duration(seconds: 30);
}
