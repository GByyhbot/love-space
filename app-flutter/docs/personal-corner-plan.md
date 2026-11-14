# 条目 7「个人角落」Flutter 迁移清单（定案）

> 2026-11-14 调研并定案。契约全部实读核实（行号见下「契约行号」章节）；
> 三段版本位已定：7-A（2.1.7/VC217）、7-B（2.1.8/VC218）均已验收，
> **7-C（2.1.9/VC219）本段交付**（条目 7 收尾段，之后无后续段）。

## 三段定稿表

| 段 | 内容 | 版本位 | 状态 |
|---|---|---|---|
| 7-A | 页面骨架 + 私密日记 + 草稿箱（列表/新建/编辑/删除/草稿发布） | 2.1.7 (VC217) | ✅ 已验收 |
| 7-B | 定时惊喜（publish_at 交互 + 揭示态）+ 回收站（列表 + 恢复）+ 删除文案统一标准口径 | 2.1.8 (VC218) | ✅ 已验收 |
| 7-C | 个人心愿（专属端点、密码唯一、解锁流、三态、隐私红线） | **2.1.9 (VC219)【本段】** | ✅ 本段交付 |

- **个人心愿入口 = 个人角落页第五个 tab（7-C 已落地）**。7-A 上 diary / draft
  两个 tab，7-B 增补 surprise / trash 共四个 tab，**7-C 增补 personal_wish
  共五个 tab**，本段即条目 7 收尾段，**之后无 7-D、无死卡**（Web 能点的 App
  才有去向）。本段之前不预置 7-C 空卡，落地时一次性扩表 + 补 IndexedStack 页。
- **新建表单口径：日记/惊喜用简洁表单、草稿箱对接正式 composer（不另造编辑器）**。
  7-A diary 用页内简洁表单（多行 content 必填）；草稿「继续编辑」「写一份草稿」
  直接 `showComposerSheet`，编辑态保持 kind=draft；7-B 的 surprise 用页内简洁表单
  + 发布时间选择器，同样不走 composer。
- 表单 / 编辑 / 发布选择等二级页一律 `context.push`（AppBar 自动返回按钮 +
  系统手势都能回上一页）；壳层 IndexedStack 常驻，tab 间切换不丢状态。
- 每段照例：契约先核实 → 一段一提交 → 停等真机验收；自测夹具含**真实存量形状
  样本**。NAS 容器 `/data/love.db` 实测：**draft 8 条 / 已删除记录 17 条**
  （post 6、draft 7、album 1、anniversary 1、question 1、music 1）为真实存量形状；
  **diary、surprise 库里实测 0 行**，按 Web composer（app.js:1807-1830）+
  clean_body（main.py:930-934）等价 serialize_many 形状推导，来源在
  `test/personal_a_test.dart:11-18` / `test/personal_b_test.dart` 头注释与本文档
  双处注明。主人已拍板**接受此例外**，不造数据、不写生产库。

## 页面定位

Web `personalPage`（app.js:1484）：heading「我的小角落 · 有些心事留给自己，有些惊喜留给未来」
+ 四 tab（diary 私密日记 / draft 草稿箱 / surprise 定时惊喜 / trash 回收站）。
settings tab 在 Web 里同页（tab==='settings' 时渲染 settingsPage）——**App 侧设置页已独立落地，不迁**。
App 入口 = 壳层 BottomAppBar 第 5 个 tab「角落」（IndexedStack 第 5 页）。
🔴 **7-C App 入口差异（主人拍板，保留说明避免下段误解）**：
Web 把个人心愿放在「我们」页工具卡 `toolsList`（`app.js:1219` 的
`['personal-wish','💝','个人心愿',…]`，`app.js:1229` `toolsList.map(...)` 渲染
`data-action="tool-personal-wish"` 工具卡，`app.js:1222`
`togetherPage()` 的 `state.tab==='personal-wish'` 分支调 `personalWishPage()`）；
而 Web 的 **个人角落 `personalPage()` 只有 4 个 tab**（`app.js:1485`
`tabs=[['diary','私密日记'],['draft','草稿箱'],['surprise','定时惊喜'],
['trash','回收站']]`，无 personal-wish）。App 按 7-A 定案放**个人角落第五个
tab**，`personalTabs` 第 5 项 `id:'personal_wish'`。两侧文案/交互逐字对齐，
仅入口位置不同；这是 App 与 Web 的结构差异，不是漏迁。
Web `recordsOf('personal_wish')`（app.js:95）只按 kind 过滤、**不按 author**，
`refreshData()`（app.js:263-272）的 kind 串 = `Object.keys(kindLabel).join(',')`
含 personal_wish（app.js:92）→ 双方都能拉到列表，与服务端可见性一致。
Web 回收站**只有「恢复这份回忆」一个动作，没有「彻底删除」**（app.js:1488/2524
全文实读无 purge / delete-forever）→ App 不自创彻底删除入口。

## 四 tab 契约（7-A + 7-B）

### ① diary 私密日记
- 列表：`GET /api/records?kind=diary,draft,surprise`（7-B 起显式 kind 串
  `personalKinds`，客户端按 r.kind 分流各 tab；main.py:1156 的隐式排除只作用于
  **非 trash 且不带 kind** 的 else 分支）。
- 顶部 hint（app.js:1489，diary/draft 同句）：「这个角落只有你能看见。草稿主动发布后，才会进入共同空间。」
- 空态：「给自己，留一点心里话」+「慢慢写，不着急。」；入口按钮「开始记录」。
- 新建：POST /api/records kind=diary，body.content 必填（main.py:1107）：
  `{content, date, media: []}`，client_id 幂等。
