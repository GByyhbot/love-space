# 「UI/布局优化」章迁移清单（2026-11-15 **定案** · 段 A 已实现（待 QA）2.2.8/VC228 · 段 B 已实现（待 QA）2.2.9/VC229 · **段 C 已实现（待 QA）2.3.0/VC230**）

> **段 D 暂停（主人 2026-11-16 裁定），改道视觉对齐 Web 线**（`web-visual-plan.md`，试点段 2.3.1/VC231：壳层 chrome + 首页 1:1）。

> 出处与口径：本章由**四路并行只读调研**（A 视觉一致性逐页 / B 设计 token 抽取+深色字号 / C 布局问题证据化 / D 交互对账+遗留复核）+ 主理人抽查汇编；抽查实读 3 处关键条目（`home_page.dart:225-235`、`period_page.dart:301/:336`、`bubble_skin_sheet.dart:113-134`）全部属实。**结论逐条附 `文件:行号`，拿不准一律写「未核实」，不许推测**。
> 状态：**2026-11-15 主人已拍板 D1–D7（第四节「决策点定案」），本清单由调研稿转定案**；段 A（错误通道欠账清偿）随 2.2.8/VC228 执行中，B/C/D 段按第五节「分段建议与版本位」固定版本位逐段放行。
> 体例沿用 `app-flutter/docs/settings-period-plan.md`（调研稿）。
> 调研时基线：HEAD `5863fee`（段 C 2.2.7/VC227 已交付）。**数据/通知章已关章（D 段 imports 跳过不做，主人 2026-11-15 拍板），2.2.8/VC228 版本位空出，本章从 2.2.8 起排**。
> 本段边界（段 A）：只动错误通道；不顺手改布局、不动 token、不碰视觉（B 段的活）；后端 `app/` / `static/` / `android-app/` 零改动；`chat-final-checklist.md` 保持未跟踪。

---

## 一、边界与既有定案（已核实，不再复议）

| # | 定案 | 出处 |
|---|---|---|
| 1 | 交互质量口径 = **页面优化计划附录 B（P1.5，叨叨AI 口径）**：动效三档 120/220/320ms、统一缓动（进入 ease-out/退出 ease-in/跟手 linear+弹簧）、错峰 40–60ms、四段反馈完整性、毛玻璃只静态区、动画区禁 blur、只用 transform/opacity | `D:/yang/Downloads/love-space-page-optimization-plan.md:75-110` |
| 2 | 🔴 **键盘/输入区是禁区**：附录 B 全部动效「不得以重构键盘逻辑为前提」；Flutter 端 A 类落盘逻辑逐字节等价 `e6cf8d1`、`chat_compose.dart` 槽位/电梯为刻意设计（`keyboard_metrics.dart:44-56`）——本章**不碰**键盘高度计算 | 优化计划 `:11`；MEMORY「键盘避让」节 |
| 3 | 🔴 **性能纪律**：动效只用 opacity/transform；毛玻璃只在静态区——Flutter 端已 100% 达标（`BackdropFilter` 全 lib/ **0 处**），本章任何动效不得引入 blur | 优化计划 `:19`；路 D 实测 |
| 4 | 聊天诊断包四项（items2-5）验收口径与源 commit：`8834803`；E7a-E7d 在 `chat-final-checklist.md:136-139` | `2026-11-11.md:121/:126` |
| 5 | 错误通道纪律（7-C 返修定案）：`validateAppStatus` 放行 4xx → 写方法显式 `writeResponseError`、detail 原文透传、不假成功；测试夹具必须与生产共用 `validateAppStatus` 形状 | `api_client.dart:267-279/:323-336` |
| 6 | 深色/字号两档机制：`ColorScheme.fromSeed` 双亮度同构（`main.dart:201-222`）+ 全局 `TextScaler.linear(fontScale)`（1.0/1.08/1.16，`main.dart:226-230`）——**写死 fontSize 也跟随缩放**（无失效点、无局部 Theme 包裹、无 noScaling 豁免），风险只在「固定高度容器 × 放大」与「写死颜色」 | 路 B 实读 |

---

## 二、现状盘点

### 2.1 全页共同点（真正同口径的基线，改动别破坏）

- `automaticallyImplyLeading` 全项目无一处显式关闭（grep 仅注释）——二级页统一默认返回 + 系统手势。
- Material 3 + `ColorScheme.fromSeed` 单源主题，无页面级 `Theme(data:)` 包裹（全 lib **0 处**，仅 `main.dart:201` 定义）。
- 空态三段式：图标 size 44 + outline 色、`titleMedium` 主句、`bodySmall+outline` 副句（`timeline_page.dart:245-253`、`album_page.dart:605-613`、`tool_pages.dart:78-86`、`personal_page.dart:208-215`、`messages_page.dart:504-509`）。
- 删除确认弹层统一：AlertDialog + TextButton 取消 + FilledButton(error 底色) 删除（`album_page.dart:461-470`、`tool_pages.dart:161-169`、`personal_page.dart:251-258`、`post_card.dart:344-347`）。
- 写操作结果统一走全局 ChatToastHost（30+ 处，主/错误 tone 区分）。
- Card + InkWell borderRadius 12 是入口卡事实标准；列表卡 margin bottom 10（`tool_pages.dart:124`、`personal_page.dart:305`、`channels_page.dart:248`）。
- 辅助文字统一 `bodySmall + colorScheme.outline`（80+ 处无一例外）；下拉刷新统一 RefreshIndicator。

### 2.2 设计 token 现状抽取（路 B 全量统计，范围 lib/ 87 个 .dart）

