# love-space Flutter 迁移 · 交接简报

> 交接时间：2026-11-11 · 交接人：啊奴（WorkBuddy 会话） · 接手方：软件开发团队（专家团）
> 方案文件：`app-flutter/docs/flutter-plan-v2.md`（功能定义与阶段划分的唯一事实源）
> 一句话现状：阶段 0/1 闭环，阶段 2 完成前两页（账号/首页）并经真机验收，下一步是条目 3 聊天专章。

## 1. 当前进度

| 阶段 | 内容 | 提交 | 状态 |
|---|---|---|---|
| 阶段 0 | API 样本实测（7 组）+ Dio/CookieJar 鉴权实验 8/8 PASS + 缺口清单 | `e166330` | ✅ 闭环 |
| 阶段 1 | Flutter 脚手架（Riverpod/go_router/Dio+CookieJar/secure_storage/drift/SSE 客户端/登录占位/CI） | `d257436` | ✅ 闭环（真机双网验收通过） |
| 阶段 1 收尾 | 移除中文路径绕法（`3628b23`）、release 补 INTERNET 权限（`1f30b71`）、会话播种+线路优先级（`578c685`）、探测并行化+看门狗（`2c3cc8d`）、splash 死锁根修（`22c23ec`） | 见左 | ✅ |
| 阶段 2 · 条目 1 账号页 | 三态认证（setup/join/login）+ 账号资料（昵称/头像/改密）+ 邀请 + 退出 | `de00357` | ✅ 真机验收通过 |
| 阶段 2 · 通则 | 二级页 push 导航（账号页 go→push） | `d39d192` | ✅ |
| 阶段 2 · 条目 2 首页 | hero 相恋天数 / 今天的心情（记改）/ 纪念日倒计时 / 最新动态 / 每日一句 / 相恋日期设置（PUT /api/space） | `2350441` | ✅ 验收通过 |
| 阶段 2 · 首页交互补强 | 不留死卡片：hero 整卡可点、纪念日→我们 tab、动态卡→时光 tab | `7b5e13f` | ✅ 验收通过 |

**下一步**：条目 3 聊天专章（**还没出分步实施清单，接手第一件事是出清单给主人确认**）。要求：发送带 client_id 防重（重试复用同一 id）、实时走 SSE 增量拉取、媒体两段式上传与 preview status 处理、输入区面板与键盘同槽位互斥切换、附录 B 发送三态（三点动效→成功清除/失败标红可重试）与长按菜单动效（气泡 1.02 微放大就近展开）。契约样本在 `docs/api-samples/03-records.md`、`04-media.md`、`05-realtime-aggregate.md`。

**页面顺序（方案 §阶段 2）**：账号✅ → 首页✅ → 消息(专章) → 时光 → 相册 → 我们 → 个人角落 → 设置/生理期。

## 2. 环境与构建

### 路径与工具链
- 仓库真路径 **`D:\Dev\love-space`**；`D:\恋爱空间` 是指向它的 junction，**不要经 junction 跑 flutter/gradle/dart**（中文路径三坑已根除：AGP 路径检查、jni CMake、AOT gen_snapshot）。
- Flutter **3.47.9**（`D:\Dev\flutter`，自带 Dart 3.13.7）；JDK/Android SDK 在 `C:\Android`（ndk 28.2、build-tools 36）。
- 依赖镜像：`FLUTTER_STORAGE_BASE_URL`/`PUB_HOSTED_URL` = flutter-io.cn；`PUB_CACHE=D:\Dev\.pub-cache`（用户级 setx）。
- Gradle 首次构建慢是依赖下载（settings.gradle.kts 已配阿里云 Maven 镜像），增量很快。

### 本 Bash 工具环境的硬坑（必读）
- 🔴 **flutter 命令输出经管道会被 SIGTERM**：一律 `cmd //c "flutter ... > %TEMP%\x.txt 2>&1"` 落盘再读。SIGTERM 间歇出现，重试即可。
- 🔴 **本机代理变量（HTTP_PROXY/https_proxy 等，端口每次会话会变）会劫持 flutter_tester 的回环 WebSocket** → test 报 `Invalid WebSocket upgrade request`。跑 test/analyze/build 前清掉全部大小写代理变量。
- `flutter pub get` 不主动升 pubspec.lock；要升特定包用 `flutter pub upgrade <pkg>`。

### sqlite3 native assets 预编译库（换机/清缓存后必做）
sqlite3 3.9.1 的构建钩子默认从 GitHub releases 下载 `libsqlite3.arm64.android.so`，直连超时会挂构建。绕法（非钉版本）：
1. 经代理下载官方产物 `https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.9.1/libsqlite3.arm64.android.so`；
2. sha256 校验 = `e684ef8646ffd48b95bae58bf29c55ffd85acebac2a7118ffde9fd02df37d629`；
3. 预置到 `app-flutter/.dart_tool/hooks_runner/shared/sqlite3/build/download-e684ef86/libsqlite3.so`（目录名=哈希前 8 位，文件名固定 `libsqlite3.so`），钩子命中缓存即跳过下载。CI/其它机器需 GitHub 可达。

