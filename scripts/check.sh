#!/usr/bin/env bash
# 本地质量闸门：语法检查 + 全量测试。CI 与本地共用同一套命令。
# 用法：bash scripts/check.sh   （可用 PYTHON=/path/to/python 覆盖解释器）
set -euo pipefail
cd "$(dirname "$0")/.."
PY="${PYTHON:-python}"
"$PY" -m py_compile app/*.py
"$PY" -m pytest -q
