"""部署到飞牛 NAS。

两种模式：
  默认（pull）  直接用 CI 构建好的镜像，NAS 不编译。
                —— 前提是本地改动已 push 到 GitHub 且 CI 已构建完。
  --local       上传源码在 NAS 本地构建。GitHub 不通 / CI 未跑完时的应急通道。

关于镜像标签（重要）：
  ghcr 上 latest **只在打 v1.2.x 正式 tag 时才前进**，main 上的普通提交推的是
  sha-<前7位> 和 edge。所以默认按当前 HEAD 的 sha 拉，严格对应本地这一次提交；
  想用"最近一次正式发布"就 LOVE_TAG=latest。

关于拉取地址：
  NAS 直连 ghcr.io 被重置、ghcr 镜像站（nju）大层拉不动，而 Docker Hub 经 NAS 的
  国内链路实测顺畅（287MB 约 3 分钟）。CI 同时把镜像推到 ghcr 和 Docker Hub，
  所以常规部署一律从 Docker Hub 拉：2126263229/love-space:<tag>。
  可用 LOVE_REGISTRY 覆盖。

用法：SSH_PASS='...' /c/Python314/python.exe deploy_sync.py [--local]
"""
import hashlib
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from deploy import connect, run, USER  # noqa: E402

FILES = [
    # .dockerignore 必须带上：漏了它，NAS 本地构建会把 1.5G 的 data/ 当成构建上下文
    'requirements.txt', 'docker-compose.yml', 'Dockerfile', '.dockerignore',
    'app/__init__.py', 'app/backups.py', 'app/db.py', 'app/importers.py',
    'app/main.py', 'app/manage.py', 'app/notifications.py', 'app/security.py', 'app/webpush.py', 'app/worker.py',
    'app/serializers.py', 'app/config.py', 'app/markdown_export.py',
    'static/index.html', 'static/style.css', 'static/app.js', 'static/sw.js',
    'static/icon.svg', 'static/garden.svg', 'static/manifest.webmanifest',
    'static/icon-192.png', 'static/icon-512.png', 'static/maskable-512.png', 'static/apple-touch-icon.png',
    'static/lovespace.apk',
]
REMOTE = '/vol1/1000/LARJ'
# 只为「在 NAS 上编译」而存在的东西。改用 CI 镜像后全是垃圾：容器只读镜像内容，
# 唯一挂载的是 ./data。static/ 里还留着早已删掉的 body.js / dressup.js / vendor
# （three.js），留着只会让人误以为线上还在跑那套 3D。
REMOTE_JUNK = [
    'Dockerfile', 'requirements.txt', '.dockerignore', 'README.md',
    'build.log', 'build.done', 'check_db.py', 'send_test_msg.py',
    'docker-compose.build.yml', 'app', 'static', 'tests',
]
# --local 时才传上去的构建段：主 compose 已经不带 build 了，用 -f 叠加这个文件
# 才能在应急时本地编译，平时它不该出现在 NAS 上。
BUILD_OVERRIDE = """services:
  love:
    image: ${LOVE_IMAGE:-2126263229/love-space:local}
    build:
      context: .
      args:
        # 国内网络加速（海外部署可删除这两行）
        APT_MIRROR: mirrors.tuna.tsinghua.edu.cn
        PIP_INDEX_URL: https://pypi.tuna.tsinghua.edu.cn/simple
        LOVE_VERSION: ${LOVE_VERSION:-dev}
        LOVE_BUILD: ${LOVE_BUILD:-local}
"""
# 默认走 Docker Hub：ghcr 镜像站（nju）大层拉不动，Hub 实测顺畅；CI 已把镜像
# 同时推到两边，tag 完全一致。LOVE_REGISTRY 可覆盖（含 :tag 之外的仓库名）。
REGISTRY = os.environ.get('LOVE_REGISTRY', '2126263229/love-space')
# compose 里 image 用的是这个名字，拉完会 retag 上去，compose 才能认
CANONICAL = '2126263229/love-space'
# 本地构建产物单独打 tag，别去污染 latest —— 否则 NAS 上那个 latest 其实是
# 本地编译出来的，下次 pull 之前看起来像"已经拉过了"其实是旧的。
LOCAL_TAG = 'local'
# 容器内路径（WORKDIR /srv）；pull 模式用它核对镜像里是不是真的有这次改动
IN_CONTAINER = {
    'static/app.js': '/srv/static/app.js',
    'static/style.css': '/srv/static/style.css',
    'static/sw.js': '/srv/static/sw.js',
    'app/main.py': '/srv/app/main.py',
    'app/db.py': '/srv/app/db.py',
    'app/worker.py': '/srv/app/worker.py',
    'app/serializers.py': '/srv/app/serializers.py',
    'app/markdown_export.py': '/srv/app/markdown_export.py',
    'app/config.py': '/srv/app/config.py',
    'app/security.py': '/srv/app/security.py',
    'app/webpush.py': '/srv/app/webpush.py',
    'static/index.html': '/srv/static/index.html',
}

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