**间距**：`all(16)`×30 vs `all(14)`×10（同为卡片内 padding 两种主流并存）；行条目 `fromLTRB(14,12,8,12)`×7 vs `(14,12,14,12)` vs `all(12)` 三种；**页面底部留白 24/28/32/40/88/100 六种并存**（`fromLTRB(16,8,16,88)`×7 主流；`period_page.dart:106` 用 100；`settings_page.dart:187` 40、`notices_page.dart:228` 28、`period_analysis_page.dart:69` 32、`together_page.dart:62` 24）；SizedBox height:6×58 与 height:8×72 并存（half-step 未定档）。

**圆角**：10×28 / 12×22 / 8×15 / 6×9 / 4×8 / 16×6 / 20×4 / 14×3 / 9×2（孤值）——Card 走 M3 默认 12（**无 cardTheme**，grep 0 处），自定义 12/14/16 三档混用（`post_card.dart:54`=16、`home_page.dart:139`=14）。

**字号/字重**：TextTheme 主体健康（bodySmall×200、labelSmall×91、titleMedium×54）；**写死 fontSize 39 处**，语义文本小字档 10×10/11×11/12×6/13×9 混用（emoji 装饰 14-30 约 20 处另计）；写死 FontWeight 12 处：w600×9 / w700×3 / **w800×2（`chat_toast.dart:495/:726` 全库孤值）**。

**颜色**：`Color(0x` 写死 54 处（沉浸式页有意设计约半数，合规）；**无主题分支的写死色**集中在经期页与 chat_toast 语音面板（见 3.1-G10/G11）。

### 2.3 交互质量层现状（附录 B P1.5 逐项对账，路 D）

| 条目 | 判定 | 关键证据 |
|---|---|---|
| B-1 三档 120/220/320ms | **部分** | 三档仅集中 `chat_toast.dart`（120×3/220×4/320×4），另有 150/250/260/240/200/180/80 等 **14 种散值**；Web `--dur-1/2/3`（`style.css:2627`）未移植 |
| B-1 统一缓动 | **部分** | easeOut×4/easeOutCubic×3/easeOutBack×3/easeIn×3/easeInCubic×1，方向感对齐但无常量 |
| B-1 错峰 40–60ms | **部分** | 仅时光页 `_RevealCard`（40ms 步进封顶 600ms，`post_card.dart:359-392`）；其余列表无错峰 |
| B-1 四段反馈 | **部分** | 发消息/立即备份/导出/发记录四操作均有 busy 态，按压段无轻压回弹 |
| B-2 发送三态 | **部分** | 上传中%/三点跳动/失败红「点击重试」三态齐且测试锁定（`messages_page.dart:967-1036`、`chat_send_test.dart:111/:123/:139/:163`）；**失败摇头、bubble-pop 微动效未移植**（Web sw290） |
| B-2 长按菜单 | **已落实** | `AnimatedScale 1.02`(150ms)+就近展开+E7c 全套参数零漂移（`messages_page.dart:871-873/:126-179`） |
| B-2 输入区小件 | **部分** | ⊕面板 16 格 InkWell ripple 无按压回弹（`chat_compose.dart:864-879`）；语音按钮是全屏遮罩非「录音条」形态 |
| B-3 相册全屏详情转场 | **部分（主体已落实）** | Hero 双向共享转场已落实（`album_page.dart:664-665` ↔ `album_viewer_page.dart:477-484`，来源 `5d7d693`）；「封面堆叠展开」未做 |
| B-3 时光托盘/筛选滑动 | **未做** | 评论=模态 BottomSheet 非「卡片不动托盘展开」（`post_card.dart:172-178`）；筛选=下拉框+chips，无标签横滑/指示底色滑动（`timeline_page.dart:146-201`） |
| B-3 进度底色/步骤条 | **部分** | quest 有 `LinearProgressIndicator` 进度卡（`quest_page.dart:82-95`）但勾选无动效、无完成提亮；打卡/纪念日无步骤条 |
| B-4 多选操作栏 | **未做** | 相册/时光均无多选模式（`album_page.dart:171/:295/:452-480` 仅相册级操作） |
| B-4 选择器选型 | **未做（规范缺位）** | SegmentedButton/Dropdown/ChoiceChip/FilterChip/TextButton tab 五种各页各做一套（`wallpaper_sheet.dart:172-179`、`timeline_page.dart:149/:186`、`quest_page.dart:293-301` 等） |
| P1-1 性能纪律 | **已落实** | `BackdropFilter` 全 lib/ 0 处；动效组件 17 处全 opacity/transform；唯一例外=键盘电梯 AnimatedContainer 动 height（刻意设计，`chat_compose.dart:746-751`） |

### 2.4 遗留对账（诊断包四项 + 错误通道存量，路 D）

**诊断包四项复核**（`git log 8834803..HEAD -- <file>` 逐文件取证）：

| 项 | 判定 | 现状 |
|---|---|---|
| E7a 键盘等高 | **已落实**（修复性增强） | 口径逐项在（`keyboard_metrics.dart:21/:27-34/:50-56`）；其后 2 commit `2481a36`/`5e193de` 改读 `View.of(context)` 原始 insets——机制增强非漂移 |
| E7b 外壳视觉统一 | **已落实（口径已换代）** | 清单记的 α0.85/α0.9 已被替代为**五处唯一 `chatChromeAlpha=0.72`**（`chat_chrome.dart:18`，换代 commit `3f1f03e`→`7f4c3ca`）——E7b 验收值需按 0.72 更新 |
| E7c 长按菜单 | **已落实（零漂移）** | `git log -L 128,178:messages_page.dart` 最后一次改动就是 `8834803` 本身 |
| E7d low_freq 缓存 | **已落实（零漂移）** | `git log 8834803..HEAD -- low_freq_cache.dart` = 空；365 天/2000/retainLatest 全在（`low_freq_cache.dart:27-35/:59-91`） |

