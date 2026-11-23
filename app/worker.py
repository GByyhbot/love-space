import datetime as dt
import json
import logging
import os
import shutil
import subprocess
import threading
import time
from zoneinfo import ZoneInfo

from PIL import Image, ImageOps

try:
    from pillow_heif import register_heif_opener
    register_heif_opener()
    _HEIF_OK = True
except Exception:
    _HEIF_OK = False

from . import db
from . import peer
from .db import connect, dumps, now
from . import period
from .security import PURPOSE_CHANNEL_CONFIG, cipher, decrypt_with_fallback
from .backups import BackupRefused, create_backup, storage_lock

# 自动备份失败后的重试间隔：1 小时。
# 不能让失败的程序每分钟重试（2026-11-07 磁盘被 33 个残包吃满 31G），
# 也不该直接放弃到第二天，留出自愈窗口。
BACKUP_RETRY_AFTER = 3600
from . import notifications

log = logging.getLogger('love.worker')

# 相恋天数里程碑：整数关口 + 常见纪念数字。只在当天提醒一次（dedupe 带天数）。
MILESTONES = {100, 200, 300, 365, 520, 600, 730, 800, 1000, 1314, 1500, 1825,
              2000, 2555, 3000, 3650, 5000, 5555, 7300, 10000, 13140, 18250}

# 投递循环的即时唤醒：请求线程写入新通知后调用 nudge()，worker 立刻跑一轮投递，
# 聊天推送不再等 5s 轮询周期（配合 db.CHAT_DELAY，服务端出队延迟从最坏 ~13s 降到 ~3-4s）。
wake = threading.Event()


def nudge():
    wake.set()


MEDIA_TIMEOUT = 300  # 音频转码固定上限（aac 编码开销小，不需要时长定标）
MEDIA_POSTER_TIMEOUT = 120


# ── 2.6.0 P5：视频转码参数/超时/时长（主人裁定口径）──────────────────────
def build_video_ffmpeg_args(src, dst):
    """视频转码参数：分辨率封顶 1080p（scale=-2:min(1080,ih) 不放大，低清
    原样）、-threads 2 防 NAS 弱 CPU 被 ffmpeg 吃满。护栏钉参数构造。"""
    return ['ffmpeg', '-y', '-i', str(src), '-map_metadata', '-1',
            '-vf', 'scale=-2:min(1080,ih)', '-c:v', 'libx264', '-preset', 'fast',
            '-crf', '25', '-pix_fmt', 'yuv420p', '-threads', '2',
            '-c:a', 'aac', '-movflags', '+faststart', str(dst)]


def build_poster_args(preview_src, poster_dst):
    """封面参数：从**转码产物 preview.mp4** 抽帧——不再解码原片
    （原片可能是 4K，抽帧要付全分辨率解码价；preview 已是 1080p 产物）。"""
    return ['ffmpeg', '-y', '-i', str(preview_src), '-frames:v', '1',
            '-vf', 'scale=640:-2', str(poster_dst)]


def video_timeout(duration):
    """超时按时长定标（替代一刀切 300s）：
    video_timeout = clamp(60 + 2×duration, 60, 900)。
    依据：1080p 封顶 + -threads 2 下 NAS 弱 CPU 转码约 0.5–1×实时，
    2×实时留足余量；60s 起步覆盖短视频；900s 封顶防超长视频无限占用。"""
    return int(min(900, max(60, 60 + 2 * (duration or 0))))


def probe_duration(path):
    """ffprobe 取时长秒（复用 music_drop._probe 范式：-show_format json）。
    失败/无 ffprobe 返回 None（duration 列保持 NULL，前端/API 容错）。"""
    if not shutil.which('ffprobe'):
        return None
    try:
        out = subprocess.run(
            ['ffprobe', '-v', 'error', '-show_format', '-of', 'json', str(path)],
            capture_output=True, text=True, timeout=30, check=False)
        if out.returncode != 0:
            return None
        dur = float(json.loads(out.stdout).get('format', {}).get('duration') or 0)
        return max(0.0, dur) if dur > 0 else None
    except (OSError, ValueError, json.JSONDecodeError):
        return None


class TranscodeAborted(Exception):
    """服务正在关闭，转码被主动中断。"""


