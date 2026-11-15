# 后续章 ·「数据管理与通知渠道」迁移清单（2026-11-15 **定案** · 段 A 已落地 2.2.5 / VC225）

> 出处与口径：本轮由三路并行只读调研（A 通知渠道/WebPush、B 导出/备份、C imports/notices/对接点）+ 主理人抽查实读汇编；**结论逐条附 `文件:行号` 或 commit hash，拿不准一律写「未核实」，不许推测**。
> 状态：**2026-11-15 主人已拍板 D1–D10（第四节「决策点定案」），本清单由调研稿转定案**；段 A 已落地并与代码同一 commit 交付（2.2.5 / VC225，门禁与出包证据见附录 A）。B/C/D 段按第五节「分段定案与版本位」固定版本位逐段放行。体例照 `app-flutter/docs/settings-period-plan.md`（调研稿）。
> 调研时基线：HEAD `2dcb4a4`，pubspec `2.2.4+224`（VC224），output 最新包 `lovespace-flutter-v2.2.4+224-20261115.apk`。阶段 2 已全部关闭、iOS 打包搁置（主人本轮）。
> 本段边界：pubspec 改 `2.2.5+225`（VC225）；`app/` / `static/` / `android-app/` 零改动；`chat-final-checklist.md` 保持未跟踪、不纳入本 commit；`flutter-plan-v2.md` 本段不改。

## 一、边界与既有定案（已核实，不再复议）

| # | 定案 | 出处 |
|---|---|---|
| 1 | 本章定名「**数据管理与通知渠道**」（原编号拆出、编号取消不复用）；范围＝notices 通知中心 / channels 渠道管理（10 种）/ deliveries / webpush 原生端跳过 / export·backups·storage / imports 导入 | `flutter-plan-v2.md:49-50`；`settings-period-plan.md:35-38`（D8 定案） |
| 2 | 🔴 条目 8 E 段**已预留 `2.2.5 (VC225)`** 且范围与本章几乎完全一致：「可选（D7 定案，停等主人决定）：通知渠道与提醒偏好 + `period` 提醒事件 + 数据导出 3 链接 + 备份/存储占用（仅 admin）+ imports/notices 若主人决定纳入」；并注明「E 段仍待主人逐段放行，不预做、不留半成品入口」 | `settings-period-plan.md:414`、`:406`、`:26`；`MEMORY.md:67`「提醒卡留 E 段…停等真机验收、不开 E 段」 |
| 3 | 设置侧 D4-c 定案：条目 8 只补「用户天天会碰的外观与连接」，**数据管理/通知渠道留后续章**；S13/S15/S16 均标「定案（D4-c）：留后续章」 | `settings-period-plan.md:390`、`:140`、`:142`、`:143` |
| 4 | D3 定案：沿用后端站内通知，**本段不做提醒 UI**；「通知渠道与提醒偏好」整体留后续章；不做提醒设置、不留半成品入口 | `settings-period-plan.md:389`；`period_page.dart:10` |
| 5 | 「**提醒设置**」hub 卡（Web 设置区块 8 卡第 7 张）条目 8 **未加**，明确「随后续通知章再加，无死卡纪律」 | `together_page.dart:159-161`（**段 A 已改写此注释**）；`settings-period-plan.md:66`、`:1430`（附录 D.1）、`:1533`（D.9） |
| 6 | WebPush 相关端点**原生端跳过**；没有 FCM/APNs 注册端点；内置 ntfy 默认关闭（`NTFY_ENABLED=0`），推送由第三方渠道 + 浏览器 Web Push 承担 | `flutter-plan-v2.md:50`、`:19`、`:89`；`gap-list.md:14`；`main.py:112-121`；`db.py:515-516` |
| 7 | 🔴 既有「明确不做（除非主人改定案）」：**notices 通知中心、imports 聊天记录导入**、「数据恢复」HTTP 端点（后端没有，只有 CLI） | `settings-period-plan.md:416-419`；S20 `:147`、S21 `:148`「建议划出本章」 |
| 8 | 通用纪律：后端零改动；二级页一律 `context.push`、返回按钮+手势必验；已有能力只做跳转不复制 UI；一页一提交、小结后停等核验 | `MEMORY.md:8`、`:56-60`；`settings-period-plan.md:1414-1416` |

> ⚠️ **编号口径冲突（如实留痕）**：`flutter-plan-v2.md:49` 已去旧编号，但 `chat-plan.md:116`、`timeline-plan.md:52-53`、`chat_compose.dart:566` 仍写旧编号。**本轮 D9 定案**：编号口径以本章为准（编号 9 已取消，= 本章）；历史文档与 ⊕ 面板旧编号占位均作为历史留痕保留，本段不批量改、**不改行为**；D9 仅文档层面口径定案（见附录 A.7）。

## 二、Web 逐项盘点 → App 缺口清单

### 2.1 两层结构（别混成一层）

| 层 | Web 位置 | 内容 | App 现状 |
|---|---|---|---|
| **入口层** | 「我们」hub 底部设置区块 8 卡 `app.js:1229`；`settingsPage()` 数据管理卡 `app.js:1481-1482` | 第 7 张「🔔 提醒设置」`data-nav="channels"`；存储摘要条 `data-nav="backups"`（仅 admin）；三个 `<a download>` 导出链接；「完整备份与存储占用」按钮（仅 admin） | hub 调研时 7 张（`together_page.dart:165-223`），**段 A 已补第 8 张**；`/settings` 页（`settings_page.dart:186-196`）只有 4 组缺口卡，**本段按 D7 允许不加数据管理/通知行** |
| **契约层** | `channelsPage()` `app.js:1495-1499`、`backupsPage()` `:1500`、`importsPage()` `:1004-1007`、`noticesPage()` `:1492` | 各页面全条目 + 对应端点 | 调研时 App **全未落地**（`main.dart:55-130` 无 `/channels`、`/backups`、`/notices`、`/imports` 路由）；**段 A 已落地 `/channels` 与 `/notices`** |

### 2.2 Web 逐项契约表（全部条目）

| # | Web 条目 | 行号 | 触发 / 端点 |
|---|---|---|---|
| W1 | 「通知渠道与提醒偏好」（设置页空间设置卡内） | `app.js:1482` | `data-nav="channels"`；同卡附注「通知渠道只影响你自己收到的提醒」 |
| W2 | channelsPage 页头「不错过，每一份在意」+「添加渠道」 | `app.js:1498` | `new-channel` → `app.js:2511` → `channelForm()` |
| W3 | 浏览器系统通知卡（**原生端为空串**） | `app.js:1497` | `enable-webpush`/`disable-webpush`/`test-webpush` → `app.js:2676-2678` |
| W4 | 渠道列表卡（名称/类型/免打扰/订阅事件 + 测试/移除） | `app.js:1498` | `test-channel`/`delete-channel` → `app.js:2673-2674` |
| W5 | 「最近发送记录」+ 刷新 + 失败重试 | `app.js:1498` | `refresh` `app.js:2697`、`retry-delivery` `app.js:2675` |
| W6 | 新增渠道表单（10 种 config 字段 / 12 事件全选默认 / 免打扰 / 间隔） | `app.js:2435-2439` | `POST /api/channels` |
| W7 | 数据管理卡：存储摘要条（仅 admin） | `app.js:1481` | `data-nav="backups"`，`state.storage`、`state.me.user.admin` |
| W8 | 导出我有权查看的记录与原文件 | `app.js:1482` | `<a href="/api/export" download>` |
| W9 | 导出 Markdown 知识库（第二大脑） | `app.js:1482` | `<a href="/api/export/markdown" download>` |
| W10 | 导出日历 .ics（纪念日与计划） | `app.js:1482` | `<a href="/api/export/ics" download>` |
| W11 | 完整备份与存储占用（仅 admin） | `app.js:1482` | `data-nav="backups"` → `backupsPage()` |
| W12 | backupsPage：存储占用三格 + 三类媒体条 + 记录/媒体数 | `app.js:1500` | `GET /api/storage` |
| W13 | backupsPage：「立即备份」+ 备份列表下载 | `app.js:1500` | `backup` `app.js:2696` → `POST /api/backups`；`<a href="/api/backups/{name}" download>` |
| W14 | backupsPage 提示「恢复操作通过服务器命令进行，并恢复到新的空目录」 | `app.js:1500` | **仅说明，无按钮** |
| W15 | importsPage / importDetailPage（导入聊天记录 / 查看 / 搜索 / 记入时光 / 删除） | `app.js:1004-1012`、`:1109-1110`、`:2714-2718` | `/api/imports` 系列 |
| W16 | noticesPage「小小的提醒」/ 全部已读 / 删除已读 / 查看详情 | `app.js:1492`、`:2571-2572`、`:2613` | `/api/notices` 系列；顶栏铃铛 `app.js:325` |

### 2.3 App 已有（**不要重做**，一句一行）

