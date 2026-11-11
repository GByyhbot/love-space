# 阶段 0 · 鉴权方案验证结论（auth-plan）

> 实验工程：`app-flutter/tools/auth_probe/`（dio 5.x + dio_cookie_manager + cookie_jar 4.x）
> 实验环境：本地 uvicorn（全新 DATA_DIR，冒烟建号 e2e1/e2e2），Dart 3.13.7（Flutter 3.47.9 自带）
> 运行：`ORIGIN=http://127.0.0.1:8356 dart run auth_probe.dart`（本地测试服）
> 结果：**8/8 PASS**（E1–E7，见下）

## 实验结果（真实输出）

```
E1 登录: PASS（200，Set-Cookie 已入 jar）
E2 免登录 /api/me: PASS（name=小兔）
E5a 缺头写请求: PASS（403）
E5b 拦截器注入头写请求: PASS（200）
E4 垃圾会话: PASS（401，应回登录页）
E3 重启模拟: PASS（新实例免登录成立）
E6 SSE 流式: PASS（6s 捕获 4 行：retry: 3000 | : ready）
E7 多线路: PASS（/api/routes 返回 0 条线路；CookieJar 原生按域名隔离……）
```

## 结论与定版方案

1. **会话载体**：`dio` + `CookieManager(PersistCookieJar)` 完全可行。登录 Set-Cookie 自动入 jar、自动回传，无需手工管理 Cookie 头。
2. **持久化与「重启免登录」**：`PersistCookieJar(FileStorage)` 落盘后，全新 Dio 实例（等价 App 冷启动）免登录访问成立（E3 PASS）。App 实现时 Cookie 存储目录挂在应用私有目录（等价 flutter_secure_storage 保护范围之外的部分由系统沙箱兜底；会话 token 本身可接受文件存储，敏感凭据如密码才进 secure_storage）。
3. **失效处理**：无效/过期会话 → 服务端 **401「请先登录」**（中文 detail）。Dio 拦截器统一处理：捕获 401 → 清 Cookie → 切登录页。30 天自然过期走同一路径（服务端 `s.expires > now` 判断，无需客户端计时）。
4. **写请求头**：拦截器对 POST/PUT/PATCH/DELETE 统一注入 `X-Love-Space: 1`（实测缺头 403、带头 200）。GET 不需要。
5. **多线路**：CookieJar 按域名天然隔离。定版策略（与方案一致）：**固定主线路登录；主线路不可达时按 `GET /api/routes` 顺序切换；新域名 = 新 Cookie 域 = 重新登录**（不做跨域 Cookie 搬运，等价服务端会话本来就不能跨域共享）。⚠️ 实测注意：**本地测试环境 `/api/routes` 返回空列表**（线路清单仅生产配置）——客户端必须处理空清单：回退内置主线路，绝不能因空清单崩溃。
6. **SSE**：`/api/events` 为无限流（`retry: 3000` + `: ready` + 2s 心跳注释）。Dio `ResponseType.stream` + 逐块读取可行。**铁律：无限流端点绝不能用普通 GET 采样/请求（2s 心跳会让读超时永不触发，请求永久挂起）**。Flutter 端实现：流式订阅 + 时间上限守护 + 断线按 retry 起步指数退避封顶 30s，进后台断开、回前台补拉。
7. **本机代理坑（仅开发环境）**：Dart HttpClient 默认 `findProxyFromEnvironment`，会读 `HTTP_PROXY/HTTPS_PROXY` 环境变量且不识别 `NO_PROXY='*'` 通配——本机（WorkBuddy 挂载代理）必须显式 `findProxy = DIRECT`。真机上无这些环境变量，默认行为即是直连，无影响。实验代码已在 `directDio()` 中显式设置。

## 对方案 §3/§4 的补充确认

- SSE 首包序列实测：`retry: 3000` → 空行 → `: ready` → 空行 → `: heartbeat`（约 2s 一次）→ 事件 `data: {...}`（对方发消息 ≤5s 内到达，样例见 `api-samples/05-realtime-aggregate.md`）。
- 媒体 ETag/304 与 preview 回退规则实测见 `api-samples/04-media.md`。
- 30 天过期无法在实验中等待，采用同一失效路径（服务端 `expires` 判断 → 401）等价验证。
