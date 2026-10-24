"""模块导入图守卫：不许再出现循环导入。

main ↔ backups / webpush 曾经互相 import，靠函数内 `from .main import ...`
把环藏起来——改一个模块的 import 顺序就可能炸在另一个模块里。现在 serialize
下沉到 serializers.py、public_origin 下沉到 config.py，这个测试把结果钉住。
"""
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MODULES = ['db', 'config', 'security', 'serializers', 'importers', 'backups', 'notifications', 'webpush', 'worker', 'main']


@pytest.mark.parametrize('name', MODULES)
def test_module_imports_standalone(name):
    """每个模块都能在干净进程里单独 import，且不牵出 main。"""
    code = (
        'import importlib, sys\n'
        f'm = importlib.import_module("app.{name}")\n'
        'loaded = sorted(k for k in sys.modules if k.startswith("app."))\n'
        'print(loaded)\n'
        'assert "app" in sys.modules\n'
    )
    result = subprocess.run([sys.executable, '-c', code], cwd=ROOT,
                            capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, f'app.{name} 导入失败：\n{result.stderr[-2000:]}'

    if name != 'main':
        # 非入口模块不该把 main 拖进来——那正是环的信号
        assert 'app.main' not in result.stdout, f'app.{name} 间接导入了 app.main，循环导入又回来了'
