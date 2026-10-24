"""与环境相关的纯函数。

单独开一个模块同样是为了打破循环导入：webpush.py 需要 public_origin，
而 main.py 又 import 了 webpush——以前靠函数内 `from .main import ...` 把环藏起来。
这里不 import 任何 app 内部模块，谁都能安全引用。
"""
import os
from urllib.parse import urlparse


def public_origin():
    """对外可访问的 origin，仅当配置了 HTTPS 的 PUBLIC_URL 才有值。

    Web Push 的 VAPID `sub` 必须是可联系的 HTTPS 地址；没有配就用占位邮箱，
    宁可让 push 服务用默认校验，也不要塞一个内网 http 地址进去。
    """
    value = urlparse(os.getenv('PUBLIC_URL', ''))
    return f'{value.scheme}://{value.netloc}' if value.scheme == 'https' and value.netloc else ''