- 编辑：PUT /api/records/{rid} 全量 body，**回填铁律**（mergeRecordBody，以原 body
  为底只盖 content）。
- 删除：DELETE /api/records/{rid}（main.py:1424 软删）；确认弹层文案
  **7-B 起统一标准口径**「删除后会进入回收站，30 天内可以恢复。」
  （与共享类 post_card.dart:271 逐字一致；7-A 的「不进回收站、不可恢复」临时
  口径已作废）。

### ② draft 草稿箱
- 列表：同上（显式 kind 串）；**顶部 hint 与 diary 同句**（app.js:1489）——
  「这个角落只有你能看见。草稿主动发布后，才会进入共同空间。」；
  「还没写完的故事，在这里等你」是 **draft 空态标题**（不是提示文案），
  空态副文案「慢慢写，不着急。」；入口按钮「写一份草稿」。
- 🔴 content 必填集合（main.py:1107）为 `{post,diary,surprise,note,chat}`，
  **不含 draft**——空内容草稿服务端允许；草稿走 composer 的 `_saveDraft()`
  已有「（草稿）」占位，**不给草稿加 content 必填校验**。
- 「写一份草稿」→ `showComposerSheet(context)`（composer 内「存草稿」→ POST kind=draft）。
- 「继续编辑」→ `showComposerSheet(context, editRecord: <转换的 Record>, editKind:'draft')`；
  composer 编辑态 PUT 保持 kind=draft（timelineController.editRecord 加 kindOverride，
  不另建编辑器）。
- 「发布」→ 三选一（post / diary / surprise）→ PUT /api/records/{rid} 改 kind
  （main.py:1400：仅 draft 可改），**必须 merge 原 body**；选 surprise 额外收集未来
  时间（main.py:1127：body.publish_at 为未来时间戳否则 422），选 post/diary 不带
  publish_at。发布成功后本地移除草稿；发布为 diary 移入日记列表。
- 删除：**7-B 起统一标准文案口径**（进回收站、30 天可恢复），同 diary。

### ③ surprise 定时惊喜（7-B 落地）
- 列表：同 [personalKinds] 显式串（含 surprise），按 r.kind 分流；**只呈现作者
  自己的**（服务端 db.visible + serialize 404 保证；客户端带 author 加固 +
  二次按 author 过滤）。NAS 实测 surprise 0 行，夹具按等价形状推导并双处注明。
- 顶部 hint（app.js:1489，逐字）：「到约定的时间，惊喜才会被另一半看见。」
  空态「提前准备一份温柔的惊喜」+「慢慢写，不着急。」；入口「准备惊喜」。
- 列表行呈现**待揭示 / 已到约定时间·等待公开**状态与 `publish_at` 格式化时间。
- 新建：POST kind=surprise，`{content, date, media: [], publish_at}`；
  **publish_at 必填且为未来 epoch 秒数值**，契约窗口
  `now < publish_at < now + 50*366*86400`（main.py:1127-1130），否则 422
  「请选择未来的公开时间」——**服务端 422 原文经 api.errorDetail 透传到顶部通知 +
  表单内联错误态双呈现，绝不静默失败**（客户端同窗口先校验）。
- 编辑（含改期）：PUT 全量 body，**回填铁律**（mergeRecordBody 只盖 content /
  publish_at）；kind 保持 surprise（否则 main.py:1132 会 pop 掉 publish_at）。
- 🔴 **揭示机制（服务端，实读 worker.py:225-235）**：定时任务 `schedule()`
  扫描 `deleted IS NULL` 记录，若 `kind=='surprise' && publish_at <= now()`，
  则 `UPDATE records SET kind='post', body=<去掉 publish_at、加 was_surprise=true>,
  published=now(), updated=now()` 并推送「有一份为你准备的惊喜公开了」通知。
  即**揭示后记录不再是 surprise，而是 post**：揭示前 db.visible 对 PRIVATE
  只放作者（对象端任何页面不可见）；到点后以 post 出现在双方时光列表。
  客户端**绝不把 surprise 缓存进共享列表（timeline/together 控制器）**，
  只按服务端返回结果呈现，不自行制造泄露路径。
- 删除：**标准口径**（进回收站、30 天可恢复），与 diary/draft 统一。

### ④ trash 回收站（7-B 落地）
- 列表：`GET /api/records?trash=true&kind=<Web 全 kind 串>`（app.js:468
  `Object.keys(kindLabel).join(',')`；`trashKinds` 逐字含 17 个 kind，
  **含 diary/draft/surprise 三类私密**，对齐主人「甲·对齐 Web」定案）。
  服务端 trash 分支强制 `author=自己 AND deleted IS NOT NULL`
  （main.py:1150-1152），客户端仍带 author 加固 + 二次过滤（fail-closed），
  绝不混入他人条目；`period` 分库由服务端 `merge_period` 合并。
- 顶部 hint（app.js:1488，逐字）：「删除的内容保留三十天，你可以恢复自己的记录。」
  空态「回收站是空的」+「你的回忆都在好好保存。」；**无新建入口**。
- 每条：`kindLabel[kind] · ${dateLabel(deleted)} 删除`（TogetherRecord.deleted
  由序列化顶层字段解析），按钮「恢复这份回忆」（app.js:1488 逐字）→
  `POST /api/records/{rid}/restore`（main.py:1443；period 分库由服务端
  `period.get(rid, include_deleted=True)` 分流，客户端统一调用）。
