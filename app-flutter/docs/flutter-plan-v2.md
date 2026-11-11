# love-space 真 APP 化迁移方案 v2（Flutter 双平台，交付 Codex 执行）

> 决策（2026-11-11 确认）：目标平台 **Android + iOS 双平台**，技术路线 **Flutter 单代码库**。
> 本版依据：2026-11-11 对仓库 **HEAD `28cfb798574cc9d149fdc90b5c64273c0c9c8e0d`（sw 297，前端 ?v=297）** 的逐文件实读分析，取代 v1。仓库内另有 `docs/API.md` 与 `docs/capy-contract.json` 可作辅助参考，但若与代码冲突以代码为准。
> **总原则：后端行为零改动。** 仅允许在阶段 0 结论中提出「必须补的后端小接口」清单，经确认再动。

---

## 0. 已核实的现状（写方案的前提，勿推翻）

- 后端：**FastAPI**（`app/main.py` 单文件承载全部路由，无 APIRouter 拆分），uvicorn 端口 **1314**，SQLite 主库 `love.db` + 生理期分库 `period.db`。OpenAPI 文档被关闭（docs_url=None）。
- 数据模型：**统一 records 模型**——17 种 kind（post/diary/draft/surprise/album/anniversary/wish/personal_wish/mood/note/question/habit/chat/quest/ledger/period/music）共用 `GET/POST /api/records`、`GET/PUT/DELETE /api/records/{rid}` 及 like/comments/answer/check/pin/recall/restore 子端点，内容是 body JSON（服务端有字段白名单与校验，错误文案为中文 detail）。period 实际存分库，API 层透明合并，客户端无感。
- 鉴权：**纯 Cookie 会话，无 Bearer 通道**。Cookie 名 `love_session`（token 为 urlsafe 随机串，服务端只存 SHA-256 摘要），**有效期 30 天**，HttpOnly + **SameSite=Strict**，Secure 按协议自适应。账号硬上限 2 人；密码 scrypt 哈希。
- **写请求硬性要求**：所有 POST/PUT/PATCH/DELETE 必须带请求头 **`X-Love-Space: 1`**，缺失直接 403（唯一豁免 `/api/proxy`）。GET 不要求。
- 线路与域名：服务端有 5 条线路（不同域名），可信域名集合在服务端硬编码；非可信 Host 的 http 请求会被 308 跳转/403。线路清单可由公开端点 `GET /api/routes` 获取；`GET /api/status` 公开返回 initialized/paired/版本/apk 信息。**Cookie 按域名隔离**——现有安卓壳靠 MainActivity 的 seedCookie 机制在切线路时人工搬运会话，原生端必须自己解决同样的问题。
- 聊天：消息即 `kind='chat'` 的 record（body 含 content、media[]、sticker、reply_to{id,text}、pinned、location{lat,lng}、song{...}）。发送幂等靠 **`client_id` + 服务端 `UNIQUE(author, client_id)`**（重复提交返回既有记录）。历史用 `before/before_id` 游标分页，首屏 limit=200。
- 实时：**SSE `GET /api/events`**（无 WebSocket 消息通道）。服务端每 5 秒比对 revision 计数器（content/chat/other 三粒度 + 私密按用户），变化时推一行 JSON（含 rev 与 refresh/chat/other 标志），客户端据此增量重拉；连接首行带 `retry: 3000`。
- 媒体：**两段式**——先 `POST /api/media`（multipart 单文件，上限由 `MAX_UPLOAD_MB` 控制，默认 250MB；图片/视频/音频白名单 + 音视频魔数校验）拿 id，再在记录 body.media 里引用（每条上限 30）。展示文件是后端 worker **异步转码**的预览版：图片 `*.preview.jpg`（Pillow，最长边 1600）、视频 `*.preview.mp4`（ffmpeg H.264)+首帧封面、音频 `*.preview.m4a`；`media.status` 为 pending/processing/ready/original，取文件走 `GET /media/{mid}?preview=true|poster=true|download=true`（带 ETag/304）。
- 通知：站内通知走 `/api/notices`(+read)。服务端外发渠道已实现 10 种（smtp/bark/serverchan/pushplus/wecom/webhook/telegram/dingtalk/feishu/ntfy），与客户端无关、不动。**没有 FCM/APNs 注册端点**；浏览器 Web Push 原生端不可用；内置 ntfy topic 由 `/api/me` 下发但**默认关闭**（NTFY_ENABLED=0）。
- 附属功能（别漏盘）：音乐在线搜索/试听 `/api/music/search|stream`（iTunes 30 秒片段）、聊天气泡素材 `/api/bubbles`、贴纸为静态文件 `/static/stickers/<包>/<序号>.webp|webm`、外部聊天记录导入 `/api/imports*`、看板/周报/年刊/日历/那年今日（dashboard/weekly/yearbook/calendar/on-this-day）、导出与备份（export/backups/storage）。`/api/pose-ai/*` 与 `/api/proxy` 是同源托管的姿势图库页专属接口，**不在迁移范围**。
- 现有安卓壳：Capacitor **8**（非 7），UA `LoveSpaceApp/1.7.4`，远程加载；Manifest 现已声明 `adjustResize`，但原生 IME 高度桥 + chat.js 的 90px A/B 分流 + rAF 平滑仍在（原生化后整套不需要）。

