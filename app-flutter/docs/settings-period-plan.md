# 条目 8 ·「设置缺口 + 生理期」迁移清单（2026-11-14 定案）

> 出处：Web `static/app.js` `settingsPage()` L1474-1483、`static/period.js` 全文 834 行；
> 后端 `app/period.py` / `db.py` / `main.py` / `backups.py` / `markdown_export.py` /
> `config.py` / `serializers.py` / `security.py` / `worker.py` / `manage.py` 实读，行号随文。
> 本清单原为架构师（后端契约）与工程师（Web 前端 + App 现状）**并行只读调研**、
> 主理人汇编的调研稿；**2026-11-14 主人拍板 D1–D8 全部采纳清单推荐，本稿转定案**。
> 段 **8-A（生理期地基 + 入口 + 读写 + 推算引擎）已随 2.2.1 / VC221 落地**：
> 一 commit、全项目 `dart analyze` / `flutter test` 全绿、后端 `app/` / `static/` /
> `android-app/` 零改动；对拍结论见**附录 A**，C4 就此关闭（见第七节）。
> 纪律：结论全部实读核实并附行号；未核实项见第七节，不作推测。
> 版本位自 **2.2.1 (VC221)** 起顺延。本章只补缺口，**不重做 App 已有部分**。
> 后续段（B/C/D/E）仍按第五节分段表停等主人逐段放行，**本段不预做、不留半成品入口**。
> 体例沿用 `app-flutter/docs/together-plan.md`（调研稿）与 `personal-corner-plan.md`（契约逐条实读）。

---

## 一、边界与既有定案（主人已定，不再复议）

- 🔴 **条目 7 已全部关闭**（主人 2026-11-14）；条目 8 **段 8-A 已随 2.2.1/VC221 落地**（对拍见附录 A），后续段停等主人逐段放行。
- 🔴 **设置区块 8 卡全归条目 8**；**生理期入口卡随条目 8 上，条目 6 hub 不放**
  —— `together-plan.md:51`、决策点⑥ `:66`、`:85-86`。
- 🔴 Web「我们」页底部「设置」区块 **8 卡**：空间信息 / 主题与外观 / 主页背景 /
  聊天背景 / 聊天气泡 / 邀请另一半 / 提醒设置 / 全部设置 —— `together-plan.md:15-16`、
  `app.js:1229`。
- 🔴 **壁纸/背景归设置**（账号页时已定，`together-plan.md:50`）；hub 不做背景类入口。
- 🔴 本章范围：设置**缺口** + 生理期本体 + 入口卡。App 已有账号资料页、聊天背景、
  聊天气泡、空间信息（首页）、回收站通用 restore —— **不重做**。
- ✅ **条目编号已定案（D8，主人 2026-11-14 拍板）**：`flutter-plan-v2.md:49` 改为
  「8. 设置缺口 + 生理期」；原 `:50`「9. 设置与数据 …」去掉编号 9、改写为**后续章
  「数据管理与通知渠道」**（端点说明保留，注明归后续章），与 `together-plan.md:51/:85`
  「设置区块 8 卡全归条目 8」不再冲突。本章统一口径「条目 8 = 设置缺口 + 生理期」。

---

## 二、设置部分：Web 逐项盘点 → App 缺口清单

### 2.1 两层结构（别混成一层）

| 层 | 位置 | 行号 | App 现状 |
|---|---|---|---|
| **入口层** | Web「我们」hub 底部设置区（8 卡）+ 账号菜单「⚙️ 设置」 | `app.js:1229`、`app.js:325`；`together-plan.md:15-16` | **均未落地**：`together_page.dart:61-137` 无设置区；无 `/settings` 路由 |
| **契约层** | `settingsPage()` 页内 6 组卡片 | `app.js:1474-1483`（**全部 UI 在 `:1482` 一行 return**） | **未落地**：`main.dart:51-130` 无该路由，lib 下无 settings 页 |

渲染链：`renderPage()` `app.js:334` → `pages` 映射 `app.js:335`（含 `settings:settingsPage`）
→ `app.js:336` 写入 `#page`；`#page` 由 `renderShell()` `app.js:325` 动态生成，
`index.html:20-22` 只有 `#app`/`#modal-root`/`#toast`，**无设置页专用 DOM**。

**入口层 8 卡逐项实读**（全部在 `app.js:1229` 同一超长行的 `settings-tools` div 内，
分组标题 `settings-section-heading` 为「⚙️ 设置」；名单亦见 `together-plan.md:15-16`）：

| # | Web UI 文案（`app.js:1229`） | 触发 | App hub 卡 | 功能在 App 别处 |
|---|---|---|---|---|
| 1 | 🏡 空间信息「空间名称与相恋日期」 | `data-action="space"` | **无** | **已有、不要重做** `home_page.dart:248-300` → `api_client.dart:162-169` |
| 2 | 🎨 主题与外观「主题色、夜间模式与动效」 | `data-action="theme-form"` | **无** | **未落地**（仅 `main.dart:143-154` `ThemeMode.system`） |
| 3 | 🖼️ 主页背景「换一张首页封面照片」 | `data-action="home-bg"` | **无** | **未落地** |
| 4 | 🌄 聊天背景「聊天壁纸与文字对比度」 | `data-action="chat-bg"` | **无** | **已有、不要重做** `wallpaper_sheet.dart:21/:131/:137`、`chat_wallpaper.dart:56`，入口 `messages_page.dart:319-323` |
| 5 | 💬 聊天气泡「两千多款气泡皮肤随手挑」 | `data-action="chat-bubble"` | **无** | **已有、不要重做** `bubble_skin_sheet.dart:22/:122`、`chat_bubbles.dart:45`，入口 `messages_page.dart:314-318` |
| 6 | 💌 邀请另一半入住「把你们的专属空间分享给 TA」（条件 `users.length<2`） | `data-action="invite"` | **无** | **已有、不要重做** `profile_page.dart:155-176/:420-449` |
| 7 | 🔔 提醒设置「通知渠道与提醒偏好」 | `data-nav="channels"` | **无** | **未落地**（无 channels 页/路由，`main.dart:51-130`） |
| 8 | ⚙️ 全部设置「账号资料、数据导出与备份」 | `data-nav="settings"` | **无** | **未落地**（无 `/settings`，`main.dart:51-130`） |

🔴 **8 张卡在 App hub 里 0 张落地**（`together_page.dart:61-137` 逐卡实读只有 12 张工具卡 +
纪念日只读展示卡 `:59`；注释 `:151`「不预放死卡」）；但 **4 卡（1/4/5/6）的功能已在别处落地**
→ 入口层要补的是**卡（导航入口）**，不是重做功能；缺卡清单 8 张全缺，其中 2/3/7/8 连功能也缺。
对照四张特殊卡（`together-plan.md:12`）：数据看板 / 回忆周报 hub 卡**已落地**
（`together_page.dart:124-130`/`:131-137`），🌸 生理期与情侣摆拍**未落地**
（figure `chat_compose.dart:565-566` 注明「Web 专属页，不在 App 迁移范围」）。

⚠️ **命名差异（未核实 D-8）**：`together-plan.md:15-16` 写「邀请另一半」，`app.js:1229`
实读为「**邀请另一半入住**」；其余 7 张一致。以 Web 实读为准，差异原因未核实、不推测。

### 2.2 Web `settingsPage()` 逐项契约表（全部条目，逐项盘点）

| # | UI 文案 | 行号 | 点击后 / 函数 / 端点 | 状态字段 |
|---|---|---|---|---|
| 1a | 空间名称与相恋日期 | `app.js:1482` | `act :2552` → `spaceForm() :1864-1869` → `PUT /api/space :1867` | `state.me.space` |
| 1b | 邀请另一半（条件 `users.length<2`） | `app.js:1482` | `act :2566` → `inviteModal() :2011` → `POST /api/invite` | `state.me.users` |
| 1c | 通知渠道与提醒偏好 | `app.js:1482` `data-nav="channels"` | `channelsPage() :1495-1499`；`eventNames :1494` 含 `period:'生理期提醒'` | `state.channels/deliveries/webpush` |
| 2a | 主题与外观 | `app.js:1482` | `act :2553` → `themeForm() :1870-1942` → `PUT /api/space :1937`；夜间/字号只写本地 `:1933-1934` | `THEME_IDS :103`（7 套）、`DARK_KEY :98`、`FONT_KEY :99` |
| 2b | 主页背景 | `app.js:1482` | `act :2554` → `homeBgForm() :1943-1956` → `PUT /api/space :1951`；上传 `uploadFile() :1805` → `POST /api/media` | `space.cover/cover_pos` |
| 2c | 聊天背景 | `app.js:1482` | `act :2651` → `chatBgForm() :1970-2008` → `PUT /api/space :1982` | `CHAT_BG_PRESETS chat.js:127` |
| 2d | 聊天气泡 | `app.js:1482` | `act :2555` → `bubblePicker() chat.js:891` → `applyBubblePick chat.js:918` → `PUT /api/space chat.js:983` | `space.chat_bubble*` |
| 3a | 头像、昵称与密码 | `app.js:1482` | `act :2565` → `profileForm() :2010` → `PUT /api/profile` | `state.me.user` |
| 3b | 退出登录 | `app.js:1482` | `act :2570` → `POST /api/logout` + `clearPrivateSession app.js:52` | — |
| 4a | 链路检测与线路切换 | `app.js:1482` `data-nav="linkcheck"` | `linkCheckPage() :1368-1386`；探测 `runLinkProbe() :1407-1456`（`bridge.probe() :1441`）；切换 `useLinkRoute() :1457-1473`（`bridge.use({url}) :1461`）；线路清单 `loadRoutes() :1348-1356` → `GET /api/routes` | `state.linkRoutes/linkProbing` |
| 5a | 存储摘要条（**仅 admin**） | `app.js:1481-1482` `storageStrip` | `data-nav="backups"` → `backupsPage() :1500` | `state.storage :1478`、`state.me.user.admin :1480` |
| 5b/5c/5d | 导出记录 / Markdown / .ics | `app.js:1482` 三个 `<a download>` | `/api/export`、`/api/export/markdown`、`/api/export/ics`（直接下载，无 JS） | — |
| 5e | 完整备份与存储占用（**仅 admin**） | `app.js:1482` | `backupsPage() :1500`；「立即备份」`act :2696` → `POST /api/backups`；下载 `/api/backups/{name}` | `state.backups` |
| 6a | 版本「APK vX · 网页 vY · 可更新到 vZ」 | `app.js:1482` | 无 | `state.appVersion/apkVersion/apkLatest` |
| 6b | 检查更新 | `app.js:1482` | `act :2593-2612` → `GET /api/status` + `detectAppVersion() :2762` / `showUpdateModal() :2845` | 同上 |
| 6c | 复制 App 下载链接 | `app.js:1482` | `act :2569`（`state.apkMirror||'/apk/download'`） | `state.apkMirror` |
| 6d | 复制键盘诊断数据 | `app.js:1482` | `act :2584-2592`（读 `window.__kbRing`） | `window.__kbRing` |

