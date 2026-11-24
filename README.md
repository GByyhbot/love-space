# 恋爱空间

一个**只属于两个人的私密恋爱空间**：发动态、存照片、聊天、听歌、写日记、记纪念日、留惊喜，还有正在落地的定位守护与情侣报备。手机体验优先，Docker 自行部署，数据完全自己掌握。

当前正式版本 **v2.7.1**（Web + Flutter Android App 同号）；**2.8.0 定位守护**开发中——后端已入库，App 侧在 `experiment/peer-loc-verify` 分支做双机 24 小时验证，通过后再合并发布。

📄 **项目展示页**：[`docs/showcase/index.html`](docs/showcase/index.html) —— 项目空间页的存档副本，随阶段进度不定期刷新；下载到本地用浏览器打开即可看渲染效果。

## 功能一览

- **首页** — 恋爱天数、双方今日心情、下个纪念日倒计时、「历史上的今天」、「今年的我们」年度小结
- **时光** — 图文/视频/语音动态，点赞评论，支持补记过去、按日期/作者/类型/关键词筛选；「传照片」可只进相册、不进时光
- **相册** — 动态照片自动汇总，可建主题相册；删除分类不删照片
- **消息** — 双人即时聊天（文字/图片/语音/视频/歌曲卡），语音转文字、逐人气泡皮肤，断线重连、失败重试、防重复发送（client_id 去重）
- **音乐** — 独立音乐页（只收录 kind=music 的歌曲，聊天语音不混入）；支持往 `data/music-drop/` 投放音频文件自动入库；通知栏全局播放器（与语音播放互斥）
- **一起看** — 双人同步放映区，进度同步
- **我们** — 纪念日（每年重复/提前提醒）、共同愿望清单、每日心情、留言板、情侣问答、共同打卡、生理期（独立加密库 period.db，双方可见可改）、报备信息卡（对方最近一次定位报备摘要）
- **个人角落** — 私密日记（完全账号隔离）、草稿箱、定时惊喜（到期自动公开）、回收站（**永不自动删除**，只能由作者手动彻底删除）
- **通知** — App 前台服务保持 SSE 长连接发原生通知；外部渠道以企业微信机器人为主，另支持浏览器系统推送、SMTP、Bark、Server酱、PushPlus、Webhook、Telegram、钉钉、飞书、ntfy；铃铛未读数与通知中心均不计聊天消息
- **数据保障** — 每日自动备份（可 AES-GCM 加密）、手动备份、个人数据导出、完整恢复与迁移；媒体按来源分区存放（chat / timeline / music / private / space / inbox）

## 定位守护（2.8.0，开发中）

- **后端（已入库）** — peer 五表（最新状态 / 轨迹点 / 围栏点 / 报备事件 / 使用统计）、轨迹与事件上报接口（Cookie 鉴权 + 写门禁、client_id 幂等）、双方状态与按日轨迹查询、SOS 强推送口径、SSE 第 7 段 `peer_revision`（只刷定位与报备，不触发整站刷新）；轨迹保留 15 天滚动删除
- **App（验证中）** — 路线 B：原生 LocationManager 采集 + 端上 GCJ-02 转换 + Leaflet 地图，零地图 Key；已完成通道注册修复、定位前台服务权限声明、电池豁免入口与期望态显示，正在双机 24 小时验证（断档与耗电达标后才决定是否加自动恢复 / 独立定位服务）
- **情侣主动报备（P0，方案已定稿未落地）** — 一键快捷报备 + 伴侣表情回应（Ack）+ 多渠道推送，复用 peer 事件流，手动报备不被 15 天清理误删。方案见 [`docs/couple-report-plan.md`](docs/couple-report-plan.md)

## 快速开始（Docker Compose，推荐）

要求：服务器/NAS 已安装 Docker 与 Docker Compose。

运行只需要两个文件：`docker-compose.yml` 和 `.env`——镜像由 GitHub Actions 构建好推到镜像仓库，服务器/NAS 上不编译源码。

```bash
# 1. 建目录，放上仓库根目录的 docker-compose.yml
mkdir -p /vol1/1000/LARJ && cd /vol1/1000/LARJ

# 2. 首次远程初始化时设置一次性随机口令（.env 已被忽略，不会提交）
echo "SETUP_TOKEN=<改成你的随机口令>" >> .env

# 3. 拉镜像并启动（数据目录 ./data 会自动创建）
docker compose pull
docker compose up -d

# 4. 查看状态
docker compose ps
curl http://127.0.0.1:1314/health
```

