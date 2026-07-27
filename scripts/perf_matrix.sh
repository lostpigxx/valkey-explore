#!/usr/bin/env bash
# 阶段3性能基准测试矩阵驱动脚本
# 对已运行中的 redis(37000)/valkey(37001) 单机实例做多维度对比压测
# 用法: ./perf_matrix.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

REDIS_PORT=37000
VALKEY_PORT=37001
OUT="${RESULTS_DIR}/perf"
mkdir -p "$OUT"

run_bench() {
  local engine="$1" port="$2" label="$3"; shift 3
  local image bin
  case "$engine" in
    redis)  image="$REDIS_IMAGE"; bin="redis-benchmark" ;;
    valkey) image="$VALKEY_IMAGE"; bin="valkey-benchmark" ;;
  esac
  local outfile="${OUT}/${label}.txt"
  log "bench: engine=$engine label=$label args=$*"
  docker run --rm --network host "$image" "$bin" -h 127.0.0.1 -p "$port" "$@" > "$outfile" 2>&1
  grep -E "requests per second|throughput summary|latency summary|avg\s+min\s+p50|^\s+[0-9]" "$outfile" | tail -8
}

# 维度1: 不同 value 大小下的 SET/GET 吞吐延迟 (固定 c=50, n=100000, 无 pipeline)
for size in 128 1024 10240; do
  for eng in redis valkey; do
    port=$([ "$eng" = redis ] && echo $REDIS_PORT || echo $VALKEY_PORT)
    run_bench "$eng" "$port" "size${size}-${eng}" -t set,get -n 100000 -d "$size" -c 50
  done
done

# 维度2: 不同 pipeline 深度下的吞吐 (固定 d=128, c=50, n=200000)
for pdepth in 1 16 64; do
  for eng in redis valkey; do
    port=$([ "$eng" = redis ] && echo $REDIS_PORT || echo $VALKEY_PORT)
    run_bench "$eng" "$port" "pipe${pdepth}-${eng}" -t set,get -n 200000 -d 128 -c 50 -P "$pdepth"
  done
done

# 维度3: 全命令套件吞吐 (标准 redis-benchmark 默认测试集,含 incr/lpush/sadd/zadd等)
for eng in redis valkey; do
  port=$([ "$eng" = redis ] && echo $REDIS_PORT || echo $VALKEY_PORT)
  run_bench "$eng" "$port" "fullsuite-${eng}" -n 100000 -d 128 -c 50
done

# 维度4: 高并发连接数下的表现 (c=200)
for eng in redis valkey; do
  port=$([ "$eng" = redis ] && echo $REDIS_PORT || echo $VALKEY_PORT)
  run_bench "$eng" "$port" "highconc-${eng}" -t set,get -n 200000 -d 128 -c 200
done

log "done, results in $OUT"