- 🔴 **恢复语义核实结论（G5 既定语义，实读）**：
  · 恢复一条 `post`：`UPDATE records SET deleted=NULL,updated=?`（main.py:1450）
    → 回到双方时光列表；App 侧显式 `resetAfterPublish()` 触发时光重拉
    （timeline 的 SSE 监听有 active 门控、IndexedStack 切回不触发 load）。
  · 恢复一条 `diary`/`draft`：同上，回到个人角落对应 tab（仅本人可见）。
  · 恢复一个 `album`：**原照片的归属回不来**——删除相册时 main.py:1434-1439
    会遍历所有非私密记录把 `body.album` 清空，而 restore 只清 `deleted`、
    **不回写那些记录的 album 字段**。这是服务端既定语义（G5），App 不做补偿。
- 🔴 **不实现「彻底删除」**：Web 全文无该动作，按「对齐 Web」不自创。

### 跨账号隐私
- main.py:1156 `kind NOT IN ('diary','draft','surprise')` 只在**非 trash 且不带 kind**
  的 else 分支；`db.visible` 对 PRIVATE 类只放作者（db.py:377），main.py:1196
  逐条过滤，serialize 对非作者私密记录直接 404。
  **跨账号隐私由服务端保证**；客户端额外带 `author=<当前用户 id>` 加固并二次按
  author 过滤，绝不渲染越权数据。

### 删除口径（Web 现状 / 主人定案对齐 Web / 7-B 已落地）

1. **Web / 后端现状（实读，非旧版错误推论）**：main.py:1150-1156 的
   `kind NOT IN ('diary','draft','surprise')` **只作用于非 trash 且不带 kind 的
   else 分支**；trash 分支只加 `author=? AND deleted IS NOT NULL`，**不排除私密类**。
   static/app.js:468 回收站请求的 kind 串是 `Object.keys(kindLabel).join(',')`，
   而 kindLabel（app.js:92）**包含** diary/draft/surprise；main.py:1443 restore
   也不区分 kind。→ **Web 现状：本人删掉的私密日记/草稿会进回收站并可 restore**。
   🔴 旧版文档曾写「trash 分支排除私密三类、私密类删除后不出现在回收站」，
   是**事实错误**，已订正；此结论与 7-B 的 `trashKinds` 实现一致。
2. **主人定案 · 对齐 Web（2026-11-14 12:10，作废此前「App 内收紧」）**：
   回收站 kind 串与 Web 一致，含 diary/draft/surprise，仅本人（服务端 trash
   分支强制 `author=自己 AND deleted IS NOT NULL`）；restore 与 Web 一样可用。
   7-A 的删除文案「不进回收站、不可恢复」为**临时口径**，随 7-B（2.1.8）改回
   标准口径，**不单独出返修包**。
3. **7-B 已落地（2.1.8）**：`trashKinds` 与 Web 全 kind 串逐字一致（17 类，
   含私密三类），提供「恢复这份回忆」→ `POST /api/records/{rid}/restore`；
   `privateDeleteText` 已改回标准口径「删除后会进入回收站，30 天内可以恢复。」，
   日记 / 草稿 / 惊喜三类与共享类统一；**后端零改动**。
   Web 无「彻底删除」，App 不自创。

### 回填铁律根因（实读证据）
- main.py:925 `clean_body(c, kind, data, user_id, previous=None)` 的 `previous`
  参数在函数体**完全未使用** → PUT 服务端**不 merge**，`cleaned` 就是客户端传来
  body 的全量替换。所以客户端编辑/发布/改期必须以原 body 为底逐键复制
  （mergeRecordBody），未知字段也要原样带回；代码 merge 处留注释。

## 7-C 已落地 + 契约实读结论（2.1.9/VC219 · 个人心愿，条目 7 收尾段）

> 本段是全迁移**唯一走专属端点**的功能。动手前按主人要求逐项实读
> `app/serializers.py:15-40`、`app/main.py:914-918 / :921-922 / :1306-1365`、
> `app/security.py:193-206`、`app/db.py:343-352`、`static/app.js` 的
> personalWishPage / personalWishForm / unlockPersonalWish / personalWishCard /
> toolsList / delete-record / new-personal-wish / unlock-personal-wish，
> 结论全部落在下面。与 7-B 交付时的预核一致，无不符处（细化见各节）。

### ① 可见性（双方都能拉到列表）

- `app/db.py:343` `PRIVATE = {'diary','draft','surprise'}`，**personal_wish 不在内**；
  `:352` `ENCRYPTED = PRIVATE | {'period'}` 也不含它 → stored body 是明文 JSON，
  但 `serialize` 会**整体重建** `result['body']`。
- `:348-349` `VISIBLE_SQL` 由 PRIVATE 派生；`:377` `visible()` 对非 PRIVATE
  直接 `return True`，不拦非作者。
- `app/main.py:1155-1159`：不带 kind 时的隐式排除**只在 `if not kind` 分支**；
  显式 `kind=personal_wish` 走 `kind IN (...)`，`:1196` `db.visible` 不拦。
- `app/serializers.py:18-19` 只对「PRIVATE 且非作者」抛 404；personal_wish
  分支另走重建，**不对非作者抛 404**。
- 🔴 结论：**双方都能拉到列表（对方见锁态标题）**，这与 diary/draft/surprise
  根本不同。客户端**绝不能带 `author=` 参数、绝不能二次按 author 过滤**，
  否则会丢掉对方的心愿。Web 侧同款：`app.js:95` `recordsOf = kind =>
  state.records.filter(r=>r.kind===kind)` 无 author 过滤；`app.js:263-272`
  `refreshData()` 的 kind 串含 personal_wish。

### ② 三态序列化字段表（`GET /api/records?kind=personal_wish` 实读）