通过配置好的 HTTPS 域名访问空间：

1. 第一个账号在页面完成初始化（需输入 `SETUP_TOKEN`）
2. 初始化完成后从 `.env` 删除 `SETUP_TOKEN` 并重启容器
3. 首页点「发送邀请」生成链接给另一半注册；双方绑定后注册自动关闭

### 镜像与标签（二标制）

镜像由 GitHub Actions 构建，**每个仓库只维护两个标签**：`latest` + 当前版本号（如 `2.7.1`），历史的 `sha-*` / `edge` / 小版本标签不再前进。

| 仓库 | 地址 |
| --- | --- |
| GHCR（首选） | `ghcr.io/gbyyhbot/love-space` |
| Docker Hub（备用） | `2126263229/love-space` |

```bash
# 固定到某个版本，改 .env 后重建（不要用 --force-recreate，用 down/up 才能真正换容器）
echo "LOVE_IMAGE=ghcr.io/gbyyhbot/love-space:2.7.1" >> .env
docker compose pull && docker compose down && docker compose up -d
```

> ⚠️ 升级后以 `curl <地址>/api/status` 返回的 **build 号**验真，不要只看 pull 输出。
> GHCR 直连不可达时，可从 Docker Hub **按 digest** 拉同一构建产物再 retag；不要拿 Hub 的 `latest` 顶替——它在某些拉取路径上会给到旧图。

容器默认带了日志轮转（`10m × 3`）、2G 内存上限、只读根文件系统与 `cap_drop: ALL`，避免长期运行把宿主拖垮。内存上限可用 `.env` 覆盖：

```bash
echo "LOVE_MEM_LIMIT=3g" >> .env
```

## Android App（Flutter）

正式 App 是 `app-flutter/` 的 Flutter 工程（Android 为主，iOS 已搁置）；旧的 Capacitor 壳 `android-app/` 已退役，仅作存档，不要再用它出包。

- **出包**：GitHub Actions 的「APK Release」工作流**手动触发**（每段开发收尾时由开发方触发，不随 push 自动打半成品包），产物发布到 GitHub Release `app-v<版本>`，App 内在线更新以 Releases 的资产 digest 对账
- **签名**：正式签名密钥通过仓库 secrets 注入；密钥缺失/损坏时工作流**硬失败**，禁止回退 debug 签名

```
ANDROID_KEYSTORE_BASE64      # base64 -w0 release.jks
ANDROID_KEYSTORE_PASSWORD
ANDROID_KEY_ALIAS            # love-space
ANDROID_KEY_PASSWORD
```

- **版本口径**：版本名由 versionCode 推导，不单独计数——`minor = (VC-200) div 10`，`patch = (VC-200) mod 10`（恒一位）。例：VC271 ↔ 2.7.1、VC280 ↔ 2.8.0。改版本只改 `app-flutter/pubspec.yaml` 的 `version:`
- **本地开发**：需要 Flutter 3.47.9 + JDK 17。门禁以全量 `dart analyze` + `flutter test` 为准

```bash
cd app-flutter
flutter pub get --enforce-lockfile   # 必须与 pubspec.lock 同源，禁止静默重解析依赖
dart analyze
flutter test
```

> CI 与本机必须共用 pubspec.lock 的托管源（`PUB_HOSTED_URL=https://pub.flutter-io.cn`）。曾因 CI 未设该变量导致依赖被静默重解析、装机包登录链断裂——lockfile 对不上时应硬失败，不要放行。

## 配置项（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `DATA_DIR` | `/data` | 数据目录（主库 `love.db`、生理期独立库 `period.db`、媒体、备份、密钥），必须持久化 |
| `SETUP_TOKEN` | 空 | 首次远程初始化口令；使用一次性随机值，初始化完成后删除 |
| `SECURE_COOKIES` | `true` | 会话 Cookie 仅通过 HTTPS 发送；生产环境保持开启 |
| `PUBLIC_URL` | 空 | 对外访问地址（如 `https://love.example.com`），用于通知附带的跳转链接与来源校验 |
| `MAX_UPLOAD_MB` | `250` | 单文件上传上限 |
| `LOW_STORAGE_MB` | `1024` | 剩余存储低于该值（MB）时告警 |
| `BACKUP_EXTRA_DIR` | 空 | 额外备份目录（第二块盘/NAS 挂载路径） |
| `BACKUP_PASSWORD` | 空 | 设置后新备份使用 AES-GCM 加密；忘记密码无法恢复 |
| `RUN_WORKER` | `true` | 是否运行内置定时任务（媒体转码、备份、通知投递、保留期清理） |
| `NOTIFY_ALLOWED_PRIVATE_HOSTS` | 空 | 允许通知发往的内网地址白名单（自建 Bark/Webhook 用） |
| `NTFY_SERVER` | `https://ntfy.350921.xyz` | ntfy 推送服务地址；必须为 HTTPS |
| `NTFY_ENABLED` | `0` | 内置 ntfy 系统推送总开关：默认关（通知走 App 前台服务 / 企业微信 / Web Push），`1` 才恢复 ntfy 弹窗 |