def run_ffmpeg(args, timeout=MEDIA_TIMEOUT, stop=None):
    """跑 ffmpeg，并在服务关闭时主动 kill。

    原来用 subprocess.run(timeout=1800)：容器 stop 时这个调用不可中断，转码到一半
    被硬杀，附件永远卡在 pending。改成 Popen + 轮询，stop 一置位就 kill。
    """
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + timeout
    while proc.poll() is None:
        if stop is not None and stop.is_set():
            proc.kill()
            proc.wait(timeout=10)
            raise TranscodeAborted()
        if time.time() >= deadline:
            proc.kill()
            proc.wait(timeout=10)
            raise subprocess.TimeoutExpired(args, timeout)
        time.sleep(0.5)
    if proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, args)
    return proc


def requeue_stuck_media():
    """把上次退出时中断的转码任务退回 pending。

    进程被 SIGTERM 硬杀或崩溃时，正在转的行会永远停在 'processing'：既不重转
    （claim 只挑 pending），也不被清理（cleanup 跳过 processing）。启动时救回来。
    返回被救回的行数。
    """
    with connect() as c:
        count = c.execute("UPDATE media SET status='pending' WHERE status='processing'").rowcount
    if count:
        log.warning('重启时发现 %s 个中断的转码任务，已重新排队', count)
    return count


def claim_pending_media(c):
    """在同一事务里原子认领一个待转码附件，返回 row 或 None。

    以前是 SELECT 出来就关闭连接，ffmpeg 一跑就是几十秒到几分钟，这期间该行
    status 仍是 'pending'；cleanup() 与转码之间没有任何协调，可能把行和磁盘文件
    一起删掉，最后 UPDATE status='ready' 命中 0 行 —— 用户看到的就是永久缺失的附件。
    认领后 status 变 'processing'，cleanup() 会跳过它。
    """
    c.execute('BEGIN IMMEDIATE')
    # 孤儿附件（未关联记录）不转码，避免为将放弃的内容浪费算力；发布后再处理
    row = c.execute("SELECT * FROM media WHERE status='pending' AND attached=1 ORDER BY created LIMIT 1").fetchone()
    if not row:
        return None
    c.execute("UPDATE media SET status='processing' WHERE id=? AND status='pending'", (row['id'],))
    return row


def finish_media(row, status, preview=None, error=None, duration=None):
    """写回转码结果。行已被删（cleanup 抢跑）时不静默成功，要记日志并清掉孤儿文件。

    2.6.0 P5：duration 一并回写（None=ffprobe 失败/图片口径，列保持 NULL）。
    """
    with connect() as c:
        cur = c.execute('UPDATE media SET status=?,preview=?,error=?,duration=? WHERE id=? AND status=?',
                        (status, preview or '', error, duration, row['id'], 'processing'))
        if cur.rowcount == 0:
            log.warning('附件 %s 在转码期间已不存在，结果丢弃（status=%s）', row['id'], status)
            if preview:
                (db.media_dir(row['zone'], row['mime'], row['created']) / preview).unlink(missing_ok=True)
            return False
        # 这是被删掉的 AFTER UPDATE ON media 触发器里真正有用的那一次 bump：
        # 转码完成后 preview 才存在，对方的客户端得重新拉一次才能看到成品缩略图，
        # 否则会一直停在黑底占位。私密记录里的附件不算共享，别惊动对方。
        if status == 'ready' and db.media_shared_visible(c, row['id']):
            db.bump_shared(c)
    return True


