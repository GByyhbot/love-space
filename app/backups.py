import datetime as dt
import html
import json
import os
import shutil
import sqlite3
import tempfile
import threading
import zipfile
from pathlib import Path

from . import db
from .db import connect, dumps, now
from . import period
from .serializers import serialize  # 不再走 main，避免 main ↔ backups 循环导入

storage_lock = threading.RLock()

_ENC_MAGIC = b'LOVEENC1\n'
# v1：包内是裸 secret.key；v2：secret.key 也用备份口令加密成 secret.key.enc
MANIFEST_VERSION = 2
LEGACY_MANIFEST_VERSIONS = (1,)


class BackupRefused(RuntimeError):
    """没有备份口令，拒绝生成任何备份包。

    fail-closed：以前 password 为空会原样落一个**明文** zip，而包里还带着
    secret.key —— 一份备份被拷走 = 全部私密历史不可逆外泄。宁可这次不备份。
    """


def backup_password():
    return os.getenv('BACKUP_PASSWORD', '')


def _aesgcm_key(password: str, salt: bytes):
    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
    from cryptography.hazmat.primitives import hashes
    return PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt,
                      iterations=480000).derive(password.encode())


def encrypt_bytes(data: bytes, password: str) -> bytes:
    """AES-GCM：magic + salt(16) + nonce(12) + ciphertext（salt 兼作 AAD）。"""
    import base64
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    salt, nonce = os.urandom(16), os.urandom(12)
    encrypted = AESGCM(_aesgcm_key(password, salt)).encrypt(nonce, data, salt + _ENC_MAGIC)
    return _ENC_MAGIC + base64.b64encode(salt) + b'\n' + base64.b64encode(nonce) + b'\n' + encrypted


def decrypt_blob(raw: bytes, password: str) -> bytes:
    import base64
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    if not raw.startswith(_ENC_MAGIC):
        raise ValueError('不是加密的恋爱空间备份')
    try:
        _, salt_b64, nonce_b64, ciphertext = raw.split(b'\n', 3)
        salt, nonce = base64.b64decode(salt_b64), base64.b64decode(nonce_b64)
    except ValueError:
        raise ValueError('加密备份文件已损坏')
    try:
        return AESGCM(_aesgcm_key(password, salt)).decrypt(nonce, ciphertext, salt + _ENC_MAGIC)
    except Exception:
        raise ValueError('解密失败：备份密码不正确')


def encrypt_file(source: Path, password: str) -> Path:
    target = source.with_suffix('.zip.enc')
    target.write_bytes(encrypt_bytes(source.read_bytes(), password))
    return target


def decrypt_bytes(source: Path, password: str) -> bytes:
    return decrypt_blob(source.read_bytes(), password)


def is_encrypted(path: Path) -> bool:
    try:
        with open(path, 'rb') as f:
            return f.read(len(_ENC_MAGIC)) == _ENC_MAGIC
    except OSError:
        return False


def _estimate_backup_bytes(backups_dir: Path) -> int:
    """估算一次备份要占多少空间，用于写之前预检。

    构成：媒体文件总大小（zip 里基本压不动，图片/视频已是压缩格式）
    + 数据库（压缩后很小，按 10MB 粗估）+ 50MB 余量兜底。
    媒体目录扫不出来（权限/不存在）时给个保守的 2GB，宁可拒绝也不写爆磁盘。"""
    media_total = 0
    try:
        for sub in ('media', 'bubbles'):
            folder = db.DATA / sub
            if not folder.is_dir():
                continue
            for path in folder.rglob('*'):
                try:
                    if path.is_file():
                        media_total += path.stat().st_size
                except OSError:
                    continue
    except OSError:
        return 2 * 1024 ** 3
    return media_total + 10 * 1048576 + 50 * 1048576