---

## 阶段 0：契约确认与缺口清单（先行交付物）

不再从零盘点（本文件 §0 与 §3 已是实读清单），本阶段只做三件事：

1. 对照 §3 清单逐项在测试环境（本地 uvicorn 或现有测试服）用真实账号跑通，记录每个端点的实际响应样例，存 `app-flutter/docs/api-samples/`。
2. **鉴权方案验证**（关键路径，先行）：用 Dart `dio` + CookieJar 做最小实验——登录拿 `love_session`、持久化、重启 App 后免登录、30 天过期处理、多线路切换时的会话搬运策略（建议：固定主线路登录，仅在主线路不可达时按 `/api/routes` 顺序切换并在新域名重新登录/搬运）。结论写入 `app-flutter/docs/auth-plan.md`。
3. **缺口清单**：预期至少包含——①设备推送注册端点缺失（见阶段 5 的决策）；②其余以实测为准。没有书面结论不进入阶段 1。

## 阶段 1：工程脚手架

- 新建 `app-flutter/`，**不动现有 `android-app/` 与 `static/`**，切换完成前 Web/壳照常发布。
- 技术选型定版：状态管理 **Riverpod**；路由 **go_router**；网络 **Dio**（拦截器统一：①注入 `X-Love-Space: 1` 到所有写请求；②Cookie 持久化；③401 时清会话回登录；④错误 detail 中文文案直通 UI）；凭据存储 **flutter_secure_storage**；图片 **cached_network_image**；本地缓存 drift（SQLite）。
- API 基地址做成配置项，来源顺序：内置主线路 → `GET /api/routes` 拉取的清单；禁止把五个域名硬抄进多处。
- 交付物：可编译空壳（登录页 + 主框架 + 主题），Android 真机与 iOS 模拟器各跑通，附截图。

## 阶段 2：页面迁移（按此顺序逐页交付，一页一 PR；功能定义以 Web 端现状为准，不增不减）

1. **账号**：`POST /api/setup`（初始化，含 SETUP_TOKEN 输入）、`/api/login`、`/api/join`（邀请绑定）、`/api/me`、`/api/profile`、`/api/space`、`POST /api/invite`（生成邀请码给对方）。
2. **首页**：`/api/records` 聚合 + `/api/dashboard`——恋爱天数（space.since）、今日心情、下个纪念日倒计时、最新动态。
3. **消息（聊天）**：见 §4 专章。本次迁移的核心收益点，必须按专章验收。
4. **时光**：post 的发布/浏览/点赞/评论（like、comments 子端点），筛选走 records 查询参数（kind/q/author/date/media_type）。
5. **相册**：`/api/photos` + `/api/media/images|videos`，album 记录管理，大图浏览（共享元素转场），多选。
6. **我们**：anniversary（annual 支持公历/农历/lunar、remind_days）、wish、mood、note、question（answer 子端点、双人作答齐了才互见的规则在服务端，客户端按返回渲染）、habit（check 子端点）、quest、ledger、music（歌单 + `/api/music/search|stream` 试听）。
7. **个人角落**：diary/draft/surprise（publish_at 定时）/personal_wish（**必须走专属端点** `/api/personal-wishes` 与 `/{rid}/unlock`，通用 CRUD 会被服务端拒绝）、回收站（`trash=true` + restore）。
8. **生理期**：period 记录走通用 records 接口（服务端自动分库），按 Web 端 period.js 的字段与推算展示实现。
9. **设置与数据**：notices 通知中心、channels 渠道管理（10 种，配置表单按 Web 端字段）、deliveries、webpush 相关端点原生端跳过、export/backups/storage、imports 导入（可降级为仅查看，录入文件选择在原生端实现成本高，取舍在 PR 描述中注明）。