| 能力 | 位置 |
|---|---|
| 独立 `/settings` 二级页（4 组缺口卡 + 已有能力 4 条跳转） | `settings_page.dart:1-5`、`:186-196`、`:660-702` |
| hub 底部「⚙️ 设置」7 张卡（逐张点通、无死卡） | `together_page.dart:159-223`（**段 A 已扩为 8 张**） |
| 检查更新 + 复制 App 下载链接（`apkMirror \|\| '/apk/download'`） | `settings_page.dart:905-1016`；`settings_state.dart:573-582` |
| Dio + CookieJar 基座、`validateAppStatus`、`writeResponseError` 错误通道 | `api_client.dart:279`、`:281-296`、`:332-335` |
| **下载落盘范式**：`getApplicationDocumentsDirectory()/downloads/{mid}{ext}` + `dio.get(responseType: bytes)` + 顶部通知 | `album_viewer_page.dart:265-285`；`image_viewer.dart:64-85` |
| 「先下载后播放」全量 GET 无 Range 范式 | `chat_media.dart:158-189`；`voice_playback.dart:163-188` |
| Clipboard 复制 / `url_launcher` 外链 | `settings_page.dart:1013-1016`；`map_launcher.dart:7/:27/:32` |
| 清聊天未读 `POST /api/notices/read?event=chat` | `chat_state.dart:743/:749` |
| 依赖现状：`path_provider` / `dio` / `url_launcher` / `flutter_cache_manager` 已在；**`share_plus`/`open_file`/`permission_handler` 不在** | `pubspec.yaml:30-70`；B 路 grep 零命中 |

### 2.4 🔴 缺口清单（调研时主体输出；段 A 已勾兑 S1/S2/S3/S4/S11）

| # | Web 条目 | App 现状 | 建议 |
|---|---|---|---|
| S1 | 「提醒设置」hub 卡（8 卡第 7 张） | **段 A 已补**（`together_page.dart`，原 `:159-161` 注释已改写） | ✅ 已落地：`key: settings-hub-remind` → `context.push('/channels')` |
| S2 | `/channels` 页全部（W2–W5） | **段 A 已落地** | ✅ `main.dart` 注册 + `channels_page.dart` |
| S3 | 10 种渠道配置表单 + `validate_config` 口径（W6） | **段 A 已落地** | ✅ 逐字对齐 `app.js:2436` configs；422 原文双呈现 |
| S4 | deliveries 发送记录与重试（W5） | **段 A 已落地** | ✅ 状态文案对齐 `app.js:1498`；失败项重试 |
| S5 | WebPush 4 端点 + 浏览器系统通知卡 | 未落地，**且既有定案原生端跳过** | **不纳入**（D2 定案全跳过，仅留痕 + 一句说明） |
| S6 | `period` 提醒事件订阅 / 提前天数 | **段 A 已落地「只呈现不设置」** | ✅ 12 事件含「生理期提醒」、通知中心呈现后端 period 条目；不做 App 设置（D6） |
| S7 | 导出三链接（W8–W10） | 未落地 | **纳入（段 B）**，承接下载方案见 D3 |
| S8 | 存储摘要 + 完整备份/下载（W7/W11–W13，仅 admin） | 未落地 | **纳入（段 C）**，非 admin 隐藏入口 |
| S9 | 恢复说明文案（W14） | 未落地 | **纳入（段 C）**，只说明不做假入口 |
| S10 | imports 聊天记录导入（W15） | 未落地 | **D1 定案降为可选段 D**（本段不做） |
| S11 | notices 通知中心（W16） | **段 A 已落地** | ✅ `notices_page.dart` + 顶栏铃铛独立角标 |
| S12 | `/settings` 页数据管理 / 通知相关行 | 无（`settings_page.dart` grep 0 命中） | **纳入**，只放跳转入口不复制 UI（D7：本段可不加 `/settings` 行，已按最小改动不加） |

## 三、契约逐条实读（附行号）

### 3.1 通知渠道端点与加密（`/api/channels` 系列）

| 路径 · 方法 | 行号 | 输入 / 输出 | 权限 | 行为 |
|---|---|---|---|---|
| `GET /api/channels` | `main.py:2518-2527` | 输出渠道数组 | `current_user` | `SELECT ... WHERE owner=?`；**逐行 `item.pop('config')` `:2524` 不回传配置**；`events` 反序列化 `:2525` |
| `POST /api/channels` | `main.py:2530-2544` | `ChannelInput` → `{'id':cid}` | `current_user` | `kind ∈ CHANNEL_KINDS` 且 `events ⊆ EVENTS`（否则 422「通知类型不正确」`:2533`）→ `validate_config` `:2536`（ValueError→422）→ `cipher(PURPOSE_CHANNEL_CONFIG).encrypt(dumps(config))` `:2542` 加密入库 |
| `DELETE /api/channels/{cid}` | `main.py:2547-2551` | `{'ok':True}` | `current_user` | `DELETE ... WHERE id=? AND owner=?` |
| `POST /api/channels/{cid}/test` | `main.py:2554-2564` | `{'ok':True}` | `current_user` | 渠道不存在 404「渠道不存在」`:2559`；插 `notices(event='test')` + 一条 deliveries `:2560-2562`；`nudge_worker()` `:2563` |
| `GET /api/deliveries` | `main.py:2567-2572` | 最近 100 条 | `current_user` | JOIN deliveries/channels/notices，`WHERE c.owner=?`，列 `status/attempts/error/sent_at/title/name` |
| `POST /api/deliveries/{did}/retry` | `main.py:2575-2579` | `{'ok':True}` | `current_user` | 仅 `status='failed'` 且渠道属本人 → 重置 pending / attempts=0 / error=NULL |

- `ChannelInput` `main.py:2507-2515`：`kind` / `name`(1–60) / `config:dict` / `events:list[str]`（默认 `['chat','comment','anniversary','surprise']` `:2511`）/ `enabled:true` / `quiet_start:22(0–23)` / `quiet_end:8(0–23)` / `interval:300(0–86400)`。
- `validate_config` **在 `app/notifications.py:24-57`，不在 `security.py`**：required 键表 `:25-28`、config 长度 ≤16000 `:29-30`、wecom/webhook/bark URL 校验 `notifications.py:15-21`（HTTPS、443、禁用户名密码、wecom 须 `qyapi.weixin.qq.com` `:35-38`）、telegram token/chat_id 格式 `:41-43`、dingtalk secret 以 `SEC` 开头 `:44-45`、smtp 端口 ∈{465,587} `:53-57`。
- 加密链：`PURPOSE_CHANNEL_CONFIG = b'love-space:channel-config:v1'` `security.py:36`；`cipher()` `security.py:42-52` = `Fernet(HKDF(SHA256, info=purpose).derive(secret_key()))`，`secret_key()` `security.py:18-27` 读 `DATA/secret.key`；`worker.py:333` `decrypt_with_fallback` 投递时解密；`decrypt_with_fallback()` `security.py:55-65` 兼容存量主密钥密文。🔴 **无 AAD 入参**：显式 AAD 只在 `security.py:104-123` 私密记录加解密，与渠道 config 无关（本轮已核实，见附录 A.6）。
- 🔴 **无 `PUT /api/channels`**：全仓端点仅 GET/POST/DELETE/test → Web 也无「编辑渠道」，只能**删除后重建**；App 不得自创编辑接口（D8 定案）。
- **权限**：上述 6 端点均仅 `current_user`（`security.py:164-171`），**无限流**（A 路复核 `rate_limit` 调用点仅 `main.py:647/667/697/1351/1601/2585/2595/2680/2819/2833`）。

### 3.2 CHANNEL_KINDS 10 种 / EVENTS 12 事件

- `CHANNEL_KINDS` `main.py:2502`：`smtp, bark, serverchan, pushplus, wecom, webhook, telegram, dingtalk, feishu, ntfy`；中文名 `app.js:1493`（邮件 / Bark / Server酱 / PushPlus / 企业微信机器人 / 自定义 Webhook / Telegram / 钉钉机器人 / 飞书机器人 / ntfy）。
- `EVENTS` `main.py:2503-2504`：`chat, comment, note, activity, anniversary, wish, surprise, habit, backup, storage, system, period`（**12 个，末项 period**）；中文名 `app.js:1494`（聊天消息 / 点赞与评论 / 留言 / 新动态与互动 / 纪念日 / 愿望到期 / 惊喜公开 / 共同打卡 / 备份失败 / 空间不足 / 系统消息 / **生理期提醒**）。
- 订阅落地 `db.py:504-524` `notice()`：`:517-520` 每个 webpush 订阅写 `webpush_outbox`；`:521-524` 按 `channels WHERE owner=? AND enabled=1` 且 `event in json.loads(channel['events'])` `:522` 写 deliveries；调度 `worker.py:301-355`（渠道）、`:396-450`（WebPush）、`:596-599`。

### 3.3 WebPush 现状（原生端跳过）

| 端点 | 行号 | 行为 |
|---|---|---|
| `GET /api/webpush` | `main.py:2445-2449` | `{'public_key': webpush_service.public_key(), 'devices': count}` |
| `PUT /api/webpush/subscription` | `main.py:2452-2473` | `validate_subscription`（ValueError→422）→ `endpoint_hash` → `seal_subscription` → 同 endpoint 属他人先删旧 → UPDATE/INSERT |
| `POST /api/webpush/unsubscribe` | `main.py:2476-2483` | 按 `user_id + endpoint_hash` 删 |
| `POST /api/webpush/test` | `main.py:2486-2499` | 无订阅 409「请先在当前设备开启浏览器通知」；插 notices + 每订阅一条 outbox；`nudge_worker()` |

