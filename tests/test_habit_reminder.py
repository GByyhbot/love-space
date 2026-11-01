"""共同打卡的 20 点晚间提醒：hour<20 不发；20 点后只提醒没打卡的人；
dedupe 保证同一天同一条打卡对同一个人只提醒一次；两人都打卡后彻底安静。
其他测试可能留下 habit 记录，这里统一按唯一标题过滤再断言。"""
import datetime as dt


def _evening(hour):
    return dt.datetime.combine(dt.date.today(), dt.time(hour, 0))

from app.db import connect
from app.worker import habit_reminders


def _notice_titles(marker):
    with connect() as c:
        return [r['title'] for r in c.execute("SELECT title FROM notices WHERE event='habit'") if marker in r['title']]


def _make_habit(client, title):
    r = client.post('/api/records', json={'kind': 'habit', 'body': {'title': title}})
    assert r.status_code == 200, r.text
    return r.json()['id']


def _check(client, rid):
    r = client.post(f'/api/records/{rid}/check')
    assert r.status_code == 200, r.text


def test_no_reminder_before_20(client_a, client_b):
    _make_habit(client_a, 'sleep marker alpha')
    habit_reminders(_evening(19))
    assert _notice_titles('sleep marker alpha') == []


def test_reminds_only_missing_after_20(client_a, client_b):
    rid = _make_habit(client_a, 'sleep marker bravo')
    # 小兔（client_a 的用户）打过卡，小熊没打
    _check(client_a, rid)
    habit_reminders(_evening(20))
    titles = _notice_titles('sleep marker bravo')
    assert len(titles) == 1
    assert 'sleep marker bravo' in titles[0]
    with connect() as c:
        row = c.execute("SELECT user_id FROM notices WHERE event='habit' AND title LIKE '%sleep marker bravo%'").fetchone()
        name = c.execute('SELECT name FROM users WHERE id=?', (row['user_id'],)).fetchone()['name']
    assert name == '小熊'


def test_dedupe_repeats_and_completed(client_a, client_b):
    rid = _make_habit(client_a, 'run marker charlie')
    when = _evening(21)
    habit_reminders(when)
    habit_reminders(when.replace(hour=22))  # 同一晚再跑，不重复
    assert len(_notice_titles('run marker charlie')) == 2  # 两个人各一条
    _check(client_a, rid)
    _check(client_b, rid)
    habit_reminders(when.replace(hour=23))
    assert len(_notice_titles('run marker charlie')) == 2  # 都打卡了，不再新增
