# 条目 6 ·「我们」页 计划与清单（2026-11-13 调研稿 · 同日主人拍板定稿）

> 调研出处与契约同初稿（Web static/app.js `togetherPage()` L1220-1230；后端
> app/main.py / serializers.py 实读，行号随文）。**决策点已由主人 2026-11-13
> 晚全部拍板定案（见下），不再复议。** 版本自 2.1.0 (VC210) 顺延。

## 一、Web「我们」页构成（调研结论，定稿保留）

Web 导航 `['together','heart','我们']`（app.js:305）。`togetherPage()` 分流：

### 1.1 宫格 hub（无 tab 时，app.js:1229）
- **四张特殊卡**：🌸 生理期（宽卡）、📊 数据看板、✉️ 回忆周报、📸 情侣摆拍参考
- **11 张工具卡**（`toolsList`，app.js:1219）：calendar / anniversary / quest / wish /
  ledger / personal-wish / mood / note / question / music / habit
- **底部「设置」区块**（8 卡）：空间信息 / 主题与外观 / 主页背景 / 聊天背景 /
  聊天气泡 / 邀请另一半 / 提醒设置 / 全部设置

### 1.2 数据流（读）
- **一次性全量**：`GET /api/records?kind=<全部 kind 拼接>&exclude=chat&limit=1000`
  （app.js:270）→ `recordsOf(kind)` 客户端过滤（app.js:95）。
- **专属统计端点**：`GET /api/dashboard`（main.py:2082）、`GET /api/weekly?offset=`
  （main.py:2126）、`GET /api/calendar?month=`（main.py:2341，days 四类标记）。
- **音乐**：`GET /api/music/search`（1807）、`GET /api/music/stream`（1863，
  passthrough 白名单 main.py:87）。
- **摆拍参考**：整页 iframe `/pose-gallery/poses`（app.js:444）。

### 1.3 数据流（写）
- **通用记录写**：POST/PUT/DELETE `/api/records`（kind 区分）。
  permitted 30 键（main.py:930-933）；必填校验（main.py:1104-1125）：
  `anniversary` 必填 date；`album/anniversary/wish/habit/question/music` 必填 title；
  `post/diary/surprise/note/chat` 必填 content 或 media；`question` 禁附件；
  `ledger` amount 0–1 亿；`surprise` publish_at 未来。
  🔴 **回填铁律适用于全部 PUT**（clean_body 的 previous 不参与合并）。
- **attached 子资源**：question 回答 `POST /api/records/{rid}/answer`（1540）；
  habit 打卡 `POST /api/records/{rid}/check`（1551）。
- **personal_wish 专属**（1306/1335）：`POST /api/personal-wishes` +
  `/{rid}/unlock`；走 /api/records 直接写 422（main.py:928）。
- **wish done 勾选口径**：`PUT /records/{id} {kind,body:{...r.body,done:!done}}`
  （app.js:2536 toggle-wish）。
- **Web 通用表单字段**（recordForm app.js:1833）：
  mood = emoji（MOOD_OPTIONS 十种 app.js:94）+ date 必填 + content 可选；
  note = content 必填、无 title；wish = title 必填 + category 五选 +
  target 可选 + content 可选。

## 二、边界（主人已定）

- 🔴 **纪念日归首页**：管理页挂首页入口（B 段建页）；首页已有「最近纪念日」
  倒计时区（home_page.dart:307-383）。「我们」hub 只放**只读展示卡**
  （决策点①定案：显示最近纪念日倒计时，点击切回首页 tab）。
- 🔴 **壁纸/背景归设置**（账号页时已定）；hub 不做背景类入口。
- 🔴 **设置区块 8 卡全归条目 8**；生理期入口卡也随条目 8 上（决策点⑥），
  条目 6 的 hub 不放。
- 🔴 **个人小角落（条目 7）**：Web personalPage 四 tab（diary/draft/surprise/trash）
  + **personal_wish（决策点④定案：从我们页挪入条目 7）**。
- 🔴 **摆拍参考（figure）暂缓出条目 6**（决策点③，原 G 段取消）。

## 三、决策点定案（2026-11-13 主人拍板，不再复议）