def process_media(stop=None):
    with connect() as c:
        row = claim_pending_media(c)
    if not row:
        return
    folder = db.media_dir(row['zone'], row['mime'], row['created'])
    path = folder / (row['id'] + row['ext'])
    preview = None
    duration = None
    try:
        if row['mime'].startswith('image/'):
            preview = row['id'] + '.preview.jpg'
            try:
                # HEIC/HEIF 需要 pillow-heif；未安装时回退到 ffmpeg，仍失败则保留原文件
                with Image.open(path) as im:
                    image = ImageOps.exif_transpose(im).convert('RGB')
                    image.thumbnail((1600, 1600))
                    image.save(folder / preview, quality=86)
            except Exception:
                if not shutil.which('ffmpeg'):
                    raise
                run_ffmpeg(['ffmpeg', '-y', '-i', str(path), '-frames:v', '1', str(folder / preview)],
                           MEDIA_POSTER_TIMEOUT, stop)
        elif shutil.which('ffmpeg'):
            video = row['mime'].startswith('video/')
            duration = probe_duration(path)  # 原片时长（图片不 probe；原文件保留播放时同样有用）
            preview = row['id'] + ('.preview.mp4' if video else '.preview.m4a')
            if video:
                args = build_video_ffmpeg_args(path, folder / preview)
                timeout = video_timeout(duration)
            else:
                args = ['ffmpeg', '-y', '-i', str(path), '-map_metadata', '-1', '-vn',
                        '-threads', '2', '-c:a', 'aac', '-movflags', '+faststart',
                        str(folder / preview)]
                timeout = MEDIA_TIMEOUT
            run_ffmpeg(args, timeout, stop)
            if video:
                # 抽首帧作封面：从转码产物 preview.mp4 抽帧（P5：不再解码原片，
                # 原片可能 4K）；失败只影响封面，不影响视频转码结果
                poster = folder / (row['id'] + '.preview.jpg')
                try:
                    run_ffmpeg(build_poster_args(folder / preview, poster),
                               MEDIA_POSTER_TIMEOUT, stop)
                except Exception:
                    # 封面失败只影响列表缩略图，视频本身已经转好了，不值得把整条任务判失败
                    log.debug('附件 %s 封面抽取失败', row['id'], exc_info=True)
                    poster.unlink(missing_ok=True)
        else:
            finish_media(row, 'original', error='未安装 FFmpeg，保留原文件播放', duration=duration)
            return
        finish_media(row, 'ready', preview=preview, duration=duration)
    except TranscodeAborted:
        # 服务正在关闭：把行退回 pending，下次启动接着转，别留下永久的 processing
        if preview:
            (folder / preview).unlink(missing_ok=True)
        with connect() as c:
            c.execute("UPDATE media SET status='pending' WHERE id=? AND status='processing'", (row['id'],))
        raise
    except Exception as exc:
        if preview:
            (folder / preview).unlink(missing_ok=True)
        # 真实原因只进日志（ffmpeg 报错里可能有路径），用户看到一句人话
        log.exception('附件 %s 转码失败', row['id'])
        finish_media(row, 'original', error='预览转换失败（%s），原文件仍保留' % type(exc).__name__,
                     duration=duration)


def due_date(value, annual, today):
    date = dt.date.fromisoformat(value)
    if not annual:
        return date
    # 农历年度纪念日：把存储的公历日期反推为农历，再用当前/下一年的同一农历日转回公历
    if annual == 'lunar':
        try:
            from lunardate import LunarDate
            lunar = LunarDate.fromSolarDate(date.year, date.month, date.day)
            for year in (today.year, today.year + 1):
                # Keep leap-month anniversaries when that lunar year has the
                # leap month; when it does not, fall back to the regular month.
                candidates = [(lunar.month, lunar.day, lunar.isLeapMonth)]
                if lunar.isLeapMonth:
                    candidates.append((lunar.month, lunar.day, False))
                for month, day, is_leap in candidates:
                    for lunar_day in (day, 29) if day == 30 else (day,):
                        try:
                            candidate = LunarDate(year, month, lunar_day, is_leap).toSolarDate()
                        except ValueError:
                            continue
                if candidate >= today:
                    return candidate
        except Exception:
            # 农历换算失败就退回公历日期，但要知道它失败过
            log.debug('农历纪念日换算失败，退回公历：%s', value, exc_info=True)
        return date
    for year in (today.year, today.year + 1):
        try:
            candidate = date.replace(year=year)
        except ValueError:
            candidate = dt.date(year, 2, 28)
        if candidate >= today:
            return candidate