`serializers.py:23-36` 逐行：先把 `result['body']` 重建为
`{'title': stored.get('title',''), 'locked': True}`；再按身份决定
`sealed_for_me = stored.get('owner_sealed') if author else readers.get(user_id)`，
若存在则 `open_sealed(...)` 得到明文 `content` 并改为
`{'title', 'locked': False, 'content': 明文}`；最后 `if author:` **无条件**
追加 `result['body']['sealed'] = stored.get('sealed', {})`。

| 视角 | `body` 实际下发字段 | 说明 |
|---|---|---|
| **作者本人**（有 `owner_sealed`） | `{title, locked:false, content, sealed}` | `content` = `open_sealed(owner_sealed)` 明文；`sealed` 是**凭密码解密用的密文副本**，Web 卡片不呈现 |
| **对象已解锁**（`readers_sealed[uid]`） | `{title, locked:false, content}` | 无 `sealed`；首次正确密码后服务端写 `readers_sealed`，永久可见 |
| **对象未解锁** | `{title, locked:true}` | **content 不下发**，只有锁态标题 |
| 作者退化态 | `{title, locked:true, sealed}` | `open_sealed` 抛 HTTPException 时 :33-34 退化为锁定态，但 :35-36 的 `if author:` 仍**无条件**追加 `sealed` |

- `password_hash` / `owner_sealed` / `readers_sealed` / `unlocked_by` 等 stored
  字段随 `result['body']` 整体替换，**客户端拿不到**。
- 🔴 **超出 Web 呈现范围的字段 = `sealed`（密文）**：它不是 `content`、不是
  `title`、不是 `locked`。客户端**不许渲染、不许缓存、不进日志/通知/搜索**。
  `parseTogetherRecords` 会把 body 整包带进客户端，故
  `personal_controller.dart` 在数据层用 `sanitizeWishBody()` **无条件收敛**
  为 `{title, locked, content?}` 三键（`locked` 时连 content 都丢），
  `personal_page.dart` 的 `_WishTile` 渲染层同样只取三键并留注释。
  注意「无条件」这点：不能只在「open 态」过滤，作者退化锁定态也带 sealed。
  🔴 **边界（QA 独立复核标为最高风险）**：净化必须挂在**数据解析边界**
  （`loadWishes()` 对每条记录无条件调用 `sanitizeWishBody`），**绝不能挂在
  `locked==false` / open 分支上**：`open_sealed` 抛异常退化成 `locked:true`
  时照样带 `sealed`，若只在 open 态过滤就会让密文进缓存。客户端不实现任何解密。

### ③ 专属端点契约（逐条实读）

**输入模型**（`app/main.py:914-922`）
- `PersonalWishInput`：`title` 1-100、`content` 1-20000、`password` 6-128、
  `client_id` 可选 ≤100。
- `PersonalWishUnlockInput`：`password` **1-128（不是 6）** → 客户端解锁页
  不套创建页的 ≥6 校验，只对创建做 6..128。

**创建 `POST /api/personal-wishes`**（`main.py:1306-1332`）
- `title/content/password` 三者 `.strip()` 后任一为空 → 422
  「请填写心愿名称、具体内容和独立密码」。
- `client_id` 幂等：命中作者已有记录时，若 `kind != 'personal_wish'` → 409
  「请求标识已被其他记录使用，请重新提交」；否则直接 `serialize(existing)` 返回。
- 🔴 **密码唯一是空间级约束**：`:1320-1323` 遍历
  `SELECT body FROM records WHERE kind='personal_wish'`（**无 author 过滤**，
  含对方的心愿）的 `password_hash` → 撞已用密码 422
  「这个密码已经用于另一条个人心愿，请为每条心愿设置不同密码」。
- stored = `{title, sealed: personal_wish_encrypt(password, content),
  owner_sealed: seal_for_owner(content), password_hash: password_hash(pw, 6)}`；
  初始**没有** `readers_sealed`。发通知「对方许下了一份个人心愿」。
- 客户端：**先拦空 + 拦 Field 越界**（`title` 1..100 / `content` 1..20000 /
  `password` 6..128，对齐 Web `minlength=6` 与 Pydantic Field 约束）再发请求；
  `client_id` 用 `newChatClientId()`；撞密码 422 原文经 `api.errorDetail` 取
  `detail`，**顶部通知 + 表单内联双呈现**，绝不吞。成功后重拉 wishes、
  toast「这份个人心愿已加密保存」。
  🔴 **QA 增量 · 必须挡住 Field 校验型 422**：`main.py:914-918` 的
  `Field(min/max)` 越界时 `detail` 是**英文数组、无中文**，而
  `api_client.dart:289-302` 的 `errorDetail()` 会把数组 `toString()` 成一坨
  英文结构化文本。客户端不先拦越界就会把英文糊到用户脸上。先拦之后，
  服务端回的全是手动抛的中文原文（422 空字段 / 422 撞密码 / 409），
  `errorDetail` 才能逐字透传。校验放在 `addPersonalWish()` 控制器层
  （UI 的 `TextField.maxLength` 之外再兜一层），并发夹具断言越界一律
  **0 请求**。

**解锁 `POST /api/personal-wishes/{rid}/unlock`**（`main.py:1335-1365`）
- `get_record` 后 `kind != 'personal_wish'` → 404「心愿不存在」。
- 作者本人（`owner_sealed`）或已解锁者（`user.id in readers`）→ **免密直返**
  `{content: open_sealed(...)}`，不要求密码正确。
- 错密码：`:1350-1352` **先** `rate_limit(request,
  'personal-wish-unlock:%s:%s' % (rid, user['id']))` **再** 403
  「密码不正确，请向心愿本人确认」。key 带 rid + 用户 id → 配额是
  「每条心愿·每人」独立，两人共用出口 IP 不互相挤占；且 rate_limit 在 403
  之前调用，第 21 次错密码才转 429。
