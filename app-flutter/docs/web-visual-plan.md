# 「视觉对齐 Web」章 · 试点段 / 推广段一（web-visual-plan.md）

> 状态：**推广段一已实现（待 QA）**——2026-11-16 基于基线 `aee0ba5`（试点 2.3.1/VC231 已验收通过）落地推广段一（版本 2.3.2/VC232），范围：首页收尾（摘除 stats-grid + 修心情胶囊）+ 时光/相册/我们三页形态对齐 + 备案缺陷② composer 日期 Row 溢出；逐项落定见文末「八、推广段一落地备注（2.3.2）」。
> 状态（历史）：**试点段已确认执行（方案 A 浮层重构定稿）**——2026-11-16 主人放行「壳层 chrome + 首页 1:1 还原」试点，版本 2.3.1/VC231；本盘点稿随实现转定案，逐项落定见文末「七、试点落地备注（2.3.1）」。
> 背景：主人裁定 App 观感不如 Web（2026-11-15），段 D 质感项暂停（`ui-polish-plan.md` 头部定案），新开「视觉对齐 Web」线；试点（壳层 chrome + 首页 1:1 还原）已确认执行。
> 体例：沿用 `app-flutter/docs/ui-polish-plan.md`（数值表 + 差异表 + 方案风险 + 未核实清单）。
> 纪律：一切数值从 `static/` 的 CSS/JS 源码实读抽取，每条给 `文件:行号`；App 现状实读 `app-flutter/lib/` 给 `文件:行号`；可复用结论注明「沿用段 B/C 盘点」。未核实单列第六节，不许推测。
> 调研基线：`static/` 为 Web 端当前发布物（`index.html:16` 引 `style.css?v=297`）；App 侧以段 B（2.2.9/VC229）+ 段 C（2.3.0/VC230）收敛后的 token 现值为准（`tokens.dart`、`main.dart:209-213` cardTheme=12）。

---

## 一、Web 设计语言数值表（逐项 + 出处）

### 1.1 底色与卡片

| 项 | Web 数值 | 出处 |
|---|---|---|
| 页面底色（浅·草莓牛奶） | `--bg:#FAF8F9` | `static/style.css:31`（兜底）/:166（theme-rose） |
| 页面底色（夜间） | `--bg:#231B1D` | `style.css:1503`/:1543 |
| 卡片底色（浅） | `--surface:#FFFFFF` | `style.css:32`/:166 |
| 卡片底色（夜间） | `--surface:#32262A` | `style.css:1503`/:1543 |
| 灰面层级 L1（hover 压层） | 浅 `rgba(61,47,51,.045)` / 夜 `rgba(255,255,255,.055)` | `style.css:70`/:1524 |
| 灰面层级 L2（raised/input） | 浅 = `var(--surface)` 同卡色 / 夜 `rgba(255,255,255,.06)` 与 `var(--bg)` | `style.css:79-80`/:1522-1523 |
| 卡片顶部内高光 | `--hairline:inset 0 1px 0 rgba(255,255,255,.72)`，叠加在 `--shadow` 外 | `style.css:1937`/:1941（增强层 B）；夜 `.04` `style.css:2017-2018` |
| 卡片 tint 差异化 | `kind-*` 低饱和渐变：`--tint-rose` rgba(primary,.055) 等六色，`linear-gradient(165deg,tint,surface 72%)` | `style.css:1930-1938`/:1944-1951/:1955-1956 |
| 卡片毛玻璃 | **普通卡片无毛玻璃**；毛玻璃只出现在 chrome（见 1.5/1.6）与弹窗遮罩（blur(10px)，`style.css:1185`） | `style.css:1183-1186` |
| 线条 | `--line:#F0E7EA` / `--line-strong:#E3D1D6` | `style.css:29-30`/:167 |
| 七套主题色板 | rose/peach/lemon/mint/sky/lavender/cocoa 各自 bg/surface/ink/primary/soft/line 一组 | `style.css:165-192`（浅）/:1542-1569（夜）/:195-198（custom） |

### 1.2 卡片圆角与阴影

| 档 | Web 数值 | 出处 |
|---|---|---|
| 圆角刻度 | xs 8 / s 12 / m 16 / 默认 20 / l 24 / pill 999 | `style.css:127-132` |
| 通用卡片 | `--radius`(20)，padding 18，边 1px `--line`，`--shadow` | `style.css:296-297` |
| 卡片（手机 ≤640） | radius **17**，padding 15 | `style.css:1421` |
| 首页 stat/today-cell | 16（手机 14） | `style.css:475`/:1415/:496 |
| 主按钮 | `--radius-s`(12)，small 档 10 | `style.css:243`/:267 |
| 弹窗 modal | `--radius-l`(24)，padding 22，`--shadow-pop`（手机 radius 20、padding 20/18） | `style.css:1187-1190`/:1466 |
| 手机底部弹层 sheet | 顶部 24 | `style.css:1218` |
| 菜单弹层 menu-pop | 16 | `style.css:381` |
| 全局搜索面板 / 挑图面板 | 22（顶部）/ 22 | `style.css:2131`/:2320 |
| 原生顶栏钮 / 返回圆钮 | 50%（pill） | `style.css:279`/:414 |
| 底栏 Dock / nav 项 / 水滴胶囊 | 24 / 14 / 14 | `style.css:2739`/:2743-2745 |
| 阴影基色 | `--shadow-rgb:69,56,63`（夜 0,0,0） | `style.css:135`/:1514 |
| shadow-xs | `0 1px 2px rgba(...,.05)` | `style.css:136`/:1515 |
| shadow（卡） | `0 2px 10px rgba(...,.06), 0 1px 2px rgba(...,.04)`（夜 `0 2px 12px .34 + 0 1px 2px .26`） | `style.css:137`/:1516 |
| shadow-lift | `0 10px 32px rgba(...,.13), 0 2px 6px rgba(...,.06)`（夜 `0 12px 34px .5 + …`） | `style.css:138`/:1517 |
| shadow-pop（弹窗） | `0 18px 44px rgba(...,.20), 0 2px 8px rgba(...,.08)`（夜 `0 20px 50px .64 + …`） | `style.css:139`/:1518 |
| btn-lift | `0 1px 2px rgba(...,.07)`（夜 `.4`） | `style.css:140`/:1519 |
| 主按钮同色柔光 | `0 4px 14px -6px var(--primary), 0 1px 2px rgba(shadow,.08)` | `style.css:254` |
| 聊天发送钮 | `0 4px 12px rgba(var(--primary-rgb),.26)` | `style.css:730` |

### 1.3 色板（草莓牛奶兜底，主题色板见 1.1 末行）