- `app/webpush.py`（107 行）：VAPID 私钥由 `secret.key` 经 HKDF 派生 `webpush.py:22-26`（恢复后订阅仍有效 `:1-3`）；`validate_subscription()` `:58-85` 限制 endpoint 为浏览器厂商 push 服务白名单（防 SSRF `:97-99`）；`send()` `:97-106` 走 `pywebpush`，`vapid_claims['sub']` 取 `config.py:114-121` `public_origin()`（仅 HTTPS `PUBLIC_URL` 才有值，否则占位邮箱）。
- 浏览器端：`app.js:9-13` SW 注册；`:2769` `browserPushSupported()`；`:2771-2781` `enableBrowserPush()`；`:2782-2787` `disableBrowserPush()`；`static/sw.js:27/:38/:49-54` push/showNotification/notificationclick。
- 🔴 **原生端分支**：`channelsPage()` `app.js:1496-1497` `const webpushCard = native ? '' : ...` → 原生端不渲染；`loadSpecial()` `:460-461` 原生端改取 `nativePushBridge().status()`；`app.js:2792` `nativeNotify()`（Capacitor LocalNotifications）；服务端 `POST /api/native-push/test` `main.py:2429-2442`，`ntfy_enabled()` 假 → 503「内置 ntfy 系统推送已停用，通知由第三方渠道与浏览器 Web Push 承担」`:2431-2432`。
- 既有定案「webpush 相关端点原生端跳过」：`flutter-plan-v2.md:50`、`:19`、`:89`、`gap-list.md:14`；`flutter-plan-v2.md:69-74` 阶段 5 路线 A（默认按 A 实施）。**本轮 D2 定案：原生端全跳过、不做假开关。**

### 3.4 `period` 提醒事件完整链路（条目 8 移交本章）

1. 每日 worker：`worker.py:243-252` `due = period.reminder(period.cycle_stats(today), today, int(os.getenv('PERIOD_REMIND_DAYS','2')))` `:246-247` → `db.notice(c,'period',due[0],dedupe=due[1])` `:252`；异常只记日志不拖垮任务 `:248-250`。
2. `period.reminder()` `period.py:342-359`：提前 N 天 `period-soon` / 当天 `period-today` / 推迟 >3 天 `period-late`，返回 `(标题, 去重键)`；`cycle_stats()` `:318-339`（无记录返回 None、有效 gap 15–60 取均值否则 28、`next_start=last_start+cycle`）。
3. `db.notice()` `db.py:504-524` 按 EVENTS 分发到 webpush_outbox / deliveries（见 3.2）。
4. `EVENTS` 含 `period` `main.py:2503-2504`；`eventNames.period` `app.js:1494`；`ChannelInput` 订阅合法性校验 `main.py:2533`。
5. 🔴 `PERIOD_REMIND_DAYS` 全仓命中仅 4 处：`worker.py:247`（**服务端环境变量，默认 2**）、`settings-period-plan.md:389`、`test/period_page_test.dart:720`、`test/period_c_page_test.dart:243`（后两条为反向断言「App 代码不含该串」）。→ **App 侧无提前天数设置可对接**（D6 定案不做）。
6. D3 定案 `settings-period-plan.md:389`「沿用后端站内通知，本段不做提醒 UI；通知渠道与提醒偏好整体留后续章」；P8 `:163`「未落地（随 S13 通知渠道）| 随通知章」。

### 3.5 数据导出三件（🔴 三者口径不一）

| 端点 | 行号 | 响应 / 文件名 | 限流 | period | 无内容 |
|---|---|---|---|---|---|
| `GET /api/export` | `main.py:2582-2589` | `FileResponse` zip `我们的回忆.zip` | `rate_limit('export',10,300)` `:2585` | **含** `backups.py:294-296` `records.extend(period.rows_for(user_id))`；`:300` `records.json` **明文**；`:307-309` 回忆.html 对 period 补 `经期 {start}` | 无空分支，恒生成 |
| `GET /api/export/markdown` | `main.py:2592-2601` | `FileResponse` zip `恋爱空间-第二大脑-{YYYYMMDD}.zip` | `rate_limit('export',10,300)` `:2595`（与 JSON **共用同一 action 桶**） | **含** `markdown_export.py:250-251`；`_render_record` `:139-148` 渲染**明文结构化字段**（开始/经期天数/周期/经量/症状/共享给 TA）；README `:367-370` 明示「这个包是明文的…要加密备份请用 App 内的『完整备份』」 | 无空分支，恒生成 |
| `GET /api/export/ics` | `main.py:2604-2673` | `Response` 文本 `text/calendar; charset=utf-8`，`love-space-{YYYYMMDD}.ics` / `filename*=UTF-8''我们的纪念日-{...}.ics` | **无限流**（函数无 `request`、无 `rate_limit`） | **不含**：`:2612-2615` 只查主库 `SELECT * FROM records` + `serialize_many`；`:2639`/`:2647` 仅 anniversary/wish/quest | `:2667-2668` 404「还没有可导出的纪念日或计划」 |

- 三者均 `current_user`，**无 admin 校验**；`FileResponse` 均带 `BackgroundTask(path.unlink)` 删临时文件 `:2589`/`:2601`。
- 既有定案同口径：`settings-period-plan.md:359-361`、`:356-357`、`:444-446`。
- 🔴 `ENCRYPTED` 记录解密强依赖 `secret.key`（`security.py:18-27`/`:104-123`，AAD 绑 kind+record_id），换错/丢失密钥 → period 记录不可解。

### 3.6 备份与存储（4 端点，全部仅 admin）

| 端点 | 行号 | 权限 / 限流 | 行为 |
|---|---|---|---|
| `POST /api/backups` | `main.py:2676-2690` | `admin` `:2678-2679` 403「完整备份由服务器管理员操作；个人记录可在导出中下载」；`rate_limit('backup',5,300)` `:2680` | `create_backup()` → `{'name':...}`；`BackupRefused` → **503**「服务器未配置备份密码，已拒绝生成明文备份；请联系管理员设置 BACKUP_PASSWORD」`:2684-2685`；其它异常 500 |
| `GET /api/storage` | `main.py:2693-2724` | `admin` `:2696-2697` 403「需要管理员账号」 | 返回 `total/media_by_kind/media_by_month/db/backups/disk_free/disk_total/record_count/media_count`；`:2713-2715` 计入 period.db/-wal；`:2718` `record_count = 主库未删 + period.count_active()` |
| `GET /api/backups` | `main.py:2727-2733` | `admin` `:2729-2730` | 列 `backup-*`，`encrypted = p.suffix=='.enc'` |
| `GET /api/backups/{name}` | `main.py:2736-2743` | `admin` + 文件名正则 `backup-[\w-]+\.zip(\.enc)?` `:2738` | `FileResponse` zip；不匹配/非 admin → 403「无权访问」 |

- `backups.py`：`create_backup()` `:213-284`；**period.db 可选** `:239-249`（老包缺它照常恢复）；`secret.key.enc` `:250-253`（v2 用 `BACKUP_PASSWORD` 二次加密）；`MANIFEST_VERSION=2` `:19-22`；保留最近 **7 份** `:280-281`；`_extract_backup()` `:374-405` v1/v2 required 集合均**不含 period.db** `:381-386`、文件名白名单 `:392-395`、v2 解密 `:401-405`。
- `BackupRefused` fail-closed `backups.py:25-30`、触发 `:215-219`、口令来源 `:33-34` `os.getenv('BACKUP_PASSWORD','')`。
- `backupsPage()` `app.js:1500` 逐项：heading「让回忆，有一个安心的家」+「立即备份」；存储三格（已使用/可用空间/磁盘占用率）+ 三类媒体条；hint 逐字「每天自动备份，保留最近七份成功备份。完整备份包含双方数据与渠道密钥，仅供服务器管理员妥善保管。**恢复操作通过服务器命令进行，并恢复到新的空目录。**」；备份列表 `<a download>`；**全文无恢复/导入按钮**。
- 非 admin 保护：`app.js:463` 注释「非管理员 /api/storage 会 403，所以只在 admin 时才请求」、`:466`「…/api/backups 会 403，别让整页崩掉」；`app.js:1480` `state.me.user.admin` 控制摘要条显隐。

### 3.7 恢复事实（只说明、不做假入口）

| 事实 | 出处 |
|---|---|
| **无 HTTP 恢复端点**：`restore_backup` 定义仅 `backups.py:328`，调用仅 `manage.py:30-31` 与测试；`main.py` 含 backup 的路由只有 POST/GET/GET{name}，含 restore 的只有 `main.py:1443` 记录级回收站恢复（非备份恢复） | B 路全仓 grep；`settings-period-plan.md:355`、`:446` |
| 只有 CLI：`python -m app.manage restore <备份> <目标目录> [--password <密码>]` | `manage.py:5`、`:15-18`、`:29-33` |
| 目标必须是**新的空目录**；恢复后「停止旧服务，将 DATA_DIR 指向该目录后重新启动」 | `backups.py:329-331`；`manage.py:17`、`:33` |
| Web 只说明：`app.js:1500` hint 逐字「恢复操作通过服务器命令进行，并恢复到新的空目录」 | `app.js:1500`；`settings-period-plan.md:101-103` |
| 既有定案「恢复/导入不是设置页条目，别照抄纳入」「明确不做…『数据恢复』HTTP 端点」 | `settings-period-plan.md:101-103`、`:416-419` |