- `app/security.py:193-206` `rate_limit(limit=20, window=900)` →
  `minutes = max(1, 900//60) = 15` → 429「尝试过于频繁，请 15 分钟后再试」。
- 正确密码：解密 `personal_wish_decrypt(password, stored['sealed'])`；作者
  补 `owner_sealed`，非作者写 `readers_sealed[uid]` + `unlocked_by`；
  `UPDATE records SET body=?` 后返回 `{content}` → **解锁一次永久可见**。
- 客户端：403 / 429 服务端文案**原样**双呈现（表单内联 + 顶部通知）；
  成功后**重拉列表确认状态**，不自己记解锁态、不本地缓存 content；
  请求中按钮禁用（`_unlocking`）、**不自动重试、不连点叠加请求**。
  QA 实读补充：首错即计数、**前 20 次错密码都是 403，第 21 次才转 429**
  （`rate_limit` 在 403 之前调用）；key = `personal-wish-unlock:{rid}:{uid}`
  + `client_ip`，每条心愿每人独立配额。客户端**不模拟计数**，只把服务端返回的
  码与原文如实呈现。解锁页**只拦空**（`UnlockInput.min_length=1`，不是 6），
  绝不套创建页 ≥6 校验，否则会拦掉合法短密码。

**通用编辑禁止**（`main.py:928-929`）
- `clean_body` 对 `personal_wish` 明确 422「个人心愿请使用专属加密接口保存」
  → **禁止 PUT 改**，Web 无编辑、App 不加编辑入口。

### ④ Web 交互逐项对齐（不自创流程，逐字）

| 项 | Web 原文 / 位置 | App 落地 |
|---|---|---|
| 页头 heading / 副标题 | 「个人心愿」/「写下的人可以直接回看，对方输入一次密码后就能一直看到。」`app.js:1302` heading 前两参 | 全局页头「我的小角落」+ 第 5 tab 标签「个人心愿」；副标题用 `personalWishSubtitle` 常量在 tab 内逐字呈现 |
| 顶部 hint | 「心愿名称彼此可见。密码至少 6 位（建议纯数字），每条心愿都要不同；告诉对方后，对方解锁一次即可永久查看。」`app.js:1302` | `personalTabs[4].hint` 逐字 |
| 空态 | 「留一份只差密码就能打开的心愿」/「对方能看见心愿名称，具体内容仍由你掌握。」/「许下第一份心愿」`app.js:1302` | `_TabFrame.emptyTitle / emptyHint / emptyEntryLabel` |
| 入口按钮 | 「许下心愿」`app.js:1302` | `_WishTab.entryLabel` |
| 创建弹层标题 | 「许下一份个人心愿」`app.js:1801` | `PersonalWishFormPage` AppBar 标题 |
| 创建三字段 label | 「心愿名称（对方可见）」「具体心愿内容（需要密码才能查看）」「这条心愿的独立密码」`app.js:1801` | 三个 `TextField` 的 labelText 逐字；password `minlength=6/maxlength=128` |
| 创建说明 | 「每条心愿都要设置不同密码。写下心愿的你可以直接回看内容；把密码告诉对方后，对方输入一次就能看到，之后不必再输。忘记密码无法找回。」`app.js:1801` | 表单说明文字逐字 |
| 创建按钮 / 成功 toast | 「加密保存」/「这份个人心愿已加密保存」`app.js:1801` | 按钮文案 + `_toast` okMsg 逐字 |
| 解锁弹层标题 / meta | 「打开这份个人心愿」/「「${title}」的内容已加密，请输入心愿本人交给你的密码。」`app.js:1802` | `PersonalWishUnlockPage` AppBar + meta 逐字 |
| 解锁 label / 按钮 / 成功 toast | 「心愿密码」/「解锁心愿」/「已解锁，内容现在直接显示在心愿卡片里」`app.js:1802` | 逐字 |
| 卡片归属 | own「你的个人心愿」/ 对方「TA的个人心愿」`app.js:2009` | `_WishTile` 逐字 |
| 卡片状态 small | 已解锁「已解锁 · 内容只有你们两人能看见」/ 未解锁「具体内容已加密保存」`app.js:2009` | 逐字 |
| 未解锁占位 | own「这是你写下的个人心愿，输入密码即可回看内容。」/ 对方「TA 留了一份心愿给你，输入一次密码后就能一直读到内容。」`app.js:2009` | 逐字 |
| 解锁入口按钮 | 「输入密码查看」`app.js:2009`（`unlock-personal-wish`，`app.js:2512`） | 逐字；`context.push('/personal/wish-unlock')` |
| 错误呈现 | `form-error` 表单内联（`app.js:1801/1802` catch → `$('.form-error',form).textContent=err.message`） | `_error` 内联 + `chatToastProvider.show(..., tone: error)` 顶部通知**双呈现**（沿用 7-B `SurpriseFormPage` 模式） |
| 删除 | 仅作者卡片菜单「删除」→ `data-action="delete-record"` `app.js:2523` → `del('/records/'+id)` **通用 DELETE** | `confirmPrivateDelete(..., wish: true)` → `deleteWish()` → `DELETE /api/records/{rid}` |

`app.js:2511` `action.startsWith('new-')` 分支把
`new-personal-wish` 单独分派给 `personalWishForm()`（不走通用 `recordForm`），
`:2512` `unlock-personal-wish` 分派给 `unlockPersonalWish(id)` → 专属端点流程
**实读确认**，App 不自创创建/编辑/解锁路径。

### ⑤ 编辑 / 删除核实结论

