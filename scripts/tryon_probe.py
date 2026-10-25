#!/usr/bin/env python3
"""AI 试衣一次性验证脚本（不进产品、不碰线上、不写数据库）。

唯一目的：花一张图的成本，判断「生成效果值不值得为它做一整个功能」。
它不 import app/ 里任何模块，不启动服务，不改 data/。

用法
    # 最省事的用法：本地图 → 自动上传百炼临时存储 → 试衣 → 下载结果
    export DASHSCOPE_API_KEY=sk-xxxxxxxx
    python scripts/tryon_probe.py --person 全身照.jpg --top 上衣.jpg

    # 只试下装
    python scripts/tryon_probe.py --person 全身照.jpg --bottom 裤子.jpg

    # 已经是公网链接就不重复上传
    python scripts/tryon_probe.py --person https://x/a.jpg --top https://x/b.png

    # 先看发什么请求、大概花多少钱，不真调用
    python scripts/tryon_probe.py --person a.jpg --top b.jpg --dry-run

    # 脚本中途挂了 / 下载失败：用 task_id 续查，不会重复扣费
    python scripts/tryon_probe.py --task-id 0385dc79-5ff8-4d82-bcb6-xxxxxxxxxxxx

    # 对比更贵的 Plus 模型
    python scripts/tryon_probe.py ... --model aitryon-plus

依赖：只用 requirements.txt 里已有的 httpx（Pillow 可选，装了会做分辨率预检）。

价格（2026-10 华北2 北京，超免费额度后）：
    aitryon        ¥0.20/张
    aitryon-plus   ¥0.50/张
每个模型 400 张免费额度 / 90 天，验证阶段基本等于 0 成本。

退出码：0 成功；1 参数或输入不合法；2 上游调用失败；3 超时。
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import secrets
import sys
import time
from pathlib import Path

import httpx

BASE = (os.environ.get('DASHSCOPE_BASE_URL') or 'https://dashscope.aliyuncs.com').rstrip('/')
SUBMIT_PATH = '/api/v1/services/aigc/image2image/image-synthesis'
TASK_PATH = '/api/v1/tasks/{task_id}'
UPLOAD_POLICY_PATH = '/api/v1/uploads'

PRICE = {'aitryon': 0.20, 'aitryon-plus': 0.50}  # 元/张
ALLOWED_MODELS = tuple(PRICE)

# 官方对输入图的硬约束（超了上游直接报错，本地先挡掉，省一次往返）
MIN_BYTES = 5 * 1024
MAX_BYTES = 5 * 1024 * 1024
MIN_SIDE = 150
MAX_SIDE = 4096
ALLOWED_EXT = {'.jpg', '.jpeg', '.png', '.bmp', '.heic'}

SUCCEEDED = {'SUCCEEDED', 'SUCCESS'}
FAILED = {'FAILED', 'CANCELED', 'CANCELLED', 'UNKNOWN', 'EXPIRED'}


class ProbeError(Exception):
    """面向人的失败，带一句该怎么办。"""

    def __init__(self, message: str, hint: str = '', code: int = 2):
        super().__init__(message)
        self.hint = hint
        self.code = code


# ── 小工具 ────────────────────────────────────────────────────────────


def say(msg: str = '') -> None:
    print(msg, flush=True)


def step(msg: str) -> None:
    say(f'\n▸ {msg}')


def mask(url: str) -> str:
    """日志里只留可辨识前缀，避免把带签名的地址整条打出去。"""
    if len(url) <= 48:
        return url
    return url[:44] + '…' + url[-12:]


def is_remote(value: str) -> bool:
    return value.startswith(('http://', 'https://'))


def human_bytes(n: int) -> str:
    if n >= 1024 * 1024:
        return f'{n / 1024 / 1024:.2f} MB'
    if n >= 1024:
        return f'{n / 1024:.0f} KB'
    return f'{n} B'


def api_error(resp: httpx.Response) -> ProbeError:
    """把上游的错误体翻译成人话。DashScope 的报错字段是 code / message / request_id。"""
    try:
        body = resp.json()
    except ValueError:
        body = {}
    code = body.get('code') or f'HTTP {resp.status_code}'
    message = body.get('message') or resp.text[:300]
    rid = body.get('request_id') or ''
    hints = {
        'InvalidApiKey': 'API Key 不对。去百炼控制台确认，并注意它必须与地域匹配（北京用 dashscope.aliyuncs.com）。',
        'UnpurchasedModel': '这个模型没开通。控制台里先开通「AI试衣」。',
        'Throttling': '触发限流（RPS 10 / 并发 5）。等几秒再试。',
        'InvalidParameter': '参数不合法。重点检查图片尺寸/大小是否在 150–4096px、5KB–5MB 之间。',
        'DataInspectionFailed': '内容审核未通过。换一张图。',
    }
    return ProbeError(f'{code}: {message}' + (f' (request_id={rid})' if rid else ''), hints.get(code, ''))


def preflight(path: Path) -> tuple[int, int | None, int | None]:
    """本地预检，返回 (字节数, 宽, 高)。宽高在没装 Pillow 时为 None。"""
    if not path.is_file():
        raise ProbeError(f'找不到文件：{path}', '路径相对当前工作目录，建议用绝对路径。', code=1)
    size = path.stat().st_size
    # 先查格式再查大小：格式不对的话，"压缩一下"这句提示是误导。
    if path.suffix.lower() not in ALLOWED_EXT:
        raise ProbeError(
            f'{path.name} 格式 {path.suffix} 不受支持（只收 jpg/png/bmp/heic）',
            'WEBP/GIF 先转成 JPG：ffmpeg -i in.webp out.jpg',
            code=1,
        )
    if not MIN_BYTES <= size <= MAX_BYTES:
        raise ProbeError(
            f'{path.name} 大小 {human_bytes(size)} 超出 5KB–5MB 限制',
            '太大的滚成 JPG 质量 85；太小说明几乎没内容，换一张原图。',
            code=1,
        )

    width = height = None
    try:
        from PIL import Image  # 可选依赖：没装就跳过分辨率检查
    except ImportError:
        return size, None, None

    try:
        with Image.open(path) as img:
            width, height = img.size
    except Exception as exc:  # noqa: BLE001 - 打不开就是打不开，不需要细分
        raise ProbeError(f'{path.name} 无法解析为图片：{exc}', '换一张真图试试。', code=1) from exc

    for side in (width, height):
        if not MIN_SIDE <= side <= MAX_SIDE:
            raise ProbeError(
                f'{path.name} 尺寸 {width}x{height} 超出 150–4096px 限制',
                '不足就放大，过大就等比缩到长边 4096 以内。',
                code=1,
            )
    return size, width, height


# ── 上传本地文件拿 oss:// 临时地址 ─────────────────────────────────────


def upload_temp(client: httpx.Client, api_key: str, model: str, path: Path) -> str:
    """走百炼官方的「上传本地文件获取临时URL」，拿到 oss:// 前缀的地址。

    这条路径的意义：甲方（我们的 NAS）不需要给公网开任何后门，
    照片是主动推给百炼的临时存储，48 小时后自动清理。
    """
    step(f'上传 {path.name} 到百炼临时存储')
    try:
        resp = client.get(
            BASE + UPLOAD_POLICY_PATH,
            params={'action': 'getPolicy', 'model': model},
            headers={'Authorization': f'Bearer {api_key}'},
        )
    except httpx.HTTPError as exc:
        raise ProbeError(f'取上传凭证失败：{exc}', '检查本机出网；这条接口是 GET，不需要代理。') from exc
    if resp.status_code != 200:
        raise api_error(resp)

    policy = (resp.json() or {}).get('data') or {}
    required = ('upload_host', 'upload_dir', 'oss_access_key_id', 'signature', 'policy')
    missing = [k for k in required if not policy.get(k)]
    if missing:
        raise ProbeError(f'上传凭证缺字段：{missing}', '百炼接口可能改版了，拿完整响应去提工单。')

    upload_dir = policy['upload_dir'].rstrip('/')
    # 文件名加随机前缀：临时空间开启 forbid-overwrite，同名重传会被 OSS 拒（409）。
    # 48 小时内反复跑同一组图很常见，前缀省掉这个坑。
    key = f'{upload_dir}/{secrets.token_hex(4)}-{path.name}'
    # OSS 的 POST 表单要求 file 字段排最后，其余是普通表单项。
    form = {
        'OSSAccessKeyId': policy['oss_access_key_id'],
        'Signature': policy['signature'],
        'policy': policy['policy'],
        'x-oss-object-acl': policy.get('x_oss_object_acl', 'private'),
        'x-oss-forbid-overwrite': policy.get('x_oss_forbid_overwrite', 'true'),
        'key': key,
        'success_action_status': '200',
    }
    mime = mimetypes.guess_type(path.name)[0] or 'application/octet-stream'
    try:
        with path.open('rb') as fh:
            resp = client.post(
                policy['upload_host'],
                data=form,
                files={'file': (path.name, fh, mime)},
                timeout=httpx.Timeout(120.0, connect=15.0),
            )
    except httpx.HTTPError as exc:
        raise ProbeError(f'上传失败：{exc}', '网络抖动可重试；反复失败就换成 http/https 图床链接。') from exc
    if resp.status_code not in (200, 204):
        raise ProbeError(
            f'OSS 拒收：HTTP {resp.status_code} {resp.text[:200]}',
            '多半是 policy 过期（凭证有时效），重跑一次即可。',
        )

    say(f'  ok  oss://{mask(key)}')
    return f'oss://{key}'


# ── 提交 + 轮询 ───────────────────────────────────────────────────────


def submit(client: httpx.Client, api_key: str, body: dict) -> str:
    step('提交试衣任务')
    try:
        resp = client.post(
            BASE + SUBMIT_PATH,
            headers={
                'Authorization': f'Bearer {api_key}',
                'Content-Type': 'application/json',
                'X-DashScope-Async': 'enable',  # 这个头漏了会报 current user api does not support synchronous calls
            },
            json=body,
        )
    except httpx.HTTPError as exc:
        raise ProbeError(f'提交失败：{exc}', '网络层问题，直接重跑；不会产生计费。') from exc
    if resp.status_code != 200:
        raise api_error(resp)

    output = (resp.json() or {}).get('output') or {}
    task_id = output.get('task_id')
    if not task_id:
        raise ProbeError(f'提交成功但没拿到 task_id：{resp.text[:300]}', '接口返回结构可能变了。')
    say(f'  ok  task_id={task_id}  status={output.get("task_status")}')
    return task_id


def poll(client: httpx.Client, api_key: str, task_id: str, timeout: float) -> dict:
    step('等待结果')
    started = time.monotonic()
    deadline = started + timeout
    delay = 2.0
    last = ''
    while time.monotonic() < deadline:
        try:
            resp = client.get(BASE + TASK_PATH.format(task_id=task_id),
                              headers={'Authorization': f'Bearer {api_key}'})
        except httpx.HTTPError as exc:
            say(f'  查询抖动：{exc}，继续等')
            time.sleep(delay)
            continue
        if resp.status_code != 200:
            raise api_error(resp)

        payload = resp.json() or {}
        output = payload.get('output') or {}
        status = (output.get('task_status') or '').upper()
        if status != last:
            say(f'  {status or "?"}  ({time.monotonic() - started:.0f}s)')
            last = status
        if status in SUCCEEDED:
            return payload
        if status in FAILED:
            reason = output.get('message') or output.get('code') or payload.get('message') or '上游没说原因'
            raise ProbeError(
                f'任务 {status}：{reason}\n  task_id={task_id}',
                '图片不合规（非全身/多人/服饰不是平拍图）最常见。换图再试；'
                '或用 --task-id 重新查一次，确认不是临时故障。',
            )
        time.sleep(delay)
        delay = min(delay * 1.5, 8.0)

    raise ProbeError(f'等了 {int(timeout)}s 还没出结果，task_id={task_id}',
                     f'任务不会丢（百炼保留 24h）。稍后用：\n'
                     f'  python scripts/tryon_probe.py --task-id {task_id}', code=3)


def extract_urls(payload: dict) -> list[str]:
    """结果地址的位置在不同模型/版本上不统一，这里宽松地捞，捞不到就把原始 JSON 打出来。"""
    output = payload.get('output') or {}
    urls: list[str] = []

    results = output.get('results')
    if isinstance(results, dict):
        results = [results]
    for item in results or []:
        if not isinstance(item, dict):
            continue
        for key, value in item.items():
            if isinstance(value, str) and value.startswith('http') and 'url' in key.lower():
                urls.append(value)
            elif key in ('image', 'image_url') and isinstance(value, str) and value.startswith('http'):
                urls.append(value)

    for key in ('result_url', 'url', 'image_url'):
        value = output.get(key)
        if isinstance(value, str) and value.startswith('http'):
            urls.append(value)

    return list(dict.fromkeys(urls))


def download(client: httpx.Client, url: str, dest_dir: Path, tag: str) -> Path:
    step('下载结果')
    dest_dir.mkdir(parents=True, exist_ok=True)
    try:
        with client.stream('GET', url, follow_redirects=True,
                           timeout=httpx.Timeout(120.0, connect=15.0)) as resp:
            if resp.status_code != 200:
                raise ProbeError(f'下载失败 HTTP {resp.status_code}',
                                 '结果地址 24 小时有效，过期就只能重新生成。')
            raw = resp.read()
    except httpx.HTTPError as exc:
        raise ProbeError(f'下载失败：{exc}', '结果地址还在有效期内的话，重跑一次下载即可。') from exc

    ctype = (resp.headers.get('content-type') or '').lower()
    ext = '.png' if 'png' in ctype else '.jpg'
    out = dest_dir / f'tryon-{tag}{ext}'
    out.write_bytes(raw)
    say(f'  ok  {out}  ({human_bytes(len(raw))})')
    return out


# ── 主流程 ────────────────────────────────────────────────────────────


def resolve_image(client: httpx.Client, api_key: str, model: str, value: str, label: str,
                  dry_run: bool) -> str:
    if is_remote(value):
        say(f'  {label}: 直接用 {mask(value)}')
        return value
    path = Path(value).expanduser()
    size, width, height = preflight(path)
    dims = f'{width}x{height}' if width else '尺寸未检查（没装 Pillow）'
    say(f'  {label}: {path.name}  {human_bytes(size)}  {dims}')
    if dry_run:
        return f'oss://<{label} 待上传>'
    return upload_temp(client, api_key, model, path)


def build_body(model: str, person: str, top: str | None, bottom: str | None,
               resolution: int, restore_face: bool) -> dict:
    data: dict = {'person_image_url': person}
    if top:
        data['top_garment_url'] = top
    if bottom:
        data['bottom_garment_url'] = bottom
    return {
        'model': model,
        'input': data,
        'parameters': {'resolution': resolution, 'restore_face': restore_face},
    }


def run(args: argparse.Namespace) -> int:
    api_key = os.environ.get('DASHSCOPE_API_KEY', '').strip()
    if not api_key and not args.dry_run:
        raise ProbeError(
            '没设置 DASHSCOPE_API_KEY',
            'export DASHSCOPE_API_KEY=sk-xxxx  （Windows PowerShell: $env:DASHSCOPE_API_KEY="sk-xxxx"）',
            code=1,
        )

    out_dir = Path(args.out).expanduser()
    client = httpx.Client(timeout=httpx.Timeout(60.0, connect=10.0), follow_redirects=False)

    with client:
        # 续查模式：只轮询 + 下载，不再提交，因此不产生新的计费。
        if args.task_id:
            say(f'续查已有任务 {args.task_id}（不会重复扣费）')
            payload = poll(client, api_key, args.task_id, args.timeout)
            urls = extract_urls(payload)
            if not urls:
                raise ProbeError('任务成功但没找到图片地址', '把下面这段原始响应贴给我看：\n'
                                 + json.dumps(payload, ensure_ascii=False, indent=2))
            download(client, urls[0], out_dir, args.task_id[:8])
            return 0

        if not args.person:
            raise ProbeError('缺少 --person（人物全身照）', code=1)
        if not (args.top or args.bottom):
            raise ProbeError('--top / --bottom 至少要给一个',
                             '连衣裙、连体衣放 --top，下装留空。', code=1)

        say(f'模型 {args.model}   预计成本 ¥{PRICE[args.model]:.2f}/张（400 张内免费）')
        step('准备输入图')
        person = resolve_image(client, api_key, args.model, args.person, 'person', args.dry_run)
        top = resolve_image(client, api_key, args.model, args.top, 'top   ', args.dry_run) if args.top else None
        bottom = (resolve_image(client, api_key, args.model, args.bottom, 'bottom', args.dry_run)
                  if args.bottom else None)

        body = build_body(args.model, person, top, bottom, args.resolution, not args.no_restore_face)

        if args.dry_run:
            step('请求体（--dry-run，未提交、未上传、未计费）')
            preview = json.loads(json.dumps(body))
            preview['input'] = {k: mask(v) for k, v in body['input'].items()}
            say(json.dumps(preview, ensure_ascii=False, indent=2))
            say(f'\nPOST {BASE}{SUBMIT_PATH}')
            say('Header: X-DashScope-Async: enable')
            return 0

        started = time.monotonic()
        task_id = submit(client, api_key, body)
        # 先落盘再等结果：进程被杀也不会丢掉 task_id，能续查而不是重刷一笔钱。
        out_dir.mkdir(parents=True, exist_ok=True)
        record = out_dir / 'last_task.json'
        record.write_text(json.dumps(
            {'task_id': task_id, 'model': args.model, 'created': int(time.time()),
             'person': mask(person), 'top': mask(top or ''), 'bottom': mask(bottom or '')},
            ensure_ascii=False, indent=2), encoding='utf-8')
        say(f'  task_id 已存到 {record}（挂了就用 --task-id {task_id} 续查）')

        payload = poll(client, api_key, task_id, args.timeout)
        urls = extract_urls(payload)
        if not urls:
            raise ProbeError('任务成功但没找到图片地址', '把下面这段原始响应贴给我看：\n'
                             + json.dumps(payload, ensure_ascii=False, indent=2))

        outputs = [download(client, url, out_dir, task_id[:8] if len(urls) == 1 else f'{task_id[:8]}-{i}')
                   for i, url in enumerate(urls)]

        elapsed = time.monotonic() - started
        images = (payload.get('usage') or {}).get('image_count') or len(outputs)
        step('完成')
        say(f'  模型 {args.model}   出图 {images} 张   耗时 {elapsed:.1f}s   成本约 ¥{PRICE[args.model] * images:.2f}')
        for path in outputs:
            say(f'  → {path}')
        say('\n现在看图，只回答一个问题：这张图你会想存进恋爱空间吗？')
        say('是 → 按最小接入做（ai_jobs 表 + ai_loop 线程，结果落现有 media 表）。')
        say('否 → 到此为止，省下后面几个月的工。')
        return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description='AI 试衣一次性验证脚本（不写数据库、不影响线上）',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='例：python scripts/tryon_probe.py --person 全身照.jpg --top 上衣.jpg',
    )
    parser.add_argument('--person', help='人物全身照：本地路径或 http(s) 链接')
    parser.add_argument('--top', help='上装 / 连衣裙 / 连体衣的平拍图')
    parser.add_argument('--bottom', help='下装平拍图（可选）')
    parser.add_argument('--model', default='aitryon', choices=ALLOWED_MODELS,
                        help='aitryon=¥0.20/张（默认），aitryon-plus=¥0.50/张')
    parser.add_argument('--task-id', help='只续查已有任务，不重新提交（不重复扣费）')
    parser.add_argument('--out', default='probe_out', help='结果目录，默认 probe_out/')
    parser.add_argument('--resolution', type=int, default=-1, help='-1 表示自动（默认）')
    parser.add_argument('--no-restore-face', action='store_true', help='关闭面部修复')
    parser.add_argument('--timeout', type=float, default=180.0, help='等待结果的秒数，默认 180')
    parser.add_argument('--dry-run', action='store_true', help='只打印请求，不上传不调用不计费')
    args = parser.parse_args(argv)

    try:
        return run(args)
    except ProbeError as exc:
        say(f'\n✗ {exc}')
        if exc.hint:
            say(f'  → {exc.hint}')
        return exc.code
    except KeyboardInterrupt:
        say('\n已中断。若已拿到 task_id，用 --task-id 续查，别重复提交。')
        return 130


if __name__ == '__main__':
    sys.exit(main())
