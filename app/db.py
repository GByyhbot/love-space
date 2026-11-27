import contextlib
import datetime as dt
import json
import os
import secrets
import sqlite3
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = Path(os.environ.get('DATA_DIR', ROOT / 'data')).resolve()


def uid():
    return uuid.uuid4().hex


# ── 媒体库隔离（2.4.11）────────────────────────────────────────────
# 顶层按来源分区（zone），里层保留类型/月份。六个 zone 逐字来自主人定版目录树。
ZONES = ('chat', 'timeline', 'music', 'private', 'space', 'inbox')
# 三个「按类型再分目录」的区：音频子目录统一叫 voice（不再用 audio）。
TYPED_ZONES = ('chat', 'timeline', 'private')


def media_dir(zone, mime, created):
    """媒体物理路径**唯一事实源**：data/media/<zone>/[type/]<YYYY-MM>。

    zone 为空（未归类/上传残留）落 inbox；zone 逐字来自 ZONES，未知值一律
    回落 inbox（宁可放临时区，也不写到可能不属于它的分区）。
    旧签名 media_dir(mime, created) 的两参数调用形态必须为零——护栏测试钉死。
    """
    z = zone if zone in ZONES else 'inbox'
    month = dt.datetime.fromtimestamp(created, dt.timezone.utc).strftime('%Y-%m')
    folder = DATA / 'media' / z
    if z in TYPED_ZONES:
        kind = 'image' if mime.startswith('image/') else ('video' if mime.startswith('video/') else 'voice')
        return folder / kind / month
    return folder / month


def media_dir_legacy(mime, created):
    """旧布局路径（media/<image|video|audio>/<YYYY-MM>），只供存量迁移找源。"""
    kind = 'image' if mime.startswith('image/') else ('video' if mime.startswith('video/') else 'audio')
    month = dt.datetime.fromtimestamp(created, dt.timezone.utc).strftime('%Y-%m')
    return DATA / 'media' / kind / month


def media_month(created):
    return dt.datetime.fromtimestamp(created, dt.timezone.utc).strftime('%Y-%m')


def legacy_media_paths(row, name):
    """一个文件在旧布局里可能的落点（现行类型/月 + 更早的平铺根）。"""
    folder = media_dir_legacy(row['mime'], row['created'])
    return (folder / name, DATA / 'media' / name)


def migrate_media_layout():
    """旧版本把所有媒体平铺在 media/ 根目录；启动时按类型与月份归位。

    2.4.11 起本函数只做「平铺根 → 旧类型/月」这一段；zone 归类由
    migrate_media_zones() 在其后接手（main.py 启动顺序）。
    """
    moved = 0
    with connect() as c:
        rows = c.execute('SELECT id,ext,preview,mime,created FROM media').fetchall()
    for r in rows:
        folder = media_dir_legacy(r['mime'], r['created'])
        for name in (r['id'] + r['ext'], r['preview']):
            if not name:
                continue
            src, dst = DATA / 'media' / name, folder / name
            if src.is_file() and not dst.exists():
                folder.mkdir(parents=True, exist_ok=True)
                src.rename(dst)
                moved += 1
    return moved


def now():
    return time.time()


# 🔴 peer 时间戳单位口径（轨迹时间戳单位修复令）：peer 全系时间列一律 **unix 秒**。
# 定位管线（App 端 PeerLocNative）自始以**毫秒**上报 points[].ts，读侧按秒切日 →
# `/api/peer/track` 恒空。阈值 1e11：作秒是公元 5138 年、作毫秒是 1973 年，
# 两种单位在真实数据里不会跨过它，故 `> 1e11` 即可无歧义判为毫秒。
# 写侧归一 / 存量迁移 / 读侧兜底三处共用这一个函数，**不许以后顺手删**。
TS_MS_THRESHOLD = 1e11


def ts_to_sec(value):
    """把可能是毫秒的 unix 时间戳归一为秒（秒级输入原样返回，不会被二次除）。"""
    v = float(value)
    return v / 1000.0 if v > TS_MS_THRESHOLD else v