### 通知方式说明

- 安卓 App 使用自建前台服务保活 SSE 长连接并弹本地通知，零第三方推送依赖（厂商推送与 FCM 在国内小米机型上均不可行）；系统强行停止 App 后连接中断，重新打开即恢复
- 实际外部触达以**企业微信机器人**为兜底主渠道；App 原生通知不可靠时以它为准
- 网页版可在「通知渠道与提醒偏好」开启浏览器系统推送，它绑定当前浏览器，和 App 是两套设备订阅
- 小米手机需允许恋爱空间自启动、通知与后台运行，并将电池策略设为「无限制」；定位共享另需开电池豁免与「后台高耗电时不限制」

## 云服务器部署

1. **域名与 HTTPS**：将域名解析到服务器，用 Nginx/Caddy 反代到容器 1314 端口并配置证书。
   Caddy 示例（自动 HTTPS）：

   ```
   love.example.com {
       reverse_proxy 127.0.0.1:1314
   }
   ```

2. 设置 `PUBLIC_URL=https://love.example.com`；`SECURE_COOKIES` 默认开启，重启容器。
3. **防火墙**：只放行 80/443；compose 默认双栈监听 1314（公网 IPv6 是 App 的直连加速线路，IPv4 公网由路由器决定是否映射），不做反代时请用防火墙限制来源。
4. **备份**：每日自动备份在 `data/backups/`；可设 `BACKUP_EXTRA_DIR` 异地再存一份。备份包内含 `love.db` 与 `period.db`，恢复时一并还原。注意：备份与数据同机时只能防软件事故，防不了整机/磁盘故障，重要数据请另做异地副本。
5. **升级**：改 `.env` 里的 `LOVE_IMAGE` 到目标版本 tag，`docker compose pull && docker compose down && docker compose up -d`，再用 `/api/status` 的 build 号验真；升级前先确认最新一份备份可用。

## 家庭设备 / NAS 部署

- 会话 Cookie 默认要求 HTTPS；使用 NAS IP 访问时页面会跳转到 `PUBLIC_URL` HTTPS 域名，非 HTTPS 地址不能提交登录和写入请求。
- 数据目录放在 NAS 的共享卷（如 `/vol1/1000/LARJ/data`），随 NAS 的快照/RAID 一起保护。
- **网页录音需要 HTTPS**：局域网下可通过 NAS 自带的反向域名或自签证书 + Tailscale/WireGuard 实现；未满足时页面会提示改用「上传已有音频」。
- **iPhone 网页系统通知**：iOS/iPadOS 16.4 及以上需先将网站添加到主屏幕，再从主屏幕打开并主动开启通知权限。
- 远程访问建议走 Tailscale/VPN，避免直接暴露公网。

聊天 ZIP 导入默认限制压缩文件为 50 MB、解压后总量为 100 MB、单个条目为 30 MB、图片为 2000 张，避免异常压缩包耗尽资源。

## 恢复与迁移

在服务器上执行（`love-space` 为容器名）：

```bash
# 手动完整备份
docker exec love-space python -m app.manage backup

# 恢复 / 迁移到新目录（用于换设备、换服务器）
docker cp love-space:/data/backups/backup-XXXX.zip .
docker run --rm -v /vol1/1000:/target -v $PWD:/src 镜像名 \
    python -m app.manage restore /src/backup-XXXX.zip /target/LARJ-new
# 然后把 compose 的 data 卷指向 LARJ-new，重启即可
```

恢复目标必须是新的空目录；恢复后所有登录会话与待发通知会被安全重置。

## 本地开发

后端 / Web：

```bash
python -m venv .venv && . .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements-dev.txt
uvicorn app.main:app --reload --port 8000
pytest            # 全部测试：API 验收 + 媒体链路 + 安全 + 版本一致性
```

