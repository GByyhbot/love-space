# 条目 3 · 聊天专章 · 分步实施清单

> 依据：`flutter-plan-v2.md` §阶段 3 + 附录 B 动效规范；对照源 `static/chat.js`（1205 行）与 `static/app.js` 聊天相关段（sendChat/uploadFile/mediaMarkup/song/背景等）。
> 契约锚点：`api-samples/03-records.md`（client_id 幂等 / pin / recall）、`04-media.md`（两段式 + preview）、`05-realtime-aggregate.md`（SSE retry:3000 + chat 标志）。
> 纪律：后端零改动；一页一提交（本清单 9 步合为一个「条目 3」提交）；验收由主人手动做，禁止 adb 点击/输入；每步完成后跑 `flutter analyze` + `flutter test`，**构建覆盖安装只在最终交付时做一次**。
> 结构约定：新增文件全部在 `lib/features/chat/` 与 `lib/core/`，不动既有页面文件的行为。

## 0. 入口与页面归属（已核实，定版）

- **聊天不是底部 tab**：Web 端聊天是顶栏「私聊」图标（带未读角标）打开的**全屏二级页**（`chat-full`，自带头部返回按钮）。App 端对应：Shell AppBar actions 加聊天图标 + 未读角标（`MeData.chat_unread`，>99 显示 99+），`context.push('/messages')`，遵守 push 导航通则（返回按钮 + 手势都能回上一页）。
- **进入聊天清未读**：`POST /api/notices/read?event=chat`（Web `navigate('messages')` 行为），本地角标同步清零。
- **对方页未打开聊天时**：SSE chat 事件 → 重拉 me → 角标更新（Web `syncBadge` 同口径）。

## 1. 分步实施顺序（每步含验收点）

### Step 1 · 数据层与模型
- `ChatRecord` 模型：id / author / created / updated / client_id / body{content, media[], sticker, reply_to{id,text}, pinned, recalled, location{lat,lng}, song{title,artist,mid,src,art,dur}} / media[]（id,name,mime,size,status,preview）。
- client_id 生成器（uuid v4），与 Web 口径一致：**发送时生成、重试复用同一 id**。
- drift 表 `chat_messages` 缓存最近窗口（方案 §阶段 3：冷启动先显缓存再同步）。
- 拉取：首屏 `GET /api/records?kind=chat&limit=200`；上翻 `before=<created>&before_id=<id>` 游标（api-samples/03 实测形态）；按 created 升序入列表。
- MeData 扩展 `chat_unread`。

**验收点（开发自验）**：单测——①client_id 幂等（同 id 重发返回既有记录的解析逻辑）；②游标分页拼接正确（两页按 created 升序、无重复无丢失）；③时间条判定（间隔≤300s 同天不加，跨天/更久加）对齐 `chatTimeLabel()`。

### Step 2 · 聊天页骨架 + 列表渲染
- `/messages` 路由 + AppBar 入口（含角标）；页面自带头部（对方头像/昵称/「我们的悄悄话 · 仅彼此可见」）。
- 列表：倒序 ListView，文本气泡（我/对方左右分侧+头像）、撤回态行（「你/对方撤回了一条消息」）、时间条、空态（「今天，有什么想对 TA 说？」）。
- 上翻历史：游标分页，预加载（接近顶部自动拉，对齐 Web 无限滚动思路）。
- 贴底跟随：新消息到达且原本在底部才自动滚到底；正在翻历史不打扰（对齐 Web `chatLogFromBottom` 语义）。

**验收点（开发自验）**：analyze 0 issues。
**真机验收点**：①返回路径：AppBar 返回按钮与系统手势都能回上一页；②文本/撤回/时间条渲染与 Web 对照一致；③上翻能拉出更早历史且位置不跳。

### Step 3 · 发送状态机（client_id 防重，附录 B·发送三态）
- 发送即入 pending 队列并**本地落盘**（等价 Web `localStorage['pending-chat:<uid>']`，用文件/secure_storage 实现），立即渲染「三点跳动」发送中态。
- `POST /api/records {kind:'chat', body, client_id}` 成功 → 清 pending 行并入正式列表（服务端返回记录幂等）；失败 → 标红「未发出 + 点击重试」，**重试复用同一 client_id**（服务端 `UNIQUE(author,client_id)` 保证不重复）。
- 断网/超时统一走失败态；错误 detail 中文文案直通。
- 发送内容含 media 时先走 Step 5 上传（状态机先行留好接缝）。

**验收点（开发自验）**：单测——重试复用同 client_id；pending 落盘/恢复（模拟杀进程）。
**真机验收点**：①连发 20 条文字无重复无丢失；②飞行模式发送→标红→恢复网络点重试→成功且只有一条；③杀进程后重开，未发出的消息还在并可重试（对齐 Web 离线保留语义）。

