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
from .db import connect, dumps, now
from . import period
from .security import PURPOSE_CHANNEL_CONFIG, cipher, decrypt_with_fallback
from .backups import BackupRefused, create_backup, storage_lock
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


MEDIA_TIMEOUT = 300  # 单次 ffmpeg 转码上限：300s 还转不完的视频，本就该先压缩再传
MEDIA_POSTER_TIMEOUT = 120


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


def finish_media(row, status, preview=None, error=None):
    """写回转码结果。行已被删（cleanup 抢跑）时不静默成功，要记日志并清掉孤儿文件。"""
    with connect() as c:
        cur = c.execute('UPDATE media SET status=?,preview=?,error=? WHERE id=? AND status=?',
                        (status, preview or '', error, row['id'], 'processing'))
        if cur.rowcount == 0:
            log.warning('附件 %s 在转码期间已不存在，结果丢弃（status=%s）', row['id'], status)
            if preview:
                (db.media_dir(row['mime'], row['created']) / preview).unlink(missing_ok=True)
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
    folder = db.media_dir(row['mime'], row['created'])
    path = folder / (row['id'] + row['ext'])
    preview = None
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
            preview = row['id'] + ('.preview.mp4' if video else '.preview.m4a')
            args = ['ffmpeg', '-y', '-i', str(path), '-map_metadata', '-1']
            if video:
                args += ['-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2', '-c:v', 'libx264', '-preset', 'fast', '-crf', '25', '-pix_fmt', 'yuv420p']
            else:
                args += ['-vn']
            args += ['-c:a', 'aac', '-movflags', '+faststart', str(folder / preview)]
            run_ffmpeg(args, MEDIA_TIMEOUT, stop)
            if video:
                # 抽首帧作为封面缩略图（前端列表用）；失败只影响封面，不影响视频转码结果
                poster = folder / (row['id'] + '.preview.jpg')
                try:
                    run_ffmpeg(['ffmpeg', '-y', '-i', str(path), '-frames:v', '1',
                                '-vf', 'scale=640:-2', str(poster)], MEDIA_POSTER_TIMEOUT, stop)
                except Exception:
                    # 封面失败只影响列表缩略图，视频本身已经转好了，不值得把整条任务判失败
                    log.debug('附件 %s 封面抽取失败', row['id'], exc_info=True)
                    poster.unlink(missing_ok=True)
        else:
            finish_media(row, 'original', error='未安装 FFmpeg，保留原文件播放')
            return
        finish_media(row, 'ready', preview=preview)
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
        finish_media(row, 'original', error='预览转换失败（%s），原文件仍保留' % type(exc).__name__)


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
        for row in c.execute('SELECT * FROM records WHERE deleted IS NULL').fetchall():
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
    folder = db.media_dir(media['mime'], media['created'])
    for name in (media['id'] + media['ext'], media['preview']):
        if name:
            (folder / name).unlink(missing_ok=True)
    c.execute('DELETE FROM media WHERE id=?', (media['id'],))


def cleanup():
    with storage_lock, connect() as c:
        c.execute('DELETE FROM records WHERE deleted IS NOT NULL AND deleted<?', (now() - 30 * 86400,))
        # 生理期在独立的 period.db 里，回收站期限与主库保持一致
        try:
            period.purge_deleted(now() - 30 * 86400)
        except Exception:
            logging.getLogger('love').exception('清理生理期回收站失败')
        # 已读通知保留 90 天后回收；三张投递队列表对 notice 外键级联删除，一并清理
        c.execute('DELETE FROM notices WHERE seen=1 AND created<?', (now() - 90 * 86400,))
        # 「在用」的附件集合。注意**不能**只挑 deleted IS NULL 的记录：软删除后
        # 30 天内还能恢复，它们的附件必须继续算在用，否则恢复出来是一片空白。
        # 这里只优化代价：非私密记录的 body 是明文 JSON，直接解析即可；
        # 私密记录整体密封，才需要 body_decode（读 secret.key + AES-GCM）。
        placeholders = ','.join('?' * len(db.PRIVATE))
        private = tuple(db.PRIVATE)  # sqlite3 只吃序列，不吃 set
        used = set()
        for (body,) in c.execute(f'SELECT body FROM records WHERE kind NOT IN ({placeholders})', private):
            used.update(json.loads(body).get('media', []))
        for row in c.execute(f'SELECT id,kind,body FROM records WHERE kind IN ({placeholders})', private):
            used.update(db.body_decode(row).get('media', []))
        space = db.setting(c, 'space', {})
        used.add(space.get('cover', ''))
        used.update(db.chat_bg_media_ids(space))
        used.update(row[0] for row in c.execute('SELECT avatar FROM users'))
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


def maintenance():
    schedule()
    cleanup()
    with connect() as c:
        last = db.setting(c, 'last_backup', now())
        if db.setting(c, 'last_backup') is None:
            db.set_setting(c, 'last_backup', last - 86400)
        initialized = c.execute('SELECT count(*) FROM users').fetchone()[0] > 0
    if initialized and now() - last >= 86400:
        try:
            create_backup()
        except BackupRefused as exc:
            # 没设口令是配置问题，不是故障；每天提醒一次，别刷屏
            log.warning('%s', exc)
            with connect() as c:
                day = dt.datetime.now(dt.timezone.utc).date().isoformat()
                db.notice(c, 'backup', '未设置备份密码，已跳过备份：请在服务器环境变量里配置 BACKUP_PASSWORD',
                          dedupe='backup-no-password:' + day)
        except Exception as exc:
            # 通知里只能说人话，真实原因（磁盘满 / 权限 / 密钥损坏）进日志
            log.exception('自动备份失败')
            with connect() as c:
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
    counter = 0
    try:
        while not stop.is_set():
            try:
                if counter % 12 == 0:
                    maintenance()
                deliver()
                deliver_pushes()
                deliver_webpushes()
            except Exception:
                log.exception('Scheduled task failed')
            counter += 1
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
