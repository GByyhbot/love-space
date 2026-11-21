# love-space 深度性能/资源分析报告

- 仓库：GByyhbot/love-space（main 分支，2026-11-21 读取）
- 范围：后端 `app/*.py` 全量 + Dockerfile / docker-compose.yml / requirements.txt + `static/` 主要资源
- 方法：逐行审读源码，全部结论给出 `文件:行号` 证据；推测均标注「推测」
- 部署背景：单容器（uvicorn 单进程 + 同进程 worker 线程），fnOS NAS，容器内存上限 2 GiB（docker-compose.yml `mem_limit: ${LOVE_MEM_LIMIT:-2g}`）

---

## 1. 现状速览

这是一个为两个人优化得很细的系统：SQLite 触发器维护 O(1) 的 revision 计数、SSE 只推「该刷新了」的信号、序列化有批量版（`serialize_many` 300 条分批）、通知投递刻意串行以避开 SQLite 写锁、转码有原子认领与中断恢复、缓存头策略（ETag 304、`?v=` 强缓存、SW 预缓存）都做过认真的功课。真正的性能风险不在单次请求，而在**随数据量线性增长的周期性全表扫描**：worker 每约 60 秒对 records 全表做两轮完整的 body 解析（其中一轮还逐条解密私密记录），且这个「60 秒」是按循环计数而非墙钟计的——聊天越活跃，循环被 nudge 唤醒得越频繁，全表扫描跑得越密。其次是**聚合类接口（年报/月历/历史上的今天）每次调用都全表序列化**，以及**转码链路单线程串行、全分辨率 libx264 重编码、无线程上限**，在 NAS 弱 CPU 上会直接顶满所有核心并拖慢同进程的 API。数据库索引对 records/notices/投递队列覆盖良好，但 **media 表除主键外零索引**，转码认领每 2 秒全表扫一次 media。整体判断：当前数据量（两人、数千条记录）下这些问题大多还只是「背景 CPU 偏高」，但全部随记录总量线性恶化，值得在数据涨起来之前处理。

---

## 2. 关键参数总表

### 2.1 worker 周期与节拍

| 参数 | 数值 | 出处 |
|---|---|---|
| worker 主循环基础节拍 | 5 s（`wake.wait(5)`，可被 nudge 提前唤醒） | app/worker.py:619 |
| maintenance（schedule+cleanup+备份检查）周期 | 每 12 个循环 ≈ 名义 60 s（按计数非墙钟，见问题 P2） | app/worker.py:599 |
| 打卡提醒 habit_reminders 周期 | 每 6 个循环 ≈ 名义 30 s，仅本地时间 ≥20:00 做实事 | app/worker.py:603；app/worker.py:277 |
| 投放夹 music_drop 扫描周期 | 每 60 个循环 ≈ 名义 300 s（≤5 分钟口径） | app/worker.py:606 |
| 转码队列空闲轮询 | 2 s（`stop.wait(2)`） | app/worker.py:591 |
| 投递每轮上限：渠道 deliveries | LIMIT 20 | app/worker.py:305 |
| 投递每轮上限：push_outbox（ntfy） | LIMIT 20 | app/worker.py:368 |
| 投递每轮上限：webpush_outbox | LIMIT 40 | app/worker.py:405 |
| 渠道投递失败退避 | `min(3600, 60*2^attempts)` s，≥4 次判 failed | app/worker.py:355-357 |
| push/webpush 失败退避 | `min(3600, 30*2^attempts)` s，≥6 次判 failed | app/worker.py:389；app/worker.py:441 |
| 渠道默认最小间隔 interval | 300 s；免打扰默认 22:00–08:00 | app/main.py:2741（ChannelInput 默认）；app/db.py channels 表定义（quiet_start 22 / quiet_end 8） |
| 聊天通知合并窗口 CHAT_DELAY | 15 s | app/db.py:431 |
| 已读通知保留 | 90 天（cleanup 删除 seen=1 且更早的） | app/worker.py:473 |
| 孤儿附件（attached=0）回收 | 24 h | app/worker.py:496 |
| 无引用媒体兜底回收 | 30 天 | app/worker.py:501 |
| 临时 zip / 残留 tmp 目录 / 备份.partial 清理 | 24 h / 1 h / 1 h | app/worker.py:504-531 |
| 自动备份周期 | 86400 s（24 h） | app/worker.py:548 |
| 备份失败退避 BACKUP_RETRY_AFTER | 3600 s | app/worker.py:31 |
| 备份保留份数 | 7 份 | app/backups.py:284 附近（`sorted(...)[7:]` 删除） |
| 备份加密分块 | 4 MiB 流式 | app/backups.py:139 |

### 2.2 转码与媒体处理

| 参数 | 数值 | 出处 |
|---|---|---|
| 视频转码超时 MEDIA_TIMEOUT | 300 s | app/worker.py:47 |
| 封面抽帧超时 MEDIA_POSTER_TIMEOUT | 120 s | app/worker.py:48 |
| run_ffmpeg 状态轮询间隔 | 0.5 s | app/worker.py:72 |
| 视频 ffmpeg 参数原文 | `-vf scale=trunc(iw/2)*2:trunc(ih/2)*2 -c:v libx264 -preset fast -crf 25 -pix_fmt yuv420p`，音频 `-c:a aac`，`-map_metadata -1`，`-movflags +faststart` | app/worker.py:152-157 |
| 封面抽帧参数原文 | `ffmpeg -y -i <原文件> -frames:v 1 -vf scale=640:-2 <poster>` | app/worker.py:163-164 |
| 图片预览 | Pillow `thumbnail((1600,1600))`，JPEG quality=86，EXIF 转正后 convert('RGB') | app/worker.py:140-143 |
| 转码并发 | 1（单个 media_loop 线程串行认领） | app/worker.py:583-595 |
| 上传分块 | 1 MiB 流式写盘 | app/main.py:1801 |
| 单文件上传上限 MAX_UPLOAD_MB | 250 MB（env 可调） | app/main.py:1804；docker-compose.yml |
| 上传限流 | 30 次 / 300 s | app/main.py:1783 |
| music_drop 新文件静置门槛 FRESH_SECONDS | 120 s | app/music_drop.py:36 |
| music_drop ffprobe 超时 | 30 s | app/music_drop.py:76 |

### 2.3 接口、SSE、缓存

