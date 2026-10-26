"""把记录导出成 Markdown 知识库（"恋爱第二大脑"）。

产物是普通的文件夹树，丢进 Obsidian / Logseq / VSCode 就能直接读：

    恋爱空间-第二大脑/
      README.md                总索引（统计 + 用法 + 隐私说明）
      索引/按月份.md
      索引/按类型.md
      2026/10/2026-10-26-1830-时光动态-第一次看海.md
      2026/10/2026-10-26-聊天记录.md
      media/2026-10-26-<mediaid>.jpg

设计约束（都是踩过的坑）：
- 只导出**当前用户可见**的记录：复用 db.visible + serialize_many，私密日记/草稿/
  惊喜对方看不见就绝不会出现在包里。
- personal_wish 的 sealed / readers_sealed 是密文，**绝不落盘**；锁定的心愿只写
  标题 + 一句提示，避免"导出即泄露"。
- 聊天按天合并成一个 md，否则几千条消息会生成几千个小文件，Obsidian 直接卡死。
- 时间统一按东八区（固定 +08:00，中国无夏令时），不依赖系统 tzdata。
"""

import datetime as dt
import posixpath
import re
import zipfile
from pathlib import Path

from . import db
from .db import connect, now, uid
from .serializers import serialize_many

KIND_LABELS = {
    'post': '时光动态', 'diary': '私密日记', 'draft': '草稿', 'surprise': '定时惊喜',
    'anniversary': '纪念日', 'wish': '共同愿望', 'personal_wish': '个人心愿',
    'mood': '每日心情', 'note': '留言板', 'question': '情侣问答', 'habit': '共同打卡',
    'chat': '聊天', 'album': '相册', 'quest': '恋爱清单', 'ledger': '共同账本',
}

# 固定东八区：Debian slim 镜像常常没有 tzdata，用 zoneinfo 会直接抛异常
LOCAL = dt.timezone(dt.timedelta(hours=8))
_ILLEGAL = re.compile(r'[\\/:*?"<>|\x00-\x1f]+')
_TITLE_MENTION = re.compile(r'\[\[([^\[\]]{1,60})\]\]')


def _safe(text, limit=48):
    text = _ILLEGAL.sub('_', str(text or '')).strip().strip('.')
    text = re.sub(r'\s+', ' ', text)
    return (text[:limit].rstrip(' .') or '未命名')


def _local(value):
    """created 是 time.time() 的 float 时间戳；兼容 ISO 字符串（老数据/测试）。"""
    try:
        if isinstance(value, (int, float)):
            return dt.datetime.fromtimestamp(float(value), LOCAL)
        parsed = dt.datetime.fromisoformat(str(value))
    except (TypeError, ValueError):
        return dt.datetime.now(LOCAL)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(LOCAL)


def _title(rec):
    body = rec['body']
    title = str(body.get('title') or '').strip()
    if title:
        return title
    content = str(body.get('content') or '').strip()
    if content:
        return content.splitlines()[0][:40]
    if body.get('emoji'):
        return f"{body['emoji']} 心情"
    return KIND_LABELS.get(rec['kind'], rec['kind'])


def _day(rec):
    date = str(rec['body'].get('date') or '').strip()
    if re.fullmatch(r'\d{4}-\d{2}-\d{2}', date):
        return date
    return _local(rec['created']).strftime('%Y-%m-%d')


def _media_name(day, mid, ext):
    return f'{day}-{mid}{ext}'


def _linkify(text, title_map, current_path):
    """把正文里的 [[标题]] 变成指向对应记录的链接（Obsidian 式双链）。"""
    def repl(match):
        title = match.group(1).strip()
        path = title_map.get(title)
        if not path:
            return match.group(0)
        return f'[{title}]({_rel_prefix(current_path)}{Path(path).name})'
    return _TITLE_MENTION.sub(repl, text)


