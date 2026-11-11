# 统一 records 模型（17 kind）

> 阶段 0 实测样例 · ORIGIN `http://127.0.0.1:8353` · 账号 e2e1(管理员)/e2e2 · 采集时间 2026-11-11 08:47

### `POST /api/records`

**client_id 幂等**：同一 (author, client_id) 重复提交返回既有记录（发送状态机的重试依据）

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"id":"13218623bf114ae991fe666de8ad6353","kind":"post","author":"823feeb85680412d9f23719e5e481c92","body":{"content":"阶段0样本动态","date":"2026-11-11","media":[]},"created":1794358045.9505417,"updated":1794358045.9505417,"deleted":null,"published":1794358045.9505417,"client_id":"s0-p1","likes":[],"comments":[],"media":[]}
```

### `POST /api/records`

返回的 id 与首次相同

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"id":"13218623bf114ae991fe666de8ad6353","kind":"post","author":"823feeb85680412d9f23719e5e481c92","body":{"content":"阶段0样本动态","date":"2026-11-11","media":[]},"created":1794358045.9505417,"updated":1794358045.9505417,"deleted":null,"published":1794358045.9505417,"client_id":"s0-p1","likes":[],"comments":[],"media":[]}
```

### `GET /api/records?kind=post&limit=10`

- 请求头：默认（登录态 Cookie）

**响应** `200`

```json
[{"id":"13218623bf114ae991fe666de8ad6353","kind":"post","author":"823feeb85680412d9f23719e5e481c92","body":{"content":"阶段0样本动态","date":"2026-11-11","media":[]},"created":1794358045.9505417,"updated":1794358045.9505417,"deleted":null,"published":1794358045.9505417,"client_id":"s0-p1","likes":[],"comments":[],"media":[]}]
```

### `GET /api/records?kind=post&q=阶段0`

- 请求头：默认（登录态 Cookie）

**响应** `200`

```json
[{"id":"13218623bf114ae991fe666de8ad6353","kind":"post","author":"823feeb85680412d9f23719e5e481c92","body":{"content":"阶段0样本动态","date":"2026-11-11","media":[]},"created":1794358045.9505417,"updated":1794358045.9505417,"deleted":null,"published":1794358045.9505417,"client_id":"s0-p1","likes":[],"comments":[],"media":[]}]
```

### `GET /api/records?kind=post&limit=1&before=1794358045.9505417&before_id=13218623bf114ae991fe666de8ad6353`

聊天/时光上翻历史用 before(创建时间)+before_id 游标

- 请求头：默认（登录态 Cookie）

**响应** `200`

```json
[]
```

### `GET /api/records/13218623bf114ae991fe666de8ad6353`

- 请求头：默认（登录态 Cookie）

**响应** `200`

```json
{"id":"13218623bf114ae991fe666de8ad6353","kind":"post","author":"823feeb85680412d9f23719e5e481c92","body":{"content":"阶段0样本动态","date":"2026-11-11","media":[]},"created":1794358045.9505417,"updated":1794358045.9505417,"deleted":null,"published":1794358045.9505417,"client_id":"s0-p1","likes":[],"comments":[],"media":[]}
```

### `PUT /api/records/13218623bf114ae991fe666de8ad6353`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"id":"13218623bf114ae991fe666de8ad6353","kind":"post","author":"823feeb85680412d9f23719e5e481c92","body":{"content":"阶段0样本动态（已编辑）","date":"2026-11-11","media":[]},"created":1794358045.9505417,"updated":1794358046.1285355,"deleted":null,"published":1794358045.9505417,"client_id":"s0-p1","likes":[],"comments":[],"media":[]}
```

### `POST /api/records/13218623bf114ae991fe666de8ad6353/like`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"ok":true}
```

### `POST /api/records/13218623bf114ae991fe666de8ad6353/comments`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"id":"448a1dc8bf1544afba71b7ad71ee81c4"}
```

### `DELETE /api/comments/448a1dc8bf1544afba71b7ad71ee81c4`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"ok":true}
```

