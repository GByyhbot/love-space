FROM python:3.13-slim

ARG APT_MIRROR=""
ARG PIP_INDEX_URL=""
# 构建期注入的版本信息，由 /api/status 读出（见 app/config.py）。
# CI 打 tag 时传 git tag 进来，网页版本号就不再需要人手改代码。
ARG LOVE_VERSION="dev"
ARG LOVE_BUILD="local"
# APK 版本：CI 打 tag 时传入与网页同号，/api/status 的 apk_version 才不会停在旧值
ARG LOVE_APK_VERSION=""

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TZ=Asia/Shanghai \
    DATA_DIR=/data \
    LOVE_VERSION=${LOVE_VERSION} \
    LOVE_BUILD=${LOVE_BUILD} \
    LOVE_APK_VERSION=${LOVE_APK_VERSION}

RUN if [ -n "$APT_MIRROR" ]; then \
        sed -i "s|deb.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list.d/debian.sources; \
    fi \
    && apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv

COPY requirements.txt .
RUN if [ -n "$PIP_INDEX_URL" ]; then \
        pip install --no-cache-dir -i "$PIP_INDEX_URL" -r requirements.txt \
        || pip install --no-cache-dir -r requirements.txt; \
    else \
        pip install --no-cache-dir -r requirements.txt; \
    fi

COPY app app
COPY static static
RUN chmod -R a+rX /srv/app /srv/static

# 非 root 运行。uid/gid 特意对齐 NAS 上的普通用户（Yyh154019:Users = 1000:1001），
# 这样数据卷里的文件主人用文件管理器就能直接改，不会越攒越多 root 所有的文件。
# 注意 gid 用 1001（Users）而不是 1000（Administrators）——别顺手给容器一个管理员组。
# -d /tmp：容器根文件系统是只读的（compose 里 read_only），HOME 指向不存在且不可写的
# /home/xxx 会让某些库在写缓存时炸掉；/tmp 是 tmpfs，可写。
RUN set -eux; \
    getent group 1001 >/dev/null || groupadd -g 1001 appuser; \
    getent passwd 1000 >/dev/null || useradd -u 1000 -g 1001 -M -d /tmp -s /usr/sbin/nologin appuser

USER 1000:1001

EXPOSE 1314

HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:1314/health', timeout=8)" || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "1314"]