| 色 | Web 数值 | 出处 |
|---|---|---|
| 主色 | `--primary:#953753`，`--primary-dark:#77283F`，`--on-primary:#FFF`，rgb 通道 `149,55,83` | `style.css:24-26`/:48/:167 |
| 淡紫填充（排卵窗） | `--fertile:#7B63A0`（ink `#54407A`，rgb `123,99,160`）；胶囊底 `rgba(var(--fertile-rgb),.34)` | `style.css:61-63`/:1648 |
| 奶油色（琥珀语义） | `--amber:#8A5A22` / `--amber-soft:#F7EEDF` | `style.css:40-41` |
| 粉色渐变①首页 hero | `linear-gradient(120deg,var(--soft) 0%,var(--surface) 55%,var(--green-soft) 100%)`，120deg | `style.css:448`；增强层叠两层 radial 光晕（左上白 .55 / 右下 primary .10）`style.css:1959-1964` |
| 粉色渐变②周期 hero | `linear-gradient(135deg,var(--period-soft),var(--surface) 68%)`，135deg | `style.css:1674` |
| 粉色渐变③进度条/柱状 | `linear-gradient(90deg,var(--primary),var(--primary-dark))`（进度条）；柱 `linear-gradient(180deg,var(--soft-strong),var(--primary))` | `style.css:1064`/:1159/:1589 |
| 语义四色 | green `#4B6B3F`/soft `#EAF1E4`；amber（上）；danger `#A83E45`/soft `#FBE9EA`；info `#3F6A8E`/soft `#E8F0F6` | `style.css:38-45` |
| 遮罩/scrim | `--scrim:rgba(41,31,35,.42)`（夜 `rgba(0,0,0,.66)`） | `style.css:73`/:1530 |
| toast | 浅=ink 底 bg 字（深底浅字），夜反转 | `style.css:82-83`/:1532 |

### 1.4 页头

| 项 | Web 数值 | 出处 |
|---|---|---|
| 大标题 h1 | 字号 `--fs-h1` = 26px（×`--fs-scale`），weight 600，letter-spacing -.3px，行高 1.36，色 `--ink` | `style.css:111`/:212 |
| 副题 p | `--fs-md` 13px，色 `--muted`，margin-top 5px | `style.css:343` |
| 页头容器 | `.page-heading` margin-bottom 16px，flex space-between（右侧可挂主按钮） | `style.css:342` |
| 页头生成 | `heading(title,description,action…)`，标题/副题逐字在各页函数 | `static/app.js:228` |
| 首页页头 | 「我们的每一天 / 一半是生活，一半是你。」 | `app.js:725` |
| 时光页头 | 「时光慢慢，爱意满满 / 那些一起走过的日子，都在这里。」 | `app.js:865` |
| 相册页头 | 「把喜欢的瞬间，装进口袋 / 照片留住的不只是风景，还有身边的你。」 | `app.js:965` |
| 我们页头 | 「关于我们，还有好多好多 / 把喜欢落在实处，把日子过成纪念。」 | `app.js:1229` |
| 生理期页头 | 「生理期 / 记下周期，把照顾提前一点。」 | `static/period.js:513` |
| 页头→首卡留白节奏 | `.main` padding `28px 36px 48px`；手机 `18px 18px 100px`（sw296 后 104px）；topbar 与页头之间 26px（手机 20px）；页头与首卡 16px | `style.css:426`/:1391/:2750/:427/:1397/:342 |
| 手机 h1 降档 | ≤640px 时 h1 用 `--fs-h2`(22px) | `style.css:1401` |

### 1.5 悬浮顶栏圆钮

| 项 | Web 数值 | 出处 |
|---|---|---|
| 右侧钮组间距 | gap 12px（手机 9px） | `style.css:430`/:1399 |
| 圆形图标钮 | 42×42，圆 pill，底 `--raised`，1px `--line-strong` 描边，`--btn-lift` 阴影，图标 19px，色 `--ink-2`；hover soft 底 primary-dark | `style.css:278-284` |
| 账号头像钮 | 44×44，padding 2px，1px `--line`，surface 底 | `style.css:431` |
| 未读角标 | min-width 17、padding 3px 4px，primary 底白字，`0 0 0 2px var(--surface)` 外圈 | `style.css:285-287` |
| 「双人私密空间」胶囊 | `.pill` soft 底 primary-dark 字，padding 6px 12px，`fs-sm`（手机隐藏） | `style.css:293-294`/:1400 |
| 顶栏钉住（桌面） | sticky top:0，bg `linear-gradient(180deg,var(--bg) 55%,rgba(250,246,247,0))` + blur(10px)，z 16 | `style.css:1966-1974` |
| 顶栏钉住（原生 APK） | `color-mix(in srgb,var(--bg) 80%,transparent)` + blur(14px)，负 margin 通宽 | `style.css:2107-2111` |
| 钮的构成 | 深浅切换、搜索、私聊（chat badge）、通知（bell badge）、头像菜单 5 个 + 左侧 pill/日期 | `static/app.js:325` |

### 1.6 悬浮底栏（sw 296 Dock）与中央 + 钮

