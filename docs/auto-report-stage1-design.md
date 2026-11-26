# 自动报备第一段 · 设计盘点回执

> 对应令文 §三 1–7。**本文件不含任何代码改动**，仅为盘点与设计。
> 基线：main `270c014`（2.8.6）；门禁基线 pytest 370/2、flutter 1056/1、analyze 0。
> 蓝本「心邻 V3」方案包**未能在本工作区定位到**（`docs/` 下无该文件），因此本文设计
> 全部以**本仓代码事实**为据；蓝本相关的取舍点一律标注为「分叉·待蓝本比对」。

---

## 一、现有报备管线盘点

### 1.1 两条写入通道（**关键事实：状态事件必须选一条，不许新开第三条**）

| 通道 | 位置 | 结构 | 幂等 | 开关拒收 |
|---|---|---|---|---|
| `POST /api/peer/report` | `app/report_routes.py:45-81` | Pydantic `ReportIn`：`scene≤32`、`summary≤120`、`note≤500`、`place_name≤80`、`push:bool?`、`client_id≤64`、`ts:float?` | `peer.create_manual_report` 按 `(user, client_id)` 命中即返回 `created=false`（`app/peer.py:173-179`） | `events` 关闭 → **422**「报备事件共享已关闭」（`report_routes.py:50-51`） |
| `POST /api/peer/events`（批量） | `app/main.py:1947-1988` | `{events:[{id,type,ts,summary}]}`，单批 ≤ `EVENTS_BATCH_MAX=100`（`peer.py:33`） | 按 `id` 主键去重（`main.py:1966-1967`） | 同上 422（`main.py:1961-1962`） |

**重要发现**：批量通道 `/api/peer/events` 在 App 侧**从未被使用**（`grep "api/peer/events"` 只有 GET 与 ack，无 POST）。也就是说现在只有 `type='manual_report'` 一种事件，`source='manual'`。

写库动作统一在 `peer.create_manual_report`（`peer.py:156-209`）：`type='manual_report'`、`source='manual'`、写入 `scene/note/place_name/client_id`，并按 `push` 决定 `pushed` 与是否 `db.notice('peer_report')`。

### 1.2 事件存储字段（`peer_events`）

基础表 `app/db.py:206-212`：`id, user, type, ts, summary, pushed, created`。
增量列（`db.py:256-270`，additive 迁移范式）：`source, scene, note, place_name, client_id, ack_by, ack_emoji, ack_at`。

→ **没有 payload / JSON 列**，也没有 kind 之外的任何结构化槽位。这是本阶段唯一必须扩表的地方（见 §二）。

### 1.3 文件队列（`app-flutter/lib/core/peer/peer_report_queue.dart`）

| 能力 | 实现 |
|---|---|
| 存储 | 单个 JSON 文件 `{items:[...]}`，**tmp + rename 原子重写**（`:166-180`） |
| 入队去重 | 按 `clientId` 判重，重复不追加（`:181-188`） |
| 上限 | 超 `reportOutboxCap` 丢最旧（`:184-186`） |
| 冲刷 | 串行锁 `_flushing`，重入直接 `skipped`（`:203-205`） |
| 分类处理 | `ReportShareClosed`→丢弃并置 `closedOff`；`PeerApiException`→**毒丸出队**不卡后续；网络/5xx→**整批保留**含后续项并 break（`:222-236`） |

→ 这套「去重 + 毒丸 + 整批保留」正是令文要求复用的东西；**状态事件可以原样搭车，只需给 `PendingReport` 增两个可选字段**（见 §二·3）。

### 1.4 报备页渲染口径（`peer_report_page.dart`，544 行）

- 三段式：状态/概览段 → **今日事件流**（`_eventsSection` `:319`）→ 轨迹点数行（`:288`）。
- 事件行渲染分叉点已存在：`isManualReport => type == 'manual_report'`（`peer_report_api.dart:190`），**只有 manual_report 渲染报备卡与回应按钮，其余类型维持简行**（`peer_report_api.dart:189`）。→ 新增的状态事件天然落在「简行」分支，**不需要改渲染主干**。
- 三态齐备：加载中 `AppProgress`、失败带重试按钮（`Key('report-events-retry')` `:339`）、对方关闭共享明示（`Key('report-events-closed')` `:353`）。

### 1.5 四键消费点逐一列

