# 通知中心与渠道

> 阶段 0 实测样例 · ORIGIN `http://127.0.0.1:8353` · 账号 e2e1(管理员)/e2e2 · 采集时间 2026-11-11 08:47

### `GET /api/notices`

- 请求头：默认（登录态 Cookie）

**响应** `200`

```json
[{"id":"b5934ec0b4024bb787347a59473a8a2f","user_id":"823feeb85680412d9f23719e5e481c92","event":"chat","title":"收到一条新消息","record_id":"6d354bdefb984ee68c81f5a74054f124","created":1794358068.0766487,"seen":0,"dedupe":null},{"id":"15c2c632128b426b9b89fd78a4808ebe","user_id":"823feeb85680412d9f23719e5e481c92","event":"chat","title":"收到一条新消息","record_id":"c6a18b93c3e642f394918d31b9b41ce9","created":1794358042.9667106,"seen":1,"dedupe":null},{"id":"993bf71abed547c19d33e56f7efe14f7","user_id":"823feeb85680412d9f23719e5e481c92","event":"system","title":"你们的双人空间已开启","record_id":null,"created":1794358031.8847697,"seen":0,"dedupe":null}]
```

### `POST /api/notices/read?event=all`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"ok":true}
```

### `GET /api/channels`

10 种渠道：smtp/bark/serverchan/pushplus/wecom/webhook/telegram/dingtalk/feishu/ntfy

- 请求头：默认（登录态 Cookie）

**响应** `200`

```json
[]
```

### `GET /api/deliveries`

- 请求头：默认（登录态 Cookie）

**响应** `200`

```json
[]
```

### `GET /api/webpush`

- 请求头：默认（登录态 Cookie）

**响应** `200`

```json
{"public_key":"BBYpajgplmHvKtXx4z2hHs8TFkW3Esh2A8G1RG4U_yh9vqYY5P-RxaOcx-pgEEFtpP5a5toqVlhhTp2swa6EcMA","devices":0}
```
