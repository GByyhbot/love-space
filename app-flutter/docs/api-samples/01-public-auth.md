# 公开端点与鉴权语义

> 阶段 0 实测样例 · ORIGIN `http://127.0.0.1:8353` · 账号 e2e1(管理员)/e2e2 · 采集时间 2026-11-11 08:47

### `GET /health`

- 请求头：默认（登录态 Cookie）

**响应** `200`

```json
{"status":"ok"}
```

### `GET /api/status`

返回 initialized/paired/version/build/apk 等，App 据此判断是否已初始化

- 请求头：默认（登录态 Cookie）

**响应** `200`

```json
{"initialized":true,"paired":true,"setup_token_required":false,"version":"dev","build":"local","apk_version":"1.7.4","apk_url":"/apk/download","apk_mirror":"/static/lovespace.apk?v=1.7.4","apk_has_local":true,"apk_url_direct":"https://github.com/GByyhbot/love-space/releases/download/v1.7.4/app-release.apk","apk_proxy":"","apk_notes":"1.7.4 · 2026-11-09\n· 升级 Capacitor 8：键盘、状态栏、安全区改由官方插件接管，适配 Android 15/16 的 edge-to-edge 新规则\n· 移除自研补丁中与新架构冲突的部分，保留 insets 兜底桥\n· 后台运行通知仍为中文，并自动清理历史遗留的通知渠道\n· 其它功能一切照旧\n1.7.3 · 2026-11-09\n· 状态栏改回内容延伸（edge-to-edge）：颜色由网页自己画，和微信、QQ 同一套机制，七套主题、深浅色都能对上\n· 键盘保持 1.7.2 的表现：系统缩放为主，原生高度桥兜底\n· 其它功能一切照旧\n1.7.2 · 2026-11-09\n· 修状态栏颜色不跟主题走：改由原生直接取主题色染状态栏，浅色/深色与七套主题都能对上\n· 切换页面（聊天页与其它页）时状态栏颜色会跟着变，不再留接缝\n· 其它功能一切照旧\n1.7.1 · 2026-11-09\n· 键盘避让交还给系统：弹起键盘时窗口自己让位，输入栏跟着上移，不再靠网页逐帧算高度\n· 聊天页顶栏与输入栏改为不透明纯色，颜色跟随主题（和微信、QQ 一致），壁纸只留在消息区\n· 状态栏与顶栏连成一体，深色/浅色主题下图标都看得清\n· 其它功能一切照旧\n1.7.0 · 2026-11-06\n· 「一起看」功能整体下线：聊天面板去掉入口，放映室、片源管理与在线片源一并移除\n· 消息里旧的「一起看」邀请卡会按普通文字消息显示，历史记录不受影响\n· 键盘避让回到 1.6.11 的稳定表现（页面尺寸全程不动，只调内边距）\n· 聊天、相册、纪念日、生理期等功能一切照旧\n1.6.11 · 2026-11-06\n· 表情贴图内置进 App：打开表情面板秒出、断网也能用，不再等网络加载（贴图更新会随 App 版本一起发）\n1.6.10 · 2026-11-04\n· 新增「内网直连」"}
```

### `GET /api/routes`

客户端多线路基地址来源；主线路固定登录、不可达时按序切换

- 请求头：默认（登录态 Cookie）

**响应** `200`

```json
{"routes":[{"name":"Cloudflare 隧道","url":"https://love.yangyuhui.xyz/"},{"name":"节点小宝","url":"https://love-space.iepose.cn/"},{"name":"腾讯云 CloudBase","url":"https://love.350921.xyz/"},{"name":"Lucky 直连","url":"https://love-space.yangyuhui.xyz:4019/"},{"name":"内网直连","url":"http://192.168.31.95:1314/"}]}
```

### `GET /api/me`

无 Cookie → 401，客户端应回登录页

- 请求头：默认（登录态 Cookie）

**响应** `401`（预期 401）

```json
{"detail":"请先登录"}
```

### `POST /api/logout`

已登录（Cookie 有效）但写方法缺 `X-Love-Space: 1` → 403（唯一豁免 /api/proxy）；这是 Dart 拦截器必须统一注入的头。另注：未登录时写请求先撞 401「请先登录」（鉴权优先于缺头检查）

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `403`（预期 403）

```json
{"detail":"请求校验失败，请刷新页面"}
```

### `POST /api/login`

错误文案是中文 detail，Flutter 端可直接透传 UI

- 请求头关键项：`X-Love-Space: 1`

**响应** `401`（预期 401）

```json
{"detail":"账号或密码不正确"}
```

### `POST /api/login`

Set-Cookie: love_session=…；HttpOnly；SameSite=Strict；30 天有效。原生端用 dio+CookieJar 等价持久化

- 请求头关键项：`X-Love-Space: 1`

**响应** `200`

```json
{"ok":true}
```