def schedule():
    with connect() as c:
        c.execute('BEGIN IMMEDIATE')
        zone = ZoneInfo(db.setting(c, 'space')['timezone'])
        today = dt.datetime.now(zone).date()
        # 2.6.0 性能段 P1：schedule 只关心 surprise/anniversary/wish 三类——
        # 此前全表逐行 body 解码（聊天占记录约 88%，纯浪费）。kind IN 命中
        # records_kind(kind, created) 索引；cleanup 的 SQL 下推不在本批（主人裁定）。
        for row in c.execute("SELECT * FROM records WHERE deleted IS NULL "
                             "AND kind IN ('surprise','anniversary','wish')").fetchall():
            body = db.body_decode(row)
            if row['kind'] == 'surprise' and body.get('publish_at', float('inf')) <= now():
                body.pop('publish_at', None)
                body['was_surprise'] = True
                c.execute("UPDATE records SET kind='post',body=?,published=?,updated=? WHERE id=?", (db.body_encode('post', row['id'], body), now(), now(), row['id']))
                db.notice(c, 'surprise', '有一份为你准备的惊喜公开了', row['id'], row['author'], dedupe='surprise:' + row['id'])
            elif row['kind'] == 'anniversary':
                date = due_date(body['date'], body.get('annual', True), today)
                if 0 <= (date - today).days <= body.get('remind_days', 1):
                    db.notice(c, 'anniversary', '一个重要的纪念日快到了', row['id'], dedupe=f'anniversary:{row["id"]}:{date}')
            elif row['kind'] == 'wish' and body.get('target') and not body.get('done'):
                if body['target'] <= today.isoformat():
                    db.notice(c, 'wish', '有一个共同愿望到了约定日期', row['id'], dedupe=f'wish:{row["id"]}:{body["target"]}')
        # 生理期在独立库（DATA/period.db），不在 records 里，所以这里单独算一遍。
        # 算不出来（比如还没记过）就当没有提醒，别让一次异常拖垮整个每日任务。
        try:
            due = period.reminder(period.cycle_stats(today), today,
                                  int(os.getenv('PERIOD_REMIND_DAYS', '2')))
        except Exception:
            log.warning('生理期提醒计算失败', exc_info=True)
            due = None
        if due:
            db.notice(c, 'period', due[0], dedupe=due[1])
        # 相恋里程碑：100 / 365 / 1000 天这类日子只在当天提醒一次
        space = db.setting(c, 'space', {}) or {}
        days = None
        if space.get('since'):
            try:
                days = (today - dt.date.fromisoformat(space['since'])).days + 1
            except ValueError:
                days = None
        if days in MILESTONES:
            db.notice(c, 'anniversary', f'今天是你们相恋 {days} 天，值得记一笔', dedupe=f'milestone:{days}')
        free = shutil.disk_usage(db.DATA).free
        if free < int(os.getenv('LOW_STORAGE_MB', '1024')) * 1024 * 1024:
            db.notice(c, 'storage', '空间剩余容量不足，请检查存储', dedupe='storage:' + today.isoformat())
        c.execute('DELETE FROM sessions WHERE expires<?', (now(),))
        c.execute('DELETE FROM auth_attempts WHERE start<?', (now() - 86400,))


def habit_reminders(now_dt=None):
    """共同打卡的晚间提醒：本地时间 20 点后，谁还没打卡就单独提醒谁。

    每次只做几个轻查询，dedupe 键带「记录 + 日期 + 人」：同一天同一条打卡对
    同一个人只入一条通知，补完打卡后也不会再发。两张卡都齐了就彻底安静。
    """
    with connect() as c:
        zone = ZoneInfo(db.setting(c, 'space')['timezone'])
        now_local = now_dt or dt.datetime.now(zone)
        if now_local.hour < 20:
            return
        today = now_local.date().isoformat()
        for row in c.execute("SELECT * FROM records WHERE kind='habit' AND deleted IS NULL").fetchall():
            # 打卡在独立的 checks 表里（record_id, author, day），不在 body
            done = {r['author'] for r in c.execute(
                'SELECT author FROM checks WHERE record_id=? AND day=?', (row['id'], today))}
            if len(done) >= 2:
                continue
            title = db.body_decode(row).get('title') or '共同打卡'
            for user in c.execute('SELECT id FROM users').fetchall():
                if user['id'] in done:
                    continue
                db.notice(c, 'habit', f'「{title}」今天还没打卡，一起坚持一下',
                          row['id'], recipient=user['id'],
                          dedupe=f"habit:{row['id']}:{today}:{user['id']}")


def quiet(hour, start, end):
    return False if start == end else (start <= hour < end if start < end else hour >= start or hour < end)


