# 调研：两个借鉴项目 + 开源聊天界面的输入法处理（2026-11-10）

> 应主人要求调研 LC044/WeChatMsg、LC044/TrailSnap，以及开源聊天软件的
> 聊天界面实现与输入法展开/回收方案。

## 一、WeChatMsg（留痕）的借鉴点

微信 PC 聊天记录导出工具（PyQt 桌面端），HTML 导出观感最接近微信本尊。

| 借鉴点 | 说明 | 对恋爱空间 |
|---|---|---|
| HTML 导出保真度 | 气泡、头像、时间分隔、图片、表情包、语音转文字、**引用消息定位原文**、**时间轴跳转** | 聊天记录导出（现只有 Markdown）可加：引用跳转锚点、时间轴锚点 |
| 年度报告 | 消息条数、活跃时段、高频词、消息类型占比、**双人报告**（选一位好友看全年对话轨迹） | 年书可加统计维度与「双人报告」视角 |
| LC044/AnnualReport | Vue3 报告模板，分页组件（欢迎页→统计→照片墙→时间轴），**全部数据集中在 getData.js**，「定制报告只改一个文件」 | 年书的数据装配方式值得照抄：数据与版式分离 |
| CSV / SQLite 导出 | 结构化数据二次加工 | 已有 Markdown 导出，可加 CSV |

## 二、TrailSnap（行影集）的借鉴点

AI 相册（Vue3 + FastAPI + pgvector，作者自述 90% 代码 AI 生成）。

| 借鉴点 | 说明 |
|---|---|
| 那年今日 | 按图片**评分**排序 + 自动播放（我们已有那年今日，可加评分与自动播放） |
| 足迹地图 | 照片按省/市/区聚合，地图/时间轴/轨迹三种视图 |
| OCR 票据识别 | 火车票、行程单、门票自动归档成行程 |
| 人脸聚类 | 多外观人脸聚类与识别档位 |
| AI 日记 | 一句话生成旅行日记（Agent 对话式） |
| SKILL / MCP / CLI | 把产品接入 Claude Code 等 AI 平台做自动化任务 |
| 工程坑 | Vue SFC 的 `:global(.dark)` 会泄漏全局主题（与我们 theme-class 方案同类的坑），他们改用 `html.dark .x` 前缀解决——我们的 theme-xxx class 方案没有这个问题 |

## 三、开源聊天界面怎么做（结构与细节）

- **结构**：全高 app shell + 底部 pinned composer（flex 列 + 消息区 flex:1 滚动）；
  composer 内 textarea 自增高到上限（主流 3 行），超过后 composer 内部滚动。
  我们已是同构（textarea max-height 96px ≈ 3 行）✓
- **命中区域**：发送/表情/语音等按钮 ≥44pt(iOS)/48dp(Android)（frenfoil #1577 实测
  36px 会把点发送误落成聚焦输入框）。我们的 compose-ib 是 var(--ctrl-h)，值得量一次
- **字体 ≥16px** 防 iOS 聚焦缩放（我们的 --fs-lg 体系需在移动端确认）

## 四、输入法展开/回收：业界三大流派 + 兜底

| 流派 | 机制 | 适用 |
|---|---|---|
| ① meta 标签 | `interactive-widget=resizes-content`：布局视口随键盘缩，100vh/dvh 直接变短，**零 JS** | Chrome/Android 108+；**Android WebView 明确不支持**（amoshydra 实测 + Chromium tracker） |
| ② VirtualKeyboard API | `navigator.virtualKeyboard.overlaysContent=true` + geometrychange → `env(keyboard-inset-height)` | Chromium 渐进增强，experimental |
| ③ visualViewport | `inset = innerHeight − vv.height − vv.offsetTop` → CSS 变量，**rAF 合帧** | 通用兜底；iOS Safari 只认这条 |
| ④ 原生桥 | Android WebView 宿主经 insets/JSBridge 喂高度（juejin 速查表：「Android WebView：原生桥接 + visualViewport 兜底」） | **我们的架构** |

**与我们方案的对照**：Capacitor 8 + insets 流通 + A 类原始值 + kbVvWorks 仲裁 +
原生桥兜底，与业界共识一致（速查表原话即是「原生桥接 + visualViewport 兜底」）。

**可吸收的细节（均一行级改动）**：
1. **pinch-zoom 过滤**：`vv.scale > 1.01` 时 inset=0——双指缩放会缩小视觉视口，
   别把手势缩放当成键盘弹出（observerviewport.com）
2. **iOS Safari 自动 blur**：键盘开着时页面滚动（vv.offsetTop 变化）→ 自动 blur 输入框
   （Yandex Messenger 的方案，cododel.dev 有完整实现）——若以后做 iOS 版可抄
3. **focus 后别抢浏览器的 scrollIntoView**：只补自己滚动容器内的定位
4. **验收标准抄 openclaw PR#188388 的 jitter check**：帧级探针断言
   「无 painted frame bounce、textarea/composer/滚动方向永不反转、动画单调」
   —— 与我们 kb-arbitration-harness.js 的思路完全一致，可把断言扩到真机 Playwright

## 五、结论

- 键盘方案**不用改架构**：我们的实现就是 Android WebView 的业界正解；
  可补 pinch-zoom 过滤与帧级探针两项小强化
- 功能侧最值得抄的：AnnualReport 的「数据单文件驱动 + 分页报告」与双人报告、
  WeChatMsg 的引用跳转/时间轴锚点、TrailSnap 的那年今日评分自动播放