🔴 **实读否证**：`settingsPage :1482` **没有**「数据恢复」「导入」入口。恢复只在 `backupsPage :1500`
说明文字写「恢复操作通过服务器命令进行」；通用恢复 action 是 `restore app.js:2524`
（`POST /api/records/{id}/restore`），挂在回收站页。**恢复/导入不是设置页条目，别照抄纳入**。

🔴 **函数名对不上**（照抄会全错）：`saveProfile/saveSpace/switchRoute/probeLatency/setTheme/setWallpaper`
在 Web **均无同名函数**，真实为 `profileForm :2010` / `spaceForm :1864` / `useLinkRoute :1457` /
`runLinkProbe :1407` / `themeForm :1870` / `chatBgForm :1970` / `homeBgForm :1943`。

**`pages` 映射归属（`app.js:335`）**：`channels :1495-1499`、`backups :1500`、
`linkcheck :1368-1386` 属设置章；`notices :1492`（顶栏铃铛通知中心）、`imports :1004-1007` /
`importdetail :1008-1012`（聊天记录导入）、`dashboard :1303-1316` / `weekly :1317-1329` /
`figure :444-454`（「我们」hub 工具卡）**均非设置章**。`period` **不在 `pages` 映射里**（见 3.7）。

### 2.3 App 已有（**不要重做**，一句一行）

| 能力 | 已落地位置 |
|---|---|
| 昵称/头像/密码 `PUT /api/profile`、邀请、退出、实际安装包版本 `vX (VC)` | `profile_page.dart:117-153`、`:92-115`、`:387-405`、`:155-176`、`:178-193`、`:43-46/:59-71/:502-506` |
| 当前线路 base 展示（**仅语音诊断弹窗头部**） | `profile_page.dart:216-235`、`:195-306` |
| 空间名称 + 相恋日期 `PUT /api/space` | `home_page.dart:248-300` + `api_client.dart:162-169`（入口在首页封面，非设置页） |
| 聊天背景 / 聊天气泡（`PUT /api/space`） | `wallpaper_sheet.dart:21/:131/:137`、`chat_wallpaper.dart:56`、`bubble_skin_sheet.dart:22/:122`、`chat_bubbles.dart:45`；入口 `messages_page.dart:314-323` |
| 回收站通用 restore | `personal_controller.dart:580-587` |
| 自动线路选择（冷启动三层探测，无 UI） | `api_client.dart:354-368`、`config.dart:16-19` |
| 主题（仅跟随系统）、5 tab 壳、23 条路由 | `main.dart:143-154`、`main.dart:51-130`、`shell_page.dart:50-59/:62/:76-89` |

差异备忘：Web 版本区还显示「网页 vX / 可更新到 vY」，App 只有安装包版本；App「语音诊断」
与 Web「复制键盘诊断数据」**不是同一物**；`together-plan.md:50`「壁纸/背景归设置」在 App
实际落在**聊天页 AppBar**，除非主人另有定案，本章不搬。

### 2.4 🔴 缺口清单（本章主体输出：只列缺口/差异，不全量重述）

**设置组**

| # | Web 条目（行号） | App 现状 | 建议 |
|---|---|---|---|
| S1 | 设置页本体 `settingsPage() :1474-1483` | **未落地**（无 `/settings`，`main.dart:51-130`） | **纳入（核心）** |
| S2 | hub 底部设置 8 卡 `app.js:1229` | **8 张全缺**（`together_page.dart:61-137`）；其中 1/4/5/6 功能已在首页/聊天页/账号页落地 → **只补卡（导航入口），不重做功能**；2/3/7/8 连功能也缺（逐卡见 2.1） | **纳入**（定案全归条目 8） |
| S9 | 主题与外观 `app.js:1482/:1870-1942` | **未落地**；仅 `ThemeMode.system` `main.dart:143-154`，无主题/夜间/字号/动效开关 | **纳入** |
| S10 | 主页背景 `app.js:1482/:1943-1956` | **未落地** | **纳入**（或按成本取舍，见 D4） |
| S13 | 通知渠道与提醒偏好 `app.js:1482/:1495-1499/:2673-2678` | **未落地**；`flutter-plan-v2.md` 现归后续章「数据管理与通知渠道」（编号 9 已取消） | **定案（D4-c）：留后续章** |
| S14 | 链路检测与手动切换线路 `app.js:1482/:1368-1386/:1407/:1457` | **差异/部分**：自动选路已有 `api_client.dart:354-368`，**手动探测/切换 UI 未落地** | **纳入**（App 侧主要补 UI） |
| S15 | 数据导出 3 链接 `app.js:1482` | **未落地** | 定案（D4-c）：留后续章 |
| S16 | 存储摘要 + 完整备份/下载（仅 admin）`app.js:1481-1482/:1500/:2696` | **未落地** | 定案（D4-c）：留后续章 |
| S17 | 检查更新 `app.js:1482/:2593-2612` | **未落地** | 建议纳入或标可选 |
| S18 | 复制 App 下载链接 `app.js:1482/:2569` | **未落地** | 建议纳入或标可选 |
| S19 | 复制键盘诊断数据 `app.js:1482/:2584-2592` | **差异**：App 为「语音诊断」`profile_page.dart:195-306`，不同物 | 不重做 |
| S20 | 数据恢复 / 导入（`app.js:2524`/`:1004-1012`，**非设置页条目**） | 通用 restore 已落地；imports 页未落地 | **建议划出本章**（`flutter-plan-v2.md:50` 归条目 9） |
| S21 | notices 通知中心 `app.js:1492` | 未落地，顶栏通知中心，非设置章 | **建议划出本章** |

已落地项 S3–S8 / S11 / S12 / S22 全部「不重做」，见 2.3。

**生理期组**（详见第三节契约）

| # | Web 条目（行号） | App 现状 | 建议 |
|---|---|---|---|
| P1 | 主页 `periodPage() period.js:484-519` | **未落地**（`main.dart` 无路由、无页面文件） | **纳入（核心）** |
| P2 | 周期推算 `period.js:110-141/:145-170` | **未落地** | **纳入**（最大缺口，见 D2） |
| P3 | 数据分析页 `period.js:674-807/:591-670` | **未落地** | **纳入**（可拆可选段，见 D7） |
| P4 | 生理期入口卡（宽卡 `app.js:1229` `tool-period`） | **未落地**（`together_page.dart:61-137`）；`chat_compose.dart:806` 有格但 `:560-561` 只弹「条目 8 迁移后开放」占位 | **纳入**（决策点⑥随本章上；**死入口必须改真跳转**） |
| P5 | 记录表单 `periodForm :809-833` + 9 种日记录弹层 `:343-483` | **未落地** | **纳入** |
| P6 | 异常预警 `periodWarnings :232-245` | **未落地** | **纳入** |
| P7 | 经期四动作（来了/走了/又来了/删整次）`:77-109`、`app.js:2507-2510` | **未落地** | **纳入** |
| P8 | 生理期提醒事件 `app.js:1494` `eventNames.period` | **未落地**（随 S13 通知渠道） | 随通知章（见 D3） |
| P9 | 软删 / 恢复 | 通用 restore 已落地 `personal_controller.dart:580-587` | **不重做通用能力**，仅接入 period 记录 |

---

## 三、生理期完整契约（本章主体，全部实读 + 行号）

### 3.1 数据位置与加密（🔴 period 不在主库）

| 结论 | 行号 |
|---|---|
| 独立库 `DATA/period.db`，主库 `records` **已无 `kind='period'` 行** | `period.py:1-4`、`period.py:45-46`（`db_path()` 返回 `db.DATA/'period.db'`） |
| 表结构 `id/kind/author/body/created/updated/deleted/client_id`，`kind` 固定 `'period'`；`UNIQUE(author,client_id)`；三索引 | `period.py:28-42` |
| body **仍是密文**，复用主库密钥，**无第二套密钥**；保留 `kind` 列即为让 `body_encode/body_decode` 原样复用 | `period.py:8-11`、`period.py:208`/`:216`/`:134` |
| `ENCRYPTED = PRIVATE \| {'period'}`；`PRIVATE={'diary','draft','surprise'}`；`SHARED_EDIT` 8 种**含 period**；`KINDS` 17 种含 period | `db.py:343`、`:350-352`、`:353`、`:354` |
| 加密链：HKDF-SHA256 派生 + AES-GCM，AAD 绑定 `kind:record_id`；密钥 `DATA/secret.key` | `db.py:361-365`/`:368-373`；`security.py:18-27`/`:104-112`/`:115-123` |
| 启动时 `period.init()` + 幂等 `migrate_from_main()`（先 `INSERT OR IGNORE` 再删主库行） | `main.py:54-62`；`period.py:64-67`/`:96-123` |
| 跨库写**非原子**：先提交分库 → 再回主库 `bump_shared` + `notice`；主库失败只影响对端刷新 | `period.py:12-15`；`main.py:1243-1248` |
| 不参与主库关联表（点赞/回复/问答/打卡），序列化固定补空数组 | `period.py:17-19`、`:137-139` |