仓库共有三个工作流：`ci.yml`（后端 + Flutter 门禁）、`docker.yml`（镜像二标制推送）、`apk-release.yml`（手动出包）。

### 改前端必须同时改两个版本号（否则用户会拿到「新 JS + 旧 CSS」）

`static/sw.js` 顶部的 `const VERSION` 与 `static/index.html` 里全部 `?v=` **必须同号**。`sw.js` 对 CSS 是 cache-first，版本号脱钩时旧 CSS 缓存会一直被命中，表现为样式莫名错乱，而服务端一切正常。

前端拆成了 5 个 classic script（共享全局作用域，靠 `defer` 保证顺序）：

| 文件 | 职责 |
| --- | --- |
| `static/watch.js` | 一起看放映区 + 进度同步 + 片源四层 |
| `static/chat.js` | 私聊消息流 / 壁纸 / 表情 / 气泡 / 贴纸面板 |
| `static/music.js` | 歌单页与选歌弹窗 |
| `static/period.js` | 生理期日历 / 分析 / 记录表单 |
| `static/app.js` | 其余页面渲染核心 |

⚠️ `watch.js` / `chat.js` / `music.js` / `period.js` **必须排在 `app.js` 之前**（`app.js` 末尾的 `boot()` 会调它们），顺序反了会整页白屏。新增/拆分文件要同步四处：`index.html` 的 `<script>`、`sw.js` 的 `BUNDLES`、部署脚本的 `FILES`、`tests/test_version_consistency.py` 的预热校验。只改后端不用升版本。

### 网页版本号从 git tag 来，不要手改代码

`/api/status` 的 `version` / `build` 是构建期注入的：`LOVE_VERSION` 取最近的 `v*` tag（注意必须 `--match 'v*'`，否则会撞上 APK 的 `app-v*` Release tag 算出错误版本），`LOVE_BUILD` 为短 commit + 日期。发版只需要打 tag：`git tag v2.7.1 && git push --tags`。

### 真机验收

自动测试跑的是干净库，覆盖不到「历史数据渲染、跨页面状态、媒体播放、后台保活」这些分支。发版前照 [`docs/真机验收.md`](docs/真机验收.md) 在真机上走一遍；UI 与交互验收以真机截图为准，不以服务端日志为准。

### 在线片源（一起看）

片源来自一台 Capy 组件聚合器（组件本体遵循 CapyPlayer 规范，**上游没有文档**）。字段归一化、本地整理、契约漂移检测的规则都在 [`docs/片源组件.md`](docs/片源组件.md)，改这块之前先看一眼，别在别处另写一套猜字段。

## 安全与隐私设计

- 未登录无法访问任何 API 与媒体文件；所有媒体经权限校验后流式返回；写接口一律需要 `X-Love-Space: 1` 头
- 鉴权为纯 Cookie（`love_session`，30 天）；实时通道是 SSE（`/api/events`），不是 WebSocket
- Service Worker 仅缓存静态页面资源；登录记录与媒体不支持离线读取，退出时清除本机草稿与推送订阅
- 私密日记/草稿/未公开惊喜：正文以 AES-GCM 加密落库，且不出现在对方的页面、搜索、相册、通知和导出中；生理期数据存独立加密库 `period.db`
- 媒体原文件仍存为普通文件，读取由账号权限控制；完整备份包含解密主密钥，建议配置 `BACKUP_PASSWORD` 并妥善保管恢复密码
- 渠道密钥用 Fernet 加密存储；密码使用 scrypt 哈希；登录/注册有频率限制
- 通知仅发送摘要，不含正文；外发地址强制 HTTPS 与公网校验（防 SSRF）
- 定位数据只存自家 NAS，轨迹点 15 天滚动删除；对方关闭共享时界面明示「已关闭」，不给空白或假故障
- 浏览器推送订阅在数据库中加密保存，VAPID 密钥由 `secret.key` 稳定派生并随完整备份恢复
- 备份文件权限 600；导出仅包含本人有权查看的内容

## 已知约定

- 时区默认北京时间，可在空间设置修改
- 静态资源与 JSON 走 gzip（`app.main.SelectiveGZip`，首屏约省 140KB）；但 `/api/events`（SSE）、`/media/`、`/api/export` 原样直出——压缩 SSE 会把帧攒在缓冲区里让实时推送失效，压缩视频则会让 Range 失效、进度条拖不动
- 纪念日第一版使用公历；iPhone 网页推送需「添加到主屏幕」后使用
- 回收站内容永不自动删除；手动彻底删除仅限作者，且必须先软删进回收站再执行