### 3.8 imports 与 notices（逐条实读）

**imports**（`app.js:1004-1012`、`:1109-1110`、`:2714-2718`；`main.py:2817-2942`；`app/importers.py`）

| 端点 | 行号 | 行为 |
|---|---|---|
| `POST /api/imports/preview` | `main.py:2817-2827` | `rate_limit('import',30,300)` `:2819`；解析 + `summarize`；无消息 422「没有解析到聊天记录…」；返回 `summary/title_hint/sample(前5)/media_count` |
| `POST /api/imports` | `main.py:2830-2871` | 同限流 `:2833`；platform ∈ `{'auto','wechat','qq','douyin'}` `:2748`（auto 识别后按微信样式 `:2851-2852`）；媒体 `attached=1` `:2791-2814`；**按空间时区 `Asia/Shanghai` 分日** `:2858-2860`；发 activity 通知 `:2868-2870` |
| `GET /api/imports` | `main.py:2885-2896` | docstring「共享列表：不做 author 过滤，两人看到的是同一份」`:2887` |
| `GET /api/imports/{iid}/messages` | `main.py:2899-2928` | `cursor/direction/limit(1–500)/q/day`；`get_import` 只校验存在不校验归属 `:2874-2882` |
| `DELETE /api/imports/{iid}` | `main.py:2931-2942` | 「谁都能删」`:2933`；消息靠外键级联，图片 `attached=1` 保留 |

- 格式：`importers.py:1-10`（微信 TXT/CSV/ZIP、QQ TXT 含 GBK、抖音 CSV/JSON、通用 JSON 数组）；`MAX_MESSAGES=200_000` `:20`；zip 防 slip `:198-199`；`read_import_file` 50MB 上限 `main.py:2751-2758`。
- Web 入口：`import-chat` `app.js:1006`/`:2715`；🔴 **`data-nav="imports"` 在 `app.js` 全文 0 命中**，与 `chat-plan.md:116` 表述不一致（未核实，见第七节）。**本轮已核实 App 侧无该占位按钮（附录 A.6）。**

**notices**（`app.js:1492`、`:325`、`:2571-2572`、`:2613`；`main.py:1955-1983`）

| 端点 | 行号 | 行为 |
|---|---|---|
| `GET /api/notices` | `main.py:1955-1958` | 最多 200 条、仅本人 `user_id`、created 倒序 |
| `POST /api/notices/read` | `main.py:1961-1972` | `record_id` 单条 / `event` 批量 / 空参数全量；`{'ok':True}` |
| `DELETE /api/notices/read` | `main.py:1975-1983` | 删已读且 `event!='chat'`；`{'ok':True,'deleted':n}` |

- 与聊天未读区分：`app.js:1492` 首行 `filter(n=>n.event!=='chat')` + 空态「聊天消息请在私聊中查看」；顶栏两个独立角标 `app.js:325`（铃铛 `me.unread` / 私聊 `me.chat_unread`）；进聊天清 `POST /api/notices/read?event=chat` `app.js:2915`、`chat-plan.md:11`；删除保护 `main.py:1980` `event!='chat'`。
- `app.js:2571` 全部已读＝空参 `post('/notices/read')`；`:2572` 删除确认逐字「将删除 N 条已读提醒，不会影响未读提醒、动态或聊天记录。」；`:2613` notice-detail 查看时 `post('/notices/read?record_id='+id)`。

### 3.9 App 侧承接下载的现有能力（方案依据，段 B 用）

| 依据 | 位置 |
|---|---|
| `dio.get(..., options: Options(responseType: ResponseType.bytes))` 全量下载 | `api_client.dart:56-63`；`album_viewer_page.dart:272-274`；`image_viewer.dart:65`；`chat_media.dart:179-187` |
| 落盘 `getApplicationDocumentsDirectory()/downloads/`，文件名 `mid+ext`，顶部通知提示路径 | `album_viewer_page.dart:275-285`；`image_viewer.dart:75-84` |
| `Clipboard` 复制链接 + toast「下载链接已复制，可以直接发给对方」 | `settings_page.dart:1013-1016` |
| `url_launcher` 外链（现有仅高德地图用途） | `map_launcher.dart:7/:27/:32`；`pubspec.yaml:64` |
| 依赖缺口：`share_plus`/`open_file`/`permission_handler` **零命中**；`dio.download` 亦零命中（现有均 `dio.get` bytes） | B 路 grep；`pubspec.yaml:30-70` |

## 四、决策点定案（2026-11-15 主人拍板，不再复议）

| # | 决策点 | 背景（行号） | 选项 | **主理人推荐（调研时）** |
|---|---|---|---|---|
| **D1** | **imports / notices 是否纳入本章** | `flutter-plan-v2.md:50` 把两者都列进「后续章」；但 `settings-period-plan.md:416-419`「明确不做（除非主人改定案）」+ S20/S21 `:147-148`「建议划出本章」+ E 行 `:414`「若主人决定纳入」；`chat-plan.md:116` 又写旧编号 | (a) 两者都纳入；(b) 都不纳入；(c) notices 纳入、imports 降为可选段 | **(c)**：notices 纳入段 A（本章名含「通知渠道」、顶栏铃铛需独立角标、端点仅 3 个、体量小）；imports **降为可选段 D**。若主人要严守 `:416-419`，也可两者都划出 |
| **D2** | **WebPush 原生端是否完全跳过** | `flutter-plan-v2.md:50/:19`、`gap-list.md:14` 定案跳过；`main.py:2445-2499` 4 端点齐全；`flutter-plan-v2.md:89` 另有「webpush 组原生端仅 test/native-push 视推送路线取舍」幅度不一（未核实） | (a) 全跳过；(b) 保留 `/api/webpush/test`；(c) 全做 | **(a) 按既有定案全跳过**：浏览器 Push API 原生不可用，App 只做「第三方渠道 + 通知中心」；`nativeNotify` 属阶段 5 路线 A，不在本章自创 |
| **D3** | **导出下载保存到哪 / 分享通道** | 现有 `downloads/` 范式 `album_viewer_page.dart:265-285`；`share_plus`/`open_file`/`permission_handler` 未引入；`pubspec.yaml:30-70` | (a) 复用现有 `downloads/` + 顶部通知；(b) 引 `share_plus` 系统分享；(c) 只复制链接外跳 | **(a)+(c)**：三个导出都走 `dio.get(responseType: bytes)` 落 `downloads/`，复用现有 toast 提示路径；分享用现有 `Clipboard` + `url_launcher`；**不引新依赖** |
| **D4** | **备份/存储仅 admin 的 App 呈现** | `main.py:2678/:2696/:2729/:2738` 四处 admin 403；`app.js:463/:466/:1480` 非 admin 不请求、只显隐；无 `BACKUP_PASSWORD` 503 `:2684-2685` | (a) 非 admin 隐藏入口；(b) 显示但点击报错；(c) 只显示说明 | **(a)**：按 `me.user.admin` 隐藏（对齐 Web），403/503 一律走 `writeResponseError` 服务端 `detail` 原文透传，不吞不改写 |
| **D5** | **恢复的产品呈现** | 无 HTTP 端点、只有 CLI、目标新空目录（`manage.py:29-33`、`backups.py:329-331`）；Web 只有 hint 文案 `app.js:1500` | (a) 只放说明文案；(b) 放按钮但点击提示「请用服务器命令」；(c) 自创入口 | **(a) 只说明、不做假入口**：逐字沿用 Web hint「恢复操作通过服务器命令进行，并恢复到新的空目录」，不设按钮、不自创端点 |
| **D6** | **`period` 提醒要不要 App 侧设置（提前天数）** | `PERIOD_REMIND_DAYS` 是**服务端环境变量** `worker.py:247`（默认 2）；D3 定案 `settings-period-plan.md:389`「沿用后端站内通知，本段不做提醒 UI」 | (a) 不做；(b) 做提前天数输入；(c) 新增后端端点 | **(a) 不做**：App 只在通知中心呈现后端已发的 `period` 事件、在渠道订阅里可勾选「生理期提醒」事件；提前天数要改须动部署环境变量或后端，属「后端零改动」边界外 |
| **D7** | **「提醒设置」hub 卡位置与落点** | Web 8 卡第 7 张 `app.js:1229` → `data-nav="channels"`；App hub 现 7 张 `together_page.dart:165-223` | (a) 补第 8 张卡 → `/channels`；(b) 并入 `/settings` 不设 hub 卡；(c) 两者都要 | **(a)**：补为第 8 张卡（对齐 Web 8 卡、兑现条目 8 的「随后续通知章再加」），点进独立 `/channels` 二级页；`/settings` 页只放一个跳转入口，不复制 UI |
| **D8** | **渠道「编辑」能力** | 🔴 全仓**无 `PUT /api/channels`**；`GET` 列表 `pop('config')` `:2524` 不回传配置；Web 也只能删重建 | (a) 不做编辑；(b) 自创 PUT；(c) 客户端缓存 config 后重建 | **(a) 不做编辑**：与 Web 对齐只提供「新增 / 测试 / 移除」，config 绝不落客户端缓存（敏感凭据）；若主人要编辑须先动后端，属边界外 |
| **D9** | **编号口径同步** | `flutter-plan-v2.md:49` 已去旧编号，但 `chat-plan.md:116`、`timeline-plan.md:52-53`、`chat_compose.dart:566` 仍写旧编号 | (a) 实现段同步改写；(b) 保留历史文本只在本章注明 | **(b)+局部(a)**：历史文档作为留痕不批量改，只在实现段把 `chat_compose.dart:566` 的旧编号占位提示按新定名处理，并在分段表注明「编号已取消」 |
| **D10** | **版本位与分段** | 当前 `2.2.4+224`；E 段预留 `2.2.5 (VC225)` `:414`；主人本轮「终验若有返修包则顺延」 | 见第五节 | 见第五节分段表，**本轮收紧：版本位落定，不再写未定表述** |

