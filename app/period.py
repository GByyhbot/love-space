"""生理期独立数据库（DATA/period.db）。

健康数据与主库物理隔离：单独一个 SQLite 文件，可以整体拷贝、单独备份、单独删除，
主库损坏也不牵连它；主库里不再保留任何 kind='period' 的行。

约定与取舍：

1. **body 仍然是密文。** 'period' 仍在 db.ENCRYPTED 里，密钥沿用 secret.key。
   独立文件解决的是"数据放在哪个文件"，不是加密强度，所以不引入第二套密钥管理——
   否则备份、恢复、迁移都要同时带两把钥匙，出错面反而更大。
   表里保留 kind 列（固定 'period'），这样 db.body_encode / body_decode 原样复用。

2. **跨库写入不是原子的。** 顺序固定为「先提交分库 → 再写主库的通知与版本号」：
   通知丢了顶多重放一次，反过来则会丢掉用户真正写下的那条记录。
   唯一需要补偿的场景（分库成功、主库失败）不影响正确性，只是对端晚一点刷新。

3. **不参与主库的关联表。** 点赞 / 回复 / 问答 / 打卡都按 record_id 外键挂在 records 上，
   period 行不在 records 里，这些入口本来也没有（生理期卡片只有编辑/共享/删除）。
   序列化时给它们固定返回空数组，前端不需要为"缺字段"加分支。
"""
import contextlib
import datetime as dt
import sqlite3

from fastapi import HTTPException

from . import db

SCHEMA = '''
CREATE TABLE IF NOT EXISTS period(
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL DEFAULT 'period',
  author TEXT NOT NULL,
  body TEXT NOT NULL,
  created REAL NOT NULL,
  updated REAL NOT NULL,
  deleted REAL,
  client_id TEXT,
  UNIQUE(author, client_id));
CREATE INDEX IF NOT EXISTS period_created ON period(created DESC, id DESC);
CREATE INDEX IF NOT EXISTS period_author ON period(author, created DESC);
CREATE INDEX IF NOT EXISTS period_deleted ON period(deleted, created DESC);
'''


def db_path():
    return db.DATA / 'period.db'


@contextlib.contextmanager
def connect():
    conn = sqlite3.connect(db_path(), timeout=30)
    conn.row_factory = sqlite3.Row
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
    with connect() as c:
        c.execute('PRAGMA journal_mode=WAL')
        c.executescript(SCHEMA)


# ── 迁移 ─────────────────────────────────────────────────────────────

def pending_count():
    if not (db.DATA / 'love.db').is_file():
        return 0
    with db.connect() as c:
        return c.execute("SELECT count(*) FROM records WHERE kind='period'").fetchone()[0]


def _safety_copy():
    """把主库整份拷一份放在 data/ 下：迁移是搬库，出错要能退回原样。"""
    source = db.DATA / 'love.db'
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d-%H%M%S')
    target = db.DATA / f'love.db.before-period-split-{stamp}'
    src = sqlite3.connect(source)
    try:
        dst = sqlite3.connect(target)
        try:
            src.backup(dst)
        finally:
            dst.close()
    finally:
        src.close()
    return target


def migrate_from_main():
    """把主库里遗留的 kind='period' 行搬进 period.db，返回搬迁条数。

    幂等：先按原 id 复制过去（INSERT OR IGNORE，重复跑不会造重），**确认落库之后**
    才从主库删除。中途崩溃重跑也只会重做没做完的那一半，不会丢行——
    这正是宁可"两边都有一份"也不能"两边都没有"的原因。
    """
    init()
    total = pending_count()
    if not total:
        return 0
    _safety_copy()
    with db.connect() as c:
        rows = c.execute("SELECT * FROM records WHERE kind='period'").fetchall()
    with connect() as pc:
        pc.execute('BEGIN IMMEDIATE')
        for row in rows:
            pc.execute('INSERT OR IGNORE INTO period(id,kind,author,body,created,updated,deleted,client_id)'
                       ' VALUES (?,?,?,?,?,?,?,?)',
                       (row['id'], 'period', row['author'], row['body'], row['created'],
                        row['updated'], row['deleted'], row['client_id']))
    with db.connect() as c:
        c.execute('BEGIN IMMEDIATE')
        moved = 0
        for row in rows:
            moved += c.execute('DELETE FROM records WHERE id=?', (row['id'],)).rowcount
        db.bump_shared(c)
    return moved


# ── 读 ───────────────────────────────────────────────────────────────

def visible(row, user_id):
    if row['deleted']:
        return False
    if row['author'] == user_id:
        return True
    try:
        return bool(db.body_decode(row).get('shared'))
    except Exception:
        return False


def serialize(row, user_id, body=None):
    body = db.body_decode(row) if body is None else body
    if row['author'] != user_id and not body.get('shared'):
        # 对方没被共享：按"不存在"处理，别泄露"今天她记了点什么"
        raise HTTPException(404, '记录不存在')
    result = dict(row)
    result['body'] = body
    result['likes'] = []
    result['comments'] = []
    result['media'] = []
    return result


