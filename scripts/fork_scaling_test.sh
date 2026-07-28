#!/usr/bin/env bash
# 阶段4: 不同数据集大小下的 fork/BGSAVE 开销对比
# 用法: ./fork_scaling_test.sh <engine: redis|valkey> <port> <target_size_mb>
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

engine="$1"; port="$2"; target_mb="$3"
case "$engine" in
  redis)  image="$REDIS_IMAGE"; cli="redis-cli"; bench="redis-benchmark" ;;
  valkey) image="$VALKEY_IMAGE"; cli="valkey-cli"; bench="valkey-benchmark" ;;
esac

# 512B value, 需要多少 key 才能达到目标 MB (粗略估算,含 key 本身与结构开销,实测后按 used_memory 校正)
approx_keys=$(( target_mb * 1024 * 1024 / 700 ))

log "loading ~${approx_keys} keys (target ~${target_mb}MB) into ${engine}:${port}"
docker run --rm --network host "$image" "$bench" -h 127.0.0.1 -p "$port" -t set -n "$approx_keys" -d 512 -c 50 -r "$approx_keys" -q >/dev/null

used_mb=$(docker run --rm --network host "$image" "$cli" -p "$port" info memory | grep "^used_memory:" | tr -d '\r' | cut -d: -f2)
used_mb=$(( used_mb / 1024 / 1024 ))
dbsize=$(docker run --rm --network host "$image" "$cli" -p "$port" dbsize | tr -d '\r')
log "actual used_memory: ${used_mb}MB, dbsize: ${dbsize}"

# 触发 3 次 BGSAVE,记录 fork 耗时
for i in 1 2 3; do
  docker run --rm --network host "$image" "$cli" -p "$port" bgsave >/dev/null
  sleep 1.5
  fork_usec=$(docker run --rm --network host "$image" "$cli" -p "$port" info stats | grep latest_fork_usec | tr -d '\r' | cut -d: -f2)
  log "trial ${i}: latest_fork_usec=${fork_usec}"
done