### 3.2 端点与分流全表

| 端点 / 函数 | 行号 | 行为 |
|---|---|---|
| `GET /api/records` 定义 | `main.py:1141-1144` | 参数 `kind,q,author,date,media_type,trash,limit,before,before_id,exclude`；`limit≤1000` `:1148` |
| `only_period` / `merge_period` | `main.py:1165-1167` | `only_period = kinds==['period']`；`merge_period` 在无 kind 或含 period、且 `period` 不在 `exclude`、且 `media_type` 为空时为真 |
| `only_period` 短路 | `main.py:1169-1171` | `pending_count()==0` 时**直接 return** `period.rows_for(...)`，不查主库 |
| 分库合并 | `main.py:1214-1220` | `result.extend(period.rows_for(同 7 参))` → 按 `(created,id)` 倒序重排 → `limit` 再截断；**`exclude`/`media_type` 不透传分库** |
| `period.rows_for` | `period.py:153-189` | `trash=True` → `author=? AND deleted IS NOT NULL` `:160-162`；否则 `deleted IS NULL` `:164`；`date` 匹配 `body.start` 或 `body.date` 前 10 位 `:184`；**`q` 只搜 `body.content`** `:186`（主库搜 `content+title` `main.py:1201`） |
| `_period_touch()` | `main.py:1229-1233` | 回主库 `db.bump_shared` 推 `content_revision`（`db.py:388-391`） |
| `POST /api/records` 按 kind 分流 | `main.py:1278-1281` | `kind=='period'` → `create_period_record`；`RecordInput{kind,body,client_id}` `:908-911` |
| `create_period_record` | `main.py:1236-1249` | `find_by_client` 命中直接返回既有（幂等）`:1238-1240` → `clean_body` → `period.insert` → `bump_shared` + `db.notice('activity','你们的空间有了新记录')` + `nudge_worker()` → `period.serialize` |
| `GET /api/records/{rid}` | `main.py:1379-1387` | 主库未命中 → `period.get(rid)` `:1384` → `period.serialize` `:1387` |
| `PUT /api/records/{rid}` | `main.py:1390-1394` | `period.get(rid)` 命中即 `update_period_record` |
| `update_period_record` | `main.py:1252-1260` | `kind != 'period'` → 422「已发布内容不能改变可见范围」；`clean_body(c,'period',body,user_id,old_body)` → `period.update` → `_period_touch()`；**无作者校验** |
| `DELETE /api/records/{rid}` | `main.py:1424-1428` | `period.get` 命中即 `delete_period_record` |
| `delete_period_record` | `main.py:1263-1267` | `period.soft_delete` → `_period_touch()` → `{'ok':True}`；**零校验，谁都能删** |
| `POST /api/records/{rid}/restore` | `main.py:1443-1451` | `period.get(rid, include_deleted=True)` 命中即 `restore_period_record`；否则主库 `UPDATE records SET deleted=NULL` |
| `GET /api/storage`（**非 `/api/status`**） | `main.py:2693-2724` | `:2714-2715` period.db/-wal 体积、`:2718` `record_count = 主库未删 + period.count_active()`；**admin 权限** `:2696-2697` |
| `GET /api/status` | `main.py:401-413` | 仅 `initialized/paired/version/build/apk_*`，**不含 period 信息** |
| `EVENTS` 含 `'period'` | `main.py:2502-2504` | `:2502 CHANNEL_KINDS`（10 种）、`:2503-2504 EVENTS`（12 事件，含 period，供通知渠道订阅）；**此处非 kind 白名单**，`db.KINDS` 在 `db.py:354` |
| 30 天物理清理 | `worker.py:468-470` → `period.purge_deleted` `period.py:232-236` | — |

### 3.3 字段全集与校验（实读）

`clean_body` 白名单 **`main.py:930-934` 共 31 键**：
`title, content, date, media, album, publish_at, annual, remind_days, category, done, emoji,
target, completion_post, sticker, amount, start, cycle, length, flow, symptoms, color, pain,
sex, mood, weight, discharge, temp, reply_to, pinned, location, song`。
🔴 **不含 `shared`**（`db.py:351` 注释、`serializers.py:21-22`、`markdown_export.py:148` 仍按 shared 判定，见 3.5 / 第六节）。

| 字段 | 校验 | 行号 |
|---|---|---|
| `start` / `date` | 二者必有其一 → 422「请选择这次经期开始的日期」 | `main.py:999-1002`、`:1099-1100` |
| `date/target/start` | ISO 日期 | `main.py:1072-1077` |
| `cycle` | int **15–60**；`length` int **1–15**；空值丢弃 | `main.py:1005-1010` |
| `flow` | `'少'/'中'/'多'` 或 int 1–5 | `main.py:1011-1016` |
| `color/pain/discharge` | int 1–5；`mood` int 1–20 | `main.py:1018-1027` |
| `sex` | list ≤8；旧 `[2,4]` 或新 `[{'t':'HH:MM','w':[1..10]}]`，统一落后者 | `main.py:1028-1054` |
| `weight` / `temp` | 20.0–300.0 / 30.0–45.0，round 1 位 | `main.py:1055-1065` |
| `symptoms` | list ≤20，每项 str ≤16 字，去重 | `main.py:1066-1071` |
| `content` ≤20000 字；其余文字 ≤200 字 | — | `main.py:978-980` |
| `media` | list ≤30，逐个 `db.media_visible` 校验 | `main.py:1101-1104`、`:1113-1118` |
| `reply_to`/`pinned` | 非聊天一律丢弃 | `main.py:1078-1081` |

**两种记录形状（实读 `period.js`）**：

- **经期区间记录**（有 `start`、无 `date`，**参与推算**）：`start :90`、`:112`、
  `length :90`（**没有 `end` 键**；结束靠改 length `:99`/`:107` 或删整条 `:98`）、
  `cycle :90`、`:824`、`flow :815`、`:824`、`symptoms :813`、`:825`、`content :816`、`:826`。
- **每日记录**（有 `date`、无 `start`，**不参与推算**；`periodSaveDay :66` 强制删 `start`）：
  `date :34-36`、`:61`、`flow :40`、`color :41`、`pain :42`、`discharge :43`、`:477`、
  `mood :44`、`sex :45-51`/`:318-322`、`symptoms :52`、`:473`、`weight :53`、`:474`、
  `temp :54`、`:475`、`content :313`、`:454`。
- `client_id` 是**记录顶层字段**（`period.js:68`/`:91`/`:828` 用 `uuid()`），**不在 body 内**。
- 🔴 **`end` 键在 `period.js` 全文未出现**：按「start/end 区间」建模会与 Web 数据不兼容。

### 3.4 周期推算逻辑（两侧各一套 —— 本章最大契约缺口）

**后端（提醒口径，不暴露 API）**：`period.py:280` `GAP_MIN,GAP_MAX=15,60`；
`episodes() :283-315`（首尾相接 ≤1 天合并经期）、`cycle_stats() :318-339`
（返回 `episodes/gaps/cycle/length/last_start/last_length/next_start/days_since/in_period`；
平均周期取 15–60 天有效 gap，**无则回落 28** `:323-325`；`next_start=last_start+cycle` `:336`）、
`reminder() :342-359`（提前 N 天一次 / 当天 / 推迟>3 天，带 `next_start` 去重键）。
唯一调用点：**每日 worker 发站内通知** `worker.py:243-252`（`:246-247` 调用、
`:252` 落 `db.notice`）；`main.py:2504` EVENTS 含 period 使渠道可订阅。
🔴 后端**没有**易孕期/排卵期/受孕概率、页面警告、周期波动分析、日历网格；
`cycle_stats/episodes/reminder` **不经任何 HTTP 端点暴露**（全 app 仅 `worker.py:246` 调用）。

**前端（页面口径，全部在 `static/period.js`）**，逐条实读：

| 口径 | 公式 / 条件 | 行号 |
|---|---|---|
| 记录形状识别 | 经期行有 `start` 参与推算；日记录行有 `date` 无 `start` 不参与 | `:32-34` |
| 碎片合并 | 相邻碎片 `s<=prev.end+1` 合并，`length=end-start+1` | `:116-124` |
| 有效间隔 | `g=episodes[i].start-episodes[i-1].start`，仅 `15<=g<=60` 计入 gaps | `:125-126` |
| 平均周期 | `gaps.length ? Math.round(平均 gaps) : (lastEp.rec.body.cycle \|\| 28)` | `:128` |
| 平均经期 | `episodes.length ? Math.round(平均 length) : 5` | `:129` |
| 下次预测 | `nextStart = lastEp.start + avg` | `:132` |
| 今天在不在经期 | 用**本次实际合并段长** `lastLen`：`todayN>=startN && todayN<startN+lastLen` | `:133-137` |
| 经期第几天 / 距下次 / 参考值 | `dayOfPeriod=todayN-startN+1`、`untilNext=nextStart-todayN`、`estimated=gaps.length===0` | `:138-140` |
| 新建经期默认天数 | `length:Math.max(3,d.length)`（不低于 3 天） | `:88-90` |
| 表单默认边界 | `length` 默认 `d.length`（1–15）、`cycle` 默认 `d.cycle`（15–60） | `:816`、`:824` |
| 排卵日 | `ovu = s + d.cycle - 14`（下次月经前 14 天，黄体期固定） | `:151-158` |
| 四阶段 | 月经期 `[s,s+len)`；卵泡期 `[s+len,ovu-6]`；排卵期 `[ovu-5,ovu+1]`（7 天）；黄体期 `[ovu+2,s+cycle)` | `:160-164` |
| 「经期第 N 天」/`周期第 N 天` | `n-hit.ep.start+1`；`min(cyc,max(1,todayN-startN+1))` | `:308`、`:249-252` |
| `periodEpisodeOf` | 取 `n∈[e.start,e.end]` 的段；`owner`=开始日 ≤n 的**最后一个**碎片 | `:145-149` |
| 预警（最近三次 gaps） | `eps.length<2` 不告警；`g<21` 偏短、`g>35` 偏长 | `:232-239` |
| 预警：经期过长 / 可能漏记 | `lastEp.length>7`；`todayN-lastEp.start > max(45,cycle+21)` | `:240-243` |
| 数据分析：完整度 | 经期每天 1 格，记了 9 字段任一项算填上 → `filled/slots*100` | `:595-600` |
| 数据分析：横轴上限 / 颜色 | `maxLen=min(7,max(episode.length))`；历史同期**均值** `paMean` / 颜色取**众数** | `:601-621` |
| 数据分析：规律度 | `sd=paSd(gaps)`；`score=min(99,max(40,round(100-min(45,max(0,(sd-1.5)*6)))))`；`gaps<2` 为 `null` | `:663-665`、`:527` |
| 受孕概率 | 只按阶段给「低/中/高」三档，**不给百分比**；声明「按日历推算，仅供参考，不能作为避孕依据」 | `:224-228`、`:701` |

