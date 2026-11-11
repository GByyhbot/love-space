# love_space · Flutter 客户端（方案 v2）

> 迁移方案：`docs/flutter-plan-v2.md`（后端零改动；页面迁移以 Web 端现状为准，不增不减）

## 目录

- `docs/` — 方案与阶段 0 交付物（`api-samples/` 实测样本、`auth-plan.md` 鉴权结论、`gap-list.md` 缺口清单）
- `tools/auth_probe/` — 阶段 0 鉴权实验（dio + CookieJar，结论已落地到 `lib/core/api/api_client.dart`）
- `lib/core/` — 配置、API 客户端（拦截器定版：X-Love-Space 注入 / Cookie 持久化 / 401 回登录）、线路选择（内置主线路 → /api/routes 回退）、SSE 客户端（流式 + retry 退避重连 + 前后台感知）
- `lib/features/` — 页面（阶段 2 起逐页迁移，一页一 PR）

## 本机开发注意（Windows）

- 仓库路径含中文：`flutter analyze`（LSP 协议）在中文路径下崩溃——统一用 ASCII junction `D:\Dev\love-ws` 进入本工程运行 dart/flutter 工具
- 本机有 `HTTP_PROXY` 环境变量（WorkBuddy 挂载代理）：Dart HttpClient 默认读它且不识别 `NO_PROXY='*'`，客户端已显式 DIRECT
- `flutter test` 的 flutter_tester 走 localhost WebSocket，同样会被该代理拦——跑测试前先清掉代理环境变量
- iOS 构建在 GitHub Actions macOS runner（见 `.github/workflows/flutter-ci.yml`），本机只管 Android