**错误通道存量欠账**（全量排查 dio.post/put/delete；已接清单见附录 A.3，这里只列欠账）：

| 文件:行号 | 请求 | 现状与风险 |
|---|---|---|
| 🔴 `chat_media.dart:87-97` `uploadChatMedia` | POST /api/media | **最险**：422/413 放行后 `['id'].toString()` 得 `"null"` → 拿 "null" mid 继续发消息 = 假成功链（5 个调用方全中招：`chat_state.dart:675`、`chat_compose.dart:490`、`wallpaper_sheet.dart:82`、`composer_sheet.dart:484`、`music_page.dart:628`） |
| 🔴 `test/chat_media_test.dart:229` | 测试夹具 | 用 Dio 默认 validateStatus → 422 抛异常被 errorDetail 接住 → **测试假通过**，与 `api_client.dart:275-278`「生产与夹具共用形状」明令相悖（checklist:59 B6「422 文案透传」真机列「—」未验，互证） |
| `api_client.dart:44-51` `uploadMedia` | POST /api/media | 未接（头像等） |
| `chat_state.dart:519/:528/:535/:749` | pin/recall/sendToMoment/markRead | 未判 4xx：pin 误更新、recall 照常 `_patchRecordLocally` 假成功、sendToMoment 假成功、markRead 静默（低危） |
| `together_controller.dart:109/:129/:160/:178/:194` | POST/PUT/DELETE /api/records* | **5 写全未接**：4xx 放行 → `load()` + 返回 null → 清单/愿望/问答/打卡弹「已保存」假成功 |
| `home_page.dart:765/:770` | POST/PUT mood | 未接；且错误文案 `'保存失败：$e'` 非 detail 原文 |
| `bubble_skin_sheet.dart:122`、`wallpaper_sheet.dart:137` | PUT /api/space | 裸 await → 4xx 放行 → 照常 reload+pop **假成功**；payload 已以完整 spaceRaw 为底（防抹除达标，C13/E10 口径） |
| `auth_state.dart:268` logout | POST /api/logout | 裸 await（本地清态为准）风险极低 |
| ⚠️ `chat_repository.dart:61-68` `sendChatBody` | POST /api/records kind=chat | 4xx 时 fromJson 抛错走 pending 失败态（功能安全可重试）但拿不到 detail 原文 |

> **段 A 落地备注（2.2.8/VC228，待 QA 验证）**：上表全部清偿——`uploadChatMedia` 接 `writeResponseError` 抛 `MediaValidationError`（message=detail 原文）+ 5 调用方逐一核查直通；`chat_media_test.dart` 夹具改与生产共用 `validateAppStatus` 形状 + 补 4xx 用例；`api_client.uploadMedia` 4xx 包回 `DioException(badResponse)`（与 5xx 同通道）；together_controller 5 写 / home mood 2 写 / bubble_skin_sheet / sendChatBody / logout 全部接显式判（sendChatBody 的 detail 原文进 pending 失败态保留可重试）；每处一条 4xx 单测见 `test/ui_polish_a_test.dart`。D9 护栏（notify_a_test）由「2dcb4a4 全文逐字比对」改为语义断言（占位仍在 + 无真跳转），原因：段 A 合法改动 chat_compose catch 分支。

