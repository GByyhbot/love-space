"""后端优化回归守卫：批量序列化、可见性单一事实源、导入列表聚合查询。

这些测试不是验证「某个接口能通」，而是钉住四处容易悄悄退化的地方：
1. main.py 不能重新定义 serialize_many 把 serializers 的 import 遮蔽掉；
2. SQL 侧可见性条件必须跟着 db.PRIVATE 走，新增私密类型不能漏过滤；
3. 批量序列化与逐行序列化的结果必须逐字相等（N+1 改造的前提）；
4. /api/imports 的 last 由相关子查询给出，空批次回空串而不是 null。
"""
import secrets

from app import db, main, serializers


def test_main_reuses_the_single_serializer_implementation():
    """main 里的名字必须就是 serializers 模块里的同一个对象。"""
    assert main.serialize is serializers.serialize
    assert main.serialize_many is serializers.serialize_many


def test_visible_sql_tracks_private_kinds():
    """每个私密类型都要出现在 SQL 条件里，且条件只带一个 author 占位符。"""
    for kind in db.PRIVATE:
        assert f"'{kind}'" in db.VISIBLE_SQL, f'私密类型 {kind} 没进 SQL 可见性条件'
    assert db.VISIBLE_SQL.count('?') == 1
    assert 'deleted IS NULL' in db.VISIBLE_SQL


def test_batch_serialize_matches_per_row(client_a):
    """批量与逐行必须产出完全相同的结果，否则统计页替换会悄悄改数据。"""
    created = client_a.post('/api/records', json={'kind': 'note', 'body': {'title': '对账', 'content': '批量与逐行'}})
    assert created.status_code == 200, created.text
    rid = created.json()['id']
    try:
        with db.connect() as c:
            user_id = c.execute('SELECT author FROM records WHERE id=?', (rid,)).fetchone()[0]
            # 加一条互动，让 related 分支真的有东西可装
            c.execute('INSERT INTO likes(record_id,user_id) VALUES (?,?)', (rid, user_id))
            rows = c.execute('SELECT * FROM records WHERE id=?', (rid,)).fetchall()
            per_row = [serializers.serialize(c, row, user_id) for row in rows]
            batch = serializers.serialize_many(c, rows, user_id)
        assert per_row == batch
    finally:
        client_a.delete(f'/api/records/{rid}')


def test_import_list_last_comes_from_one_query(client_a):
    """last 是最后一条消息；空批次回空串；列表按 created 倒序。"""
    iid_plain = 'opt-' + secrets.token_hex(4)
    iid_empty = 'opt-' + secrets.token_hex(4)
    with db.connect() as c:
        author = c.execute('SELECT id FROM users LIMIT 1').fetchone()[0]
        c.execute('INSERT INTO imports(id,platform,title,author,participants,me,message_count,created) '
                  'VALUES (?,?,?,?,?,?,?,?)',
                  (iid_plain, 'wechat', '有消息', author, '[]', '', 2, db.now()))
        c.execute('INSERT INTO imports(id,platform,title,author,participants,me,message_count,created) '
                  'VALUES (?,?,?,?,?,?,?,?)',
                  (iid_empty, 'wechat', '空批次', author, '[]', '', 0, db.now() + 1))
        c.execute('INSERT INTO import_messages(import_id,sender,content,day) VALUES (?,?,?,?)',
                  (iid_plain, '甲', '第一条', '2026-01-01'))
        c.execute('INSERT INTO import_messages(import_id,sender,content,day) VALUES (?,?,?,?)',
                  (iid_plain, '乙', '最后一条', '2026-01-01'))
    try:
        rows = client_a.get('/api/imports').json()
        by_id = {row['id']: row for row in rows}
        assert by_id[iid_plain]['last'] == '最后一条'
        assert by_id[iid_empty]['last'] == ''
        ids = [row['id'] for row in rows]
        assert ids.index(iid_empty) < ids.index(iid_plain), '未按 created 倒序'
    finally:
        with db.connect() as c:
            c.execute('DELETE FROM imports WHERE id IN (?,?)', (iid_plain, iid_empty))