| 参数 | 数值 | 出处 |
|---|---|---|
| SSE 轮询间隔 | 5 s（`asyncio.sleep(5)`） | app/main.py:2283 |
| SSE 断线重连 retry | 3000 ms | app/main.py:2249 |
| SSE 会话校验频率 | 每 10 轮（≈50 s）查一次 sessions | app/main.py:2259 |
| SSE 每轮查询 | 1 条组合 SQL（5 个标量子查询：content_revision / user_revision / unread count / chat_revision / other_revision） | app/main.py:2177-2200 |
| typing 心跳 TTL | 5.0 s（内存态，不落库） | app/main.py:1969 |
| /api/records limit 上限 | 1000 | app/main.py:1245 |
| /api/records 批大小 | 500（有 limit 时按剩余量放大，min 500） | app/main.py:1292 |
| serialize_many 分批 | 300 条/批，每批 5 类关联查询 + 媒体分批 300 | app/serializers.py:58-77 |
| /api/notices | LIMIT 200 | app/main.py:2149 |
| /api/imports/{id}/messages | limit 默认 100，上限 500 | app/main.py:3146 |
| /api/media/images | limit 默认 200 上限 400，SQL 先取 limit×4 再逐条过滤 | app/main.py:1911-1916 |
| /api/media/videos | limit 默认 60 上限 200，同样 ×4 过取 | app/main.py:1933 附近 |
| /api/photos 媒体批量查 | 500 个 id 一块 | app/main.py:1890 附近 |
| /media 缓存头 | `private, max-age=0, must-revalidate` + ETag/Last-Modified 条件请求 304 | app/main.py 中间件（/media/ 分支）；app/main.py:1855 `_conditional` |
| /api/bubbles/{pack}/{name} 缓存 | `private, max-age=31536000, immutable` | app/main.py:2141 附近 |
| 带?v= 静态资源缓存 | `public, max-age=31536000, immutable`（.apk 例外为 no-cache） | app/main.py 中间件（/static/ 分支） |
| HTML 外壳 / sw.js | no-store / no-cache | app/main.py 中间件 |
| /api/* 缓存 | no-store | app/main.py 中间件 |
| GZip | minimum_size=1024；SSE、/media/、/api/export、/api/music/stream 直通不压 | app/main.py:95-105 |
| 在线音乐搜索缓存 | 进程内存，TTL 600 s，上限 200 条（满时淘汰最旧 100） | app/main.py:2013；app/main.py:2044 |
| 在线音乐搜索上游超时 | httpx 9 s | app/main.py:2021 |
| 音乐试听转发 | httpx Timeout(20s, connect 8s)，64 KiB 分块中继，响应头 `Cache-Control: private, max-age=86400` | app/main.py:2066-2082 |
| AI 合成台代理 /api/proxy | 超时 300 s（connect 15 s），请求体上限 24 MiB | app/main.py:524；app/main.py:470 |

### 2.4 数据库与安全开销

| 参数 | 数值 | 出处 |
|---|---|---|
| SQLite 连接模式 | 每次操作新建连接（contextmanager，用完 commit+close），无连接池 | app/db.py:89-103 |
| sqlite3.connect timeout | 30 s | app/db.py:91 |
| PRAGMA busy_timeout | 30000 ms | app/db.py:96 |
| PRAGMA journal_mode | WAL（init 时设置一次，库级持久） | app/db.py:111 |
| PRAGMA synchronous / cache_size / mmap / wal_autocheckpoint | **未设置**（synchronous 用默认 FULL；cache_size 用默认约 2 MiB/连接） | app/db.py:89-103 全段无此项 |
| 会话有效期 | 30 天 | app/security.py:180（login_session） |
| 账号密码哈希 | scrypt n=16384, r=8, p=1 | app/security.py:57 |
| 个人心愿密码派生 | PBKDF2-HMAC-SHA256 600,000 次 | app/security.py:88；app/security.py:98 |
| 私密记录解密 | 每条：读 secret.key 文件 + HKDF 派生 + AES-GCM 解密（无缓存） | app/security.py:18-27；app/security.py:115 |
| 限流默认值 | 20 次 / 900 s（login/setup/join）；export 10/300；backup 5/300；imports 30/300 | app/security.py:193；app/main.py:2814、2908、3064 |

### 2.5 进程与镜像

| 参数 | 数值 | 出处 |
|---|---|---|
| uvicorn 进程数 | 1（CMD 无 --workers） | Dockerfile:57 |
| worker 形态 | 同进程 2 条线程（主循环 + media_loop），RUN_WORKER 控制 | app/main.py lifespan（约 85-90 行）；app/worker.py:574 |
| 基础镜像 | python:3.13-slim + apt ffmpeg + tzdata | Dockerfile:1、24-27 |
| 容器内存上限 | 2 GiB（compose 默认） | docker-compose.yml |
| /tmp tmpfs | 256 MiB | docker-compose.yml |
| 健康检查 | 60 s 间隔，/health（每次开一个新连接跑 SELECT 1） | Dockerfile:54-55；app/main.py:443 |
| 日志 | json-file max-size 10m × 3 | docker-compose.yml |

---

## 3. 问题清单（按影响排序）

### P1. worker 每约 60 秒对 records 全表做两轮完整 body 解析（一轮含逐条解密）

- **证据**：
- `schedule()`：`SELECT * FROM records WHERE deleted IS NULL` 后逐行 `db.body_decode(row)`（app/worker.py:229 及紧随的循环）。
- `cleanup()`：`SELECT body FROM records WHERE kind NOT IN (...)` 逐行 `json.loads`，再对私密 kind 逐行 `db.body_decode`（app/worker.py:479 起）。
- 两者都由 `maintenance()` 在每个 maintenance 周期无条件调用（app/worker.py:538-541、599）。
- 私密记录的 `body_decode` 走 AES-GCM 解密，且每次解密都重新读密钥文件并做 HKDF 派生（app/security.py:18-27、115；app/db.py `body_decode`）。
- **机理**：records 是全站增长最快的表（代码注释自述聊天占全部记录约 88%，见 app/db.py:177-181）。schedule 实际只需要 surprise/anniversary/wish 三类 + 里程碑/存储检查，却把每条聊天记录的 body 都 JSON 解析一遍；cleanup 为了算「在用媒体集合」同样全量解析。两轮合计每分钟把整个库的正文在 Python 里过两遍，成本随记录总量线性增长，且发生在 API 同进程的线程里（GIL 竞争会直接抬高请求延迟）。这是全系统最大的稳态背景 CPU 来源（推测：当前数据量下单轮为几十到几百毫秒级，记录到 5 万条量级后将进入秒级）。
- **优化建议**：
1. schedule 的主循环加 kind 过滤：`WHERE deleted IS NULL AND kind IN ('surprise','anniversary','wish')`，直接命中已有索引 records_kind(kind, created)（app/db.py:122）。里程碑/存储/会话清理与 records 无关，不受影响。
2. cleanup 的在用集合改 SQL 下推：非私密记录用 `json_each(body,'$.media')` + `json_extract(body,'$.song.mid')` 在 SQL 里取（同文件已有先例：`media_in_visible_record`，app/db.py:686-720），避免把 body 拉回 Python；私密记录行数小，保留解密路径。
3. 若仍嫌贵，把 cleanup 拆出 maintenance 单独降频（如 10 分钟一轮）：孤儿回收口径是 24 h / 30 天，分钟级频率没有必要。
- **预期收益**：稳态背景 CPU 下降一个数量级（全表解析从每分钟两轮降到近零）；写锁持有时间缩短，聊天发送延迟更稳。
- **风险/改动量**：中低。需保证 schedule 的 surprise 发布、纪念日提醒语义不变（kind 过滤后逐条验证）；cleanup 改 SQL 后要用现有护栏测试对拍在用集合。
- **验证方法**：改前/改后在容器里给 maintenance 打耗时日志（或 py-spy dump 采样 worker 线程）；`sqlite3 love.db "EXPLAIN QUERY PLAN SELECT... WHERE kind IN (...)"` 确认走 records_kind；`docker stats love-space` 观察空闲时段 CPU 基线。

### P2. 周期任务按「循环计数」而非墙钟计时，nudge 会把实际频率成倍放大

- **证据**：主循环每轮 `counter += 1`（app/worker.py:617），周期门控是 `counter % 12`（maintenance）、`counter % 6`（habit）、`counter % 60`（music_drop）（app/worker.py:599-607）；循环末尾 `wake.wait(5)`（app/worker.py:619）在有新通知时被 `nudge()` 提前唤醒——而每条聊天/记录创建都会调 `nudge_worker()`（app/main.py `create_record` 等多处）。投递本身就该即时，但计数器不区分「5 秒自然 tick」和「被唤醒的 tick」。
- **机理**：两人热聊时，每发一条消息就多一个 tick，counter 转速远高于 1 tick/5 s：名义 60 s 的 maintenance 可能十几秒就跑一轮，与 P1 叠加后，全表扫描频率随聊天活跃度进一步放大；music_drop 的「5 分钟」也会被压缩（其内部有 120 s 静置门槛兜底，影响较小）。这是隐蔽的正反馈：越活跃 → 后台越忙 → API 越慢。
- **优化建议**：周期任务改墙钟门控：记录每个任务的 `last_run` 时间戳，到期才跑；nudge 只影响投递（deliver 三件套保持每轮执行）。
- **预期收益**：周期任务频率回到设计值且可预测；与 P1 互为乘数，组合收益最大。
- **风险/改动量**：低。纯 worker 内部改动，需注意首次启动各任务立即跑一次的现有语义。
- **验证方法**：在 maintenance 入口加一行 debug 日志带时间戳，热聊场景下观察相邻两次间隔是否稳定 ≈60 s；或统计 10 分钟内 schedule 执行次数。

### P3. 聚合接口每次调用全表序列化：/api/yearbook、/api/calendar、/api/on-this-day、/api/export/ics

- **证据**：
- yearbook：`SELECT * FROM records ORDER BY created` 全表取回，Python 里过滤 visible/kind，再 `serialize_many` 序列化**全部**记录后才按年份筛选（app/main.py:2490 起）。
- calendar：`SELECT * FROM records`（无任何 WHERE），全表 visible 过滤 + 全表 serialize_many，只为渲染一个月（app/main.py:2576）。
- on-this-day：同 yearbook 模式，全表 + 全量序列化后按月-日分组（app/main.py:2635）。
- export/ics：同模式全表（app/main.py:2844），但有导出限流兜底，优先级最低。
- serialize_many 本身是好的（300 分批、关联查询 O(N/300)），但它对每个候选行都执行 body_decode + 构建完整 dict（含 likes/comments/media 子结构），不匹配的行也照付全价（app/serializers.py:58-77）。
- **机理**：这四个接口的单次成本 = O(全部记录 × (JSON 解析/解密 + 序列化))，与「用户只看一年/一月/一天」的需求完全脱钩。首页年报卡、月历页都是常打开的页面（推测：年报卡在 App 首页，打开即调），数据涨到数万条后单次调用可达数百毫秒至秒级（推测），且在线程池里占住一个线程 + 一份全量内存副本。
- **优化建议**：
1. 先过滤后序列化：第一遍只 decode body 取 date/kind 做筛选（或用 `json_extract(body,'$.date')` 在 SQL 侧粗筛），只对入选行调 serialize_many。
2. revision 键控缓存：这三个接口的结果只随 content_revision 变化（app_state 已有该计数，app/db.py:184），进程内按 (接口, 参数, revision) 缓存结果 JSON，revision 不变直接返回——两人场景下命中率会非常高。
3. calendar 可直接按 kind IN ('mood','post','anniversary','habit') + 月份粗筛。
- **预期收益**：这三个接口从 O(全表) 降到 O(当期记录) 或 O(1)（缓存命中时）；首页打开速度与 NAS 负载明显改善。
- **风险/改动量**：中。筛选口径（album_only、可见性、body.date 优先）必须与现有 Python 逻辑逐项对拍；缓存方案要小心 period 分库记录不在主库 revision 覆盖内（period 写入走 _period_touch 推共享 revision，app/main.py:1400 附近，已覆盖）。
- **验证方法**：`curl -w '%{time_total}'` 对三个接口在改前后各测 10 次取中位数；用 `EXPLAIN QUERY PLAN` 看粗筛 SQL；记录数翻倍造数后复测确认亚线性。

### P4. /api/records 的搜索与日期过滤：函数包裹列 + Python 层逐行匹配，且每行 body 被重复解码 3 次

- **证据**：
- 搜索 `q`：SQL 完全不过滤，取回批次后在 Python 里 `q.lower() not in (content+title).lower()` 逐行筛（app/main.py:1300-1303），外层 while 循环会持续以 500 条/批向后翻，直到凑满 limit 或扫完整表（app/main.py:1284-1320）。
- 日期过滤：`json_extract(body,'$.date')=?`（app/main.py:1282）——函数包裹 body 列，无索引可用；trash/私密场景更退化为 Python 过滤（date_in_python 分支）。
- album_only 过滤：`json_extract(body,'$.album_only') IS NOT 1`（app/main.py:1262）挂在几乎所有列表查询上，每行都要算一次 json_extract（行数 ≤1000 时可接受，但与上面两项叠加）。
- 重复解码：同一行 body 在端点过滤循环里 decode 一次（app/main.py:1300），`serialize_many` 为收集 media id 再 decode 一次（app/serializers.py:72），`serialize` 里第三次（app/serializers.py:19）。私密 kind 每次 decode 还含 AES-GCM + 读密钥文件 + HKDF（见 P8）。
- **机理**：默认列表（无 q）靠 (created,id) 游标 + LIMIT，成本可控；但**站内搜索**是最坏路径：关键词命中稀疏时要把全表 body 解码一遍才能凑满一页。records_deleted_created(deleted, created DESC)（app/db.py:324）能支撑排序与 deleted 过滤，但 json_extract 条件只能逐行求值。
- **优化建议**：
1. 给 records 加生成列 + 索引：`body_date TEXT GENERATED ALWAYS AS (json_extract(body,'$.date')) VIRTUAL` 并建索引；album_only 同理可做生成列。SQLite 生成列对密封 body（私密 kind）取不到值，但那几类本就走 Python 路径，不受影响。
2. 搜索引入 FTS5（content/title 建全文索引，中文按现有 _year_words 的 2-gram 思路或 trigram 分词器）——改动较大，可排后；轻量替代：先用 `body LIKE` 粗筛再 Python 精筛，至少让 SQLite 在 C 层过滤而不是把每行 body 搬回 Python 解码。
3. 解码收敛：端点把已 decode 的 body 透传给 serialize_many/serialize（一行只解一次）。
- **预期收益**：搜索从 O(全表解码) 降到 O(命中集)；日期型查询可走索引；列表接口 CPU 约降 1/3（少两次 decode）。
- **风险/改动量**：中。生成列需走 db.py 的 MIGRATIONS 版本化迁移通道（app/db.py:395 起已有机制）；FTS5 为高改动，建议独立排期。
- **验证方法**：`EXPLAIN QUERY PLAN` 对比改前后 date 查询是否走新索引；对同一关键词搜索计时；用 `python -X importtime` 无关——直接在端点加 timing 日志或 curl 计时。

### P5. 视频转码：单线程串行 + 全分辨率 libx264 重编码 + 无 CPU 线程上限

- **证据**：
- 认领与处理严格串行：单个 media_loop 线程，一次 `process_media` 只处理一条（app/worker.py:583-595、92-110）。
- 参数：不对分辨率设上限（`scale=trunc(iw/2)*2:trunc(ih/2)*2` 只保证偶数尺寸），libx264 `preset fast, crf 25`，无 `-threads` 限制（app/worker.py:154）。
- 封面是第二次独立 ffmpeg 调用、且解码的是**原文件**（app/worker.py:163-164）。
- 超时 300 s（app/worker.py:47）：转不完直接判失败保留原文件——即先烧满 300 s CPU 再放弃。
- **机理**：手机 4K/1080p 长视频在 NAS 弱 CPU 上以 fast 预设全分辨率编码，单条就可能跑满 300 s 并被 kill；期间 ffmpeg 默认按核心数开线程，与同进程的 uvicorn 抢全部 CPU，API 延迟整体抬升；队列串行意味着一条长视频堵住后面所有图片/视频的预览生成。封面再对原文件全解码一遍是纯重复劳动（完全可以从刚生成的 preview.mp4 抽帧，或在同一次 ffmpeg 里用多输出一次完成）。
- **优化建议**：
1. 分辨率封顶：`-vf scale=-2:min(1080,ih)`（或按短边 720，二人手机观看足够），转码耗时通常降 2-4 倍（推测，取决于源分辨率）。
2. 封面改从 preview.mp4 抽帧（文件更小、解码更便宜），或单次 ffmpeg 双输出。
3. 给 ffmpeg 加 `-threads 2`（按 NAS 核心数定）与/或对 media_loop 降优先级（nice），保 API 响应。
4. 超时按时长分级：先 ffprobe 取时长（见 §6 接入点），超时 = clamp(时长×系数, 60, 600)，避免注定失败的视频空烧 300 s。
- **预期收益**：单条视频转码时间与峰值 CPU 大幅下降；转码不再拖垮 API；队列吞吐提升。
- **风险/改动量**：中低。画质口径变化需机主确认（1080p 封顶对手机观看无感，但属产品决策）；poster 来源切换要验证旧视频兼容。
- **验证方法**：取一条真实 4K 样片，改前后分别计时 `process_media` 并看 `docker stats` 峰值；`ffprobe` 对比输出分辨率/码率与肉眼画质。

### P6. media 表除主键外零索引：转码认领每 2 秒全表扫，选图/选片接口全表扫 + 逐行权限查询

- **证据**：
- db.py 的全部 CREATE INDEX 只覆盖 records/comments/notices/三张投递表/webpush_subscriptions/import_messages（app/db.py:122、174-175、188、322-330），**media 表没有任何二级索引**。
- 转码认领：`SELECT * FROM media WHERE status='pending' AND attached=1 ORDER BY created LIMIT 1`（app/worker.py:104），队列空时 media_loop 每 2 s 执行一次（app/worker.py:591）→ 每 2 秒全表扫 media + 排序。
- 选图：`WHERE mime LIKE 'image/%' ORDER BY created DESC LIMIT?(limit×4)`（app/main.py:1914 附近），选片同理（app/main.py:1938 附近）——mime 前缀 LIKE + created 排序无索引，全表扫 + 排序；随后对每行（非本人上传的）调 `db.media_visible`，其内部含 json_each 全表 records 匹配等最多约 5 条查询（app/db.py:686-773），最坏情况一次打开选图面板产生数百条小查询。
- finish_media 的共享判定 `media_shared_visible` 同样是 json_each 全表扫（app/db.py:716-728），每转完一条媒体付一次。
- **机理**：media 行数 = 历史上传总量（只增不减，purge 才删）。当前量级下全表扫是毫秒级，但它以 2 秒一次的频率**永远在跑**，且随总量线性变贵；选图面板的 N+1 则是打开即感知的延迟。
- **优化建议**：
1. `CREATE INDEX media_claim ON media(status, attached, created)` 与 `CREATE INDEX media_mime_created ON media(mime, created DESC)`（走 MIGRATIONS 通道）。
2. 选图/选片：先按 owner 分流——本人的行免查；对方的行批量判定（一条 json_each 查询取回「可见媒体 id 集合」再在 Python 里过滤），把每行 5 查压成整页 1 查。
- **预期收益**：认领查询变 O(1) 索引命中；后台无谓扫描消失；选图面板查询数从 O(行数×5) 降到 O(1)。
- **风险/改动量**：低（加索引）；中低（选图批量化，需与 media_visible 语义对拍，尤其是私密记录引用判定）。
- **验证方法**：`EXPLAIN QUERY PLAN` 跑认领 SQL 与选图 SQL，确认由 SCAN 变 SEARCH；面板接口 curl 计时。

### P7. SQLite 连接与 PRAGMA：每操作新建连接、synchronous=FULL、无页缓存调优

- **证据**：`connect()` 每次 `sqlite3.connect` 新建连接，仅设 foreign_keys 与 busy_timeout=30000（app/db.py:89-103）；WAL 只在 init 设（app/db.py:111）；全仓无 synchronous/cache_size/mmap 设置（grep 无命中）。每个 API 请求至少开两个连接：鉴权 `current_user` 一个（app/security.py:186-190），端点自身一个；SSE 探针每 5 s 每连接再开一个（app/main.py:2177）。
- **机理**：WAL 下 synchronous=FULL 意味着每次提交都要 fsync WAL——在 fnOS 的存储上这是写路径延迟的主要成分之一；聊天发送一条消息要串行走多个事务（记录 INSERT + notice + outbox/deliveries 多行 + 触发器更新），fsync 次数直接决定发送耗时。cache_size 默认约 2 MiB 且连接级（冷缓存），全表类查询每次都要重新从页缓存/磁盘热身。两人规模下不是瓶颈，但这是**全局生效**的便宜优化。
- **优化建议**：在 `connect()` 里统一补 `PRAGMA synchronous=NORMAL`（WAL 下的常规推荐，断电最多丢最后若干事务、不损坏库）+ `PRAGMA cache_size=-8000`（8 MiB）。period.py 的 connect() 同步补（app/period.py:48-60 同样只有 busy_timeout）。
- **预期收益**：写事务延迟下降（fsync 从每提交一次降为 checkpoint 时）；读热路径页缓存命中提升。
- **风险/改动量**：低。synchronous=NORMAL 的取舍需机主知情（极端断电可能丢最后几条已提交记录；NAS 场景风险可控但要明示）。
- **验证方法**：微基准：脚本循环 100 次「INSERT 一条 chat 记录 + notice」计时改前后；观察 love.db-wal 文件大小与 checkpoint 行为。

### P8. 密钥材料零缓存：每次解密都读盘 secret.key + HKDF 重派生

- **证据**：`secret_key()` 每次调用都 `path.read_bytes()` 读 DATA/secret.key（app/security.py:18-27）；`cipher(purpose)` 每次做 HKDF 派生（app/security.py:42-50）；`private_record_decrypt` 每次派生私有记录密钥（app/security.py:115-125）。调用点遍布热路径：body_decode（每条私密记录每次序列化）、pose-ai 配置读写、webpush 订阅解封（app/webpush.py:83-87）、渠道配置解密（投递每条一次，app/worker.py:331）。
- **机理**：单次开销不大（文件读走 OS 页缓存，HKDF 是微秒级），但它乘在 P1/P3/P4 的全表循环里：全表里每条私密记录的每次 decode 都重复付一遍。属于「不修也不疼、修了全局受益」的纯浪费。
- **优化建议**：模块级缓存 secret 字节与各 purpose 的派生密钥（进程生命周期内不变；密钥文件轮换本来就需要重启服务）。
- **预期收益**：私密记录 decode 单条成本下降约一半（推测）；与 P1/P3 叠加收益。
- **风险/改动量**：低。注意测试环境里 secret.key 可能被重建——缓存要允许显式失效或按文件 mtime 校验。
- **验证方法**：微基准循环 1000 次 body_decode 私密记录计时；strace -c 看 read 系统调用次数变化。

### P9. 每日备份对全量媒体做 ZIP_DEFLATED：已压缩格式再压一遍，纯烧 CPU

- **证据**：`create_backup` 用 `zipfile.ZipFile(..., zipfile.ZIP_DEFLATED)` 打开后把每个媒体文件 `archive.write` 进去（app/backups.py:246 起）——zipfile 的压缩级别是包级设置，图片/视频条目同样被 deflate。备份在 worker 线程里跑且全程持 `storage_lock`（app/backups.py:225），cleanup 也抢同一把锁（app/worker.py:471），备份期间清理被阻塞。
- **机理**：JPEG/MP4/MP3 本身已是压缩格式，deflate 只能再榨出约 0-2%（推测），却要把整个媒体库（GB 级）在 NAS CPU 上过一遍 zlib，这是每日一次的最大单发 CPU 事件，时长随媒体总量线性增长。
- **优化建议**：逐条指定压缩：media 条目用 ZIP_STORED，love.db / period.db / manifest / secret.key.enc 用 ZIP_DEFLATED（zipfile 支持 `archive.write(..., compress_type=...)` 逐条覆盖）。
- **预期收益**：备份耗时从「压缩全库」降到「拷贝全库」（受磁盘 IO 封顶），通常快数倍（推测）；包体积几乎不变。
- **风险/改动量**：低。恢复侧按条目自带压缩类型解压，无兼容问题；老包照常可恢复。
- **验证方法**：手动跑一次 `python -m app.manage backup` 计时并对比包大小；`docker stats` 看备份窗口 CPU。

### P10. /media/{mid} 每次请求（含 304 校验）都付一轮可见性查询

- **证据**：端点先调 `db.media_visible`（app/main.py:1829-1832），本人媒体走 owner 快路径 1 查；对方媒体走 `media_in_visible_record`：json_each 全表 records 匹配 + settings 读取 + pose_ai_media_ids（再查 settings）+ import_messages 查询 + users 头像查询，约 4-6 条 SQL（app/db.py:686-773）。之后才构造 FileResponse 并做 ETag 条件判断（app/main.py:1855-1871）——即 304 响应也要先付全额可见性成本。中间件对 /media 的策略是 must-revalidate（app/main.py 中间件 /media/ 分支），意味着每次看图都必然回源校验。
- **机理**：聊天页一屏几十张图、相册整页上百张，每张都是「4-6 条小查询 + 一次 304 往返」。单条都便宜，但乘上图片数量和隧道往返延迟，就是相册/聊天图片加载体感的主要构成（推测）。
- **优化建议**：
1. 可见性判定进程内短缓存：以 (mid, user_id, content_revision) 为键缓存布尔结果，revision 变化即失效——判定输入只依赖记录/设置/头像，全部被 revision 覆盖（pose_ai_media 与 space 设置写入会触发 settings 触发器推 content_revision，app/db.py settings 触发器组）。
2. preview/poster 文件一旦 status='ready' 内容永不变更，可考虑对 preview 请求放宽为 `private, max-age=86400` 之类的短强缓存（原图保持 must-revalidate）——属策略变更，需机主拍板隐私/新鲜度取舍。
- **预期收益**：图片密集页的回源查询数下降一个数量级；304 往返本身保留（带宽已省），主要省服务端 CPU 与查询往返。
- **风险/改动量**：中。缓存失效键必须覆盖全部判定输入，漏一个就会出现「已撤回/已删图仍可见」的越权窗口——建议先只做 (1) 且 TTL 再兜底 60 s。
- **验证方法**：给 love.db 开 `PRAGMA` 无关——用 sqlite3 命令行无法直接数；改在 media_visible 入口加计数日志或用 py-spy 采样；前端侧对比相册页请求瀑布耗时。

### P11. 写路径上的全表扫描：改记录删附件、删相册、撤回、彻底删除

- **证据**：
- update_record：每个被移除的附件都跑一遍 `any(mid in db.body_decode(other)...)` 遍历**全部**其它记录并逐条 decode（app/main.py:1517）。
- delete album：遍历全部非私密记录 decode 找引用（app/main.py:1537 起）。
- purge 的 `_other_refs_excluding`：对每个独占候选附件做两轮全表扫（一轮明文 json.loads、一轮私密 decode）（app/main.py:1558 起）。
- recall：`SELECT 1 FROM records WHERE body LIKE '%<mid>%'` 全表 LIKE（app/main.py:1637 附近）。
- **机理**：都是低频操作，单次成本 O(全表 decode)，且都开着 BEGIN IMMEDIATE 写事务执行——扫描期间写锁被占住，其它写请求在 busy_timeout 内排队（最长等 30 s 才报错）。数据量大后，一次编辑/删除可能让对方的发送卡顿数百毫秒（推测）。
- **优化建议**：统一改用 json_each SQL 下推（`media_in_visible_record` 已是范本，app/db.py:686），把「全表 decode」换成「全表 SQL 匹配」；recall 的 LIKE 可换 json_each 精确匹配。
- **预期收益**：这些操作的耗时与锁持有时间大幅缩短；顺带消除 P1 之外又一处全表 decode 来源。
- **风险/改动量**：中低。逐个端点改，语义（song.mid、settings、头像、导入消息等旁路引用）要按 _other_refs_excluding 的现有清单对拍。
- **验证方法**：造一条带多附件的记录，改前后分别计时 PUT/DELETE 并观察并发发送一条 chat 的延迟。

### P12. /api/dashboard 多条全表聚合；/api/photos 全量 post 扫描

- **证据**：dashboard 一次调用约 9 条聚合：months 用 `strftime('%Y-%m', created, 'unixepoch')` 分组（函数包裹 created，全表扫）、moods 用 json_extract 分组（全表扫）、photos 用 json_each count DISTINCT（全表扫）、likes/comments 各一次 JOIN 统计（app/main.py:2287-2330）。photos 接口遍历全部 post 记录 json.loads 取引用（app/main.py:1878 起），媒体本体已批量化（好处在），但记录侧仍是全量。
- **机理**：都是「打开页面才调」的低频接口，单次全表扫在当前量级可接受；随总量增长会线性变慢。dashboard 与 P3 同病，可同方：revision 键控缓存一次解决。
- **优化建议**：dashboard 接入 P3 的 revision 缓存；photos 的引用收集改 json_each SQL 下推。
- **预期收益**：看板/相册页打开延迟稳定，不随总量恶化。
- **风险/改动量**：低-中。
- **验证方法**：同 P3 的 curl 计时法。

### P13. 启动期迁移的潜在 O(U×R)：未定区媒体逐条全表取证

- **证据**：启动时 `migrate_media_zones()` 对每条 zone='' 的媒体调 `media_zone_evidence`（app/db.py:600 起），而 evidence 内部把 records 全表迭代**两遍**并逐条 json 解析/decode（app/db.py:560-583）。上传接口 INSERT media 时不写 zone（app/main.py:1813，zone 默认 ''），未被任何记录引用的孤儿上传会一直保持 ''。
- **机理**：正常路径下媒体在建记录时被 mark_attached 定区，所以存量 '' 主要是孤儿；但只要攒下 U 条未定区媒体，每次容器重启就要付 U × (2 × 全表解析)。fnOS 上容器重启不罕见（更新镜像即重启），启动变慢会直接表现为「更新后半天打不开」（推测：U 与记录数都上千时进入分钟级）。
- **优化建议**：evidence 改为先把全部记录的 media 引用一次性建索引（mid → kinds），再逐条查表，O(R + U)；或给上传行直接落 zone='inbox' 语义值并让迁移跳过（media_dir 对未知 zone 本就回落 inbox，app/db.py:23-33）。
- **预期收益**：启动时间与数据量脱钩。
- **风险/改动量**：中低。迁移逻辑有对账与 manifest 机制，改动需跑现有迁移测试。
- **验证方法**：在测试库造 1000 条 '' 区媒体 + 1000 条记录，计时 lifespan 启动段日志（迁移日志已有输出，app/main.py:63-76）。

### P14. 投递链路：串行 + 每条新建 httpx.Client + 每状态一事务（可接受，记录备查）

- **证据**：deliver/deliver_pushes/deliver_webpushes 在 worker 主循环里串行执行（app/worker.py:611-613、301-460，代码注释明确说明串行是为避 SQLite 写锁的刻意取舍）；`notifications.send` 每次新建 `httpx.Client(timeout=15)`（app/notifications.py:146、153），无连接复用，每条通知付一次 TCP+TLS 握手；deliver 内层每条消息要开 3-5 次独立 connect() 做状态迁移（app/worker.py:311-360）；webpush 每次 send 现场派生 VAPID 密钥（app/webpush.py:29-40、106）。
- **机理**：两人量级下完全够用；唯一真实风险是某个渠道端点慢/超时 15 s 时，同轮后续渠道与 webpush 全部顺延——表现为「企业微信到了、浏览器推送迟到」。聊天合并窗口（15 s）与渠道 interval（默认 300 s）已把频率压住，不构成 CPU 问题。
- **优化建议**：不急。若要做：给每个渠道的 send 保持串行但把 httpx.Client 提升为模块级复用；或维持现状，仅在日志里记录单渠道耗时以便定位慢渠道。
- **预期收益**：边际（握手毫秒级 + 慢渠道隔离）。
- **风险/改动量**：低。
- **验证方法**：deliveries 表 sent_at 与 notices.created 的差值分布；日志观察单轮 deliver 总耗时。

### P15. 进程模型与资源上限（结构性备查，非缺陷）

- **证据**：uvicorn 单进程（Dockerfile:57），worker 是同进程线程（app/main.py lifespan），容器 mem_limit 2 GiB（docker-compose.yml），/tmp tmpfs 256 MiB。
- **机理**：同步端点跑在 Starlette 默认线程池（40 线程），SSE/音乐流/AI 代理是 async；SQLite 的单写者模型决定了多 uvicorn worker 只会加剧写锁竞争，单进程是正确选择。真正的结构性风险是 P5 的 ffmpeg 子进程不受进程内调度约束——它能吃满宿主全部核心与大量内存（4K 转码），与 2 GiB 上限叠加时可能触发容器 OOM（备份模块已有 2026-11-07 OOM 前科，app/backups.py:120-131 注释）。
- **优化建议**：不改进程模型；用 P5 的 `-threads` 上限 + 分辨率封顶把 ffmpeg 关进笼子；可考虑给容器加 cpu 份额下限保障 API（compose `cpus` 上限会连 API 一起限，慎用）。
- **验证方法**：转码一条大视频时 `docker stats` + 同时 curl /health 计时，观察 API 延迟劣化幅度。

---

## 4. 热点接口逐个过

### 4.1 GET /api/records（app/main.py:1236-1377）

- **查询形态**：游标分页 `(created<? OR (created=? AND id<?))` + `ORDER BY created DESC, id DESC LIMIT?`，批 500 条循环取（app/main.py:1290-1292）。默认（无 kind）排除私密 kind；带 kind 时走 kind IN。索引命中：records_deleted_created(deleted, created DESC) 支撑主排序与 deleted 过滤；records_author_kind_created 支撑 author+kind 组合（app/db.py:323-324）。
- **额外成本**：album_only 的 json_extract 条件逐行求值（app/main.py:1262）；date 的 json_extract 等值（app/main.py:1282）；q 搜索 Python 逐行（app/main.py:1300-1303）；每行 body 最多 decode 3 次（见 P4）；私密 kind（指定 kind=diary 等）时 date_in_python 全量 Python 过滤。
- **period 合并**：kinds 含 period 或未指定 kind 时，另查 period 分库 `rows_for` 并在内存合并排序（app/main.py:1330-1340）；period.rows_for 在 limit 之外还要逐行解密 + Python 过滤 date/q（app/period.py:153-190）。period 行数天然小，可接受。
- **序列化**：serialize_many 300 分批（app/serializers.py:58），关联查询数 ≈ ceil(N/300)×5 + 媒体分批——批量化做得对。
- **放大点**：搜索（P4）、limit=1000 首屏全量非聊天记录（设计如此，成本 = 1000 行 × (decode×3 + 序列化)，是 App/Web 首屏的主要服务端开销）。

### 4.2 GET /api/me（app/main.py:746-758）

- **查询**：users 全表（2 行）、settings space 一条、未读数两条 count（user_id+seen 走 notices_user_seen 索引，app/db.py:326；chat 那条多一个 event 条件，同索引前缀可用）。NTFY 关闭时跳过 ensure_push_topic（默认关，app/main.py:749）。
- **开销**：加上鉴权的会话查询（app/security.py:186），整请求约 6 条小查询、2 次建连接。App 在每次 SSE refresh 后会 reload /api/me（背景已知），频率 = 每次内容变化一次，两人场景无压力。
- **放大点**：无实质问题。若日后要抠，space 设置可随 revision 缓存。

### 4.3 GET /api/notices 与已读（app/main.py:2146-2180）

- 列表：`WHERE user_id=? ORDER BY created DESC LIMIT 200`，notices_user_created 索引精确命中（app/db.py:325）。已读标记按 record_id/event/全量三种 UPDATE，均以 user_id 开头走索引。删除已读一条 DELETE。
- **放大点**：无。通知中心是全站做得最干净的接口之一。

### 4.4 GET /api/events（SSE）（app/main.py:2245-2285）

- **连接管理**：每连接一个 async 生成器，5 s 一轮（app/main.py:2283）；每轮经 `asyncio.to_thread` 在线程池跑一次组合探针 SQL（app/main.py:2259、2177-2200），不阻塞事件循环——这点处理正确（注释自述 busy_timeout 30 s 若在事件循环里查会卡死全进程）。
- **每连接成本**：每 5 s = 1 次建连接 + 1 条组合 SQL（5 个标量子查询，revision 读 app_state/user_revisions 主键行，unread count 走 notices_user_seen）。两人 × 每人 1-3 条连接（Web + App 前台服务）≈ 每秒 1 条小查询量级，可忽略。
- **断线/重连**：`retry: 3000`（app/main.py:2249）；首轮只建基线不推 data，避免重连风暴引发整页重绘（app/main.py:2266-2272 的设计）；签名不变只发 `: heartbeat` 注释行保活。会话校验每 10 轮降频（app/main.py:2259）。无重连风暴风险。
- **放大点**：探针里的 unread count 是每次现算的 count(*)——notices 保留 90 天已读 + 全部未读，count 走索引，影响小。若连接数将来放大（不会，两人系统），可改缓存计数。

### 4.5 GET /media/{mid}（app/main.py:1827-1871）

- **链路**：鉴权 → media_visible（见 P10，1-6 条 SQL）→ 按 zone/mime/created 拼路径（app/db.py media_dir）→ FileResponse（Starlette 按 sendfile 发送，支持 Range）→ `_conditional` 补 ETag/Last-Modified 条件请求（app/main.py:1855）。
- **缓存**：中间件统一 `private, max-age=0, must-revalidate`：省带宽（304 无体）但不省往返；GZip 直通名单含 /media/（app/main.py:100），视频 Range 不受压缩破坏——这两处都对。
- **放大点**：P10 的可见性成本；以及原图无任何缩放直出（看原图即全尺寸下载，属产品行为非缺陷）。

### 4.6 搜索

- 站内记录搜索 = /api/records 的 q 参数（见 4.1 与 P4）：无全文索引，Python 子串匹配，最坏全表 decode。
- 导入记录搜索：`/api/imports/{iid}/messages` 的 q 走 `content LIKE '%...%'`（app/main.py:3153），import_id 有索引先收窄到单个导入批次，批次内 LIKE 全扫——批次可达数万条时单次搜索为该批次全扫，但频率低且范围有界，可接受。
- 在线音乐搜索：见 §2.3，内存缓存 600 s + 上游 9 s 超时，设计合理。

### 4.7 时间线聚合：dashboard / weekly / yearbook / calendar / on-this-day

- dashboard（app/main.py:2287）：约 9 条聚合、多条全表扫，见 P12。
- weekly（app/main.py:2331）：主查询用 VISIBLE_SQL + created 区间（records_deleted_created 可部分支撑），窗口内行数有界；但 streak 计算另拉「最近一年全部记录的 created」（app/main.py:2413）逐行转日期——一年行数级别，可接受；likes/comments 按 500 分块批量（好）。
- yearbook / calendar / on-this-day：见 P3，全表序列化，是本节最贵三件套。
- **共同放大点**：都未做任何缓存，而结果只随 revision 变——P3 的 revision 键控缓存可一并覆盖 dashboard。

### 4.8 其它接口（简要）

- POST /api/media 上传：同步端点在线程池里 1 MiB 分块写盘 + 图片 PIL verify / 音视频魔数嗅探（app/main.py:1781-1824）；250 MB 上限意味着一次上传可占住一个线程池线程数分钟，线程池 40 条，两人场景无碍。
- POST /api/records：单条 INSERT + clean_body 内对每个附件调 media_visible（每个附件一轮 json_each 匹配，≤30 个附件，app/main.py:1225-1232）+ notice 的 outbox/deliveries 写入（按订阅/渠道数展开，app/db.py:758 起）。单条成本可控。
- /api/photos：见 P12。/api/storage：遍历 media 表聚合 + 若干 stat，管理员低频，无碍（app/main.py:2934）。
- /api/music/stream：每请求新建 httpx.AsyncClient 中继 Apple CDN（app/main.py:2054），30 s 试听片段、响应带 max-age=86400 私有缓存，无放大。
- /api/proxy（AI 出图）：async 转发，300 s 长超时（app/main.py:498-545）——长连接占用一个 async 任务，不占线程池，正常。

---

## 5. SQL 层：高频语句与索引对照

### 5.1 现有索引清单（app/db.py）

| 索引 | 定义 | 出处 |
|---|---|---|
| records_kind | records(kind, created) | app/db.py:122 |
| records_author_kind_created | records(author, kind, created DESC) | app/db.py:323 |
| records_deleted_created | records(deleted, created DESC) | app/db.py:324 |
| comments_record_created | comments(record_id, created) | app/db.py:322 |
| notices_user_created | notices(user_id, created DESC) | app/db.py:325 |
| notices_user_seen | notices(user_id, seen) | app/db.py:326 |
| deliveries_due | deliveries(status, next_at) | app/db.py:327 |
| push_outbox_due | push_outbox(status, next_at) | app/db.py:328 |
| webpush_outbox_due | webpush_outbox(status, next_at) | app/db.py:329 |
| webpush_subscriptions_user | webpush_subscriptions(user_id) | app/db.py:330 |
| import_messages_import / _day / _media | (import_id, id) / (import_id, day) / (media_id) | app/db.py:174-175、188 |
| period_created / period_author / period_deleted | period 分库三索引 | app/period.py:39-41 |
| 唯一约束兼索引 | records UNIQUE(author, client_id)；notices.dedupe UNIQUE；likes/comments 等主键 | app/db.py 建表段 |

### 5.2 高频语句 × 索引命中判定

| 语句（场景） | 出处 | 索引情况 |
|---|---|---|
| records 列表游标查询 ORDER BY created DESC | app/main.py:1290 | records_deleted_created 支撑排序与 deleted 过滤 ✓；附加的 json_extract 条件逐行求值（P4） |
| records 按 kind 取（schedule 现状无 kind 过滤） | app/worker.py:229 | 现状全表扫 ✗（P1 修复后可走 records_kind） |
| SSE 探针 unread count | app/main.py:2196 | notices_user_seen ✓ |
| SSE 探针 revision 读取 | app/main.py:2193-2199 | app_state / user_revisions 主键 ✓ |
| notices 列表 LIMIT 200 | app/main.py:2149 | notices_user_created ✓ |
| 投递三队列 due 查询 | app/worker.py:305、368、405 | *_due(status, next_at) ✓ |
| 转码认领 media status/attached/created | app/worker.py:104 | **无索引，全表扫** ✗（P6） |
| 选图/选片 media mime+created | app/main.py:1914、1938 | **无索引，全表扫+排序** ✗（P6） |
| media 按 id 取 | 多处 | 主键 ✓ |
| media_visible 的 json_each(records.body,'$.media') | app/db.py:702 | 表达式匹配，天然全表扫（单条判定可接受，批量场景放大，P6/P10） |
| dashboard months GROUP BY strftime(created) | app/main.py:2295 | 函数包裹列，全表扫（低频，P12） |
| dashboard moods json_extract GROUP BY | app/main.py:2300 | 全表扫（低频，P12） |
| yearbook/calendar/on-this-day 全表 SELECT * | app/main.py:2490、2576、2635 | 排序/过滤全在 Python（P3） |
| cleanup 在用集合 SELECT body FROM records | app/worker.py:479 | 全表扫（P1） |
| recall 的 body LIKE '%mid%' | app/main.py:1637 附近 | 前导通配，全表扫（低频，P11） |
| import_messages 按批次分页/计数 | app/main.py:3144-3176 | import_messages_import ✓；q 的 LIKE 在批次内全扫（可接受） |
| sessions 按 token 查（每次鉴权） | app/security.py:187 | 主键 ✓ |
| auth_attempts 按 key | app/security.py:197 | 主键 ✓ |

### 5.3 缺索引/索引失效小结

1. **media 表零二级索引**是唯一的「结构性缺索引」：认领、选图、选片三处受累（P6）。
2. **函数包裹列**：json_extract(body,'$.date')、json_extract(body,'$.album_only')、strftime(created) 三处——前两处在热路径上，建议用生成列 + 索引根治（P4）；strftime 只在 dashboard，低频可缓。
3. **LIKE 前导通配**：recall 的 body LIKE 与导入搜索的 content LIKE——前者可改 json_each，后者范围有界可保留。
4. records 的高频路径索引覆盖其实良好（列表/作者/类型/回收站都有对应索引），问题不在索引而在**过滤条件下推不足**（P1/P3/P4）。

---

## 6. 媒体链路时序（一条含视频的动态：上传 → 可播放）

以「App 发一条带视频的 post」为例（Web 同理）：

1. **上传原文件**（API 进程，线程池线程，同步）：`POST /api/media`（app/main.py:1781）以 1 MiB 分块流式写盘到 `data/media/inbox/<YYYY-MM>/<mid>.mp4`（未定区落 inbox，app/db.py:23-33），同时累计大小（上限 250 MB）并做魔数嗅探；随后 INSERT media 行：status='pending'、attached=0、zone=''（app/main.py:1813）。客户端等整个文件传完才拿到 mid。
2. **建记录并定区**（API 进程，线程池，同步，BEGIN IMMEDIATE 事务）：`POST /api/records`（app/main.py:1380）→ clean_body 逐个附件调 media_visible 校验（app/main.py:1225）→ `mark_attached(zone='timeline')`：classify_media 把文件从 inbox **rename** 到 `media/timeline/video/<YYYY-MM>/` 并置 attached=1（app/db.py:743-770）→ INSERT records → notice() 写 notices + webpush_outbox + deliveries 行（app/db.py:758 起）→ `nudge_worker()` 唤醒投递。
3. **通知投递**（worker 主循环线程，异步于请求）：deliver/deliver_webpushes 在下一 tick（或被 nudge 立即唤醒）串行发出；聊天类有 15 s 合并延迟（app/db.py:431），post 走 activity 事件即时。
4. **转码认领**（worker media_loop 线程）：每 2 s 轮询，BEGIN IMMEDIATE 原子认领最老的 pending+attached 行，status→'processing'（app/worker.py:92-110）。
5. **视频转码**（media_loop 线程拉起 ffmpeg 子进程，串行）：
- 第 1 次 ffmpeg（超时 300 s，app/worker.py:47）：`ffmpeg -y -i <原文件> -map_metadata -1 -vf scale=trunc(iw/2)*2:trunc(ih/2)*2 -c:v libx264 -preset fast -crf 25 -pix_fmt yuv420p -c:a aac -movflags +faststart <mid>.preview.mp4`（app/worker.py:152-157）。
- 第 2 次 ffmpeg 抽封面（超时 120 s）：对**原文件** `-frames:v 1 -vf scale=640:-2` 生成 `<mid>.preview.jpg`（app/worker.py:163-164）；失败不影响主结果。
- 图片附件则不走 ffmpeg：同线程内 Pillow 生成 1600px/q86 预览（app/worker.py:140-143）；HEIC 失败才回退 ffmpeg 单帧。
6. **写回与推送刷新**（media_loop 线程）：finish_media UPDATE media SET status='ready', preview=…（app/worker.py:109）；若该媒体属共享可见（json_each 全表判定一次），bump_shared 推 content_revision → 双方 SSE 在 5 s 内收到 refresh → 客户端重拉记录，视频位从占位变可播。
7. **播放**（API 进程）：`GET /media/{mid}?preview=true` → media_visible 判定 → FileResponse 发 preview.mp4（Range 可用、ETag 304、private must-revalidate，app/main.py:1827-1871）。preview 不存在/转码失败时 status='original'，前端改拉原文件。
8. **媒体时长**：当前链路中**没有任何一步对上传媒体跑 ffprobe**，时长无处落库——这正是已知延期项「转码时记录媒体时长」的缺口。接入点在第 5 步：process_media 的 video/audio 分支（app/worker.py:146-168）在转码成功后（或转码前对原文件）调用 ffprobe 取 duration，随 finish_media（app/worker.py:109）一并写回 media 行——music_drop 已有现成范式 `_probe()`（app/music_drop.py:71-93，ffprobe -show_format 取 duration，30 s 超时），可直接复用；注意 media 表目前没有时长列，需走 MIGRATIONS 加列。此处仅标注接入点，不展开设计。

---

## 7. 前端 Web（简要）

- **资源体积**（仓库 static/ 实测字节数）：style.css 219,528 B；app.js 274,806 B；chat.js 77,024 B；period.js 62,092 B；music.js 14,764 B；sw.js 8,127 B。首屏 HTML（static/index.html）以 defer 方式加载全部 4 个 JS + CSS，合计约 648 KB 未压缩文本；经 SelectiveGZip（minimum_size=1024，app/main.py:105）后约 180-200 KB（推测，按常见 0.28 压缩比估）。
- **缓存策略**（做得好）：index.html 对 5 个资源统一带 `?v=299`，中间件对带 v 的静态资源回 `public, max-age=31536000, immutable`；HTML 本身 no-store、sw.js no-cache（app/main.py 中间件）；Service Worker 预缓存 CORE 全套并按版本换桶（static/sw.js），二次打开基本零网络。
- **可议点**：
1. period.js（62 KB）与 chat.js（77 KB）首屏即全量加载，与当前视图无关也要下载/解析——有 SW + 强缓存兜底，仅首次访问有感，优先级低。
2. JS/CSS 未见构建压缩痕迹（按源文件原样下发），靠 gzip 兜底；若日后要抠首屏，可加构建期 minify，收益约再降 20-30% 文本体积（推测）。
3. `static/lovespace.apk` 43,543,573 B（约 43.5 MB）随 `COPY static static` 进镜像（Dockerfile:38）——镜像体积 +43 MB，且每次发版镜像层都要带它；它同时是 /apk/download 的站内分发源（app/main.py:417-425），属有意设计，仅作体积备查。
4. /pose-gallery 是卷挂载的独立静态站（docker-compose.yml 卷 + app/main.py:3400 附近的 mount 与外壳注入），其 index.html 每次 no-store 回源并注入同步脚本——只影响图库页，不波及主站。

## 8. 镜像与部署（简要）

- **镜像构成**：python:3.13-slim + ffmpeg/tzdata（apt 层）+ pip 依赖（fastapi/uvicorn/Pillow/pillow-heif/cryptography 等，requirements.txt 共 10 项）+ app/ + static/（含 43.5 MB APK，见 §7）。无多阶段构建，但 Python 应用本身没有编译产物，slim 基础已属合理；镜像大头推测为 ffmpeg 及其依赖 + APK + Pillow/cryptography wheels（推测，未实测镜像分层大小）。
- **启动耗时构成**：uvicorn 起来前 lifespan 串行执行 db.init（含触发器重建与私密记录迁移检查）、两次媒体目录迁移（migrate_media_layout 全表 + 文件 stat；migrate_media_zones 见 P13）、period 迁库检查、music_drop 启动扫描一次（app/main.py:44-100）。稳态下都是秒级；P13 的场景是唯一的启动放大风险。
- **更新路径**：NAS 不编译、只拉 GHCR 镜像（docker-compose.yml 注释），down && up 后启动耗时即上面的 lifespan；HEALTHCHECK 60 s 间隔、start-period 30 s（Dockerfile:54），与 lifespan 的迁移耗时相加决定「更新后多久可用」。
- **资源护栏**：mem_limit 2 GiB、日志轮转 10m×3、read_only 根文件系统 + tmpfs /tmp 256 MiB（docker-compose.yml）——护栏齐全；/tmp 只有 256 MiB 值得注意：备份/导出的临时快照走 DATA/tmp 不走 /tmp（app/backups.py 用 DATA/'tmp'），不受影响；但系统级临时文件（如 ffmpeg 的临时输出若落 /tmp）需留意——当前 ffmpeg 输出直写数据卷，无此问题。

---

## 9. 快速胜利清单（≤5 条）

1. **给 media 表加两个索引**：`media(status, attached, created)` + `media(mime, created DESC)`，走 db.py 的 MIGRATIONS 通道一次 DDL——立即消灭转码认领每 2 s 的全表扫与选图/选片的全表排序（P6）。
2. **周期任务改墙钟门控 + schedule 加 kind 过滤**：worker 里把 counter%N 换成 last_run 时间戳，并给 schedule 主查询加 `kind IN ('surprise','anniversary','wish')` 走 records_kind 索引——稳态背景 CPU 最大的一刀（P1+P2）。
3. **密钥材料进程内缓存**：security.py 缓存 secret 字节与 HKDF 派生结果，去掉每次解密的读盘 + 派生（P8），全站 decode 路径一起受益，改动约十行。
4. **备份逐条压缩**：create_backup 里 media 条目改 ZIP_STORED、数据库与小文件保留 DEFLATED——每日备份从「压缩全库」变「拷贝全库」（P9）。
5. **connect() 补两个 PRAGMA**：`synchronous=NORMAL` + `cache_size=-8000`（db.py 与 period.py 各一处）——全局写延迟与读缓存一起改善（P7，需机主知情 synchronous 取舍）。

---

## 10. 文件覆盖清单（app/ 全部后端文件）

| 文件 | 与性能相关的一句话 |
|---|---|
| app/__init__.py | 空文件，与性能无关。 |
| app/main.py | 全部热点接口、SSE、缓存中间件、上传与聚合接口都在此——本报告 P3/P4/P10/P12 的主战场。 |
| app/worker.py | 周期任务节拍、转码、投递三件套——P1/P2/P5/P14 的主战场。 |
| app/db.py | 连接模式（每操作新连接）、索引与 revision 触发器、可见性判定（json_each 下推范本）——P6/P7 的根。 |
| app/period.py | 独立 SQLite（连接参数同主库问题）；rows_for 无 LIMIT 时全量解密返回（行数天然小）；cycle_stats 每次全量解密 period 行（worker 每周期调用，量级小）。 |
| app/serializers.py | serialize_many 300 分批批量关联是正确范式；但与调用方之间 body 重复 decode（P4）。 |
| app/security.py | 每请求一次会话查询（主键，便宜）；secret_key 每次调用读盘 + HKDF 重派生（P8）；scrypt(16384,8,1) 与 PBKDF2 600k 只在登录/解锁时触发，非热点。 |
| app/notifications.py | send() 每条新建 httpx.Client、15 s 超时、同步阻塞 worker 投递轮（P14）；DNS 判定有 600 s 缓存（好）。 |
| app/webpush.py | 每次 send 现场 HKDF + EC 派生 VAPID 密钥并读 secret 文件（P8/P14 同源问题）；pywebpush 超时 10 s。 |
| app/backups.py | 每日全量 DEFLATED 备份（P9）；user_export 用非批量 serialize 逐条查（N+1），有 export 限流兜底，可接受。 |
| app/music_drop.py | 5 分钟一轮扫描；魔数不过的文件每轮重复全文件 sha256（小浪费）；ffprobe 每文件 30 s 超时、串行——投放高峰会排队，但非稳态热点。 |
| app/importers.py | 纯解析模块，只在导入请求内运行（整文件读入内存 + 逐行解析），有 50 MB 上限与限流，非常驻热点。 |
| app/markdown_export.py | 导出时全表 SELECT + 全量内存渲染组装（app/markdown_export.py:248），与 user_export 同级，限流兜底。 |
| app/config.py | 导入期扫 static/*.apk（43 MB）zip 读版本号（app/config.py:56-76）——只读 zip 目录区与一个小条目，启动一次性小成本。 |
| app/manage.py | 备份/恢复 CLI 包装，与运行时性能无关。 |

---

## 附：阅读范围说明

- 后端 `app/` 共 15 个.py 文件已全部扫读，main.py（3451 行）、worker.py（632 行）、db.py（773 行）逐段细读。
- 前端仅核了 static/ 目录清单、index.html、sw.js 与中间件缓存策略，未逐行审 app.js/chat.js/period.js 的运行时逻辑（本任务以服务端资源为主）。
- Flutter App 端不在本次范围。
- 本报告所有「推测」均已标注；其余结论均有源码行号支撑。未修改仓库任何文件。