### Step 4 · SSE 增量接入
- 订阅既有 `sseEventsProvider`：`chat==true` 事件 → 只重拉聊天（增量：拿当前最新 created 之后的数据，或简化为重拉首屏 200 后与 drift 对账——实现取对账方案，避免整列表重建）。
- 回前台补拉（SseClient 生命周期已有，接聊天侧对账即可）；后台断开不重复接入。
- 列表增量更新按 id 对账，不整段重建（对齐 Web `paintChat` 语义：图片/视频不重载、滚动不跳）。
- 不在聊天页时 chat 事件 → 重拉 me 更新角标。

**验收点（开发自验）**：单测——对账合并（新消息/撤回更新/置顶变化）。
**真机验收点**：①Web 端发消息，App 前台 ≤5s 收到；②App 在别的 tab 时角标+1，进聊天清零；③后台回前台补拉到位。

### Step 5 · 两段式上传 + 媒体气泡
- 上传：`POST /api/media` multipart（dio 带进度回调，进度可见）；格式白名单与 250MB **本地预检**（服务端魔数/Pillow 校验会 422，文案透传）；拿 id 后进 body.media（每条上限 30，超限本地提示）。
- 入口对齐 Web：⊕面板「相册」= 服务器媒体库半屏网格多选（`/api/media/images?limit=300`，勾选序号 + 可写一句）+「上传」按钮进本机选择器；「拍摄」= image_picker camera。
- 渲染：图片 preview 图（`/media/{mid}?preview=true`，带 Cookie 的共享 dio/cached_network_image）；status 非 ready 显示占位、就绪后自动替换；视频 poster 封面 + 播放；语音 chip（时长 + 点击播放）。
- 视频播放 video_player、语音 audioplayers/just_audio（新依赖，逐个加防 gradle intermediates 坑）。

**验收点（开发自验）**：analyze/test 过；上传 422 中文文案透传单测。
**真机验收点**：①发图（单/多张带一句话）双向可见、进度可见；②大图 preview 占位→清晰替换；③视频封面+可播放；④语音可录（再点结束）可播；⑤超 250MB 本地先拦；⑥422（坏图）服务端文案原样显示。

### Step 6 · 输入区原生规范（键盘 ↔ ⊕面板 ↔ 贴纸坞同槽位互斥）
- `resizeToAvoidBottomInset` + `MediaQuery.viewInsets` 读键盘高度；**不移植 Web 键盘逻辑**（A/B 类分流、原生桥、平滑全部不要）。
- 底部同一槽位互斥切换：键盘 / ⊕面板 / 贴纸坞三选一；面板高度按内容实测、夹「无键盘视口」62%；切换防闪烁（面板先以键盘高度占位，键盘收起后显内容——Flutter 常规做法）。
- 「面板意图」等价 fnIntent：点输入框键盘临时压掉面板，键盘收起后面板自动回来；用户亲手收起/选走功能才清意图。
- ⊕面板 16 格对齐 Web（相册/拍摄/语音/表情/位置/音乐/搜消息/聊天背景/共同年历/恋爱清单/共同愿望/共同账本/生理期/数据看板/回忆周报/情侣摆拍）——后 8 个为跨页去向（见决策点 3）。
- 贴纸坞：emoji 两组（日常/涩涩）+ 3 个内置贴纸包（webm 循环播放/静态 webp）+「我的」（自定义表情包上传→media id 本机保存，上限 100）；视频贴纸可视区才解码播放（对齐 Web IO 门控语义）。
- 输入框自动长高（约 4 行封顶内滚）；有文字时语音位换发送钮。

**验收点（开发自验）**：analyze/test 过。
**真机验收点**：①键盘↔⊕↔贴纸坞反复切换无闪烁无跳变、输入栏不弹跳；②键盘收起后 ⊕面板自动回位；③点表情不打断输入（插入文本不弹键盘）；④贴纸包发送直接成为 sticker 消息；⑤自定义表情包可添加/发送/删除。

### Step 7 · 消息操作（附录 B·长按动效）
- 长按气泡 ≈480ms：**气泡 scale 1.02 微放大 + 抬升阴影，操作菜单就近展开**（不飞到屏幕中央）。
- 菜单项对齐 Web ops 行 + 原生惯例：复制（原生加）、引用、置顶/取消置顶、记入时光、撤回（仅本人且 2 分钟窗口内显示，超窗不显示）。
- 引用：底栏「引用：xxx + 取消」；发送带 `reply_to{id,text}`（text 截 60 字）；气泡内引用块点击跳回原消息并高亮闪烁 ≈1.4s（Web flash 口径）。
- 置顶：`POST /records/{id}/pin` toggle；页顶置顶栏显示最新一条（>1 条显总数），点击跳转。
- 撤回：确认弹层 → `/recall`；撤回态渲染进列表。
- 记入时光：按决策点 2 实施。
- 点按态：Web 有「点一下展开 ops」（沉浸式下）；原生统一收敛为长按菜单，点按行为留给媒体播放/引用跳转——对照差异记入对照清单注明。