## 阶段 3：聊天与输入区专章（原生实现要点）

- 列表与分页：`GET /api/records?kind=chat&limit=200`，上翻用 before/before_id 游标；本地 drift 缓存最近窗口，冷启动先显缓存再同步。
- 发送状态机（对齐 Web 端语义，原生实现）：待发消息本地落盘（等价于 Web 的 localStorage pending），状态 发送中（三点动效，设计规范见页面优化方案附录 B）→ 成功清除 / 失败标红可重试；**重试复用同一 client_id**，服务端幂等保证不重复。语音/图片/视频：先 `POST /api/media` 拿 id 再发记录；上传进度要可见。
- 实时：SSE 长连接订阅 `/api/events`，按推送中的 chat/other 标志决定重拉范围（chat 变只拉聊天增量）；断线按服务端 `retry: 3000` 起步、指数退避封顶 30s 的策略重连（与 Web 端现有策略一致）；App 进后台时断开 SSE，回前台重连并补拉。
- 消息类型渲染：文本、图片（preview 图，status 非 ready 时占位）、视频（poster 封面 + preview.mp4 播放）、语音（preview.m4a)、贴纸（静态文件 URL)、引用（reply_to 跳转原文）、位置（打开系统地图）、歌曲卡片（song.src 试听）、置顶栏（pin）、撤回态（recall 后 body 标记）。
- 输入区（原生规范，不移植任何 Web 键盘逻辑）：`Scaffold.resizeToAvoidBottomInset` + `MediaQuery.viewInsets` 读取键盘高度；⊕面板/贴纸坞与键盘共用底部同一槽位互斥切换，面板高度取最近一次键盘高度（无记录时屏高 38%），切换防闪烁按 Flutter 常规做法（面板先以键盘高度占位、键盘收起后再显面板）。长按消息菜单（复制/引用/置顶/撤回）按附录 B 规范：原气泡微放大 1.02 + 就近展开。
- 验收：见 §6 矩阵的聊天部分，逐项过。

## 阶段 4：媒体与文件

- 上传：dio multipart 直传 `/api/media`，带进度；大视频（上限 250MB）失败可重试，不做分片（服务端不支持分片，不要自创协议）。
- 展示：列表一律用 preview/poster，原图/原视频仅点开时经 `/media/{mid}` 拉取；`cached_network_image` 需带 Cookie（自定义 HttpClient 或 headers 注入），缓存键含 mid 与 preview 标志。
- 拍摄/选取：image_picker + 录音插件（语音消息）；格式以服务端白名单为准（图 jpg/png/webp/gif/heic、视频 mp4/mov/webm、音频 m4a/mp3/wav/aac/ogg/webm），超限在本地先提示。

## 阶段 5：推送（决策点，实施前确认）

现有后端没有原生推送注册端点，三条路线三选一（PR 描述里写明所选）：

- **A. 零后端改动**：继续用服务端现有渠道（Bark/企业微信/ntfy 等）承担锁屏提醒，App 内靠 SSE + 通知中心。iOS 可用 Bark，Android 可用现有渠道。成本为零，体验够用（现安卓壳在 NTFY_ENABLED=0 时本质也是这条路）。
- **B. 启用内置 ntfy**：服务端开 `NTFY_ENABLED=1`，App 按 `/api/me` 下发的 topic 订阅（安卓可自维护长连接/前台服务，iOS 受后台限制只能靠 ntfy 官方 App 或自建 ntfy 的 APNs 转发，约束要在方案里写清）。
- **C. 后端补一个小端点**：新增设备 token 注册表 + APNs/FCM 发送（属于「后端小接口」例外，走阶段 0 的清单流程经确认后实施）。体验最好，工作量与长期维护（证书、token 失效清理）也最大。
- **默认按 A 实施**，B/C 作为后续迭代，不要在首版混做。

