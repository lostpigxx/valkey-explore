#!/usr/bin/env bash
# 公共变量与函数,被其他脚本 source

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESULTS_DIR="${PROJECT_ROOT}/results"
DATA_ROOT="${PROJECT_ROOT}/.data"   # 容器挂载的数据目录,不入库

REDIS_IMAGE="redis:7.2.6"
VALKEY_IMAGE="${VALKEY_IMAGE:-valkey/valkey:9.0}"

now_ms() {
  python3 -c 'import datetime; print(datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3])'
}

log() {
  echo "[$(now_ms)] $*"
}

# container_running <name> -> 0/1
container_running() {
  docker ps --format '{{.Names}}' | grep -qx "$1"
}

# container_exists <name> -> 0/1
container_exists() {
  docker ps -a --format '{{.Names}}' | grep -qx "$1"
}

ensure_data_dir() {
  mkdir -p "$1"
}