- **Web 无编辑**：`personalWishCard`（`app.js:2009`）卡片头只有 own 的
  `card-menu` → 「删除」，全文无「编辑」按钮；通用 `recordForm` 也不接
  personal_wish（`:2511` 分流到 `personalWishForm`）。服务端 `clean_body`
  `:928-929` 明确 422 禁止 PUT 改。→ **App 不加编辑入口、不发 PUT**。
- **Web 有删除、走通用路由**：`app.js:2523` `action==='delete-record'` →
  `confirmAction('暂时收起这份回忆？', …)` → `del('/records/'+id)`，
  即 `DELETE /api/records/{rid}`（服务端 main.py:1424 软删），不是专属端点。
  → App 用 `deleteWish()` 走同一通用 DELETE，成功后重拉 wishes + trash。
- **Web 删除弹层原文**是「暂时收起这份回忆？」+「记录会进入作者的回收站，三十天内可以恢复。」；
  App 按 7-B 主人定案（「甲·对齐 Web」）统一用 `privateDeleteText`
  「删除后会进入回收站，30 天内可以恢复。」，与日记/草稿/惊喜/共享类一致。
  **这是经拍板的已知文案差异**，不是 bug。
  🔴 **7-C 口径裁定（主人/team-lead 2026-11-14，QA 已同步改判据）**：
  QA 验收矩阵⑧原要按 Web `app.js:2523` 逐字断言 Web 弹层文案；**已裁定按
  App 7-B 定案走**——直接复用现有 `confirmPrivateDelete()`（弹层标题
  「删除这条记录」+ 内容 `privateDeleteText`），**不新造弹层、不按 Web 逐字
  改文案**。理由：主人 7-B 明确要求三类删除文案统一标准口径且已随 2.1.8 包
  落地，7-C 是条目 7 内一段，沿用 App 统一口径。删除动作本身仍是通用
  `DELETE /api/records/{rid}`（不是任何专属端点），仅作者可见「删除」。
  Web 全文无「彻底删除」，App 不自创。

### ⑥ 隐私红线（本段最高优先级）

1. **未解锁 content 不得出现在客户端任何地方**：列表 / 缓存 / 通知 / 搜索。
   服务端未解锁态本就不下发 content；客户端 `sanitizeWishBody` 对
   `locked==true` **连畸形塞进来的 content 也丢掉**，渲染层再兜一层。
2. **超出 Web 呈现范围的字段（作者额外下发的 `sealed` 密文）**：不渲染、
   不缓存、不进日志/通知/搜索。数据层无条件收敛三键 + 渲染层只取三键，
   双处注释说明；`PersonalState.wishes` 里不会存在 `sealed`。
3. **密码只在请求里过一遍**：不落本地存储、不进日志、不进任何缓存；
   `TextField` controller 用完 dispose，**不设 `autofillHints`**（避免系统
   密码管理器落盘），不打印。加解密全在服务端
   （`personal_wish_encrypt` / `seal_for_owner` / `open_sealed`），
   客户端**不实现任何加密**。
4. **不记解锁态**：服务端写 `readers_sealed` 后，客户端重拉列表确认，
   不本地缓存 content、不本地标记「已解锁」。
5. **换号不串**：`_boundUserId` 机制覆盖 wishes —— `build()` 的
   userChanged 兜底、`ref.listen(personalCurrentUserProvider)` 回调、
   `bootstrap()` 三条路径都 `_wishSeq++` + 清空 + 重拉；`logout()` 的
   `ref.container.invalidate(personalControllerProvider)` 把
   `records / trash / wishes` 三路 state 一并归零（auth_state.dart 已加注释确认）。
6. **失败兜底**：uid 为空时 `loadWishes()` / `wishes()` 都 fail-closed
   不渲染任何内容；但 **personal_wish 与 PRIVATE 不同，不套「仅本人可见」**
   逻辑（不按 author 过滤）。

### ⑦ 数据层 / 页面落地（防串防漏）

- **不复用 `personalKinds`**：那是 `diary,draft,surprise`，服务端对不带 kind
  隐式排除 + `load()` 带 author 且二次按 author 过滤，复用会丢掉对方心愿。
  新增顶层常量 `personalWishKinds = 'personal_wish'`、独立
  `PersonalState.wishes`、独立 `loadWishes()`
  （`GET /api/records?kind=personal_wish&limit=1000`，**不带 author**）、
  独立 `_wishSeq`。
- 三态视觉可辨：作者免密（own + `locked:false` + content 直显）、
  对方已解锁（TA + `locked:false` + content 直显）、待解锁
  （`locked:true` + 占位文案 + 「输入密码查看」）。作者态列表恒下发 content，
  **免密直达、不发额外请求**；仅「对方待解锁」出现解锁入口
  （避免作者误发 unlock 请求）。
- 二级页一律 `context.push`，在 `lib/main.dart` 注册
  `/personal/wish-form`、`/personal/wish-unlock` 两条路由；
  不用 `go` / `pushReplacement`。AppBar 自动返回 + 系统手势都能回上一页。
- 🔧 支撑修正：`loadTrash()` 的响应序号检查由误用的 `_reqSeq` 改回自己的
  `_trashSeq`。7-C 起 `loadWishes()` 会独立自增 `_wishSeq`，三者不再同步
  递增，若继续按 `_reqSeq` 比对，删除心愿后的 `loadTrash()` 会被误判为
  「旧响应」而静默不更新回收站。与 7-B 注释「load 与 loadTrash 互不误杀」
  的设计一致，后端零改动。

### ⑧ 自测夹具来源（真实存量 + 序列化后形状）