**验收点（开发自验）**：撤回窗口显隐判定单测。
**真机验收点**：①长按有 1.02 微放大动效、菜单出现在气泡附近；②引用→发送→点引用块跳回原消息高亮；③置顶/取消置顶双向生效、置顶栏正确；④2 分钟内本人可撤回、超 2 分钟无撤回项、对方长按无撤回项；⑤复制可用。

### Step 8 · 位置与歌曲卡片
- 位置：geolocator 拿经纬度（精度 1e-5 取整，enableHighAccuracy，权限被拒给中文指引）→ 发 `location{lat,lng}`；卡片「位置 · 点开用高德地图看」→ url_launcher 走 `androidamap://` scheme，回退 `https://uri.amap.com/marker?...&callnative=1`（对齐 Web openMap 顺序，无需 KEY）。
- 歌曲：⊕「音乐」→ 在线搜索 `/api/music/search`（iTunes 30 秒试听）选择后发 `song{title,artist,src,art,dur}`；气泡内歌卡可试听（同源 `/api/music/stream` 转发）；「从歌单选」入口注明归属条目 6（见决策点 4）。

**验收点（真机）**：①发位置→点卡片唤起高德（未装则回落网页地图）；②在线搜歌→发送→对方点开可试听 30 秒；③权限被拒提示指引用户去系统设置。

### Step 9 · 聊天背景与气泡皮肤
- 背景：7 预设 +「用照片」（上传/从媒体库选）+ 遮罩 dim(0–80)；存 `PUT /api/space` 的 `chat_bg*` 字段；**每人一份**（`chat_bg_users[uid]`，可替对方设，Web 同款「设给谁」选择器）；照片背景全屏铺（头部/输入栏压图上）+ 沉浸式半透明排版。
- 皮肤：`/api/bubbles` 分组网格（2000+ 张分批加载，滚动到底续载）、预览行（同款左右规则）、字色深/浅、左右互换开关、恢复默认；落 `chat_bubble/chat_bubble_fg/chat_bubble_swap`，气泡九宫格拉伸（border-image 等价：Flutter 用 `Container` + `DecorationImage` 九宫格 `centerSlice`）。

**验收点（真机）**：①换背景双向生效、dim 滑杆即时可感、文字任何底图上可读；②替对方设背景对方生效；③照片背景沉浸式排版正确；④换皮肤双向生效、预览与实际一致（左右规则相同）、字色/互换开关有效；⑤「不用皮肤」可恢复默认。

## 2. 需要主人拍板的决策点

| # | 事项 | 建议 |
|---|---|---|
| 1 | 「相册」格子口径：Web 是**服务器媒体库**选择器（含上传入口），不是本机相册 | 按对齐 Web 实施（可看已传图不重复上传）；本机相册直选由「拍摄/上传」入口覆盖 |
| 2 | 「记入时光」去向：时光 composer 属条目 4 未迁移 | 建议做**最小发布弹窗**（文字+沿用媒体，POST kind=post），不留死卡片；否则点击提示「条目 4 迁移后开放」 |
| 3 | ⊕面板跨页 8 格（共同年历/恋爱清单/共同愿望/共同账本/生理期/数据看板/回忆周报/情侣摆拍） | 跳对应占位 tab/页 + 注明条目编号（对齐首页「不留死卡片」通则）；摆拍是 iframe 页，跳占位提示 |
| 4 | 歌曲卡片「从歌单选」：歌单在条目 6 | 首版只做在线搜索发送+试听，歌单入口先隐藏或注明归属（避免半残入口） |
| 5 | 新依赖 5 个：video_player / audioplayers(或 just_audio) / record / geolocator / url_launcher | 逐个加、每加一个复验构建（gradle intermediates 坑已知）；iOS 侧 CI 阶段 3 才要求全绿 |
| 6 | 点按 vs 长按：Web 触屏「点一下展开 ops 行」，原生方案收敛为长按菜单 | 长按为主（方案 §阶段 3 定版），对照清单注明差异 |

## 3. 最终交付物

- 一个提交（Step 1–9 合并）+ 小结（做了什么 / 对照清单 / APK 路径）。
- 构建覆盖安装一次：`flutter build apk --release --split-per-abi --target-platform android-arm64` → `adb install -r app-arm64-v8a-release.apk`（arm64 versionCode=2001）。
- **逐项手动验收清单**（真机，主人执行）：按 Step 2–9 的真机验收点汇总成序号清单，每项写操作步骤 + 预期结果；首页通则项（返回路径按钮+手势）必列。
- 对照清单：以 `static/chat.js` 为准逐项过（时间条/增量对账/贴纸 IO 门控/背景缓存等 Web 内部优化在 Flutter 的等价实现方式，逐项注明）。

## 4. 明确不做（本条目）

- 全量搜索（Web 也只筛最近 200 条，页内同口径）；聊天记录导入页（`data-nav="imports"` 头部按钮 → 占位提示，归属条目 9）。
- 后端任何改动；新消息免打扰/推送（阶段 5 路线 A）。
- 一起看（v1.7.0 已下线，不在对照源）。
