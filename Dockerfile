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

EXPOSE 1314

HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:1314/health', timeout=8)" || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "1314"]