### 决策点定案（逐条 · 主人拍板，不再复议）

| # | 定案 | 本轮收紧 / 落地口径 |
|---|---|---|
| **D1** | ✅ **采纳清单推荐 (c)**：notices 纳入本段；imports 降为可选段 D | 段 A 只做 `/notices`，不做 imports；D 段（2.2.8）不预做、不留半成品入口 |
| **D2** | ✅ **采纳清单推荐 (a)**：WebPush 原生端**全跳过** | 🔴 **不做订阅开关、不做「开启本设备通知」假按钮、不调 `/api/webpush*`**；页面只留一句说明「浏览器系统通知仅网页端可用，原生端请使用第三方渠道」，不出现可点但无实现的控件 |
| **D3** | ✅ **采纳清单推荐 (a)+(c)**：导出下载复用 `downloads/`、**不引新依赖** | 段 B（2.2.6）执行；本段不涉及 |
| **D4** | ✅ **采纳清单推荐 (a)**：备份按 admin 隐藏 + 403/503 原文透传 | 段 C（2.2.7）执行；本段不涉及 |
| **D5** | ✅ **采纳清单推荐 (a)**：恢复只说明、不做假入口 | 段 C（2.2.7）执行；本段不涉及 |
| **D6** | ✅ **采纳清单推荐 (a)**：**不做 App 侧提前天数设置** | 🔴 `PERIOD_REMIND_DAYS` 是服务端环境变量 `worker.py:247`；本段只在订阅事件（12 事件含「生理期提醒」）与通知中心呈现后端已发的 `period` 条目，不做设置 UI、不新增端点 |
| **D7** | ✅ **采纳清单推荐 (a)**：hub 补**第 8 张「提醒设置」卡** → `context.push('/channels')` | 位置对齐 Web 8 卡（`app.js:1229`）：**邀请另一半入住之后、全部设置之前**；`/settings` 页只放跳转入口不复制 UI，**本段可不加 `/settings` 行**（已按最小改动不加） |
| **D8** | ✅ **采纳清单推荐 (a)**：**不做渠道编辑** | 🔴 后端无 `PUT /api/channels`、GET 列表 `pop('config')` 不回传；「修改」＝删掉重建，页面文案写清「渠道配置由服务端加密保存，不支持修改；需要调整请删除后重新添加」 |
| **D9** | ✅ **采纳清单推荐 (b)+局部(a)：历史文档与 ⊕ 面板旧编号占位均作为历史留痕，本段不批量改、不改行为；D9 仅文档层面口径定案（编号 9 已取消，= 本章）** | `chat_compose.dart` 本段**零改动**（`_snack('条目 9 迁移后开放')` 占位原样保留、与 `2dcb4a4` 逐字一致）；`settings_d_test.dart` 仅同步 8 卡断言；不触碰条目 6 段 G 的 ⊕ 面板回归面（见附录 A.7） |
| **D10** | ✅ **采纳清单推荐 + 本轮收紧：分段与版本位落定** | 🔴 **A=2.2.5 (VC225)、B=2.2.6、C=2.2.7、D 可选=2.2.8**；**不再保留「返修包顺延」类未定表述，改为定案** |

## 五、分段定案与版本位

> **版本位落定（D10，主人本轮明确）**：调研时 HEAD `2dcb4a4` = `2.2.4+224` (VC224)，条目 8 E 段 `settings-period-plan.md:414` 亦预留 **2.2.5 (VC225)**。主人本轮拍板 **A=2.2.5 (VC225)、B=2.2.6 (VC226)、C=2.2.7 (VC227)、D 可选=2.2.8 (VC228)**，各段绝对版本位固定，**不再顺延、不再写未定表述**。
> 沿用纪律：每段一 commit、一包、全项目 analyze + flutter test 全过、停等真机验收；二级页 `context.push`、返回按钮+手势必验；后端零改动。

| 段 | 版本位（定案） | 内容 | 主要端点 | 依赖决策点 |
|---|---|---|---|---|
| **A** | **段 A 已定案/已落地 · 2.2.5 (VC225)** | **通知中心 + 通知渠道基础**：hub 第 8 张「提醒设置」卡、`/channels` 二级页（渠道列表 / 10 种配置表单 / 12 事件订阅 / 免打扰与间隔 / 测试与移除 / deliveries 发送记录与重试）、`/notices` 通知中心；`period` 事件在订阅列表与通知中心呈现（不做设置）。**已落地，见附录 A** | `/api/channels` 系列 `main.py:2518-2579`、`/api/notices` `:1955-1983`、`/api/deliveries` `:2567-2579` | D1、D2、D6、D7、D8、D9 |
| **B** | **2.2.6 (VC226)** | **数据导出三件**：三个下载入口、全量 bytes 下载落 `downloads/`、复制链接/外链通道、三者文案与口径差异提示（period 只有前两个含）、429/404 原文透传 | `GET /api/export` `:2582`、`/export/markdown` `:2592`、`/export/ics` `:2604` | D3 |
| **C** | **2.2.7 (VC227)** | **备份与存储（仅 admin）**：存储占用卡、`/api/backups` 列表与下载、「立即备份」、503/403 原文透传、**恢复只放说明文案不做入口** | `POST /api/backups` `:2676`、`/api/storage` `:2693`、`GET /api/backups` `:2727`、`/api/backups/{name}` `:2736` | D4、D5 |
| **D** | **2.2.8 (VC228)** | **可选段（D1 定案）**：imports 聊天记录导入「仅查看」（列表/详情/搜索/按日跳转），不做文件选择录入；若主人后续决定不纳入则整段取消 | `/api/imports` 系列 `main.py:2817-2942` | D1 |

**明确不做（除非主人改定案）**：WebPush 4 端点原生端接线（D2）、渠道编辑 PUT（D8）、`period` 提前天数设置（D6）、备份恢复假入口（D5）、新增 `share_plus`/`open_file` 等依赖（D3）、App 已有能力重做（2.3 全表）、后端任何改动。

## 六、风险与坑位备忘

1. 🔴 **渠道 config 敏感**：`GET /api/channels` 主动 `pop('config')` `main.py:2524` 不回传；`POST` 用 `cipher(PURPOSE_CHANNEL_CONFIG)` 加密入库 `:2542`；App 表单提交后**绝不缓存明文凭据**，列表不显示 config；`validate_config` 对 wecom/webhook/bark 有 URL 白名单（HTTPS/443/禁用户名密码）`notifications.py:15-21/:35-40`，前端校验要对齐否则 422。
2. 🔴 **无 `PUT /api/channels`**：Web 也只能删重建，App 别自创编辑；失败重试走「删除+新增」会换 cid，deliveries 历史按旧 cid JOIN 可能不再显示（未核实，见第七节）。
3. 🔴 **三者导出口径不一**：`/api/export` 与 `/markdown` **共用同一 `rate_limit('export',10,300)` 计数桶**（`security.py:194` key=`action:ip`），`/ics` **无限流**；`ics` 无内容 404，另两个恒生成 zip；period 只有前两个含且是**明文**。文案要如实呈现，别写成「三个都含全部数据」。
4. 🔴 **`secret.key` 强依赖**：ENCRYPTED 记录（period 等）解密 AAD 绑 kind+record_id `security.py:104-123`；备份包 `secret.key.enc` v2 用 `BACKUP_PASSWORD` 二次加密 `backups.py:250-253`；换错/丢失密钥 → 记录不可解。导出包本身是**明文**（`markdown_export.py:370`），需在 UI 提示妥善保管。
5. 🔴 **备份包内 `period.db` 是可选非必需**（`backups.py:381-386` required 集合不含）；老包靠启动迁移兜底 `backups.py:358`。
6. 🟡 **`GET /api/storage` 的 `backups_size` 只 `glob('*.zip')`** `main.py:2716`，而 `create_backup` 产物是 `.zip.enc` `backups.py:265-268` —— 两处原文不一致，是否导致加密备份不计入占用**未实跑核实**（第七节）。
7. 🟡 **admin 与非 admin**：四处 admin 403；非 admin 直接进备份页会 403（`app.js:463/:466` 注释已说明），App 需按 `me.user.admin` 隐藏入口，别让整页崩。
8. 🟡 **恢复不可在 App 内完成**：CLI + 新空目录 + 停旧服务切 `DATA_DIR` `manage.py:33`；只说明、不设按钮（D5）。
9. 🟡 **imports 共享语义**：列表不做 author 过滤、谁都能删 `main.py:2887/:2933`；按空间时区分日 `:2858-2860`；50MB / 20 万条上限；`data-nav="imports"` 在 Web 0 命中，入口只有 `import-chat` `app.js:1006`。
10. 🟡 **notices 与聊天未读是两个体系**：`event!='chat'` 过滤 `app.js:1492`、两个独立角标 `app.js:325`、删除保护 `main.py:1980`；别把 `POST /api/notices/read?event=chat`（聊天清未读）当成通知中心「全部已读」。
11. 🟡 **WebPush 原生跳过**与 `flutter-plan-v2.md:89`「仅 test/native-push 视取舍」措辞幅度不一（未核实是否有后续定案覆盖）；`isNativeApp()` 在 `app.js:1363` 与 `:2755` **两处同名定义**，运行时生效者未核实。**本轮 D2 已定案全跳过，历史幅度差异不再影响实现。**
12. 🟡 **下载承接**：现有 `downloads/` 范式用 `dio.get(bytes)` 而非 `dio.download`；中文文件名 `我们的回忆.zip` 的 `FileResponse` 编码行为未实跑核实；`share_plus`/`open_file` 未引入，系统分享/打开文件需新依赖。
13. 🟡 **编号与既有定案冲突**：`:416-419`「明确不做 notices/imports」与 E 行 `:414`「若主人决定纳入」并存；E 行标「D7 定案」而 D7 原文 `:393` 是「数据分析页是否独立可选段」，口径差异未核实。**本轮 D1/D9 已定案覆盖。**