def get(rid, include_deleted=False):
    with connect() as c:
        row = c.execute('SELECT * FROM period WHERE id=?', (rid,)).fetchone()
    if row is None:
        return None
    if row['deleted'] and not include_deleted:
        return None
    return row


def rows_for(user_id, *, author='', date='', q='', trash=False,
             before=0.0, before_id='', limit=0):
    """列出当前用户可见的生理期记录（已序列化），按 created 倒序。

    date 匹配 start（生理期的"那一天"就是经期开始日），q 只搜备注正文。
    """
    clauses, params = [], []
    if trash:
        clauses += ['author=?', 'deleted IS NOT NULL']
        params.append(user_id)
    else:
        clauses.append('deleted IS NULL')
    if author:
        clauses.append('author=?')
        params.append(author)
    if before:
        clauses.append('(created<? OR (created=? AND id<?))')
        params += [before, before, before_id]
    sql = 'SELECT * FROM period'
    if clauses:
        sql += ' WHERE ' + ' AND '.join(clauses)
    sql += ' ORDER BY created DESC, id DESC'
    if limit:
        sql += ' LIMIT ?'
        params.append(limit)
    out = []
    with connect() as c:
        for row in c.execute(sql, params):
            if not trash and not visible(row, user_id):
                continue
            body = db.body_decode(row)
            if date and str(body.get('start') or body.get('date') or '')[:10] != date:
                continue
            if q and q.lower() not in str(body.get('content') or '').lower():
                continue
            out.append(serialize(row, user_id, body))
    return out


# ── 写 ───────────────────────────────────────────────────────────────

def find_by_client(author, client_id):
    if not client_id:
        return None
    with connect() as c:
        return c.execute('SELECT * FROM period WHERE author=? AND client_id=?',
                         (author, client_id)).fetchone()


def insert(rid, author, body, client_id=None):
    ts = db.now()
    with connect() as c:
        c.execute('BEGIN IMMEDIATE')
        c.execute('INSERT INTO period(id,kind,author,body,created,updated,deleted,client_id)'
                  ' VALUES (?,?,?,?,?,?,NULL,?)',
                  (rid, 'period', author, db.body_encode('period', rid, body), ts, ts, client_id))
    return ts


def update(rid, body):
    with connect() as c:
        c.execute('BEGIN IMMEDIATE')
        c.execute('UPDATE period SET body=?,updated=? WHERE id=?',
                  (db.body_encode('period', rid, body), db.now(), rid))


def soft_delete(rid):
    ts = db.now()
    with connect() as c:
        c.execute('BEGIN IMMEDIATE')
        c.execute('UPDATE period SET deleted=?,updated=? WHERE id=?', (ts, ts, rid))


def restore(rid):
    with connect() as c:
        c.execute('BEGIN IMMEDIATE')
        c.execute('UPDATE period SET deleted=NULL,updated=? WHERE id=?', (db.now(), rid))


def set_shared(author, shared):
    """把某个人的全部记录一次性设为共享 / 收回，返回 (改动条数, 总数)。"""
    changed = total = 0
    with connect() as c:
        c.execute('BEGIN IMMEDIATE')
        rows = c.execute('SELECT * FROM period WHERE author=? AND deleted IS NULL',
                         (author,)).fetchall()
        total = len(rows)
        for row in rows:
            body = db.body_decode(row)
            if bool(body.get('shared')) == shared:
                continue
            body['shared'] = shared
            c.execute('UPDATE period SET body=?,updated=? WHERE id=?',
                      (db.body_encode('period', row['id'], body), db.now(), row['id']))
            changed += 1
    return changed, total


def purge_deleted(cutoff):
    with connect() as c:
        c.execute('BEGIN IMMEDIATE')
        return c.execute('DELETE FROM period WHERE deleted IS NOT NULL AND deleted<?',
                         (cutoff,)).rowcount


def count_active():
    if not db_path().is_file():
        return 0
    with connect() as c:
        return c.execute('SELECT count(*) FROM period WHERE deleted IS NULL').fetchone()[0]


def copy_file(destination):
    """备份用：把库做一份一致性快照到 destination（走 SQLite backup，别直接拷文件）。"""
    source = sqlite3.connect(db_path())
    try:
        target = sqlite3.connect(destination)
        try:
            source.backup(target)
        finally:
            target.close()
    finally:
        source.close()
    return destination


def integrity_ok():
    with connect() as c:
        return c.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'


def remove_file():
    """删库（连同 -wal/-shm），返回删掉的文件数。"""
    removed = 0
    for suffix in ('', '-wal', '-shm'):
        candidate = db_path().with_name(db_path().name + suffix)
        if candidate.is_file():
            candidate.unlink()
            removed += 1
    return removed
