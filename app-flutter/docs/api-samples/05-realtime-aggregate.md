# 实时通道与聚合端点

> 阶段 0 实测样例 · ORIGIN `http://127.0.0.1:8353` · 账号 e2e1(管理员)/e2e2 · 采集时间 2026-11-11 08:47

### `GET /api/events`（流式采样 7s）

首行 `retry: 3000`，随后 `: ready` 注释与 `: heartbeat` 心跳（约 2s 一次）；变化时推 `data: {...}`（含 rev 与 refresh/chat/other 标志）。无 WebSocket 消息通道——Flutter 端用流式 HTTP 实现，断线按 retry 起步指数退避封顶 30s（与 Web 一致），进后台断开、回前台补拉。**经验：无限流端点绝不能用普通请求采样（心跳会让读超时永不触发），必须流式 + 时间上限。**

```
retry: 3000

: ready

: heartbeat

: heartbeat
```
### `GET /api/events`（真实触发样例）

捕获到 chat 事件：False


### `GET /api/dashboard`

- 请求头：默认（登录态 Cookie）

**响应** `200`

```json
{"total":19,"by_kind":{"album":1,"anniversary":1,"chat":5,"diary":1,"draft":1,"habit":1,"ledger":1,"mood":1,"note":1,"personal_wish":1,"post":1,"quest":1,"question":1,"surprise":1,"wish":1},"months":[{"month":"2026-11","count":19}],"moods":{"☀️":1},"likes":1,"comments":0,"photos":0,"days_together":null,"wishes_total":1,"wishes_done":0}
```

### `GET /api/weekly`

- 请求头：默认（登录态 Cookie）

**响应** `200`

```json
{"offset":0,"label":"这一周","start":"2026-11-09","end":"2026-11-15","total":19,"prev_total":0,"delta":19,"days_active":1,"photos":1,"by_kind":{"chat":5,"post":1,"diary":1,"draft":1,"album":1,"anniversary":1,"wish":1,"mood":1,"note":1,"question":1,"habit":1,"quest":1,"ledger":1,"surprise":1,"personal_wish":1},"moods":{"☀️":1},"top_mood":"☀️","likes":1,"comments":0,"streak":1,"last_record_days_ago":null,"highlights":[{"id":"2a89f6d0a41b44afad8f1734efd713ed","kind":"chat","author":"823feeb85680412d9f23719e5e481c92","body":{"content":"e2e-1794358036599","date":"2026-11-11","media":[]},"created":1794358036.670773,"updated":1794358036.670773,"deleted":null,"published":1794358036.670773,"client_id":"435640e7-6a58-4297-9de2-11a1fbecab94","likes":[],"comments":[],"media":[]},{"id":"81385ff2d7cf4a56aab6ebb285b314bd","kind":"chat","author":"823feeb85680412d9f23719e5e481c92","body":{"content":"看图","media":["93e941af5961478bb463e69e1f184311"]},"created":1794358036.8185856,"updated":1794358036.8185856,"deleted":null,"published":1794358036.8185856,"client_id":"img-1794358036800","likes":[],"comments":[],"media":[{"id":"93e941af5961478bb463e69e1f184311","name":"e2e.png","mime":"image/png","size":186,"status":"pending","preview":null}]},{"id":"c6a18b93c3e642f394918d31b9b41ce9","kind":"chat","author":"04cfe47693914e7c9e96694ac57bf811","body":{"content":"对方-1794358042921","media":[]},"created":1794358042.9665506,"updated":1794358042.9665506,"deleted":null,"published":1794358042.9665506,"client_id":"e2e-1794358042921","likes":[],"comments":[],"media":[]},{"id":"13218623bf114ae991fe666de8ad6353","kind":"post","author":"823feeb85680412d9f23719e5e481c92","body":{"content":"阶段0样本动态（已编辑）","date":"2026-11-11","media":[]},"created":1794358045.9505417,"updated":1794358046.3820891,"deleted":null,"published":1794358045.9505417,"client_id":"s0-p1","likes":["823feeb85680412d9f23719e5e481c92"],"comments":[],"media":[]}],"message":"这一周，你们一起写下了 19 段回忆、1 张照片，有 1 天留下了痕迹。"}
```

### `GET /api/yearbook`

- 请求头：默认（登录态 Cookie）

**响应** `200`

```json
{"year":2026,"is_current":true,"total":12,"by_kind":{"post":1,"diary":1,"draft":1,"wish":1,"mood":1,"note":1,"question":1,"habit":1,"quest":1,"ledger":1,"surprise":1,"personal_wish":1},"photos":0,"moods":1,"wishes_done":0,"anniversaries":0,"active_days":1,"streak":1,"best_month":{"month":11,"count":12},"best_weekday":{"weekday":2,"count":12},"top_kind":{"kind":"diary","count":1},"mood_top":[{"emoji":"☀️","n":1}],"words":[{"w":"样本","n":11}],"interactions":1}
```

### `GET /api/calendar?month=2026-11`

- 请求头：默认（登录态 Cookie）

**响应** `200`

```json
{"month":"2026-11","days":{"11":{"posts":[{"id":"13218623bf114ae991fe666de8ad6353","title":"阶段0样本动态（已编辑）"}],"checks":[{"author":"823feeb85680412d9f23719e5e481c92"}]}}}
```

### `GET /api/on-this-day`

- 请求头：默认（登录态 Cookie）

**响应** `200`

```json
[{"year":2026,"is_today":true,"items":[{"id":"13218623bf114ae991fe666de8ad6353","kind":"post","author":"823feeb85680412d9f23719e5e481c92","body":{"content":"阶段0样本动态（已编辑）","date":"2026-11-11","media":[]},"created":1794358045.9505417,"updated":1794358046.3820891,"deleted":null,"published":1794358045.9505417,"client_id":"s0-p1","likes":["823feeb85680412d9f23719e5e481c92"],"comments":[],"media":[]},{"id":"503718b5762e458ea3fc136aca52e1b9","kind":"diary","author":"823feeb85680412d9f23719e5e481c92","body":{"content":"日记样本","date":"2026-11-11","media":[]},"created":1794358046.4136677,"updated":1794358046.4136677,"deleted":null,"published":null,"client_id":"s0-d","likes":[],"comments":[],"media":[]},{"id":"8caad64845d84f6d9355499e922ab994","kind":"draft","author":"823feeb85680412d9f23719e5e481c92","body":{"content":"草稿样本","date":"2026-11-11","media":[]},"created":1794358046.4444294,"updated":1794358046.4444294,"deleted":null,"published":null,"client_id":"s0-dr","likes":[],"comments":[],"media":[]}]}]
```