## 七、未核实项清单（**不许推测**，保持开放）

| # | 项 | 状态 / 原因 |
|---|---|---|
| U1 | 本次《数据管理与通知渠道章清单》是否即为 `settings-period-plan.md:414` E 段「停等主人逐段放行」的放行 | **未核实**：`MEMORY.md:67`「停等真机验收、不开 E 段」、`:80`「阶段 2 未收口前不启动」是最近状态；未见明确放行原文（任务前提，非代码事实） |
| U2 | `flutter-plan-v2.md:89`「webpush 组原生端仅 test/native-push 视取舍」vs `:50`/`gap-list.md:14`「跳过」是否有后续定案覆盖 | **未核实**，两份原文均照录于 3.3（本轮 D2 定案全跳过，历史幅度差异不再影响实现） |
| U3 | `app.js` 两处 `isNativeApp()`（`:1363`/`:2755`）运行时哪处生效 | **未核实**（未执行 JS、未做作用域判定） |
| U4 | `showUpdateModal()` `app.js:2845` 内部逻辑 | **未核实**（沿用 `settings-period-plan.md:486` D-1 原标注） |
| U5 | 渠道 config 是否另有 AAD | **已核实（见附录 A.6）**：实读 `security.py:42-52`，`cipher()` 仅 `Fernet(HKDF(SHA256, info=purpose).derive(secret_key()))`，**无 AAD 入参**；用途绑定靠 HKDF `info=purpose` |
| U6 | `period.rows_for / count_active / copy_file / db.visible / serialize_many` 函数体 | **未核实**（B 路仅依据调用点与既有结论） |
| U7 | `encrypt_file / is_encrypted / decrypt_file` 完整实现 | **未核实**（已读 `backups.py:44-50/:53-61/:70` 片段） |
| U8 | `/api/export`、`/export/markdown` 零记录时的实际 zip 产物、`{stamp}` 边界 | **未实跑核实**（代码无空内容分支） |
| U9 | `FileResponse` 中文 `filename` 编码、`.ics` 的 `filename*=UTF-8''` 客户端表现 | **未核实**（未实跑） |
| U10 | `rate_limit('export')` 两处是否真共享计数桶 | **代码推得、未实跑验证** |
| U11 | `GET /api/backups` 的 `p.suffix=='.enc'` 对 `backup-xxx.zip.enc` 取值 | **由 `Path.suffix` 语义推得，未实跑** |
| U12 | `GET /api/storage` `backups_size` 只 glob `*.zip` 与产物 `.zip.enc` 的差异是否导致漏计 | **未实跑核实**（仅如实登记两处原文） |
| U13 | `app-flutter/lib` 是否已有 `/api/export*`、`/api/backups`、`/api/storage` 调用 | **已核实（见附录 A.6）**：全量 grep `app-flutter/lib`，`/api/export*`、`/api/backups`、`/api/storage`、`/api/imports`、`/api/webpush` **零命中**；仅 `chat_state.dart:749` 有 `/api/notices/read?event=chat`；段 A 新增 channels / deliveries / notices 三类端点封装 |
| U14 | `markdown_export.py` 其余渲染逻辑（`:30/:38/:66-79` 等） | **未逐行实读** |
| U15 | **C5**：`/api/imports` 聊天消息内容是否加密存储 | **未核实**（沿用 `settings-period-plan.md:481`）；本轮补原文 `main.py:2864` INSERT、`db.py:132-135` `content TEXT NOT NULL`、`importers.py` 全文均无加密调用，但按纪律**不改 C5 状态、不下结论** |
| U16 | `chat-plan.md:116` 的 `data-nav="imports"` 头部按钮 / App 侧占位 | Web `app.js` **0 命中**；**已核实（见附录 A.6）**：`app-flutter/lib` 全量 grep `imports` **零命中**，App 侧无该占位按钮；Web 侧历史表述仍留痕不批量改 |
| U17 | `api-samples/06-notices.md:15` `?event=all` vs `main.py:1961-1972` 的 event 分支 | 样本采于 2026-11-11 阶段 0，是否同源/曾变更 **未核实**（本段实读服务端仅 `record_id` / `event` / 空参三分支，见附录 A.2） |
| U18 | `settings-period-plan.md:414` E 行标「D7 定案」而 D7 原文 `:393` 是「数据分析页是否独立可选段」 | 是否笔误 **未核实** |
| U19 | `flutter-plan-v2.md:50`「imports 可降级为仅查看…取舍在 PR 描述中注明」的具体取舍 | **已由 D1 定案覆盖（见附录 A.6）**：imports 降为可选段 D（2.2.8），本段不做；历史取舍不再影响实现 |
| U20 | `app.js:1492` 内 `icon(n.event==='chat'?...)` 与首行 `filter(event!=='chat')` 并存是否为历史残留 | **未核实**（仅登记原文） |
| U21 | `app.js:310` toolsSub 不含 notices/imports 而 `:306` navActive 含 | 原因 **未核实** |
| U22 | 删除渠道后重建（cid 变化）对 deliveries 历史 JOIN 的影响 | **未核实**（由「无 PUT」推得的风险，未实跑；本段实读 `main.py:2570-2572` 为 INNER JOIN，见附录 A.2） |
| U23 | `PERIOD_REMIND_DAYS` 是否在 `.env` / `docker-compose.yml` / README 配置 | **已核实（见附录 A.6）**：全仓 grep 命中仅 `app/worker.py:247`（服务端 `os.getenv(...,'2')`）与文档 / 测试 / 记忆文件，`.env`、`docker-compose.yml`、README 均无配置；D6 定案不做 App 设置 |
| U24 | 全量路由枚举确认「除 `main.py:1443` 外是否另有 period/备份恢复专用端点」 | **未核实**（沿用 `settings-period-plan.md:485` 原标注） |
| U25 | `MEMORY.md` 主文件是否存在其它历史版本/副本含旧编号字面 | **未核实**（当前 `:67/:80` 无该字面；合并表述在 `2026-11-14.md:131`） |

---

> **交付说明**：本清单已于 2026-11-15 由主人拍板 D1–D10 **转定案**（不再复议）；段 A 已落地、与代码同一 commit 交付（2.2.5 / VC225，门禁与三行证据见附录 A）。B/C/D 段版本位固定，逐段放行。第七节除 5 项标「已核实（见附录 A）」外，其余 20 项「未核实」保持开放，**不许推测**。
> **停等真机验收；不自宣完成、不开 B 段、不动后端。**

---

## 附录 A · 段 A 落地清单（2.2.5 / VC225 · 与代码同一 commit）

### A.1 改动文件

**本段共 14 个文件**（8 个新增 `A` + 6 个修改 `M`），与 `git diff --name-only 2dcb4a4..HEAD` 逐项一致；D9 回退后 `chat_compose.dart` **不在清单内**。

**新增（8 个 `A` 文件）**

