"""补丁镜像法部署（支持 static/ 与 app/ 后端改动）。

镜像层下载被阻断时的应急通道：以当前运行镜像为基底，叠加 COPY 改动过的文件。
容器内路径映射：static/... → /srv/static/...，app/... → /srv/app/...

用法：SSH_PASS='...' python deploy_patch_full.py <sha> <date> <file1> [file2 ...]
"""
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from deploy import connect, run  # noqa: E402

REMOTE = '/vol1/1000/LARJ'
BUILD_DIR = '/vol1/1000/LARJ-patch-build'
CANONICAL = '2126263229/love-space'
VERSION = '1.7.16'

# 本地 → 容器内路径映射
IN_CONTAINER = {
    'static/app.js': '/srv/static/app.js',
    'static/style.css': '/srv/static/style.css',
    'static/sw.js': '/srv/static/sw.js',
    'static/index.html': '/srv/static/index.html',
    'static/apk-notes.txt': '/srv/static/apk-notes.txt',
    'static/lovespace.apk': '/srv/static/lovespace.apk',
    'app/main.py': '/srv/app/main.py',
    'app/db.py': '/srv/app/db.py',
    'app/worker.py': '/srv/app/worker.py',
    'app/config.py': '/srv/app/config.py',
    'app/security.py': '/srv/app/security.py',
}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)


BINARY_EXT = ('.apk', '.png', '.jpg', '.jpeg', '.webp', '.gif', '.ico', '.zip', '.woff', '.woff2', '.ttf')


def md5(rel):
    data = open(rel, 'rb').read()
    if not rel.lower().endswith(BINARY_EXT):
        data = data.replace(b'\r\n', b'\n')  # 文本文件按 LF 归一，二进制原样比对
    return hashlib.md5(data).hexdigest()


if len(sys.argv) < 3:
    sys.exit('用法：deploy_patch_full.py <sha> <date> <file1> [file2 ...]')
sha, date = sys.argv[1], sys.argv[2]
files = sys.argv[3:]
tag = f'{CANONICAL}:sha-{sha}'

c = connect()
print('已连接 NAS')

# 1. 读取当前运行中的镜像 tag 作为补丁基底
code, out, _ = run(c, f'cd {REMOTE} && docker inspect love-space --format "{{{{.Config.Image}}}}" 2>/dev/null',
                   sudo=True, timeout=30)
base = (out or '').strip()
if not base:
    sys.exit(f'读不到当前运行镜像 tag（拿到 "{base}"），中止')
if base == tag:
    # 同一个 sha 重发（例如只改 ENV 里的版本号）：以当前镜像为基底再叠一层即可，
    # docker build 会在构建开始前先按 tag 解析基镜，构建完再把这个 tag 指过去，不会自引用。
    print('⚠️ 基底与目标 tag 相同，按同一 sha 重打一层（只改 ENV 或补文件时正常）')
print('当前运行镜像 →', base)

# 2. 写补丁 Dockerfile + 上传改动文件（按目录分 src 布局）
run(c, f'sudo mkdir -p {BUILD_DIR}/src/static {BUILD_DIR}/src/app && rm -rf {BUILD_DIR}/src/static/* {BUILD_DIR}/src/app/*',
    sudo=True, timeout=30)
sftp = c.open_sftp()
for rel in files:
    if rel.startswith('static/'):
        dest_dir = f'{BUILD_DIR}/src/static'
        dest_name = os.path.basename(rel)
    elif rel.startswith('app/'):
        dest_dir = f'{BUILD_DIR}/src/app'
        dest_name = os.path.basename(rel)
    else:
        sys.exit(f'不支持的改动文件：{rel}')
    sftp.put(rel, f'{dest_dir}/{dest_name}')
    run(c, f'chmod 644 {dest_dir}/{dest_name}', sudo=True, timeout=10)
    print('上传', rel, '→', dest_name)

# 生成 COPY 指令
copies = []
for rel in files:
    dest = IN_CONTAINER[rel]
    src = f'src/{rel}'
    copies.append(f'COPY --chmod=644 {src} {dest}')
dockerfile = f"""FROM {base}
{chr(10).join(copies)}
RUN chmod -R a+rX /srv/app /srv/static
ENV LOVE_BUILD={sha}-{date}
ENV LOVE_VERSION={VERSION}
"""
with sftp.open(f'{BUILD_DIR}/Dockerfile', 'w') as fh:
    fh.write(dockerfile)
sftp.close()

