"""NAS 部署用的 SSH 小工具（deploy_patch / deploy_patch_full / deploy_sync 共用）。

口令只从环境变量 SSH_PASS 读，绝不落盘；主机/用户/端口从 deploy.env 读，
环境变量优先。飞牛 NAS 的登录用户不在 docker 组，所以 docker 命令一律 sudo。
"""
import os
import shlex

import paramiko

HERE = os.path.dirname(os.path.abspath(__file__))


def _load_env_file():
    """读 deploy.env（本地覆盖文件，已在 .gitignore 里）。"""
    conf = {}
    path = os.path.join(HERE, 'deploy.env')
    try:
        with open(path, encoding='utf-8') as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                key, value = line.split('=', 1)
                conf[key.strip()] = value.strip()
    except OSError:
        pass
    return conf


_ENV = _load_env_file()
HOST = os.environ.get('SSH_HOST') or _ENV.get('SSH_HOST', '192.168.31.95')
PORT = int(os.environ.get('SSH_PORT') or _ENV.get('SSH_PORT', '22'))
USER = os.environ.get('SSH_USER') or _ENV.get('SSH_USER', 'Yyh154019')
PASS = os.environ.get('SSH_PASS', '')
REMOTE_DIR = os.environ.get('SSH_REMOTE_DIR') or _ENV.get('SSH_REMOTE_DIR', '/vol1/1000/LARJ')


def shell_quote(s):
    return shlex.quote(str(s))


def connect():
    """连上 NAS。sudo 口令也用同一个 SSH_PASS。"""
    if not PASS:
        raise SystemExit("缺少 SSH_PASS 环境变量：SSH_PASS='...' python deploy_xxx.py ...")
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, port=PORT, username=USER, password=PASS,
                   timeout=20, banner_timeout=20, auth_timeout=20,
                   look_for_keys=False, allow_agent=False)
    return client


def run(client, cmd, sudo=False, timeout=120):
    """执行命令，返回 (退出码, stdout, stderr)。

    sudo 走 `printf 口令 | sudo -S`：NAS 上该用户可以用密码提权，
    而 `sudo -S` 需要口令从 stdin 进来，不能走交互。
    """
    if sudo:
        cmd = "echo %s | sudo -S -p '' bash -c %s" % (shell_quote(PASS), shell_quote(cmd))
    stdin, stdout, stderr = client.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode('utf-8', 'replace')
    err = stderr.read().decode('utf-8', 'replace')
    code = stdout.channel.recv_exit_status()
    return code, out, err


if __name__ == '__main__':
    c = connect()
    print(f'{USER}@{HOST}:{PORT} 已连接，远端目录 {REMOTE_DIR}')
    print(run(c, 'uname -a')[1].strip())
    c.close()