def create_backup():
    with storage_lock:
        password = backup_password()
        if not password:
            # 明文备份包里还带着 secret.key，等于把整部私密历史的钥匙一起打包。
            # 没有口令就不备份——静悄悄生成明文包比不备份危险得多。
            raise BackupRefused('未设置 BACKUP_PASSWORD，已跳过本次备份')
        target = db.DATA / 'backups' / ('backup-' + dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d-%H%M%S-') + db.uid()[:6] + '.zip')
        temp_target = target.with_suffix('.partial')
        # 空间预检：备份包约等于「数据库 + 全部媒体」的体积，压缩后通常略小。
        # 曾在磁盘写满时留下 33 个 ~1GB 的 .partial 把 31G 吃干（2026-11-07），
        # 所以宁可提前拒绝，也不要写到一半失败。
        need = _estimate_backup_bytes(target.parent)
        avail = shutil.disk_usage(target.parent).free
        if avail < need:
            raise BackupRefused(
                f'磁盘空间不足，已跳过备份：需要约 {need // 1048576}MB，'
                f'仅剩 {avail // 1048576}MB')
        with tempfile.TemporaryDirectory(dir=db.DATA / 'tmp') as tmp:
            snapshot = Path(tmp) / 'love.db'
            with connect() as source:
                destination = sqlite3.connect(snapshot)
                try:
                    source.backup(destination)
                finally:
                    destination.close()
            # 生理期在独立的 period.db：备份必须把它一起带走，否则"恢复出来的世界"
            # 会凭空少掉一个人的全部周期记录。老版本留下的包没有这个文件，照常恢复。
            period_snapshot = Path(tmp) / 'period.db'
            has_period = period.db_path().is_file()
            if has_period:
                period.copy_file(period_snapshot)
            try:
                with zipfile.ZipFile(temp_target, 'w', zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
                    archive.write(snapshot, 'love.db')
                    if has_period:
                        archive.write(period_snapshot, 'period.db')
                    # 主密钥单独再加密一遍：外层整包加密防止"备份被拷走即可读"，
                    # 这一层保证即使有人只拿到包内文件，也解不开私密记录
                    archive.writestr('secret.key.enc',
                                     encrypt_bytes((db.DATA / 'secret.key').read_bytes(), password))
                    archive.writestr('manifest.json', dumps({'version': MANIFEST_VERSION, 'created': now()}))
                    reader = sqlite3.connect(snapshot)
                    try:
                        media_rows = reader.execute('SELECT id,ext,preview,mime,created FROM media').fetchall()
                    finally:
                        reader.close()
                    for mid, ext, preview, mime, created in media_rows:
                        folder = db.media_dir(mime, created)
                        for filename in (mid + ext, preview):
                            if filename and (folder / filename).is_file():
                                archive.write(folder / filename, 'media/' + filename)
                # 口令已在入口校验过，这里必然走加密分支：产物永远是 .zip.enc
                encrypted = encrypt_file(temp_target, password)
                encrypted.replace(target.with_name(target.name + '.enc'))
                target = target.with_name(target.name + '.enc')
                temp_target.unlink(missing_ok=True)
                target.chmod(0o600)
                extra = os.getenv('BACKUP_EXTRA_DIR')
                if extra:
                    extra_dir = Path(extra)
                    extra_dir.mkdir(parents=True, exist_ok=True)
                    extra_tmp = extra_dir / (target.name + '.partial')
                    shutil.copyfile(target, extra_tmp)
                    extra_tmp.replace(extra_dir / target.name)
                    (extra_dir / target.name).chmod(0o600)
                for folder in [target.parent] + ([Path(extra)] if extra else []):
                    for old in sorted(folder.glob('backup-*'), reverse=True)[7:]:
                        old.unlink()
                with connect() as c:
                    db.set_setting(c, 'last_backup', now())
                return target
            finally:
                temp_target.unlink(missing_ok=True)


def user_export(user_id):
    # Build export from the same visibility checks used by the application, never a raw DB dump.
    path = db.DATA / 'tmp' / (db.uid() + '.zip')
    with storage_lock, connect() as c:
        records = [serialize(c, r, user_id) for r in c.execute('SELECT * FROM records ORDER BY created') if db.visible(r, user_id)]
        # 生理期在独立的 period.db：导出「我们的回忆」时不能少掉这一块
        records.extend(period.rows_for(user_id))
        records.sort(key=lambda item: item['created'])
        mids = {mid for r in records for mid in r['body'].get('media', [])}
        users = [{k: u[k] for k in ('id', 'name')} for u in c.execute('SELECT * FROM users')]
        with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
            archive.writestr('records.json', dumps({'version': 1, 'space': db.setting(c, 'space'), 'users': users, 'records': records}))
            sections = []
            for record in records:
                body = record['body']
                content = html.escape(body.get('content', '')).replace('\n', '<br>')
                title = body.get('title', '')
                date = body.get('date', '')
                if record['kind'] == 'period' and body.get('start'):
                    title = title or f"经期 {body['start']}"
                    date = date or body['start']
                attachments = []
                for mid in body.get('media', []):
                    media = c.execute('SELECT * FROM media WHERE id=?', (mid,)).fetchone()
                    # 附件可能已被孤儿清理回收（记录里的引用还在）：导出整包不能因此 500
                    if media:
                        attachments.append(f'<a href="media/{mid}{media["ext"]}">{html.escape(media["name"])}</a>')
                sections.append(f'<article><small>{html.escape(record["kind"])} · {html.escape(date)}</small><h2>{html.escape(title)}</h2><p>{content}</p>{" · ".join(attachments)}</article>')
            archive.writestr('回忆.html', '<!doctype html><meta charset="utf-8"><title>我们的回忆</title><style>body{max-width:800px;margin:40px auto;font:16px/1.8 sans-serif;padding:20px}article{border-bottom:1px solid #ddd;padding:20px 0}small{color:#888}</style><h1>我们的回忆</h1>' + ''.join(sections))
            for mid in mids:
                media = c.execute('SELECT * FROM media WHERE id=?', (mid,)).fetchone()
                if not media:
                    continue
                source = db.media_dir(media['mime'], media['created']) / (mid + media['ext'])
                if source.is_file():
                    archive.write(source, 'media/' + mid + media['ext'])
    return path


def restore_backup(source, destination, password=''):
    destination = Path(destination).resolve()
    if destination.exists() and any(destination.iterdir()):
        raise ValueError('恢复目标必须是新的空目录；停止旧服务后再切换 DATA_DIR')
    destination.mkdir(parents=True, exist_ok=True)
    source = Path(source)
    if is_encrypted(source):
        if not password:
            raise ValueError('该备份已加密，请通过 --password 提供备份密码')
        import tempfile
        with tempfile.TemporaryDirectory(dir=destination.parent) as tmp:
            plain = Path(tmp) / 'decrypted.zip'
            plain.write_bytes(decrypt_bytes(source, password))
            with zipfile.ZipFile(plain) as archive:
                _extract_backup(archive, destination, password)
    else:
        with zipfile.ZipFile(source) as archive:
            _extract_backup(archive, destination, password)
    conn = sqlite3.connect(destination / 'love.db')
    try:
        if conn.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise ValueError('备份数据库完整性检查失败')
        conn.execute('DELETE FROM sessions')
        conn.execute('DELETE FROM invites')
        conn.execute("UPDATE deliveries SET status='failed',error='恢复后暂停历史通知，请按需重试' WHERE status IN ('pending','sending')")
        conn.commit()
    finally:
        conn.close()
    # 生理期分库：老备份里没有这个文件，那就留给启动时的自动迁移去搬（主库里还留着那些行）
    extra_db = destination / 'period.db'
    if extra_db.is_file():
        conn = sqlite3.connect(extra_db)
        try:
            if conn.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                raise ValueError('生理期数据库完整性检查失败')
            conn.commit()
        finally:
            conn.close()
        extra_db.chmod(0o600)
    (destination / 'secret.key').chmod(0o600)
    for folder in ('backups', 'tmp'):
        (destination / folder).mkdir(exist_ok=True)


def _extract_backup(archive, destination, password=''):
    names = set(archive.namelist())
    if 'manifest.json' not in names:
        raise ValueError('不是完整的恋爱空间备份')
    version = json.loads(archive.read('manifest.json')).get('version')
    # v1 的包里是裸 secret.key，v2 起改成 secret.key.enc。两种都要能恢复，
    # 否则升级后会发现自己攒的老备份全成废纸。
    if version == 1:
        required = {'love.db', 'secret.key', 'manifest.json'}
    elif version == MANIFEST_VERSION:
        required = {'love.db', 'secret.key.enc', 'manifest.json'}
    else:
        raise ValueError('不支持此备份版本')
    if not required.issubset(names):
        raise ValueError('不是完整的恋爱空间备份')
    if version == MANIFEST_VERSION and not password:
        # 必须在落盘前就问口令，别解压一半才发现解不开
        raise ValueError('这份备份的主密钥是加密的，请提供备份密码')
    for item in archive.infolist():
        name = item.filename
        if name not in {'love.db', 'period.db', 'secret.key', 'secret.key.enc', 'manifest.json'} and not name.startswith('media/'):
            raise ValueError('备份包含未知文件')
        if not (destination / name).resolve().is_relative_to(destination) or '\\' in name:
            raise ValueError('备份路径不安全')
    if sum(i.file_size for i in archive.infolist()) > shutil.disk_usage(destination).free:
        raise ValueError('恢复空间不足')
    archive.extractall(destination)
    if version == MANIFEST_VERSION:
        enc = destination / 'secret.key.enc'
        (destination / 'secret.key').write_bytes(decrypt_blob(enc.read_bytes(), password))
        enc.unlink()
        (destination / 'secret.key').chmod(0o600)