| 项 | Web 数值 | 出处 |
|---|---|---|
| 容器定位 | `inset:auto 10px calc(10px + env(safe-area-inset-bottom))`（左右下各离边 10px） | `style.css:2738` |
| 容器外观 | padding 6px；1px `--dock-line`（浅 `rgba(0,0,0,.06)`/夜 `rgba(255,255,255,.09)`）；radius 24；bg `--dock-bg`（浅 `rgba(255,255,255,.9)`/夜 `rgba(28,22,30,.78)`）；`backdrop-filter:blur(18px) saturate(1.25)`；shadow `0 10px 28px var(--dock-shadow)`（浅 `rgba(90,50,70,.28)`/夜 `rgba(0,0,0,.55)`） | `style.css:2736-2741` |
| Dock 高度 | 无固定高，由内容撑：nav 项 min-height 46 + 容器 padding 6×2 ≈ 58 + safe | `style.css:2743`/:2738 |
| nav 常规项 | min-height 46、padding 5px 2px、radius 14、icon 20px 上文字下、字 `fs-xs`(11px)；选中字/图标 primary、透明底 | `style.css:2743-2744`/:2701/:1384-1385 |
| 选中胶囊（水滴） | `.nav-pill` 高 44、radius 14，底 `--soft`（夜 `rgba(255,255,255,.14)`），双弹簧边缘动效（width .36s spring / transform .46s 晚 60ms）+ 压扁 pill-squash | `style.css:2696-2702`/:2745-2746`；动效参数 `static/app.js:399-407` |
| 中央 + 钮（FAB） | **46×46 圆形**（sw296 当前值），radius 50%，底 `--primary`，图标 22px 白（on-primary），`span` 隐藏（纯图标无文字），shadow `0 4px 14px rgba(0,0,0,.24)` | `style.css:2747-2749`（前版 52×52/radius16/`0 6px 18px .20` 存于 `style.css:1388-1390`，已被 sw296 覆盖） |
| 凸起形态 | **⚠️ 注释自称「FAB 上浮一半突出 Dock 顶」（`style.css:2734`），但实读规则为 `margin-top:0`（:2747）且 align-self:center（:1388），当前 Web 并无真正凸出/切口——+ 钮嵌在 Dock 行内居中，两侧各留 flex 空位（navHtml.splice(2,…) 插在第 3 位）** | `style.css:2747`/:1388/:307（app.js） |
| 底部让位 | `.main` 手机 padding-bottom 104px（sw296 后） | `style.css:2750` |
| 旧版对照（sw296 之前） | 底栏贴边实色白 `.94`、blur14、无圆角边框；FAB 52×52 radius 16 | `style.css:1381-1390` |

### 1.7 胶囊选中态汇总

| 组件 | 选中态参数 | 出处 |
|---|---|---|
| 底栏 nav 项 | 透明底 + primary 字/图标 + soft（夜白 .14）胶囊背后衬 | `style.css:2701`/:2699/:2746 |
| 页内 tabs | `.tabs button.active`：soft 底 + primary 1px 描边 + primary-dark 字 + 600 + 无阴影 | `style.css:337` |
| 症状 chip | `.sym-chip.on`：primary 实心 + on-primary 字 + 600 | `style.css:1712` |
| 分段钮 | `.seg-btn.primary`：primary 实心 | `style.css:1750` |
| 贴纸 tab | soft 底 + primary-dark 字 + `inset 0 0 0 1px var(--primary)` 内描边 | `style.css:1018` |
| 状态 pill | sent=green-soft/green、failed=danger-soft/danger、pending=amber-soft/amber | `style.css:366-368` |
| 气泡皮肤 tab | `.bp-tab.on`：primary 实心 | `style.css:2479` |
| 主题色卡 | `.theme-swatch.on`：primary 描边 + soft 底 + `0 0 0 3px var(--ring)` 外圈 | `style.css:2419` |

### 1.8 渐变圆环与阶段胶囊（生理期 hero）

| 项 | Web 数值 | 出处 |
|---|---|---|
| 圆环实现 | SVG `viewBox 0 0 72 72`，track/fill 两 circle，`r=31`，`transform:rotate(-90)`，dasharray/dashoffset 按百分比 | `static/period.js:253`/:269-273 |
| 圆环尺寸 | CSS 宽高 74px（手机 ≤640 68px） | `style.css:1697`/:1706 |
| 线宽 | track/fill 均 `stroke-width:9`，fill `stroke-linecap:round` | `style.css:1698-1699` |
| 轨道色 | `rgba(var(--period-rgb),.2)` | `style.css:1698` |
| 进度色 | `var(--period)` —— **纯色描边，无渐变**（主人问的「渐变圆环」在当前 Web 源码中不存在渐变实现） | `style.css:1699`；SVG 结构 `period.js:270-271` |
| 环内数字 | `--fs-h2`(22px) weight 700，色 `--period-ink` | `style.css:1700` |
| hero 卡 | radius 18（手机 16）；bg 粉渐变（1.3②）；`inset 3px 0 0 var(--period)` 左侧色条 + `--shadow`；右上 136px 圆形 `rgba(var(--period-rgb),.10)` 光斑；padding 16px 18px（手机 14px 15px） | `style.css:1674-1675`/:1704 |
| 阶段色·月经期 | `--period:#C23F68` / soft `#FBE3EC` / ink `#8A2445`（夜 `#EE7C9F`/`#3D1C28`/`#FFC6D8`） | `style.css:57-60`/:1510 |
| 阶段色·卵泡期 | `rgba(var(--green-rgb),.26)`（绿 #4B6B3F 的 α26%） | `style.css:1647`/:1667 |
| 阶段色·排卵期 | `rgba(var(--fertile-rgb),.34)`（紫 #7B63A0） | `style.css:1648`/:1668 |
| 阶段色·黄体期 | `rgba(var(--amber-rgb),.28)`（琥珀 #8A5A22） | `style.css:1649`/:1669 |
| 阶段胶囊 lg-pill | 高 26、padding 0 12、radius 999、`fs-sm` 600；p-period=period-soft 底/period-ink 字/period 描边；p-pred=虚线 primary 描边 + `rgba(period,.06)` 底 | `style.css:1645-1655` |
| 阶段进度条 | 高 40，seg radius 9，段间 gap 3；当前段 `inset 0 0 0 2px var(--primary)` + `0 3px 10px rgba(primary,.14)`；游标 3×7px primary-dark + 3px 光圈 | `style.css:1659-1671` |
| 排卵日圆点 | 7px `--fertile` + `0 0 0 2px rgba(fertile,.25)` | `style.css:1643` |

---

## 二、逐页差异表（六处）

> App 侧「当前值」均指段 B/C token 收敛后现状：`AppRadius.card=12 / sm=10 / lg=16`（`tokens.dart:28-34`）、`Spacing.cardPad=16 / pageBottom=88 / gap=8`（`tokens.dart:11-22`）、cardTheme radius 12（`main.dart:209-213`）、TextTheme 走 M3 `ColorScheme.fromSeed`（`main.dart:202-213`），seed 取七套主题 hex（`settings_state.dart:57-81`，与 Web 主题 hex 同源）。

### 2.1 壳层（chrome：顶栏 + 底栏）

| 维度 | Web 语言 | App 现状 | 差 |
|---|---|---|---|
| 顶栏形态 | sticky 半透明毛玻璃条：bg 80% color-mix + blur14、通宽负 margin、内容是「日期文案 + 私密 pill + 4 圆钮 + 头像」 | Material `AppBar`：title=当前 tab 名（`shell_page.dart:67`），actions=通知/私聊/头像 3 颗 IconButton（`shell_page.dart:73-109`） | Web 无页面名标题、有搜索钮+深浅切换钮+私密 pill（App 后两者在设置页）；形态圆钮浮层 vs 系统 AppBar |
| 顶栏底色 | `var(--bg)` 80% 透明 + blur（`style.css:2107-2111`） | `ColorScheme.surface`（M3 AppBar 默认，`main.dart:202-213` 未覆写 appBarTheme） | App 不透明、无玻璃 |
| 底栏形态 | 悬浮 Dock：距边 10px、radius 24、白/黑玻璃 blur18、阴影 0 10px 28px（`style.css:2736-2741`） | `BottomAppBar` 贴边、高 52、实色、无圆角无边框；`CircularNotchedRectangle` + notchMargin 6（`shell_page.dart:119-121`） | 整体形态不同：悬浮玻璃 Dock vs 贴边实色条 |
| 中央钮 | 46×46 圆形 primary FAB，嵌 Dock 内（不凸出，见 1.6 ⚠️） | `FloatingActionButton` centerDocked + 凹口（`shell_page.dart:113-118`），M3 FAB 默认 56px、图标 favorite | 尺寸 46 vs 56；形态嵌行 vs 凸出凹口；Web 是 plus 图标 |
| tab 结构 | 4 tab（首页/时光/相册/我们），+ 插在第 3 位；「个人角落」走侧栏 profile-btn / 顶栏头像菜单 | 5 tab IndexedStack（首页/时光/相册/我们/角落）（`shell_page.dart:55-64`/:132-148） | tab 数与归属不同——试点红线：tab 结构与手势不动 |
| tab 选中态 | soft 胶囊 + primary 字 + 水滴弹簧动效（`style.css:2696-2706`） | 图标/文字 primary 变色（`shell_page.dart:182-187`），无胶囊无动效 | 缺胶囊与动效 |
| 未读角标 | primary 实底 + 2px surface 外圈（`style.css:285-287`） | M3 `Badge` 默认（`shell_page.dart:77-82`/:89-93） | 形状/外圈不同 |

### 2.2 首页