> **段 B 落地备注（2.2.9/VC229，待 QA 验证）**：必改 4 项（S1/G10/G11/G19）+ token 全量收敛（间距/圆角/字号/动效四类，D6 三处写死色随段）。纪律：只改取值来源，不改行为、不改 widget 树形态；2.1 基线 10 条经 `test/ui_polish_b_test.dart` 源码级逐条复核仍成立。令牌文件：`lib/core/theme/tokens.dart`（Spacing/AppRadius）+ `lib/core/theme/motion.dart`（Motion 三档）；`cardTheme`（AppRadius.card=12）落 `main.dart` ThemeData。**改动明细**：
> - **S1** `home_page` 卡头部昵称 Expanded+ellipsis（信息结构不变）；长昵称夹具暴露同卡操作行（Spacer+长提示语，320 宽 +8.2px）与 S2 `_MoodRow`（昵称非 flex）两处预存 overflow，一并 Flexible+ellipsis 修复（S2 属段 B 计划范畴）。
> - **G10/G11** `period_page` 黑87/黑54 → `colorScheme.onSurface`（浅=近黑/深=近白自适应）；**G19** `timeline_page` `Colors.grey` → `colorScheme.outline`（与 2.1 辅助文字口径同源）。单测深浅两亮度断言 widget 实际 Color 来自 Theme。
> - **G19 附带修复（原逻辑缺陷，非设计变更）**：`itemCount` 原式只在 `hasMore`/`loading&&!hasMore` 时留尾槽，而页脚分支要求 `!hasMore && posts.isNotEmpty`——页脚在正常到底态**永远不可达**（真机从不出现）。一行补齐槽位还原页脚意图。
> - **间距对照**：卡内 `all(14)`×10 + 卡内 `all(16)`×20 → `Spacing.cardPad=16`（G2，取主流值）；页面底部留白 `88`×7 / `100`×1 / `40`×2 / `32`×1 / `28`×2 / `24`×4（`fromLTRB` 底值，新增 channels:206/:516、dashboard:63 按规则入集）→ `Spacing.pageBottom=88`（G1 规则：滚动内容页统一底白 88，避让口径=底栏/悬浮操作+呼吸）；`SizedBox(height:6)`×58 → `Spacing.gapTight`、`(height:8)`×72 → `Spacing.gap`（half-step 两枚并存，**归并 6→8 待主人裁定**，裁定后删 gapTight 全局替换即可）。
> - **圆角对照**：`circular(10)`×24 → `AppRadius.sm`；`circular(12)`×21+`Radius.circular(12)`×3 → `AppRadius.card`；`circular(14)`×3（14 归档）+`circular(16)`×6+`Radius.circular(16)`×10 → `AppRadius.lg`（G3 四档收敛为 10/12/16 三档）。残留：`chat_compose`×5（键盘/输入区禁区不碰）、`circular(1.5)`×3（细线指示器）、`circular(9)`×2（U7 未定性孤值）。
> - **字号对照**：语义小字档 `fontSize:10`×10+`11`×11 → `labelSmall`；`12`×6+`13`×9 → `bodySmall`（共 36 处清零，±1px 视觉差为收敛固有）。残留白名单：emoji 装饰档 14-30 ×28 保留（D2 定案）；`size*0.38` 头像缩放 ×3、`isValue?10:9` 图表微标签 ×1（参数化，需自造档位，段 C 议）。
> - **动效对照**（≤160→fast/161-280→base/281-320→slow）：`120`×3+`150`×3 → `Motion.fast`；`180`×1+`220`×2+`240`×2+`250`×3+`260`×3 → `Motion.base`；`300`×1+`320`×3 → `Motion.slow`（共 23 处归档）。白名单 12 处：timeline:63 搜索防抖 480、post_card:376 错峰延迟入参、chat_toast:96 toast 计时 2200 / :168 退出收尾 320 / :543 计时 ticker 60、chat_compose:333 振幅采样 80（禁区）、song_picker:234 首帧延迟 480、sse:138 重连退避、keyboard_metrics:56 键盘电梯 200（定案#2 唯一例外）、messages:925 闪烁循环 1400 / :1058 三点循环 1100 / media_bubble:243 声浪循环 800（repeat 循环不套三档）。
> - **写死色残留（白名单）**：`Color(0x`×45（chat_toast 微信语义色板 ×10、经期页沉浸 phase 色板/日历 ×15、messages/皮肤气泡 ×7、wallpaper ×5、chat_chrome ×2、其余散点）；`Colors.white/white70/white60/white54/white24`×60（图上/ scrim/语音面板覆盖层）；`Colors.transparent`×11；`black45/38`×4（图上角标底/阴影 blur 色）；`period_page:285 Colors.grey`（phase 色板未知段 fallback，沉浸式有意设计）；`composer_sheet:758 Colors.grey`（建议级，段 C）。`black87/black54` 已清零（仅存注释）。
> - **门禁**：`flutter analyze`+`dart analyze` 0 issues；全量 `flutter test` 通过（见段 B 小结，known flaky 2 项除外）；新测试 `test/ui_polish_b_test.dart` ×10（S1 两形态 / G10·G11 深浅 / G19 深浅 / token 常量 / 引用纪律 / 关键页面护栏 / 基线十条）。