| 键 | 位置 | 现状 |
|---|---|---|
| `location` | `peer.py:36` `SHARE_KEYS` | `GET /api/peer/status` 返回 `enabled/closed_off`（`main.py:2011-2019`）；App 侧驱动原生 `toggle` |
| `track` | 同上 | `GET /api/peer/track` 双侧 gating，关闭侧给 `closed_off`（`main.py:2029-2048`） |
| `events` | 同上 | **服务端两处 422 已有**（report / batch）；**客户端目前没有"停采"动作**（因为现在只有手动报备，无采集器） |
| `usage` | 同上 | **零消费**（`peer.py:8` 注释「一期建表，三期接入」；`grep peer_usage_daily` 仅建表 + 注释）→ 符合红线 3 |

→ 红线 4 要求「采集端停采 + 服务端拒收」双保险：**服务端那一半已经存在**，本阶段只需在采集端读开关后主动停。

---

## 二、事件 schema 设计

### 2.1 kind 命名（落在 `peer_events.type`）

统一 `state.` 前缀，与既有 `manual_report` / `sos` / `arrive_place` 并列不冲突，且为下一段分档留命名空间：

| kind | payload 字段 | 触发 |
|---|---|---|
| `state.battery` | `{level:int(0-100), charging:bool}` | 电量 Δ≥2% 或充电状态翻转 |
| `state.net` | `{net:"wifi"\|"cell"\|"none", ssid?:string}` | 网络类型切换 |
| `state.unlock` | `{count:int, window_sec:int}` | 端上窗口聚合 |
| `state.screen` | `{session_sec:int, on:bool}` | 亮屏会话结束/开始 |

**分档扩展位留法**（红线 5）：payload 内固定预留 `tier` 与 `policy` 两个键，**服务端不解析、原样透传**。下一段做分档时，只需采集端填值、呈现端读值，**schema 不再动**。

### 2.2 解锁与亮屏的聚合口径（分叉，给推荐）

- **解锁**：推荐**端上 10 分钟窗口聚合**（`{count:N, window_sec:600}`），不逐条。理由：真机日均解锁 60–120 次，逐条会把「今日事件流」刷成流水账，且用户真正关心的是「几点醒的 / 半夜起来几次」；聚合后日均 20–30 条，信息量不降。逐条的唯一好处是能画精确时间轴——本阶段不做时间轴（红线 5 不做分档/不做精细画像）。
- **亮屏**：推荐**双落点**——
  - 事件流只发**节点事件**（首次亮屏「醒了」、超长会话≥2h 结束）；
  - 日累计走**现成表** `peer_usage_daily.screen_sec / unlocks`（`db.py:213-219`，含 `updated`），这正是它建表的初衷（`peer.py:8`）。
  - ⚠️ 与红线 3 的边界：`usage` 开关与本阶段**无关**，本阶段只写 `screen_sec/unlocks` 两列，**`top_apps` 列一律不写、usage 开关不读不写**。若你认为「写 peer_usage_daily 也算预埋」，则退到方案 B（全走 peer_events 事件，日累计由服务端按 ts 求和）。

### 2.3 存储：复用还是加字段（分叉，给推荐）

- **推荐 A（加一列）**：`peer_events` 增 `payload TEXT NOT NULL DEFAULT ''`（JSON 字符串），沿用 `db.py:256-270` 的 additive 迁移范式；`serialize_peer_event`（`peer.py:127-150`）加一个 `payload` 键，旧行返回 `''`，App 解析容缺。
- 方案 B：把结构化数据塞进 `note`/`summary` 编码。**不推荐**：破坏语义、无法校验、展示与查询都得解字符串。

### 2.4 按日查询是否够用

`GET /api/peer/events?date=`（`main.py:2059-2097`）**够用于事件流**：已按空间时区切日、已含 `mine/peer` 双侧与 `closed_off`、已 `ORDER BY ts DESC`。
**不够用于「今日亮屏累计/解锁次数」**——那需要一条 `GET /api/peer/state-daily?date=`（或并入 `GET /api/peer/status` 返回今日汇总）。分叉：
- 推荐**新开一个只读 GET**（纯查询、无写入、不违反「不许新开上报通道」）；
- 备选并进 `/api/peer/status`（少一个端点，但会让 status 承担日历维度参数）。

---

## 三、最新状态快照设计

**结论：快照已经存在，不许再造第二套。**

`peer_location_latest`（`db.py:189-193`）已有 `battery, charging, net, wifi, updated` 五列，且原生定位上报**每次都会带这四项**（`PeerLocNative.kt:532-533` 与 `:608-609`，读取在 `:747-781`）。`GET /api/peer/status` 原样返回该行（`main.py:2001-2007`）。

→ 所以「对方当前状态（电量/充电/网络/最后活跃）」= `peer.location` 的现成字段，**App 侧一行都不用新增接口**。