def deliver():
    with connect() as c:
        rows = c.execute("""SELECT d.*,c.kind,c.config,c.quiet_start,c.quiet_end,c.interval,c.enabled,
          n.title,n.event,n.created,n.seen,n.user_id FROM deliveries d JOIN channels c ON c.id=d.channel_id
          JOIN notices n ON n.id=d.notice_id WHERE d.status='pending' AND d.next_at<=? ORDER BY d.next_at LIMIT 20""", (now(),)).fetchall()
        hour = dt.datetime.now(ZoneInfo(db.setting(c, 'space')['timezone'])).hour
    by_channel = {}
    for row in rows:
        by_channel.setdefault(row['channel_id'], []).append(row)

    def deliver_channel(channel_rows):
        for row in channel_rows:
            with connect() as c:
                if not row['enabled']:
                    c.execute("UPDATE deliveries SET status='skipped' WHERE id=?", (row['id'],))
                    continue
                if row['event'] != 'test':
                    if row['event'] == 'chat' and row['seen']:
                        c.execute("UPDATE deliveries SET status='skipped' WHERE id=?", (row['id'],))
                        continue
                    if quiet(hour, row['quiet_start'], row['quiet_end']):
                        c.execute('UPDATE deliveries SET next_at=? WHERE id=?', (now() + 300, row['id']))
                        continue
                    recent = c.execute("SELECT max(sent_at) FROM deliveries WHERE channel_id=? AND status='sent'", (row['channel_id'],)).fetchone()[0]
                    if recent and now() - recent < row['interval']:
                        c.execute('UPDATE deliveries SET next_at=? WHERE id=?', (recent + row['interval'], row['id']))
                        continue
                if not c.execute("UPDATE deliveries SET status='sending',attempts=attempts+1 WHERE id=? AND status='pending'", (row['id'],)).rowcount:
                    continue
            cutoff = now()
            try:
                # 回退：用途分离之前的渠道配置是用主密钥直接加密的
                config = json.loads(decrypt_with_fallback(PURPOSE_CHANNEL_CONFIG, row['config'].encode()))
                title = row['title']
                if row['event'] == 'chat':
                    # 合并通知：按「发送开始前」累计的未读聊天数生成文案（与 merged 口径一致）
                    with connect() as c:
                        cnt = c.execute("SELECT count(*) FROM notices WHERE user_id=? AND event='chat' AND seen=0 AND created<=?",
                                        (row['user_id'], cutoff)).fetchone()[0]
                    title = f'你有 {cnt} 条新消息'
                notifications.send(row['kind'], config, title, '打开你们的恋爱空间查看详情。', row['id'])
                with connect() as c:
                    c.execute("UPDATE deliveries SET status='sent',sent_at=?,error=NULL WHERE id=?", (now(), row['id']))
                    if row['event'] == 'chat':
                        # 与 push/webpush 相同口径：只合并「发送开始前」已入队的消息，
                        # 发送期间新到的消息保留，避免慢渠道（15s 超时）吞掉后续通知。
                        c.execute("""UPDATE deliveries SET status='merged' WHERE channel_id=? AND status='pending'
                          AND notice_id IN (SELECT id FROM notices WHERE event='chat' AND created<=?)""", (row['channel_id'], cutoff))
            except Exception as e:
                # Never persist exception strings: provider URLs can contain credentials.
                attempts = row['attempts'] + 1
                with connect() as c:
                    c.execute('UPDATE deliveries SET status=?,next_at=?,error=? WHERE id=?',
                              ('failed' if attempts >= 4 else 'pending', now() + min(3600, 60 * 2 ** attempts),
                               '发送失败（' + type(e).__name__ + '），请检查渠道配置、网络和额度', row['id']))

    # 串行投递（原来是 12 线程池）：并发写同一个 SQLite 库是 SQLITE_BUSY 的头号来源，
    # 而这里是两个人的空间、通常只有两三个渠道，并发带来的收益是 0，风险却是实打实的。
    for group in by_channel.values():
        deliver_channel(group)


def deliver_pushes():
    """Retry the built-in per-account push channel through a durable outbox."""
    with connect() as c:
        rows = c.execute('''SELECT p.*,n.event,n.created AS notice_created,n.seen FROM push_outbox p
          JOIN notices n ON n.id=p.notice_id WHERE p.status='pending' AND p.next_at<=?
          ORDER BY p.next_at LIMIT 20''', (now(),)).fetchall()
    for row in rows:
        with connect() as c:
            if row['seen']:
                c.execute("UPDATE push_outbox SET status='skipped' WHERE id=? AND status='pending'", (row['id'],))
                continue
            if not c.execute("UPDATE push_outbox SET status='sending',attempts=attempts+1 WHERE id=? AND status='pending'", (row['id'],)).rowcount:
                continue
        cutoff = now()
        try:
            host = os.getenv('NTFY_SERVER', 'https://ntfy.350921.xyz')
            title = '你有新的聊天消息' if row['event'] == 'chat' else row['title']
            notifications.send('ntfy', {'host': host, 'topic': row['topic']}, title,
                               '打开恋爱空间查看详情。', row['id'])
            with connect() as c:
                c.execute("UPDATE push_outbox SET status='sent',sent_at=?,error=NULL WHERE id=?", (now(), row['id']))
                if row['event'] == 'chat':
                    c.execute('''UPDATE push_outbox SET status='merged' WHERE user_id=? AND status='pending'
                      AND notice_id IN (SELECT id FROM notices WHERE event='chat' AND created<=?)''',
                              (row['user_id'], cutoff))
        except Exception as e:
            attempts = row['attempts'] + 1
            with connect() as c:
                c.execute('UPDATE push_outbox SET status=?,next_at=?,error=? WHERE id=?',
                          ('failed' if attempts >= 6 else 'pending', now() + min(3600, 30 * 2 ** attempts),
                           '推送失败（' + type(e).__name__ + '），稍后重试', row['id']))


