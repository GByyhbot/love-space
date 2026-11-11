# API 样本索引（阶段 0）

- ORIGIN：`http://127.0.0.1:8353`（本地测试环境，全新 DATA_DIR）
- 账号：e2e1（管理员）/ e2e2；密码与冒烟一致

| 分组 | 文件 |
|---|---|
| 公开端点与鉴权语义 | 01-public-auth.md |
| 账号与空间 | 02-account.md |
| records 17 kind | 03-records.md |
| 媒体两段式 | 04-media.md |
| 实时与聚合 | 05-realtime-aggregate.md |
| 通知与渠道 | 06-notices.md |
| 附属与数据 | 07-attached-data.md |

错误语义样例（401/403/422/409/304/幂等）分布在各组内，均为真实响应。