**读写调用链（无生理期专属端点，全走通用 `/api/records`）**：
存一天 `post('/records',{kind:'period',body,client_id:uuid()})` `period.js:68` /
`put('/records/'+id,{kind:'period',body})` `:67`（整份 body 覆盖 `:58`）→ `refresh()` `:69`；
月经来了 `put ... length` `:84` / 新建 `post ... {start,length,cycle}` `:90-91`；
月经走了首日 `del` `:98` / 中途 `put ... length:n-s` `:99`；又来了 `put ... length:want` `:107`；
编辑 `periodForm` `put :827` / `post :828`（`recordForm` 分流 `app.js:1834`）；
删整次 `period-del-episode` 逐个 `del` `app.js:2507-2510`；恢复 `post('/records/'+id+'/restore')` `app.js:2524`；
数据源 `GET /api/records?kind=<全部>&exclude=chat&limit=1000` `app.js:270`、`:278` →
前端 `recordsOf('period')` 过滤 `period.js:34`/`:112`。
`flutter-plan-v2.md:49` 亦写「period 记录走通用 records 接口（服务端自动分库）」。

🔴 **结论**：Flutter 迁移若只调后端接口，**拿不到任何预测字段**；必须客户端 1:1 重算
或新增端点（决策点 D2，定案 (a)）。前端无有效 gap 时回落 `body.cycle||28`（`:128`），
后端直接回落 28（`period.py:325`）—— **8-A 对拍已核实差异属实，只留痕、以前端为准，
C4 已关闭（见附录 A）**。

### 3.5 可见性规则（谁能看 / 谁能记 / 谁能改删 / 谁能恢复）

| 问题 | 实读结论 | 行号 |
|---|---|---|
| 谁能看 | **分库路径（现行）：双方都能看全部未删记录，不检查 `shared`、不按作者过滤** | `period.visible :128-130`（`return not row['deleted']`，完全忽略 user_id）、`period.serialize :133-140`（无门槛）、`period.rows_for :153-189` |
| 主库遗留路径 | `db.visible()` 只看 `deleted` 与 `PRIVATE`，period 不在 PRIVATE → 恒 True；但 `serializers.py:21-22` 额外要求「非作者且 `not body.shared` → 404」。**两条路径口径不一致** | `db.py:344-349`/`:376-381`；`serializers.py:21-22` |
| 谁能记 / 改 | **记**：`create_period_record :1236-1249` 无作者/角色校验（仅 `current_user`）；**改**：`update_period_record :1252-1260` 无作者校验 + `SHARED_EDIT` 含 period（`db.py:353`） | `main.py:1374` 是 `SHARED_EDIT` 唯一使用点（`get_record` 的 403 闸） |
| 谁能删 | **谁都能删**（零校验）；注释逐字「period 在 SHARED_EDIT 里：谁都能删，恢复只有本人能做（回收站是按人分的）」 | `main.py:1263-1267`（`:1264` 注释已核实成立） |
| 谁能恢复 | **只有本人**：`restore_period_record` 作者不符 → `HTTPException(404,'记录不存在')`；回收站列表也按本人过滤 | `main.py:1271-1272`；`period.py:160-162` |
| Web 侧表现 | **无「共享/私密」开关、无「替谁记」、无编辑权限 UI**；两人共同维护同一条周期，页面完全一样；历史卡只显示记录者，不做权限判断 | `period.js:6-7`/`:13-15`/`:111`/`:486`/`:489`/`:816`、`:505`/`:509` |
| 前端 sharedEdit 白名单 | `app.js:856-857` 列 `album,anniversary,wish,habit,quest,ledger,music`，**不含 period**；与后端 `db.SHARED_EDIT`（含 period）不一致，period 走独立页面/独立权限路径 | `app.js:856-857`；`db.py:353` |
| 「shared 只能本人改」保护 | `main.py:1404-1407` 走**主库** `update_record` 分支，而 period 在 `:1392-1394` 已分流 → **对分库记录不可达** | `main.py:1392-1394`、`:1404-1407` |

### 3.6 回收站 restore 的 period 分流（逐跳调用链，实读）

`POST /api/records/{rid}/restore` `main.py:1443`
→ `period.get(rid, include_deleted=True)` `:1445`（→ `period.py:143-150`，允许已删行）
→ 命中 → `restore_period_record(rid,prow,user)` `:1447`（→ `main.py:1270-1275`）
→ 作者校验 `row['author'] != user['id']` → 404「记录不存在」`:1271-1272`
→ `period.restore(rid)` `:1273`（→ `period.py:226-229`，`SET deleted=NULL,updated=now()`）
→ `_period_touch()` `:1274`（→ `main.py:1229-1233` → `db.bump_shared` → `db.py:388-391`）
→ `{'ok':True}` `:1275`；未命中则退回主库 `UPDATE records SET deleted=NULL,updated=?` `main.py:1448-1450`。

🔴 **只清 `deleted`，不回写任何 body 字段**（与条目 7 的 G5 相册归属语义同类）；
`restore` 对分库记录**不恢复 shared、不改任何内容**（`period.py:226-229` 逐字）。

### 3.7 专门 App 入口（条目 6 定案：入口卡随本章上线）

| 事实 | 行号 |
|---|---|
| Web 生理期**不是独立 page**，而是「我们」页的 `state.tab`：`if(state.tab==='period')return periodPage()`；分析页 `:1226`；`app.js:335` `pages` 映射**没有 period** | `app.js:1225-1226`、`togetherPage() :1220-1230` |
| 入口卡是 `app.js:1229` `tools-grid` **首位硬编码宽卡** `tool-card-wide`，`🌸 生理期 / 记下周期，把照顾提前一点`；`toolsList :1219` 共 11 项**不含 period** | `app.js:1219`、`:1229`；`together-plan.md:12`（四张特殊卡） |
| 跳转链 `data-action="tool-period"` → `act :2513`（`navigate('together',action.slice(5))`）→ `navigate :423` → `:1225` | `app.js:2513`、`:423`、`:1225` |
| 条目 6 定案「生理期入口卡随条目 8 上，条目 6 hub 不放」 | `together-plan.md:51`、`:66`、`:85-86` |
| App 现状：hub 无此卡（`together_page.dart:61-137` 逐卡实读，注释 `:151`「不预放死卡」）；**聊天 ⊕ 面板有「生理期」格但点击只弹占位「条目 8 迁移后开放」** | `chat_compose.dart:806`、`:560-561` |
| App 无 `/period` 路由（`main.dart:51-130` 全量实读）、无 period 页面文件、无推算/日历/日记录/分析实现 | `main.dart:51-130`；`app-flutter/lib` 内 11 处 period 引用逐处判定见下 |

🔴 **入口卡 vs tab 分流严格区分（两件事，App 两者都缺）**：入口卡是 `app.js:1229` 的
**静态 DOM**（`data-action="tool-period"` 宽卡），管「点什么进」；tab 分流是 `app.js:1225`
的**运行时分支**（`state.tab==='period'` → `periodPage()`），管「进去渲染谁」。决策点⑥
（`together-plan.md:66`）针对**入口卡**；本章既要补宽卡到 App hub，也要补对应页面本体
（`period.js:484-519` 主页 / `:674-807` 分析页）。分析页进/出：`app.js:2505`
`period-analysis` → `navigate('together','period-analysis')`、`:2506` `period-back` →
`navigate('together','period')`。

`period` 在 `app-flutter/lib` 全量引用（8 文件 11 处）：仅 kind 串/文案
（`together_data.dart:486`、`personal_controller.dart:88`、`api_client.dart:136`）、
注释（`personal_controller.dart:276`/`:581`）、**占位提示**（`chat_compose.dart:560-561`）、
工具项标签（`chat_compose.dart:806`）、以及 5 处**无关引用**（`Timer.periodic`
`composer_sheet.dart:396`/`chat_toast.dart:543`、`stalePeriod` `low_freq_cache.dart:16/:23/:32`/
`skin_bubble.dart:82`）。**判定：App 生理期页面未落地**。

### 3.8 备份 / 导出 / 恢复与 `secret.key`

