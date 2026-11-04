# 恋爱空间

一个**只属于两个人的私密恋爱空间**：发动态、存照片、聊天、写日记、记纪念日、留惊喜。手机体验优先，通过 Docker 自行部署，数据完全自己掌握。

## 功能一览

- **首页** — 恋爱天数、双方今日心情、下个纪念日倒计时、最新动态
- **时光** — 图文/视频/语音动态，点赞评论，支持补记过去、按日期/作者/类型/关键词筛选
- **相册** — 动态照片自动汇总，可建主题相册；删除分类不删照片
- **消息** — 双人即时聊天（文字/图片/语音/视频），断线重连、失败重试、防重复发送
- **我们** — 纪念日（每年重复/提前提醒）、共同愿望清单、每日心情、留言板、情侣问答、共同打卡
- **个人角落** — 私密日记（完全账号隔离）、草稿箱、定时惊喜（到期自动公开）、回收站（30 天）
- **通知中心** — 浏览器系统推送（含 iPhone 主屏幕网页）、Android 原生提醒，以及 SMTP、Bark、Server酱、PushPlus、企业微信机器人、Webhook、Telegram、钉钉、飞书、ntfy；失败自动重试
- **数据保障** — 每日自动备份（保留 7 份）、手动备份、个人数据导出、完整恢复与迁移

## 快速开始（Docker Compose，推荐）

要求：服务器/NAS 已安装 Docker 与 Docker Compose。

运行只需要两个文件：`docker-compose.yml` 和 `.env`——镜像由 GitHub Actions 构建好推到
ghcr，服务器/NAS 上不编译源码（源码、`Dockerfile` 都不用上传）。

```bash
# 1. 建目录，放上仓库根目录的 docker-compose.yml
mkdir -p /vol1/1000/LARJ && cd /vol1/1000/LARJ

# 2. 首次远程初始化时设置一次性随机口令（.env 已被忽略，不会提交）
echo "SETUP_TOKEN=$(openssl rand -hex 32)" >> .env

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

### 用预构建镜像（不本地构建）

镜像由 GitHub Actions 自动构建并推送到 `ghcr.io/gbyyhbot/love-space`，标签规则：

| 标签 | 触发 | 说明 |
| --- | --- | --- |
| `latest` | 打 `v*` tag | **只在正式发版时前进**，永远是"最近一次发布"，不是最新提交 |
| `edge` | push 到 `main` | 跟随 main 最新提交，供尝鲜 |
| `sha-xxxxxxx` | 每次 push | 对应提交短哈希，最精确 |
| `1.2.3` / `1.2` | 打 `v1.2.3` 这样的 tag | 固定版本 |

> ⚠️ 别默认盯 `latest`：它停在最近一次正式发布上，日常改完代码 push 之后
> `latest` **不会**变，拉它到的是旧代码。想要"刚 push 的那次"就用 `sha-<短哈希>` 或 `edge`。

```bash
# 直接拉镜像运行（需要先有 docker-compose.yml 与 .env）
docker compose pull
docker compose up -d

