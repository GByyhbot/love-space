"""2.6.0 性能段第二批（P3/P12）· revision 键控缓存。

四个「每次调用全表聚合」的接口（/api/yearbook、/api/calendar、/api/on-this-day、
/api/dashboard）进程内缓存：键 = (接口, 用户, 参数, 当天日期)，外加全局
content_revision 前置校验——revision 由 SQLite 触发器在一切内容变更时推进
（app/db.py 触发器组），period 分库写入经 _period_touch → bump_shared 推同一
计数（app/main.py:1331），所以**不需要任何显式失效调用**：revision 变 = 键全
失配 = 全清重算，语义安全。

键里的「当天日期」不可省：dashboard 的 days_together、on-this-day 的 is_today
随日历天变化而 revision 不变；键含当天日期，跨天自动失配。

命中判断只付一条 app_state 单行查询（O(1) 主键行），远低于四接口的 O(全表聚合)。
并发：FastAPI 线程池下 dict 读写是 GIL 原子操作，最坏情形是并发首查重复计算
一次，不加锁。
"""

from . import db

# {'rev': 上次见到的 content_revision, 'data': {键: 结果}}
_rev_cache = {'rev': -1, 'data': {}}


def current_revision(c=None):
    """当前内容版本号（app_state 单行；c 可传入已有连接复用）。"""
    if c is not None:
        return int(c.execute(
            "SELECT value FROM app_state WHERE key='content_revision'").fetchone()[0])
    with db.connect() as conn:
        return int(conn.execute(
            "SELECT value FROM app_state WHERE key='content_revision'").fetchone()[0])


def cached(key, compute):
    """键控缓存入口。

    key 必须完整覆盖计算的全部输入语义（接口名、用户、参数、当天日期）；
    compute 是零参闭包，内部自行开连接。返回值只读透传（端点不得原地修改
    返回的容器，否则会污染缓存）。
    """
    rev = current_revision()
    box = _rev_cache
    if box['rev'] != rev:
        box['rev'] = rev
        box['data'] = {}
    hit = box['data'].get(key)
    if hit is not None:
        return hit
    val = compute()
    box['data'][key] = val
    return val