def deliver_webpushes():
    """Deliver generic browser notifications with per-device durable retries."""
    from . import webpush as webpush_service
    with connect() as c:
        rows = c.execute('''SELECT o.*,s.payload,n.event,n.created AS notice_created,n.seen,n.user_id
          FROM webpush_outbox o
          JOIN webpush_subscriptions s ON s.id=o.subscription_id
          JOIN notices n ON n.id=o.notice_id
          WHERE o.status='pending' AND o.next_at<=?
          ORDER BY o.next_at LIMIT 40''', (now(),)).fetchall()
    by_subscription = {}
    for row in rows:
        by_subscription.setdefault(row['subscription_id'], []).append(row)

    def deliver_device(device_rows):
        for row in device_rows:
            with connect() as c:
                if row['seen']:
                    c.execute("UPDATE webpush_outbox SET status='skipped' WHERE id=? AND status='pending'", (row['id'],))
                    continue
                if not c.execute("UPDATE webpush_outbox SET status='sending',attempts=attempts+1 WHERE id=? AND status='pending'", (row['id'],)).rowcount:
                    continue
            cutoff = now()
            try:
                subscription = webpush_service.validate_subscription(webpush_service.open_subscription(row['payload']))
                body = '你有一条新的提醒，打开空间查看。'
                if row['event'] == 'chat':
                    with connect() as c:
                        cnt = c.execute("SELECT count(*) FROM notices WHERE user_id=? AND event='chat' AND seen=0 AND created<=?",
                                        (row['user_id'], cutoff)).fetchone()[0]
                    body = f'你有 {cnt} 条新消息'
                webpush_service.send(subscription, {
                    'title': '恋爱空间',
                    'body': body,
                    'url': '/#notices',
                    'tag': 'love-' + row['notice_id'][:24],
                })
                with connect() as c:
                    c.execute("UPDATE webpush_outbox SET status='sent',sent_at=?,error=NULL WHERE id=?",
                              (now(), row['id']))
                    if row['event'] == 'chat':
                        c.execute('''UPDATE webpush_outbox SET status='merged' WHERE subscription_id=? AND status='pending'
                          AND notice_id IN (SELECT id FROM notices WHERE event='chat' AND created<=?)''',
                                  (row['subscription_id'], cutoff))
            except Exception as exc:
                status_code = getattr(exc, 'status_code', None)
                with connect() as c:
                    if status_code in (404, 410):
                        c.execute('DELETE FROM webpush_subscriptions WHERE id=?', (row['subscription_id'],))
                        continue
                    attempts = row['attempts'] + 1
                    c.execute('UPDATE webpush_outbox SET status=?,next_at=?,error=? WHERE id=?',
                              ('failed' if attempts >= 6 else 'pending',
                               now() + min(3600, 30 * 2 ** attempts),
                               '浏览器推送失败（' + type(exc).__name__ + '），稍后重试', row['id']))

    # 同上：串行，避免并发写库
    for device in by_subscription.values():
        deliver_device(device)


def remove_media(c, media):
    folder = db.media_dir(media['zone'], media['mime'], media['created'])
    for name in (media['id'] + media['ext'], media['preview']):
        if name:
            (folder / name).unlink(missing_ok=True)
    c.execute('DELETE FROM media WHERE id=?', (media['id'],))