### `POST /api/records/13218623bf114ae991fe666de8ad6353/restore`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"ok":true}
```

### `DELETE /api/records/13218623bf114ae991fe666de8ad6353`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"ok":true}
```

### `GET /api/records?trash=true`

- 请求头：默认（登录态 Cookie）

**响应** `200`

```json
[{"id":"13218623bf114ae991fe666de8ad6353","kind":"post","author":"823feeb85680412d9f23719e5e481c92","body":{"content":"阶段0样本动态（已编辑）","date":"2026-11-11","media":[]},"created":1794358045.9505417,"updated":1794358046.3122034,"deleted":1794358046.3122025,"published":1794358045.9505417,"client_id":"s0-p1","likes":["823feeb85680412d9f23719e5e481c92"],"comments":[],"media":[]}]
```

### `POST /api/records/13218623bf114ae991fe666de8ad6353/restore`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"ok":true}
```

### `POST /api/records`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"id":"503718b5762e458ea3fc136aca52e1b9","kind":"diary","author":"823feeb85680412d9f23719e5e481c92","body":{"content":"日记样本","date":"2026-11-11","media":[]},"created":1794358046.4136677,"updated":1794358046.4136677,"deleted":null,"published":null,"client_id":"s0-d","likes":[],"comments":[],"media":[]}
```

### `POST /api/records`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"id":"8caad64845d84f6d9355499e922ab994","kind":"draft","author":"823feeb85680412d9f23719e5e481c92","body":{"content":"草稿样本","date":"2026-11-11","media":[]},"created":1794358046.4444294,"updated":1794358046.4444294,"deleted":null,"published":null,"client_id":"s0-dr","likes":[],"comments":[],"media":[]}
```

### `POST /api/records`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"id":"c83e7874323846aaa3b5e13016f9e552","kind":"album","author":"823feeb85680412d9f23719e5e481c92","body":{"title":"样本相册","media":[]},"created":1794358046.4731505,"updated":1794358046.4731505,"deleted":null,"published":1794358046.4731505,"client_id":"s0-al","likes":[],"comments":[],"media":[]}
```

### `POST /api/records`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"id":"248b0c79e55349a09fad4ad3e59e0849","kind":"anniversary","author":"823feeb85680412d9f23719e5e481c92","body":{"title":"样本纪念日","date":"2027-01-01","annual":true,"remind_days":3,"media":[]},"created":1794358046.5025513,"updated":1794358046.5025513,"deleted":null,"published":1794358046.5025513,"client_id":"s0-an","likes":[],"comments":[],"media":[]}
```

### `POST /api/records`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"id":"8e2bb47dcc244a348849e6cf2bfd7d0f","kind":"wish","author":"823feeb85680412d9f23719e5e481c92","body":{"title":"样本愿望","category":"小心愿","media":[]},"created":1794358046.5293672,"updated":1794358046.5293672,"deleted":null,"published":1794358046.5293672,"client_id":"s0-w","likes":[],"comments":[],"media":[]}
```

### `POST /api/records`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"id":"50c45c22f33c42829552de244d787985","kind":"mood","author":"823feeb85680412d9f23719e5e481c92","body":{"emoji":"☀️","media":[]},"created":1794358046.5564885,"updated":1794358046.5564885,"deleted":null,"published":1794358046.5564885,"client_id":"s0-m","likes":[],"comments":[],"media":[]}
```

### `POST /api/records`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"id":"98912f665b8448989176c7c70afb1186","kind":"note","author":"823feeb85680412d9f23719e5e481c92","body":{"content":"留言样本","media":[]},"created":1794358046.5858002,"updated":1794358046.5858002,"deleted":null,"published":1794358046.5858002,"client_id":"s0-n","likes":[],"comments":[],"media":[]}
```