| 文件 | 用途 |
|---|---|
| `lib/features/notify/notify_models.dart` | 10 种渠道中文名 / 12 事件中文名 / 发送状态映射 / config 字段表（逐字对齐 `app.js:2436`）/ 三个模型 / 纯函数（提交体、事件中文名、时间、免打扰） |
| `lib/features/notify/notify_api.dart` | 3 个 GET + **6 个写方法统一 `_write` → `api.writeResponseError`** |
| `lib/features/notify/notify_widgets.dart` | 内联错误区（双呈现之一）/ 说明卡 / 空态卡 |
| `lib/features/notify/channels_page.dart` | `/channels` 页 + 新建表单（页内展开、**凭据即弃**） |
| `lib/features/notify/notices_page.dart` | `/notices` 页（首行过滤 chat / 三个动作 / 角标服务端联动） |
| `lib/features/notify/system_unread_provider.dart` | 铃铛角标 `me.unread`（与 `chatUnreadProvider` 严格区分；>99 显 99+） |
| `test/notify_a_test.dart` | 段 A 契约 + widget 测试（含两页返回两条独立路径；D9 护栏断言含与 `2dcb4a4` git blob **全文逐字比对**） |
| `docs/data-notification-plan.md` | 调研稿转定案（D1–D10 + 分段定案 + 附录 A），随本段同一 commit 纳入版本控制 |

**修改（6 个 `M` 文件）**

| 文件 | 改动 |
|---|---|
| `pubspec.yaml` | `2.2.4+224` → `2.2.5+225`（VC225）；**不引新依赖** |
| `lib/main.dart` | 注册 `/channels` → `ChannelsPage`、`/notices` → `NoticesPage`（`GoRoute`，与既有二级页同构） |
| `lib/features/together/together_page.dart` | 改写 `:159-161` 「不加提醒设置卡」注释；补第 8 张「🔔 提醒设置」卡（`key: settings-hub-remind`、desc「通知渠道与提醒偏好」、`context.push('/channels')`），位置＝邀请另一半入住之后、全部设置之前 |
| `lib/features/shell/shell_page.dart` | AppBar `actions` 在私聊**之前**加铃铛（`tooltip:'通知'`、`Icons.notifications_none_rounded`、`Badge(systemUnread)`、`context.push('/notices')`） |
| `lib/features/auth/auth_state.dart` | `_bootstrap` 播种 `systemUnreadProvider ← me.unread`（`main.py:723`），与 `chatUnreadProvider ← me.chat_unread` 并列 |
| `test/settings_d_test.dart` | 7 卡断言 → **8 卡断言**：新增 `/channels` 占位路由、`settings-hub-remind` 用例与「提醒设置」文本断言 |

**零改动**：`app/` / `static/` / `android-app/`；**`lib/features/chat/chat_compose.dart`（D9：旧编号占位作为历史留痕保留、与基线 `2dcb4a4` 逐字一致，本段不改行为；widget 护栏有全文比对实证）**；`lib/features/settings/settings_page.dart`（D7 允许本段不加 `/settings` 行）；`app-flutter/docs/flutter-plan-v2.md`；`chat-final-checklist.md` 保持未跟踪、**未 `git add`**。

### A.2 关键契约自查

- **列表只呈现服务端字段**：`GET /api/channels` 逐行 `pop('config')`（`main.py:2524`）→ `ChannelItem` **无 config 字段**；列表显示中文类型 / name / enabled / 「服务端已保存配置」/ `events` 中文名 / 免打扰 / 间隔；**不展示、不回填任何凭据**。
- **新建提交体**：`{kind,name,config,events,quiet_start,quiet_end,interval,enabled:true}` 对齐 `app.js:2437`；10 种 config 字段逐项对齐 `app.js:2436`，`port` 默认 `'465'`，`bark.url`/`webhook.token` 非必填（`app.js:2438`）；字段标签逐字对齐 Web。
- **订阅语义**：12 事件 checkbox 默认全选（`app.js:2437`）；**无独立订阅开关、无 PUT、无本地缓存**；POST 后重拉 `GET /api/channels` 确认 `events` 落库；杀进程重开仍从服务端取，不本地记订阅态。
- **`validate_config` 原文双呈现**：`notifications.py:24-57` 的 422（required 缺失「请填写完整的渠道配置」/ kind·events 非法「通知类型不正确」）经顶部 `chatToastProvider(error)` + 表单 `NotifyErrorBanner` 内联区同时呈现；失败不假成功、输入保留、不 pop、不重试、不改列表。
- **测试 / 删除 / 重试**：测试 404「渠道不存在」原文透传；成功提示「测试已加入发送队列，请刷新发送记录」；删除弹层可取消，成功后重拉确认消失；发送记录状态文案对齐 `app.js:1498`，失败项重试走 `POST /api/deliveries/{did}/retry`。
- **通知中心**：`GET /api/notices` 内容只来自服务端；首行 `event!='chat'` 过滤；空态「还没有新的提醒…聊天消息请在私聊中查看」；`POST /api/notices/read` 空参＝全部已读、`?record_id=`＝单条已读（`app.js:2613`）；`DELETE` 删前确认逐字「将删除 N 条已读提醒，不会影响未读提醒、动态或聊天记录。」；**不做本地通知生成 / 免打扰设置 / 推送开关**。
- **角标联动**：`/api/me` 的 `unread`（`main.py:723`）→ 铃铛；`chat_unread` → 私聊；进页 / 写成功后 `authProvider.reload()` 重拉 me，以服务端为准，不本地推算。
- **WebPush / 编辑 / 提前天数**：不调 `/api/webpush*`、无「开启本设备通知」控件；无编辑 UI / 无「修改」按钮；`lib` 内 `PERIOD_REMIND_DAYS` 零命中（D6）。
- **两页返回**：`AppBar.automaticallyImplyLeading` 不关；widget 用例对 `/channels` 与 `/notices` 各走「返回按钮」「系统返回手势 `handlePopRoute`」两条独立路径。

### A.3 验收点 ①–⑤ 逐项自查

| 验收点 | 本段自查结论 |
|---|---|
| ① 建渠道（Bark/Webhook）→ 点测试 → 真机收到测试消息；删掉后列表消失、重拉不复活 | 代码路径齐备（新建→测试→删除确认→重拉）；**「真机收到测试消息」需真机验收**，本段用夹具验证 POST/test/DELETE 与重拉消失（见 `test/notify_a_test.dart`）。**待真机** |
| ② 订阅事件切换两项（按 Web 语义＝新建时勾选不同 events）→ 杀进程重开仍是切换后状态；重拉 GET 确认 `events` 落库 | ✅ widget 用例：新建时取消 `chat`/`comment` 两个 checkbox → POST body events 校验 → POST 后重拉 GET → 全新 `ProviderContainer`（模拟杀进程重开）仍显示切换后订阅；不本地缓存 |
| ③ 通知中心能看到 `period` 提醒与活动通知的历史条目 | ✅ 夹具含 `event:'period'`（生理期提醒）与 `event:'activity'`（新动态与互动）及 `chat`；断言渲染前两条、过滤 chat、只呈现服务端 title/event/时间 |
| ④ 故意建配置不全的渠道 → `validate_config` 报错原文双呈现、不假成功 | ✅ widget 用例：故意不填 `bark.key` → 422「请填写完整的渠道配置」同时出现在顶部通知与表单内联错误区；断言不落库、不 pop、输入保留、只发 1 次请求、无成功通知 |
| ⑤ hub「提醒设置」卡、AppBar 铃铛两入口都落对页面，返回按钮 + 手势可回 | ✅ hub 第 8 卡 `settings-hub-remind` → `/channels`（`settings_d_test.dart` 8 卡用例逐张点通）；铃铛 → `/notices`（源码断言 + 角标字段区分测试）；两页返回按钮 + 系统手势各两条独立路径 |

### A.4 错误通道覆盖的写方法（6 个，全部经 `NotifyApi._write`）

| # | 写方法 | 端点 | 4xx 原文来源 |
|---|---|---|---|
| 1 | `createChannel` | `POST /api/channels` | `validate_config` 422 / kind·events 非法 422「通知类型不正确」 |
| 2 | `deleteChannel` | `DELETE /api/channels/{cid}` | 服务端 `detail`（如 403） |
| 3 | `testChannel` | `POST /api/channels/{cid}/test` | 404「渠道不存在」 |
| 4 | `retryDelivery` | `POST /api/deliveries/{did}/retry` | 服务端 `detail`（如 429） |
| 5 | `markNoticesRead` | `POST /api/notices/read` | 服务端 `detail`（如 422） |
| 6 | `deleteReadNotices` | `DELETE /api/notices/read` | 服务端 `detail`（如 403） |

- `api_client.dart:279` `validateAppStatus(s)=s!=null && s<500` 放行 4xx；`_write` 统一 `api.writeResponseError(r)`（`api_client.dart:332-335`），2xx→null、4xx→`responseDetail(data)` 原文、抛出的异常→`api.errorDetail`。测试逐一断言 6 个方法 4xx 原文、2xx 返回 null、5xx 兜底。
- 失败一律：**不发成功通知、不 pop、输入保留、不自动重试、不本地改动列表**（删/建/测试失败后列表保持原状；成功才重拉）。写路径 `X-Love-Space:1` 由 dio 拦截器注入（`api_client.dart:291-298`），封装内不重复加头。

### A.5 凭据落点核查结论（grep 逐处说明）

对 `app-flutter/lib` 全量 grep 凭据字段名（`token` / `key` / `secret` / `password` / `chat_id` / `url` / `Bearer`），逐处用途：