| 位置 | 行号 | 行为 |
|---|---|---|
| 备份带走 period.db | `backups.py:239-249` | `period_snapshot=tmp/'period.db'` `:241` → `period.copy_file()` `:244`（SQLite `source.backup`，非直接拷文件 `:246-257`）→ `archive.write(...,'period.db')` `:249` |
| 备份写加密密钥 | `backups.py:250-254` | `archive.writestr('secret.key.enc', encrypt_bytes(secret.key, password))` + `manifest.json{version:2,created}` |
| `GET /api/export` → `user_export` | `backups.py:289-325` | `:293` 主库 `db.visible`+`serialize`；**:294-296 `records.extend(period.rows_for(user_id))`**；`:300` `records.json` **明文**；`:307-309` 回忆.html 对 period 用 `经期 {start}` 补 title |
| 恢复 period.db 落位 | `backups.py:328-371` | `:359-360` `extra_db=destination/'period.db'`；`PRAGMA integrity_check` 不过抛「生理期数据库完整性检查失败」`:363-364`；`chmod 0o600` `:368`；老备份缺它靠启动迁移兜底 `:358` |
| 解包白名单 | `backups.py:374-405` | **required** 集合 v1=`{love.db,secret.key,manifest.json}`、v2=`{love.db,secret.key.enc,manifest.json}`（`:382/:384`，**均不含 period.db → 可选**）；文件名白名单 `:392-395` 含 `period.db` |
| 无口令拒绝备份 | `backups.py:25-30`/`:33-34`/`:215-219` → `main.py:2684-2685` | `BackupRefused` → HTTP 503「未配置备份密码」（包内含 `secret.key`） |
| **恢复没有 HTTP 端点** | `manage.py:5`/`:15-18`/`:29-33` | 只有 CLI `python -m app.manage restore <备份> <目标目录> [--password]`，目标必须是**新的空目录**、停旧服务后切 `DATA_DIR`（`backups.py:329-331`） |
| Markdown 导出 | `markdown_export.py:30`/`:38`/`:66-79`/`:139-148`/`:244-252` | `:250-251` `records.extend(period.rows_for(user_id))`；`_render_record` period 分支**渲染明文结构化字段**（开始/经期天数/周期/经量/症状/共享给 TA），**不是只写标题、不含密文**；包本身明文 `:367-370` |
| `/api/export/ics` | `main.py:2604-2673` | `:2612-2615` **只查主库**、`:2639/:2647` 仅 anniversary/wish/quest → **不含 period** |

🔴 **三个导出口径不一**：`/api/export` 含 period 明文、Markdown 含 period 且渲染明文结构化字段、
`/api/export/ics` 完全不含 period。ENCRYPTED 记录解密强依赖 `secret.key`（`security.py:18-27`/`:104-123`，
AAD 绑定 kind+record_id），换错/丢失密钥 → period 记录不可解。

### 3.9 Web 交互函数表（`period.js` 全文 834 行，节选）

`periodDayRows/Row/Logs :34-36`；`periodValueText :38-57`；`periodSaveDay :59-70`；
`periodStart :77-93`；`periodEnd :94-101`；`periodMore :102-109`；`periodData :110-141`；
`periodEpisodeOf :145-150`；`cyclePhases :155-170`；`todayPhase :171`；
`periodMonthGrid :174-193`；`shiftMonth :195-201`；`cycleHero :246-277`；`phaseBar :281-289`；
`periodTopCard :292-295`；`periodLogCard :298-315`；`periodSexEntries :318-322`；
`periodSexSheet :343-394`；`periodChoiceSheet :400-409`；`periodMultiSheet :410-428`；
`periodNumberSheet :430-450`；`periodLogSheet :451-483`；`periodPage :484-519`；
图表件 `:532-587`；`periodAnalysis :591-670`；`periodAnalysisPage :674-807`（13 板块）；
`periodForm :809-833`。常量 `PERIOD_LOG_FIELDS :28`（9 项）、`DAY_MS :29`。
脚本加载顺序 `index.html:25` `period.js` → `:26` `app.js`（均为 `defer`），
符合 `period.js:9-10` 注释「必须排在 app.js 之前加载」。

---

## 四、决策点定案（2026-11-14 主人拍板，不再复议）

> 本节单列，不混进实现细节。**D1–D8 全部「采纳清单推荐」**（主理人原推荐即定案），
> 并按主人下达的 **0–7 条**逐条写明本段（8-A）约束；后续段按第五节分段表停等放行。
> 「定案」列中「本段约束」指 8-A 实现必须落地 / 禁止越界的项，逐条对应主人 0–7 条。

| # | 决策点 | 背景（行号） | 选项 | **定案** |
|---|---|---|---|---|
| **D1** | **入口位置与页面形态** | Web 是 hub 硬编码宽卡 `app.js:1229` + `state.tab='period'` `:1225`（非独立 page）；App 无 `/period` 路由、`chat_compose.dart:806` 有格但 `:560-561` 死入口；阶段 2 通则「二级页一律 `context.push`、返回路径按钮+手势必验」 | (a) 照 Web 在 hub 加宽卡 + tab 内页；(b) 独立 `/period` 二级路由页；(c) hub 宽卡 + 独立路由页 | ✅ **采纳清单推荐 (c)**：hub 顶部放 🌸 宽卡，`context.push('/period')` 进独立二级页，**不照搬 `state.tab`**；⊕ 面板 `tool-period` 占位改同一跳转，杜绝「卡能点但没页面」。**本段约束（第 2 条）**：文案/位置对齐 `app.js:1229`「🌸 生理期 / 记下周期，把照顾提前一点」；`main.dart` 注册 `/period`；二级页一律 `context.push`、AppBar `automaticallyImplyLeading` 不关、返回按钮 + 系统手势必验；grep 确认 `_snack('条目 8 迁移后开放')` 零残留 |
| **D2** | **周期推算口径** | 页面推算全在 `period.js:110-141/:155-170/:232-245/:591-670`；后端 `period.py:283-359` 仅供 `worker.py:243-252` 每日提醒、不暴露 API、不含易孕期/警告；前后端回落口径疑似不同（`period.py:325` 直接 28 vs `period.js:128` `body.cycle\|\|28`），**C4 未核实** | (a) App 端 1:1 复刻前端公式（纯 Dart，后端零改动）；(b) 后端新增端点暴露 `cycle_stats`；(c) 混合 | ✅ **采纳清单推荐 (a)**：纯 Dart **单一实现** 1:1 复刻 `period.js:110-141/:145-150/:155-170`（后端零改动）。**本段约束（第 1 条，🔴 硬门槛先于任何页面代码）**：Node `vm` 注入 `recordsOf/today` **实跑 Web 三函数**产出期望值（不许手算）；夹具必备三组（多周期正常 / 无 gap 单条 / 碎片合并）；逐项对拍 cycle / length / nextStart / 四阶段逐日 phase+ovu / inWindow / dayOfPeriod 全等才准进页面代码，不等立即停下报告；**C4 就此关闭**：前端回落 `body.cycle\|\|28` 为准，后端硬 28 只留痕、不移植（结论见附录 A） |
| **D3** | **提醒 / 通知渠道** | `worker.py:243-252` 每日已发 period 站内通知（后端实现，App 不用做）；`main.py:2504` EVENTS 含 period；`app.js:1494` `eventNames.period`；`PERIOD_REMIND_DAYS` 是服务端环境变量 `worker.py:246`；App 通知渠道 S13 未落地 | (a) 本段不做提醒 UI，沿用后端站内通知；(b) 随通知渠道段做订阅/提前天数设置；(c) 独立成段 | ✅ **采纳清单推荐 (a)**：沿用后端站内通知，本段不做提醒 UI；「通知渠道与提醒偏好」整体留后续章。**本段约束（第 4 条）**：不做 `periodWarnings` 预警、不做提醒设置，也不留半成品入口 |
| **D4** | **设置缺口取舍（S13/S15/S16/S20 归本章还是后续）** | 这些项 App 全未落地；`flutter-plan-v2.md:49-50` 把设置与数据列条目 9，`together-plan.md:51/:85` 把设置区块 8 卡全归条目 8（**编号冲突**）；数据管理/通知渠道涉及 admin 权限（`main.py:2696-2697`）、渠道 config 加密入库（`:2542`）、密钥口令（`backups.py:250-253`），体量大 | (a) 全归本章；(b) 全留后续章；(c) 本章只做「设置页容器 + 主题/外观 + 主页背景 + 链路检测 + 检查更新/APK 链接」，通知渠道/导出/备份/存储/imports 留后续 | ✅ **采纳清单推荐 (c)**：设置侧只补「用户天天会碰的外观与连接」，数据管理/通知渠道留后续章。**本段约束（第 4 条）**：8-A 边界只含生理期地基 + 入口 + 读写 + 最小可用页面，设置页/数据管理不提前做 |
| **D5** | **设置页形态** | App 无 `/settings`；`personal-corner-plan.md:37` 写「App 侧设置页已独立落地，不迁」与代码矛盾（**D-5 未核实**）；账号资料页 `profile_page.dart` 已覆盖资料/邀请/退出/版本/base | (a) 新建独立 `/settings` 二级页；(b) 并入账号资料页加设置区块；(c) 不做容器、缺口散落各页 | ✅ **采纳清单推荐 (a)**：独立 `/settings` 二级页（归段 D），账号资料页不动、已有项用跳转链接不复制 UI。**本段约束（第 4 条）**：段 D 才做，8-A 不做、不留半成品入口 |
| **D6** | **隐私口径（历史 `shared` 矛盾）** | `db.py:351` 注释「period 加密但可按 shared 共享」、`serializers.py:21-22`、`markdown_export.py:148`、`main.py:1407` 仍按 shared 判定；但分库 `period.visible :128-130` 只看 deleted、`serialize :133-140` 无门槛，`period.js:6-7/:13-15/:111/:486/:816` 明说「两人共同维护同一条，无共享/私密」；白名单 `main.py:930-934` **不含 shared**（C1 历史数据未核实）；`app.js:856-857` 前端 sharedEdit 不含 period | (a) 按现行分库「双方全可见」实现，对齐 Web 现状；(b) 补回 shared 开关；(c) 先查历史数据再定 | ✅ **采纳清单推荐 (a)**：按现行分库「双方全可见」对齐 Web，后端零改动、历史 `shared` 矛盾只留痕。**本段约束（第 5 条）**：不加 `author == uid` 过滤、不加「仅本人可编辑」判断；谁都能看/记/改/删；恢复限本人由服务端兜（404「记录不存在」）→ 必须经 7-C 返修后的错误通道**原文双呈现**（顶部通知 + 表单内联）、不静默、不发成功通知，写进测试用例 |
| **D7** | **数据分析页是否独立可选段** | `periodAnalysisPage :674-807` 13 板块 + 手画 SVG `:532-587`，体量大且不影响主流程；条目 6 有「可选段 E 主线做完停手等主人」先例（`together-plan.md:67`/`:83`） | (a) 并入主线；(b) 独立成段；(c) 降为可选段 | ✅ **采纳清单推荐 (b)+(c)**：数据分析页独立成段且标可选，主线做完停手等主人。**本段约束（第 4 条）**：B/C 段内容（整月日历网格、9 字段弹层、经期四动作、预警、分析页、滚轮/多选/数字键盘、受孕概率卡）一律不做、不留半成品入口 |
| **D8** | **条目编号一致性** | `flutter-plan-v2.md:49-50`（生理期=条目 8、设置与数据=条目 9）vs `together-plan.md:51/:85`（设置区块 8 卡全归条目 8） | 二选一 | ✅ **采纳清单推荐**：条目 8 = 设置缺口 + 生理期；`flutter-plan-v2.md:49` 改「8. 设置缺口 + 生理期」、原 `:50` 去编号 9 改后续章「数据管理与通知渠道」（端点说明保留）。**本段约束（第 0 条）**：随本 commit 同步两份文档，消除与 `together-plan.md:51/:85` 冲突 |