| 维度 | Web 语言 | App 现状 | 差 |
|---|---|---|---|
| 页底色 | `--bg` #FAF8F9 | `ColorScheme.surface`（fromSeed 派生，非同 hex） | 色源不同 |
| 页头 | `.page-heading` h1 26px/600 + 副题 13px muted，文案「我们的每一天 / 一半是生活…」（`app.js:725`） | 无页面级 heading；hero 卡即头（`home_page.dart:122`） | 缺大标题+副题层 |
| hero | 独立渐变卡：radius 20、min-height 230（手机）、bg 三段 120deg 渐变 + 双 radial 光晕（`style.css:448`/:1959-1964/:1406）；有封面时文字压深色渐变遮罩 `--hero-shade`（`style.css:2259-2260`）；names serif 26px 600（手机 22，`style.css:2266-2289`）；天数 serif **52px（手机 42）weight 500** + 白/主色（`style.css:2271`/:2289） | Card radius 12 + Stack 封面 + `surface α0.45` 遮罩（`home_page.dart:330-345`/:840-864）；names `titleLarge`(22) 居中（:354）；天数 `displaySmall` primary（:369-372） | 圆角 12 vs 20；无渐变底/光晕；遮罩 α0.45 单色 vs 双向渐变；数字无 serif 感、色 primary vs ink/白；无「♥」符号排版（App 是 `' ♥ '` 文本，:323） |
| 指标条 stats-grid | 3 格卡（天数/照片/心愿）：白卡 16 圆角 + serif 24px 数字 + 三色图标底（`style.css:474-482`） | **无此区**（`home_page.dart` 全文无对应块） | 整块缺失 |
| 今天的心情/纪念日 | 手机双格 today-cell：radius 16、serif 26px 倒计时（`style.css:496`/:505） | 单 Card 内分区（`home_page.dart:551-631`）；倒计时 `headlineMedium` primary（:592-594） | 双格卡 vs 单卡分区；数字档不同 |
| 每日一句 | `daily-quote` soft 胶囊条 radius 12 + primary 图标（`style.css:1906-1909`） | `surfaceContainerHighest α0.4` 容器 radius 16（`home_page.dart:131-137`） | 底色/圆角不同 |
| 最近动态卡 | `.card` radius 20/17 + kind-mood/post tint 渐变 + hairline（`style.css:1941`/:1950-1951） | Card radius 12、白底、无 tint（`home_page.dart:197-203`） | 圆角/底色层次差 |
| 发布入口 | 顶栏/页头「记录此刻」按钮 + 底栏 + 钮 → 发布弹窗（见 3.2②） | FAB → `showComposerSheet`（`shell_page.dart:115`） | 入口位置与形态 |

### 2.3 时光

| 维度 | Web 语言 | App 现状 | 差 |
|---|---|---|---|
| 页头 | h1「时光慢慢，爱意满满」26/600 + 副题（`app.js:865`） | `headlineSmall` 同文案（`timeline_page.dart:110`）+ bodySmall 副题（:112-113） | 文案一致；字号档 26 vs 24、字重 600 无显式 |
| 筛选 | 桌面常开 input+select 高 46；手机 filter-box 折叠（`style.css:591-600`） | TextField radius `AppRadius.card`(12)（:144）+ 下拉/chips（沿用段 B/C 盘点 B-3 条） | 控件形态与高度档 |
| 卡片 | `.card` radius 20（手机 17）+ `--shadow` + hairline + kind-* tint；媒体 3 列格 radius 12（`style.css:602-604`/:1421） | `PostCard` radius 16（`post_card.dart:54`）、卡内 padding 16（沿用段 B 盘点 G3 行） | 16 vs 20/17；无 tint 无 hairline |
| 选中胶囊 | tabs active soft+primary 描边（`style.css:337`） | chips radius 999 底 surface（`timeline_page.dart:228-231`） | 选中态样式不同 |

### 2.4 相册

| 维度 | Web 语言 | App 现状 | 差 |
|---|---|---|---|
| 页头 | 「把喜欢的瞬间，装进口袋」h1+副题+主按钮（`app.js:965`） | `headlineSmall` 同文案（`album_page.dart:136`） | 字号档同 2.3 |
| 照片网格 | 4 列 gap 12（手机 3 列 gap 8，`style.css:618`/:1433/:1375） | GridView 3 列 gap 8（`album_page.dart:538-539`） | 桌面档列数（App 单一 3 列）；gap 12 vs 8 |
| 照片块圆角 | 14（手机 12，`style.css:619`/:1434） | `AppRadius.sm`(10)（`album_page.dart:227`/:341 等） | 14/12 vs 10 |
| 分组头 | 左 3px primary 竖线 + primary-dark 标题（`style.css:626`） | 按月分组无竖线（沿用段 A 调研 A 路「视觉一致性逐页」结论） | 缺书签线 |
| hover 抬升 | translateY(-2px)+shadow-lift（`style.css:620`） | 无 hover 概念；Hero 转场已有（沿用段 B 盘点 B-3） | —（触屏无 hover，不追） |

### 2.5 我们（together hub）

| 维度 | Web 语言 | App 现状 | 差 |
|---|---|---|---|
| 页头 | 「关于我们，还有好多好多 / 把喜欢落在实处…」（`app.js:1229`） | `headlineSmall` 同文案（`together_page.dart:68`） | 字号档 |
| 工具区形态 | **3 列宫格**（≤1150 两列）radius 20 白卡 + emoji fs-xl + 顶部 hover 渐变细线 + lift（`style.css:1078`/:1079`/:1983-1988`） | **纵向列表卡**：Card radius 12、padding 16/14、icon+文字行（`together_page.dart:313-331`/_toolCard:83-160） | 宫格 vs 列表，是此页最大形态差 |
| 生理期 wide 卡 | 整行横卡：`linear-gradient(120deg,soft,surface 64%)` 渐变底（`style.css:1085`） | `_PeriodEntryCard` Card radius 12 无渐变（`together_page.dart:368-381`） | 缺渐变底 |
| 设置区 | section-heading + 同款宫格（`app.js:1229`） | `_settingsCard` 纵向列表（`together_page.dart:262-281`） | 同上 |
| 大数字 | 纪念日展示卡 serif 24px 档（`style.css:479` 系） | `headlineMedium`（`together_page.dart:444`） | 无 serif 感 |

### 2.6 生理期