- 2026-11-14 SSH 只读直查 NAS 容器 `love-space:/data/love.db`
  （`.workbuddy/deploy.py` 的 `connect()/run()`，`SSH_PASS` 仅环境变量、
  临时脚本用完即删；**未写库、未造数据、未打印密文**）：
  `personal_wish` 实测 **2 行**
  · `id=b2c7d2a1f5b344dfabbf50c8d96c1fb3` / `author=c7e5070e0f0a467dbc2e13d677ca8612`
    / `created=1791195587.7337775` / `title=「最想完成的事」`
  · `id=9ce5acfad9e04baaa8d5bdb50bb70a0f` / `author=b7572733c5d540f0bf2379bb06f35206`
    / `created=1793635924.9610257` / `title=「回🏡了」`
  · 两条 stored body keys 实测均为 `[owner_sealed, password_hash, sealed, title]`，
    都还没有 `readers_sealed`（对方未解锁）；两条分属不同 author，正好印证
    「双方心愿都要显示」。
- 🔴 客户端实际收到的是 **serialize 重建后的 body**
  （`{title, locked, content?, sealed?}`），**不是 stored 原文**。
  `test/personal_c_test.dart` 的夹具按序列化后三态形状构造，以两条真实行的
  id/author/created/title 为底，`readers_sealed` 分支（已解锁态）为等价推导；
  推导依据写在 `test/personal_c_test.dart` 文件头与本文档双处。
  作者态额外注入 `sealed` 密文 / 畸形 `password_hash`/`owner_sealed`、
  锁定态额外注入畸形 `content`，专门验证「不渲染 / 不缓存 / 不进日志」。
  与 7-A diary / 7-B surprise 的「真实存量 + 等价形状」处理一致，
  主人已接受此例外，**不造数据、不写生产库**。

### ⑨ 后端隐私佐证（QA 独立实读补录）

- **stored 原文没有明文 `content` 键**：NAS 实测两条 personal_wish 的 stored
  body keys 均为 `[owner_sealed, password_hash, sealed, title]`，正文只以
  密文 `sealed`（凭密码解密）与 `owner_sealed`（主密钥封存）存在
  （`main.py:1327-1328`）。→ **测试夹具绝不构造 stored 夹具、绝不伪造
  `content` 键**，否则会造出隐私假阳性；`test/personal_c_test.dart` 全部夹具
  都是 serialize 重建后的 API 形状。文件里那一个 locked 态 `content` 是
  **畸形注入的防御样本**（专测客户端 locked 态不呈现 content、数据层无条件
  丢越界键），**不代表 API 形状**——服务端 serialize 恒不下发
  `locked:true + content`。
- **`q` 搜索只匹配 title**：`main.py:1198/1201` 用 **stored 原文**
  `body.get('content','') + body.get('title','')` 做 `q` 匹配，personal_wish
  的 stored 没有 content → 搜索只能命中标题，正文不会通过搜索泄露。
- **Markdown 导出只写标题**：`app/markdown_export.py:16` 明确
  「personal_wish 的 sealed / readers_sealed 是密文，**绝不落盘**」；
  `:121` 渲染正文时 `kind != 'personal_wish'` 才输出 `content`，
  `:66-78` 的 `_title()` 也只取 title（无 content 时回退标题/类型名）。
- **通知只存固定标题**：`main.py:1331`
  `db.notice(c, 'activity', '对方许下了一份个人心愿', rid, user['id'])`
  —— 固定文案，不含正文、不含密码、不含密文。

## 契约行号（逐条实读，保留）

