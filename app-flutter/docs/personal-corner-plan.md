# 条目 7「个人角落」Flutter 迁移清单（定案）

> 2026-11-14 调研并定案。契约全部实读核实（行号见下「契约行号」章节）；
> 三段版本位已定：7-A（2.1.7/VC217）已验收，7-B（2.1.8/VC218）本段落地。

## 三段定稿表

| 段 | 内容 | 版本位 | 状态 |
|---|---|---|---|
| 7-A | 页面骨架 + 私密日记 + 草稿箱（列表/新建/编辑/删除/草稿发布） | 2.1.7 (VC217) | ✅ 已验收 |
| 7-B | 定时惊喜（publish_at 交互 + 揭示态）+ 回收站（列表 + 恢复）+ 删除文案统一标准口径 | **2.1.8 (VC218)【本段】** | ✅ 本段交付 |
| 7-C | 个人心愿（专属端点、密码唯一、解锁流） | 2.1.9 | 待 7-B 真机验收后开工 |

- **个人心愿入口 = 个人角落页第五个 tab（7-C 落地）**。7-A 上 diary / draft
  两个 tab，7-B 增补 surprise / trash 共**四个 tab**，7-C 的 tab 一律**不预置**
  （无死卡纪律：Web 能点的 App 才有去向）。
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

## 7-C 契约备忘（本段不实现，留档）

### personal_wish 个人心愿（7-C 第五 tab，专属端点）
- 创建：`POST /api/personal-wishes`（main.py:1306）：title/content/password 全必填；
  密码唯一（撞已用密码 → 422）；body 存 `{title, sealed, owner_sealed,
  password_hash, readers_sealed}`；client_id 幂等照旧。
- 解锁：`POST /api/personal-wishes/{rid}/unlock`（main.py:1335）：作者免密，对方凭
  密码首次解锁，成功后入 readers_sealed；有 rate_limit（main.py:1351）。
- 🔴 加解密在服务端（personal_wish_encrypt / seal_for_owner），客户端只传明文密码。

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

## 共同注意

- 写方法强制 `X-Love-Space: 1`（dioProvider 已自动注入）。
- 复用 `core/together/together_data.dart`：TogetherRecord / parseTogetherRecords /
  mergeRecordBody（回填铁律）；kindLabel 已含 'diary'/'draft'/'surprise'；
  7-B 起 TogetherRecord 增加 `deleted`（软删时间戳，序列化顶层字段）供回收站呈现。
- 页面骨架 tab 用可扩展数据表（7-A 两项 → 7-B 四项），7-C 扩表不预置死卡。
- 存量形状来源：2026-11-14 SSH 直查 NAS 容器 `/data/love.db`（app.db.body_decode
  解密 PRIVATE body）：**draft 8 条**（body = `{content, date, media: [], title?,
  album?}`）、**已删除 17 条**（post 6 / draft 7 / album 1 / anniversary 1 /
  question 1 / music 1；顶层含 `deleted`、`published`、`client_id`）为真实存量形状；
  **diary、surprise 实测 0 行**——测试夹具按 Web composer（app.js:1807-1830）+
  clean_body（main.py:930-934）等价 serialize_many 形状推导，来源在
  `test/personal_a_test.dart:11-18` / `test/personal_b_test.dart` 头注释与本文档
  双处注明；主人已接受此例外，不造数据、不写生产库。