> **段 C 落地备注（2.3.0/VC230，待 QA 验证）**：三态统一（G14/G15/G16 + D4 选 b）+ half-step 归并 + G5 + 段 B 残留 fontSize 收编 + quest 写失败丢草稿修复。纪律：只改呈现层，不改数据流/请求时机、不新增 provider、不重构 build 骨架；段 A 错误通道与段 B 令牌纪律零回归；键盘/输入区禁区不碰；D9 占位不动。**改动明细**：
> - **统一组件（新增 `lib/core/ui/`）**：`progress.dart` AppProgress（G16 三种 spinner 包装收编为单一形态：Center + 纵向留白 48）；`empty_view.dart` AppEmptyView（三段式基线：图标 44+outline / titleMedium 主句 / bodySmall+outline 副句，页内空态留白统一 48）；`error_view.dart` AppErrorView（图标+detail 原文+重试按钮，重试走调用方既有回调=ref.invalidate / 控制器既有 load，不自造数据）+ AppErrorText（行内错误口径 bodySmall+error，收编裸 TextStyle）。
> - **三态优先级落法**：loading（首拉）→ error（列表为空时 AppErrorView 可重试）→ empty → data；**已出数据后的局部刷新失败维持行内 AppErrorText**（呈现位不动）。
> - **逐页销账**：✅改——home（裸 Center×2→AppProgress；「加载失败+重试」Column→AppErrorView，detail=errorDetail 原文）、dashboard（Padding(32)→AppProgress；首拉失败→AppErrorView(retry _load)，局部失败→AppErrorText）、notices（Padding(28)→AppProgress；段 A NotifyErrorBanner 双呈现通道**不动**）、timeline（页内 Text 错误→AppErrorView(retry load(reset:true))；骨架屏/空态/页脚维持现状）、profile（裸 TextStyle→AppErrorText，写失败 toast 通道不动）、mood/note/wish（ToolScaffold 加 loading 门 + 空态/错误态收编）、quest/ledger/music（loading 门 + 空态收编 AppEmptyView + 空态且失败→AppErrorView(retry load)；ledger 24/quest 32 留白归档 48）、personal 五 tab（IndexedStack 各 tab 补 loading 门（diary/draft/surprise=loading、trash=trashLoading、wish=wishLoading）+ 空态且失败→AppErrorView(retry 对应 load)；空态三段式基线维持）。⚪原本合规未动——timeline/album 空态与骨架屏（D4 定案）、messages 空态、tool_pages/personal 原空态三段式形状（仅组件化相邻页）。⚪局部失败已有呈现不动——notices 页内 banner、album 空态 error 槽。
> - **half-step 归并**：`Spacing.gap`(8)×72 vs `Spacing.gapTight`(6)×58（grep 引用数）→ 归并到引用多的 **gap(8)**；全局替换 24 文件 + 删除 gapTight 常量；复核 lib/test 0 残留（仅文档与 b_test 注释提及）。
> - **G5**：chat_toast w800×2（:496/:724 行号随注释偏移）归档既有高亮档 **w700**（依据：w700 为同文件既有先例「松手 编辑文字」:709，w800 全库孤值无存在必要；w600×9/w700×4 既有分布不变）。
> - **fontSize 收编 7 处**：chat_toast 15px 语义文本×4（:476/:495/:723/:795 原行号）→ bodyLarge（16，±1px 收敛固有；色板走 G13 白名单不动）；album_viewer 页码 15px → bodyLarge+white（图上白名单）；period_analysis 图表日标签 15px → bodyLarge+bold、心情 chip emoji 14px → bodyMedium（14 等值零视觉差）。**白名单 29 处（QA 复核校正后总数）**：头像缩放 `size*0.38`×3（profile:536/messages:1140/post_card:431，段 B 已列参数化）；图表微标签 `isValue?10:9`×1（period_charts:207，段 B 已列）；emoji/装饰符号档 ×25（D2「emoji 档 14-30 保留」定案覆盖：period_page:374/:415/:424/:651/:710、period_sheets:404/:413/:540/:657、settings:599/:680/:691/:699/:707/:1056、together:284/:333/:384、weekly:338、tool_pages:235/:281、dashboard:290、home:746、messages:302 ♡、chat_compose:989——chat_compose 属键盘/输入区禁区）。收完 grep 复核：语义文本写死 fontSize 清零，残留仅白名单。
> - **quest 写失败丢草稿修复**：`quest_page.dart` 自定义输入「加入清单」原 `_customCtrl.clear()` 在 err 判定前执行——写失败后输入已清。改齐全 App 纪律：只有 err==null 才清空；失败时输入保留、行不关、错误 detail 原文走 toast error tone（可原地重试）。精选 chip 分支无输入可丢，无需改。单测见 `test/ui_polish_c_test.dart`。
> - **文档对齐**：`chat-final-checklist.md`（未跟踪）E7b 加注「验收值已换代：五处唯一 chatChromeAlpha=0.72（chat_chrome.dart:18，换代 3f1f03e→7f4c3ca），原记 α0.85/α0.9 为史实存档」。
> - **门禁**：`flutter analyze`+`dart analyze` 0 issues；全量 `flutter test` 通过（known flaky 2 项除外）；新测试 `test/ui_polish_c_test.dart`（三态组件断言 / 9 页 loading 行为 / quest 失败保草稿 / 深浅两档颜色来源 / half-step 无残留引用）。

---

## 三、问题清单（分组 × 严重度：必改 / 建议 / 可选）

### 3.1 全局基线类

| # | 严重度 | 问题 | 证据 |
|---|---|---|---|
| G1 | 建议 | 页面底部留白 24/28/32/40/88/100 六种并存，无统一口径 | `period_page.dart:106`(100)、`settings_page.dart:187`(40)、`period_analysis_page.dart:69`(32)、`notices_page.dart:228`(28)、`together_page.dart:62`(24)、`tool_pages.dart:68`(88) |
| G2 | 建议 | 卡片内 padding `all(14)`×10 与 `all(16)`×30 两种主流并存 | `settings_page.dart:230` vs `backups_page.dart:158` |
| G3 | 建议 | 圆角 10/12/14/16 四档混用，Card 无 cardTheme（M3 默认 12） | `media_bubble_widgets.dart:45`(10)×28、`post_card.dart:54`(16)、`home_page.dart:139`(14)、grep cardTheme=0 |
| G4 | 建议 | 语义文本写死 fontSize 39 处（10/11/12/13 小字档混用），绕过 TextTheme | `channels_page.dart:524`(12)、`shell_page.dart:105`(13)、`period_form.dart:259`(12) 等（全清单见路 B 报告） |
| G5 | 可选 | FontWeight w600/w700/w800 三档混用，w800 全库孤值 | `chat_toast.dart:495/:726`(w800)、`backups_page.dart:243`(w700) |
| G6 | 建议 | 动效时长 14 种散值无令牌（Web `--dur-1/2/3` 未移植） | grep `Duration(milliseconds:` 33 处；`messages_page.dart:374-382`(250) |
| G7 | 建议 | 错峰入场仅时光页有，其余列表全员同时动 | `post_card.dart:359-392` vs grep stagger 全 lib 仅 1 处 |
| G8 | 建议 | 空态竖直留白五种（48/32/24/全屏 Center/卡片空态） | `tool_pages.dart:76`(48)、`quest_page.dart:103`(32)、`ledger_page.dart:196`(24) |
| G9 | 建议 | 危险操作按钮两形态：FilledButton error 底色（删除类）vs OutlinedButton error 描边（退出登录） | `album_page.dart:465-467` vs `profile_page.dart:493-496` |
| G10 | **必改** | 经期页「今天」竖线 `Colors.black87`——深色 surface 上不可见 | `period_page.dart:301` |
| G11 | **必改** | 经期页风险提示项目符号 `Colors.black54`——深色下对比不足 | `period_page.dart:336` |
| G12 | 建议 | 经期周期条白字画在 alpha 0.45 浅色相上，对比不足 | `period_page.dart:292`（`fontSize:10 + Colors.white`） |
| G13 | 建议 | chat_toast 语音面板写死色板无主题分支（微信风格语义色，深色下表现未核实） | `chat_toast.dart:402-404/:760/:796` |
| G14 | 建议 | 错误呈现四形态分流：页内 Text(error色) / chatToast / NotifyErrorBanner+chatToast 双呈现 / 裸 TextStyle 无 error 色 | `timeline_page.dart:256-258`、`notify_widgets.dart:19-25`、`profile_page.dart:415-416`(裸) |
| G15 | 建议 | 加载态：骨架屏仅 timeline/album 两页且样式互不相同（卡片形 vs 灰格子）；**personal 五 tab + mood/note/wish + quest/ledger/music 共 9 页无任何加载态**（首拉可能闪空态，未核实真机观感） | `timeline_page.dart:300-345`、`album_page.dart:624-635`、`personal_page.dart`（全文件无 CircularProgressIndicator） |
| G16 | 建议 | spinner 包装三种（裸 Center / Padding(32) / Padding(28)） | `home_page.dart:105`、`dashboard_page.dart:71`、`notices_page.dart:252` |
| G17 | 可选 | 主操作载体三形态并存：工具页 FAB.extended / notices·channels AppBar TextButton / timeline 页头按钮 | `tool_pages.dart:59-64`、`notices_page.dart:217-221`、`timeline_page.dart:114` |
| G18 | 建议 | 大数字强调三档并存（headlineSmall/titleLarge/displaySmall） | `ledger_page.dart:117`、`dashboard_page.dart:169`、`home_page.dart:359` |
| G19 | **必改** | timeline「没有更多了」硬编码 `Colors.grey` 未走 colorScheme，夜间模式不可控 | `timeline_page.dart:283-284` |
| G20 | 可选 | hub 入口卡标题同屏两档（工具卡 titleMedium vs 设置卡 titleSmall） | `together_page.dart:338` vs `:289` |