**唯一要补的缝**：若用户只开 `events` 不开 `location`，则快照永不过期地停在最后一次定位上报。分叉：
- **推荐**：`state.battery` / `state.net` 写入时**顺带 UPSERT 快照的四列**（不动 `lat/lng/updated` 语义，只更新 `battery/charging/net/wifi` + 一个 `state_updated` 新列），这样「关了定位但开了状态」也能看到当前电量；
- 备选：不补缝，UI 明示「最后活跃来自定位，已 X 小时未更新」。

（若选推荐，需要新增一列 `state_updated REAL`，仍走 additive 迁移。）

---

## 四、原生采集设计

### 4.1 现状锚点

| 能力 | 现状 |
|---|---|
| 定时唤醒 | `AlarmManager` `setAndAllowWhileIdle` + `ELAPSED_REALTIME_WAKEUP`（`PeerLocNative.kt:57-62`） |
| 心跳 | `HEARTBEAT_MS = 5min`（`:849`），`STILL_HEARTBEAT_MS`（`:112`），`HEARTBEAT_ACTION` receiver（`:397-414`） |
| 定位节流 | `MIN_TIME_MS=15s` / `MIN_DISTANCE_M=25m`（`:108-109`） |
| 批量上行 | `BATCH_FLUSH_MS = 3min`（`:116`） |
| 电量/充电/网络读取 | 一次性 sticky 读（`:747-760`）+ `ConnectivityManager` 能力判定（`:762-777`）+ SSID（`:779-781`） |
| 前台服务 | **无**（PeerLocNative 不持有 FGS，靠 alarm + 部分唤醒锁） |

### 4.2 方案（动态 BroadcastReceiver + NetworkCallback，挂在现有生命周期内）

| 事件源 | 注册点 | 注销点 | 过滤/聚合 |
|---|---|---|---|
| `ACTION_BATTERY_CHANGED`（sticky） | `start()`（与 `heartbeatReceiver` 注册同一处，`:397` 附近） | `stop()`（`:414` 附近统一注销） | 记 `lastLevel/lastCharging`；`abs(delta)≥2` 或 `charging` 翻转才入队；**最小间隔 60s 防抖** |
| `ACTION_USER_PRESENT` | 同上 | 同上 | 进 10min 聚合窗口，窗口满或 `stop()` 时落一条 |
| `ACTION_SCREEN_ON/OFF` | 同上 | 同上 | ON 记会话起点；OFF 算 `session_sec` 入队 + 累加日累计 |
| `NetworkCallback`（`registerDefaultNetworkCallback`） | 同上 | 同上 | `onCapabilitiesChanged` 比对上一次 `net`；变化即入队，**最小间隔 30s**；SSID 冷却 5min |

**进程被杀后的恢复**：不新增常驻。重启后（下次 App 打开或 alarm 唤醒拉起进程）——
1. `ACTION_BATTERY_CHANGED` 是 **sticky**，注册即立刻回调一次 → 电量为**当前真值**，`state.battery` 立即正确；
2. 网络同理，`registerDefaultNetworkCallback` 注册后立刻回调一次当前网络；
3. 亮屏/解锁是**瞬时事件**，被杀期间丢失属设计内（不可回溯，也不该伪造）。

**与心跳/看门狗的关系**（不许互相打架）：
- **不新增任何 timer**：所有采集都挂在系统广播/回调上，心跳只负责「把待发队列 flush 出去」；
- 复用现有 `BATCH_FLUSH_MS=3min` 的 flush 节拍，**状态事件与定位点共用一次上行机会**（若选批量通道）或共用队列（若选 report 通道）；
- 看门狗（`HeartbeatGate`）语义不变：它管「采集是否还活着」，状态采集的存活与定位**同生共死**（同一 receiver 集合、同一 `toggle`），不出现两套存活判定。

### 4.3 采集端停采（红线 4 的另一半）

`toggle(false)` 或读到 `events=false` 时：注销全部状态 receiver + 清空聚合窗口（**不 flush**，防止停用瞬间还往外发一条）。服务端 422 是第二道保险。

---

## 五、节流与功耗预算

| 类 | 最小间隔 | 合并策略 | 静默期（23:00–07:00，按空间时区） |
|---|---|---|---|
| battery | 60s（Δ≥2% 或翻转） | 无 | **保留**（低电量/断电是夜间高价值信息） |
| net | 30s | 同类型重复事件丢 | **保留**（断网/联网） |
| unlock | 10min 窗口 | 窗口内计数 | **不发事件，仍本地累计**（避免暴露半夜起夜细节） |
| screen | 会话结束即发 | ≥2h 会话单独一条 | 同上 |

**日均事件量估算**（按真机中位使用强度）：
- battery 8–15（含充电翻转 2–4）
- net 3–8
- unlock 聚合 20–30（≈120–180 次解锁 / 10min 窗）
- screen 10–20（会话数）
→ **合计 40–75 条/日**；对比现状定位点 100–300 点/日，增量约 **+25%**，且状态事件单条 payload <100B。

