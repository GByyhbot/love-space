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


def media_dir(mime, created):
    """媒体文件按「类型/年-月」分目录存放：media/image/2026-10/…"""
    kind = 'image' if mime.startswith('image/') else ('video' if mime.startswith('video/') else 'audio')
    month = dt.datetime.fromtimestamp(created, dt.timezone.utc).strftime('%Y-%m')
    return DATA / 'media' / kind / month


def migrate_media_layout():
    """旧版本把所有媒体平铺在 media/ 根目录；启动时按类型与月份归位。"""
    moved = 0
    with connect() as c:
        rows = c.execute('SELECT id,ext,preview,mime,created FROM media').fetchall()
    for r in rows:
        folder = media_dir(r['mime'], r['created'])
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


def dumps(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


@contextlib.contextmanager
def connect():
    conn = sqlite3.connect(DATA / 'love.db', timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute('PRAGMA foreign_keys=ON')
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
          avatar TEXT NOT NULL DEFAULT '', created REAL NOT NULL);        CREATE TABLE IF NOT EXISTS sessions(token TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), expires REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS invites(token TEXT PRIMARY KEY, expires REAL NOT NULL, used INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, kind TEXT NOT NULL, author TEXT NOT NULL REFERENCES users(id),
          body TEXT NOT NULL, created REAL NOT NULL, updated REAL NOT NULL, deleted REAL, published REAL,
          client_id TEXT, UNIQUE(author, client_id));
        CREATE INDEX IF NOT EXISTS records_kind ON records(kind, created);
        CREATE TABLE IF NOT EXISTS media(id TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES users(id),
          name TEXT NOT NULL, mime TEXT NOT NULL, size INTEGER NOT NULL, ext TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending', preview TEXT, error TEXT, created REAL NOT NULL,
          attached INTEGER NOT NULL DEFAULT 0);
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
        ''')
        c.execute("INSERT OR IGNORE INTO app_state(key,value) VALUES ('content_revision',0)")
        # Additive columns must exist before triggers reference them.
        if 'media_id' not in {r[1] for r in c.execute('PRAGMA table_info(import_messages)')}:
            c.execute("ALTER TABLE import_messages ADD COLUMN media_id TEXT NOT NULL DEFAULT ''")
        c.execute('CREATE INDEX IF NOT EXISTS import_messages_media ON import_messages(media_id)')
        if 'attached' not in {r[1] for r in c.execute('PRAGMA table_info(media)')}:
            c.execute('ALTER TABLE media ADD COLUMN attached INTEGER NOT NULL DEFAULT 0')
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
        CREATE TRIGGER IF NOT EXISTS revision_settings_insert AFTER INSERT ON settings
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_settings_update AFTER UPDATE ON settings
          BEGIN UPDATE app_state SET value=value+1 WHERE key='content_revision'; END;
        CREATE TRIGGER IF NOT EXISTS revision_settings_delete AFTER DELETE ON settings
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
MIGRATIONS = {}


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


def visible(row, user_id):
    if row['deleted']:
        return False
    if row['kind'] in PRIVATE:
        return row['author'] == user_id
    if row['kind'] == 'period' and row['author'] != user_id:
        # 生理期是健康数据：默认只有本人可见，作者显式打开「共享给 TA」才让对方看到。
        # body 解析只发生在 period 行上，不影响其他类型的性能。
        try:
            return bool(body_decode(row).get('shared'))
        except Exception:
            return False
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


def mark_attached(c, mids):
    """把附件标记为「已被引用」，不再被孤儿清理回收。

    取代了已删除的 AFTER UPDATE ON media 触发器里 "UPDATE media SET attached=1" 的
    那一半职责。这里**不推进共享 revision**：引用它的那条记录 / 头像 / 设置本身就有
    自己的触发器会推，再推一次等于把私密内容的存在泄漏成对端的 refresh。

    写入点只有三处：保存记录、设头像、导入 zip 附件。新增写入点时记得也调这里，
    否则附件会被 cleanup 当成孤儿删掉。
    """
    mids = [m for m in mids if m]
    if not mids:
        return
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
