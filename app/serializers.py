"""记录序列化。

从 main.py 下沉出来只为一件事：打破 main ↔ backups / webpush 的循环导入。
backups.py 的用户导出要用 serialize，而 main 又 import 了 backups——函数内
`from .main import serialize` 那种"用到才导入"的写法只是把环藏起来，并没有拆掉。

这里只依赖 db 与 security，不依赖 main，谁都可以直接 import。
"""
from fastapi import HTTPException

from . import db
from .security import open_sealed


def serialize(c, row, user_id, related=None):
    if row['kind'] in db.PRIVATE and row['author'] != user_id:
        raise HTTPException(404, '记录不存在')
    result = dict(row)
    result['body'] = db.body_decode(row)
    if row['kind'] == 'personal_wish':
        stored = result['body']
        # 作者本人始终可见；对方输入过正确密码后也永久可见，不必反复输密码
        author = row['author'] == user_id
        readers = stored.get('readers_sealed') or {}
        result['body'] = {'title': stored.get('title', ''), 'locked': True}
        sealed_for_me = stored.get('owner_sealed') if author else readers.get(user_id)
        if sealed_for_me:
            try:
                result['body'] = {'title': stored.get('title', ''), 'locked': False, 'content': open_sealed(sealed_for_me)}
            except HTTPException:
                pass  # 主密钥遗失时退化为锁定态，列表页不至于整体报错
        if author:
            result['body']['sealed'] = stored.get('sealed', {})
    result['likes'] = related['likes'].get(row['id'], []) if related is not None else [r[0] for r in c.execute('SELECT user_id FROM likes WHERE record_id=?', (row['id'],))]
    result['comments'] = related['comments'].get(row['id'], []) if related is not None else [dict(r) for r in c.execute('SELECT * FROM comments WHERE record_id=? ORDER BY created', (row['id'],))]
    if row['kind'] == 'question':
        answers = related['answers'].get(row['id'], []) if related is not None else [dict(r) for r in c.execute('SELECT * FROM answers WHERE record_id=?', (row['id'],))]
        result['answers'] = answers if len(answers) == 2 else [a for a in answers if a['author'] == user_id]
        result['answer_count'] = len(answers)
    if row['kind'] == 'habit':
        result['checks'] = related['checks'].get(row['id'], []) if related is not None else [dict(r) for r in c.execute('SELECT * FROM checks WHERE record_id=? ORDER BY day DESC', (row['id'],))]
    if related is None:
        result['media'] = [dict(m) for mid in result['body'].get('media', [])
                           if (m := c.execute('SELECT id,name,mime,size,status,preview FROM media WHERE id=?', (mid,)).fetchone())]
    else:
        result['media'] = [related['media'][mid] for mid in result['body'].get('media', []) if mid in related['media']]
    return result


def serialize_many(c, rows, user_id):
    """Serialize a result page with bounded queries instead of per-row lookups."""
    related = {'likes': {}, 'comments': {}, 'answers': {}, 'checks': {}, 'media': {}}
    rows = list(rows)
    for start in range(0, len(rows), 300):
        chunk = rows[start:start + 300]
        ids = [row['id'] for row in chunk]
        if not ids:
            continue
        marks = ','.join('?' for _ in ids)
        for row in c.execute(f'SELECT record_id,user_id FROM likes WHERE record_id IN ({marks})', ids):
            related['likes'].setdefault(row['record_id'], []).append(row['user_id'])
        for row in c.execute(f'SELECT * FROM comments WHERE record_id IN ({marks}) ORDER BY created', ids):
            related['comments'].setdefault(row['record_id'], []).append(dict(row))
        for row in c.execute(f'SELECT * FROM answers WHERE record_id IN ({marks})', ids):
            related['answers'].setdefault(row['record_id'], []).append(dict(row))
        for row in c.execute(f'SELECT * FROM checks WHERE record_id IN ({marks}) ORDER BY day DESC', ids):
            related['checks'].setdefault(row['record_id'], []).append(dict(row))
        media_ids = list(dict.fromkeys(mid for record in chunk for mid in db.body_decode(record).get('media', [])))
        for media_start in range(0, len(media_ids), 300):
            mids = media_ids[media_start:media_start + 300]
            media_marks = ','.join('?' for _ in mids)
            for row in c.execute(f'SELECT id,name,mime,size,status,preview FROM media WHERE id IN ({media_marks})', mids):
                related['media'][row['id']] = dict(row)
    return [serialize(c, row, user_id, related) for row in rows]