### `POST /api/records`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"id":"11417b2de52c4dff97c62c88cadaa4e5","kind":"question","author":"823feeb85680412d9f23719e5e481c92","body":{"title":"样本问题：今晚吃什么","content":"","media":[]},"created":1794358046.6127808,"updated":1794358046.6127808,"deleted":null,"published":1794358046.6127808,"client_id":"s0-q","likes":[],"comments":[],"answers":[],"answer_count":0,"media":[]}
```

### `POST /api/records`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"id":"5a0c68c51960407fb583754f7a8a122b","kind":"habit","author":"823feeb85680412d9f23719e5e481c92","body":{"title":"样本打卡","category":"日常","media":[]},"created":1794358046.6423306,"updated":1794358046.6423306,"deleted":null,"published":1794358046.6423306,"client_id":"s0-h","likes":[],"comments":[],"checks":[],"media":[]}
```

### `POST /api/records`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"id":"ba4bcce49ae84455b37a40336ea8525c","kind":"quest","author":"823feeb85680412d9f23719e5e481c92","body":{"title":"样本清单","category":"自定义","media":[]},"created":1794358046.6687667,"updated":1794358046.6687667,"deleted":null,"published":1794358046.6687667,"client_id":"s0-qu","likes":[],"comments":[],"media":[]}
```

### `POST /api/records`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"id":"4514051c5fbd4dd5839ef79b1352b77d","kind":"ledger","author":"823feeb85680412d9f23719e5e481c92","body":{"amount":12.5,"category":"伙食","content":"样本账本","media":[]},"created":1794358046.695536,"updated":1794358046.695536,"deleted":null,"published":1794358046.695536,"client_id":"s0-l","likes":[],"comments":[],"media":[]}
```

### `POST /api/records`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"id":"3951dff1e58643c0999a82a46a30577d","kind":"surprise","author":"823feeb85680412d9f23719e5e481c92","body":{"content":"惊喜样本","publish_at":1794444446,"media":[]},"created":1794358046.7230203,"updated":1794358046.7230203,"deleted":null,"published":null,"client_id":"s0-s","likes":[],"comments":[],"media":[]}
```

### `POST /api/records`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"id":"12c1256a25164af0b3d61f854a0fe3e3","kind":"chat","author":"823feeb85680412d9f23719e5e481c92","body":{"content":"聊天样本消息","media":[]},"created":1794358046.7493746,"updated":1794358046.7493746,"deleted":null,"published":1794358046.7493746,"client_id":"s0-c","likes":[],"comments":[],"media":[]}
```

### `POST /api/records/12c1256a25164af0b3d61f854a0fe3e3/pin`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"ok":true,"pinned":true}
```

### `POST /api/records/12c1256a25164af0b3d61f854a0fe3e3/pin`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"ok":true,"pinned":false}
```

### `POST /api/records/12c1256a25164af0b3d61f854a0fe3e3/recall`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"ok":true}
```

### `POST /api/records/11417b2de52c4dff97c62c88cadaa4e5/answer`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"ok":true}
```

### `POST /api/records/5a0c68c51960407fb583754f7a8a122b/check`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"ok":true}
```

### `POST /api/personal-wishes`

**必须走专属端点**；通用 records CRUD 不接受该 kind

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"id":"569a6aac7bf4488facf64b5a38e496d3","kind":"personal_wish","author":"823feeb85680412d9f23719e5e481c92","body":{"title":"心愿样本","locked":false,"content":"许愿内容","sealed":{"salt":"YlGSjY3md6jzuIHyG_W5YQ==","nonce":"XoUubr6FEt8ebz07","ciphertext":"O61xsXDaUAiRfeJV_WoprFVAYPy17JqqjQ-Sgg=="}},"created":1794358047.0530052,"updated":1794358047.0530052,"deleted":null,"published":1794358047.0530052,"client_id":null,"likes":[],"comments":[],"media":[]}
```

### `POST /api/personal-wishes/569a6aac7bf4488facf64b5a38e496d3/unlock`

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `200`（预期 200）

```json
{"content":"许愿内容"}
```

### `POST /api/records`

错误文案中文 detail 直通 UI

- 请求头：默认（登录态 Cookie + `X-Love-Space: 1`）

**响应** `422`（预期 422）

```json
{"detail":"相册不存在"}
```