def md5(rel):
    """比较前把 CRLF 归一成 LF。

    Windows 工作区 checkout 成 CRLF（git autocrlf），CI 在 Linux 上构建用的是 LF，
    同一个文件的 md5 天然不同——不归一就会误报「镜像落后」而拒绝部署。"""
    return hashlib.md5(open(rel, 'rb').read().replace(b'\r\n', b'\n')).hexdigest()
local_mode = '--local' in sys.argv


def git(*args):
    return subprocess.run(['git', *args], capture_output=True, text=True).stdout.strip()


def preflight():
    """pull 模式前置校验：本地改动必须已经躺在 GitHub 上。

    否则拉到的是旧镜像，界面看起来"没生效"，这种问题最难查。"""
    # 只看已跟踪文件：未跟踪的本地草稿（如根目录 preview.html）不会进 CI 的 checkout，
    # 也就不该拦住部署；真正会被打进镜像的是 tracked 文件的改动。
    changed = git('diff', '--name-only', 'HEAD')
    if changed:
        sys.exit('❌ 已跟踪文件有未提交改动：\n   ' + changed.replace('\n', '\n   ')
                 + '\n   pull 模式部署的是 GitHub 上的代码，请先 commit + push，或用 --local 应急。')
    subprocess.run(['git', 'fetch', 'origin', 'main'], capture_output=True)
    head, remote = git('rev-parse', 'HEAD'), git('rev-parse', 'origin/main')
    if head != remote:
        sys.exit(f'❌ 本地 HEAD({head[:7]}) 与 origin/main({remote[:7]}) 不一致，请先 push（或 pull --rebase）。')


def mkdir_p(sftp, path):
    """逐级建目录：paramiko 的 mkdir 没有 -p。"""
    cur = REMOTE
    for part in path[len(REMOTE):].strip('/').split('/'):
        cur = f'{cur}/{part}'
        try:
            sftp.stat(cur)
        except IOError:
            sftp.mkdir(cur)


def put_tree(sftp, rel):
    """整目录上传。贴纸有几百个文件，逐个列进 FILES 不现实——之前 --local
    一直漏传 static/stickers，应急构建出来的镜像聊天贴纸全是裂图。"""
    base = os.path.join(ROOT, rel.replace('/', os.sep))
    if not os.path.isdir(base):
        return 0
    count = 0
    for dirpath, _, names in os.walk(base):
        rdir = REMOTE + '/' + os.path.relpath(dirpath, ROOT).replace(os.sep, '/')
        mkdir_p(sftp, rdir)
        for name in names:
            sftp.put(os.path.join(dirpath, name), f'{rdir}/{name}')
            count += 1
    return count


def cleanup_remote():
    """删掉 NAS 上只服务于「本地编译」的文件。

    容器跑的是镜像里的内容，唯一挂载的是 ./data，删这些不影响运行。
    真要留底就先打个 tar 丢到上级目录，不占部署目录。"""
    code, out, _ = run(c, f'cd {REMOTE} && ls -d app static Dockerfile 2>/dev/null | wc -l',
                       sudo=True, timeout=60)
    if (out or '0').strip() not in ('0', ''):
        ts = time.strftime('%Y%m%d-%H%M%S')
        arc = f'/vol1/1000/love-src-archive-{ts}.tar.gz'
        run(c, f'cd {REMOTE} && tar czf {arc} app static Dockerfile requirements.txt '
               f'README.md build.log tests .dockerignore 2>/dev/null; ls -la {arc}',
            sudo=True, timeout=600)
        print('归档备份 →', arc)
    run(c, f'cd {REMOTE} && rm -rf ' + ' '.join(REMOTE_JUNK), sudo=True, timeout=300)
    print('清理构建残留：', ', '.join(REMOTE_JUNK))


def set_env_image(target):
    """把当前镜像 tag 写进 NAS 的 .env。

    否则哪天有人在 NAS 上直接 docker compose up -d，会按默认值退回 latest
    （那是上一次正式 tag），界面悄悄回退到旧版本还查不出原因。"""
    owner = run(c, f'cd {REMOTE} && (stat -c "%U:%G" .env 2>/dev/null || echo "{USER}")',
                sudo=True, timeout=30)[1].strip() or USER
    cmd = (f'cd {REMOTE} && touch .env && grep -v "^LOVE_IMAGE=" .env > .env.new 2>/dev/null; '
           f'echo "LOVE_IMAGE={target}" >> .env.new && mv .env.new .env && '
           f'chown {owner} .env 2>/dev/null; chmod 600 .env')
    code, out, err = run(c, cmd, sudo=True, timeout=60)
    if code != 0:
        sys.exit('❌ 写 .env 失败：' + (err or out))
    print(f'.env 固定镜像 → {target}')


c = connect()
print('已连接 NAS')