### 3.2 单页类

| # | 严重度 | 页面 | 问题 | 证据 |
|---|---|---|---|---|
| S1 | **必改** | 首页 | 「最近的小美好」卡头部 Row：`Text(author.name)` 无 flex/maxLines，长昵称把 `Text(r.date)` 挤出右边界 → RenderFlex overflow 红黄条 | `home_page.dart:225-235`（主理人抽查属实） |
| S2 | 建议 | 首页 | `_MoodRow` 长昵称为非 flex 子项，会把心情气泡 Expanded 压到 0 宽（静默变形） | `home_page.dart:669-671` |
| S3 | 建议 | 首页 | 近 3 条动态标题/正文全文渲染无 maxLines 无折叠（composer 上限 20000 字） | `home_page.dart:241-252`、上限 `composer_sheet.dart:665` |
| S4 | 建议→需真机 | 摆拍/发布 composer | 「日期+图/视频+音频」Row 全固定宽无 Flexible，320 屏预期 overflow（360 临界） | `composer_sheet.dart:671-691` |
| S5 | 建议→需真机 | 摆拍/发布 composer | 录音态 Row（计时+暂停+完成+取消）同行固定排布，同类风险 | `composer_sheet.dart:695-740` |
| S6 | 建议 | 时光 | 卡片标题/正文无 maxLines（title≤200、正文 20000 字全文进列表卡） | `post_card.dart:83/:88` |
| S7 | 建议 | 时光→需真机 | 经期四动作 Row（🩸+44px 标签+Spacer+双按钮）按钮态 320/大字体预期 overflow | `period_page.dart:639-669` |
| S8 | 建议 | 共同意愿 | content 全文渲染无 maxLines（上限 20000）；对照私密日记 tile 有 maxLines:3，口径不一致 | `tool_pages.dart:501` vs `personal_page.dart:333` |
| S9 | 建议 | 恋爱清单 | 标题无 maxLines（≤200）；对照共同愿望标题 maxLines:2，两页不一致 | `quest_page.dart:244-248` vs `tool_pages.dart:490-492` |
| S10 | 建议 | 问答/打卡 | title/content/答案框全文无 maxLines（答案≤5000） | `question_habit_pages.dart:82-89/:164/:373-380` |
| S11 | 建议 | 账本 | `_statRow` 标签列 `width:56` 截断 >4 字昵称；金额列 `width:76` 对 ¥99999999.99 临界换行 | `ledger_page.dart:243-247/:255-259` |
| S12 | 建议 | 账本 | 台账备注全文渲染（≤20000）；近六月趋势数值无截断六列各 ~44px | `ledger_page.dart:276-281/:156` |
| S13 | 建议 | 个人角落 | 个人心愿 title 无 maxLines（≤100，对照共同愿望 maxLines:2）；已解锁 content 全文（≤20000） | `personal_page.dart:1056/:1059` |
| S14 | 建议 | 备份页 | `_backupTile` 主行 Flexible 无 ellipsis：超长文件名换多行 + 🔒 尾巴悬挂错位 | `backups_page.dart:314-327` |
| S15 | 建议 | 设置页 | 选中封面文件名 `_picked!.name` 全文渲染无截断 | `settings_page.dart:540-547` |
| S16 | 建议 | 渠道页 | 「已订阅：12 事件拼接」无 maxLines，全订阅时数行撑高卡片 | `channels_page.dart:271-274` |
| S17 | 建议→需真机 | 相册 | 封面卡 ⋯ 菜单 `Positioned(top:-4,right:-4)` 负偏移，Stack 默认 hardEdge 裁剪，按钮被裁角 | `album_page.dart:284-307` |
| S18 | 建议→需真机 | 多页表单弹层 | AlertDialog content `SizedBox(width:360)` 无 SingleChildScrollView（note/wish/ledger/anniversary/quest/music 编辑），小屏+键盘溢出；对照 `period_form.dart:191` 有内滚 | `tool_pages.dart:385-402` 等 |
| S19 | 可选 | 聊天 | AppBar title Row 320 屏+大字体下文本可用宽仅 ~100px（伴侣昵称只显 2-3 字） | `messages_page.dart:300-328` |
| S20 | 建议 | 生理期 | 历史卡 words（当日日记 content）全文渲染（≤20000） | `period_page.dart:884` |
| S21 | 可选 | 一起·日历 | 语义色 0xFF43A047/0xFFFFB300 写死（绿=完成/琥珀=待办），深色下偏刺眼但可读 | `calendar_page.dart:196/:198` |
| S22 | 可选 | 个人角落/工具页 | ListView 预构建 children 非 itemBuilder 惰性（大列表全量构建） | `personal_page.dart:181-226`、`tool_pages.dart:67-89` |