## 阶段 6：发布与切换

- Android：AAB/APK 构建接入 CI（与现有 ghcr 镜像流水线并列，加一个 Flutter job）；自用分发沿用现状（APK 直装 + `/api/status` 式检查更新思路可复用：包内版本号与服务端比对）。
- iOS：**Apple Developer Program（99 美元/年）+ TestFlight** 分发两人使用（免费签名 7 天过期，不可长期用）；证书与描述文件保管方式在脚手架 PR 中注明。
- 切换顺序：一人先装新 App 试用一周 → 聊天页验收矩阵全过 → 两人全量切换；旧 Capacitor 壳与 Web 端保留至少一个发布周期再决定去留。回滚 = 继续用 Web/壳（数据同源，无迁移回滚问题）。

## 附录：接口清单（实读 HEAD 28cfb79，除注明外均需登录 Cookie；写操作另需 X-Love-Space: 1)

- 公开：`GET /health`、`GET /api/status`、`GET /api/routes`、`GET /apk/download`、`POST /api/setup`、`POST /api/login`、`POST /api/join`
- 账号：`POST /api/logout`、`POST /api/invite`、`GET /api/me`、`PUT /api/profile`、`PUT /api/space`
- 记录：`GET/POST /api/records`、`GET/PUT/DELETE /api/records/{rid}`、`POST /api/records/{rid}/restore|recall|pin|like|comments|answer|check`、`DELETE /api/comments/{cid}`、`POST /api/personal-wishes`、`POST /api/personal-wishes/{rid}/unlock`
- 媒体：`POST /api/media`、`GET /media/{mid}`、`GET /api/photos`、`GET /api/media/images`、`GET /api/media/videos`
- 实时与聚合：`GET /api/events`(SSE)、`GET /api/dashboard`、`GET /api/weekly`、`GET /api/yearbook`、`GET /api/calendar`、`GET /api/on-this-day`
- 通知：`GET /api/notices`、`POST/DELETE /api/notices/read`、`GET/POST /api/channels`、`DELETE /api/channels/{cid}`、`POST /api/channels/{cid}/test`、`GET /api/deliveries`、`POST /api/deliveries/{did}/retry`、`POST /api/native-push/test`、`GET /api/webpush`、`PUT /api/webpush/subscription`、`POST /api/webpush/unsubscribe|test`（webpush 组原生端仅 test/native-push 视推送路线取舍）
- 附属：`GET /api/bubbles`、`GET /api/bubbles/{pack}/{name}`、`GET /api/music/search`、`GET /api/music/stream`
- 数据：`GET /api/export`、`/api/export/markdown`、`/api/export/ics`、`POST/GET /api/backups`、`GET /api/backups/{name}`、`GET /api/storage`、`POST /api/imports/preview`、`POST/GET /api/imports`、`GET /api/imports/{iid}/messages`、`DELETE /api/imports/{iid}`
- 不迁移：`/api/pose-ai/config|history`、`POST /api/proxy`（姿势图库页专属）

## 验收矩阵（双平台真机：小米 15 + 一台 iPhone）

- 账号：初始化/登录/邀请绑定全流程；杀掉 App 重开免登录；改密码后旧会话失效
- 聊天：键盘↔面板↔贴纸切换无闪烁无跳变；连发 20 条无重复无丢失；断网发送→失败标记→恢复网络重试成功且不重复；语音/视频/位置/引用/置顶/撤回逐项可用；对方发消息时 SSE 增量到达（前台）
- 媒体：250MB 内大视频上传进度与失败重试；preview 未就绪时的占位与就绪后自动替换
- 通用：弱网（Fast 3G）首屏与列表滚动；Web 端与 App 端同账号交叉使用数据一致
- 每阶段完成定义：功能对齐 + 本矩阵对应项通过 + 不改动后端行为（阶段 0 清单批准项除外）
