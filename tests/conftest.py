import os
import tempfile

# 必须在导入 app 之前设置：隔离的数据目录 + 关闭后台线程
os.environ.setdefault('DATA_DIR', tempfile.mkdtemp(prefix='love-test-'))
os.environ.setdefault('RUN_WORKER', 'false')

import pytest
from fastapi.testclient import TestClient

# 必须晚于上面的环境变量设置
from app.main import app  # noqa: E402

# 从 test_acceptance.py 搬过来：登录客户端要能被所有测试模块共用，
# 放在测试文件里的话每个模块都会重新 setup 一遍，第二次必然 409。
HEADERS = {'X-Love-Space': '1'}
PASSWORD = 'love-space-123'


@pytest.fixture(scope='session')
def client_a():
    with TestClient(app, base_url='https://testserver', headers=HEADERS) as client:
        r = client.post('/api/setup', headers=HEADERS,
                        json={'username': 'lover1', 'password': PASSWORD, 'name': '小兔'})
        assert r.status_code == 200, r.text
        yield client


@pytest.fixture(scope='session')
def client_b(client_a):
    token = client_a.post('/api/invite', headers=HEADERS).json()['token']
    with TestClient(app, base_url='https://testserver', headers=HEADERS) as client:
        r = client.post('/api/join', headers=HEADERS,
                        json={'username': 'lover2', 'password': PASSWORD, 'name': '小熊', 'token': token})
        assert r.status_code == 200, r.text
        yield client