### 3.3 交互类（附录 B 补齐向，均「建议/可选」，与 2.3 对账表对应）

| # | 严重度 | 条目 | 现状缺口 |
|---|---|---|---|
| I1 | 建议 | 动效令牌 | 三档时长+缓动无常量（G6/G7 同源），建议建 `motion.dart` 令牌文件移植 `--dur-1/2/3` |
| I2 | 建议 | 发送失败动效 | 失败摇头、气泡 bubble-pop 未移植（三态数据链已齐，纯呈现层） |
| I3 | 可选 | 时光托盘/标签横滑 | 评论模态 Sheet→托盘形态、筛选标签指示滑动——重形态改造，收益存疑 |
| I4 | 可选 | 进度底色/完成提亮 | quest 进度卡补「勾选平滑前推+完成整体提亮」（底座已有） |
| I5 | 可选 | 多选操作栏 | 相册/时光多选模式整建制新增（当前无载体，属新功能非修复） |
| I6 | 建议 | 选择器选型规范 | 五种控件各页一套，建议落档「≤5 分段/6-12 标签横滑/更多抽屉」规范并逐步收敛 |
| I7 | 可选 | ⊕面板按压回弹 | 16 格无轻压缩放（微反馈档 120ms 可套） |

### 3.4 测试覆盖证据（路 C）

- **有布局断言仅 3 处**：`personal_a_fix_test.dart:256-283`（ShellPage 五 tab 六档扫宽零 overflow，实跑通过）、`chat_merge_fix_test.dart:263/:314`（PostCard 媒体网格）、`voice_overlay_golden_test.dart:58-76`。
- **无任何 widget 测试的页面**：LoginPage、HomePage、TimelinePage 列表本体。
- **有 widget 测试但零布局断言**：Messages/Album/Channels/Notices/Backups/Settings/Profile/Together 全家/Period 全家。

---

## 四、决策点（待主人拍板；每条带主理人推荐）

| # | 决策点 | 选项 | **主理人推荐** |
|---|---|---|---|
| **D1** | **错误通道欠账是否纳入本章** | (a) 纳入并放段 A 最先做；(b) 单独返修包；(c) 不做 | **(a) 纳入、放段 A 最先做**。理由：`chat_media.dart` 是真机阻断级风险（"null" mid 假成功链 + 测试夹具形状漂移），11 处改动全是一行 `writeResponseError` + 一条单测级别，与 UI 无耦合，先做风险隔离，后续 UI 段回归不被污染 |
| **D2** | **token 收敛范围** | (a) 全量收敛（间距/圆角/字号/字重四类 + cardTheme/appBarTheme 补进 ThemeData）；(b) 只收敛最痛三对（14vs16、10vs12、10/11/12/13） | **(a) 全量收敛**，但**一次 token 段做完**、不与布局修复混段（改面大、逐字节可验）；写死 fontSize 全部归 TextTheme，emoji 档 20 处保留 |
| **D3** | **交互质感层补齐范围** | (a) 全做附录 B 差额；(b) 只做轻量项（I1 令牌 + I2 发送失败动效 + I4 完成提亮 + I6 规范落档），重形态（I3 托盘/标签横滑、I5 多选）砍或缓 | **(b) 轻量项做、重形态缓**。托盘/标签横滑/多选属重形态改造且现功能可用，与「布局优化」章定位不符，建议砍出本章或等主人单独立项 |
| **D4** | **加载态统一方案** | (a) 全页铺骨架屏；(b) 轻量统一 loading 组件（统一 spinner 包装 + 9 页补 loading 态），骨架维持 timeline/album 现状 | **(b)**。9 页补 loading 是修复缺失（防闪空态），铺骨架是增强，成本收益不匹配；两种骨架样式是否统一也一并在 (b) 内定 |
| **D5** | **危险操作按钮统一** | (a) 统一 FilledButton error 底色（退出登录也改实心）；(b) 维持两形态并落档语义规则（删除=实心、退出/降级=描边） | **(b) 落档规则不强行统一**。「退出登录」描边红是常见惯例且语义不同，落档「删除类数据=实心 error、会话级=描边」更合理 |
| **D6** | **深色必改项** | G10/G11（black87/black54）+ G19（Colors.grey）是否随 token 段一起改 | **是**，三处都是一行级替换（改 `theme.colorScheme.*`），随段 B 一起、单测断言深浅两亮度下颜色来源 |
| **D7** | **分段与版本位** | 第五节 3+1 段方案是否采纳；错误通道段是否前置 | 采纳与否由主人定；若 D1 选 (a) 则段序为 A(错误通道)→B(布局+token)→C(三态)→D(可选质感) |

### 4.1 决策点定案（主人 2026-11-15 拍板）

