# 条目 7「个人角落」Flutter 迁移清单（定案）

> 2026-11-14 调研并定案。契约全部实读核实（行号见下「契约行号」章节）；
> 三段版本位已定，7-A 随本段落地（2.1.7 / VC217）。

## 三段定稿表

| 段 | 内容 | 版本位 | 状态 |
|---|---|---|---|
| 7-A | 页面骨架 + 私密日记 + 草稿箱（列表/新建/编辑/删除/草稿发布） | **2.1.7 (VC217)【本段】** | ✅ 本段交付 |
| 7-B | 定时惊喜（publish_at 交互 + 揭示态）+ 回收站（列表 + 恢复） | 2.1.8 | 待 7-A 真机验收后开工 |
| 7-C | 个人心愿（专属端点、密码唯一、解锁流） | 2.1.9 | 待 7-B 真机验收后开工 |

- **个人心愿入口 = 个人角落页第五个 tab（7-C 落地）**。本段只上 diary / draft
  两个 tab，7-B / 7-C 的 tab 一律**不预置**（无死卡纪律：Web 能点的 App 才有去向）。
- **新建表单口径：日记/惊喜用简洁表单、草稿箱对接正式 composer（不另造编辑器）**。
  本段 diary 用页内简洁表单（多行 content 必填）；草稿「继续编辑」「写一份草稿」
  直接 `showComposerSheet`，编辑态保持 kind=draft；7-B 的 surprise 同样用简洁表单
  + 未来时间选择，不走 composer 另建编辑器。
- 表单 / 编辑 / 发布选择等二级页一律 `context.push`（AppBar 自动返回按钮 +
  系统手势都能回上一页）；壳层 IndexedStack 常驻，tab 间切换不丢状态。
- 每段照例：契约先核实 → 一段一提交 → 停等真机验收；自测夹具含**真实存量形状
  样本**。NAS 容器 `/data/love.db` 实测 **draft 8 条为真实存量形状**；
  **diary 库里实测 0 行**，按 Web composer（app.js:1807-1830）+ clean_body
  （main.py:930-934）等价 serialize_many 形状推导，来源在
  `test/personal_a_test.dart:11-18` 与本文档双处注明。主人已拍板**接受此例外**，
  不造数据、不写生产库。

## 页面定位

Web `personalPage`（app.js:1484）：heading「我的小角落 · 有些心事留给自己，有些惊喜留给未来」
+ 四 tab（diary 私密日记 / draft 草稿箱 / surprise 定时惊喜 / trash 回收站）。
settings tab 在 Web 里同页（tab==='settings' 时渲染 settingsPage）——**App 侧设置页已独立落地，不迁**。
App 入口 = 壳层 BottomAppBar 第 5 个 tab「角落」（IndexedStack 第 5 页）。

## 两个 tab（7-A）契约

### ① diary 私密日记
- 列表：`GET /api/records?kind=diary,draft`（7-A 统一显式 kind 串 `personalKinds`，
  客户端按 r.kind 分流两 tab；main.py:1156 的隐式排除只作用于**非 trash 且
  不带 kind** 的 else 分支）。
- 顶部 hint（app.js:1489，两 tab 同句）：「这个角落只有你能看见。草稿主动发布后，才会进入共同空间。」
- 空态：「给自己，留一点心里话」+「慢慢写，不着急。」；入口按钮「开始记录」。
- 新建：POST /api/records kind=diary，body.content 必填（main.py:1107）：
  `{content, date, media: []}`，client_id 幂等。
- 编辑：PUT /api/records/{rid} 全量 body，**回填铁律**（mergeRecordBody，以原 body
  为底只盖 content）。
- 删除：DELETE /api/records/{rid}（main.py:1424 软删）；7-A 确认弹层文案
  「私密内容删除后不进回收站、不可恢复」与共享类 post_card.dart:271 /
  tool_pages.dart:160 的「删除后会进入回收站，30 天内可以恢复。」分开。
  🔴 该文案为 **7-A 暂时口径**：主人已定案对齐 Web（2026-11-14 12:10），
  随 **7-B 的包（2.1.8）** 改回标准口径「删除后进回收站、30 天内可恢复」，
  **不单独出返修包**；详见「删除口径」章节。

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
- 删除：同 7-A 暂时文案口径（不进回收站、不可恢复；**7-B 改回标准口径**）。

### 跨账号隐私
- main.py:1156 `kind NOT IN ('diary','draft','surprise')` 只在**非 trash 且不带 kind**
  的 else 分支；`db.visible` 对 PRIVATE 类只放作者（db.py:377），main.py:1196
  逐条过滤，serialize 对非作者私密记录直接 404。
  **跨账号隐私由服务端保证**；客户端额外带 `author=<当前用户 id>` 加固并二次按
  author 过滤，绝不渲染越权数据。