def _render_record(rec, authors, media_links, prev_next, same_day, path, title_map=None):
    """单条记录的 Markdown 正文。只渲染已知字段，不把内部 JSON 原样倒出来。"""
    body = rec['body']
    kind = rec['kind']
    out = ['---',
           f"title: {_md_yaml(_title(rec))}",
           f"kind: {kind}",
           f"kind_label: {KIND_LABELS.get(kind, kind)}",
           f"date: {_day(rec)}",
           f"author: {_md_yaml(authors.get(rec['author'], '未知'))}",
           f"created: {_local(rec['created']).isoformat(timespec='seconds')}",
           f"record: {rec['id']}",
           '---', '', f"# {_title(rec)}", '']

    if body.get('emoji'):
        out += [f"**心情**：{body['emoji']}", '']
    if str(body.get('content') or '').strip() and kind != 'personal_wish':
        out += [_linkify(str(body['content']).strip(), title_map or {}, path), '']
    if str(body.get('note') or '').strip() and str(body.get('note')) != str(body.get('content')):
        out += [f"> {body['note']}", '']
    if body.get('date'):
        extra = ' （每年重复）' if body.get('annual') else ''
        out += [f"- 日期：{body['date']}{extra}"]
    if kind == 'wish':
        out += [f"- 状态：{'已实现' if body.get('done') else '还在期待'}"]
    if kind == 'quest':
        out += [f"- 状态：{'已完成' if body.get('done') else '还没做'}",
                f"- 分类：{body.get('category') or '日常'}"]
    if kind == 'ledger':
        try:
            amount = float(body.get('amount') or 0)
        except (TypeError, ValueError):
            amount = 0.0
        out += [f'- 金额：¥{amount:.2f}', f"- 分类：{body.get('category') or '其他'}"]
    if kind == 'habit':
        checks = rec.get('checks') or []
        out += [f"- 打卡：{len(checks)} 次"]
        if checks:
            days = '、'.join(sorted({c.get('day', '') for c in checks if c.get('day')}))
            if days:
                out += [f"- 打卡日期：{days}"]
    if kind == 'question':
        answers = rec.get('answers') or []
        if answers:
            out += ['', '## 回答']
            for answer in answers:
                out += [f"**{authors.get(answer.get('author'), '?')}**：{str(answer.get('content') or '').strip()}", '']
        if rec.get('answer_count') is not None and rec.get('answer_count') < 2:
            out += ['> 另一方的回答还没揭晓，导出时只有你自己的答案。', '']
    if kind == 'personal_wish':
        # 带密码的心愿永远只导标题：作者在 App 里能读，但 Markdown 是明文文件，
        # 一旦被拷走/同步到云盘就等于绕过密码保护，这里宁可少导。
        out += ['> 内容受独立密码保护，不写入 Markdown 导出；请在 App 内输入密码查看。', '']

    if out and out[-1] != '':
        out.append('')

    attachments = [media_links[mid] for mid in body.get('media', []) if mid in media_links]
    if attachments:
        out += ['## 附件', '']
        for name, mime in attachments:
            link = _rel('media/' + name, path)
            if str(mime).startswith('image/'):
                out.append(f'![{name}]({link})')
            else:
                out.append(f'- [{name}]({link})')
        out.append('')

    if prev_next:
        out += ['## 同类前后', '']
        for label, other, title in prev_next:
            out.append(f'- {label}：' + (f'[{title}]({_rel(other, path)})' if other else '—'))
        out.append('')

    if same_day:
        out += ['## 同一天', '']
        for other, title in same_day:
            out.append(f'- [{title}]({_rel(other, path)})')
        out.append('')
    return '\n'.join(out)


def _rel(target, current):
    """从 current 文件指到 target 的相对路径（同目录只留文件名）。"""
    return posixpath.relpath(target, posixpath.dirname(current) or '.')


def _linkify(text, title_map, current_path):
    """把正文里的 [[标题]] 变成指向对应记录的链接（Obsidian 式双链）。"""
    def repl(match):
        title = match.group(1).strip()
        path = title_map.get(title)
        if not path:
            return match.group(0)
        return f'[{title}]({_rel(path, current_path)})'
    return _TITLE_MENTION.sub(repl, text)


def _md_yaml(text):
    text = str(text).replace('"', "'").replace('\n', ' ')
    return f'"{text}"'