---

## 五、分段定案与版本位（按体量，从 2.2.1 (VC221) 起）

> 沿用条目 6/7 纪律：**一段一 commit、一包、停等真机验收**；全项目 `dart analyze` +
> `flutter test` 全绿；二级页一律 `context.push`；返回路径按钮 + 手势必验；后端零改动。
> ✅ **8-A 已定案并随 2.2.1 (VC221) 落地**（一 commit、门禁全绿、对拍见附录 A）；
> B/C/D/E 段仍待主人逐段放行，本段不预做、不留半成品入口。

| 段 | 版本 | 内容 | 主要端点 / 依赖 | 依赖决策点 |
|---|---|---|---|---|
| **A（8-A 已定案）** | **2.2.1 (VC221)** | **生理期地基 + 入口 + 读写**：hub 🌸宽卡、⊕ 面板死入口改真跳转、`/period` 二级页、`GET /api/records` 合并拉 period、两种记录形状解析、`periodData`/`cyclePhases`/`periodEpisodeOf` 客户端重算、经期区间与日记录的 POST/PUT/DELETE + `client_id` 幂等、软删/恢复接通用 `restore` | `GET/POST/PUT/DELETE /api/records`、`POST /api/records/{rid}/restore`；`period.js:34-141/:145-170`；`main.py:1141-1220/:1236-1275` | D1、D2、D6 |
| **B** | **2.2.2 (VC222)** | **生理期主页 UI**：整月日历网格（四相位/预测/排卵/记录点）、hero 环形「周期第 N 天」、日记录 9 字段弹层、经期四动作（来了/走了/又来了/删整次）、`periodForm` 表单、预警 `periodWarnings`、症状排行、历史卡 | `period.js:174-193/:232-245/:246-315/:343-483/:484-519/:809-833` | D1、D2 |
| **C** | **2.2.3 (VC223)** | **可选**：数据分析页 13 板块 + 手画图表 + 受孕概率三档（**主线做完停手等主人决定做不做**） | `period.js:532-587/:591-670/:674-807` | D7 |
| **D** | **2.2.4 (VC224)** | **设置缺口（D4-c 范围）**：独立 `/settings` 二级页容器、hub 底部设置 8 卡（已落地项用跳转不复制 UI）、主题与外观（7 套 + custom）、主页背景、链路检测/手动切线路、检查更新/APK 下载链接 | `PUT /api/space`/`PUT /api/profile`、`GET /api/routes`、`GET /api/status`、`POST /api/backups`（若纳入）；`app.js:1368-1386/:1870-1942/:1943-1956` | D4、D5、D8 |
| **E** | **2.2.5 (VC225)** | **可选（D7 定案，停等主人决定）**：通知渠道与提醒偏好 + `period` 提醒事件 + 数据导出 3 链接 + 备份/存储占用（仅 admin）+ imports/notices 若主人决定纳入 | `/api/channels` 系列 `main.py:2518-2564`、`/api/export*`、`/api/backups`、`/api/storage`、`/api/imports*` | D3、D4 |

**明确不做（除非主人改定案）**：App 已有项（2.3 全表，不重做）；figure 摆拍
（`chat_compose.dart:565-566` 注明「Web 专属页，不在 App 迁移范围」）；notices 通知中心、
imports 聊天记录导入（非设置章，`app.js:1492`/`:1004-1012`）；「数据恢复」HTTP 端点（后端
没有，只有 CLI `manage.py:29-33`）；按 `shared` 加隐私权限模型（D6）。

---

## 六、风险与坑位备忘

1. 🔴 **period 不在主库**：独立 `DATA/period.db`（`period.py:1-4/:45-46`），任何按主库写的
   统计/SQL/导出都要单独并分库（`main.py:1214-1220`、`backups.py:294-296`、
   `markdown_export.py:250-251`、`main.py:2718`）。
2. 🔴 **推算在两侧各一套**，且后端那套不暴露 API、不含易孕期/警告（3.4）。**Flutter 只调
   后端接口拿不到任何预测字段**；8-A 已按附录 A 完成对拍（C4 关闭）：差异仅在无有效 gap
   时后端硬 28 / 前端 `body.cycle||28`，以前端为准、只留痕、不移植。
3. 🔴 **权限不对称**：谁都能删（`main.py:1263-1267`）、谁都能改（`:1252-1260`）、
   **恢复只有本人**（`:1271-1272`）、回收站按本人过滤（`period.py:160-162`）。别按「私密
   健康数据」自创权限模型。
4. 🔴 **`end` 键不存在**（`period.js` 全文未见），经期结束靠改 `length` 或删整条；按
   start/end 区间建模会与 Web 数据不兼容。
5. 🔴 **`shared` 三处口径不一致**（`db.py:351` 注释 / `serializers.py:21-22` / `markdown_export.py:148`
   vs 分库 `period.py:128-140`；白名单 `main.py:930-934` 不含 shared；`app.js:856-857`
   sharedEdit 不含 period）；且 `main.py:1404-1407` 的「shared 只能本人改」保护对分库记录
   **不可达**（`:1392-1394` 已分流）。C1 历史数据未核实。
6. 🔴 **`GET /api/records` 分库合并有条件短路**：`only_period && pending_count()==0` 直接
   return 分库结果（`:1169-1171`）；`merge_period` 在 `exclude` 含 period 或 `media_type` 非空时
   **整体置 False**（`:1166-1167`），分库记录完全不返回；`exclude`/`media_type` 不透传分库；
   `q` 分库只搜 `content`（`period.py:186`）、主库搜 `content+title`（`main.py:1201`）。
7. 🔴 **三个导出口径不一**（3.8）；备份里 `period.db` 是**可选而非必需**
   （`backups.py:382/:384`）；**无 `BACKUP_PASSWORD` 拒绝备份**（`:25-30/:215-219` →
   `main.py:2685`）；**恢复无 HTTP 端点**（`manage.py:29-33`）。
8. 🔴 **函数名对不上**（2.2 否证）；**period 不是 page 而是 tab**（`app.js:1225-1226`，
   `pages :335` 无 period）；**入口卡不在 `toolsList`**（`app.js:1219` 11 项不含 period，
   宽卡在 `:1229` 硬编码）；按 toolsList 对齐 hub 会漏卡。
9. 🔴 **`validateAppStatus` 名不副实**：`api_client.dart:274` 是 Dio `validateStatus`
   （4xx 当成功 Response），不是线路/App 状态校验、更不是设置能力；别把它算作「线路切换已落地」。
10. 🔴 **聊天 ⊕ 面板 period 是死入口**（`chat_compose.dart:806` + `:560-561` 占位），本章上线
    必须改真跳转，否则「卡能点但没页面」。
11. 🔴 **`period.js` 依赖一堆 Web 全局**（`recordsOf/state/post/put/del/refresh/openModal/esc/
    icon/today/uuid/button/field/formError/modalActions/avatar/person/heading/dateLabel/toggle`
    `period.js:9-10`），Flutter 无对应全局，需逐一映射成 provider；`client_id` 用
    `newClientId()` `api_client.dart:158`（Web `uuid()`）。
12. 🟡 **跨库写非原子**（`period.py:12-15`）；**30 天物理清理** `worker.py:468-470`。
13. 🟡 **`space` 的 `None` 语义特殊**：旧客户端不带壁纸/气泡/封面构图字段时沿用库里原值
    （`main.py:788-806`/`:876-898`），Flutter 全字段提交时**别把对方设好的背景抹掉**；
    `chat_bg_target` 谁都能替对方设（`:794`），改个人那份不动空间级默认值（`:872-874`）。
14. 🟡 **文档矛盾**：`personal-corner-plan.md:37` 称「App 侧设置页已独立落地，不迁」，
    但 `main.dart:51-130` 无 `/settings`、lib 下无 settings 页 —— 原意**未核实**（D-5），
    别据此判定「设置页已有」。`together-plan.md:29` 记 permitted「30 键」，实读
    `main.py:930-934` 为 **31 键**（C3，以实读为准）。
