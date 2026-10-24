"""恋爱空间管理命令：备份恢复与迁移。

用法：
    python -m app.manage backup                    # 立即创建备份（设置 BACKUP_PASSWORD 时自动加密）
    python -m app.manage restore <备份> <目标目录> [--password <密码>]
    python -m app.manage decrypt <备份.enc> <输出.zip> --password <密码>
"""
import argparse


def main():
    parser = argparse.ArgumentParser(prog='python -m app.manage', description='恋爱空间管理命令')
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('backup', help='立即创建一份完整备份（数据库+媒体+密钥；设置 BACKUP_PASSWORD 环境变量后自动加密）')
    restore = sub.add_parser('restore', help='将备份恢复到一个新的空目录，用于恢复或迁移')
    restore.add_argument('source', help='备份文件路径（zip 或加密的 .enc）')
    restore.add_argument('destination', help='恢复目标目录（必须为空或不存在）')
    restore.add_argument('--password', default='', help='备份密码（加密备份必填）')
    decrypt = sub.add_parser('decrypt', help='将加密备份解密为普通 zip')
    decrypt.add_argument('source', help='加密备份 .enc 文件路径')
    decrypt.add_argument('output', help='输出 zip 文件路径')
    decrypt.add_argument('--password', required=True, help='备份密码')
    args = parser.parse_args()

    if args.command == 'backup':
        from .backups import create_backup
        path = create_backup()
        print('备份完成:', path)
    elif args.command == 'restore':
        from .backups import restore_backup
        restore_backup(args.source, args.destination, args.password)
        print('恢复完成:', args.destination)
        print('下一步：停止旧服务，将 DATA_DIR 指向该目录后重新启动。')
    elif args.command == 'decrypt':
        from pathlib import Path
        from .backups import decrypt_bytes
        output = Path(args.output)
        output.write_bytes(decrypt_bytes(Path(args.source), args.password))
        print('解密完成:', output)


if __name__ == '__main__':
    main()
