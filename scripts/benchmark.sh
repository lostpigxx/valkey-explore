#!/usr/bin/env bash
# 用官方 benchmark 工具对指定实例做压测,输出 CSV 结果到 results/
#
# 用法: ./benchmark.sh <engine: redis|valkey> <host> <port> <label> [extra args passed to benchmark tool]
#
# 例: ./benchmark.sh valkey 127.0.0.1 30000 vk-single-set -t set -n 1000000 -d 512 -c 50 -P 16

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

engine="$1"; host="$2"; port="$3"; label="$4"; shift 4

case "$engine" in
  redis)  image="$REDIS_IMAGE"; bin="redis-benchmark" ;;
  valkey) image="$VALKEY_IMAGE"; bin="valkey-benchmark" ;;
  *) echo "unknown engine: $engine"; exit 1 ;;
esac

mkdir -p "${RESULTS_DIR}/benchmark"
outfile="${RESULTS_DIR}/benchmark/${label}-$(date +%Y%m%d-%H%M%S).txt"

log "running ${bin} against ${host}:${port}, label=${label}"
log "args: $*"

docker run --rm --network host "$image" "$bin" -h "$host" -p "$port" --csv "$@" | tee "$outfile"

log "results saved to ${outfile}"