15. 🟡 **锚点偏差已在本文档按实读修正**：period.db 体积在 `GET /api/storage`（`main.py:2693-2724`）
    而非 `/api/status`；`:2504` 是 EVENTS 事件白名单非 kind 白名单；字段白名单在 `:930-934`、
    `:999` 起才是 period 专用取值校验；`restore_period_record` 在 `:1270-1275`；
    `GET /api/records` 定义在 `:1141`；`ChannelInput` 在 `main.py:2507-2515`（架构师已更正笔误）。

---

## 七、未核实项清单（**不许推测**，主人拍板前保持开放）

| # | 项 | 状态 / 原因 |
|---|---|---|
| C1 | `shared` 字段当前能否落库、历史数据是否携带 | **未核实**。白名单 `main.py:930-934` 不含 shared；`clean_body` 的 `previous` 形参 `:925` 全文无引用；`static/period.js` 无 shared；但 `serializers.py:21-22`/`markdown_export.py:148`/`main.py:1407` 仍按 shared 判定。历史迁移数据与其它写入路径未查 |
| C2 | `clean_body(..., previous=old_body)` 传了却不用是否刻意 | **未核实**（`:1257` 传参、`:925` 定义无引用；`together-plan.md:33` 记「previous 不参与合并」，未查提交历史） |
| C3 | permitted 键数 31（实读）vs `together-plan.md:29` 记 30 | **未核实**差异原因（文档笔误/计数口径）；本清单以实读 31 为准 |
| C4 | 后端 `cycle_stats` 与前端 `periodData()` 口径是否逐项完全一致 | ✅ **已关闭**，对拍结论见**附录 A**；**后端回落 28 与前端回落 `body.cycle` 的差异只留痕，以 `period.js` 为准**。三组夹具 Node 实跑 Web 三函数 + Dart 引擎逐项全等；差异仅在无有效 gap 时（`period.py:325` 直接 28 vs `period.js:128` `body.cycle\|\|28`），App 以前端为准、不移植后端口径。其余口径（gaps 15–60、`s<=prev.end+1` 合并、用实际合并段长判窗口、`next_start=last_start+cycle`）逐项一致 |
| C5 | `/api/imports` 聊天消息内容是否加密存储 | **未核实**（未读 `importers.py` 与 `import_messages` 建表 SQL） |
| C6 | `period.copy_file()` 快照是否完整包含 WAL 未 checkpoint 数据 | **未核实**（`period.py:246-257` 用 SQLite backup，通常包含，未实测） |
| C7 | 气泡皮肤静态端点 `main.py:1945-1952` 完整路径与鉴权 | **未核实**（只读到尾段） |
| C8 | 是否还有 period 专用 HTTP 端点 | **未核实**（全 app Grep + 端点表未见，但未做全量路由枚举） |
| C9 | `integrity_ok/remove_file/pending_count` 之外是否另有分库入口 | **未核实**（同 C8） |
| D-1 | `app.js:2762` `detectAppVersion()`、`:2845` `showUpdateModal()`、`:2771-2794` WebPush 系列函数体 | **未核实**（仅从调用点 `:2593-2612` 确认存在），检查更新/WebPush 内部逻辑未展开 |
| D-2 | `chat.js:891` `bubblePicker()` `:906-983` 素材加载/预览/分页 | **未核实**（只实读 `:888-905` 与 `:918/:983` 提交端点） |
| D-3 | `app.js:2539` 注释「默认双人可见，但健康数据必须能一键收回」是否有对应 UI/action | **未核实**：未找到实现，不写成结论 |
| D-4 | `importsPage :1004` 除 `:1171` 外是否还有其它入口 | **未核实**；仅能确认**不在** `settingsPage :1482` |
| D-5 | `personal-corner-plan.md:37`「App 侧设置页已独立落地，不迁」原意 | **未核实**（与 `main.dart:51-130` 代码矛盾），仅如实记录 |
| D-6 | 服务端 period 可见性/分库规则 | 由架构师材料给出（第三节），工程师侧不重复结论 |
| D-7 | 历史遗留数据里是否还有 `period.js` 未列举的 body 键 | **未核实**；B-3 为「当前前端代码会读/写的键」全集 |
| D-8 | 入口层 8 卡命名：`together-plan.md:15-16`「邀请另一半」vs `app.js:1229` 实读「邀请另一半入住」 | **未核实**差异原因；**以 Web 实读为准**（见 2.1） |

---

## 附录 A · 8-A 对拍结论（2026-11-14 · Web 公式实跑）

### A.1 期望值生成方式（**来自 Web 实跑，不许手算**）

一次性脚本 `app-flutter/tool/gen_period_expected.js`（**跑完即删**，无未跟踪残留）：
Node `vm.createContext` 后把 `static/period.js` **整份源码 + 求值 IIFE 拼成同一 script**
执行 —— 因此 `dayNum` / `dayStr` / `periodData` / `cyclePhases` / `periodEpisodeOf`
全是 **Web 原函数**，未被 mock 覆盖。只注入三类全局依赖：

- `recordsOf(kind)` → 当前夹具的 records（`period.js:112` 的数据源）；
- `today()` → 固定 `'2026-11-14'`（Web 由 `app.js` 提供；固定以消除日期漂移）；
- `PROBES` / `DAYNUM_INPUTS` / `DAYSTR_INPUTS`（求值输入）。

IIFE 内实跑 `periodData()`、`cyclePhases(d)`、`periodEpisodeOf(d, dayNum(iso))`，
以及 `todayPhase :171` 等价式与 `cycleHero :249-252` 的「周期第 N 天」表达式；
仅把 JS 的 `undefined ovu` 归一为 `false`（`phase` / `predicted` 原样），JSON 落盘。
三组夹具的 `dayNum/dayStr` 样本在脚本内做**跨沙箱一致性断言**，注入未被污染。
运行（项目根 `D:\Dev\love-space`）：`node app-flutter/tool/gen_period_expected.js`。

产出两份**受版本控制**的测试资产：

- `app-flutter/test/fixtures/period_cases.json` —— Node 与 Dart **共用的同一组夹具**；
- `app-flutter/test/fixtures/period_expected.json` —— Web 实跑期望值
  （`meta` 记 source / functions / method / today / ovuNormalization）。

Dart 侧 `test/period_engine_portrait_test.dart` 读这两份 JSON 逐项断言全等。
QA 可照抄下列精简脚本复核（读 cases.json → 同一 vm 拼接法重跑 → 与 expected.json 比对）：

```js
const fs = require('fs'), vm = require('vm');
const cases = JSON.parse(fs.readFileSync('app-flutter/test/fixtures/period_cases.json', 'utf8'));
const exp = JSON.parse(fs.readFileSync('app-flutter/test/fixtures/period_expected.json', 'utf8'));
const src = fs.readFileSync('static/period.js', 'utf8');
const EVAL = `(()=>{const d=periodData(),p=cyclePhases(d),m={};
 Object.keys(p).sort().forEach(k=>m[k]={phase:p[k].phase,predicted:!!p[k].predicted,ovu:!!p[k].ovu});
 return {cycle:d.cycle,length:d.length,nextStart:d.nextStart,
   nextStartIso:d.nextStart!=null?dayStr(d.nextStart):null,
   todayN:d.todayN,inWindow:d.inWindow,dayOfPeriod:d.dayOfPeriod,
   untilNext:d.untilNext,estimated:d.estimated,lastLen:d.lastLen,gaps:d.gaps,phases:m};})()`;
for (const [name, c] of Object.entries(cases.cases)) {
  const s = { recordsOf: () => c.records, today: () => c.today, console };
  vm.createContext(s);
  vm.runInContext(src + '\n;globalThis.__R=' + EVAL + ';', s);
  const got = s.__R, e = exp.cases[name];
  for (const k of ['cycle','length','nextStart','nextStartIso','todayN','inWindow',
                   'dayOfPeriod','untilNext','estimated','lastLen','gaps'])
    if (JSON.stringify(got[k]) !== JSON.stringify(e[k])) throw new Error(name + ' ' + k);
  if (JSON.stringify(got.phases) !== JSON.stringify(e.phases))
    throw new Error(name + ' phases 逐日不等');
  console.log('OK', name);
}
```

（复核片段省略了 `hits` / `dayNum` / `dayStr` 样本，完整断言以
`test/period_engine_portrait_test.dart` 为准；一次性生成脚本全文曾落在
`tool/gen_period_expected.js`，已按纪律用完即删。）

### A.2 三组必备夹具（`period_cases.json`）

| 组 | 构成 | 验证点 |
|---|---|---|
| ① `multiCycle` 多周期正常组 | 4 条经期区间行（06-01 / 06-28 / 07-26 / 08-24，gaps 27/28/29 全在 15–60）+ 2 条日记录行（06-02 / 08-25），**混入双方作者 u1/u2** | ≥2 episode、有效 gaps；不按作者区分；日记录不参与推算 |
| ② `singleNoGap` 无 gap 只有一条经期记录组 | 1 条经期行（11-10，length 6，**`cycle: 31` ≠ 28**）+ 1 条日记录；落在窗口内 | `period.js:128` 回落 `body.cycle\|\|28`；`inWindow` / `dayOfPeriod`；**证明不能移植后端硬 28** |
| ③ `fragmentMerge` 碎片合并组 | 5 行碎片 → 合并成 2 次月经（09-01 起 3 行 → 7 天；10-01 起 2 行 → 5 天） | `:116-124` `s<=prev.end+1` 合并；`:148` owner = 开始日 ≤n 的最后一个碎片 |

### A.3 逐项比对表（左 = Web 实跑期望值，右 = Dart 引擎实测；**全等**）