# 3. 构建补丁镜像
print('构建补丁镜像…')
# ⚠️ 必须 set -o pipefail：命令接了 `| tail -8` 之后退出码是 tail 的，永远是 0，
# 构建失败也照样往下走 —— 曾因此把 .env 改到一个不存在的 tag 上（1.6.7 踩过）。
code, out, err = run(c, f'cd {BUILD_DIR} && set -o pipefail && docker build -t {tag} . 2>&1 | tail -8',
                     sudo=True, timeout=180)
print(out or err)
if code != 0:
    sys.exit('补丁镜像构建失败（.env 未改动，容器还在跑原镜像）')
code, _, _ = run(c, f'docker image inspect {tag} >/dev/null 2>&1', sudo=True, timeout=30)
if code != 0:
    sys.exit(f'构建结束后找不到镜像 {tag}，中止')

# 3.5 预检：先试着"建"一次容器，不启动。
# 补丁镜像一层层往上叠，累计到 overlay2 的层数上限时，docker build 会成功、
# 直到 create 容器才抛 `max depth exceeded`。那一步在写 .env 之后，等于把 .env
# 指向一个永远起不来的 tag（1.7.16 就这么翻的车）。提前 create 一次，问题在
# 动 .env 之前就暴露，容器继续跑原镜像。
print('预检：试建容器…')
run(c, 'docker rm -f love-space-probe >/dev/null 2>&1; true', sudo=True, timeout=30)
code, out, err = run(c, f'docker create --name love-space-probe {tag} true', sudo=True, timeout=120)
run(c, 'docker rm -f love-space-probe >/dev/null 2>&1; true', sudo=True, timeout=30)
if code != 0:
    hint = '（多半是镜像层数到上限了，用 docker export/import 打平）' if 'max depth' in (err + out) else ''
    sys.exit(f'新镜像建不出容器，已中止，.env 未改动{hint}：{(err or out).strip()[:300]}')

# 4. md5 校验
paths = ' '.join(IN_CONTAINER[f] for f in files)
code, out, _ = run(c, f'docker run --rm --entrypoint md5sum {tag} {paths}', sudo=True, timeout=120)
got = {}
for line in (out or '').splitlines():
    p = line.split()
    if len(p) == 2 and len(p[0]) == 32:
        got[p[1]] = p[0]
stale = [f for f in files if got.get(IN_CONTAINER[f]) != md5(f)]
if stale:
    print('⚠️ md5 差异（多半只是换行符）：', ', '.join(stale))
else:
    print('✅ 镜像内容 = 本地文件')

# 5. 写 .env + 重启容器
# ⚠️ 这一步是"改全局状态"，失败必须把 .env 改回去：否则容器还在跑旧镜像，
# 而 .env 指向新 tag，下次任何 compose 操作都会拿它去起容器 —— 起不来就整站下线。
def write_env(img):
    return run(c, f'cd {REMOTE} && touch .env && grep -v "^LOVE_IMAGE=" .env > .env.new 2>/dev/null; '
                  f'echo "LOVE_IMAGE={img}" >> .env.new && mv .env.new .env && chmod 600 .env',
               sudo=True, timeout=60)


def switch_to(img):
    write_env(img)
    print('.env 固定镜像 →', img)
    return run(c, f'cd {REMOTE} && set -o pipefail && LOVE_IMAGE={img} '
                  f'docker compose up -d --force-recreate --no-build 2>&1 | tail -3',
               sudo=True, timeout=300)


def running_image():
    _, out, _ = run(c, 'docker ps --format "{{.Image}}" --filter name=love-space', sudo=True, timeout=30)
    return (out or '').strip()


def rollback(reason):
    print(f'❌ {reason}')
    print(f'↩️ 回滚 .env → {base} 并重建容器')
    code, out, err = switch_to(base)
    print(out or err)
    now = running_image()
    if code != 0 or base not in now:
        sys.exit(f'回滚也没成功，需要人工处理：.env 现在是 {base}，容器跑的是 {now or "无"}')
    sys.exit(f'部署失败已回滚，站点仍跑原镜像：{reason}')


code, out, err = switch_to(tag)
print(out or err)
if code != 0:
    rollback('容器重启失败')
# 起来了才算数：compose 拉不到镜像时也会打印 Started，之后才在 ps 里露出真相
now = running_image()
if tag not in now:
    rollback(f'容器没在跑目标镜像（当前：{now or "无"}）')

# 6. 清理构建目录
run(c, f'rm -rf {BUILD_DIR}', sudo=True, timeout=30)
print('✅ 部署完成，容器已切到', tag)
