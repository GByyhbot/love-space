# 账号与空间

> 阶段 0 实测样例 · ORIGIN `http://127.0.0.1:8353` · 账号 e2e1(管理员)/e2e2 · 采集时间 2026-11-11 08:47

### `GET /api/me`

unread/chat_unread 角标、space 主题/背景/推送配置都在这里

- 请求头：默认（登录态 Cookie）

**响应** `200`

```json
{"user":{"id":"823feeb85680412d9f23719e5e481c92","username":"e2e1","name":"小兔","admin":1,"avatar":""},"users":[{"id":"823feeb85680412d9f23719e5e481c92","username":"e2e1","name":"小兔","admin":1,"avatar":""},{"id":"04cfe47693914e7c9e96694ac57bf811","username":"e2e2","name":"小熊","admin":0,"avatar":""}],"space":{"name":"我们的恋爱空间","since":"","cover":"","theme":"rose","motion":true,"timezone":"Asia/Shanghai","chat_bg":"","chat_bg_media":"","chat_bg_dim":35},"unread":1,"chat_unread":0,"ntfy_topic":null,"ntfy_server":null}
```

### `PUT /api/profile`

字段以实际返回为准；传空串表示不修改头像

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"ok":true,"login_required":false}
```

### `PUT /api/space`

space 配置整体或部分更新；主题 7 色 + custom；chat_bg/chat_bg_users 聊天壁纸也在这里

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"ok":true}
```

### `POST /api/invite`

两人已绑定时返回 409「已经绑定了」——这是预期样例

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `409`（预期 409）

```json
{"detail":"你们已经绑定了"}
```

### `POST /api/logout`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"ok":true}
```

### `GET /api/me`

服务端删除会话记录 → 401，验证「过期/失效→回登录」路径

- 请求头：默认（登录态 Cookie）

**响应** `401`（预期 401）

```json
{"detail":"请先登录"}
```