| 维度 | Web 语言 | App 现状 | 差 |
|---|---|---|---|
| 页头 | 「生理期 / 记下周期，把照顾提前一点。」（`period.js:513`） | AppBar title + 副标题 bodySmall（`period_page.dart:95`/:109 注释） | 形态 |
| hero 卡 | 粉渐变卡 + 左 3px 色条 + 右上光斑 + radius 18（`style.css:1674-1675`） | 普通 Card radius 12、白底、无色条无光斑（`period_page.dart:174-177`） | 缺整套 hero 视觉 |
| 圆环 | SVG 74px、stroke 9、track `rgba(period,.2)`、fill `--period`(#C23F68 固定色)、环内 22px/700（`style.css:1697-1700`） | CustomPaint 72×72、strokeWidth 6、track `surfaceContainerHighest`、fill `cs.primary`、环内 titleMedium bold（`period_page.dart:948-962`/:987-992） | 直径 74 vs 72、线宽 9 vs 6、色源固定主题周期色 vs colorScheme.primary |
| 四阶段色 | 全走主题变量：period `#C23F68`、绿/紫/琥珀用 rgb 通道 α 底（`style.css:1631-1649`/:1666-1669） | **写死四色** `0xFFEF3F68 / 0xFF81C784 / 0xFF9575CD / 0xFFFFB74D`（`period_page.dart:265-269`，图例 ：448-451，格子 ：579-589）——Web 旧值 `#FF5C8A` 系的遗留映射，与现行主题变量体系脱钩（G10/G11/G13 同族问题，沿用段 B 盘点 D6 结论） | 色值与「跟主题/明暗换」机制双差 |
| 图例胶囊 | lg-pill 高 26 radius 999 主题变量底（`style.css:1645-1655`） | `_legend` 自绘小方块/圆点 radius 3（`period_page.dart:485-494`） | 形态不同 |
| 阶段进度条 | 高 40、radius 9、当前段 primary 内描边（`style.css:1659-1665`） | 自绘 Row 段 radius 5、α0.45/0.95（`period_page.dart:283-287`） | 高度/圆角/高亮方式 |
| 日历 | cal-board radius 18 白卡 + cal-day radius 13/11、经期格 period-soft 底+1.5px 描边（`style.css:2197`/:2203`/:1631`） | 自绘格 radius 8、写死 α 底（`period_page.dart:516`/:578-589） | 卡容器与格子参数 |

---

## 三、试点实现方案与风险（只写方案，不实现；等放行）

### 3.1 试点范围（已放行执行，2026-11-16）

- **壳层 chrome**：① 悬浮顶栏圆钮组（42×42 圆钮 + 角标外圈 + 私密 pill 的 App 化版式）；② 悬浮底栏 Dock（距边 10px、radius 24、玻璃底、阴影）+ 中央 46px 圆形 + 钮 + tab soft 胶囊选中态。
- **首页一页**：页头（大标题+副题档位）、hero 渐变卡（含光晕与遮罩变量 `--hero-shade` 口径）、stats-grid 三格、today 双格、每日一句条、最近动态卡的 1:1 还原。
- **硬红线**：功能与数据流零变化——provider/请求时机/路由结构/IndexedStack tab 结构/手势全部不动；只换呈现层。

### 3.2 风险清单

| # | 风险 | 分析与方案草案 |
|---|---|---|
| ① | **悬浮底栏 vs `ShellPage` 底部 NavigationBar 替换/共存** | 现状：`BottomAppBar`+`CircularNotchedRectangle`+centerDocked FAB（`shell_page.dart:113-151`）。方案 A（推荐）：**浮层重构**——`Scaffold.bottomNavigationBar` 置 null，Dock 做成 `Stack` 内 `Positioned` 浮层（对齐 Web `inset:auto 10px` 定位），FAB 与 Dock 同层绘制；`Spacing.pageBottom=88` 需按 Dock 实高复核避让（Web 口径 104px，`style.css:2750`）。方案 B：仅换 `BottomAppBar` 皮肤（圆角+玻璃），保留 docked 结构——观感上限低（难做距边悬浮）。**两条都不改 IndexedStack 与手势**；方案 A 需真机验证 `MediaQuery.padding.bottom` 透传。风险点：`personal_a_fix_test` 五 tab 六档扫宽断言（沿用段 B/C 盘点 3.4 节）依赖 BottomAppBar 结构，改浮层需同步改测试口径。 |
| ② | **中央 + 钮与现有功能入口衔接** | Web 端 + 的实际行为（实读）：`data-action="compose"` → `composer()` 打开**发布弹窗**（标题「记录此刻的小美好」，post/diary/surprise 三提交态 + 图/语音上传，`app.js:307`/:2484/:1807-1830），**不是工具面板**；工具入口在 Web 走「我们」宫格 tool-*。App 现状：FAB → `showComposerSheet`（`shell_page.dart:115`），语义一致、无重复入口。方案：+ 钮视觉重绘（46px 圆形 primary + plus 图标），行为**原样接 showComposerSheet**；无需与 ⊕ 面板/工具页去重（⊕ 面板属聊天页输入栏，不在壳层）。唯一注意：Web + 钮无文字 label（`style.css:1389` span 隐藏），App tooltip 保留无碍。 |
| ③ | **沉浸式页与壳层 chrome 兼容** | chat/period：chat 是 push 出的独立页（`/messages`，`shell_page.dart:88`），不挂 Dock——试点不动；period 是「我们」子页走 push（`together_page.dart` tool-period 入口），同样不在壳层。风险仅在：Dock 改浮层后，push 返回动画中 Dock 是否闪现（方案 A 浮层常驻于 ShellPage Stack，push 覆盖自然遮住，真机确认即可）。 |
| ④ | **深浅两套底色适配口径** | Web 双值：dock-bg 浅 `rgba(255,255,255,.9)` / 深 `rgba(28,22,30,.78)`，dock-line/dock-shadow 各一组（`style.css:2736-2737`）。App 方案：在 `buildTheme` 外建「chrome 语义色」小表（按 brightness 取值），**不**走 `ColorScheme.fromSeed` 派生（玻璃 α 值无法从 seed 派生）；卡片 tint 渐变的 α 蒙层同样按明暗两套（Web `:root.dark` 覆盖组 `style.css:1542-1569`）。注意红线：不引入 `BackdropFilter` 于动画区（定案 #3：毛玻璃只静态区；Dock 是静态区，可用）。 |
| ⑤ | **可回滚性** | 试点**一个 commit**（版本位 2.3.1/VC231，见 3.3），真机不点头 → `git revert` 单点回退；影响面限定在 `shell_page.dart` + `home_page.dart` + 新增 chrome 组件文件 + 对应测试文件；不动 tokens.dart 既有常量语义（可新增 chrome 令牌，不重命名旧值），revert 后段 B/C 收敛成果零残留风险。 |
| ⑥ | （附带）**「渐变圆环」口径修正** | 主人语中的「渐变圆环」在 Web 源码中**不存在渐变**——`cycle-ring` 是纯色 `--period` 描边（`style.css:1699`）。若试点后推广到生理期页，按「纯色 + 主题周期变量」对齐即可，不必造渐变；周期页写死四色（2.6 差异行）属推广段议题，本试点不碰。 |

### 3.3 分段建议草案（版本位沿用章内顺延，不写死承诺）

| 段 | 相对位次 | 范围 | 备注 |
|---|---|---|---|
| **试点段** | **2.3.1 (VC231)**（章内顺延，段 D 暂停后此位空出） | 壳层 chrome（悬浮顶栏圆钮组 + 悬浮底栏 Dock 含 + 钮）+ 首页一页 1:1；一 commit、analyze+test 全过、停等真机验收；不点头即 revert | 放行前提：本盘点经主人确认 |
| 推广段一 | 试点验收后的下一顺延位 | 时光/相册/我们三页（卡片圆角/tint/宫格形态/照片网格参数） | 位次届时按验收结论排，不预先锁版本号 |
| 推广段二 | 再下一顺延位 | 生理期页（hero 视觉 + 周期色变量化——含写死四色清理，需主人对色板口径拍板） | 周期色换机制涉及「跟主题/明暗换」，改动面大于视觉换皮，单列 |

**明确不做**：键盘/输入区（禁区，定案 #2）、数据流/请求时机、tab 结构与手势、后端 `app/`/`static/` 任何改动。

---

## 四、口径对照速查（Web 刻度 → App 令牌）

| Web | 值 | App 对应 | 差 |
|---|---|---|---|
| 圆角卡 20/17 | `style.css:296`/:1421 | AppRadius.card=12（`tokens.dart:31`） | 视觉对齐主战场 |
| 圆角大容器 24 | `style.css:131` | AppRadius.lg=16（`tokens.dart:34`） | sheet/dialog 档 |
| 卡 padding 18/15 | `style.css:297`/:1421 | Spacing.cardPad=16（`tokens.dart:11`） | ±2px 级 |
| 字号 h1 26 / 副题 13 | `style.css:111`/:103 | M3 headlineSmall(24)/bodySmall(12) | ±1~2px |
| 大数字 serif 52/46/42 | `style.css:2271`/:1462(旧 46)/:2289 | displaySmall(36) | 需自造 display 档或写死+跟随缩放（定案 #6 机制允许） |
| 动效三档 120/220/320 | `style.css:2627` | Motion.fast/base/slow（沿用段 B 盘点，`motion.dart`） | 已同构 |
| 底部留白 104 | `style.css:2750` | Spacing.pageBottom=88（`tokens.dart:16`） | Dock 化后需复核 |

---

## 五、grep/实读关键文件清单

- Web：`static/style.css`（全 2753 行实读，重点 ：22-203 变量层、:126-150 圆角阴影、:278-294/:1966-1974 顶栏、:1378-1493 手机断点、:2690-2753 sw294/295/296 Dock 与水滴）、`static/app.js`（:228 heading、:295-332 renderShell、:383-408 navPill、:725/:865/:965/:1229 页头文案、:1807-1830 composer、:2484 compose 路由）、`static/period.js`（:253/:261-276 圆环、:513 页头）、`static/index.html`（全 28 行）。
- App：`app-flutter/lib/core/theme/tokens.dart`（全 35 行）、`lib/main.dart`(:189-237)、`lib/features/settings/settings_state.dart`(:55-98)、`lib/features/shell/shell_page.dart`（全 193 行）、`lib/features/home/home_page.dart`（全 871 行）、`lib/features/timeline/timeline_page.dart`（grep 实读 :106-357）、`lib/features/album/album_page.dart`（grep 实读 :134-635/:533-545）、`lib/features/together/together_page.dart`（grep 实读 :63-451）、`lib/features/period/period_page.dart`（grep+选段 :140-269/:448-592/:939-1004）。
- 沿用文档：`app-flutter/docs/ui-polish-plan.md`（段 B/C 落地备注、定案 #1-#7、未核实 U1-U8）。

## 六、未核实清单

| # | 事项 | 缺口 |
|---|---|---|
| W1 | Web Dock 实际渲染高度（nav 项 46 + padding 12 + 边框，推算 ≈60+safe）未在真机/浏览器量测 | 源码可推，未实测 |
| W2 | 注释「FAB 上浮一半突出 Dock 顶」（`style.css:2734`）与实读 `margin-top:0`（:2747）矛盾——按实读口径记录为「不凸出」，是否注释过期需主人确认历史意图 | 实读为准，存疑标注 |
| W3 | Web 顶栏 sticky 在「桌面」与「原生 APK」两套背景（渐变 vs color-mix 80%）在手机浏览器直访时的实际表现未测（APK UA 才挂 `is-native-app`，`app.js:2757`） | 端侧分支未实测 |
| W4 | `nav-pill` 水滴动效的弹簧曲线在 Flutter 端等价实现选型（`Animations` 库 spring vs 手写 dual-tween）未定 | 实现期决策 |
| W5 | 首页 hero 无封面时 Web 的 garden.svg 插画层（`hero-art` opacity .82，`style.css:450`）App 是否对齐（App 无封面时无插画） | 素材资产未核对 |
| W6 | Web `--fs-scale` 三档（1/1.08/1.16）与 App `TextScaler.linear` 同构已核实（`style.css:202-203` vs `settings_state.dart:94-98`），但 Dock 内 11px label 放大 1.16 后是否溢出未实测 | 沿用 U8 同族，需真机 |
| W7 | 时光/相册/我们/生理期四页的 Web 卡片在**手机宽度**下的全部覆盖值（radius 17 等）仅抽查了 `.card`/`.photo-item`/`.cal-board` 三类，其余组件（如 `.pa-card`）手机档未逐一复核 | 推广段前补 |

---

## 七、试点落地备注（2.3.1/VC231，随试点段交付）

> 试点范围：壳层 chrome（方案 A 浮层重构）+ 首页一页 1:1；代码落点 `lib/features/shell/web_chrome.dart`（新增：chrome 语义色表 + ChromeMetrics + WebDock/圆钮/角标/头像钮）+ `shell_page.dart`（浮层重构）+ `home_page.dart`（首页还原）；`tokens.dart` 既有常量零改动。

### 7.1 W1–W7 逐条落定

| # | 落定 |
|---|---|
| W1 | **落定为推算口径**：Dock 实高 = nav 46 + padding 6×2 + 边框 2 = 60（style.css:2738/:2743），Flutter 端 widget 测试以 `Key('shell-dock')` 实测断言（web_visual_d_test），真机验收兜底 |
| W2 | **按实读口径定案**：+ 钮 46×46 `margin-top:0` 嵌 Dock 行内居中（style.css:2747/:1388），**不凸出、不做凹口**；`style.css:2734` 注释为过期遗留，不再引用 |
| W3 | **试点不涉及**（顶栏吸顶两套背景为 Web 端浏览器行为；App 端顶栏半透明 80% 常驻，`web_chrome.dart topbarBg`，出处 style.css:2108） |
| W4 | **落定为双 tween 近似**：选中胶囊 `AnimatedContainer`（色/透明度 220ms = Motion.base）+ 内容 `AnimatedScale`（120ms = Motion.fast），不引 spring 依赖、不调弹簧参数（app.js:399-407 的双弹簧不做逐帧等价） |
| W5 | **试点不涉及**（garden.svg 插画属素材资产，App 无此资产包；无封面时仅渐变底 + 双光晕，与 Web 有封面遮罩分支互不影响） |
| W6 | **沿用既有机制**：Dock 内 11px label 为写死 fontSize，跟随全局 `TextScaler.linear` 缩放（定案 #6），320 宽 ×1.16 的溢出由扫宽断言六档兜底（personal_a_fix_test P1-2 改口径后仍全过） |
| W7 | **推广段前补**（试点只碰壳层 + 首页，其余页面卡片手机档复核顺延推广段） |

### 7.2 扫宽断言改口径（personal_a_fix_test P1-2）

- 六档扫宽（320/360/393/400/411/428 零 RenderFlex overflow）**原样保留**；
- 原 `BottomAppBar padding=0` + `FloatingActionButton findsOneWidget` 断言改为：`BottomAppBar/FloatingActionButton findsNothing`（贴边底栏与 M3 FAB 已移除）→ `Key('shell-dock')` 浮层在位 + `Positioned` left/right=10（style.css:2738）+ `Key('shell-compose-fab')` 尺寸 46×46（style.css:2747）+ `BackdropFilter` 全树恰 1 处（毛玻璃只 Dock 静态区）；
- 五 tab 结构断言（五文案在位、IndexedStack children=5、切 index 4 见「个人角落」）**零改动**。

### 7.3 关键数值 → 出处对照（实现侧）

| 数值 | App 落点 | 出处 |
|---|---|---|
| Dock inset 10 / padding 6 / radius 24 | `ChromeMetrics.dockInset/dockPadding/dockRadius` | style.css:2738-2739 |
| 玻璃 blur 18 + saturate 1.25 | `ChromeMetrics.dockBlurSigma/dockSaturation`（本 SDK 无 ColorFilter.saturate 工厂，手写等价矩阵） | style.css:2740 |
| dock-bg 浅 `rgba(255,255,255,.9)` / 夜 `rgba(28,22,30,.78)`；dock-line 浅 `rgba(0,0,0,.06)` / 夜 `rgba(255,255,255,.09)`；dock-shadow 浅 `rgba(90,50,70,.28)` / 夜 `rgba(0,0,0,.55)` | `ChromeColors.dockBg/dockLine/dockShadow`（纯常量，不走 fromSeed） | style.css:2736-2737 |
| Dock 阴影 `0 10px 28px` | `ChromeMetrics.dockShadowOffsetY/Blur` | style.css:2741 |
| nav 项 min-height 46 / radius 14 / icon 20 / label 11 | `ChromeMetrics.navItem*` | style.css:2743-2744/:2701 |
| 选中胶囊底 --soft（夜白 .14）/ radius 14 | `ChromeColors.navPillBg`（浅=primaryContainer 映射 / 夜=白 .14 显式） | style.css:2699/:2746 |
| + 钮 46×46 圆形 primary、icon 22、阴影 0 4px 14px .24、嵌行内不凸出 | `ChromeMetrics.fab*` + `WebDock._composeButton` | style.css:2747-2749/:1388 |
| 顶栏圆钮 42×42 / icon 19 / 间距 9（手机档）/ btn-lift 阴影 | `ChromeMetrics.topBtn*` + `ChromeColors.topBtnBg/Shadow`（夜 raised=白 .06，style.css:1522） | style.css:279-284/:1399/:140/:1519 |
| 角标 min-width 17 / padding 3px 4px / surface 2px 外圈 | `WebBadge`（border 2px surface 同效 box-shadow） | style.css:285-287 |
| 头像钮 44×44 / padding 2 / 1px --line | `WebAvatarButton` | style.css:431 |
| 内容避让 104 | `ChromeMetrics.contentBottom`（首页 ListView 底 padding） | style.css:2750 |
| 页头 h1→headlineSmall(24)/600/ls-0.3，副题→bodySmall/outline，mt 5，mb 16 | `_PageHeading`（文案逐字 app.js:725） | style.css:342-343/:212/:1401 |
| hero radius 20 / min-height 230 / padding 18px 16px / 1px --line | `_Hero` 容器 | style.css:448/:1405-1406 |
| hero 底层 linear 120°（soft→surface 55%→green-soft）+ 双 radial 光晕（白 .55@左上 / primary .10@右下） | `_HeroGradientPainter`（soft→primaryContainer 映射；green-soft 走语义色表，圆近似椭圆已注明） | style.css:448/:1959-1964 |
| --hero-shade 双向遮罩（90deg .74→.4@58%→.1 + 0deg .52→0@52%） | `_HomeCover` 双渐变层 | style.css:2258-2260 |
| hero 名字 serif 22/600（手机档 ≤720）+ 心符号主色 / 封面转白 | `_Hero` Text.rich（serif=Georgia/Songti SC/Microsoft YaHei，style.css:153；简报 26 为桌面档，见 7.4） | style.css:2264-2266/:2283 |
| hero 天数 serif 42/500（手机档）/「天」14 | `_Hero` 天数行 | style.css:2289/:2272 |
| stats 三格 radius 14 / padding 13px 12px / gap 9 / 图标底 38×38 r12 三色 / 数字 serif 22/500 | `_StatsGrid`（天数/照片/心愿，数据零新请求） | style.css:474-482/:1415 |
| today 双格 radius 16 / padding 11px 13px / 倒计时 serif 26/500 | `_TodayCells` | style.css:496/:1417/:505 |
| 每日一句 radius 12 / soft 底 / 图标 primary / small muted | `_DailyQuote` | style.css:1906-1909 |
| 动态卡 radius 17 / padding 15 / kind tint 165°（tint→surface 72%）/ 顶部 hairline .72（夜 .05） | `_recentCard` + `_kindTint` | style.css:1421/:1930-1956/:1937/:2017 |
| 私密 pill 手机档隐藏 | App 端本就无此 pill，无需实现 | style.css:1400 |

### 7.4 与任务简报字面的三处口径差异（待主人真机验收时拍板）

App 视口属 Web 手机档断点（≤640/≤720），实现按**盘点表手机档**取值；如要桌面档，改 `web_chrome.dart`/`home_page.dart` 对应常量即可：

1. hero 名字/天数：简报 26/52（桌面档，style.css:2266 前/:2271）→ 实现 22/42（手机档，style.css:2266/:2289）；
2. 动态卡圆角：简报 20（桌面档，style.css:296）→ 实现 17（手机档，style.css:1421；新测试按 17 断言）；
3. 页头 h1：Web 手机档 22（style.css:1401）、简报 26 → 实现取字阶 headlineSmall(24)（任务定案「26→headlineSmall 或体感一致档」）。

### 7.5 测试交付

- 新增 `test/web_visual_d_test.dart`（10 例）：chrome 色表深浅两档逐值断言、Dock 结构（+ 钮 46×46、五 tab、距边 10、玻璃仅 Dock 一处）、顶栏三钮 42/42/44 + 角标 + push 去向、首页页头逐字 / hero radius 20 / stats 三格 / 动态卡 radius 17 / 320 宽零溢出；
- 改口径：`personal_a_fix_test.dart` P1-2（见 7.2）、`ui_polish_b_test.dart` ⑨（BackdropFilter 豁口仅 `web_chrome.dart`）+ S1 两例加滚动露出步骤（首页内容变高，320×700 下动态卡在折叠线下）。

---

## 八、推广段一落地备注（2.3.2/VC232，随推广段一交付）

> 基线 `aee0ba5`（试点 2.3.1/VC231 已验收）。纪律：功能/数据流/路由/手势零变化；毛玻璃不新增（全 lib `BackdropFilter` 仍仅 `web_chrome.dart` 1 处）；段 A 错误通道 / 段 B 令牌 / 段 C 三态 / 试点 chrome+首页成果零回退（stats-grid 摘除与心情格修复为任务明确例外）；键盘/输入区禁区不碰；后端 `app/`/`static/`/`android-app/`/`.github/` 零改动；`tokens.dart` 既有常量语义不变（`web_chrome.dart` 仅新增 `WebSemanticColors.info` 一色）。

### 8.1 关键数值 → 出处对照（实现侧，≥15 条）

| 数值 / 形态 | App 落点 | 出处 |
|---|---|---|
| 摘除 stats-grid 三格（真 Web 手机端无此区） | `home_page.dart` 删 `_StatsGrid` 整块 + 调用 | `index.html`/`app.js` 全库无 `stats-grid` 引用（盘点偏差） |
| 心情 chip 单行 pill + 昵称分行 | `_MoodRow`（`maxLines:1`/`softWrap:false`/radius 999） | `style.css:132`（--radius-pill 999）+ 对照图 `22_compare_light` 左侧 |
| PostCard radius 17 | `post_card.dart` `cardRadius` | `style.css:1421`（.card 手机档） |
| PostCard 165° tint→surface 72% | `post_card.dart` LinearGradient stops [0,.72] | `style.css:1944-1956` |
| PostCard 顶部 hairline .72 / 夜 .05 | `WebSemanticColors.cardHairline` | `style.css:1937`/`:2017` |
| 六色 kind tint（rose/amber/violet/green/blue/peach） | `_postKindTint` | `style.css:1930-1936` |
| 媒体格圆角 12 | `MediaImageView` 可选 `borderRadius`，时光传 12 | `style.css:602-604`/`:1434` |
| 筛选控件高 46 | `timeline_page.dart` TextField SizedBox(46) + 日期钮 46 | `style.css:2743`/`:1422` |
| tabs/chips 选中态 soft 底 + primary 描边 + primary-dark 字 600 | `_chip` / SegmentedButton | `style.css:337` |
| 相册照片块圆角 12 | `_Thumb`/`_VideoThumb`/封面/骨架 | `style.css:1434`（手机档 12） |
| 相册分组头 3px primary 竖线 + primary-dark 标题 | `_timeList` 分组头 Row | `style.css:626` |
| 相册页头主按钮 pill 999 | `_heading` InkWell radius 999 | `style.css:132`/`:293` |
| 我们页工具/设置 2 列宫格 radius 20 白卡 | `_twoColumnGrid` + `_toolCard`/`_settingsCard` | `style.css:1078-1083`（tools-grid/ tool-card） |
| emoji fs-xl 24 / h3 fs-body / p fs-sm muted | 宫格卡 24 / titleSmall / bodySmall·outline | `style.css:110`/`:1081-1083` |
| 生理期 wide 卡 120° 渐变底 soft→surface 64% | `_PeriodEntryCard` LinearGradient stops [0,.64] | `style.css:1085` |
| 纪念日大数字 serif 24 | `_AnniversaryCard` `webSerifStyle(24)` | `style.css:479` 系（盘点表 2.5） |
| ink/info 语义色（浅 #3F6A8E / 夜 #8FB6D4） | `WebSemanticColors.info` | `style.css:44`/`:1508` |

### 8.2 我们页宫格文案实读对照表（`static/app.js:1229` / `toolsList :1219` 逐条）

> 逐条实读 Web，不自造。App 侧保留既有 11 工具 + 8 设置 + 生理期 wide + 纪念日展示卡（无增减）；Web 独有而 App 无对应入口的「情侣摆拍参考（figure）」「纪念日/个人心愿 toolsList 项」**不新增**（红线：无卡片增减）。宫格卡仅取 Web 的「emoji + 标题 + 诗意副题」呈现语言，App 文案沿用各自实读原文。

| App 卡（宫格） | emoji | 副题 | Web 对应（`app.js:1229` / `toolsList`） |
|---|---|---|---|
| 生理期（wide） | 🌸 | 记下周期，把照顾提前一点 | `tool-card-wide` 首位硬编码逐字同文 |
| 共同年历 | 🗓️ | 重要的日子，一眼看清 | toolsList calendar 逐字同文 |
| 心情手记 | 🌤 | 晴天雨天，都想陪着你 | toolsList mood 逐字同文 |
| 悄悄留言 | 💌 | 有些喜欢，值得慢慢读 | toolsList note 逐字同文 |
| 共同愿望 | ✨ | 把一起想做的事，一件件实现 | toolsList wish 逐字同文 |
| 情侣问答 | 💭 | 每天再多了解彼此一点 | toolsList question 逐字同文 |
| 共同打卡 | 🌱 | 和你一起，成为更好的我们 | toolsList habit 逐字同文 |
| 恋爱清单 | 💫 | 一起做完这些小事，就是我们的故事 | toolsList quest 逐字同文 |
| 共同账本 | 💰 | 为了彼此花过的钱，也是一段回忆 | toolsList ledger 逐字同文 |
| 共同歌单 | 🎵 | 把属于我们的歌，放在一起 | toolsList music 逐字同文 |
| 数据看板 | 📊 | 把日子过成数据，也过成回忆 | `tool-card` dashboard（Web「我们的点滴，都在这里」为另一副题口径，App 沿用既有） |
| 回忆周报 | 📬 | 把这一周，收进一封小小的信 | 同 dashboard（App 沿用既有副题） |
| 空间信息 | 🏡 | 空间名称与相恋日期 | settings-tools space 逐字同文 |
| 主题与外观 | 🎨 | 主题色、夜间模式与动效 | settings-tools theme-form 逐字同文 |
| 主页背景 | 🖼️ | 换一张首页封面照片 | settings-tools home-bg 逐字同文 |
| 聊天背景 | 🌄 | 聊天壁纸与文字对比度 | settings-tools chat-bg 逐字同文 |
| 聊天气泡 | 💬 | 两千多款气泡皮肤随手挑 | settings-tools chat-bubble 逐字同文 |
| 邀请另一半入住 | 💌 | 把你们的专属空间分享给 TA | settings-tools invite（Web 条件展示；App 既有卡全保留） |
| 提醒设置 | 🔔 | 通知渠道与提醒偏好 | settings-tools channels 逐字同文 |
| 全部设置 | ⚙️ | 主题、背景、链路检测与检查更新 | settings-tools settings（App 副题为本地化描述） |

### 8.3 备案缺陷修复说明

- **缺陷①（心情气泡碎字）**：`home_page.dart` `_MoodRow` 原「头像+昵称+Expanded 气泡」单行 Row，在 today-cell 双格窄列（手机档约半屏宽）下 `＋ 记一笔` 被压窄竖排碎字。改「头像 +（昵称行／pill 胶囊行）」分行 Column + 胶囊 `maxLines:1`/`softWrap:false`/radius 999，单行横向不换行；记心情仍走 `_openMoodSheet` 原链，S1/S2 `Flexible+ellipsis` 不回退。出处：对照图 `22_compare_light` 左侧 + `style.css:132`。
- **缺陷②（composer 日期 Row 溢出）**：`composer_sheet.dart:672` 原单行 Row（图标+文字+日期按钮+Spacer+图/视频+音频）在 393 宽右溢出约 90px、320 更甚。改 `Wrap`：日期组 `Row(mainAxisSize.min)` 固定一行，媒体入口按钮空间不足自动换行；三个回调 `_pickDate`/`_pickImageVideo`/`_pickFromLibrary` 与发布字段/提交链全部零变化。出处：QA 备案 + 320/393/403 三档 widget 断言。

### 8.4 测试交付

- 新增 `test/web_visual_e1_test.dart`：stats-grid 摘除（源码护栏 + widget 断言）、心情胶囊单行护栏、PostCard radius17+tint+hairline+媒体 12、相册圆角 12+竖线+chips 态+pill 主按钮、我们页宫格 2 列 + 11 工具/8 设置 key 与去向/顺序不变 + 生理期渐变 + 纪念日 serif、composer 日期 Row 320/393/403 零溢出、深浅两档颜色来源（含 `WebSemanticColors.info`）；
- 改口径：`web_visual_d_test.dart` 首页「stats 三格在位」断言改为「已摘除」（任务明确例外），320 宽零溢出断言描述同步；`personal_a_fix_test.dart` 六档扫宽原样保留。
