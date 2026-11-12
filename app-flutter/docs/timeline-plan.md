# 条目 4 · 时光页 · 分步实施清单

> 依据：`flutter-plan-v2.md` §阶段 2.4（post 的发布/浏览/点赞/评论，筛选走 records 查询参数）；对照源 `static/app.js`（timelinePage:860 / recordCard:851 / loadTimeline:282 / composer:1807 / like:2525 / comment:2532 / edit-record / delete-record / notice-detail 的卡片复用）+ `app/main.py:1142` records 查询参数实测（kind/q/author/date/media_type/trash + before/before_id 游标）。
> 复用资产：段二上传链路（白名单/250MB 预检/进度）、媒体渲染组件、client_id 幂等、`LowFreqCacheManager`（头像；列表媒体图仍走常规 Cookie 策略，不进低频缓存——主人通则明文）。
> 纪律：后端零改动；对照 Web 不增不减；分两段交付（每段一提交+小结+验收清单）；验收主人手动；皮肤 `[skin-dbg]` 埋点保留至总验收取证后移除，本条目不动它。

## 0. 已核实的关键口径（照抄，勿改）

- **首屏与游标**：`GET /api/records?kind=post&limit=61`，取前 60 条、`hasMore = fetched.length > 60`；上翻 `before=<created>&before_id=<id>`；按 id 去重追加、**只追加不整列表重建**（Web revealTimeline 语义）。
- **筛选参数**：q（搜索）/author（用户 id，空=两人）/date（yyyy-MM-dd）/media_type（image/video/audio）。**筛选变化即 reset 重拉**；chips 显示当前条件与激活数。
- **字段约束**：标题 ≤200（可选）、内容 ≤20000、评论 ≤5000、每条附件 ≤30；日期字段 body.date（发生日）≠ created（发布时间戳），卡片头部显示 `b.date || dateLabel(created)`，footer 显示 dateLabel(created)。
- **可见性**：服务端已过滤（diary/draft/surprise 非作者不可见），客户端照常渲染。
- **点赞**：`POST /records/{id}/like` toggle，返回 `{ok:true}`——**不返回新状态**，成功后本地翻转该卡 likes（含本人 id）或对账重拉；liked 态红心。
- **评论**：`POST /records/{id}/comments {content}`；删除 `DELETE /api/comments/{cid}`（仅本人）；评论列表直接在卡片内展开。
- **编辑/删除**：仅本人（own）；编辑=同 composer 预填走 `PUT /api/records/{id}` **全量 body**（含 kind 与原字段，put 丢字段会清数据——已有坑备案）；删除=确认弹层→`DELETE /api/records/{id}`（进作者回收站，30 天可恢复——回收站 UI 归条目 7）。

## 1. 段一 · 浏览、筛选与发布入口（决策 4 定版：按钮不留死）

1. **时光 tab 接入**：shell 第 2 tab 替换占位页；页头 heading（「时光慢慢，爱意满满」/「那些一起走过的日子，都在这里。」）。
2. **列表与卡片**：kind=post 卡片全要素——头像（LowFreqCache）+昵称+日期（b.date||dateLabel 口径）+可选标题+正文+媒体网格（图 preview 可点开查看器/视频 poster+播放徽标/语音 chip 播放——复用聊天组件）+footer（时间戳+点赞数/评论数按钮，互动行为段二接）+内联评论列表展示。空态两套（没有记录 / 没有符合筛选）。
3. **筛选区**：搜索框（q，防抖）+筛选盒（作者下拉=两个人/各自、日期选择器、类型三选）+激活 chips+清除筛选；筛选变更 reset 重拉。
4. **无限滚动**：ScrollController 近底部（约一屏）预取下一页；只追加；末尾「没有更多了」。
5. **首屏骨架与浮现**：3 张骨架卡（形状对齐真实卡）+骨架淡出、卡片错开浮现（对齐 Web revealTimeline 节奏）。
6. **图片查看器（基础版）**：点卡片图全屏打开（preview 图起步、原图点下载时再取）、左右切换同卡多图、双指缩放、下载原文件（/media/{mid}?download=true）、关闭。共享元素转场等增强归条目 5。
7. **Composer 基础态（决策 4：页头按钮+FAB 段一就可发）**：标题（≤200 可选）/内容（≤20000）/日期（**原生 showDatePicker**，决策 3）/媒体上传（图/视频多选+音频文件，≤30 带进度、可前移/移除）——复用段二聊天上传链路与 client_id 幂等；发布=POST kind:'post'。**页头「记录此刻」与 shell FAB 双入口本段即接**；草稿/录音/相册分类/本地暂存恢复归段二。client_id 首次生成后在本段先随会话态保留（暂存持久化段二补齐）。
8. **SSE 联动**：other 事件且正在时光 tab → reset 重拉。

