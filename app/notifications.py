import ipaddress
import json
import os
import smtplib
import socket
import ssl
import threading
import time
from email.message import EmailMessage
from urllib.parse import urlparse

import httpx


def validate_url(url):
    parsed = urlparse(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError('通知地址需要使用 HTTPS，并且不能在地址中包含用户名密码')
    if parsed.port and parsed.port != 443:
        raise ValueError('通知地址需要使用标准 HTTPS 端口')
    return parsed.hostname


def validate_config(kind, config):
    required = {'smtp': ['host', 'port', 'username', 'password', 'from', 'to'], 'bark': ['key'],
                'serverchan': ['key'], 'pushplus': ['token'], 'wecom': ['url'], 'webhook': ['url'],
                'telegram': ['token', 'chat_id'], 'dingtalk': ['token', 'secret'], 'feishu': ['token', 'secret'],
                'ntfy': ['host', 'topic']}
    if len(json.dumps(config)) > 16000:
        raise ValueError('渠道配置过长')
    if kind not in required:
        raise ValueError('不支持的渠道类型')
    if any(not str(config.get(k, '')).strip() for k in required[kind]):
        raise ValueError('请填写完整的渠道配置')
    if kind in {'wecom', 'webhook'}:
        host = validate_url(config['url'])
        if kind == 'wecom' and host != 'qyapi.weixin.qq.com':
            raise ValueError('企业微信机器人需要使用 qyapi.weixin.qq.com 的 Webhook 地址')
    if kind == 'bark' and config.get('url'):
        validate_url(config['url'])
    if kind == 'telegram':
        if not str(config['token']).count(':') >= 1 or not str(config['chat_id']).lstrip('-').isdigit():
            raise ValueError('Telegram Token 格式应为 数字:字母数字，chat_id 为数字（群组带负号）')
    if kind == 'dingtalk' and not str(config['secret']).startswith('SEC'):
        raise ValueError('钉钉机器人 secret 以 SEC 开头')
    if kind == 'feishu' and not str(config['secret']).startswith('SEC') and not str(config['secret']).count('-') >= 1:
        raise ValueError('飞书机器人签名校验 secret 格式不正确')
    if kind == 'ntfy':
        try:
            validate_url(str(config['host']).rstrip('/'))
        except ValueError as exc:
            raise ValueError('ntfy 服务地址需要使用 HTTPS 和标准端口') from exc
    if kind == 'smtp':
        if int(config['port']) not in {465, 587}:
            raise ValueError('邮件使用 465（SSL）或 587（STARTTLS）端口')
        if any('\n' in str(config[k]) or '\r' in str(config[k]) for k in ('from', 'to')):
            raise ValueError('邮件地址格式不正确')


_host_cache = {}
_host_cache_lock = threading.Lock()
_HOST_CACHE_TTL = 600


def check_host(host):
    allowed = set(filter(None, os.getenv('NOTIFY_ALLOWED_PRIVATE_HOSTS', '').split(',')))
    if host in allowed:
        return
    # 每次投递都做 DNS 解析代价不小（尤其高频 ntfy 内置通道），缓存通过判定 10 分钟
    with _host_cache_lock:
        cached = _host_cache.get(host)
        if cached and cached > time.monotonic():
            return
    for info in socket.getaddrinfo(host, None):
        if not ipaddress.ip_address(info[4][0]).is_global:
            raise ValueError('通知目的地不是公网地址；自建服务请由管理员配置允许列表')
    with _host_cache_lock:
        _host_cache[host] = time.monotonic() + _HOST_CACHE_TTL


def send(kind, config, title, body, event_id):
    validate_config(kind, config)
    url = os.getenv('PUBLIC_URL', '').rstrip('/')
    body = body + ('\n' + url if url else '')
    if kind == 'smtp':
        check_host(config['host'])
        message = EmailMessage()
        message['Subject'], message['From'], message['To'] = title, config['from'], config['to']
        message['Message-ID'] = f'<{event_id}@love-space.local>'
        message.set_content(body)
        port = int(config['port'])
        client = smtplib.SMTP_SSL(config['host'], port, timeout=15, context=ssl.create_default_context()) if port == 465 else smtplib.SMTP(config['host'], port, timeout=15)
        with client:
            if port == 587:
                client.starttls(context=ssl.create_default_context())
            client.login(config['username'], config['password'])
            client.send_message(message)
        return
    if kind == 'bark':
        endpoint = config.get('url', 'https://api.day.app').rstrip('/') + '/push'
        payload = {'device_key': config['key'], 'title': title, 'body': body, 'url': url, 'group': '恋爱空间'}
    elif kind == 'serverchan':
        key = config['key']
        if not key.isalnum():
            raise ValueError('SendKey 格式不正确')
        endpoint, payload = f'https://sctapi.ftqq.com/{key}.send', {'title': title, 'desp': body}
    elif kind == 'pushplus':
        endpoint, payload = 'https://www.pushplus.plus/send', {'token': config['token'], 'title': title, 'content': body, 'template': 'txt'}
    elif kind == 'wecom':
        endpoint, payload = config['url'], {'msgtype': 'text', 'text': {'content': title + '\n' + body}}
    elif kind == 'telegram':
        endpoint = f'https://api.telegram.org/bot{config["token"]}/sendMessage'
        payload = {'chat_id': config['chat_id'], 'text': title + '\n' + body, 'parse_mode': 'HTML', 'disable_web_page_preview': True}
    elif kind == 'dingtalk':
        import time, hmac, hashlib, base64, urllib.parse
        ts = str(int(time.time() * 1000))
        sign = base64.b64encode(hmac.new(config['secret'].encode(), (ts + '\n' + config['secret']).encode(), hashlib.sha256).digest()).decode()
        endpoint = f'https://oapi.dingtalk.com/robot/send?access_token={config["token"]}&timestamp={ts}&sign={urllib.parse.quote(sign)}'
        payload = {'msgtype': 'text', 'text': {'content': title + '\n' + body}}
    elif kind == 'feishu':
        import time, hmac, hashlib, base64
        ts = str(int(time.time()))
        string_to_sign = f'{ts}\n{config["secret"]}'
        sign = base64.b64encode(hmac.new(string_to_sign.encode(), digestmod=hashlib.sha256).digest()).decode()
        endpoint = f'https://open.feishu.cn/open-apis/bot/v2/hook/{config["token"]}?timestamp={ts}&sign={sign}'
        payload = {'msg_type': 'text', 'content': {'text': title + '\n' + body}}
    elif kind == 'ntfy':
        ntfy_url = config['host'].rstrip('/') + '/' + config['topic'].lstrip('/')
        check_host(urlparse(ntfy_url).hostname)
        with httpx.Client(timeout=15, follow_redirects=False, trust_env=False) as client:
            response = client.post(ntfy_url, data=(title + '\n' + body).encode('utf-8'),
                                   headers={'Title': 'LoveSpace', 'Tags': 'heart', 'Idempotency-Key': event_id})
            response.raise_for_status()
        return
    else:
        endpoint, payload = config['url'], {'id': event_id, 'title': title, 'body': body, 'url': url}
    check_host(validate_url(endpoint))
    headers = {'Idempotency-Key': event_id}
    if kind == 'webhook' and config.get('token'):
        headers['Authorization'] = 'Bearer ' + config['token']
    with httpx.Client(timeout=15, follow_redirects=False, trust_env=False) as client:
        response = client.post(endpoint, json=payload, headers=headers)
        response.raise_for_status()
        if kind != 'webhook':
            result = response.json()
            expected_map = {'bark': 200, 'pushplus': 200, 'wecom': 0, 'dingtalk': 0, 'feishu': 0, 'telegram': 200, 'serverchan': 0}
            expected = expected_map.get(kind, 0)
            code = result.get('errcode') if kind == 'wecom' else (result.get('errcode') if kind == 'dingtalk' else (result.get('StatusCode') if kind == 'feishu' else (result.get('ok') if kind == 'telegram' else result.get('code'))))
            # telegram 用 ok=True 判定；其他渠道用码值
            if kind == 'telegram':
                if not result.get('ok'):
                    raise ValueError('Telegram 未接受消息，请检查 Token 和 chat_id')
            elif code != expected:
                raise ValueError('通知服务未接受消息，请检查账号、额度和渠道配置')