def cleanup():
    """定时清理。

    2.4.11 裁定：回收站永不自动删除——records 的 30 天硬删与 period.purge_deleted
    调用均已移除。彻底删除只能由作者本人走 purge 接口手动触发。
    """
    with storage_lock, connect() as c:
        # 已读通知保留 90 天后回收；三张投递队列表对 notice 外键级联删除，一并清理
        c.execute('DELETE FROM notices WHERE seen=1 AND created<?', (now() - 90 * 86400,))
        # 「在用」的附件集合。**含软删记录**（回收站里的附件永不回收——护栏测试钉死）。
        # 非私密记录 body 是明文 JSON 直接解析；私密记录整体密封才需 body_decode。
        placeholders = ','.join('?' * len(db.PRIVATE))
        private = tuple(db.PRIVATE)
        used = set()
        for (body,) in c.execute(f'SELECT body FROM records WHERE kind NOT IN ({placeholders})', private):
            parsed = json.loads(body)
            used.update(parsed.get('media', []))
            # 裁定3：body.song.mid 纳入在用集合（引用即在用）——避免手动 purge 掉
            # 歌曲记录后，聊天里的歌曲分享被孤儿清理误删。定区不纳入（由 music 记录定）。
            song = parsed.get('song')
            if isinstance(song, dict) and song.get('mid'):
                used.add(song['mid'])
        for row in c.execute(f'SELECT id,kind,body FROM records WHERE kind IN ({placeholders})', private):
            body = db.body_decode(row)
            used.update(body.get('media', []))
            song = body.get('song')
            if isinstance(song, dict) and song.get('mid'):
                used.add(song['mid'])
        space = db.setting(c, 'space', {})
        used.add(space.get('cover', ''))
        used.update(db.chat_bg_media_ids(space))
        used.update(row[0] for row in c.execute('SELECT avatar FROM users'))
        used.update(db.pose_ai_media_ids(c))
        # 未关联进任何记录/头像/封面的孤儿附件（上传后放弃发布）：24 小时后回收
        # status='processing' 的正在被转码线程持有，删了就会让它白干一场并把结果写进空气
        for media in c.execute("SELECT * FROM media WHERE attached=0 AND status!='processing' AND created<?", (now() - 86400,)).fetchall():
            if media['id'] not in used:
                remove_media(c, media)
        # 其余失去引用的媒体（如记录彻底删除后）：30 天兜底回收
        for media in c.execute("SELECT * FROM media WHERE status!='processing' AND created<?", (now() - 30 * 86400,)).fetchall():
            if media['id'] not in used:
                remove_media(c, media)
    for path in (db.DATA / 'tmp').glob('*.zip'):
        if now() - path.stat().st_mtime > 86400:
            path.unlink(missing_ok=True)
    # tempfile.TemporaryDirectory 的清理只在正常退出时执行；备份/导出中途抛异常
    # （如磁盘满）会留下 tmpXXXXXX/ 目录，每个约 780K（love.db + period.db 快照）。
    # 2026-11-07 一次备份风暴就堆了 117 个、89M。这里连同子目录一起清。
    tmp_root = db.DATA / 'tmp'
    try:
        for entry in tmp_root.iterdir():
            if not entry.is_dir() or not entry.name.startswith('tmp'):
                continue
            try:
                if now() - entry.stat().st_mtime > 3600:
                    shutil.rmtree(entry, ignore_errors=True)
                    log.warning('清理残留临时目录 %s', entry.name)
            except OSError:
                continue
    except OSError:
        pass
    # 备份残包兜底清理：失败的备份会留下 .partial，正常情况下 finally 里已经删了，
    # 但磁盘写满时连 unlink 都可能失败。这里把超过 1 小时的残包一律清掉，
    # 避免 2026-11-07 那种「每个残包近 1GB、堆到 31G 吃满磁盘」的事故重演。
    for path in (db.DATA / 'backups').glob('*.partial'):
        try:
            if now() - path.stat().st_mtime > 3600:
                path.unlink(missing_ok=True)
                log.warning('清理残留备份包 %s', path.name)
        except OSError:
            pass


def maintenance():
    schedule()
    cleanup()
    # 2.8.0 定位守护：peer 轨迹/事件 15 天滚动删除（拍板口径；created 索引，
    # 无匹配行时代价接近零）
    with connect() as c:
        peer.cleanup_expired(c, now())
        # 观察行（2.8.0 修复令四）：本条只用于证明清理步骤确实执行（删除 0 条
        # 也留痕），不参与任何判定，也不改保留期口径。
        # 用 WARNING 是因为容器内 root logger 为 WARNING、应用 logger 未配级别，
        # log.info 不会落进 docker logs（实测：投放夹入库的 info 从未出现）。
        log.warning('维护：peer 滚动清理已执行')
    with connect() as c:
        last = db.setting(c, 'last_backup', now())
        if db.setting(c, 'last_backup') is None:
            db.set_setting(c, 'last_backup', last - 86400)
        initialized = c.execute('SELECT count(*) FROM users').fetchone()[0] > 0
    if initialized and now() - last >= 86400:
        try:
            create_backup()
        except BackupRefused as exc:
            # 没设口令 / 磁盘不足 —— 配置或环境问题，不是故障；每天提醒一次，别刷屏
            log.warning('%s', exc)
            # 🔴 同样要退避：磁盘不足时若不推进 last_backup，maintenance 每分钟
            # 重试一次，虽然预检已能拦住写包，但每次都白扫一遍媒体目录、每次都
            # 尝试写一条 notice。退避 1 小时后重试，给清理腾出空间的时间。
            with connect() as c:
                db.set_setting(c, 'last_backup', now() - 86400 + BACKUP_RETRY_AFTER)
                day = dt.datetime.now(dt.timezone.utc).date().isoformat()
                db.notice(c, 'backup', '未设置备份密码，已跳过备份：请在服务器环境变量里配置 BACKUP_PASSWORD',
                          dedupe='backup-no-password:' + day)
        except Exception as exc:
            # 通知里只能说人话，真实原因（磁盘满 / 权限 / 密钥损坏）进日志
            log.exception('自动备份失败')
            # 🔴 失败也要推进 last_backup，否则 maintenance 每分钟重跑一遍、
            # 每次都写一个近 1GB 的残包 —— 2026-11-07 磁盘就是这么被吃满 31G 的。
            # 但也不能直接推 24 小时（那等于放弃当天的自动备份），
            # 这里退避 1 小时：既止住风暴，又给磁盘/权限问题留出自愈机会。
            with connect() as c:
                db.set_setting(c, 'last_backup', now() - 86400 + BACKUP_RETRY_AFTER)
                day = dt.datetime.now(dt.timezone.utc).date().isoformat()
                db.notice(c, 'backup', f'自动备份失败（{type(exc).__name__}），请检查存储和目录权限',
                          dedupe='backup-failed:' + day)