**段一验收点**：返回路径（查看器/筛选盒/日期选择器/composer 弹层可关）；列表对照 Web 卡片要素逐项；筛选四参数生效+chips+清除；连翻 3 页无重复无丢失不跳位置；骨架→浮现过渡；查看器缩放/切换/下载；双入口发布（纯文字/带图/带视频/带音频）双方可见。

## 2. 段二 · 互动与 Composer 完整态

1. **Composer 补全**：「保存草稿」（kind:'draft'，草稿列表展示归条目 7）/**表单本地暂存**（等价 Web localStorage：字段+media+client_id 持久化，关弹层不丢、杀进程重开恢复，未传完媒体提示重选）/录音 tile（record 插件）/相册分类 chips（kind=album 记录，「暂不分类」=空 album 字段）。
2. **互动**：点赞 toggle（本地翻转+失败回滚）；评论原生 BottomSheet（≤5000）→POST→卡片内即时插入；删评论确认。写操作后**本卡原地更新**。
3. **编辑/删除菜单**：本人卡片「⋯」→编辑（composer 预填，**PUT 全量 body** 注意 album/date 字段不丢）/删除（确认弹层，30 天可恢复）。
4. **聊天「记入时光」升级**：段三最小发布弹窗替换为正式 composer（post 态，沿用媒体），行为合一。

**段二验收点**：发布（纯文字/带图/带视频/带语音/录音）双方可见；草稿保存；杀进程后表单暂存恢复（含未传完媒体提示重选）；编辑改内容生效（全量字段无丢失——重点验 album/date）；删除→卡片消失；点赞/评论/删评论即时；FAB 与页头双入口。

## 3. 决策点（需主人拍板）

| # | 事项 | 建议 |
|---|---|---|
| 1 | 图片查看器：段一做基础版（全屏/切换/缩放/下载），共享元素转场归条目 5 相册 | 按建议 |
| 2 | 段划分：段一=浏览筛选查看器，段二=发布互动 composer | 按建议（体量对齐聊天分段的节奏） |
| 3 | 日期选择：自绘 mini-cal（对齐 Web 观感）vs 原生 showDatePicker（快） | 建议 showDatePicker + 中文 locale（成本/收益更优，Web 自绘是 Web 无原生组件的妥协） |
| 4 | 「记录此刻」页头按钮：段一直接实现（等于提前交段二入口）还是先置灰 | 建议段一直接可点（FAB 同批），段二只差弹层内容——避免按钮先死后活 |
| 5 | 评论输入形态：Web 是弹层 textarea | 对齐弹层（原生 BottomSheet 带输入框） |

## 4. 明确不做（本条目）

- 其它 kind 卡片与 composer 态（diary/surprise/draft 列表=条目 7；wish/quest/habit/question/ledger/music=条目 6）；recordCard 通用底座按 post 实现并留 kind 扩展位。
- 相册上传入口（upload-album=条目 5）；notice-detail「这一刻的故事」弹层（条目 9 通知中心）；on-this-day/年刊（归属未定，维持待办）。
- timeline 本地持久缓存（Web 无，对齐）；全局搜索（Web 顶栏全局搜索归条目 9，本页搜索仅 q 参数）。
- 后端零改动；上传限流 30 次/300s 已知，composer 连传多附件时按序上传（与聊天同策略）。