### git push 惯例
- 走 NAS 代理：`git -c http.proxy=http://192.168.31.95:7890 -c https.proxy=http://192.168.31.95:7890 push origin main`（NAS `192.168.31.95`，mihomo）。
- 🔴 **全局 git config 曾有 github.com 域级代理残留（已清）**：`http.https://github.com/.proxy` 优先级高于 `-c http.proxy` 和 env 变量，别再往 global 写域级代理。
- 会话服务代理端口每次启动会变，git 走 env 代理时别显式覆盖。
- 出口全断（NAS 7890 / ECS 隧道 18081 / 会话代理 / 直连全灭）→ 按熔断规则停手汇报，本地提交不丢。

### 真机（小米 15，adb id `31e0f85d`）
- 安装：`adb install -r app-flutter/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`（split-per-abi，arm64 versionCode = 1 + 1000×2 = **2001**；debug 全量包 code=1 会被判降级，debug 也要 `--split-per-abi`）。
- release 不可 run-as；要读设备数据先装 debug split 包覆盖（同 debug 签名，数据保留）。
- uiautomator dump 常被 MIUI 拦 → UI 验证用 `adb exec-out screencap -p` 截图。
- ⚠️ 主人使用手机时不要用 adb input tap 抢焦点（验收由主人手动做，见下）。

## 3. 现行规矩（全部强制）

1. **后端零改动**：缺口先停下报告，不自创协议、不钉版本绕过（sqlite3 缓存预置是唯一例外，属构建环境问题）。
2. **一页一提交**：交阶段式小结（做了什么/对照清单/复验数据/APK 路径）后**停下等主人核验**，不连冲多页。
3. **验收由主人手动做**：助手只构建 + adb 覆盖安装 + 截图佐证，**禁止 adb 自动点击/输入**（主人使用手机时会抢焦点）。
4. 🔴 **UI 验收以真机截图为准——服务端 200 ≠ 页面正确**（教训：splash 死锁，me 200 但路由 authed 分支漏处理 /splash 导致永远转圈，服务端视角全部「正常」）。
5. 🔴 **二级页一律 `context.push`**（保留主页在路由栈），AppBar automaticallyImplyLeading 不关；系统返回手势在二级页回上一页，主页根部按返回才退出；每页小结验收点必含「**返回路径：按钮和手势都能回上一页**」。
6. **首页不留死卡片**：Web 能点的，App 必须有明确去向（可点→去向 / 只读→Web 依据），逐项列入对照清单。
7. **对照清单**：每页功能与交互以 Web 端现状（`static/app.js`）为准逐项对照，不增不减；跨页归属的项注明去向。
8. **线路优先级（主人定版，写死 `config.dart:routePriority`，不读 /api/routes 顺序）**：4019 Lucky → iepose.cn 节点小宝 → 350921.xyz 腾讯云 → love.yangyuhui.xyz CF → 192.168.31.95:1314 内网明文。`effectiveRoutes`：dart-define 覆盖值不在清单里=测试环境单线模式。
9. **会话播种/自愈现状**：token 正本存 secure_storage；登录后 `seedSessionToAllRoutes` 播种五线路（http 线路不带 Secure）；冷启动/换线 `ensureSessionCookie` 自愈（先扫其它线路 jar，再 secure_storage）；登出/401 全清理。cookie_jar 的 per-host 文件偶发丢失已由此兜住，不要回退此机制。
10. **CI 已钉 Flutter 3.47.9 + `flutter analyze`**（教训：`dart analyze --fatal-infos` 在新 stable 已移除，exit 64）。全绿是阶段 3 的要求，阶段 2 期间红了不阻塞但顺手修。
11. 预算常量集中在 `config.dart`（probeTimeout 3s / bootstrapDeadline 10s / sse 3s-30s / sessionTtl 30d），改动注意相互依赖（看门狗 ≥ 探测预算+me 时间）。
12. 收尾清理一次性脚本/截图/临时日志；长期记忆与每日流水在 `D:\恋爱空间\.workbuddy\memory\`（junction 路径有效）。

## 4. 已知待办与坑

- **on-this-day（历史上的今天）/ 小年报（yearbook）归属未定**：Web 首页异步区块，方案条目 2 未列，等主人拍板（并入首页补做 or 归统计/时光页）。
- **封面更换（cover-pick）/ 存一张天数卡片（loveCardImage）**：媒体能力，阶段 4 做（首页对照清单已注明）。
- **iOS 构建流**：workflow 已配（macos-14 手动触发，私有仓分钟 10 倍计费），阶段 3 才要求全绿；TestFlight 签名在阶段 6（需 Apple Developer secrets）。
- **推送**：后端无原生推送注册端点，阶段 5 三选一路线（方案 §阶段 5，实施前确认）。
- 坑备忘：`PUT /api/records/{id}` 是全量 body；写方法一律带 `X-Love-Space: 1`（拦截器已统一注入，连 /api/login 也算写方法）；上传限流 30 次/300s；mood body 含 date/emoji/content；`/media/{id}` 图片需 Cookie（现用共享 dio 取字节，阶段 4 换 cached_network_image 统一缓存）；纪念日推算结果（due/days）必须随记录返回，展示禁止二次重算（-97 天事故）。
- 竞品与旧壳参考：旧 Capacitor 壳在 `android-app/`（MainActivity 的 seedCookie/shareSessionToAll 是会话播种的参照实现）；Web 端 `static/app.js` 是功能现状唯一对照源。