if local_mode:
    # ———— 应急：上传源码 + NAS 本地构建 ————
    sftp = c.open_sftp()
    for f in FILES:
        d = os.path.dirname(f)
        if d:
            mkdir_p(sftp, f'{REMOTE}/{d}')
    for f in FILES:
        sftp.put(f, f'{REMOTE}/{f}')
        print('上传', f)
    n = put_tree(sftp, 'static/stickers')
    if n:
        print(f'上传 static/stickers（{n} 个文件）')
    with sftp.open(f'{REMOTE}/docker-compose.build.yml', 'w') as fh:
        fh.write(BUILD_OVERRIDE)
    sftp.close()
    print('上传 docker-compose.build.yml')

    print('NAS 本地构建镜像…')
    version = os.environ.get('LOVE_VERSION') or git('describe', '--tags', '--always')
    version = version[1:] if version.startswith('v') else version or 'dev'
    build_id = git('rev-parse', '--short', 'HEAD') or 'local'
    build_id = f'{build_id}-{time.strftime("%Y%m%d")}'
    print(f'版本 {version} / 构建 {build_id}')
    cmd = (f'cd {REMOTE} && LOVE_IMAGE={CANONICAL}:{LOCAL_TAG} LOVE_VERSION={version} '
           f'LOVE_BUILD={build_id} '
           f'docker compose -f docker-compose.yml -f docker-compose.build.yml '
           f'up -d --build --force-recreate 2>&1 | tail -3')
else:
    # ———— 默认：直接用 CI 构建好的镜像 ————
    preflight()
    tag = os.environ.get('LOVE_TAG') or 'sha-' + git('rev-parse', '--short', 'HEAD')
    src = f'{REGISTRY}:{tag}'
    target = f'{CANONICAL}:{tag}'
    print(f'镜像 {src}')

    # compose 偶尔会改（端口/环境变量），同步一份，避免远端漂了
    sftp = c.open_sftp()
    sftp.put('docker-compose.yml', f'{REMOTE}/docker-compose.yml')
    sftp.close()
    print('同步 docker-compose.yml')
    # 顺手清掉历史遗留的源码副本与构建产物：现在容器只读镜像，这些文件纯占地方
    cleanup_remote()

    code, out, err = run(c, f'docker pull {src} 2>&1 | tail -2', sudo=True, timeout=1800)
    print(out or err)
    if code != 0:
        sys.exit('❌ 拉取镜像失败。可换 LOVE_REGISTRY=ghcr.io/gbyyhbot/love-space 重试，或用 --local 应急。')

    # 关键校验：拉到的镜像里必须真的有这次提交的代码。
    # CI 还没构建完时同 tag 不存在、或 latest 还停在旧发布版，这时绝不能重启容器。
    paths = ' '.join(IN_CONTAINER.values())
    code, out, err = run(c, f'docker run --rm --entrypoint md5sum {src} {paths}', sudo=True, timeout=300)
    got = {}
    for line in (out or '').splitlines():
        p = line.split()
        if len(p) == 2 and len(p[0]) == 32:
            got[p[1]] = p[0]
    stale = [rel for rel, path in IN_CONTAINER.items() if got.get(path) != md5(rel)]
    if stale:
        sys.exit('❌ 镜像内容与本地不一致（CI 可能还没构建完这次提交）：' + ', '.join(stale)
                 + '\n   等 CI 跑完再执行，或用 --local 应急。')
    print('✅ 镜像内容 = 本地这一次提交')

    # compose 里写的是 ghcr.io/.../love-space，把拉下来的镜像挂到同名 tag 上它才认
    code, out, err = run(c, f'docker tag {src} {target}', sudo=True, timeout=120)
    if code != 0:
        sys.exit('❌ retag 失败：' + (err or out))
    set_env_image(target)
    cmd = (f'cd {REMOTE} && LOVE_IMAGE={target} '
           f'docker compose up -d --force-recreate --no-build 2>&1 | tail -3')

code, out, err = run(c, cmd, sudo=True, timeout=900)
print(out or err)
if code != 0:
    sys.exit(1)

targets = ' '.join(IN_CONTAINER.values())
verify = (
    "sleep 8; docker compose ps --format '{{.Name}} {{.Status}}'; "
    "curl -s -m 8 http://127.0.0.1:1314/api/status; echo; "
    f"docker exec love-space md5sum {targets}"
)
code, out, err = run(c, f'cd {REMOTE} && {verify}', sudo=True, timeout=180)
print(out or err)

remote_md5 = {}
for line in (out or '').splitlines():
    parts = line.split()
    if len(parts) == 2 and len(parts[0]) == 32:
        remote_md5[parts[1]] = parts[0]
bad = [rel for rel, path in IN_CONTAINER.items() if remote_md5.get(path) != md5(rel)]
if bad:
    print('❌ md5 不一致:', bad)
    sys.exit(1)
print('✅ 容器内文件与本地一致')
c.close()