def _render_chat(day, items, authors, media_links, path):
    out = ['---', f'title: "{day} 聊天记录"', 'kind: chat', 'kind_label: 聊天',
           f'date: {day}', '---', '', f'# {day} 聊天记录', '']
    for rec in sorted(items, key=lambda r: r['created']):
        body = rec['body']
        stamp = _local(rec['created']).strftime('%H:%M')
        who = authors.get(rec['author'], '?')
        if body.get('recalled'):
            out.append(f'**{who} {stamp}**：《撤回了一条消息》')
        elif body.get('sticker'):
            out.append(f'**{who} {stamp}**：_[贴纸] {body["sticker"]}_')
        else:
            text = str(body.get('content') or '').replace('\n', '  \n')
            out.append(f'**{who} {stamp}**：{text}')
        for mid in body.get('media', []):
            if mid in media_links:
                name, mime = media_links[mid]
                link = _rel('media/' + name, path)
                if str(mime).startswith('image/'):
                    out.append(f'![{name}]({link})')
                else:
                    out.append(f'- [{name}]({link})')
        out.append('')
    return '\n'.join(out)


def build_markdown_archive(user_id):
    """生成 zip 并返回路径；调用方负责在响应结束后删除。"""
    target = db.DATA / 'tmp' / (uid() + '-md.zip')
    with connect() as c:
        rows = [row for row in c.execute('SELECT * FROM records ORDER BY created') if db.visible(row, user_id)]
        records = serialize_many(c, rows, user_id)
        authors = {u['id']: u['name'] for u in c.execute('SELECT id,name FROM users')}
        space = db.setting(c, 'space') or {}
        media_rows = {m['id']: dict(m) for m in c.execute('SELECT id,ext,mime,created,name FROM media')}
        media_sources = {}
        for mid, m in media_rows.items():
            source = db.media_dir(m['mime'], m['created']) / (mid + m['ext'])
            if source.is_file():
                media_sources[mid] = source

    # ── 第一遍：排路径 ────────────────────────────────────────────────
    chat_by_day, entries = {}, []
    used = set()
    for rec in records:
        day = _day(rec)
        year, month = day[:4], day[5:7]
        if rec['kind'] == 'chat':
            chat_by_day.setdefault(day, []).append(rec)
            continue
        stamp = _local(rec['created']).strftime('%H%M')
        slug = _safe(_title(rec))
        path = f'{year}/{month}/{day}-{stamp}-{KIND_LABELS.get(rec["kind"], rec["kind"])}-{slug}.md'
        if path in used:
            path = path[:-3] + f'-{rec["id"][:4]}.md'
        used.add(path)
        entries.append({'rec': rec, 'day': day, 'path': path, 'title': _title(rec)})
    for day in chat_by_day:
        path = f'{day[:4]}/{day[5:7]}/{day}-聊天记录.md'
        used.add(path)
        entries.append({'rec': None, 'day': day, 'path': path, 'title': f'{day} 聊天记录'})

    entries.sort(key=lambda e: (e['day'], e['path']))

    # ── 媒体链接表：md 里用到的文件名 → (文件名, mime) ────────────────
    media_links, media_files = {}, []
    for rec in records:
        day = _day(rec)
        for mid in rec['body'].get('media', []):
            m = media_rows.get(mid)
            if not m or mid not in media_sources or mid in media_links:
                continue
            name = _media_name(day, mid, m['ext'])
            media_links[mid] = (name, m['mime'])
            media_files.append((media_sources[mid], 'media/' + name))

    # ── 第二遍：渲染 ──────────────────────────────────────────────────
    files = []
    title_map = {}
    for e in entries:
        if e['rec'] and e['title'] not in title_map:
            title_map[e['title']] = e['path']
    day_index = {}
    for e in entries:
        day_index.setdefault(e['day'], []).append(e)
    kind_entries = {}
    for e in entries:
        if e['rec']:
            kind_entries.setdefault(e['rec']['kind'], []).append(e)

    for e in entries:
        if e['rec'] is None:
            files.append((e['path'], _render_chat(e['day'], chat_by_day[e['day']], authors, media_links, e['path'])))
            continue
        rec = e['rec']
        prev_next = []
        same_kind = kind_entries.get(rec['kind'], [])
        pos = next((i for i, x in enumerate(same_kind) if x['path'] == e['path']), 0)
        if pos > 0:
            prev_next.append(('上一条', same_kind[pos - 1]['path'], same_kind[pos - 1]['title']))
        if pos + 1 < len(same_kind):
            prev_next.append(('下一条', same_kind[pos + 1]['path'], same_kind[pos + 1]['title']))
        same_day = [(x['path'], x['title']) for x in day_index[e['day']] if x['path'] != e['path']]
        files.append((e['path'], _render_record(rec, authors, media_links, prev_next, same_day, e['path'], title_map)))

    # ── 索引 ──────────────────────────────────────────────────────────
    space_name = str(space.get('name') or '我们的恋爱空间')
    counts = {}
    for e in entries:
        label = KIND_LABELS.get(e['rec']['kind'], e['rec']['kind']) if e['rec'] else '聊天'
        counts[label] = counts.get(label, 0) + 1

    month_rows = sorted({e['day'][:7] for e in entries})
    month_lines = ['# 按月份', '']
    for month in month_rows:
        month_lines.append(f'- **{month}** · ' + '、'.join(
            f'[{x["title"]}](../{x["path"]})' for x in entries if x['day'][:7] == month))

    kind_lines = ['# 按类型', '']
    for kind, items in sorted(kind_entries.items(), key=lambda kv: -len(kv[1])):
        kind_lines += [f'## {KIND_LABELS.get(kind, kind)}（{len(items)}）', '']
        kind_lines += [f'- [{x["title"]}](../{x["path"]})' for x in items]
        kind_lines.append('')
    if chat_by_day:
        kind_lines += [f'## 聊天（{len(chat_by_day)} 天）', '']
        kind_lines += [f'- [{d} 聊天记录](../{d[:4]}/{d[5:7]}/{d}-聊天记录.md)' for d in sorted(chat_by_day)]
        kind_lines.append('')

    readme = [
        f'# {space_name} · 恋爱第二大脑', '',
        f'生成时间：{dt.datetime.now(LOCAL).strftime("%Y-%m-%d %H:%M")}（东八区）', '',
        '## 这是什么', '',
        '把两个人写下的记录导出成纯 Markdown。没有数据库、没有专用软件，', '用任何文本编辑器都能打开，也可以直接拖进 Obsidian / Logseq 当知识库。', '',
        '## 统计', '',
        f'- 记录总数：{len([e for e in entries if e["rec"]])}',
        f'- 聊天天数：{len(chat_by_day)}',
        f'- 附件：{len(media_files)} 个（都在 `media/`，文件按"日期-附件ID"命名）',
        '', '| 类型 | 条数 |', '| --- | --- |',
    ]
    readme += [f'| {k} | {v} |' for k, v in sorted(counts.items(), key=lambda kv: -kv[1])]
    readme += ['', '## 怎么用', '',
               '1. 打开 `索引/按月份.md` 或 `索引/按类型.md` 找内容；',
               '2. 每条记录的文末有「同一天」「同类前后」，可以顺着链接一直看下去；',
               '3. 想当知识库用，把整个文件夹拖进 Obsidian，front-matter 里的',
               '   `kind / date / author` 可以直接做筛选和统计；',
               '4. 想给 AI 当长期记忆，把文件夹路径告诉它即可，不需要任何转换。', '',
               '## 隐私说明', '',
               '- 本包只包含**你自己的账号能看到的**内容；对方的私密日记、草稿、定时惊喜不会出现在这里。',
               '- 个人心愿（带密码的那种）只导出标题，正文加密内容不会写入 Markdown。',
               '- 这个包是**明文**的，请像对待日记本一样保管；要加密备份请用 App 内的「完整备份」。', '',
               '## 目录', '', '- [按月份](索引/按月份.md)', '- [按类型](索引/按类型.md)', '']
    files.append(('README.md', '\n'.join(readme)))
    files.append(('索引/按月份.md', '\n'.join(month_lines)))
    files.append(('索引/按类型.md', '\n'.join(kind_lines)))

    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
        for path, text in files:
            archive.writestr('恋爱空间-第二大脑/' + path, text)
        for source, name in media_files:
            archive.write(source, '恋爱空间-第二大脑/' + name)
    return target