### 删除口径（Web 现状 / 主人定案对齐 Web / 7-B 落地）

1. **Web / 后端现状（实读，非旧版错误推论）**：main.py:1150-1156 的
   `kind NOT IN ('diary','draft','surprise')` **只作用于非 trash 且不带 kind 的
   else 分支**；trash 分支只加 `author=? AND deleted IS NOT NULL`，**不排除私密类**。
   static/app.js:468 回收站请求的 kind 串是 `Object.keys(kindLabel).join(',')`，
   而 kindLabel（app.js:92）**包含** diary/draft/surprise；main.py:1443 restore
   也不区分 kind。→ **Web 现状：本人删掉的私密日记/草稿会进回收站并可 restore**。
   （旧版文档写「trash 分支排除私密三类、私密类删除后不出现在回收站」是错的，已删。）
2. **主人定案 · 对齐 Web（2026-11-14 12:10，作废此前「App 内收紧」）**：
   回收站 kind 串与 Web 一致，含 diary/draft/surprise，仅本人（服务端 trash
   分支强制 `author=自己 AND deleted IS NOT NULL`）；restore 与 Web 一样可用。
   **7-A 删除文案是暂时口径，随 7-B 的包（2.1.8）改回标准口径「删除后进回收站、
   30 天内可恢复」，不单独出返修包**。
3. **7-B 落地（本段不实现、不改后端）**：按 Web 口径，kind 串含 PRIVATE 三类、
   提供 restore 入口；**后端零改动**（restore 端点对所有 kind 放行是服务端事实，
   客户端按 Web 同款调用即可）。`privateDeleteText` 随 7-B 包改回标准口径。

### 回填铁律根因（实读证据）
- main.py:925 `clean_body(c, kind, data, user_id, previous=None)` 的 `previous`
  参数在函数体**完全未使用** → PUT 服务端**不 merge**，`cleaned` 就是客户端传来
  body 的全量替换。所以客户端编辑/发布必须以原 body 为底逐键复制（mergeRecordBody），
  未知字段也要原样带回；代码 merge 处留注释。

## 7-B / 7-C 契约备忘（本段不实现，留档）

### ③ surprise 定时惊喜
- 列表：`GET /api/records?kind=surprise`。
- 新建：POST kind=surprise，body.publish_at 必填且 **now < publish_at < now+50 年**
  （main.py:1127-1130），其余 kind 会 pop 掉 publish_at。
- 提示文案：「到约定的时间，惊喜才会被另一半看见。」

### ④ trash 回收站（7-B，本段不实现）
- **Web 现状**：`GET /api/records?trash=true&kind=<kindLabel 全 kind>`（app.js:468，
  kindLabel 含 diary/draft/surprise）→ trash 分支只加 `author=自己 AND
  deleted IS NOT NULL`，**不排除私密类**；`POST /api/records/{rid}/restore`
  （main.py:1443）不区分 kind、仅本人 → 本人删掉的私密日记/草稿在 Web 会进
  回收站并可恢复。文案：「删除的内容保留三十天，你可以恢复自己的记录。」
- **主人定案（7-B 落地）：对齐 Web**，kind 串含 PRIVATE 三类、restore 可用、
  **后端零改动**；`privateDeleteText` 随 7-B 包改回标准口径。详见「删除口径」。

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
| DELETE 软删 / restore 不区分 kind | `app/main.py:1424` / `:1443` |
| PRIVATE 集合 / visible（作者专属） | `app/db.py:343` / `:377` |
| 回收站 kind 串 = Object.keys(kindLabel).join(',')（含私密三类） | `static/app.js:468` / `:92` |
| personalPage 提示文案（两 tab 同句）/ 空态 / heading | `static/app.js:1484-1490` |
| recordForm（diary/draft/surprise 走 composer） | `static/app.js:1833` |

## 共同注意

- 写方法强制 `X-Love-Space: 1`（dioProvider 已自动注入）。
- 复用 `core/together/together_data.dart`：TogetherRecord / parseTogetherRecords /
  mergeRecordBody（回填铁律）；kindLabel 已含 'diary'/'draft'/'surprise'。
- 页面骨架 tab 用可扩展数据表（本段只两项），后续 7-B/7-C 扩表不预置死卡。
- 存量形状来源：2026-11-14 SSH 直查 NAS 容器 `/data/love.db`（app.db.body_decode
  解密 PRIVATE body）：**draft 8 条为真实存量形状**（body = `{content, date,
  media: [], title?, album?}`），**diary 实测 0 行**——测试夹具的 diary 样本按
  Web composer（app.js:1807-1830）+ clean_body（main.py:930-934）等价
  serialize_many 形状推导，来源在 `test/personal_a_test.dart:11-18` 与本文档双处
  注明；主人已接受此例外，不造数据、不写生产库。