# 想固定到某个版本，改 .env：
echo "LOVE_IMAGE=ghcr.io/gbyyhbot/love-space:sha-2ac50a7" >> .env
```

镜像默认是**私有**的。要么在 GitHub 的包设置里改成 Public，要么先在服务器上登录一次：

```bash
echo "<你的 GitHub PAT，需 read:packages 权限>" | docker login ghcr.io -u <GitHub 用户名> --password-stdin
```

> 国内拉取 `ghcr.io` 常被重置连接（实测 `unexpected EOF`，**不是权限问题**）。
> 更稳的办法是走 ghcr 镜像站，实测 40 秒拉完且 digest 与官方一致：
>
> ```bash
> docker pull ghcr.nju.edu.cn/gbyyhbot/love-space:sha-xxxxxxx   # 南京大学 ghcr 镜像
> ```
>
> 想直连就先重试几次。一直失败的话——有些家宽/NAT 的 IPv6 出口是坏的，而 docker 解析后会
> 优先走 IPv6——就整镜像站拉完再 retag 成规范名（compose 里写的是 `ghcr.io/...`）：
>
> ```bash
> docker pull ghcr.nju.edu.cn/gbyyhbot/love-space:sha-xxxxxxx
> docker tag  ghcr.nju.edu.cn/gbyyhbot/love-space:sha-xxxxxxx ghcr.io/gbyyhbot/love-space:sha-xxxxxxx
> ```

容器默认带了日志轮转（`10m × 3`）和 2G 内存上限，避免长期运行把宿主的
`/var/lib/docker` 撑爆、或视频转码时把整台 NAS 拖垮。内存上限可用 `.env` 覆盖：

```bash
echo "LOVE_MEM_LIMIT=3g" >> .env
```

## Android APK

APK 是 Capacitor 原生壳（远程加载线上站点，所以网页改版不需要重新打包）。工程在 `android-app/`，由 GitHub Actions 自动构建：

| 触发 | 结果 |
| --- | --- |
| 打 `v*` tag | 构建正式包 → 自动发布到 GitHub Release（附 APK，versionName 取自 tag，**versionCode 沿用 `build.gradle`**） |
| 改 `android-app/**` 或手动触发 | 只构建并留 workflow artifact，不发布 |

> **`versionCode` 只能升不能降**。安卓装过 `20261113` 之后，任何更小的包都会被系统拒绝安装，用户看到的现象是「检查更新→下载完成→装不上」。所以发版时只改 `android-app/android/app/build.gradle` 里的 `versionCode`（`versionName` 与 `capacitor.config.json` 的 `LoveSpaceApp/<版本>` UA 必须同号），CI 不再自行按日期推算。
>
> `scripts/check_apk_version.py` 在流水线里拦三次：checkout 后（源配置三处同号 + 不低于站内基线包）、tag 覆盖版本号后、构建产物落地后（`aapt2` 读真实 `versionCode`）。手动跑法：`python scripts/check_apk_version.py [--apk static/lovespace.apk] [--strict]`。

签名密钥通过仓库 secrets 注入，不入库：

```
ANDROID_KEYSTORE_BASE64      # base64 -w0 release.jks
ANDROID_KEYSTORE_PASSWORD
ANDROID_KEY_ALIAS            # love-space
ANDROID_KEY_PASSWORD
```

本地构建（需要 **JDK 21**，Capacitor 7 要求 Java 21；JDK 17 会报「无效源发行版: 21」）：

```bash
cd android-app
npm ci
npx cap sync android          # 生成 assets/capacitor.plugins.json 等
cd android
./gradlew assembleRelease     # 产物：app/build/outputs/apk/release/app-release.apk
```

本地构建需要 `android/keystore.properties`（缺失会自动回落到 debug 签名）与 `android/local.properties`（`sdk.dir`），两者都被 gitignore。

> 换签名后旧包无法覆盖安装，必须先卸载。贴纸包**不要**放回 `assets/stickers`——那会让 APK 从 3.4MB 涨到 43MB，现由服务器 `/static/stickers/` 提供。

## 配置项（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `DATA_DIR` | `/data` | 数据目录（主库 `love.db`、生理期独立库 `period.db`、媒体、备份、密钥），必须持久化 |
| `SETUP_TOKEN` | 空 | 首次远程初始化口令；使用一次性随机值，初始化完成后删除 |
| `SECURE_COOKIES` | `true` | 会话 Cookie 仅通过 HTTPS 发送；生产环境保持开启 |
| `LOVE_BIND_ADDRESS` | `127.0.0.1` | 宿主机监听地址；只允许同机反向代理连接。反向代理在独立容器时使用私有网络或防火墙限制来源，不要直接向公网开放应用端口 |
| `PUBLIC_URL` | 空 | 对外访问地址（如 `https://love.example.com`），用于通知附带的跳转链接与来源校验 |
| `MAX_UPLOAD_MB` | `250` | 单文件上传上限 |
| `LOW_STORAGE_MB` | `1024` | 剩余存储低于该值（MB）时告警 |
| `BACKUP_EXTRA_DIR` | 空 | 额外备份目录（第二块盘/NAS 挂载路径） |
| `BACKUP_PASSWORD` | 空 | 设置后新备份使用 AES-GCM 加密；忘记密码无法恢复 |
| `RUN_WORKER` | `true` | 是否运行内置定时任务（媒体转码、备份、通知投递） |
| `NOTIFY_ALLOWED_PRIVATE_HOSTS` | 空 | 允许通知发往的内网地址白名单（自建 Bark/Webhook 用） |
| `NTFY_SERVER` | `https://ntfy.350921.xyz` | 内置系统推送服务地址；必须为 HTTPS |

### 通知方式说明

- 安卓 APK 使用 ntfy HTTP 持续连接接收提醒，断线后自动重连；不需要 Firebase 项目、服务账号或小米推送资质。
- APK 正常联网时加载线上空间；断网或服务器暂时不可达时，会显示 APK 内置的恢复页，提供本机版本、网络诊断、重试连接和浏览器打开入口。空间页面、记录与媒体仍需联网访问。
- 网页版可在「通知渠道与提醒偏好」开启浏览器系统推送；推送连接由浏览器自身管理，不需要你提供 Firebase 项目或服务账号。它绑定当前浏览器，和 APK 是两套设备订阅。
- 也可配置 Bark、邮件、Server酱、PushPlus、企业微信、Webhook、Telegram、钉钉、飞书或 ntfy。建议同时启用两个独立渠道作为补充。
- 小米手机需允许恋爱空间自启动、通知与后台运行，并将电池策略设为「无限制」。系统强行停止 App 或厂商限制后台网络时，持续连接也可能中断；打开 App 后会恢复连接。


## 云服务器部署

1. **域名与 HTTPS**：将域名解析到服务器，用 Nginx/Caddy 反代到容器 1314 端口并配置证书。
   Caddy 示例（自动 HTTPS）：

   ```
   love.example.com {
       reverse_proxy 127.0.0.1:1314
   }
   ```

2. 设置 `PUBLIC_URL=https://love.example.com`；`SECURE_COOKIES` 默认开启，重启容器。
3. **防火墙**：只放行 80/443；应用端口默认仅监听本机 `127.0.0.1:1314`。若反向代理在独立容器中，请改用私有网络或防火墙规则限制来源。
4. **备份**：每日自动备份在 `data/backups/`，保留 7 份；可设 `BACKUP_EXTRA_DIR` 异地再存一份。
   备份包内含 `love.db` 与 `period.db`（生理期是独立数据库文件），恢复时一并还原。
5. **升级**：改 `.env` 里的 `LOVE_IMAGE` 到目标 tag，然后 `docker compose pull && docker compose up -d`，
   数据目录不受影响。升级前先把 `data/backups/` 里最新的备份确认一遍。

## 家庭设备 / NAS 部署

- 会话 Cookie 默认要求 HTTPS；使用 NAS IP 访问时页面会跳转到 `PUBLIC_URL` HTTPS 域名，非 HTTPS 地址不能提交登录和写入请求。
- 数据目录放在 NAS 的共享卷（如 `/vol1/1000/LARJ/data`），随 NAS 的快照/RAID 一起保护。
- **网页录音需要 HTTPS**：局域网下可通过 NAS 自带的反向域名（如 `*.fnos.club`）或自签证书 + Tailscale/WireGuard 实现；未满足时页面会提示改用「上传已有音频」。
- **iPhone 网页系统通知**：iOS/iPadOS 16.4 及以上需先将网站添加到主屏幕，再从主屏幕打开并主动开启通知权限；不同系统版本和设备策略可能影响送达。
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

```bash
python -m venv .venv && . .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements-dev.txt
uvicorn app.main:app --reload --port 8000
pytest            # 全部测试：API 验收 + 媒体链路 + 安全 + 版本一致性
```

### 改前端必须同时改两个版本号（否则用户会拿到「新 JS + 旧 CSS」）

`static/sw.js` 顶部的 `const VERSION` 与 `static/index.html` 里
`style.css` / `app.js` 的 `?v=` **必须同号**。`sw.js` 对 CSS 是 cache-first，
版本号脱钩时旧 CSS 缓存会一直被命中，表现为样式莫名其妙错乱，而服务端一切正常。

1. `static/sw.js`：`const VERSION = 69;`（`CACHE` 与 `CORE` 都由它拼出，不要再手写）
2. `static/index.html`：两处 `?v=69`

`tests/test_version_consistency.py` 会自动校验这三处；只升一处的话 pytest 会失败。
只改后端不用升版本。

### 网页版本号从 git tag 来，不要手改代码

`/api/status` 的 `version` / `build` 不再是写死在 `main.py` 里的字符串，而是构建期注入：

| 变量 | 来源 | 默认值 |
| --- | --- | --- |
| `LOVE_VERSION` | CI 用 git tag（去掉 `v`）；本地部署脚本用 `git describe` | `dev` |
| `LOVE_BUILD` | 短 commit + 日期，如 `abc1234-20261024` | `local` |
| `LOVE_APK_VERSION` | 手动/CI 指定，要和 `android-app/.../build.gradle` 的 `versionName` 同号 | `1.2.4` |

所以**发版只需要打 tag**：`git tag v1.2.5 && git push --tags`，镜像里的版本号自动变成 1.2.5。
`tests/test_version_config.py` 会校验 `/api/status` 报的 APK 版本与 `build.gradle` 的
`versionName` 一致——不同号的话客户端「检查更新」会一直提示有新版本。

## 安全与隐私设计

- 未登录无法访问任何 API 与媒体文件；所有媒体经权限校验后流式返回
- Service Worker 仅缓存静态页面资源；登录记录与媒体不支持离线读取，退出时清除本机草稿与推送订阅
- 私密日记/草稿/未公开惊喜：正文以 AES-GCM 加密落库，且不出现在对方的页面、搜索、相册、通知和导出中
- 媒体原文件仍存为普通文件，读取由账号权限控制；完整备份包含解密主密钥，建议配置 `BACKUP_PASSWORD` 并妥善保管恢复密码
- 渠道密钥用 Fernet 加密存储；密码使用 scrypt 哈希；登录/注册有频率限制
- 通知仅发送摘要，不含正文；外发地址强制 HTTPS 与公网校验（防 SSRF）
- Android 后台提醒使用独立账号 topic、持久化投递与重试；锁屏仅显示通用提醒
- 浏览器推送订阅在数据库中加密保存，VAPID 密钥由 `secret.key` 稳定派生并随完整备份恢复；外部端点限定为主流浏览器推送服务
- 备份文件权限 600；导出仅包含本人有权查看的内容

## 已知约定

- 时区默认北京时间，可在空间设置修改
- 静态资源与 JSON 走 gzip（`app.main.SelectiveGZip`，首屏约省 140KB）；但
  `/api/events`（SSE）、`/media/`、`/api/export` 原样直出——压缩 SSE 会把帧攒在缓冲区里
  让实时推送失效，压缩视频则会让 Range 失效、进度条拖不动
- 纪念日第一版使用公历；iPhone 网页推送需「添加到主屏幕」后使用