**功耗目标 ≤5%/24h**：本设计**不新增唤醒源**（无 timer、无轮询、无 FGS），全部为已注册 receiver 的回调；网络回调与电池广播本身由系统驱动。预期增量远低于 1%，但**验收段仍需实测**（目标先挂在设计上，不当作已达成）。

---

## 六、App 呈现设计

### 6.1 报备页新增「对方状态」卡

位置：`peer_report_page.dart` 概览段（`_eventsSection` 之上）。字段：

| 字段 | 来源 | 兜底 |
|---|---|---|
| 电量 % + 充电态 | `status.peer.location.battery/charging` | 空 → 不显示该行（与「轨迹点数为空整行不显示」同口径 `:288`） |
| 当前网络 | `location.net`（`wifi` 时附 SSID，取不到降级 type-only） | 同上 |
| 最后活跃 | `location.updated` 相对时间 | 超过 6h 显示「长时间无更新」 |
| 今日亮屏 / 解锁 | 新 GET 日汇总（§二·4） | 拉不到 → 整段隐藏，不冒充 0 |

视觉：**App 自己的设计语言**——`AppProgress/AppEmptyView/AppErrorView` 三态组件（`lib/core/ui/`）+ `Spacing.gap` + `cardTheme`，**不抄蓝本原型**（红线 6）。

### 6.2 事件流简行样式

落在既有「自动事件简行」分支（`peer_report_api.dart:189-190`），每条：图标 + 一句话 + 相对时间。
文案示例：`22:41 电量 18%，已低于 20%` / `23:05 断开 Wi-Fi，切到移动数据` / `07:12 醒了（解锁 14 次）`。

### 6.3 采集状态可见（不许黑箱）

在「对方状态」卡底部加**自己一侧**一行：
- `采集中`（绿点）：events 开 && 原生 receiver 已注册（读 `PeerLocNative.status()`，`:267`）
- `已暂停 · 因为你关闭了「报备共享」`（灰点）：events=false
- `未授权 · 解锁/亮屏不可采`（黄点）：缺 `ACTION_USER_PRESENT` 所需能力（该项无需额外权限，但 SSID 需定位权限——缺权限时网络显示降级为 type-only）

---

## 七、预计测试面

| 侧 | 覆盖点 | 数量级 |
|---|---|---|
| 后端 | payload 形状校验（level clamp 0-100、net 枚举、count≥1）、events 关闭 422（两条通道各一）、client_id 幂等、日汇总 UPSERT、`GET state-daily` 口径、旧行容缺（payload='') | **12–16** |
| Flutter | 聚合器纯函数（Δ2% 阈值、翻转、10min 窗口、静默期规则）、队列复用（新字段往返 + 毒丸）、状态卡三态、简行渲染、采集状态文案 | **10–14** |
| 原生（JVM 单测） | 电量阈值判定、去重/防抖、SSID 降级 | **4–6** |

合计 **26–36 条**。施工段落地后：pytest 370 → **≈382–386**、flutter 1056 → **≈1066–1070**，analyze 保持 0；**既有用例一条不许删**。

---

## 八、需要你拍板的分叉（汇总，均给推荐）

| # | 分叉 | 推荐 | 备选 |
|---|---|---|---|
| 1 | 状态事件走哪条通道 | **`POST /api/peer/report` 扩 `payload`**（令文点名，且天然复用 client_id 幂等 + 文件队列） | 走未使用的批量 `/api/peer/events`（省一次扩字段，但 App 侧要新写一整套队列/去重） |
| 2 | 解锁/亮屏聚合 | **端上聚合 + 日累计落 `peer_usage_daily`** | 全量逐条进事件流 |
| 3 | 快照补缝 | **状态事件顺带 UPSERT 快照列 + 新列 `state_updated`** | 不补缝，UI 明示「最后活跃来自定位」 |
| 4 | 今日汇总接口 | **新开只读 `GET /api/peer/state-daily`** | 并进 `/api/peer/status` |
| 5 | 静默期 | **按上表分档执行**（unlock/screen 不发事件但仍本地累计） | 本阶段不做静默期，全部照发 |

> 分叉 1 是**唯一影响面最大的选择**：它决定「扩一个 Pydantic 模型」还是「新写一套批量队列」。我推荐前者的理由是——令文红线 1 明确点名 `POST /api/peer/report`，且该通道已有 client_id 幂等、422 拒收、文件队列三件配套，零发明成本。

---

——自动报备第一段设计盘点令完（请复述本行确认未被截断）——