| 出现位置 | 用途 | 是否留存凭据 |
|---|---|---|
| `notify_models.dart` `channelConfigs` 里 `key: 'token' / 'key' / 'secret' / 'password' / 'chat_id' / 'url'` 及标签字符串 | **只是 `POST /api/channels` 请求体 `config` 的键名与表单标签**（逐字对齐 `app.js:2436`），不是凭据值 | 否 |
| `notify_models.dart` `ChannelFieldType { text, number, password, email, url }` | 输入类型枚举（决定 `obscureText` / 键盘类型），非数据 | 否 |
| `notify_models.dart` `buildChannelConfig` / `buildChannelPayload` | 构造一次性 `config` 快照与 POST 请求体；函数返回后由调用方丢弃 | 否（仅请求体） |
| `channels_page.dart` `_ChannelForm._configControllers` | 表单局部 `TextEditingController` **临时输入缓冲**：只在表单 State 生命周期内存在；切换渠道类型即 dispose 重建；提交成功立即 `clear()` 并随表单 dispose；失败按纪律保留输入（不落盘） | 否（不跨页面/进程） |
| `channels_page.dart` `_submitChannel(Map payload)` | payload 通过参数一次性传给 `NotifyApi.createChannel` → `dio.post(data: payload)`；之后不再引用 | 否 |
| `channels_page.dart` `_ChannelFormState._submit` 的 `values` / `config` 局部变量 | 一次性快照，出作用域即弃；不写入任何 `state` / `provider` / 缓存字段 | 否 |
| `channels_page.dart` 凭据红线文档注释 | 说明性文字，非数据 | 否 |
| `auth_state.dart` 既有 `password` / `token` / `old_password` / `new_password` / 邀请 `token` | **账号登录/改密/邀请既有逻辑**（本段未改），与本段渠道凭据无关；其 `token` 是会话/邀请令牌，走既有 secure_storage 正本 | 既有能力，非本段新增 |

**结论**：`lib/features/notify/*` 内 `SharedPreferences` / `FlutterSecureStorage` / `storeSessionToken` / `writeAsString` / `File(` / `print(` / `debugPrint(` **零命中**（`test/notify_a_test.dart` 有源码级护栏断言）；`ChannelItem` 模型无 `config` 字段；列表页不展示、不回填明文；凭据只在 `POST /api/channels` 请求体里过一遍，与个人心愿密码同级红线。

### A.6 第七节「已核实」项的实读证据

| U 项 | 本段实读证据 |
|---|---|
| U5 | `app/security.py:42-52` `cipher(purpose=None)`：无 `purpose` → `Fernet(secret_key())`；有 `purpose` → `Fernet(base64.urlsafe_b64encode(HKDF(SHA256, info=purpose).derive(secret_key())))`。**无 AAD 入参**；显式 AAD 只在 `security.py:104-123` 私密记录加解密 |
| U13 | 全量 grep `app-flutter/lib`：`/api/export*`、`/api/backups`、`/api/storage`、`/api/imports`、`/api/webpush` 零命中；仅 `chat_state.dart:749` 的 `/api/notices/read?event=chat`。段 A 新增 `/api/channels` 系列、`/api/deliveries`、`/api/notices` 封装 |
| U16 | 全量 grep `app-flutter/lib` 的 `imports` 字面：**零命中**，App 侧无 `data-nav="imports"` 占位按钮 |
| U19 | D1 定案（第四节）：imports 降为可选段 D（2.2.8），本段不做；历史取舍不再影响实现 |
| U23 | 全仓 grep `PERIOD_REMIND_DAYS`：命中 `app/worker.py:247`（`os.getenv('PERIOD_REMIND_DAYS','2')`）、`settings-period-plan.md:389`、`test/period_page_test.dart:720`、`test/period_c_page_test.dart:243`、本清单与 `.workbuddy/memory/*`；`.env` / `docker-compose.yml` / README 均无配置 |

**本段实读但未解决 / 未实跑，一律保留「未核实」**：U17（服务端 `main.py:1961-1972` 实读为 `record_id` / `event` / 空参三分支，样本 `?event=all` 历史变更未核实）、U20（`app.js:1492` 实读 icon 分支与首行 filter 并存，是否历史残留未核实）、U22（`main.py:2570-2572` 实读为 `INNER JOIN`，删除重建后 deliveries 历史真机表现未实跑）、U24（未做全量路由枚举）、其余各项均保持原状态。

### A.7 已知偏差与待办

- **D7 `/settings` 行**：主人明确「本段可不加 `/settings` 行」，本段按最小改动**未加**；若后续要放数据管理跳转入口，按「只放跳转、不复制 UI」处理。
- **D9 已按最小变更处理**：主理人裁定 ⊕ 面板属条目 6 段 G 回归面，D9 仅为**文档层面口径定案**（编号 9 已取消、= 本章）；`chat_compose.dart` 本段**零改动**（`_snack('条目 9 迁移后开放')` 占位原样保留、与 `2dcb4a4` 逐字一致，见 `git diff 2dcb4a4..HEAD -- <path>` 为空），`settings_d_test.dart` 仅同步 8 卡断言；不改行为、不扩大改动面。
- **notice-detail 详情**：Web `app.js:2613` 会 `api('/records/'+id)` 弹 `recordCard`；App 本段按最小实现，弹层只呈现服务端 notice 自身字段（title / event 中文名 / 时间），未接 `GET /api/records/{rid}`；查看时按契约发 `POST /api/notices/read?record_id=`。
- **事件订阅顺序**：`eventNames` 按 `app.js:1494` 对象键顺序照录（`period` 在 `anniversary` 之后），与 `main.py:2503-2504` 集合列举顺序（period 末项）不同；提交顺序按 Web `Object.keys(eventNames)`，中文名逐字一致，落库内容不受影响。
- **停等真机验收**：验收点 ① 的「真机收到测试消息」、角标真机联动、长按/滚动体感均需真机；本段**不自宣完成、不开 B 段、不动后端**。

### A.8 门禁实测输出与出包三行证据（2026-11-15 · D9 回退后最终版）

- 跑前 `unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy`（本机代理会劫持 flutter_tester 本地 WebSocket）。
- **`flutter analyze`（不带 lib 参数）**：`No issues found!`（16.8–16.9s，多轮复核），exit `0`。
- **`flutter test`（全量）**：`+609: All tests passed!`，exit `0`（含本段 `test/notify_a_test.dart` **37** 个契约/widget 用例与 `test/settings_d_test.dart` 8 卡用例；D9 护栏断言同步后**加强**＝占位留痕正向断言 + 无真跳转断言 + 与 `2dcb4a4` git blob **全文逐字比对**，用例规模未下降）。
- **出包**：`flutter build apk --release --split-per-abi --target-platform android-arm64` → `√ Built build\app\outputs\flutter-apk\app-arm64-v8a-release.apk (24.2MB)`，exit `0`（Gradle `assembleRelease` 259.8s）。
- 🔴 **D9 回退 → 重出包**：`chat_compose.dart` 回退到 `2dcb4a4` 后 lib 代码变化，**首版包 sha1 `89411ab4e4e85ac73786c9ce97a0a2f48e17d2be` 作废**，以下为覆盖重出后的最终包证据（文档 A.8 不进 APK，包与最终 commit 的 `lib/` 代码一致）。

**三行证据**

1. ① 绝对路径 `D:\Dev\love-space\output\lovespace-flutter-v2.2.5+225-20261115.apk`，**25,384,387 字节**（18:32 覆盖落盘）；构建产物 `app-arm64-v8a-release.apk` 与交付包 sha1 同为 `a03f68ee4cb6405b9ade8756ee243006943d61f2`。
2. ② `/c/Android/build-tools/35.0.0/aapt.exe dump badging`：`package: name='cn.iepose.lovespace.love_space' versionCode='2225' versionName='2.2.5' platformBuildVersionName='16' platformBuildVersionCode='36' compileSdkVersion='36'`（arm64 split 自动 `+2000`：`+225` → `2225`，单调高于 `2224` 可覆盖装）；`aapt2.exe dump badging` 同号复核。
3. ③ `ls -la /d/Dev/love-space/output/`：交付包在列（现 2.0.8 ~ 2.2.5 共 16 个版本包 + 既有素材）。

**sha1 比对**：最终包 `a03f68ee4cb6405b9ade8756ee243006943d61f2` ≠ 2.2.4 包 `d13f427894a774eac9d7ef554dba3d54f774257e` ✓，且 ≠ D9 回退前作废包 `89411ab4e4e85ac73786c9ce97a0a2f48e17d2be` ✓。
**`lib/arm64-v8a/libapp.so` 换包核验**：最终包 `d7b99123b3e78145b448b5d4ad6d422baab89f04` ≠ 2.2.4 包 `78b3bb0dc937d76becadbcdeb36dde651548a824` ✓，且 ≠ 作废包 `2c43248b31ba336a412bae8997b901b1931bbd8e` ✓（AOT 快照确实重编）。
**边界**：`app/` / `static/` / `android-app/` 零改动；`chat-final-checklist.md` 保持未跟踪、未 `git add`；一次性脚本 / 诊断日志用完即删；`output/` 版本包保留。
