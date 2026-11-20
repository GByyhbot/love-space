#!/usr/bin/env python3
"""媒体 zone 迁移反向脚本（仅交付，不执行）。

按 data/media-zone-migration-<YYYYMMDD>.json 的 (id, name, from, to) 条目，
把文件从 zone 目录搬回旧布局（media/<image|video|audio>/<YYYY-MM>/）。

用法：
    python scripts/rollback_media_zones.py [manifest路径]

安全约束：
· 只搬文件、不删文件；目标已存在不覆盖（与正向迁移同款）；
· 逐条 is_file() 检查，磁盘上已不存在的文件跳过并计数；
· 默认 DRY RUN——加 --apply 才真搬；
· 不修改数据库 zone 字段（回滚镜像后旧后端按旧布局找文件，zone 列被忽略）。
"""
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = Path(os.environ.get('DATA_DIR', ROOT / 'data')).resolve()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    apply = '--apply' in sys.argv
    manifest = Path(args[0]) if args else next(
        sorted(DATA.glob('media-zone-migration-*.json'), reverse=True), None)
    if manifest is None or not manifest.is_file():
        print('找不到 manifest：%s' % manifest)
        return 1
    entries = json.loads(manifest.read_text(encoding='utf-8'))
    moved = skipped = missing = 0
    for e in entries:
        src = DATA / e['to']
        dst = DATA / e['from']
        if not src.is_file():
            missing += 1
            continue
        if dst.exists():
            skipped += 1
            continue
        print('%s %s -> %s' % ('搬' if apply else '预演', e['to'], e['from']))
        if apply:
            dst.parent.mkdir(parents=True, exist_ok=True)
            src.rename(dst)
            moved += 1
    print('合计 %d 条：%s %d，目标已存在跳过 %d，源缺失 %d' %
          (len(entries), '已搬' if apply else '待搬', moved, skipped, missing))
    if not apply:
        print('（DRY RUN，加 --apply 才真搬）')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
