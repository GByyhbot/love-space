# backdrop-filter / will-change / 滚动监听 全站登记表

> P1-1 / P1-2 验收产物。登记基准：2026-11-10，sw 284 之后。
> 纪律来源：`love-space-page-optimization-plan.md` P1-1（同屏可见 blur ≤4、动画元素禁 blur、静态区可保留）与 P1-2。

## 一、backdrop-filter 逐处登记（grep 全量，含已被覆盖的）

| 位置 | 选择器 | blur | 判定 | 说明 |
|---|---|---|---|---|
| style.css:779 | `.chat-panel.immersive .fn-panel` | 16px | **已移除**（sw 283 覆盖） | 键盘/面板动画区 |
| style.css:896 | `.chat-panel.has-wallpaper .chat-compose` | 16px+saturate | **已移除**（sw 283） | 同上；同行的 `.chat-header` blur 保留（不随键盘动） |
| style.css:947 | `.chat-panel.immersive .chat-time button` | 10px | **已移除**（sw 283） | 每条消息 3 颗，底色已加深补可读性 |
| style.css:953 | `.chat-panel.immersive .chat-compose .compose-field` | 14px+saturate | **已移除**（sw 283） | 动画区 |
| style.css:957 | `.chat-panel.immersive .chat-compose .compose-ib` | 10px | **已移除**（sw 283） | 动画区 |
| style.css:1185 | `.modal-overlay` | 10px+saturate | **保留** | 弹窗遮罩，弹起后静止，无尺寸动画 |
| style.css:1266 | `.lb-zoom` | 10px | **保留** | 看图器缩放条，静态浮层 |
| style.css:1381 | 移动端 `.sidebar`（底部导航） | 14px | **保留** | 常驻静态，不参与动画 |
| style.css:1978 | 桌面 `.topbar`（吸顶） | 10px | **保留** | sticky 静态 |
| style.css:2086 | 移动端 topbar | 12px | **保留** | 同上 |
| style.css:2116 | `html.is-native-app .topbar` | 14px | **保留** | 同上 |
| style.css:2136 | `.search-overlay` | 6px | **保留** | 搜索遮罩，fade-in 后静止 |
| style.css:2165 | `.hero-crop` | 6px | **保留** | 首页小胶囊，静态 |
| style.css:2305 | `.chat-panel.has-wallpaper .chat-reply-bar` | 12px | **保留** | 引用回复条，出现后静止（若日后做展开动画再移除） |
| style.css:2324 | `.pick-overlay` | 3px | **保留** | 选图遮罩，blur 值很小；fade-in（opacity）动画期间允许 |
| style.css:2532 | `.skin-on .chat-bubble` 等 | none | — | 皮肤气泡显式清 blur，属修复不是开销 |

**同屏可见 blur 计数**（最坏情形）：聊天页（照片壁纸 + 正在回复）= 聊天头 1 + 回复条 1 = **2 ≤ 4 ✅**；其它页面 ≤ 2 ✅。

## 二、will-change 登记

| 位置 | 选择器 | 判定 |
|---|---|---|
| style.css:1247 | `.lightbox-image` | **保留**：看图器捏合缩放需要独立合成层防掉帧；元素只在看图器打开时存在，无常驻成本。全站再无第二处 will-change。 |

## 三、scroll 监听 passive 审计

| 位置 | 监听 | 判定 |
|---|---|---|
| chat.js:324 | `#chat-log` scroll | 已是 `passive:true` ✅（回调只读 scrollTop/scrollHeight 后写基准，单元素读写、无级联） |
| app.js:861 | `visualViewport` resize/scroll（键盘仲裁） | **不动**——属 P0 键盘保护区，且 scroll 回调不 preventDefault，passive 无收益 |

时光页无限滚动、相册 blur-up、贴纸可视区均已用 IntersectionObserver（无 scroll 监听）✅。

## 四、P2-1 核查结论（无代码改动）

1. **gzip**：已有 `SelectiveGZip`（main.py:78，minimum_size=1024，放过 SSE 与二进制）✅，实测见提交说明。
2. **首屏接口并行**：`refreshData` 本就是 `Promise.all` 五路并行；首页的 `loadOnThisDay`/`loadYearbook` 是 fire-and-forget 异步、互不阻塞 ✅。
3. **关键 CSS 内联**：**不做**。style.css 206KB 全量内联会让每次进站都重新传输（无缓存复用），且 CSP/维护成本不划算；现状 CSS 单文件强缓存一年 + gzip 已是更优解。非首屏 JS 已全部 `defer` ✅。

## 五、P1-3 聊天节点窗口化：分期决策

- **现状**：#chat-log 最多 200 条消息（API 上限）≈ 2000~3000 个 DOM 节点。
- **第一阶段（sw 286 已试、sw 287 回退）**：给 `.chat-line` 加 `content-visibility:auto` 后实测翻车——屏外行只占估高（76px），渐进渲染时 scrollHeight 持续漂移：`scrollChat` 的 `scrollTop=scrollHeight` 在估高上贴底，行渲染出真实高度后内容高度又变，贴底失效（自动化实测 `nearBottom=false`、贴纸停播、IO 门控全乱）。聊天页贴底锚定（watchChatLog：ResizeObserver + 距底基准）依赖「渲染完成后高度稳定」这一前提，与按需渲染天然冲突。**渲染跳过对 200 行的收益本就有限，回退保稳。**
- **第二阶段（真·节点回收，暂缓）**：需改 paintChat 对账模型（对账要求节点在场）+ 滚动锚点补偿，收益仅剩内存占用。等真机实测「200 条消息下内存/帧率是否吃紧」再决定。度量方法：Chrome DevTools → Performance monitor（DOM Node 数 / JS heap），翻历史前后对比。
- 时光流 / 相册网格的 `content-visibility:auto`（sw 285）**保留**：窗口滚动 + IO 驱动、无自定义贴底锚定，回归全绿。