def dumps(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


@contextlib.contextmanager
def connect():
    conn = sqlite3.connect(DATA / 'love.db', timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute('PRAGMA foreign_keys=ON')
    # 2.6.0 P7（主人裁定）：WAL 配套 synchronous=NORMAL——写吞吐显著提升；
    # 崩溃一致性取舍：断电最坏丢最后一个已提交事务（WAL 仍在，库不损坏）。
    conn.execute('PRAGMA synchronous=NORMAL')
    # timeout=30 在驱动层已经等价于这条，但它是隐式契约——将来有人调小 timeout
    # 参数，写并发就会从"等待"退化成"立刻 SQLITE_BUSY"。显式写死，别让人猜。
    conn.execute('PRAGMA busy_timeout=30000')
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def init():
    for folder in ('media', 'backups', 'tmp'):
        (DATA / folder).mkdir(parents=True, exist_ok=True)
    with connect() as c:
        c.execute('PRAGMA journal_mode=WAL')
        c.executescript('''
        CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY, username TEXT UNIQUE NOT NULL,
          name TEXT NOT NULL, password TEXT NOT NULL, admin INTEGER NOT NULL DEFAULT 0,
          avatar TEXT NOT NULL DEFAULT '', created REAL NOT NULL,
          bubble_skin TEXT NOT NULL DEFAULT '', bubble_fg TEXT NOT NULL DEFAULT '', bubble_swap INTEGER);        CREATE TABLE IF NOT EXISTS sessions(token TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), expires REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS invites(token TEXT PRIMARY KEY, expires REAL NOT NULL, used INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, kind TEXT NOT NULL, author TEXT NOT NULL REFERENCES users(id),
          body TEXT NOT NULL, created REAL NOT NULL, updated REAL NOT NULL, deleted REAL, published REAL,
          client_id TEXT, UNIQUE(author, client_id));
        CREATE INDEX IF NOT EXISTS records_kind ON records(kind, created);
        CREATE TABLE IF NOT EXISTS media(id TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES users(id),
          name TEXT NOT NULL, mime TEXT NOT NULL, size INTEGER NOT NULL, ext TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending', preview TEXT, error TEXT, created REAL NOT NULL,
          attached INTEGER NOT NULL DEFAULT 0, zone TEXT NOT NULL DEFAULT '',
          duration REAL,  -- 2.6.0 P5：转码时长（秒，REAL 可空；存量行保持 NULL，前端/API 容错）
          transcript TEXT);  -- 2.7.0 ASR：转写缓存（media_id 路径成功后落库，可空）
        -- 2.6.0 性能段 P6：media 此前除主键外零索引——转码认领（worker 每 2s
        -- 全表扫+排序）与选图/选片（mime 前缀 LIKE + created 排序）全靠 SCAN。
        -- 幂等 DDL 放基线块（与 records_kind 同款）：新库建表即带，存量库启动即补。
        CREATE INDEX IF NOT EXISTS media_claim ON media(status, attached, created);
        CREATE INDEX IF NOT EXISTS media_mime_created ON media(mime COLLATE NOCASE, created DESC);
        CREATE TABLE IF NOT EXISTS likes(record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
          user_id TEXT NOT NULL REFERENCES users(id), PRIMARY KEY(record_id,user_id));
        CREATE TABLE IF NOT EXISTS comments(id TEXT PRIMARY KEY, record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
          author TEXT NOT NULL REFERENCES users(id), content TEXT NOT NULL, created REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS answers(record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
          author TEXT NOT NULL REFERENCES users(id), content TEXT NOT NULL, PRIMARY KEY(record_id,author));
        CREATE TABLE IF NOT EXISTS checks(record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
          author TEXT NOT NULL REFERENCES users(id), day TEXT NOT NULL, PRIMARY KEY(record_id,author,day));
        CREATE TABLE IF NOT EXISTS notices(id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
          event TEXT NOT NULL, title TEXT NOT NULL, record_id TEXT, created REAL NOT NULL, seen INTEGER NOT NULL DEFAULT 0,
          dedupe TEXT UNIQUE);
        CREATE TABLE IF NOT EXISTS push_topics(user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
          topic TEXT UNIQUE NOT NULL, created REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS push_outbox(id TEXT PRIMARY KEY, notice_id TEXT NOT NULL UNIQUE REFERENCES notices(id) ON DELETE CASCADE,
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, topic TEXT NOT NULL, title TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0, next_at REAL NOT NULL,
          sent_at REAL, error TEXT);
        CREATE TABLE IF NOT EXISTS webpush_subscriptions(id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          endpoint_hash TEXT NOT NULL UNIQUE, payload TEXT NOT NULL,
          created REAL NOT NULL, updated REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS webpush_outbox(id TEXT PRIMARY KEY,
          notice_id TEXT NOT NULL REFERENCES notices(id) ON DELETE CASCADE,
          subscription_id TEXT NOT NULL REFERENCES webpush_subscriptions(id) ON DELETE CASCADE,
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
          next_at REAL NOT NULL, sent_at REAL, error TEXT,
          UNIQUE(notice_id,subscription_id));
        CREATE TABLE IF NOT EXISTS channels(id TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES users(id),
          kind TEXT NOT NULL, name TEXT NOT NULL, config TEXT NOT NULL, events TEXT NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1, quiet_start INTEGER NOT NULL DEFAULT 22,
          quiet_end INTEGER NOT NULL DEFAULT 8, interval INTEGER NOT NULL DEFAULT 300);
        CREATE TABLE IF NOT EXISTS deliveries(id TEXT PRIMARY KEY, notice_id TEXT NOT NULL REFERENCES notices(id) ON DELETE CASCADE,
          channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE, status TEXT NOT NULL DEFAULT 'pending',
          attempts INTEGER NOT NULL DEFAULT 0, next_at REAL NOT NULL, sent_at REAL, error TEXT,
          UNIQUE(notice_id, channel_id));
        CREATE TABLE IF NOT EXISTS auth_attempts(key TEXT PRIMARY KEY, count INTEGER NOT NULL, start REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS app_state(key TEXT PRIMARY KEY, value INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS user_revisions(user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
          value INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS imports(id TEXT PRIMARY KEY, platform TEXT NOT NULL, title TEXT NOT NULL,
          author TEXT NOT NULL REFERENCES users(id), participants TEXT NOT NULL DEFAULT '[]', me TEXT NOT NULL DEFAULT '',
          message_count INTEGER NOT NULL DEFAULT 0, start_at REAL, end_at REAL, created REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS import_messages(id INTEGER PRIMARY KEY AUTOINCREMENT,
          import_id TEXT NOT NULL REFERENCES imports(id) ON DELETE CASCADE,
          sender TEXT NOT NULL, content TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'text',
          sent_at REAL, day TEXT NOT NULL DEFAULT '', mine INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS import_messages_import ON import_messages(import_id, id);
        CREATE INDEX IF NOT EXISTS import_messages_day ON import_messages(import_id, day);

        -- ── 2.8.0 定位守护（docs/location-guard-plan.md 拍板定案）──────
        -- 独立小表不动既有契约；轨迹/事件 15 天滚动删除（worker maintenance）。
        CREATE TABLE IF NOT EXISTS peer_location_latest(
          user TEXT PRIMARY KEY REFERENCES users(id),
          lat REAL NOT NULL, lng REAL NOT NULL, acc REAL, speed REAL,
          battery INTEGER, charging INTEGER, net TEXT, wifi TEXT,
          updated REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS peer_location_points(
          id TEXT PRIMARY KEY,
          user TEXT NOT NULL REFERENCES users(id),
          ts REAL NOT NULL, lat REAL NOT NULL, lng REAL NOT NULL,
          acc REAL, speed REAL, backfill INTEGER NOT NULL DEFAULT 0,
          created REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS peer_points_user_ts
          ON peer_location_points(user, ts DESC, created);
        CREATE TABLE IF NOT EXISTS peer_places(
          id TEXT PRIMARY KEY, name TEXT NOT NULL,
          lat REAL NOT NULL, lng REAL NOT NULL, radius REAL NOT NULL DEFAULT 150,
          created REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS peer_events(
          id TEXT PRIMARY KEY,
          user TEXT NOT NULL REFERENCES users(id),
          type TEXT NOT NULL, ts REAL NOT NULL, summary TEXT NOT NULL,
          pushed INTEGER NOT NULL DEFAULT 0, created REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS peer_events_user_ts
          ON peer_events(user, ts DESC, created);
        CREATE TABLE IF NOT EXISTS peer_usage_daily(
          user TEXT NOT NULL REFERENCES users(id),
          day TEXT NOT NULL,
          screen_sec INTEGER NOT NULL DEFAULT 0,
          unlocks INTEGER NOT NULL DEFAULT 0,
          top_apps TEXT NOT NULL DEFAULT '[]',
          updated REAL NOT NULL,
          PRIMARY KEY(user, day));
        -- 2.8.7 全量施工令：策略变更审计（只读不可删，双方可见）
        CREATE TABLE IF NOT EXISTS peer_policy_audit(
          id TEXT PRIMARY KEY,
          user TEXT NOT NULL REFERENCES users(id),
          ts REAL NOT NULL,
          action TEXT NOT NULL,
          detail TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS peer_policy_audit_ts
          ON peer_policy_audit(ts DESC);
        ''')
        c.execute("INSERT OR IGNORE INTO app_state(key,value) VALUES ('content_revision',0)")
        # 刷新的颗粒度：内容变了不等于"整站都变了"。
        # chat_revision 只统计 kind='chat'，other_revision 统计聊天以外的共享记录。
        # 对方每发一条消息都要触发一轮刷新，而聊天占全部记录的 88%——不分开的话，
        # 每来一句话客户端都要重拉 1000 条非聊天记录 + 整本相册。
        # content_revision 的语义保持不变（仍然涵盖一切），老客户端继续按整站刷新。
        c.execute("INSERT OR IGNORE INTO app_state(key,value) VALUES ('chat_revision',0)")
        c.execute("INSERT OR IGNORE INTO app_state(key,value) VALUES ('other_revision',0)")
        # 2.8.0 定位守护：peer 状态版本号（位置/报备更新时 bump，驱动 SSE 第 7 段
        # peer 事件——不 bump content_revision，客户端只刷地图标记不整站刷新）。
        c.execute("INSERT OR IGNORE INTO app_state(key,value) VALUES ('peer_revision',0)")
        # Additive columns must exist before triggers reference them.
        if 'media_id' not in {r[1] for r in c.execute('PRAGMA table_info(import_messages)')}:
            c.execute("ALTER TABLE import_messages ADD COLUMN media_id TEXT NOT NULL DEFAULT ''")
        c.execute('CREATE INDEX IF NOT EXISTS import_messages_media ON import_messages(media_id)')
        if 'attached' not in {r[1] for r in c.execute('PRAGMA table_info(media)')}:
            c.execute('ALTER TABLE media ADD COLUMN attached INTEGER NOT NULL DEFAULT 0')
        # 2.4.11 媒体库隔离：存量库幂等加 zone（'' = 未归类，启动迁移会给它们定区）
        if 'zone' not in {r[1] for r in c.execute('PRAGMA table_info(media)')}:
            c.execute("ALTER TABLE media ADD COLUMN zone TEXT NOT NULL DEFAULT ''")
        # 2.4.6 气泡各发各的：users 侧按人三键（skin/fg/swap）。存量库幂等 ALTER，
        # 与上面 media 的两列同一惯例；bubble_swap 不给 NOT NULL —— NULL = 未设置，
        # 渲染回退空间级 chat_bubble_swap。
        _users_cols = {r[1] for r in c.execute('PRAGMA table_info(users)')}
        if 'bubble_skin' not in _users_cols:
            c.execute("ALTER TABLE users ADD COLUMN bubble_skin TEXT NOT NULL DEFAULT ''")
        if 'bubble_fg' not in _users_cols:
            c.execute("ALTER TABLE users ADD COLUMN bubble_fg TEXT NOT NULL DEFAULT ''")
        if 'bubble_swap' not in _users_cols:
            c.execute('ALTER TABLE users ADD COLUMN bubble_swap INTEGER')
        # 2.8.x 情侣主动报备：peer_events 存量库幂等加列（与 users/media 同惯例）
        # ack_at 不给 NOT NULL — NULL 表示对方尚未回应
        _peer_event_cols = {r[1] for r in c.execute('PRAGMA table_info(peer_events)')}
        if 'source' not in _peer_event_cols:
            c.execute("ALTER TABLE peer_events ADD COLUMN source TEXT NOT NULL DEFAULT 'auto'")
        if 'scene' not in _peer_event_cols:
            c.execute("ALTER TABLE peer_events ADD COLUMN scene TEXT NOT NULL DEFAULT ''")
        if 'note' not in _peer_event_cols:
            c.execute("ALTER TABLE peer_events ADD COLUMN note TEXT NOT NULL DEFAULT ''")
        if 'place_name' not in _peer_event_cols:
            c.execute("ALTER TABLE peer_events ADD COLUMN place_name TEXT NOT NULL DEFAULT ''")
        if 'client_id' not in _peer_event_cols:
            c.execute("ALTER TABLE peer_events ADD COLUMN client_id TEXT NOT NULL DEFAULT ''")
        if 'ack_by' not in _peer_event_cols:
            c.execute("ALTER TABLE peer_events ADD COLUMN ack_by TEXT NOT NULL DEFAULT ''")
        if 'ack_emoji' not in _peer_event_cols:
            c.execute("ALTER TABLE peer_events ADD COLUMN ack_emoji TEXT NOT NULL DEFAULT ''")
        if 'ack_at' not in _peer_event_cols:
            c.execute('ALTER TABLE peer_events ADD COLUMN ack_at REAL')
        # 2.8.7 自动报备：设备状态事件的结构化载荷（JSON 字符串，空串=无）
        if 'payload' not in _peer_event_cols:
            c.execute("ALTER TABLE peer_events ADD COLUMN payload TEXT NOT NULL DEFAULT ''")

        # 2.8.7：状态事件顺手刷新的时间戳（与定位的 updated 分开记——
        # 定位停了但状态在动时，客户端才知道「状态还是新鲜的」）
        _latest_cols = {r[1] for r in c.execute('PRAGMA table_info(peer_location_latest)')}
        if 'state_updated' not in _latest_cols:
            c.execute('ALTER TABLE peer_location_latest ADD COLUMN state_updated REAL')
        if 'place_name' not in _latest_cols:
            c.execute("ALTER TABLE peer_location_latest ADD COLUMN place_name TEXT NOT NULL DEFAULT ''")

        # 仅对携带 client_id 的手动报备做幂等防重（弱网重试不重复入流）
        c.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS peer_events_user_client "
            "ON peer_events(user, client_id) WHERE client_id<>''"
        )
        # Public changes share one O(1) revision. Private records, uploaded
        # unshared media and imported logs advance only their owner's revision.
        for table in ('records', 'media', 'likes', 'comments', 'answers', 'checks', 'notices', 'imports', 'import_messages', 'settings', 'users'):
            for operation in ('INSERT', 'UPDATE', 'DELETE'):
                c.execute(f'DROP TRIGGER IF EXISTS revision_{table}_{operation.lower()}')
        # 上面那层循环只按「表名_操作」命名匹配，而 media 的两个触发器带 _shared/_private
        # 后缀，匹配不到 —— 不做这一步，已删除的共享触发器会永远留在存量库里继续全表扫描。
        # 这条删的是「每次 UPDATE media 都要扫一遍 records + json_each」的性能炸弹。
        c.execute('DROP TRIGGER IF EXISTS revision_media_update_shared')
        c.execute('DROP TRIGGER IF EXISTS revision_import_messages_insert')
        c.execute('DROP TRIGGER IF EXISTS revision_import_messages_update')
        c.execute('DROP TRIGGER IF EXISTS revision_import_messages_delete')
        c.executescript('''
        CREATE TRIGGER IF NOT EXISTS revision_records_insert_shared AFTER INSERT ON records
          WHEN NEW.kind NOT IN ('diary','draft','surprise')
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_records_insert_private AFTER INSERT ON records
          WHEN NEW.kind IN ('diary','draft','surprise')
          BEGIN INSERT INTO user_revisions(user_id,value) VALUES (NEW.author,1)
            ON CONFLICT(user_id) DO UPDATE SET value=value+1; END;
        CREATE TRIGGER IF NOT EXISTS revision_records_update_shared AFTER UPDATE ON records
          WHEN OLD.kind NOT IN ('diary','draft','surprise') OR NEW.kind NOT IN ('diary','draft','surprise')
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_records_update_private AFTER UPDATE ON records
          WHEN OLD.kind IN ('diary','draft','surprise') OR NEW.kind IN ('diary','draft','surprise')
          BEGIN INSERT INTO user_revisions(user_id,value) VALUES (NEW.author,1)
            ON CONFLICT(user_id) DO UPDATE SET value=value+1; END;
        CREATE TRIGGER IF NOT EXISTS revision_records_delete_shared AFTER DELETE ON records
          WHEN OLD.kind NOT IN ('diary','draft','surprise')
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_records_delete_private AFTER DELETE ON records
          WHEN OLD.kind IN ('diary','draft','surprise')
          BEGIN INSERT INTO user_revisions(user_id,value) VALUES (OLD.author,1)
            ON CONFLICT(user_id) DO UPDATE SET value=value+1; END;
        -- 颗粒度拆分：聊天单独计数。这几条只加在 records 上（聊天就是 records 的一种），
        -- 每次写入只多一次 O(1) 的 app_state 自增，代价可以忽略。
        -- 私密类型（diary/draft/surprise）不算 other：它们走 user_revisions，对另一半不可见。
        CREATE TRIGGER IF NOT EXISTS revision_records_chat_insert AFTER INSERT ON records
          WHEN NEW.kind='chat'
          BEGIN UPDATE app_state SET value=value+1 WHERE key='chat_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_records_chat_update AFTER UPDATE ON records
          WHEN NEW.kind='chat' OR OLD.kind='chat'
          BEGIN UPDATE app_state SET value=value+1 WHERE key='chat_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_records_chat_delete AFTER DELETE ON records
          WHEN OLD.kind='chat'
          BEGIN UPDATE app_state SET value=value+1 WHERE key='chat_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_records_other_insert AFTER INSERT ON records
          WHEN NEW.kind NOT IN ('chat','diary','draft','surprise')
          BEGIN UPDATE app_state SET value=value+1 WHERE key='other_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_records_other_update AFTER UPDATE ON records
          WHEN (NEW.kind NOT IN ('chat','diary','draft','surprise'))
            OR (OLD.kind NOT IN ('chat','diary','draft','surprise'))
          BEGIN UPDATE app_state SET value=value+1 WHERE key='other_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_records_other_delete AFTER DELETE ON records
          WHEN OLD.kind NOT IN ('chat','diary','draft','surprise')
          BEGIN UPDATE app_state SET value=value+1 WHERE key='other_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_media_insert_private AFTER INSERT ON media
          BEGIN INSERT INTO user_revisions(user_id,value) VALUES (NEW.owner,1)
            ON CONFLICT(user_id) DO UPDATE SET value=value+1; END;
        CREATE TRIGGER IF NOT EXISTS revision_media_update_private AFTER UPDATE ON media
          BEGIN INSERT INTO user_revisions(user_id,value) VALUES (NEW.owner,1)
            ON CONFLICT(user_id) DO UPDATE SET value=value+1; END;
        -- 这里原本还有一条 AFTER UPDATE ON media 的共享 revision 触发器，已删除：
        -- 它的 WHEN 子句要对 records 全表做 json_each 展开，而 worker 每转完一个附件
        -- 就 UPDATE media SET status='ready'，等于每张图/每个视频都扫一遍全库记录，
        -- 还会拉长写锁持有时间。而它补的那次 bump 其实是重复劳动——记录自身的
        -- INSERT/UPDATE 触发器已经推进过共享 revision 了。改由 mark_attached() 显式负责。
        CREATE TRIGGER IF NOT EXISTS revision_media_delete_private AFTER DELETE ON media
          BEGIN INSERT INTO user_revisions(user_id,value) VALUES (OLD.owner,1)
            ON CONFLICT(user_id) DO UPDATE SET value=value+1; END;
        CREATE TRIGGER IF NOT EXISTS revision_likes_insert AFTER INSERT ON likes
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_likes_delete AFTER DELETE ON likes
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_comments_insert AFTER INSERT ON comments
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_comments_update AFTER UPDATE ON comments
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_comments_delete AFTER DELETE ON comments
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_answers_insert AFTER INSERT ON answers
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_answers_update AFTER UPDATE ON answers
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_answers_delete AFTER DELETE ON answers
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_checks_insert AFTER INSERT ON checks
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_checks_delete AFTER DELETE ON checks
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        -- settings 是张杂项表（space 背景、last_backup 备份时间等），任何一处改动
        -- 都算"整站数据变了"，推进 content_revision。
        -- 先 DROP 再建：老库里的这三条触发器带着 WHEN NEW.key <> 'watch' 的条件，
        -- IF NOT EXISTS 不会覆盖它们，只能显式重建。
        DROP TRIGGER IF EXISTS revision_settings_insert;
        DROP TRIGGER IF EXISTS revision_settings_update;
        DROP TRIGGER IF EXISTS revision_settings_delete;
        CREATE TRIGGER revision_settings_insert AFTER INSERT ON settings
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER revision_settings_update AFTER UPDATE ON settings
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER revision_settings_delete AFTER DELETE ON settings
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_users_insert AFTER INSERT ON users
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_users_update AFTER UPDATE ON users
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_users_delete AFTER DELETE ON users
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        -- 聊天记录是两人共享的（谁都能看、谁都能删），所以变化推给共享 revision，
        -- 而不是只推给导入者。否则另一方要手动刷新页面才看得到新导入的记录。
        CREATE TRIGGER IF NOT EXISTS revision_imports_insert AFTER INSERT ON imports
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_imports_update AFTER UPDATE ON imports
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_imports_delete AFTER DELETE ON imports
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        ''')
        c.execute('CREATE INDEX IF NOT EXISTS comments_record_created ON comments(record_id,created)')
        c.execute('CREATE INDEX IF NOT EXISTS records_author_kind_created ON records(author,kind,created DESC)')
        c.execute('CREATE INDEX IF NOT EXISTS records_deleted_created ON records(deleted,created DESC)')
        c.execute('CREATE INDEX IF NOT EXISTS notices_user_created ON notices(user_id,created DESC)')
        c.execute('CREATE INDEX IF NOT EXISTS notices_user_seen ON notices(user_id,seen)')
        c.execute('CREATE INDEX IF NOT EXISTS deliveries_due ON deliveries(status,next_at)')
        c.execute('CREATE INDEX IF NOT EXISTS push_outbox_due ON push_outbox(status,next_at)')
        c.execute('CREATE INDEX IF NOT EXISTS webpush_outbox_due ON webpush_outbox(status,next_at)')
        c.execute('CREATE INDEX IF NOT EXISTS webpush_subscriptions_user ON webpush_subscriptions(user_id)')
        # Remove obsolete Firebase device tokens and delivery queue from upgraded databases.
        c.execute('DROP TABLE IF EXISTS fcm_outbox')
        c.execute('DROP TABLE IF EXISTS fcm_devices')
        # 旧库迁移（media_id / attached）已在上面按 PRAGMA 检查后补齐，这里不再重复。
        defaults = {'space': {'name': '我们的恋爱空间', 'since': '', 'cover': '', 'theme': 'rose',
                             'motion': True, 'timezone': 'Asia/Shanghai',
                             # 聊天壁纸：预设键 / 用照片时的媒体 id / 遮罩强度（百分比）
                             'chat_bg': '', 'chat_bg_media': '', 'chat_bg_dim': 35}, 'schema_version': 1}
        for key, value in defaults.items():
            c.execute('INSERT OR IGNORE INTO settings VALUES (?,?)', (key, dumps(value)))
        # The former shared topic let both accounts receive the same transport
        # event. Per-account topics are now stored in push_topics.
        c.execute("DELETE FROM settings WHERE key='ntfy_topic'")
        # One-time migration: encrypt existing diary, draft and unpublished
        # surprise JSON bodies; shared records remain searchable JSON.
        for row in c.execute("SELECT id,kind,body FROM records WHERE kind IN ('diary','draft','surprise')").fetchall():
            stored = json.loads(row['body'])
            if '_private_record' not in stored:
                c.execute('UPDATE records SET body=? WHERE id=?',
                          (body_encode(row['kind'], row['id'], stored), row['id']))
        # 基线 schema 视为版本 1；以后的非幂等结构变更登记到 MIGRATIONS 里按版本执行。
        apply_migrations(c)


def setting(c, key, default=None):
    row = c.execute('SELECT value FROM settings WHERE key=?', (key,)).fetchone()
    return json.loads(row['value']) if row else default


def set_setting(c, key, value):
    c.execute('INSERT INTO settings VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value', (key, dumps(value)))


# ── 版本化迁移 ──────────────────────────────────────────────────────────
# 基线 schema（上面的 CREATE TABLE IF NOT EXISTS + 幂等 ALTER）视为版本 1。
# 以后凡是「CREATE IF NOT EXISTS 无法自动完成」的变更（改列、搬数据、重建索引），
# 在这里登记一个新版本，并保证迁移函数幂等；按版本号递增执行，成功后抬 schema_version。
# 例：MIGRATIONS[2] = ('给 records 加 pinned 列', lambda c: c.execute('ALTER TABLE records ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0'))
MIGRATIONS = {
    # 2.6.0 P5：media 时长列（存量库补列；新库由基线 schema 直建，故迁移必须幂等）
    2: ('media 加 duration 列（转码时长秒，可空）',
        lambda c: None if 'duration' in {r[1] for r in c.execute('PRAGMA table_info(media)')}
        else c.execute('ALTER TABLE media ADD COLUMN duration REAL')),
    # 2.7.0 ASR：语音转文字缓存列（media_id 路径转写成功后落缓存，可空）
    3: ('media 加 transcript 列（ASR 转写缓存，可空）',
        lambda c: None if 'transcript' in {r[1] for r in c.execute('PRAGMA table_info(media)')}
        else c.execute('ALTER TABLE media ADD COLUMN transcript TEXT')),
    # 轨迹时间戳单位修复令：peer 轨迹点 ts 毫秒 → 秒（先备份原行，幂等，秒级数据不动）
    4: ('peer_location_points.ts 毫秒归一为秒（含 latest.updated/state_updated 兜底）',
        lambda c: migrate_peer_ts_to_sec(c)),
}


PEER_TS_BACKUP_TABLE = 'peer_location_points_ms_backup'


def migrate_peer_ts_to_sec(c):
    """存量 peer 时间戳毫秒 → 秒。返回 {'points': n, 'latest_updated': n, 'latest_state_updated': n}。

    · 只动 `> TS_MS_THRESHOLD` 的行：秒级数据零误伤；跑完再跑一次影响 0 行（幂等）。
    · 动之前把待改的原行整行拷进 `peer_location_points_ms_backup`（按 id 去重），
      备份行随轨迹保留期一起滚动删除（peer.cleanup_expired），不永久留存位置数据。
    · 条数写进 app_state `peer_ts_ms_migrated`，部署回执据此对账。
    · peer_events.ts / peer_usage_daily.updated 本来就是秒，**不在本迁移范围内**。
    """
    t = TS_MS_THRESHOLD
    n_points = c.execute('SELECT count(*) FROM peer_location_points WHERE ts>?', (t,)).fetchone()[0]
    if n_points:
        c.execute(f'CREATE TABLE IF NOT EXISTS {PEER_TS_BACKUP_TABLE}('
                  'id TEXT PRIMARY KEY, user TEXT NOT NULL, ts REAL NOT NULL,'
                  'lat REAL NOT NULL, lng REAL NOT NULL, acc REAL, speed REAL,'
                  'backfill INTEGER NOT NULL DEFAULT 0, created REAL NOT NULL,'
                  'backed_up REAL NOT NULL)')
        c.execute(f'INSERT OR IGNORE INTO {PEER_TS_BACKUP_TABLE}'
                  '(id,user,ts,lat,lng,acc,speed,backfill,created,backed_up) '
                  'SELECT id,user,ts,lat,lng,acc,speed,backfill,created,? '
                  'FROM peer_location_points WHERE ts>?', (now(), t))
        c.execute('UPDATE peer_location_points SET ts=ts/1000.0 WHERE ts>?', (t,))
    n_upd = c.execute('UPDATE peer_location_latest SET updated=updated/1000.0 '
                      'WHERE updated>?', (t,)).rowcount
    n_state = c.execute('UPDATE peer_location_latest SET state_updated=state_updated/1000.0 '
                        'WHERE state_updated>?', (t,)).rowcount
    if n_points or n_upd or n_state:
        c.execute("INSERT INTO app_state(key,value) VALUES ('peer_ts_ms_migrated',?) "
                  'ON CONFLICT(key) DO UPDATE SET value=value+excluded.value', (n_points,))
        import logging
        logging.getLogger('love').info(
            'peer 时间戳毫秒→秒迁移：points %d 条（原行已备份到 %s），latest.updated %d，'
            'latest.state_updated %d', n_points, PEER_TS_BACKUP_TABLE, n_upd, n_state)
    return {'points': n_points, 'latest_updated': n_upd, 'latest_state_updated': n_state}


def apply_migrations(c):
    """把 schema_version 从当前值推进到最新。返回最终版本号。"""
    current = int(setting(c, 'schema_version', 1) or 1)
    for version in sorted(MIGRATIONS):
        if version <= current:
            continue
        description, migrate = MIGRATIONS[version]
        migrate(c)
        set_setting(c, 'schema_version', version)
        current = version
    return current


def ensure_push_topic(c, user_id):
    row = c.execute('SELECT topic FROM push_topics WHERE user_id=?', (user_id,)).fetchone()
    if row:
        return row['topic']
    topic = secrets.token_urlsafe(24)
    c.execute('INSERT INTO push_topics(user_id,topic,created) VALUES (?,?,?)', (user_id, topic, now()))
    return topic


PRIVATE = {'diary', 'draft', 'surprise'}
# SQL 侧的同款可见性条件。从 PRIVATE 派生而不是让调用方各写一份字面量：
# 以前看板/周报里各抄一遍 "kind NOT IN ('diary','draft','surprise')"，
# 将来新增私密类型只改 Python 侧就会漏过滤，等于把私密记录算进统计里。
# 末尾的 author=? 由调用方传入当前用户 id。
VISIBLE_SQL = "deleted IS NULL AND (kind NOT IN ({}) OR author=?)".format(
    ','.join("'" + kind + "'" for kind in sorted(PRIVATE)))
# 静态加密的类型：私密记录 + 生理期（健康数据，库文件被拷走也不该是明文）。
# 注意它和 PRIVATE 不等价：period 加密但可以按 shared 共享给另一半。
ENCRYPTED = PRIVATE | {'period'}
SHARED_EDIT = {'album', 'anniversary', 'wish', 'habit', 'quest', 'ledger', 'music', 'period'}
KINDS = {'post', 'diary', 'draft', 'surprise', 'album', 'anniversary', 'wish', 'personal_wish', 'mood', 'note', 'question', 'habit', 'chat', 'quest', 'ledger', 'period', 'music'}

# 聊天通知的合并窗口（秒）：短时间连发只弹一条推送，文案带未读数量。
# 窗口越长合并越彻底、延迟越高；15s 在"及时"与"不刷屏"之间取平衡。
CHAT_DELAY = 15


def body_encode(kind, record_id, body):
    if kind in ENCRYPTED:
        from .security import private_record_encrypt
        return dumps({'_private_record': private_record_encrypt(record_id, kind, dumps(body))})
    return dumps(body)


def body_decode(row):
    body = json.loads(row['body'])
    if row['kind'] in ENCRYPTED and '_private_record' in body:
        from .security import private_record_decrypt
        return json.loads(private_record_decrypt(row['id'], row['kind'], body['_private_record']))
    return body


# ── 2.4.11 媒体归类映射（主人定版 + 第 0 步裁定）──────────────────
# kind → zone。album 按引用定性（裁定1）：封面 mid 只是对 post 媒体的引用，
# 不产生新媒体、不独立定区——按其引用的 post 归 timeline。
KIND_ZONE = {
    'chat': 'chat', 'post': 'timeline', 'album': 'timeline', 'music': 'music',
    'diary': 'private', 'draft': 'private', 'surprise': 'private',
    'question': 'timeline', 'mood': 'timeline', 'note': 'timeline',
    'anniversary': 'timeline', 'wish': 'timeline', 'personal_wish': 'timeline',
    'habit': 'timeline', 'quest': 'timeline', 'ledger': 'timeline',
}
# 多 kind 引用同一媒体时的定区优先级（裁定：private > chat > timeline > music）
ZONE_PRIORITY = {'private': 0, 'chat': 1, 'timeline': 2, 'music': 3, 'space': 4}


def zone_for_kind(kind):
    return KIND_ZONE.get(kind, 'timeline')


def _media_file_names(row):
    """一个媒体行可能拥有的全部文件名：原图 + preview + 视频 poster。

    poster 没有独立 DB 字段，靠 <id>.preview.jpg 约定（worker.py:161 /
    main.py:1738），图片 preview 也可能是这个名字——用 set 去重即可。
    """
    names = {row['id'] + row['ext']}
    if row['preview']:
        names.add(row['preview'])
    names.add(row['id'] + '.preview.jpg')     # 图片 preview / 视频 poster
    names.add(row['id'] + '.preview.mp4')     # 视频 preview
    names.add(row['id'] + '.preview.m4a')     # 音频 preview
    return names


def move_media_files(c, mid, zone, *, collect_manifest=None):
    """把一个媒体行的已落盘文件搬到 zone 目录。返回 (moved, missing)。

    · 只处理 zone 为空的行；zone 已有值直接返回 (0, 0)——永不二次搬家；
    · 逐文件 is_file() 检查，目标已存在不覆盖（照 migrate_media_layout 先例）；
    · 磁盘上缺失的文件跳过搬家、照样写 zone，计数 missing（生产确有手动删过的文件）；
    · manifest 收集 (mid, from, to)（相对 data 根的 POSIX 路径）。
    """
    row = c.execute('SELECT * FROM media WHERE id=?', (mid,)).fetchone()
    if not row or row['zone']:
        return (0, 0)
    target = media_dir(zone, row['mime'], row['created'])
    moved = missing = 0
    for name in _media_file_names(row):
        # 源可能是旧布局（类型/月、平铺根）或 inbox（新上传）
        candidates = (
            *legacy_media_paths(row, name),
            DATA / 'media' / 'inbox' / media_month(row['created']) / name,
        )
        src = next((p for p in candidates if p.is_file()), None)
        if src is None:
            missing += 1
            continue
        dst = target / name
        if dst.exists():
            continue
        target.mkdir(parents=True, exist_ok=True)
        src.rename(dst)
        moved += 1
        if collect_manifest is not None:
            collect_manifest.append({
                'id': mid, 'name': name,
                'from': src.relative_to(DATA).as_posix(),
                'to': dst.relative_to(DATA).as_posix(),
            })
    c.execute('UPDATE media SET zone=? WHERE id=? AND zone=?', (zone, mid, ''))
    return (moved, missing)


def classify_media(c, mid, zone):
    """首次绑定定区：仅 zone='' 时搬家并写 zone；已有值直接返回 False。

    调用点必须排在 attached=1（worker claim 视野）之前或同链路内——
    由 mark_attached(zone=...) 统一保证。多处引用以第一次归类为准，永不二次搬家。
    """
    if not mid or not zone:
        return False
    row = c.execute('SELECT zone FROM media WHERE id=?', (mid,)).fetchone()
    if not row or row['zone']:
        return False
    move_media_files(c, mid, zone)
    return True


def media_zone_evidence(c, mid):
    """存量行的定区证据链（按优先级取一，返回 zone；无引用返回 'inbox'）。

    优先级：私密记录引用（解密判定）> 其它记录引用（按 kind 映射，多引用
    private>chat>timeline>music）> import_messages → chat > space 设置/头像/
    pose_ai_media → space > 无引用 → inbox。

    裁定补充：album 的 body.media[0] 是对 post 媒体的引用（不独立定区），
    KIND_ZONE['album']='timeline' 即按 timeline 引用计；body.song.mid 不纳入
    定区（歌曲由所属 music 记录定区），但纳入 cleanup 在用集合。
    """
    zones = set()
    # ①/② 记录引用。私密记录 body 密封，手握 secret.key 的服务端可解密判定。
    placeholders = ','.join('?' * len(PRIVATE))
    for row in c.execute(f"SELECT id,kind,body FROM records WHERE kind NOT IN ({placeholders})", tuple(PRIVATE)):
        try:
            if mid in json.loads(row['body']).get('media', []):
                zones.add(zone_for_kind(row['kind']))
        except (ValueError, TypeError):
            continue
    for row in c.execute(f"SELECT id,kind,body FROM records WHERE kind IN ({placeholders})", tuple(PRIVATE)):
        try:
            if mid in media_ids(body_decode(row)):
                zones.add(zone_for_kind(row['kind']))
        except Exception:
            continue
    if zones:
        return min(zones, key=lambda z: ZONE_PRIORITY.get(z, 99))
    # ③ 导入聊天媒体
    if c.execute('SELECT 1 FROM import_messages WHERE media_id=? LIMIT 1', (mid,)).fetchone():
        return 'chat'
    # ④ space 设置 / 头像 / pose_ai_media（裁定2：pose_ai 归 space）
    space = setting(c, 'space', {})
    if mid in ([space.get('cover'), space.get('chat_bg_media')]
               + chat_bg_media_ids(space)
               + [v for v in (space.get('pose_ai_media') or []) if v]):
        return 'space'
    if c.execute('SELECT 1 FROM users WHERE avatar=?', (mid,)).fetchone():
        return 'space'
    if mid in pose_ai_media_ids(c):
        return 'space'
    # ⑤ 无引用
    return 'inbox'


def media_zone_counts(c):
    return {z: c.execute('SELECT count(*) FROM media WHERE zone=?', (z,)).fetchone()[0] for z in ZONES}


def migrate_media_zones():
    """启动时把 zone='' 的存量行定区并搬家（幂等可重入，中断可续跑）。

    返回统计字典：各 zone 搬家文件数、缺失跳过数、manifest 条目数。
    manifest 落 data/media-zone-migration-<YYYYMMDD>.json（追加合并同日多次运行）。
    """
    manifest_path = DATA / ('media-zone-migration-' + dt.datetime.now().strftime('%Y%m%d') + '.json')
    manifest = []
    if manifest_path.is_file():
        try:
            manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
            if not isinstance(manifest, list):
                manifest = []
        except (OSError, ValueError):
            manifest = []
    media_root = DATA / 'media'
    def _file_count():
        return sum(1 for p in media_root.rglob('*') if p.is_file()) if media_root.is_dir() else 0
    total_before = _file_count()
    moved_by_zone = {z: 0 for z in ZONES}
    missing = 0
    with connect() as c:
        for row in c.execute("SELECT id FROM media WHERE zone='' OR zone IS NULL ORDER BY created").fetchall():
            mid = row['id']
            zone = media_zone_evidence(c, mid)
            before = len(manifest)
            mv, miss = move_media_files(c, mid, zone, collect_manifest=manifest)
            moved_by_zone[zone] += mv
            missing += miss
            if len(manifest) > before:
                manifest_path.write_text(dumps(manifest), encoding='utf-8')
    total_after = _file_count()
    # 旧类型目录（image/video/audio）搬空后删掉；只删空目录，不碰任何文件
    for kind in ('image', 'video', 'audio'):
        kind_root = media_root / kind
        if kind_root.is_dir():
            try:
                kind_root.rmdir()   # 非空会抛 OSError——说明还有残留，保留不删
            except OSError:
                pass
    # 对账：搬家只 rename 不复制不删除，前后总数必须相等；差一即停报（由调用方 log.error）
    balanced = total_before == total_after
    return {'moved_by_zone': moved_by_zone, 'missing': missing,
            'manifest': str(manifest_path), 'manifest_entries': len(manifest),
            'total_before': total_before, 'total_after': total_after, 'balanced': balanced}


def purge_media_files(c, mid):
    """彻底删除：删媒体行与其全部物理文件（原图 + preview + poster），按 zone 解析。"""
    row = c.execute('SELECT * FROM media WHERE id=?', (mid,)).fetchone()
    if not row:
        return
    folder = media_dir(row['zone'], row['mime'], row['created'])
    for name in _media_file_names(row):
        (folder / name).unlink(missing_ok=True)
    c.execute('DELETE FROM media WHERE id=?', (mid,))


def visible(row, user_id):
    if row['deleted']:
        return False
    if row['kind'] in PRIVATE:
        return row['author'] == user_id
    return True


def media_ids(body):
    return body.get('media', [])


def bump_shared(c):
    """推进共享 revision：让双方的 SSE 都收到 refresh。"""
    c.execute("UPDATE app_state SET value=value+1 WHERE key='content_revision'")


def bump_user(c, user_id):
    """只推进某个人自己的 revision。

    用于「不该让对方知道有变化」的写入——比如生理期记录设成了仅自己可见，
    那时推进共享 revision 等于告诉 TA「她刚记了点什么」。表里没有该用户的行时先插入。
    """
    c.execute('INSERT INTO user_revisions(user_id,value) VALUES (?,1)'
              ' ON CONFLICT(user_id) DO UPDATE SET value=value+1', (user_id,))


def media_shared_visible(c, mid):
    """这条附件是否属于「两人都看得到」的内容。

    复刻了已删除的 AFTER UPDATE ON media 触发器的判定：私密记录（日记/草稿/惊喜）
    里的附件不算共享——否则对方光是收到一次 refresh，就等于被告知"TA 刚写了点秘密"。
    只用于决定要不要推进共享 revision，不做权限判定（权限看 media_visible）。
    """
    if not mid:
        return False
    return bool(c.execute(
        "SELECT 1 FROM records r, json_each(r.body,'$.media') j"
        " WHERE r.deleted IS NULL AND r.kind NOT IN ('diary','draft','surprise')"
        " AND j.value=? LIMIT 1", (mid,)).fetchone())


def mark_attached(c, mids, zone=None):
    """把附件标记为「已被引用」，不再被孤儿清理回收。

    取代了已删除的 AFTER UPDATE ON media 触发器里 "UPDATE media SET attached=1" 的
    那一半职责。这里**不推进共享 revision**：引用它的那条记录 / 头像 / 设置本身就有
    自己的触发器会推，再推一次等于把私密内容的存在泄漏成对端的 refresh。

    2.4.11：zone 非空时先对每个附件首次定区（classify_media），再标记 attached——
    保证归类搬家在 attached=1 进入 worker claim 视野之前完成。zone 已有值的附件
    二次引用（含拿 post 照片当封面）直接跳过搬家。
    """
    mids = [m for m in mids if m]
    if not mids:
        return
    if zone:
        for mid in mids:
            classify_media(c, mid, zone)
    c.execute('UPDATE media SET attached=1 WHERE id IN (%s)' % ','.join('?' * len(mids)), mids)


_PRIVATE_PLACEHOLDERS = ','.join('?' * len(PRIVATE))


def media_in_visible_record(c, media_id, user_id):
    """这条附件是否被某条「当前用户可见」的记录引用。

    分两步走，避免原来的「全表 records + 逐条 body_decode」：
    1. 非私密记录的 body 是明文 JSON，一条 SQL 用 json_each 就能下推匹配；
    2. 私密记录的 body 被整体密封（只剩 _private_record 密文，SQL 匹配不到 media），
       所以只回退解密「用户自己的私密记录」这个小集合。

    每看一张图都要调一次：打开 30 图的相册，原来是 30 次全表扫描 + 30×N 次
    AES-GCM 解密（还要读 secret.key），现在是 30 次 SQL 匹配 + 至多少量解密。
    """
    row = c.execute(
        "SELECT 1 FROM records r, json_each(r.body,'$.media') j"
        f" WHERE r.deleted IS NULL AND r.kind NOT IN ({_PRIVATE_PLACEHOLDERS})"
        "   AND j.value=? LIMIT 1", (*PRIVATE, media_id)).fetchone()
    if row:
        return True
    # 只有作者本人能看到自己的私密记录，所以这里限定 author=?，集合很小
    for r in c.execute(
            f"SELECT id,kind,body FROM records WHERE deleted IS NULL AND author=?"
            f" AND kind IN ({_PRIVATE_PLACEHOLDERS})", (user_id, *PRIVATE)):
        if media_id in media_ids(body_decode(r)):
            return True
    return False


def chat_bg_media_ids(space):
    """所有个人聊天背景图的 id（两人各一份，可以互相代设）。"""
    return [v.get('media') for v in (space or {}).get('chat_bg_users', {}).values() if v.get('media')]


def pose_ai_media_ids(c):
    """AI 合成台生成图的 id 集合。

    这类图不挂在任何记录上，按「作者本人 / 记录引用」都判不到，但两张图本来就是两人
    一起合成的，另一半看历史记录时必须能加载出来，所以单独记一份。
    """
    try:
        row = c.execute("SELECT value FROM settings WHERE key='pose_ai_media'").fetchone()
        return set(json.loads(row['value'])) if row else set()
    except Exception:
        return set()


def media_visible(c, media_id, user_id):
    if not media_id:
        return False
    media = c.execute('SELECT * FROM media WHERE id=?', (media_id,)).fetchone()
    if not media:
        return False
    if media['owner'] == user_id:
        return True
    if media_in_visible_record(c, media_id, user_id):
        return True
    space = setting(c, 'space', {})
    # 对方替我设的背景图是他的，我这边要能取到（否则就是一张裂图）
    if media_id in [space.get('cover'), space.get('chat_bg_media')] + chat_bg_media_ids(space):
        return True
    # 导入的聊天记录是两人共享的，里面的图片不能只让导入者看到
    if c.execute('SELECT 1 FROM import_messages WHERE media_id=? LIMIT 1', (media_id,)).fetchone():
        return True
    # AI 合成台生成的图同理：一人合成、两人共看
    if media_id in pose_ai_media_ids(c):
        return True
    return bool(c.execute('SELECT 1 FROM users WHERE avatar=?', (media_id,)).fetchone())


def notice(c, event, title, record_id=None, actor=None, dedupe=None, recipient=None):
    for user in c.execute('SELECT id FROM users').fetchall():
        if user['id'] == actor or (recipient and user['id'] != recipient):
            continue
        nid = uid()
        key = f'{dedupe}:{user["id"]}' if dedupe else None
        inserted = c.execute('INSERT OR IGNORE INTO notices VALUES (?,?,?,?,?,?,0,?)',
                            (nid, user['id'], event, title, record_id, now(), key)).rowcount
        if not inserted:
            continue
        delay = CHAT_DELAY if event == 'chat' else 0
        # 手机端已停用内置 ntfy 系统推送（弹窗/锁屏），改用第三方渠道（企业微信等）+ 浏览器 Web Push。
        # 因此不再写入 push_outbox；原生 NtfyStreamService 收不到消息自然不再弹系统通知。
        subscriptions = c.execute('SELECT id FROM webpush_subscriptions WHERE user_id=?', (user['id'],)).fetchall()
        for subscription in subscriptions:
            c.execute('INSERT OR IGNORE INTO webpush_outbox(id,notice_id,subscription_id,user_id,next_at) VALUES (?,?,?,?,?)',
                      (uid(), nid, subscription['id'], user['id'], now() + delay))
        for channel in c.execute('SELECT * FROM channels WHERE owner=? AND enabled=1', (user['id'],)).fetchall():
            if event in json.loads(channel['events']):
                c.execute('INSERT INTO deliveries(id,notice_id,channel_id,next_at) VALUES (?,?,?,?)',
                          (uid(), nid, channel['id'], now() + delay))