def run(stop):
    with connect() as c:
        # An interrupted request may already have reached a provider. Do not blindly resend it.
        c.execute("UPDATE deliveries SET status='failed',error='服务重启前发送结果未知，请先检查渠道收件情况' WHERE status='sending'")
        # Push providers accept idempotency keys; retry unknown sends after a delay.
        c.execute("UPDATE push_outbox SET status='pending',next_at=? WHERE status='sending'", (now() + 60,))
        c.execute("UPDATE webpush_outbox SET status='pending',next_at=? WHERE status='sending'", (now() + 60,))
    requeue_stuck_media()

    def media_loop():
        while not stop.is_set():
            try:
                process_media(stop)
            except TranscodeAborted:
                break
            except Exception:
                log.exception('Media processing failed')
            stop.wait(2)

    media_thread = threading.Thread(target=media_loop, daemon=True, name='media-loop')
    media_thread.start()
    # 2.6.0 性能段 P2：周期任务改墙钟门控——原 counter%N 按「循环计数」计时，
    # 而每条聊天/记录创建都会 nudge() 提前唤醒主循环：越聊 counter 转速越高，
    # 名义 60s 的 maintenance 可能十几秒就跑一轮（与 P1 全表扫描互为乘数）。
    # 现在按 last_run 时间戳到期才跑；last_run=None（首次启动）立即跑一次，
    # 保留「启动即跑」语义。nudge 只加速投递（deliver 三件套每轮执行，不变）。
    periodic = {'maintenance': (60.0, 0.0), 'habit': (30.0, 0.0), 'music_drop': (300.0, 0.0)}
    try:
        while not stop.is_set():
            try:
                t = now()
                if t - periodic['maintenance'][1] >= periodic['maintenance'][0]:
                    periodic['maintenance'] = (60.0, t)
                    maintenance()
                # 共同打卡提醒：30s 查一次就够（20 点整后最迟半分钟送达），
                # dedupe 保证同一天同一个人只提醒一次，重复跑没有副作用
                if t - periodic['habit'][1] >= periodic['habit'][0]:
                    periodic['habit'] = (30.0, t)
                    habit_reminders()
                # 2.4.12 投放入库：5 分钟一轮（墙钟口径，≤5 分钟不变）
                if t - periodic['music_drop'][1] >= periodic['music_drop'][0]:
                    periodic['music_drop'] = (300.0, t)
                    from .music_drop import scan_once
                    result = scan_once()
                    if result['imported']:
                        log.info('投放夹入库 %d 首，跳过 %d，失败 %d',
                                 result['imported'], result['skipped'], result['failed'])
                deliver()
                deliver_pushes()
                deliver_webpushes()
            except Exception:
                log.exception('Scheduled task failed')
            # 基础节奏 5s；请求线程 nudge() 可立即唤醒，聊天推送即时出队
            wake.wait(5)
            wake.clear()
    finally:
        # 转码线程看到 stop 后会 kill 掉 ffmpeg 再退出；等它一小会儿，
        # 免得 docker stop 在 ffmpeg 写文件写到一半时把进程干掉
        media_thread.join(timeout=15)
        if media_thread.is_alive():
            log.warning('转码线程 15s 内未退出，放弃等待')


if __name__ == '__main__':
    db.init()
    cipher()
    run(threading.Event())