| # | 定案 |
|---|---|
| **D1** | ✅ **采纳 (a)**：错误通道欠账纳入本章、放**段 A 最先做**（风险隔离） |
| **D2** | ✅ **采纳 (a)**：token 全量收敛，一次 token 段（段 B）做完；写死 fontSize 全部归 TextTheme，emoji 档保留 |
| **D3** | ✅ **采纳 (b)**：交互质感只做轻量项（I1 令牌 + I2 发送失败动效 + I4 完成提亮 + I6 规范落档）；重形态 I3 托盘/标签横滑、I5 多选砍出本章 |
| **D4** | ✅ **采纳 (b)**：轻量统一 loading 组件 + 9 页补 loading 态；骨架维持 timeline/album 现状（样式是否统一随段 C 定） |
| **D5** | ✅ **采纳 (b)**：危险按钮落档语义规则（删除类数据=实心 error、会话级=描边），不强行统一 |
| **D6** | ✅ **是**：G10/G11/G19 三处写死色随段 B 一改，单测断言深浅两亮度颜色来源 |
| **D7** | ✅ **采纳**：段序 A(错误通道 2.2.8)→B(布局+token 2.2.9)→C(三态 2.3.0)→D 可选(质感 2.3.1) |

---

## 五、分段建议（版本位从 2.2.8 起排；每段一 commit、全项目 analyze+test 全过、停等真机验收）

| 段 | 版本位 | 范围 | 对应问题 |
|---|---|---|---|
| **段 A（若 D1 纳入）** | **2.2.8 (VC228)** | **错误通道补全**：`chat_media.uploadChatMedia` + 夹具形状修复（共用 `validateAppStatus`）、`api_client.uploadMedia`、chat_state 4 写、together_controller 5 写、home mood、两个 space sheet、`chat_repository.sendChatBody` detail 透传、logout（顺手）；每处一条 4xx 单测（detail 原文 + 不假成功断言） | 2.4 欠账表全部 |
| **段 B** | **2.2.9 (VC229)** | **布局修复 + token 收敛**：S1（必改）→ S2-S17/S20 布局条目（Flexible/maxLines/ellipsis/固定列/弹层内滚）；G1-G5/G18-G20 token 收敛（间距/圆角/字号/字重 + cardTheme + 三处写死色）；改面以「逐文件可 grep 验证」为验收口径 | 3.1 全局基线类 + 3.2 单页类 |
| **段 C** | **2.3.0 (VC230)** | **三态呈现统一**：统一 loading 包装组件 + 9 页补加载态（D4 选 b）、错误呈现归一（页内 Text 统一样式 + detail 原文口径）、空态留白归档；顺带 S19/S21/S22 可选项 | G14-G16 + D4/D5 |
| **段 D（可选，D3 拍板后才开）** | **2.3.1 (VC231)** | **交互质感层**：`motion.dart` 令牌移植（120/220/320 + 缓动常量）、发送失败摇头 + bubble-pop、quest 完成提亮、错峰推广到主要列表、选择器规范落档 | 3.3 I1/I2/I4/I6/I7 |

**明确不做（除非主人改定案）**：键盘/输入区重构（禁区，定案 #2）、I3 托盘/标签横滑、I5 多选操作栏（除非 D3 改选 (a)）、任何后端改动、WebPush/渠道等已关闭章范围。

---

## 六、未核实 / 需真机验证清单

| # | 事项 | 佐证缺口 |
|---|---|---|
| U1 | personal 五 tab / 工具页首拉是否闪空态（真机观感） | G15 标注「未核实」 |
| U2 | composer 两行 Row（S4/S5）、经期四动作（S7）320 屏 + 大字体 overflow | 代码推演，可 widget 测试构造复现 |
| U3 | 相册 ⋯ 菜单负偏移裁剪实际视觉（S17） | 默认 hardEdge 推演 |
| U4 | 20000 字长文卡片滚动流畅度与排版（S3/S6/S13/S20） | 需真机低端机 |
| U5 | chat_toast 语音面板写死色板深色下观感（G13） | 面板底色来源未实读到底 |
| U6 | 多表单弹层 + 键盘溢出表现（S18） | 需真机 |
| U7 | `settings_page.dart:763` 圆角 9 是否有意（色块指示器） | 孤值未定性 |
| U8 | 底部导航 fontSize 13/11 放大 1.16 后与图标挤压 | `shell_page.dart:105/:183` 未实测 |

---

## 附录：调研来源与抽查记录

- **A.1 调研路**：A 视觉一致性逐页（10 页区六项全过）/ B token 全量抽取（87 个 .dart 统计）/ C 布局问题（22 条全部代码证据 + 测试盘点）/ D 交互对账（附录 B 13 项 + 诊断包 4 项 + 错误通道全量排查）。
- **A.2 主理人抽查（全部属实）**：`home_page.dart:225-235`（Row 无 flex）、`period_page.dart:301/:336`（black87/black54 在）、`bubble_skin_sheet.dart:113-134`（裸 await + 4xx 放行假成功链）。
- **A.3 错误通道已接清单**（供对照）：`api_client.updateSpace`(:166)、`settings_state.dart:390`、`backups_api.dart:201/:214/:235`、`export_api.dart:240`、`notify_api._write`(:43/:53)、`period_controller._write`(:291 起 7 处)、`personal_controller._writeResponse`(:405 起 7 处)、`auth_state.dart:185/:224/:249`（手写 ≥400 判）、`album_controller.dart:175 起 4 处`、`timeline_controller.dart:225 起 7 处`。
- **A.4 口径原文**：附录 B = `D:/yang/Downloads/love-space-page-optimization-plan.md:75-110`；诊断包 = `chat-final-checklist.md:136-139` + `2026-11-11.md:121/:126` + commit `8834803`。