| 项 | ① multiCycle | ② singleNoGap | ③ fragmentMerge |
|---|---|---|---|
| 平均周期 `cycle` | 28 | **31**（`body.cycle`） | 30 |
| 平均经期 `length` | 5 | 6 | 6 |
| 下次预测 `nextStart` | 20717 / **2026-09-21** | 20798 / **2026-12-11** | 20757 / **2026-10-31** |
| 四阶段逐日 key 数 | 195 | 124 | 150 |
| `ovu` 标记日 | 7 天（含 11-30 预测） | 4 天 | 5 天 |
| 今天是否经期 `inWindow` | false | **true** | false |
| 经期第几天 `dayOfPeriod` | 0 | **5** | 0 |
| `gaps` | [27,28,29] | **[]** | [30] |
| `episodes`（段长） | 4 段 5/6/4/5 | 1 段 6 | 2 段 7/5 |
| `itemCount` | 4 | 1 | 5 |
| `todayN` / `untilNext` / `estimated` | 20771 / -54 / false | 20771 / 27 / **true** | 20771 / -14 / false |
| `todayPhase` | luteal（预测） | period（实际） | fertile（预测） |
| 周期第 N 天 `dayInCycle` | 28 | 5 | 30 |
| `periodEpisodeOf` probes | 11 项 | 7 项 | 11 项 |

**全量比对，不是抽查**：`cyclePhases` 每组断言「逐日 key 集合全等 + 每天
`phase/predicted/ovu` 三项全等」（195+124+150 = **469 个日期**全量覆盖）；
`periodEpisodeOf` 对全部 **29 个探针日**断言 `ep.start/end/length/owner.id` 或 null；
另对拍 `untilNext` / `estimated` / `lastLen` / `todayPhase` / `dayInCycle` /
`dayNum`（6 样本）/ `dayStr`（6 样本，含负数 -1 → 1969-12-31）/
`||28` 缺省分支（衍生夹具：去掉 `cycle` → Web 实跑 **28**，非手算）。
`flutter test test/period_engine_portrait_test.dart` → **8/8 全过，0 fail**。

### A.4 全等结论 + **C4 就此关闭**

- 前端 `period.js:128`：无有效 gap → `avg = lastEp.rec.body.cycle || 28`。
  组② 实跑 **31**；衍生（去掉 cycle）实跑 **28**（`fallback28: {cycle:28,
  nextStartIso:'2026-12-08'}`）。Dart 引擎与两者全等。
- 后端 `period.py:325`：`cycle = ... if good else 28`，**直接回落 28，不读 body.cycle**。
- 定案：**以 `period.js` 为准，App 移植 31 口径；后端回落 28 与前端回落
  `body.cycle` 的差异只留痕、不移植**。`singleNoGap` 夹具 + `fallback28` 衍生断言
  即回归护栏（若谁改成硬 28，对拍立刻红）。
- 其余口径逐项实读一致：gaps 15–60、合并规则 `s<=prev.end+1`、
  `in_period` 用实际合并段长（后端 `last_start<=today<=last_end` 与前端
  `todayN<startN+lastLen` 等价）、`next_start=last_start+cycle`、平均经期取合并段均值。
  **差异仅此一处**，第七节 C4 已改「已关闭」。

### A.5 8-A 落地清单（随 2.2.1 / VC221 同一 commit）

| 文件 | 作用 |
|---|---|
| `lib/features/period/period_engine.dart` | 纯 Dart **单一实现**：`dayNum/dayStr` `:30-31`、`periodData` `:110-141`、`periodEpisodeOf` `:145-150`、`cyclePhases` `:155-170`、`todayPhase` `:171`、`dayInCycle` `:249-252` |
| `lib/features/period/period_controller.dart` | `GET /api/records?kind=period&limit=1000`（**`only_period` 短路**；无 `media_type` / `exclude` / `author` / `trash`）；两种形状解析、POST/PUT/DELETE、`client_id` 幂等、回填铁律、7-C 错误通道 |
| `lib/features/period/period_page.dart` | `/period` 独立二级页：状态摘要（全来自引擎）+ 记录列表 + 两种形状基础新建/编辑/删除（软删），恢复接已有通用 restore（个人角落 · 回收站） |
| `test/period_engine_portrait_test.dart` / `test/period_page_test.dart` / `test/fixtures/*.json` | 对拍 + 数据层/入口/权限/错误通道/恢复 404 用例 |
| `lib/main.dart` / `lib/features/together/together_page.dart` / `lib/features/chat/chat_compose.dart` / `pubspec.yaml` | `/period` 路由、hub 🌸 宽卡、⊕ 面板真跳转（死入口清零）、2.2.1+221 |

门禁：全项目 `flutter analyze` **0 issues**、`flutter test` 全量全过；
后端 `app/` / `static/` / `android-app/` 零改动；**停等真机验收、不自宣完成、不开 B 段**。

### A.6 时区与「固定 today」口径（D2 补充 · 主理人 2026-11-14 实读提醒）

**契约实读**
- `static/app.js:90`：`const today = () => new Intl.DateTimeFormat('sv-SE',{timeZone:state.me?.space.timezone || 'Asia/Shanghai',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());` → **空间时区的日历日** `yyyy-MM-dd`。
- `static/period.js:29-31`：`DAY_MS=864e5`；`dayNum(s)=Math.round(Date.parse(String(s).slice(0,10)+'T00:00:00Z')/DAY_MS)`（**UTC 午夜解析**）；`dayStr(n)=new Date(n*DAY_MS).toISOString().slice(0,10)`（**UTC 输出**）。
- 组合口径：`periodData():130` 的 `todayN = dayNum(today())` = 「空间时区当天日期字符串 → UTC 天序号」。
- 后端 `space.timezone` 默认恒为 `Asia/Shanghai`（`app/db.py:285`；`main.py:2134/:2268/:2347/:2403/:2616/:2860` 全部 fallback），该时区全年 UTC+8、无 DST。

**引擎 1:1 保留**：`periodData(records, {required String today})` 把 today 做成**显式字符串入参**，`todayN = dayNum(today)`；`dayNum` 用 `DateTime.utc(y,m,d).millisecondsSinceEpoch ~/ dayMs`，`dayStr` 用 `DateTime.fromMillisecondsSinceEpoch(..., isUtc: true)`。**引擎代码内无 `DateTime.now()`、无 `.toLocal()`**（`period_engine_portrait_test.dart` 剥离注释后做源码级断言），绝不改成设备本机时区、也绝不用本地 `DateTime` 直接算天序号。

**页面注入源**：本段不用项目既有的 `todayDateStr()`（`DateTime.now()` 本机时区），改用纯函数 `spaceTodayIso(DateTime.now().toUtc())`：取 UTC 绝对时刻 +8h 得空间默认时区日历日，与 Web `Intl('sv-SE', Asia/Shanghai)` 逐日一致；页面摘要 / 表单日期默认值 / 测试用例三处同源。仅「空间在 Web 端被改成其它 IANA 时区」时存在一天级偏差（Dart 无内置 IANA 库、本段不引入新依赖、不用 DST 近似冒充精确），作为**已知偏差留痕**；后端默认口径下不会命中。

**对拍固定 today 的取值与注入方式（🔴 防假通过）**
- 固定值 **`'2026-11-14'`**（三组夹具共用；`period_cases.json` 每个 case 自带 `today` 字段，`period_expected.json` 的 `meta.fixedToday` 亦记录）。
- Node 侧：一次性脚本在 `vm` sandbox 注入 `today: () => TODAY`，**直接 mock 全局 `today()` 的返回值**，绕开 `state.me.space.timezone` 与真实 `new Date()`（比「固定 timezone + 固定 Date.now()」更彻底）；`dayNum/dayStr/periodData/cyclePhases/periodEpisodeOf` 全是 Web 原函数、未被 mock 覆盖。
- Dart 侧：`periodData(records, today: c['today'])`，从**同一份 `period_cases.json`** 读取。两侧同源、同一日期串、同一 UTC 解析口径；`todayPhase` / `dayInCycle` / `nextStartStr` 也都用同一固定 today。

**三组夹具在该 today 下的 `inWindow` / `dayOfPeriod`（Web 实跑期望值）**

| 组 | today | todayN | inWindow | dayOfPeriod | untilNext |
|---|---|---|---|---|---|
| ① multiCycle | 2026-11-14 | 20771 | false | 0 | -54 |
| ② singleNoGap | 2026-11-14 | 20771 | **true** | **5** | 27 |
| ③ fragmentMerge | 2026-11-14 | 20771 | false | 0 | -14 |

**「不同 today」补强**：组② 在 11-09 / 11-10 / 11-14 / 11-15 / 11-16 / 12-11 六个注入值下，Web 实跑得 `inWindow` = false/true/true/true/false/false、`dayOfPeriod` = 0/1/5/6/0/0、`untilNext` = 32/31/27/26/25/0，写入 `period_expected.json` 的 `todaySweep`（`meta.todaySweepMethod` 记生成方式，期望值非手算）；Dart 逐项断言全等，证明这三项**只由注入的 today 决定**，与真实时钟、设备时区无关。

**四阶段 key 逐字一致**：`cyclePhases():155-170` 的 `mark()` 用 `dayStr(n)` 作 map key（`:159`）、`ovu` 按 `dayStr(ovu)` 标记（`:164`）；Dart `cyclePhases` 完全同款 `map[dayStr(n)]`，对三组共 **469 个 `"YYYY-MM-DD"` key** 断言「key 集合全等 + 每天 `phase/predicted/ovu` 全等」，不用任何别的时间表示。

---

> **本轮交付（定案）**：调研稿转定案；**D1–D8 全部采纳清单推荐、不再复议**；
> 段 **8-A 随 2.2.1 / VC221 落地**（一 commit、一包、停等真机验收）；
> 对拍结论见附录 A、**C4 已关闭**；`flutter-plan-v2.md` 编号已同步。
> 后端 `app/` / `static/` / `android-app/` 零改动；B/C/D/E 段仍待主人逐段放行。