| # | 决策点 | 定案 |
|---|---|---|
| ① | hub 纪念日卡 | **保留只读展示卡**（最近纪念日倒计时，点击切首页 tab）；管理页归首页入口、B 段建页 |
| ② | mood 列表页 | **做**（段 A） |
| ③ | figure 摆拍 | **暂缓出条目 6**（原 G 段取消） |
| ④ | personal_wish | **挪条目 7 个人角落**（原 E 段只剩歌单） |
| ⑤ | 歌单深度 | **只试听**、对齐 Web（/api/music/search+stream） |
| ⑥ | 生理期入口卡 | **随条目 8 上**，条目 6 hub 不放 |
| ⑦ | dashboard/weekly | **降为可选段 E**：主线 A–D 做完停手等主人决定做不做 |
| ⑧ | ledger 口径 | **与 Web 一致**（按 author 聚合：月对比 + 总量对比） |

## 四、分段定稿（5 段；每段一 commit；版本顺延）

> 通用地基：`TogetherPage` hub + 通用记录列表件（ToolScaffold/ToolTile）+
> 各 kind 表单弹层（不复用 post composer；横切口径：ChatToastHost 顶部通知 /
> client_id 幂等 / 回填铁律 / 软删确认）。hub 宫格**只上已落地页面的卡片**，
> 后续段随页面落地逐段增补，不预放死卡。

| 段 | 版本 | 内容 | 主要端点 |
|---|---|---|---|
| **A** | **2.1.0 (VC210)** | hub 宫格 + 通用列表件 + mood / note / wish 三工具（新增/编辑/删除；wish done 勾选）+ 纪念日只读展示卡 | GET/POST/PUT/DELETE /api/records |
| B | 2.1.1 (VC211) | 共同年历（四色点 + 点日详情）+ 纪念日管理页（挂首页入口；hub 展示卡跳转目标落位） | /api/calendar、/api/records(anniversary) |
| C | 2.1.2 (VC212) | 情侣问答（双方揭晓 + 内置题库）+ 共同打卡（打卡流） | /api/records、{rid}/answer、{rid}/check |
| D | 2.1.3 (VC213) | 恋爱清单（进度 + 精选 + 自定义）+ 共同账本（按 author 人均聚合）+ 共同歌单（只试听，决策点⑤） | /api/records（quest/ledger/music） |
| E | 2.1.4 (VC214) | **可选**：数据看板 + 回忆周报（只读统计；决策点⑦，主线做完停手等主人） | /api/dashboard、/api/weekly |

**明确不做（边界外）**：壁纸/背景/主题/气泡/邀请/提醒渠道/全部设置（条目 8）；
diary/draft/surprise/trash/**personal_wish**（条目 7）；生理期本体与入口卡（条目 8）；
figure 摆拍（暂缓）；like/comment 行内互动（工具记录卡暂不做，与时光互动件
统一复用留待后续——Web recordCard footer 的点赞/评论，段 A 列表件不含）。

## 五、每段验收点草案（每段小结逐项自查；返回路径必查）

**通用（每段都验）**：
- 返回路径：工具二级页按钮 + 系统返回手势/返回键都能回 hub；hub 在 shell tab 栈内；
- 写操作失败回滚 + 顶部通知；回填铁律（PUT 以原始 body 为底）单测必带；
- 空态/加载态/SSE other 重拉；表单取消不误写（含弹层外点、返回键）。

**段 A**：hub 卡片只含已落地页（mood/note/wish + 纪念日展示卡）；纪念日卡口径与
首页逐字一致（annual 推进 + 02-29 回退 + days<0 跳过），点击切首页 tab；
mood 表情十种与 Web MOOD_OPTIONS 一致；note 无 title；wish done 双方可点
（非本人 PUT 403 → 错误通知）；删除确认可取消。
**段 B**：月历翻月/回今天；四色点图例一致；点日详情只列当天；纪念日新增
（date 必填 + 公历/农历/一次 + remind_days 0-365）；首页倒计时区点击进管理页。
**段 C**：问答双方答完才互见；打卡按日去重；内置题库去重已存在题目。
**段 D**：清单进度实时；精选清单过滤已添加；账本月切换/人均聚合正确（author=付款人）；
歌单搜索防抖、试听带 Cookie 流。
**段 E（可选）**：看板数字与 Web 一致；周报下一周到本周封顶。

## 六、风险与坑位备忘
- **personal_wish 千万别走通用 PUT**（422 + 密码不进通用表单）——已挪条目 7，注意跨段协作。
- **question 无附件**（服务端 422，main.py:1112）；**ledger amount 上限 1 亿**。
- 上传限流 30 次/300s；media ≤30/条；写方法一律 `X-Love-Space: 1`（拦截器自动）。
- SSE other 重拉沿用时光/相册同款（代次防竞态）。
- wish done 非本人 PUT 会 403（服务端 get_record(editable) author 校验）：
  Web 也存在同口径（按钮展示但提交报错），客户端以错误通知兜底即可。