| 契约 | 位置 |
|---|---|
| diary content 必填集合 `{post,diary,surprise,note,chat}`（**不含 draft**） | `app/main.py:1107` |
| PUT 服务端不 merge（clean_body 的 previous 参数未使用） | `app/main.py:925` |
| surprise publish_at 必须未来时间戳 | `app/main.py:1127` |
| records 列表：非 trash 且不带 kind 才隐式排除私密类；trash 分支不排除 | `app/main.py:1143-1200`（`:1150-1156` / `:1196`） |
| PUT 仅 draft→post/diary/surprise 可改 kind | `app/main.py:1400` |
| surprise 揭示：worker 定时任务把 kind=surprise 改成 post（was_surprise / published=now） | `app/worker.py:225-235` |
| 删除相册清空其他记录的 body.album（恢复不回写 → G5 语义） | `app/main.py:1434-1439` |
| DELETE 软删 / restore 不区分 kind、period 分流 | `app/main.py:1424` / `:1443-1451` |
| PRIVATE 集合 / visible（作者专属） | `app/db.py:343` / `:377` |
| serialize 非作者私密记录 404 | `app/serializers.py:18-19` |
| 回收站 kind 串 = Object.keys(kindLabel).join(',')（含私密三类） | `static/app.js:468` / `:92` |
| personalPage 提示文案（diary/draft 同句、surprise 另句、trash 提示）/ 空态 / heading | `static/app.js:1484-1490` |
| 回收站「恢复这份回忆」按钮 / restore 动作 / 无彻底删除 | `static/app.js:1488` / `:2524` |
| recordForm（diary/draft/surprise 走 composer） | `static/app.js:1833` |
| 7-C：`serialize` 对 personal_wish 重建 body（三态 + 作者无条件追加 sealed） | `app/serializers.py:23-36` |
| 7-C：`serialize_many` 批量序列化 | `app/serializers.py:53-61` |
| 7-C：`PersonalWishInput` / `PersonalWishUnlockInput` 字段约束 | `app/main.py:914-922` |
| 7-C：创建专属端点（空字段 422 / client_id 409 / 密码唯一 422） | `app/main.py:1306-1332` |
| 7-C：解锁专属端点（免密直返 / 403 / readers_sealed 永久可见） | `app/main.py:1335-1365` |
| 7-C：`rate_limit(limit=20, window=900)` → 429「…请 15 分钟后再试」 | `app/security.py:193-206`（调用点 `app/main.py:1351`） |
| 7-C：`PRIVATE` / `ENCRYPTED` / `VISIBLE_SQL` / `KINDS` | `app/db.py:343-354` |
| 7-C：`db.visible()` 对非 PRIVATE 直接放行 | `app/db.py:377-381` |
| 7-C：records 列表显式 kind 分支 + `db.visible` 逐条过滤 | `app/main.py:1155-1159` / `:1196` |
| 7-C：`clean_body` 禁止 PUT 改 personal_wish | `app/main.py:928-929` |
| 7-C：DELETE 软删 / restore 通用路由 | `app/main.py:1424` / `:1443-1451` |
| 7-C：surprise 揭示（worker 定时任务，7-B 复用证据） | `app/worker.py:225-235` |
| 7-C：Web 个人心愿页（heading/副标题/hint/空态/入口） | `static/app.js:1302` |
| 7-C：Web 创建表单 `personalWishForm` / 解锁弹层 `unlockPersonalWish` | `static/app.js:1801` / `:1802` |
| 7-C：Web 卡片 `personalWishCard`（三态文案 + 仅作者删除菜单） | `static/app.js:2009` |
| 7-C：Web 工具卡入口 `toolsList`（App 差异：改放个人角落第五 tab） | `static/app.js:1219` / `:1222` |
| 7-C：Web 动作分派 `new-personal-wish` / `unlock-personal-wish` / `delete-record` | `static/app.js:2511-2512` / `:2523` |
| 7-C：Web `recordsOf` 只按 kind 过滤 / `refreshData` 全 kind 串 | `static/app.js:95` / `:263-272` |
| 7-C：Web 表单内联错误 `formError()` | `static/app.js:225` / `:1801-1802` |
| 7-C：`author=?` 会在 SQL 层排除对方心愿（**wishes 绝不能带**） | `app/main.py:1175-1177` |
| 7-C：`q` 搜索用 stored 原文 content+title → personal_wish 只有 title 可搜 | `app/main.py:1198` / `:1201` |
| 7-C：通知只存固定标题「对方许下了一份个人心愿」 | `app/main.py:1331` |
| 7-C：`errorDetail()` 对数组 detail 会 toString 成英文结构化文本 | `lib/core/api/api_client.dart:289-302` |
| 7-C：Markdown 导出不落密文、personal_wish 只写标题 | `app/markdown_export.py:16` / `:121` / `:66-78` |
| 7-C：Web 工具卡渲染 `tool-personal-wish` | `static/app.js:1229` |
| 7-C：Web `personalPage()` 只有 4 tab（无 personal-wish） | `static/app.js:1485` |

## 共同注意

- 写方法强制 `X-Love-Space: 1`（dioProvider 已自动注入）。
- 复用 `core/together/together_data.dart`：TogetherRecord / parseTogetherRecords /
  mergeRecordBody（回填铁律）；kindLabel 已含 'diary'/'draft'/'surprise'；
  7-B 起 TogetherRecord 增加 `deleted`（软删时间戳，序列化顶层字段）供回收站呈现。
- 页面骨架 tab 用可扩展数据表（7-A 两项 → 7-B 四项 → **7-C 五项**）；
  7-C 是本段落地、条目 7 收尾段，**之后无 7-D、无死卡**。
- **7-C 独立数据层（防串防漏）**：`personalWishKinds = 'personal_wish'` 顶层
  常量、独立 `PersonalState.wishes` / `loadWishes()` / `_wishSeq`；
  `loadWishes()` 显式 `kind=personal_wish&limit=1000` 且**不带 author**、
  **不按 author 过滤**（双方锁态标题都要显示）；uid 为空 fail-closed。
  `logout()` 的 `invalidate` 已确认覆盖 wishes state。
- **7-C 隐私红线**：`sanitizeWishBody()` 数据层无条件收敛
  `{title, locked, content?}` 三键（作者额外下发的 `sealed` 密文、
  `password_hash` / `owner_sealed` / `readers_sealed` 等一律丢弃），
  `_WishTile` 渲染层只取三键；未解锁 content 不渲染/不缓存/不进日志；
  密码只在请求体里过一遍，客户端不实现任何加密、不落本地、不自动重试。
- 存量形状来源：2026-11-14 SSH 直查 NAS 容器 `/data/love.db`（app.db.body_decode
  解密 PRIVATE body）：**draft 8 条**（body = `{content, date, media: [], title?,
  album?}`）、**已删除 17 条**（post 6 / draft 7 / album 1 / anniversary 1 /
  question 1 / music 1；顶层含 `deleted`、`published`、`client_id`）为真实存量形状；
  **diary、surprise 实测 0 行**——测试夹具按 Web composer（app.js:1807-1830）+
  clean_body（main.py:930-934）等价 serialize_many 形状推导，来源在
  `test/personal_a_test.dart:11-18` / `test/personal_b_test.dart` 头注释与本文档
  双处注明；主人已接受此例外，不造数据、不写生产库。
- **7-C 存量形状**：同一 SSH 只读直查实测 **personal_wish 2 行**（id / author /
  created / title 见上「⑧ 自测夹具来源」）；stored body keys 实测均为
  `[owner_sealed, password_hash, sealed, title]`，都还没有 `readers_sealed`。
  🔴 客户端收到的是 **serialize 重建后** 的 body 而非 stored 原文，故
  `test/personal_c_test.dart` 按三态序列化形状构造夹具（真实两行 id/title/author
  为底 + `readers_sealed` 分支等价推导），来源在测试文件头与本文档双处注明；
  不造数据、不写生产库、不打印密文。
